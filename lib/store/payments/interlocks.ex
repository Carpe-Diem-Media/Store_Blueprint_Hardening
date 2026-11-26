defmodule Store.Payments.Interlocks do
  @moduledoc """
  Checkout and payment replay interlocks for idempotent intent creation and paid apply-once flow.
  """

  import Ash.Expr
  require Ash.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias Store.Digital.Facade, as: DigitalFacade
  alias Store.Fulfillment.Facade, as: FulfillmentFacade
  alias Store.Orders.Order

  alias Store.Payments.{
    ObservationEvidence,
    ObservationReconciliation,
    PaymentAttempt,
    PaymentIntent,
    PaymentOutcomeCertification,
    PaymentOutcomeResolver,
    ProviderEvent,
    Providers,
    WebhookReceipt
  }

  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.Inputs.RenewalOrderPaymentApplicationInput
  alias Store.Payments.Inputs.RenewalPaymentApplicationInput
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.Types.CanonicalReceipt
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.RenewalCollectionAttempt
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Subscriptions.RenewalCollectionAttempts.PaymentApplicationSettlementInput
  alias Store.Subscriptions.RenewalCollectionAttempts.RecordFinancialOutcomeInput
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.Governance.Idempotency
  alias Store.Workers.EnsureSubscriptionsForPaidOrderWorker
  alias Store.Workers.ReconcilePaidSubscriptionRenewalWorker

  @type payment_intent_request :: %{
          required(:order_id) => String.t(),
          required(:amount_received_minor) => integer(),
          required(:currency) => String.t(),
          optional(:provider) => Providers.provider(),
          optional(:payment_intent_key) => String.t(),
          optional(:provider_request_reference) => String.t() | nil
        }

  @spec create_or_reuse_payment_intent(payment_intent_request(), keyword()) ::
          {:ok,
           %{
             payment_intent: PaymentIntent.t(),
             payment_intent_key: String.t(),
             duplicate?: boolean()
           }}
          | {:error, Error.t() | term()}
  def create_or_reuse_payment_intent(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    ash_opts = payment_ash_opts(opts)

    with {:ok, request} <- normalize_payment_intent_request(attrs),
         {:ok, intent, duplicate?} <- create_or_reuse_payment_intent_record(request, ash_opts) do
      {:ok,
       %{
         payment_intent: intent,
         payment_intent_key: request.payment_intent_key,
         duplicate?: duplicate?
       }}
    end
  end

  @spec process_payment_webhook_receipt(WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt(receipt, opts \\ [])

  def process_payment_webhook_receipt(
        %WebhookReceipt{provider: :paystack, processing_status: "processed"},
        _opts
      ),
      do: :ok

  def process_payment_webhook_receipt(%WebhookReceipt{provider: :paystack} = receipt, _opts) do
    with :ok <- ensure_receipt_verified(receipt),
         :ok <- Providers.ensure_enabled_provider(:paystack),
         {:ok, payload} <- decode_webhook_payload(receipt.raw_body),
         {:ok, canonical} <- normalize_canonical_receipt(:paystack, payload),
         {:ok, payment_intent} <- fetch_paystack_checkout(canonical.provider_request_reference),
         {:ok, verified} <- verify_paystack_checkout(payment_intent, canonical),
         {:ok, _event_key} <- ingest_provider_event(receipt, canonical),
         {:ok, %{outcome: outcome}}
         when outcome in [:authoritative_success, :already_applied_success] <-
           apply_observed_payment_outcome(verified) do
      :ok
    else
      :ignore -> {:discard, "Paystack event is outside sandbox checkout"}
      {:ok, _outcome} -> paystack_outcome_unresolved()
      {:discard, _} = result -> result
      {:error, _} = result -> result
    end
  end

  def process_payment_webhook_receipt(%WebhookReceipt{} = receipt, _opts) do
    with :ok <- ensure_receipt_verified(receipt),
         :ok <- Providers.ensure_enabled_provider(receipt.provider),
         {:ok, payload} <- decode_webhook_payload(receipt.raw_body),
         {:ok, canonical} <- normalize_canonical_receipt(receipt.provider, payload),
         {:ok, payment_intent} <- fetch_payment_intent_for_canonical(canonical),
         {:ok, provider_event_key} <- ingest_provider_event(receipt, canonical),
         {:ok, %PaymentAttempt{} = evidence, observation} <-
           record_payment_attempt(payment_intent, receipt, canonical),
         :ok <- validate_canonical_receipt_target(payment_intent, canonical),
         {:ok, payment_intent} <-
           hydrate_payment_intent_provider_references(payment_intent, canonical),
         {:ok, _outcome} <-
           apply_provider_observation(
             payment_intent,
             observation,
             provider_event_key,
             evidence
           ) do
      :ok
    else
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_paystack_checkout(reference) do
    case fetch_payment_intent_by_provider_request_reference(:paystack, reference) do
      {:ok, %PaymentIntent{purpose: :order_checkout} = intent} -> {:ok, intent}
      {:ok, _intent} -> {:discard, "Paystack checkout reference has no Store payment intent"}
      {:error, _} = result -> result
    end
  end

  defp verify_paystack_checkout(payment_intent, %CanonicalReceipt{
         provider_payment_id: transaction_id,
         amount_minor: amount,
         currency: currency,
         provider_environment: environment
       }) do
    input = %ObservePaymentIntentInput{payment_intent_id: payment_intent.id}

    case ObservationReconciliation.observe_payment_intent(input) do
      {:ok,
       %{
         eligibility: :eligible,
         observation: %ProviderObservation{
           provider_transaction_id: ^transaction_id,
           amount_minor: ^amount,
           currency: ^currency,
           provider_environment: ^environment
         }
       } = verified} ->
        {:ok, verified}

      {:ok, _observation} ->
        paystack_outcome_unresolved()

      {:error, _} = result ->
        result
    end
  end

  defp paystack_outcome_unresolved do
    {:error,
     Error.new(
       "PAYMENT_OUTCOME_UNRESOLVED",
       "Paystack webhook and checkout verification do not match"
     )}
  end

  @spec apply_payment_success_once(PaymentIntent.t() | String.t(), keyword()) ::
          {:ok, %{applied?: boolean(), order: Order.t(), payment_intent: PaymentIntent.t()}}
          | {:error, Error.t() | term()}
  def apply_payment_success_once(payment_intent_or_id, opts \\ [])

  def apply_payment_success_once(%PaymentIntent{} = payment_intent, opts) when is_list(opts) do
    apply_payment_success_once_internal(
      payment_intent,
      false,
      Keyword.get(opts, :payment_attempt_id)
    )
  end

  def apply_payment_success_once(%PaymentIntent{} = payment_intent, _opts) do
    apply_payment_success_once_internal(payment_intent, false, nil)
  end

  def apply_payment_success_once(payment_intent_id, opts)
      when is_binary(payment_intent_id) and is_list(opts) do
    with {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id) do
      apply_payment_success_once(payment_intent, opts)
    end
  end

  @spec renewal_payment_application_status_for_system(RenewalPaymentApplicationInput.t()) ::
          {:ok, :applied | :unapplied} | {:error, Error.t()}
  def renewal_payment_application_status_for_system(%RenewalPaymentApplicationInput{} = input) do
    read_renewal_payment_application_status(input)
  end

  @spec serialize_renewal_order_payment_application_for_system(
          RenewalOrderPaymentApplicationInput.t()
        ) :: {:ok, :unapplied} | {:error, Error.t()}
  def serialize_renewal_order_payment_application_for_system(
        %RenewalOrderPaymentApplicationInput{} = input
      ) do
    run_renewal_application_transaction(fn -> lock_and_confirm_unapplied_renewal_order(input) end)
  end

  defp lock_and_confirm_unapplied_renewal_order(%RenewalOrderPaymentApplicationInput{
         order_id: order_id
       }) do
    with :ok <- lock_order!(order_id),
         {:ok, []} <- read_renewal_order_payment_applications(order_id) do
      {:ok, :unapplied}
    else
      {:ok, [_application]} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "renewal Order has an application without a bound PaymentIntent"
         )}

      {:ok, [_first, _second | _rest]} ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal Order has conflicting applications")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_renewal_order_payment_applications(order_id) do
    case SQL.query(
           Repo,
           "SELECT payment_intent_id::text FROM payment_applications WHERE order_id = $1::text::uuid LIMIT 2",
           [order_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  @spec serialize_renewal_payment_application_for_system(RenewalPaymentApplicationInput.t()) ::
          {:ok, :applied | :unapplied} | {:error, Error.t()}
  def serialize_renewal_payment_application_for_system(%RenewalPaymentApplicationInput{} = input) do
    run_renewal_application_transaction(fn ->
      lock_and_read_renewal_payment_application(input)
    end)
  end

  defp lock_and_read_renewal_payment_application(%RenewalPaymentApplicationInput{} = input) do
    with :ok <- lock_order!(input.order_id),
         :ok <- lock_payment_intent_for_renewal(input.order_id, input.payment_intent_id) do
      read_renewal_payment_application_status(input)
    end
  end

  defp run_renewal_application_transaction(fun) do
    if Repo.in_transaction?() do
      fun.()
    else
      case Repo.transaction(fn ->
             rollback_renewal_application_error(fun.())
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, Normalize.normalize(reason)}
      end
    end
  end

  defp rollback_renewal_application_error({:error, reason}), do: Repo.rollback(reason)
  defp rollback_renewal_application_error(result), do: result

  defp lock_payment_intent_for_renewal(order_id, payment_intent_id) do
    query = """
    SELECT order_id::text
    FROM payment_intents
    WHERE id = $1::text::uuid
    FOR UPDATE
    """

    case SQL.query(Repo, query, [payment_intent_id]) do
      {:ok, %{rows: [[^order_id]]}} ->
        :ok

      {:ok, %{rows: [[_other_order_id]]}} ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal payment identity conflicts")}

      {:ok, %{rows: []}} ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal payment intent was not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp read_renewal_payment_application_status(%RenewalPaymentApplicationInput{} = input) do
    query = """
    SELECT payment_applications.payment_intent_id::text, payment_intents.order_id::text
    FROM payment_applications
    JOIN payment_intents ON payment_intents.id = payment_applications.payment_intent_id
    WHERE payment_applications.order_id = $1::text::uuid
    LIMIT 2
    """

    case SQL.query(Repo, query, [input.order_id]) do
      {:ok, %{rows: []}} ->
        {:ok, :unapplied}

      {:ok, %{rows: [[payment_intent_id, payment_order_id]]}}
      when payment_intent_id == input.payment_intent_id and payment_order_id == input.order_id ->
        {:ok, :applied}

      {:ok, %{rows: [[_payment_intent_id, _payment_order_id]]}} ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "order payment identity conflicts")}

      {:ok, %{rows: [_first, _second]}} ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "order has conflicting payment applications")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def apply_observed_payment_outcome(%{
        payment_intent: %PaymentIntent{} = payment_intent,
        observation: %ProviderObservation{} = observation,
        evidence: %PaymentAttempt{} = evidence
      }) do
    with {:ok, current_intent} <- fetch_payment_intent(payment_intent.id),
         {:ok, persisted_evidence} <- fetch_payment_attempt(evidence.id),
         :ok <- validate_persisted_evidence(current_intent, observation, persisted_evidence),
         {:ok, outcome} <-
           apply_provider_observation(current_intent, observation, nil, persisted_evidence) do
      {:ok, %{outcome: outcome, payment_intent: current_intent}}
    end
  end

  def apply_observed_payment_outcome(_result),
    do: {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "payment observation is invalid")}

  def validate_collection_outcome_certification(%ValidateRenewalCollectionOutcomeInput{} = input) do
    with {:ok, canonical_input} <-
           ValidateRenewalCollectionOutcomeInput.new(Map.from_struct(input)),
         {:ok, {certification, evidence, payment_intent}} <-
           fetch_outcome_certification_context(canonical_input.payment_attempt_id),
         true <- payment_intent.id == canonical_input.payment_intent_id,
         :ok <- validate_outcome_certification_identity(certification, evidence, payment_intent),
         :ok <-
           validate_certified_provider_outcome(
             certification,
             evidence,
             payment_intent,
             canonical_input.financial_outcome
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "provider outcome identity conflicts")}
    end
  end

  defp maybe_record_outcome_certification(
         payment_intent,
         observation,
         %PaymentAttempt{} = evidence,
         outcome
       ) do
    case {collection_financial_outcome(outcome),
          observation_certifies_collection_outcome?(payment_intent, observation, outcome)} do
      {financial_outcome, true} when is_atom(financial_outcome) ->
        with :ok <- validate_persisted_evidence(payment_intent, observation, evidence),
             {:ok, _certification} <-
               PaymentOutcomeCertification
               |> Ash.Changeset.for_create(
                 :record,
                 %{
                   payment_intent_id: payment_intent.id,
                   payment_attempt_id: evidence.id,
                   financial_outcome: Atom.to_string(financial_outcome)
                 },
                 context: %{system?: true}
               )
               |> Ash.create(
                 domain: Store.Payments,
                 authorize?: false,
                 context: %{system?: true}
               ) do
          {:ok, evidence.id}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp observation_certifies_collection_outcome?(payment_intent, observation, outcome) do
    finality = Providers.classify_payment_finality(observation.provider, observation)

    case {collection_financial_outcome(outcome), observation.normalized_outcome, finality} do
      {:verified_success, :authoritative_success, :authoritative_success} ->
        case Providers.expected_environment(payment_intent.provider) do
          {:ok, environment} ->
            observation_eligibility(payment_intent, observation, environment) == :eligible

          _ ->
            false
        end

      {:verified_terminal_financial_non_success, :failure_observation, :terminal_non_success} ->
        true

      {:requires_action, :requires_action, :non_terminal} ->
        true

      _ ->
        false
    end
  end

  defp fetch_outcome_certification_context(payment_attempt_id) do
    query = """
    SELECT
      certification.id::text,
      certification.payment_intent_id::text,
      certification.payment_attempt_id::text,
      certification.financial_outcome,
      payment_intent.provider::text,
      payment_intent.purpose::text,
      payment_intent.provider_payment_id,
      payment_intent.provider_request_reference,
      payment_intent.provider_session_id,
      payment_intent.amount_received_minor,
      payment_intent.currency,
      evidence.id::text,
      evidence.payment_intent_id::text,
      evidence.provider::text,
      evidence.outcome,
      evidence.provider_reference,
      evidence.provider_reference_kind,
      evidence.provider_transaction_id,
      evidence.observation_source,
      evidence.raw_provider_status,
      evidence.amount_minor,
      evidence.currency,
      evidence.provider_environment,
      evidence.provider_occurred_at,
      evidence.observed_at,
      evidence.provider_event_id,
      evidence.payload_sha256
    FROM payment_outcome_certifications AS certification
    JOIN payment_intents AS payment_intent
      ON payment_intent.id = certification.payment_intent_id
    JOIN payment_attempts AS evidence
      ON evidence.id = certification.payment_attempt_id
     AND evidence.payment_intent_id = payment_intent.id
    WHERE certification.payment_attempt_id = $1::text::uuid
    LIMIT 2
    """

    case SQL.query(Repo, query, [payment_attempt_id]) do
      {:ok, %{rows: [row]}} ->
        {:ok, certification_context(row)}

      {:ok, %{rows: []}} ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "provider outcome certification was not found")}

      {:ok, %{rows: _multiple}} ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "provider outcome certification is ambiguous")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp certification_context([
         certification_id,
         certification_payment_intent_id,
         certification_payment_attempt_id,
         certification_outcome,
         provider,
         purpose,
         provider_payment_id,
         provider_request_reference,
         provider_session_id,
         amount_received_minor,
         payment_intent_currency,
         evidence_id,
         evidence_payment_intent_id,
         evidence_provider,
         evidence_outcome,
         provider_reference,
         provider_reference_kind,
         provider_transaction_id,
         observation_source,
         raw_provider_status,
         evidence_amount_minor,
         evidence_currency,
         provider_environment,
         provider_occurred_at,
         observed_at,
         provider_event_id,
         payload_sha256
       ]) do
    certification = %PaymentOutcomeCertification{
      id: certification_id,
      payment_intent_id: certification_payment_intent_id,
      payment_attempt_id: certification_payment_attempt_id,
      financial_outcome: certified_outcome_atom(certification_outcome)
    }

    payment_intent = %PaymentIntent{
      id: certification_payment_intent_id,
      provider: Providers.normalize_provider(provider),
      purpose: payment_intent_purpose(purpose),
      provider_payment_id: provider_payment_id,
      provider_request_reference: provider_request_reference,
      provider_session_id: provider_session_id,
      amount_received_minor: amount_received_minor,
      currency: payment_intent_currency
    }

    evidence = %PaymentAttempt{
      id: evidence_id,
      payment_intent_id: evidence_payment_intent_id,
      provider: Providers.normalize_provider(evidence_provider),
      outcome: evidence_outcome,
      provider_reference: provider_reference,
      provider_reference_kind: provider_reference_kind,
      provider_transaction_id: provider_transaction_id,
      observation_source: observation_source,
      raw_provider_status: raw_provider_status,
      amount_minor: evidence_amount_minor,
      currency: evidence_currency,
      provider_environment: provider_environment,
      provider_occurred_at: provider_occurred_at,
      observed_at: observed_at,
      provider_event_id: provider_event_id,
      payload_sha256: payload_sha256
    }

    {certification, evidence, payment_intent}
  end

  defp certified_outcome_atom("requires_action"), do: :requires_action
  defp certified_outcome_atom("verified_success"), do: :verified_success

  defp certified_outcome_atom("verified_terminal_financial_non_success"),
    do: :verified_terminal_financial_non_success

  defp certified_outcome_atom(_outcome), do: :unknown

  defp payment_intent_purpose("subscription_payment_method_update"),
    do: :subscription_payment_method_update

  defp payment_intent_purpose(_purpose), do: :order_checkout

  defp validate_outcome_certification_identity(certification, evidence, payment_intent) do
    if certification.payment_attempt_id == evidence.id and
         certification.payment_intent_id == payment_intent.id and
         evidence.payment_intent_id == payment_intent.id do
      case observation_from_payment_attempt(evidence) do
        %ProviderObservation{} = observation ->
          validate_observation_identity(payment_intent, observation)

        _ ->
          {:error,
           Error.new("PAYMENT_EVENT_UNVERIFIED", "provider outcome evidence is incomplete")}
      end
    else
      {:error,
       Error.new("PAYMENT_EVENT_UNVERIFIED", "provider outcome evidence identity conflicts")}
    end
  end

  defp validate_certified_provider_outcome(certification, evidence, payment_intent, outcome) do
    with true <- certification.financial_outcome == outcome,
         %ProviderObservation{} = observation <- observation_from_payment_attempt(evidence),
         true <- observation_certifies_collection_outcome?(payment_intent, observation, outcome) do
      :ok
    else
      _ ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "provider evidence does not certify the requested collection outcome"
         )}
    end
  end

  defp apply_payment_success_once_internal(
         %PaymentIntent{} = payment_intent,
         verified_correction?,
         payment_attempt_id
       ) do
    started_at = System.monotonic_time()

    result =
      with true <- is_binary(payment_intent.order_id),
           {:ok, order} <- fetch_order(payment_intent.order_id),
           {:ok,
            %{
              result: result,
              renewal_attempt_lookup: renewal_attempt_lookup,
              inventory_variant_ids_to_invalidate: inventory_variant_ids_to_invalidate
            }, notifications} <-
             Repo.transaction(fn ->
               run_apply_payment_success_once(
                 payment_intent,
                 order,
                 verified_correction?,
                 payment_attempt_id
               )
             end)
             |> normalize_transaction_result(),
           :ok <-
             Store.Orders.invalidate_inventory_availability_for_variants(
               inventory_variant_ids_to_invalidate
             ),
           :ok <-
             AshNotifications.notify_post_commit(
               notifications,
               context: %{
                 flow: :apply_payment_success_once,
                 order_id: order.id,
                 payment_intent_id: payment_intent.id
               }
             ),
           :ok <-
             Store.Orders.notify_order_state_change(
               result.order.id,
               result.order.state,
               :payment_succeeded
             ),
           :ok <- maybe_enqueue_fulfillment(result),
           :ok <-
             maybe_record_renewal_collection_outcome(
               payment_intent,
               :authoritative_success,
               payment_attempt_id,
               renewal_attempt_lookup
             ),
           :ok <- maybe_enqueue_subscriptions(result, renewal_attempt_lookup),
           :ok <- maybe_enqueue_order_receipt(result) do
        {:ok, result}
      else
        false ->
          {:error,
           Error.new("PAYMENT_EVENT_UNVERIFIED", "payment intent is not attached to an order")}

        {:error, reason} ->
          {:error, reason}
      end

    emit_apply_payment_success_once_telemetry(result, started_at)
    result
  end

  defp normalize_payment_intent_request(attrs) do
    order_id = attr(attrs, :order_id)
    amount_received_minor = attr(attrs, :amount_received_minor)
    currency = attr(attrs, :currency)
    provider_input = attr(attrs, :provider)
    provider_request_reference = attr(attrs, :provider_request_reference)

    with {:ok, provider} <- normalize_provider(provider_input),
         :ok <- Providers.ensure_enabled_provider(provider),
         :ok <- require_binary(order_id, "order_id is required"),
         :ok <-
           require_non_negative_integer(
             amount_received_minor,
             "amount_received_minor must be >= 0"
           ),
         :ok <- require_binary(currency, "currency is required"),
         :ok <- optional_binary(provider_request_reference, "provider_request_reference"),
         payment_intent_key =
           attr(
             attrs,
             :payment_intent_key,
             if(
               is_binary(order_id) and is_integer(amount_received_minor) and is_binary(currency),
               do:
                 Idempotency.payment_intent_key(
                   order_id,
                   amount_received_minor,
                   currency,
                   provider
                 ),
               else: nil
             )
           ),
         :ok <- require_binary(payment_intent_key, "payment_intent_key is required") do
      {:ok,
       %{
         order_id: order_id,
         amount_received_minor: amount_received_minor,
         currency: currency,
         provider: provider,
         payment_intent_key: payment_intent_key,
         provider_request_reference: provider_request_reference
       }}
    end
  end

  defp create_or_reuse_payment_intent_record(request, ash_opts) do
    with {:ok, preflight_intent} <- read_preflight_payment_intent(request) do
      create_or_reuse_payment_intent_from_preflight(request, preflight_intent, ash_opts)
    end
  end

  defp create_or_reuse_payment_intent_from_preflight(
         %{provider: :paystack, provider_request_reference: reference, payment_intent_key: key},
         %PaymentIntent{
           provider: :paystack,
           provider_request_reference: nil,
           purpose: :order_checkout,
           payment_intent_key: key
         },
         _ash_opts
       )
       when is_binary(reference) do
    {:error,
     Error.new(
       "PAYMENT_OUTCOME_UNRESOLVED",
       "This payment needs a support review.",
       %{reason: :missing_durable_reference}
     )}
  end

  defp create_or_reuse_payment_intent_from_preflight(
         request,
         %PaymentIntent{payment_intent_key: payment_intent_key} = intent,
         _ash_opts
       )
       when payment_intent_key == request.payment_intent_key do
    if reusable_payment_intent_matches?(intent, request) do
      {:ok, intent, true}
    else
      {:error,
       Error.new(
         "PAYMENT_INTENT_DUPLICATE",
         "payment intent does not match its immutable collection identity"
       )}
    end
  end

  defp create_or_reuse_payment_intent_from_preflight(
         _request,
         %PaymentIntent{state: :succeeded},
         _ash_opts
       ) do
    {:error, Error.new("PAYMENT_ALREADY_SUCCEEDED", "payment already succeeded for order")}
  end

  defp create_or_reuse_payment_intent_from_preflight(_request, %PaymentIntent{}, _ash_opts) do
    {:error, Error.new("PAYMENT_INTENT_DUPLICATE", "payment intent already in-flight for order")}
  end

  defp create_or_reuse_payment_intent_from_preflight(request, nil, ash_opts) do
    with {:ok, intent} <- create_or_reuse_intent(request, ash_opts) do
      {:ok, intent, payment_intent_duplicate?(intent)}
    end
  end

  defp reusable_payment_intent_matches?(intent, request) do
    intent.provider_request_reference == request.provider_request_reference or
      (String.starts_with?(request.payment_intent_key, "renewal-collection:") and
         intent.provider == request.provider and intent.order_id == request.order_id and
         intent.amount_received_minor == request.amount_received_minor and
         String.upcase(intent.currency || "") == String.upcase(request.currency) and
         is_binary(intent.provider_request_reference) and intent.provider_request_reference != "")
  end

  defp create_or_reuse_intent(request, ash_opts) do
    attrs = %{
      order_id: request.order_id,
      amount_received_minor: request.amount_received_minor,
      currency: String.upcase(request.currency),
      provider: request.provider,
      payment_intent_key: request.payment_intent_key,
      provider_request_reference: request.provider_request_reference
    }

    PaymentIntent
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create(ash_opts)
    |> case do
      {:ok, intent} ->
        {:ok, intent}

      {:error, error} ->
        normalize_create_or_reuse_error(error)
    end
  end

  defp normalize_create_or_reuse_error(error) do
    message = Exception.message(error)

    cond do
      String.contains?(message, "payment_intents_unique_in_flight_order_id_index") ->
        {:error,
         Error.new(
           "PAYMENT_INTENT_DUPLICATE",
           "payment intent already in-flight for order"
         )}

      String.contains?(message, "payment_intents_unique_payment_intent_key_index") ->
        {:error, Error.new("PAYMENT_INTENT_DUPLICATE", "payment intent key already exists")}

      true ->
        {:error, error}
    end
  end

  defp read_preflight_payment_intent(request) do
    blocking_query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(
          payment_intent_key == ^request.payment_intent_key or
            (order_id == ^request.order_id and
               (state == :succeeded or state == :submitted or state == :requires_action))
        )
      )
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)

    case Ash.read(blocking_query, payment_ash_opts([])) do
      {:ok, intents} ->
        {:ok, prefer_preflight_intent(intents, request.payment_intent_key)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp prefer_preflight_intent(intents, payment_intent_key) do
    Enum.find(intents, &(&1.payment_intent_key == payment_intent_key)) ||
      Enum.find(intents, &(&1.state == :succeeded)) ||
      List.first(intents)
  end

  defp emit_apply_payment_success_once_telemetry(result, started_at) do
    :telemetry.execute(
      [:store, :payments, :interlock_apply_payment_success_once],
      %{duration: System.monotonic_time() - started_at},
      %{
        replay: apply_payment_success_once_replay?(result),
        outcome: apply_payment_success_once_outcome(result)
      }
    )
  end

  defp apply_payment_success_once_replay?({:ok, %{applied?: false}}), do: true
  defp apply_payment_success_once_replay?(_result), do: false

  defp apply_payment_success_once_outcome({:ok, _result}), do: :ok
  defp apply_payment_success_once_outcome({:error, _reason}), do: :error
  defp apply_payment_success_once_outcome(_result), do: :unknown

  defp payment_intent_duplicate?(%PaymentIntent{} = intent) do
    Ash.Resource.get_metadata(intent, :upsert_skipped) == true
  end

  defp decode_webhook_payload(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:discard, "invalid webhook payload"}
    end
  end

  defp decode_webhook_payload(_raw_body), do: {:discard, "invalid webhook payload"}

  defp ensure_receipt_verified(%WebhookReceipt{verification_status: "verified"}), do: :ok

  defp ensure_receipt_verified(%WebhookReceipt{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "webhook receipt must be signature-verified before processing"
     )}
  end

  defp normalize_canonical_receipt(provider, payload) when is_map(payload) do
    with {:ok, normalized_provider} <- normalize_provider(provider) do
      Providers.normalize_webhook(normalized_provider, payload)
    end
  end

  defp normalize_canonical_receipt(_provider, _payload) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "unable to normalize provider receipt")}
  end

  defp fetch_payment_intent_for_canonical(%CanonicalReceipt{} = canonical) do
    provider_session_id = canonical.provider_session_id
    provider_payment_id = canonical.provider_payment_id
    provider_request_reference = canonical.provider_request_reference
    local_payment_intent_id = canonical.local_payment_intent_id

    with {:ok, provider} <- normalize_provider(canonical.provider),
         {:ok, by_provider_session_id} <-
           fetch_payment_intent_by_provider_session_id(provider, provider_session_id),
         {:ok, by_provider_payment_id} <-
           fetch_payment_intent_by_provider_payment_id(provider, provider_payment_id),
         {:ok, by_provider_request_reference} <-
           fetch_payment_intent_by_provider_request_reference(
             provider,
             provider_request_reference
           ),
         {:ok, by_local_payment_intent_id} <-
           fetch_payment_intent_if_present(local_payment_intent_id) do
      cond do
        match?(%PaymentIntent{}, by_provider_session_id) ->
          {:ok, by_provider_session_id}

        match?(%PaymentIntent{}, by_provider_payment_id) ->
          {:ok, by_provider_payment_id}

        match?(%PaymentIntent{}, by_provider_request_reference) ->
          {:ok, by_provider_request_reference}

        match?(%PaymentIntent{}, by_local_payment_intent_id) ->
          {:ok, by_local_payment_intent_id}

        true ->
          fallback_fetch_payment_intent(
            provider_payment_id || provider_session_id || provider_request_reference ||
              local_payment_intent_id
          )
      end
    end
  end

  defp fetch_payment_intent_by_provider_session_id(provider, provider_session_id)
       when is_atom(provider) and is_binary(provider_session_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(provider == ^provider and provider_session_id == ^provider_session_id)
      )

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_by_provider_session_id(_provider, _provider_session_id),
    do: {:ok, nil}

  defp fetch_payment_intent_by_provider_payment_id(provider, provider_payment_id)
       when is_atom(provider) and is_binary(provider_payment_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(provider == ^provider and provider_payment_id == ^provider_payment_id)
      )

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_by_provider_payment_id(_provider, _provider_payment_id),
    do: {:ok, nil}

  defp fetch_payment_intent_by_provider_request_reference(provider, provider_request_reference)
       when is_atom(provider) and is_binary(provider_request_reference) do
    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(provider == ^provider and provider_request_reference == ^provider_request_reference)
      )

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_by_provider_request_reference(_provider, _provider_request_reference),
    do: {:ok, nil}

  defp hydrate_payment_intent_provider_references(
         %PaymentIntent{} = payment_intent,
         %CanonicalReceipt{} = canonical
       ) do
    attrs =
      %{
        provider: payment_intent.provider,
        provider_payment_id: canonical.provider_payment_id || payment_intent.provider_payment_id,
        provider_session_id: canonical.provider_session_id || payment_intent.provider_session_id,
        provider_customer_ref:
          canonical.provider_customer_ref || payment_intent.provider_customer_ref,
        provider_payment_method_ref:
          canonical.provider_payment_method_ref || payment_intent.provider_payment_method_ref,
        provider_client_secret: canonical.client_secret || payment_intent.provider_client_secret
      }

    if provider_reference_update_needed?(payment_intent, attrs) do
      payment_intent
      |> Ash.Changeset.for_update(:set_provider_reference, attrs, context: %{system?: true})
      |> Ash.update(payment_ash_opts([]))
    else
      {:ok, payment_intent}
    end
  end

  defp fallback_fetch_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    case fetch_payment_intent(payment_intent_id) do
      {:ok, %PaymentIntent{} = payment_intent} -> {:ok, payment_intent}
      {:discard, _reason} -> {:discard, "payment intent not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback_fetch_payment_intent(_payment_intent_id),
    do: {:discard, "payment intent not found"}

  defp fetch_payment_intent_if_present(payment_intent_id) when is_binary(payment_intent_id) do
    case fetch_payment_intent(payment_intent_id) do
      {:ok, payment_intent} -> {:ok, payment_intent}
      {:discard, _reason} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_if_present(_payment_intent_id), do: {:ok, nil}

  defp ensure_canonical_totals_match_order(%CanonicalReceipt{} = canonical, %Order{} = order) do
    order_amount = non_neg_int(order.grand_total_minor)
    order_currency = order.currency_code |> normalize_currency()
    receipt_currency = canonical.currency |> normalize_currency()

    cond do
      canonical.amount_minor != order_amount ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "receipt amount mismatch for finalized order totals"
         )}

      order_currency == nil or receipt_currency == nil ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "receipt/order currency must be present"
         )}

      order_currency != receipt_currency ->
        {:error, Error.new("CURRENCY_MISMATCH", "receipt currency does not match order totals")}

      true ->
        :ok
    end
  end

  defp ingest_provider_event(receipt, canonical) do
    with {:ok, provider} <- normalize_provider(canonical.provider || receipt.provider) do
      payload_hash = Idempotency.payload_hash(canonical.raw_payload)

      attrs = %{
        provider: provider,
        provider_event_id: canonical.provider_event_id,
        provider_event_key: Idempotency.provider_event_key(provider, canonical.provider_event_id),
        event_type: canonical.event_type,
        payload_sha256: payload_hash,
        received_at: receipt.received_at
      }

      ProviderEvent
      |> Ash.Changeset.for_create(:ingest, attrs, context: %{system?: true})
      |> Ash.create(payment_ash_opts([]))
      |> case do
        {:ok, event} -> {:ok, event.provider_event_key}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp record_payment_attempt(payment_intent, receipt, canonical) do
    with {:ok, provider} <- normalize_provider(canonical.provider || receipt.provider) do
      payload_hash =
        canonical.raw_payload
        |> Idempotency.payload_hash()

      observation = %ProviderObservation{
        provider: provider,
        provider_reference:
          canonical.provider_payment_id || canonical.provider_session_id ||
            canonical.provider_request_reference || "",
        provider_reference_kind: canonical_reference_kind(canonical),
        provider_transaction_id: canonical.provider_payment_id,
        local_payment_intent_id: payment_intent.id,
        observation_source: :webhook,
        normalized_outcome: webhook_observation_outcome(canonical.status),
        raw_provider_status: canonical.raw_provider_status || canonical.event_type,
        amount_minor: canonical.amount_minor,
        currency: canonical.currency,
        provider_environment: canonical.provider_environment,
        provider_occurred_at: canonical.occurred_at,
        observed_at: receipt.received_at,
        provider_customer_ref: canonical.provider_customer_ref,
        provider_payment_method_ref: canonical.provider_payment_method_ref,
        provider_event_id: canonical.provider_event_id,
        evidence_sha256: payload_hash,
        metadata: nil
      }

      with {:ok, attempt} <- ObservationEvidence.record(payment_intent, observation) do
        {:ok, attempt, observation}
      end
    end
  end

  defp canonical_reference_kind(%CanonicalReceipt{event_type: "setup_intent." <> _}),
    do: :setup_intent

  defp canonical_reference_kind(%CanonicalReceipt{provider_payment_id: payment_id})
       when is_binary(payment_id),
       do: :payment_intent

  defp canonical_reference_kind(%CanonicalReceipt{provider_session_id: session_id})
       when is_binary(session_id),
       do: :checkout_session

  defp canonical_reference_kind(%CanonicalReceipt{provider_request_reference: reference})
       when is_binary(reference),
       do: :transaction_reference

  defp canonical_reference_kind(_canonical), do: nil

  defp webhook_observation_outcome(:succeeded), do: :authoritative_success
  defp webhook_observation_outcome(:failed), do: :failure_observation
  defp webhook_observation_outcome(:requires_action), do: :requires_action
  defp webhook_observation_outcome(_), do: :unknown_or_contradictory

  defp apply_provider_observation(
         payment_intent,
         observation,
         provider_event_key,
         %PaymentAttempt{} = evidence
       ) do
    with :ok <- validate_observation_identity(payment_intent, observation),
         {:ok, provider_environment} <- Providers.expected_environment(payment_intent.provider),
         eligibility <- observation_eligibility(payment_intent, observation, provider_environment),
         finality <- Providers.classify_payment_finality(payment_intent.provider, observation),
         {:ok, application} <- fetch_payment_application(payment_intent),
         {:ok, evidence_history} <-
           fetch_payment_evidence_history(payment_intent, observation, provider_environment),
         {:ok, outcome} <-
           PaymentOutcomeResolver.resolve(payment_intent, observation,
             eligibility: eligibility,
             provider_finality: finality,
             payment_application: application,
             terminal_non_success_evidence?: evidence_history.terminal_non_success?,
             authoritative_success_evidence?: evidence_history.authoritative_success?,
             evidence_history_overflow?: evidence_history.overflow?
           ),
         {:ok, certified_payment_attempt_id} <-
           maybe_record_outcome_certification(
             payment_intent,
             observation,
             evidence,
             outcome
           ),
         {:ok, _result} <-
           apply_resolved_outcome(
             payment_intent,
             outcome,
             provider_event_key,
             certified_payment_attempt_id
           ),
         :ok <-
           maybe_record_non_success_collection_outcome(
             payment_intent,
             outcome,
             certified_payment_attempt_id
           ) do
      {:ok, outcome}
    end
  end

  defp observation_eligibility(
         %PaymentIntent{purpose: :subscription_payment_method_update} = payment_intent,
         %ProviderObservation{normalized_outcome: :authoritative_success} = observation,
         provider_environment
       ) do
    with :ok <- ProviderObservation.validate_identity(payment_intent, observation),
         true <- observation.provider_environment == provider_environment do
      :eligible
    else
      false -> {:error, :environment_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp observation_eligibility(
         %PaymentIntent{} = payment_intent,
         %ProviderObservation{normalized_outcome: :authoritative_success} = observation,
         provider_environment
       ) do
    ProviderObservation.validate_target(payment_intent, observation,
      provider_environment: provider_environment
    )
  end

  defp observation_eligibility(_payment_intent, _observation, _provider_environment),
    do: :not_applicable

  defp validate_observation_identity(payment_intent, observation) do
    case ProviderObservation.validate_identity(payment_intent, observation) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "provider observation identity does not match", %{
           reason: reason
         })}
    end
  end

  defp apply_resolved_outcome(
         payment_intent,
         :authoritative_success,
         _provider_event_key,
         payment_attempt_id
       ) do
    if payment_intent.purpose == :subscription_payment_method_update do
      with {:ok, _updated_intent, _notifications} <-
             maybe_mark_payment_intent_succeeded(payment_intent, true),
           :ok <-
             SubscriptionsFacade.handle_payment_method_update_succeeded_for_system(
               payment_intent.id
             ) do
        {:ok, :applied}
      end
    else
      apply_payment_success_once_internal(payment_intent, true, payment_attempt_id)
    end
  end

  defp apply_resolved_outcome(
         %PaymentIntent{order_id: order_id} = payment_intent,
         :already_applied_success,
         _provider_event_key,
         payment_attempt_id
       )
       when is_binary(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         result = %{applied?: false, order: order, payment_intent: payment_intent},
         renewal_attempt_lookup = renewal_attempt_for_payment_result(result),
         :ok <-
           maybe_record_renewal_collection_outcome(
             payment_intent,
             :already_applied_success,
             payment_attempt_id,
             renewal_attempt_lookup
           ),
         :ok <- maybe_enqueue_subscriptions(result, renewal_attempt_lookup) do
      {:ok, :already_applied_success}
    end
  end

  defp apply_resolved_outcome(
         _payment_intent,
         :already_applied_success,
         _provider_event_key,
         _payment_attempt_id
       ) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "applied payment has no Order identity")}
  end

  defp apply_resolved_outcome(
         %PaymentIntent{purpose: :subscription_payment_method_update} = payment_intent,
         :verified_terminal_non_success,
         _provider_event_key,
         _payment_attempt_id
       ),
       do: maybe_cancel_payment_intent(payment_intent)

  defp apply_resolved_outcome(
         payment_intent,
         :verified_terminal_non_success,
         _provider_event_key,
         payment_attempt_id
       ),
       do: apply_terminal_non_success(payment_intent, payment_attempt_id)

  defp apply_resolved_outcome(
         payment_intent,
         :requires_action,
         _provider_event_key,
         _payment_attempt_id
       ),
       do: maybe_mark_payment_intent_requires_action(payment_intent)

  defp apply_resolved_outcome(_payment_intent, outcome, _provider_event_key, _payment_attempt_id),
    do: {:ok, outcome}

  defp maybe_record_renewal_collection_outcome(payment_intent, outcome, payment_attempt_id) do
    maybe_record_renewal_collection_outcome(
      payment_intent,
      outcome,
      payment_attempt_id,
      :lookup_collection
    )
  end

  defp maybe_record_renewal_collection_outcome(
         payment_intent,
         outcome,
         payment_attempt_id,
         :lookup_collection
       ) do
    with outcome when not is_nil(outcome) <- collection_financial_outcome(outcome),
         true <- is_binary(payment_attempt_id),
         {:ok, %RenewalCollectionAttempt{} = collection} <-
           fetch_collection_for_payment_intent(payment_intent.id),
         {:ok, _updated} <-
           RenewalCollectionAttempts.record_financial_outcome_for_system(
             %RecordFinancialOutcomeInput{
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id,
               payment_attempt_id: payment_attempt_id,
               financial_outcome: outcome
             }
           ) do
      :ok
    else
      nil -> :ok
      false -> :ok
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_record_renewal_collection_outcome(
         payment_intent,
         outcome,
         payment_attempt_id,
         renewal_attempt_lookup
       ) do
    case collection_financial_outcome(outcome) do
      nil ->
        :ok

      financial_outcome ->
        maybe_record_collection_outcome_for_attempt(
          payment_intent,
          financial_outcome,
          payment_attempt_id,
          renewal_attempt_lookup
        )
    end
  end

  defp maybe_record_collection_outcome_for_attempt(
         _payment_intent,
         _outcome,
         _evidence_id,
         :none
       ),
       do: :ok

  defp maybe_record_collection_outcome_for_attempt(
         _payment_intent,
         _outcome,
         _evidence_id,
         {:ok, %{collection_attempt_id: nil}}
       ),
       do: :ok

  defp maybe_record_collection_outcome_for_attempt(
         %PaymentIntent{} = payment_intent,
         financial_outcome,
         payment_attempt_id,
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{} = attempt,
            collection_attempt_id: collection_attempt_id
          }}
       )
       when is_binary(collection_attempt_id) and is_binary(payment_attempt_id) do
    RenewalCollectionAttempts.record_financial_outcome_for_system(%RecordFinancialOutcomeInput{
      collection_attempt_id: collection_attempt_id,
      payment_intent_id: payment_intent.id,
      payment_attempt_id: payment_attempt_id,
      financial_outcome: financial_outcome,
      renewal_attempt_id: attempt.id,
      subscription_id: attempt.subscription_id
    })
    |> case do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_record_collection_outcome_for_attempt(
         _payment_intent,
         _financial_outcome,
         _payment_attempt_id,
         {:ok, %{collection_attempt_id: collection_attempt_id}}
       )
       when is_binary(collection_attempt_id) do
    :ok
  end

  defp maybe_record_collection_outcome_for_attempt(
         _payment_intent,
         _financial_outcome,
         _payment_attempt_id,
         {:error, reason}
       ),
       do: {:error, reason}

  defp maybe_record_collection_outcome_for_attempt(
         _payment_intent,
         _financial_outcome,
         _payment_attempt_id,
         _lookup
       ),
       do:
         {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal collection identity is invalid")}

  defp collection_financial_outcome(outcome) do
    case outcome do
      outcome
      when outcome in [:authoritative_success, :already_applied_success, :verified_success] ->
        :verified_success

      :requires_action ->
        :requires_action

      :verified_terminal_non_success ->
        :verified_terminal_financial_non_success

      :verified_terminal_financial_non_success ->
        :verified_terminal_financial_non_success

      _ ->
        nil
    end
  end

  defp maybe_record_non_success_collection_outcome(_payment_intent, outcome, _payment_attempt_id)
       when outcome in [:authoritative_success, :already_applied_success],
       do: :ok

  defp maybe_record_non_success_collection_outcome(payment_intent, outcome, payment_attempt_id),
    do: maybe_record_renewal_collection_outcome(payment_intent, outcome, payment_attempt_id)

  defp fetch_collection_for_payment_intent(payment_intent_id) do
    query =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent_id))
      |> Ash.Query.limit(1)

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [%RenewalCollectionAttempt{} = collection | _]} -> {:ok, collection}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_payment_application(%PaymentIntent{order_id: order_id}) when is_binary(order_id) do
    query = """
    SELECT order_id::text, payment_intent_id::text
    FROM payment_applications
    WHERE order_id = $1::text::uuid
    LIMIT 2
    """

    case SQL.query(Repo, query, [order_id]) do
      {:ok, %{rows: [[^order_id, payment_intent_id]]}} ->
        {:ok, %{order_id: order_id, payment_intent_id: payment_intent_id}}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[applied_order_id, payment_intent_id]]}} ->
        {:ok, %{order_id: applied_order_id, payment_intent_id: payment_intent_id}}

      {:ok, %{rows: [_first, _second]}} ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "order has conflicting payment applications")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_payment_application(_payment_intent), do: {:ok, nil}

  @payment_evidence_history_limit 100

  defp fetch_payment_evidence_history(
         %PaymentIntent{} = payment_intent,
         observation,
         provider_environment
       ) do
    query =
      PaymentAttempt
      |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
      |> Ash.Query.limit(@payment_evidence_history_limit + 1)

    case Ash.read(query,
           domain: Store.Payments,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, attempts} ->
        matching_observations =
          attempts
          |> Enum.filter(&same_provider_transaction?(&1, payment_intent, observation))
          |> Enum.map(&observation_from_payment_attempt/1)
          |> Enum.reject(&is_nil/1)

        observations = [observation | matching_observations]

        {:ok,
         %{
           terminal_non_success?:
             Enum.any?(observations, fn evidence ->
               Providers.classify_payment_finality(evidence.provider, evidence) ==
                 :terminal_non_success
             end),
           authoritative_success?:
             Enum.any?(observations, fn evidence ->
               Providers.classify_payment_finality(evidence.provider, evidence) ==
                 :authoritative_success and
                 ProviderObservation.validate_target(payment_intent, evidence,
                   provider_environment: provider_environment
                 ) == :eligible
             end),
           overflow?: length(attempts) > @payment_evidence_history_limit
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_provider_transaction?(attempt, payment_intent, observation) do
    attempt.payment_intent_id == payment_intent.id and
      attempt.provider == observation.provider and
      attempt.provider_reference == observation.provider_reference and
      attempt.provider_reference_kind == Atom.to_string(observation.provider_reference_kind) and
      attempt.provider_transaction_id == observation.provider_transaction_id
  end

  defp observation_from_payment_attempt(%PaymentAttempt{} = attempt) do
    with {:ok, outcome} <- observation_outcome(attempt.outcome),
         {:ok, source} <- observation_source(attempt.observation_source),
         {:ok, reference_kind} <- observation_reference_kind(attempt.provider_reference_kind),
         true <- is_binary(attempt.provider_reference),
         true <- is_binary(attempt.raw_provider_status),
         true <- not is_nil(attempt.observed_at) do
      %ProviderObservation{
        provider: attempt.provider,
        provider_reference: attempt.provider_reference,
        provider_reference_kind: reference_kind,
        provider_transaction_id: attempt.provider_transaction_id,
        local_payment_intent_id: attempt.payment_intent_id,
        observation_source: source,
        normalized_outcome: outcome,
        raw_provider_status: attempt.raw_provider_status,
        amount_minor: attempt.amount_minor,
        currency: attempt.currency,
        provider_environment: attempt.provider_environment,
        provider_occurred_at: attempt.provider_occurred_at,
        observed_at: attempt.observed_at,
        provider_event_id: attempt.provider_event_id
      }
    else
      _ -> nil
    end
  end

  defp observation_outcome(value) do
    case value do
      "unresolved" -> {:ok, :unresolved}
      "requires_action" -> {:ok, :requires_action}
      "failure_observation" -> {:ok, :failure_observation}
      "authoritative_success" -> {:ok, :authoritative_success}
      "reversal_observation" -> {:ok, :reversal_observation}
      "unknown_or_contradictory" -> {:ok, :unknown_or_contradictory}
      _ -> :error
    end
  end

  defp observation_source(value) do
    case value do
      "direct_response" -> {:ok, :direct_response}
      "webhook" -> {:ok, :webhook}
      "verification" -> {:ok, :verification}
      "reconciliation" -> {:ok, :reconciliation}
      "operator" -> {:ok, :operator}
      _ -> :error
    end
  end

  defp observation_reference_kind("payment_intent"), do: {:ok, :payment_intent}
  defp observation_reference_kind("checkout_session"), do: {:ok, :checkout_session}
  defp observation_reference_kind("setup_intent"), do: {:ok, :setup_intent}
  defp observation_reference_kind("transaction_reference"), do: {:ok, :transaction_reference}
  defp observation_reference_kind(_value), do: :error

  defp fetch_payment_attempt(id) do
    query = PaymentAttempt |> Ash.Query.filter(expr(id == ^id))

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [%PaymentAttempt{} = attempt]} ->
        {:ok, attempt}

      {:ok, _} ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "payment evidence was not found")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_persisted_evidence(payment_intent, observation, evidence) do
    reference_kind =
      case observation.provider_reference_kind do
        kind when is_atom(kind) -> Atom.to_string(kind)
        _ -> nil
      end

    fields = [
      payment_intent_id: {evidence.payment_intent_id, payment_intent.id},
      provider: {evidence.provider, Providers.normalize_provider(observation.provider)},
      provider_reference: {evidence.provider_reference, observation.provider_reference},
      provider_reference_kind: {evidence.provider_reference_kind, reference_kind},
      provider_transaction_id:
        {evidence.provider_transaction_id, observation.provider_transaction_id},
      observation_source:
        {evidence.observation_source, Atom.to_string(observation.observation_source)},
      outcome: {evidence.outcome, Atom.to_string(observation.normalized_outcome)},
      raw_provider_status: {evidence.raw_provider_status, observation.raw_provider_status},
      amount_minor: {evidence.amount_minor, observation.amount_minor},
      currency: {evidence.currency, observation.currency},
      provider_environment: {evidence.provider_environment, observation.provider_environment},
      provider_occurred_at:
        {date_time_identity(evidence.provider_occurred_at),
         date_time_identity(observation.provider_occurred_at)},
      payload_sha256: {evidence.payload_sha256, observation.evidence_sha256},
      provider_event_id: {evidence.provider_event_id, observation.provider_event_id}
    ]

    mismatches =
      fields
      |> Enum.reject(fn {_field, {stored, supplied}} -> stored == supplied end)
      |> Enum.map(&elem(&1, 0))

    if mismatches == [] do
      :ok
    else
      {:error,
       Error.new("PAYMENT_EVENT_UNVERIFIED", "payment evidence does not match observation", %{
         mismatched_fields: mismatches
       })}
    end
  end

  defp date_time_identity(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp date_time_identity(value), do: value

  defp apply_terminal_non_success(
         %PaymentIntent{order_id: order_id} = payment_intent,
         payment_attempt_id
       )
       when is_binary(order_id) do
    with {:ok, _order} <- fetch_order(order_id),
         {:ok,
          %{
            outcome: outcome,
            inventory_variant_ids_to_invalidate: inventory_variant_ids
          }, notifications} <-
           Repo.transaction(fn ->
             lock_order!(order_id)
             lock_payment_intent!(payment_intent.id)
             apply_terminal_non_success_in_transaction(payment_intent, payment_attempt_id)
           end)
           |> normalize_transaction_result(),
         :ok <- Store.Orders.invalidate_inventory_availability_for_variants(inventory_variant_ids),
         :ok <-
           AshNotifications.notify_post_commit(notifications,
             context: %{
               flow: :apply_terminal_payment_failure,
               order_id: order_id,
               payment_intent_id: payment_intent.id
             }
           ) do
      {:ok, outcome}
    end
  end

  defp apply_terminal_non_success(_payment_intent, _payment_attempt_id),
    do: {:ok, :verified_terminal_non_success}

  defp apply_terminal_non_success_in_transaction(payment_intent, payment_attempt_id) do
    with {:ok, current_intent} <- fetch_payment_intent(payment_intent.id),
         {:ok, current_order} <- fetch_order(payment_intent.order_id),
         {:ok, renewal_attempt_lookup} <-
           renewal_attempt_lookup_for_payment_application(current_order, current_intent),
         {:ok, certified_payment_attempt_id} <-
           ensure_renewal_collection_outcome_certification(
             renewal_attempt_lookup,
             current_intent,
             payment_attempt_id,
             :verified_terminal_financial_non_success
           ) do
      case fetch_payment_application(current_intent) do
        {:ok, %{payment_intent_id: id}} when id == current_intent.id ->
          {:ok,
           %{
             outcome: :already_applied_success,
             inventory_variant_ids_to_invalidate: []
           }, []}

        {:ok, %{payment_intent_id: _other_id}} ->
          Repo.rollback(Error.new("PAYMENT_EVENT_UNVERIFIED", "order payment identity conflicts"))

        {:ok, nil} ->
          apply_terminal_failure_without_payment_application(
            current_intent,
            certified_payment_attempt_id
          )

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_terminal_failure_without_payment_application(
         payment_intent,
         payment_attempt_id
       ) do
    with {:ok, current} <- fetch_payment_intent(payment_intent.id),
         {:ok, {_marked, notifications}} <- maybe_mark_payment_intent_failed(current),
         {:ok, inventory_variant_ids} <-
           maybe_release_failed_renewal_reservations(current, payment_attempt_id) do
      {:ok,
       %{
         outcome: :verified_terminal_non_success,
         inventory_variant_ids_to_invalidate: inventory_variant_ids
       }, notifications}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_order!(order_id) do
    case SQL.query(Repo, "SELECT id FROM orders WHERE id = $1::text::uuid FOR UPDATE", [order_id]) do
      {:ok, %{rows: [[_id]]}} -> :ok
      _ -> Repo.rollback(Error.new("ORDER_NOT_FOUND", "order not found for payment intent"))
    end
  end

  defp lock_payment_intent!(payment_intent_id) do
    case SQL.query(Repo, "SELECT id FROM payment_intents WHERE id = $1::text::uuid FOR UPDATE", [
           payment_intent_id
         ]) do
      {:ok, %{rows: [[_id]]}} -> :ok
      _ -> Repo.rollback(Error.new("PAYMENT_EVENT_UNVERIFIED", "payment intent was not found"))
    end
  end

  defp run_apply_payment_success_once(
         payment_intent,
         order,
         verified_correction?,
         payment_attempt_id
       ) do
    lock_order!(order.id)
    lock_payment_intent!(payment_intent.id)

    with {:ok, current_intent} <- fetch_payment_intent(payment_intent.id),
         {:ok, current_order} <- fetch_order(order.id),
         {:ok, existing_application} <- fetch_payment_application(current_intent),
         :ok <- ensure_payment_application_identity(existing_application, current_intent),
         {:ok, renewal_attempt_lookup} <-
           renewal_attempt_lookup_for_payment_application(current_order, current_intent),
         {:ok, certified_payment_attempt_id} <-
           ensure_renewal_collection_outcome_certification(
             renewal_attempt_lookup,
             current_intent,
             payment_attempt_id,
             :verified_success
           ),
         {:ok, status} <-
           insert_payment_application(
             current_order.id,
             current_intent.id,
             "paid_apply:order:#{current_order.id}"
           ),
         {:ok, updated_intent, intent_notifications} <-
           maybe_mark_payment_intent_succeeded(current_intent, verified_correction?),
         {:ok, updated_order, order_notifications} <- maybe_mark_order_paid(current_order, status),
         {:ok, settlement_result} <-
           settle_payment_order_reservations(
             current_order,
             current_intent,
             renewal_attempt_lookup,
             certified_payment_attempt_id
           ),
         result = apply_once_result(status, updated_order, updated_intent),
         :ok <- maybe_enqueue_digital_grants(result, renewal_attempt_lookup) do
      notifications = intent_notifications ++ order_notifications

      {:ok,
       %{
         result: result,
         renewal_attempt_lookup: renewal_attempt_lookup,
         inventory_variant_ids_to_invalidate:
           Map.get(settlement_result, :inventory_variant_ids_to_invalidate, [])
       }, notifications}
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, other} -> Repo.rollback(other)
    end
  end

  defp ensure_payment_application_identity(nil, _payment_intent), do: :ok

  defp ensure_payment_application_identity(
         %{payment_intent_id: payment_intent_id},
         %PaymentIntent{id: payment_intent_id}
       ),
       do: :ok

  defp ensure_payment_application_identity(_application, _payment_intent) do
    {:error,
     Error.new("PAYMENT_EVENT_UNVERIFIED", "order already has a different payment application")}
  end

  defp insert_payment_application(order_id, payment_intent_id, application_key) do
    query = """
    INSERT INTO payment_applications (
      id, order_id, payment_intent_id, application_key, applied_at, inserted_at, updated_at
    )
    VALUES (
      uuid_generate_v7(), $1::text::uuid, $2::text::uuid, $3, (now() AT TIME ZONE 'utc'),
      (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
    )
    ON CONFLICT (application_key) DO NOTHING
    RETURNING id::text
    """

    case SQL.query(Repo, query, [order_id, payment_intent_id, application_key]) do
      {:ok, %{rows: [[_id]]}} ->
        {:ok, :inserted}

      {:ok, %{rows: []}} ->
        confirm_existing_payment_application(order_id, payment_intent_id, application_key)

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to record payment application")}
    end
  end

  defp confirm_existing_payment_application(order_id, payment_intent_id, application_key) do
    query = """
    SELECT order_id::text, payment_intent_id::text
    FROM payment_applications
    WHERE application_key = $1
    LIMIT 1
    """

    case SQL.query(Repo, query, [application_key]) do
      {:ok, %{rows: [[^order_id, ^payment_intent_id]]}} ->
        {:ok, :exists}

      {:ok, %{rows: [[_order_id, _other_payment_intent_id]]}} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "order already has a different payment application"
         )}

      {:ok, %{rows: []}} ->
        {:error,
         Error.new("INTERNAL_ERROR", "payment application conflict could not be resolved")}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to verify existing payment application")}
    end
  end

  defp apply_once_result(:inserted, order, payment_intent) do
    %{applied?: true, order: order, payment_intent: payment_intent}
  end

  defp apply_once_result(:exists, order, payment_intent) do
    %{applied?: false, order: order, payment_intent: payment_intent}
  end

  defp maybe_mark_payment_intent_succeeded(
         %PaymentIntent{state: :succeeded} = payment_intent,
         _verified_correction?
       ),
       do: {:ok, payment_intent, []}

  defp maybe_mark_payment_intent_succeeded(
         %PaymentIntent{state: state} = payment_intent,
         _verified_correction?
       )
       when state in [:submitted, :requires_action],
       do: mark_payment_intent_succeeded(payment_intent, :mark_succeeded)

  defp maybe_mark_payment_intent_succeeded(
         %PaymentIntent{
           state: :created,
           provider: :paystack,
           purpose: :order_checkout,
           provider_request_reference: reference
         } = payment_intent,
         true
       )
       when is_binary(reference) and reference != "",
       do: mark_payment_intent_succeeded(payment_intent, :recover_verified_paystack_checkout)

  defp maybe_mark_payment_intent_succeeded(
         %PaymentIntent{state: :failed} = payment_intent,
         true
       ),
       do: mark_payment_intent_succeeded(payment_intent, :correct_to_succeeded)

  defp maybe_mark_payment_intent_succeeded(_payment_intent, _verified_correction?) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent is not in a success-transitionable state"
     )}
  end

  defp mark_payment_intent_succeeded(payment_intent, action) do
    payment_intent
    |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts(return_notifications?: true))
  end

  defp maybe_mark_payment_intent_failed(%PaymentIntent{state: :failed}),
    do: {:ok, {:noop, []}}

  defp maybe_mark_payment_intent_failed(%PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action] do
    payment_intent
    |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts(return_notifications?: true))
    |> case do
      {:ok, updated_intent, notifications} -> {:ok, {updated_intent, notifications}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_payment_intent_failed(%PaymentIntent{}), do: {:ok, {:noop, []}}

  defp maybe_cancel_payment_intent(%PaymentIntent{state: :cancelled}), do: {:ok, :noop}

  defp maybe_cancel_payment_intent(%PaymentIntent{state: state} = payment_intent)
       when state in [:created, :submitted, :requires_action] do
    payment_intent
    |> Ash.Changeset.for_update(:cancel, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts([]))
    |> case do
      {:ok, _updated_intent} -> {:ok, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_cancel_payment_intent(%PaymentIntent{}), do: {:ok, :noop}

  defp maybe_mark_payment_intent_requires_action(%PaymentIntent{state: :requires_action}),
    do: {:ok, :noop}

  defp maybe_mark_payment_intent_requires_action(
         %PaymentIntent{state: :submitted} = payment_intent
       ) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_requires_action, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts([]))
    |> case do
      {:ok, _updated_intent} -> {:ok, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_payment_intent_requires_action(%PaymentIntent{}), do: {:ok, :noop}

  defp maybe_release_failed_renewal_reservations(
         %PaymentIntent{order_id: order_id} = payment_intent,
         payment_attempt_id
       )
       when is_binary(order_id) do
    if renewal_order?(order_id) do
      with {:ok, %{reservations: reservations}} <-
             Store.Orders.release_reservations_for_order(order_id,
               context: %{system?: true},
               invalidate?: false
             ),
           {:ok, exact_collection_variants} <-
             release_terminal_collection_reservation_for_payment_application(
               payment_intent,
               payment_attempt_id
             ) do
        {:ok,
         Enum.map(reservations, & &1.variant_id)
         |> Kernel.++(exact_collection_variants)
         |> Enum.uniq()}
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, other} -> {:error, other}
      end
    else
      {:ok, []}
    end
  end

  defp maybe_release_failed_renewal_reservations(%PaymentIntent{}, _payment_attempt_id),
    do: {:ok, []}

  defp release_terminal_collection_reservation_for_payment_application(
         %PaymentIntent{} = payment_intent,
         payment_attempt_id
       ) do
    with {:ok, order} <- fetch_order(payment_intent.order_id) do
      release_collection_reservation_for_payment(order, payment_intent, payment_attempt_id)
    end
  end

  defp release_collection_reservation_for_payment(order, payment_intent, payment_attempt_id) do
    case renewal_attempt_for_payment_result(%{order: order, payment_intent: payment_intent}) do
      {:ok,
       %{
         renewal_attempt: %RenewalAttempt{} = attempt,
         collection_attempt_id: collection_attempt_id,
         payment_intent_id: payment_intent_id
       }}
      when is_binary(collection_attempt_id) ->
        release_collection_reservation(
          order,
          attempt,
          collection_attempt_id,
          payment_intent_id,
          payment_attempt_id
        )

      {:ok, %{collection_attempt_id: nil}} ->
        {:ok, []}

      :none ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_collection_reservation(
         order,
         attempt,
         collection_attempt_id,
         payment_intent_id,
         payment_attempt_id
       ) do
    input = %PaymentApplicationSettlementInput{
      collection_attempt_id: collection_attempt_id,
      order_id: order.id,
      renewal_attempt_id: attempt.id,
      payment_intent_id: payment_intent_id,
      payment_attempt_id: payment_attempt_id
    }

    case RenewalCollectionAttempts.release_terminal_collection_reservation_for_payment_application(
           input
         ) do
      {:ok, result} -> {:ok, Map.get(result, :inventory_variant_ids_to_invalidate, [])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_order_paid(%Order{state: :paid} = order, _application_status),
    do: {:ok, order, []}

  defp maybe_mark_order_paid(%Order{state: :refunded} = order, :exists),
    do: {:ok, order, []}

  defp maybe_mark_order_paid(%Order{state: state} = order, _application_status)
       when state in [:pending_payment, :pending_provider_setup] do
    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update(order_ash_opts(return_notifications?: true))
    |> case do
      {:ok, updated_order, notifications} -> {:ok, updated_order, notifications}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_order_paid(_order, _application_status) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "order is not in a payable state")}
  end

  defp renewal_order?(order_id) when is_binary(order_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, order_ash_opts([])) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found for payment intent")}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_canonical_receipt_target(
         %PaymentIntent{purpose: :subscription_payment_method_update},
         %CanonicalReceipt{}
       ),
       do: :ok

  defp validate_canonical_receipt_target(
         %PaymentIntent{} = payment_intent,
         %CanonicalReceipt{} = canonical
       ) do
    with {:ok, order} <- fetch_order(payment_intent.order_id) do
      ensure_canonical_totals_match_order(canonical, order)
    end
  end

  defp fetch_payment_intent(payment_intent_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:discard, "payment intent not found"}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_enqueue_order_receipt(%{applied?: true, order: %Order{} = order}) do
    case Store.Comms.enqueue_order_receipt_for_system(order.id) do
      {:ok, _outbox} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "order_receipt_enqueue_failed order_id=#{order.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_order_receipt(_result), do: :ok

  defp maybe_enqueue_fulfillment(%{order: %Order{billing_country_code: country}})
       when is_binary(country),
       do: :ok

  defp maybe_enqueue_fulfillment(%{applied?: true, order: %Order{} = order}) do
    case SubscriptionsFacade.order_is_subscription_only_for_system(order.id) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        case FulfillmentFacade.enqueue_paid_order_fulfillment_for_system(order.id) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ensure_fulfillment_enqueue_failed order_id=#{order.id} reason=#{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "ensure_fulfillment_precheck_failed order_id=#{order.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_fulfillment(_result), do: :ok

  defp maybe_enqueue_digital_grants(
         %{applied?: true, order: %Order{}},
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{failure_code: "RENEWAL_AUTHORITY_WITHDRAWN"}
          }}
       ) do
    :ok
  end

  defp maybe_enqueue_digital_grants(
         %{applied?: true},
         {:ok, %{renewal_attempt: %RenewalAttempt{}}}
       ) do
    :ok
  end

  defp maybe_enqueue_digital_grants(%{applied?: true, order: %Order{} = order}, :none) do
    case DigitalFacade.enqueue_paid_order_download_grants_for_system(order.id) do
      {:ok, _job} ->
        :ok

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to queue paid order download grants")}
    end
  end

  defp maybe_enqueue_digital_grants(
         %{applied?: true, order: %Order{} = order},
         {:error, reason}
       ) do
    Logger.warning(
      "issue_digital_grants_suppressed_unverified_renewal order_id=#{order.id} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp maybe_enqueue_digital_grants(_result, _renewal_attempt_lookup), do: :ok

  defp maybe_enqueue_subscriptions(
         %{order: %Order{} = order},
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{} = renewal_attempt,
            collection_attempt_id: collection_attempt_id,
            payment_intent_id: payment_intent_id
          }}
       ) do
    case collection_attempt_id do
      id when is_binary(id) ->
        with {:ok, %{handoff: handoff, reconciliation: disposition}} <-
               RenewalCollectionAttempts.success_handoff_context_for_system(id),
             true <-
               handoff.order_id == order.id and
                 handoff.renewal_attempt_id == renewal_attempt.id and
                 handoff.payment_intent_id == payment_intent_id do
          maybe_enqueue_renewal_recovery_reconciliation(handoff, disposition)
        else
          false ->
            {:error,
             Error.new("PAYMENT_EVENT_UNVERIFIED", "exact renewal collection handoff conflicts")}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "renewal success has no exact collection identity"
         )}
    end
  end

  defp maybe_enqueue_subscriptions(%{applied?: true, order: %Order{} = order}, :none) do
    maybe_enqueue_initial_subscriptions(order)
  end

  defp maybe_enqueue_subscriptions(
         %{order: %Order{} = order},
         {:error, reason}
       ) do
    Logger.warning(
      "renewal_reconciliation_precheck_failed order_id=#{order.id} reason=#{inspect(reason)}"
    )

    {:error, reason}
  end

  defp maybe_enqueue_subscriptions(_result, _renewal_attempt_lookup), do: :ok

  defp maybe_enqueue_renewal_recovery_reconciliation(_handoff, :handoff_only), do: :ok

  defp maybe_enqueue_renewal_recovery_reconciliation(handoff, :recovery_required),
    do: enqueue_renewal_reconciliation_job(handoff)

  defp renewal_attempt_for_payment_result(%{
         order: %Order{id: order_id},
         payment_intent: %PaymentIntent{id: payment_intent_id}
       }) do
    with {:ok, renewal_attempt} <- fetch_renewal_attempt_by_order_id(order_id),
         {:ok, collection} <- fetch_collection_for_payment_intent(payment_intent_id) do
      resolve_renewal_payment_identity(renewal_attempt, collection, order_id, payment_intent_id)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp renewal_attempt_for_payment_result(_result), do: :none

  defp resolve_renewal_payment_identity(nil, nil, _order_id, _payment_intent_id), do: :none

  defp resolve_renewal_payment_identity(
         %RenewalAttempt{order_id: order_id, payment_intent_id: payment_intent_id} = attempt,
         nil,
         order_id,
         payment_intent_id
       ),
       do: legacy_renewal_payment_identity(attempt, payment_intent_id)

  defp resolve_renewal_payment_identity(
         %RenewalAttempt{id: attempt_id, order_id: order_id} = attempt,
         %RenewalCollectionAttempt{
           renewal_attempt_id: attempt_id,
           payment_intent_id: payment_intent_id
         } = collection,
         order_id,
         payment_intent_id
       ) do
    {:ok,
     %{
       renewal_attempt: attempt,
       collection_attempt_id: collection.id,
       payment_intent_id: payment_intent_id,
       payment_attempt_id: collection.payment_attempt_id
     }}
  end

  defp resolve_renewal_payment_identity(_attempt, _collection, _order_id, _payment_intent_id) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal payment identity conflicts")}
  end

  defp legacy_renewal_payment_identity(attempt, payment_intent_id) do
    case fetch_collection_for_renewal_attempt(attempt.id) do
      {:ok, nil} ->
        {:ok,
         %{
           renewal_attempt: attempt,
           collection_attempt_id: nil,
           payment_intent_id: payment_intent_id
         }}

      {:ok, %RenewalCollectionAttempt{}} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "renewal PaymentIntent has no exact collection identity"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_collection_for_renewal_attempt(renewal_attempt_id) do
    query =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
      |> Ash.Query.limit(1)

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [%RenewalCollectionAttempt{} = collection | _]} -> {:ok, collection}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp renewal_attempt_lookup_for_payment_application(order, payment_intent) do
    {:ok, renewal_attempt_for_payment_result(%{order: order, payment_intent: payment_intent})}
  end

  defp ensure_renewal_collection_outcome_certification(
         :none,
         _payment_intent,
         _payment_attempt_id,
         _financial_outcome
       ),
       do: {:ok, nil}

  defp ensure_renewal_collection_outcome_certification(
         {:ok, %{collection_attempt_id: nil}},
         _payment_intent,
         _payment_attempt_id,
         _financial_outcome
       ),
       do: {:ok, nil}

  defp ensure_renewal_collection_outcome_certification(
         {:ok,
          %{
            collection_attempt_id: collection_attempt_id,
            payment_intent_id: payment_intent_id
          } = renewal_identity},
         %PaymentIntent{id: payment_intent_id},
         payment_attempt_id,
         financial_outcome
       )
       when is_binary(collection_attempt_id) do
    payment_attempt_id = payment_attempt_id || Map.get(renewal_identity, :payment_attempt_id)

    with true <- is_binary(payment_attempt_id),
         {:ok, _uuid} <- Ecto.UUID.cast(payment_attempt_id),
         {:ok, input} <-
           ValidateRenewalCollectionOutcomeInput.new(%{
             payment_attempt_id: payment_attempt_id,
             payment_intent_id: payment_intent_id,
             financial_outcome: financial_outcome
           }),
         :ok <- Store.Payments.validate_collection_outcome_certification_for_system(input) do
      {:ok, payment_attempt_id}
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "exact renewal collection has no certified provider evidence"
         )}

      :error ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "exact renewal collection provider evidence identity is invalid"
         )}

      {:error, %Error{code: "VALIDATION_ERROR"}} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "exact renewal collection provider evidence identity is invalid"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_renewal_collection_outcome_certification(
         {:ok, %{collection_attempt_id: collection_attempt_id}},
         _payment_intent,
         _payment_attempt_id,
         _financial_outcome
       )
       when is_binary(collection_attempt_id) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "exact renewal collection PaymentIntent identity conflicts"
     )}
  end

  defp ensure_renewal_collection_outcome_certification(
         {:error, reason},
         _payment_intent,
         _payment_attempt_id,
         _financial_outcome
       ),
       do: {:error, reason}

  defp ensure_renewal_collection_outcome_certification(
         _renewal_attempt_lookup,
         _payment_intent,
         _payment_attempt_id,
         _financial_outcome
       ) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal payment identity conflicts")}
  end

  defp settle_payment_order_reservations(
         %Order{id: order_id},
         %PaymentIntent{id: payment_intent_id},
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{
              id: renewal_attempt_id,
              order_id: order_id,
              failure_code: "RENEWAL_AUTHORITY_WITHDRAWN"
            },
            collection_attempt_id: collection_attempt_id,
            payment_intent_id: payment_intent_id
          }},
         payment_attempt_id
       )
       when is_binary(collection_attempt_id) do
    input = %PaymentApplicationSettlementInput{
      collection_attempt_id: collection_attempt_id,
      order_id: order_id,
      renewal_attempt_id: renewal_attempt_id,
      payment_intent_id: payment_intent_id,
      payment_attempt_id: payment_attempt_id
    }

    with {:ok, settlement} <-
           RenewalCollectionAttempts.release_withdrawn_collection_reservation_for_payment_application(
             input
           ),
         {:ok, withdrawn_settlement} <-
           Store.Orders.settle_withdrawn_renewal_reservations_for_payment(order_id) do
      {:ok,
       Map.put(
         withdrawn_settlement,
         :inventory_variant_ids_to_invalidate,
         Map.get(settlement, :inventory_variant_ids_to_invalidate, [])
       )}
    end
  end

  defp settle_payment_order_reservations(
         %Order{id: order_id},
         %PaymentIntent{id: payment_intent_id},
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{id: renewal_attempt_id, order_id: order_id},
            collection_attempt_id: collection_attempt_id,
            payment_intent_id: payment_intent_id
          }},
         payment_attempt_id
       )
       when is_binary(collection_attempt_id) do
    RenewalCollectionAttempts.settle_successful_collection_reservation_for_payment_application(
      %PaymentApplicationSettlementInput{
        collection_attempt_id: collection_attempt_id,
        order_id: order_id,
        renewal_attempt_id: renewal_attempt_id,
        payment_intent_id: payment_intent_id,
        payment_attempt_id: payment_attempt_id
      }
    )
  end

  defp settle_payment_order_reservations(
         %Order{id: order_id},
         %PaymentIntent{id: payment_intent_id},
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{
              order_id: order_id,
              failure_code: "RENEWAL_AUTHORITY_WITHDRAWN"
            },
            payment_intent_id: payment_intent_id
          }},
         _payment_attempt_id
       ) do
    Store.Orders.settle_withdrawn_renewal_reservations_for_payment(order_id)
  end

  defp settle_payment_order_reservations(
         %Order{id: order_id},
         %PaymentIntent{id: payment_intent_id},
         {:ok,
          %{
            renewal_attempt: %RenewalAttempt{order_id: order_id},
            payment_intent_id: payment_intent_id
          }},
         _payment_attempt_id
       ) do
    Store.Orders.consume_reservations_for_order(order_id, context: %{system?: true})
  end

  defp settle_payment_order_reservations(
         %Order{id: order_id},
         %PaymentIntent{},
         :none,
         _payment_attempt_id
       ) do
    Store.Orders.consume_reservations_for_order(order_id, context: %{system?: true})
  end

  defp settle_payment_order_reservations(
         _order,
         _payment_intent,
         {:error, identity_error},
         _payment_attempt_id
       ) do
    {:error, identity_error}
  end

  defp settle_payment_order_reservations(
         _order,
         _payment_intent,
         _renewal_attempt_lookup,
         _payment_attempt_id
       ) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal payment identity conflicts")}
  end

  defp maybe_enqueue_initial_subscriptions(%Order{} = order) do
    case SubscriptionsFacade.order_has_subscription_lines_for_system(order.id) do
      {:ok, true} -> enqueue_initial_subscription_job(order)
      {:ok, false} -> :ok
      {:error, reason} -> log_subscription_precheck_failure(order.id, reason)
    end
  end

  defp enqueue_initial_subscription_job(%Order{} = order) do
    %{"order_id" => order.id}
    |> EnsureSubscriptionsForPaidOrderWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> log_subscription_enqueue_failure(order.id, reason)
    end
  end

  defp log_subscription_precheck_failure(order_id, reason) do
    Logger.warning(
      "ensure_subscriptions_precheck_failed order_id=#{order_id} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp log_subscription_enqueue_failure(order_id, reason) do
    Logger.warning(
      "ensure_subscriptions_enqueue_failed order_id=#{order_id} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp fetch_renewal_attempt_by_order_id(order_id) when is_binary(order_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.limit(2)

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [renewal_attempt]} ->
        {:ok, renewal_attempt}

      {:ok, []} ->
        {:ok, nil}

      {:ok, [_first, _second | _rest]} ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "multiple renewal attempts match Order")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_renewal_reconciliation_job(%{
         order_id: order_id,
         renewal_attempt_id: renewal_attempt_id,
         collection_attempt_id: collection_attempt_id,
         payment_intent_id: payment_intent_id
       }) do
    %{
      "order_id" => order_id,
      "renewal_attempt_id" => renewal_attempt_id,
      "collection_attempt_id" => collection_attempt_id,
      "payment_intent_id" => payment_intent_id
    }
    |> ReconcilePaidSubscriptionRenewalWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "renewal_reconciliation_enqueue_failed order_id=#{order_id} reason=#{inspect(reason)}"
        )

        {:error,
         Error.new("INTERNAL_ERROR", "renewal reconciliation could not be queued", %{
           reason: inspect(reason)
         })}
    end
  end

  defp normalize_transaction_result({:ok, {:ok, result, notifications}})
       when is_list(notifications),
       do: {:ok, result, notifications}

  defp normalize_transaction_result({:ok, other}) do
    {:error,
     Error.new("INTERNAL_ERROR", "invalid transaction result shape", %{
       result: inspect(other)
     })}
  end

  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp payment_ash_opts(opts) do
    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.put_new(:system?, true)

    opts
    |> Keyword.put(:domain, Store.Payments)
    |> Keyword.put(:authorize?, false)
    |> Keyword.put(:context, context)
  end

  defp order_ash_opts(opts) do
    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.put_new(:system?, true)

    opts
    |> Keyword.put(:domain, Store.Orders)
    |> Keyword.put(:authorize?, false)
    |> Keyword.put(:context, context)
  end

  defp require_binary(value, _message) when is_binary(value), do: :ok
  defp require_binary(_value, message), do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp optional_binary(nil, _field), do: :ok

  defp optional_binary(value, _field) when is_binary(value) and value != "", do: :ok

  defp optional_binary(_value, field) do
    {:error, Error.new("VALIDATION_ERROR", "#{field} must be a non-empty string when provided")}
  end

  defp require_non_negative_integer(value, _message) when is_integer(value) and value >= 0,
    do: :ok

  defp require_non_negative_integer(_value, message),
    do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp normalize_provider(nil) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_SELECTION_REQUIRED",
       "payment provider selection is required"
     )}
  end

  defp normalize_provider(provider_input) do
    case Providers.normalize_provider(provider_input) do
      :unknown ->
        {:error, Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is unsupported")}

      known ->
        if Providers.known_provider?(known) do
          {:ok, known}
        else
          {:error, Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is unsupported")}
        end
    end
  end

  defp normalize_currency(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_currency(_), do: nil

  defp non_neg_int(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_), do: 0

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp provider_reference_update_needed?(payment_intent, attrs) do
    Enum.any?(
      [
        :provider_payment_id,
        :provider_session_id,
        :provider_customer_ref,
        :provider_payment_method_ref,
        :provider_client_secret
      ],
      fn key ->
        Map.get(attrs, key) != nil and Map.get(payment_intent, key) != Map.get(attrs, key)
      end
    )
  end
end
