defmodule Store.Payments do
  @moduledoc """
  Payments domain for payment lifecycle, provider events, and refunds.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Checkout
  alias Store.Digital.Facade, as: DigitalFacade
  alias Store.Orders.Order
  alias Store.Orders.OrderLineItem
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput

  alias Store.Payments.{
    Interlocks,
    ObservationEvidence,
    PaymentIntent,
    Providers,
    ProviderTask,
    Refunds
  }

  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.Telemetry.RepoStats

  @recoverable_pending_provider_intent_states [:created, :submitted, :requires_action, :succeeded]

  resources do
    resource(Store.Payments.PaymentIntent)
    resource(Store.Payments.PaymentAttempt)
    resource(Store.Payments.PaymentOutcomeCertification)
    resource(Store.Payments.ProviderEvent)
    resource(Store.Payments.Refund)
    resource(Store.Payments.RefundAttempt)
    resource(Store.Payments.WebhookReceipt)
  end

  json_api do
    prefix("/api/v1")
    show_raised_errors?(false)

    routes do
      base_route("/admin/payment-intents", Store.Payments.PaymentIntent) do
        index(:read_for_admin, derive_filter?: false, derive_sort?: false)
        get(:get_for_admin, derive_filter?: false, derive_sort?: false)
      end
    end
  end

  @spec request_refund(map(), keyword()) :: {:ok, Store.Payments.Refund.t()} | {:error, term()}
  def request_refund(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Refunds.request_refund(attrs, opts)
  end

  @spec process_refund_webhook_receipt(Store.Payments.WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt(receipt, opts \\ []) when is_list(opts) do
    Refunds.process_refund_webhook_receipt(receipt, opts)
  end

  @spec create_or_reuse_payment_intent(map(), keyword()) ::
          {:ok,
           %{
             payment_intent: Store.Payments.PaymentIntent.t(),
             payment_intent_key: String.t(),
             duplicate?: boolean()
           }}
          | {:error, term()}
  def create_or_reuse_payment_intent(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Interlocks.create_or_reuse_payment_intent(attrs, opts)
  end

  @spec create_intent_for_order(map() | nil, String.t(), CreateIntentForOrderInput.t()) ::
          {:ok,
           %{
             order_id: Ecto.UUID.t(),
             order_ref: String.t(),
             payment_intent_id: Ecto.UUID.t(),
             payment_intent_key: String.t(),
             provider: String.t(),
             provider_session_id: String.t() | nil,
             state: atom(),
             amount_minor: non_neg_integer(),
             currency: String.t(),
             checkout_key: String.t(),
             redirect_url: String.t() | nil,
             client_secret: String.t() | nil,
             duplicate?: boolean()
           }}
          | {:error, Error.t()}
  def create_intent_for_order(actor, checkout_key, %CreateIntentForOrderInput{} = input)
      when is_binary(checkout_key) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, checkout} <- Checkout.get_payment_context_for_user(actor, checkout_key),
             :ok <-
               DigitalFacade.ensure_checkout_actor_allowed_for_system(actor, checkout.order_id),
             :ok <- ensure_totals_finalized(checkout),
             {:ok, checkout} <- ensure_order_payable(checkout),
             :ok <- ensure_payable_total(checkout),
             :ok <- Providers.ensure_enabled_provider(input.provider),
             {:ok, has_subscription_lines?} <- order_has_subscription_lines(checkout.order_id),
             {:ok, provider_context} <-
               checkout_provider_context(input.provider, actor, checkout, has_subscription_lines?),
             {:ok, intent_result} <- create_or_reuse_intent_for_checkout(checkout, input),
             {:ok, payment_intent, checkout} <-
               ensure_provider_setup(
                 intent_result.payment_intent,
                 checkout,
                 intent_result.payment_intent_key,
                 input,
                 provider_context
               ) do
          {:ok, build_checkout_intent_result(checkout, intent_result, payment_intent)}
        end
      end)

    :telemetry.execute(
      [:store, :checkout, :create_payment_intent],
      %{duration: System.monotonic_time() - started_at},
      %{provider: provider_to_string(input.provider), result: telemetry_result(result)}
    )

    :telemetry.execute(
      [:store, :checkout, :step],
      %{
        duration: System.monotonic_time() - started_at,
        query_count: repo_stats.query_count,
        queue_time: repo_stats.queue_time,
        query_time: repo_stats.query_time,
        decode_time: repo_stats.decode_time
      },
      %{
        step: :create_payment_intent,
        provider: provider_to_string(input.provider),
        result: telemetry_result(result)
      }
    )

    normalize_result(result)
  end

  def create_intent_for_order(_actor, _checkout_key, _input) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key and create intent input are required")}
  end

  @spec reconcile_pending_provider_setup(keyword()) ::
          {:ok,
           %{
             recovered_count: non_neg_integer(),
             order_ids: [String.t()]
           }}
          | {:error, term()}
  def reconcile_pending_provider_setup(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 200)
    source = Keyword.get(opts, :source, :worker)

    recoverable_pending_provider_setup_candidates(limit)
    |> Enum.reduce_while(
      {:ok, %{recovered_count: 0, order_ids: []}},
      &recover_pending_provider_setup_candidate(&1, &2, source)
    )
    |> case do
      {:ok, result} -> {:ok, %{result | order_ids: Enum.reverse(result.order_ids)}}
      other -> other
    end
  end

  @spec process_payment_webhook_receipt(Store.Payments.WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt(receipt, opts \\ []) when is_list(opts) do
    Interlocks.process_payment_webhook_receipt(receipt, opts)
  end

  @spec apply_payment_success_once(Store.Payments.PaymentIntent.t() | String.t(), keyword()) ::
          {:ok,
           %{
             applied?: boolean(),
             order: Store.Orders.Order.t(),
             payment_intent: Store.Payments.PaymentIntent.t()
           }}
          | {:error, term()}
  def apply_payment_success_once(payment_intent_or_id, opts \\ []) when is_list(opts) do
    Interlocks.apply_payment_success_once(payment_intent_or_id, opts)
  end

  @spec apply_observed_payment_outcome_for_system(map()) :: {:ok, map()} | {:error, term()}
  def apply_observed_payment_outcome_for_system(observation_result)
      when is_map(observation_result) do
    Interlocks.apply_observed_payment_outcome(observation_result)
  end

  @spec validate_collection_outcome_certification_for_system(
          ValidateRenewalCollectionOutcomeInput.t()
        ) :: :ok | {:error, term()}
  def validate_collection_outcome_certification_for_system(
        %ValidateRenewalCollectionOutcomeInput{} = input
      ) do
    Interlocks.validate_collection_outcome_certification(input)
  end

  def validate_collection_outcome_certification_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection outcome evidence is required")}
  end

  @spec record_and_apply_payment_observation_for_system(
          PaymentIntent.t(),
          ProviderObservation.t()
        ) :: {:ok, map()} | {:error, term()}
  def record_and_apply_payment_observation_for_system(
        %PaymentIntent{} = payment_intent,
        %ProviderObservation{} = observation
      ) do
    with {:ok, evidence} <-
           ObservationEvidence.record(payment_intent, observation),
         {:ok, result} <-
           Interlocks.apply_observed_payment_outcome(%{
             payment_intent: payment_intent,
             observation: observation,
             evidence: evidence
           }) do
      {:ok, Map.put(result, :evidence, evidence)}
    end
  end

  defp create_or_reuse_intent_for_checkout(checkout, input) do
    attrs = %{
      order_id: checkout.order_id,
      amount_received_minor: checkout.grand_total_minor,
      currency: checkout.currency_code,
      provider: input.provider,
      provider_request_reference: checkout_request_reference(input.provider, checkout.order_id)
    }

    create_or_reuse_payment_intent(attrs, context: %{system?: true})
  end

  defp checkout_request_reference(:paystack, order_id),
    do: "checkout-" <> String.replace(order_id, "-", "")

  defp checkout_request_reference(_provider, _order_id), do: nil

  defp checkout_provider_context(:paystack, _actor, _checkout, true) do
    {:error,
     Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "Paystack subscription checkout is disabled")}
  end

  defp checkout_provider_context(
         :paystack,
         %{id: user_id, email: email},
         %{user_id: user_id, currency_code: "ZAR", grand_total_minor: amount},
         false
       )
       when is_binary(user_id) and amount > 0 and
              (is_binary(email) or is_struct(email, Ash.CiString)) do
    {:ok, %{has_subscription_lines?: false, customer_email: to_string(email)}}
  end

  defp checkout_provider_context(:paystack, _actor, _checkout, _subscription_lines?) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "Paystack checkout requires a signed-in customer and a positive ZAR total"
     )}
  end

  defp checkout_provider_context(_provider, _actor, _checkout, has_subscription_lines?),
    do: {:ok, %{has_subscription_lines?: has_subscription_lines?, customer_email: nil}}

  defp ensure_provider_reference(
         payment_intent,
         checkout,
         payment_intent_key,
         input,
         provider_context
       ) do
    case provider_reference_present?(payment_intent) do
      true ->
        {:ok, payment_intent}

      false ->
        with {:ok, provider_payload} <-
               run_provider_setup_request(
                 payment_intent,
                 checkout,
                 payment_intent_key,
                 input,
                 provider_context
               ) do
          update_provider_reference(payment_intent, provider_payload, input.provider)
        end
    end
  end

  defp run_provider_setup_request(
         payment_intent,
         checkout,
         payment_intent_key,
         input,
         provider_context
       ) do
    ProviderTask.execute(
      fn ->
        Providers.create_intent(
          input.provider,
          provider_create_intent_attrs(
            checkout,
            payment_intent,
            payment_intent_key,
            provider_context
          ),
          []
        )
      end,
      provider: input.provider,
      order_id: checkout.order_id,
      checkout_key: checkout.checkout_key,
      payment_intent_key: payment_intent_key
    )
  end

  defp ensure_provider_setup(
         payment_intent,
         checkout,
         payment_intent_key,
         input,
         provider_context
       ) do
    with {:ok, payment_intent, checkout} <-
           ensure_provider_reference_for_checkout(
             payment_intent,
             checkout,
             payment_intent_key,
             input,
             provider_context
           ) do
      time_provider_setup_phase(:local_finalize, input.provider, fn ->
        reconcile_local_provider_setup(payment_intent, checkout, source: :request)
      end)
    end
  end

  defp ensure_provider_reference_for_checkout(
         payment_intent,
         checkout,
         payment_intent_key,
         input,
         provider_context
       ) do
    case provider_reference_present?(payment_intent) do
      true ->
        maybe_resume_provider_setup(checkout, payment_intent)

      false ->
        begin_provider_setup_flow(
          payment_intent,
          checkout,
          payment_intent_key,
          input,
          provider_context
        )
    end
  end

  defp begin_provider_setup_flow(
         payment_intent,
         checkout,
         payment_intent_key,
         input,
         provider_context
       ) do
    case mark_provider_setup_pending(checkout) do
      {:ok, updated_checkout} ->
        payment_intent
        |> request_provider_reference_phase(
          updated_checkout,
          payment_intent_key,
          input,
          provider_context
        )
        |> finalize_provider_request(updated_checkout, payment_intent)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_resume_provider_setup(%{state: :pending_provider_setup} = checkout, payment_intent) do
    :telemetry.execute(
      [:store, :checkout, :pending_provider_setup, :resume],
      %{count: 1},
      %{provider: provider_to_string(payment_intent.provider)}
    )

    emit_pending_provider_setup_state(checkout, payment_intent, :resume, :request)
    {:ok, payment_intent, checkout}
  end

  defp maybe_resume_provider_setup(checkout, payment_intent), do: {:ok, payment_intent, checkout}

  defp reconcile_local_provider_setup(payment_intent, checkout, opts) do
    source = Keyword.get(opts, :source, :request)
    pending_before? = checkout.state == :pending_provider_setup
    created_before? = payment_intent.state == :created

    emit_pending_provider_setup_state(checkout, payment_intent, :before_local_finalize, source)

    with {:ok, payment_intent} <- maybe_submit_payment_intent(payment_intent),
         {:ok, checkout} <- maybe_mark_provider_setup_ready(checkout) do
      emit_pending_provider_setup_state(checkout, payment_intent, :after_local_finalize, source)

      if pending_before? or created_before? do
        emit_local_provider_recovery(payment_intent, checkout, source)
      end

      {:ok, payment_intent, checkout}
    end
  end

  defp maybe_mark_provider_setup_ready(
         %{order_id: order_id, state: :pending_provider_setup} = checkout
       ) do
    with {:ok, order} <- fetch_order(order_id),
         {:ok, updated_order} <- provider_setup_ready(order) do
      {:ok, Map.put(checkout, :state, updated_order.state)}
    end
  end

  defp maybe_mark_provider_setup_ready(checkout), do: {:ok, checkout}

  defp provider_create_intent_attrs(
         checkout,
         payment_intent,
         payment_intent_key,
         %{has_subscription_lines?: has_subscription_lines?, customer_email: customer_email}
       ) do
    urls = provider_return_urls(checkout.checkout_key)
    checkout_mode = provider_checkout_mode(checkout.grand_total_minor, has_subscription_lines?)

    %{
      order_ref: checkout.order_ref,
      order_id: checkout.order_id,
      checkout_key: checkout.checkout_key,
      local_intent_id: payment_intent.id,
      amount_minor: checkout.grand_total_minor,
      currency: checkout.currency_code,
      payment_intent_key: payment_intent_key,
      idempotency_key: payment_intent_key,
      provider_request_reference: payment_intent.provider_request_reference,
      customer_email: customer_email,
      has_subscription_lines?: has_subscription_lines?,
      save_payment_method_for_off_session?: has_subscription_lines?,
      checkout_mode: checkout_mode,
      return_url: urls.return_url,
      cancel_url: urls.cancel_url
    }
  end

  defp provider_return_urls(checkout_key) do
    payments_config = Application.get_env(:store, :payments, [])
    checkout_config = Keyword.get(payments_config, :checkout, [])

    return_base_url =
      Keyword.get(checkout_config, :return_base_url, "http://localhost:4000/checkout/return")

    cancel_base_url =
      Keyword.get(checkout_config, :cancel_base_url, "http://localhost:4000/checkout/cancel")

    %{
      return_url: append_checkout_key(return_base_url, checkout_key),
      cancel_url: append_checkout_key(cancel_base_url, checkout_key)
    }
  end

  defp append_checkout_key(base_url, checkout_key)
       when is_binary(base_url) and is_binary(checkout_key) do
    separator = if String.contains?(base_url, "?"), do: "&", else: "?"
    "#{base_url}#{separator}checkout_key=#{checkout_key}"
  end

  defp update_provider_reference(payment_intent, provider_payload, provider)
       when is_map(provider_payload) do
    provider_value =
      Map.get(provider_payload, :provider, provider)

    case Providers.normalize_provider(provider_value) do
      :unknown ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_UNSUPPORTED",
           "payment provider is not supported"
         )}

      normalized ->
        if Providers.known_provider?(normalized) do
          attrs = %{
            provider: normalized,
            provider_payment_id: Map.get(provider_payload, :provider_payment_id),
            provider_session_id: Map.get(provider_payload, :provider_session_id),
            provider_customer_ref: Map.get(provider_payload, :provider_customer_ref),
            provider_payment_method_ref: Map.get(provider_payload, :provider_payment_method_ref),
            provider_checkout_url: Map.get(provider_payload, :provider_checkout_url),
            provider_client_secret: Map.get(provider_payload, :provider_client_secret)
          }

          payment_intent
          |> Ash.Changeset.for_update(:set_provider_reference, attrs, context: %{system?: true})
          |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
        else
          {:error,
           Error.new(
             "PAYMENT_PROVIDER_UNSUPPORTED",
             "payment provider is not supported"
           )}
        end
    end
  end

  defp maybe_submit_payment_intent(
         %Store.Payments.PaymentIntent{state: :created} = payment_intent
       ) do
    payment_intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp maybe_submit_payment_intent(%Store.Payments.PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action, :succeeded] do
    {:ok, payment_intent}
  end

  defp maybe_submit_payment_intent(_payment_intent) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent cannot be submitted from the current state"
     )}
  end

  defp build_checkout_intent_result(checkout, intent_result, payment_intent) do
    %{
      order_id: checkout.order_id,
      order_ref: checkout.order_ref,
      payment_intent_id: payment_intent.id,
      payment_intent_key: intent_result.payment_intent_key,
      provider: provider_to_string(payment_intent.provider),
      provider_session_id: payment_intent.provider_session_id,
      state: payment_intent.state,
      amount_minor: checkout.grand_total_minor,
      currency: checkout.currency_code,
      checkout_key: checkout.checkout_key,
      redirect_url: payment_intent.provider_checkout_url,
      client_secret: payment_intent.provider_client_secret,
      duplicate?: intent_result.duplicate?
    }
  end

  defp ensure_totals_finalized(%{totals_finalized?: true}), do: :ok

  defp ensure_totals_finalized(_checkout) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "checkout totals must be finalized before payment intent creation"
     )}
  end

  defp ensure_order_payable(%{state: state} = checkout)
       when state in [:pending_payment, :pending_provider_setup],
       do: {:ok, checkout}

  defp ensure_order_payable(%{state: :paid}),
    do: {:error, Error.new("PAYMENT_ALREADY_SUCCEEDED", "order is already paid")}

  defp ensure_order_payable(_checkout) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "order is not payable in the current state")}
  end

  defp ensure_payable_total(%{grand_total_minor: amount, currency_code: currency})
       when is_integer(amount) and amount >= 0 and is_binary(currency) and currency != "",
       do: :ok

  defp ensure_payable_total(_checkout) do
    {:error, Error.new("VALIDATION_ERROR", "checkout totals are invalid")}
  end

  defp provider_reference_present?(%Store.Payments.PaymentIntent{} = payment_intent) do
    is_binary(payment_intent.provider_session_id) or
      is_binary(payment_intent.provider_payment_id) or
      is_binary(payment_intent.provider_customer_ref) or
      is_binary(payment_intent.provider_payment_method_ref) or
      is_binary(payment_intent.provider_checkout_url) or
      is_binary(payment_intent.provider_client_secret)
  end

  defp order_has_subscription_lines(order_id) when is_binary(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(
        expr(order_id == ^order_id and not is_nil(subscription_plan_id_snapshot))
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [_ | _]} -> {:ok, true}
      {:ok, []} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  defp provider_checkout_mode(amount_minor, true)
       when is_integer(amount_minor) and amount_minor == 0,
       do: :setup

  defp provider_checkout_mode(_amount_minor, _has_subscription_lines?), do: :payment

  defp provider_to_string(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.downcase()

  defp provider_to_string(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp provider_to_string(_provider), do: "unknown"

  defp mark_provider_setup_pending(%{order_id: order_id} = checkout) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, order} <- fetch_order(order_id),
         {:ok, updated_order} <- begin_provider_setup(order, started_at) do
      {:ok, Map.put(checkout, :state, updated_order.state)}
    end
  end

  defp begin_provider_setup(%Order{state: :pending_provider_setup} = order, started_at) do
    order
    |> Ash.Changeset.for_update(
      :refresh_provider_setup,
      %{provider_setup_started_at: started_at},
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> tap(fn
      {:ok, updated_order} ->
        _ =
          Store.Orders.notify_order_state_change(
            updated_order.id,
            updated_order.state,
            :provider_setup_refreshed
          )

      _ ->
        :ok
    end)
  end

  defp begin_provider_setup(%Order{} = order, started_at) do
    order
    |> Ash.Changeset.for_update(
      :begin_provider_setup,
      %{provider_setup_started_at: started_at},
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> tap(fn
      {:ok, updated_order} ->
        _ =
          Store.Orders.notify_order_state_change(
            updated_order.id,
            updated_order.state,
            :provider_setup_started
          )

      _ ->
        :ok
    end)
  end

  defp provider_setup_ready(%Order{state: :pending_provider_setup} = order) do
    order
    |> Ash.Changeset.for_update(:provider_setup_ready, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> tap(fn
      {:ok, updated_order} ->
        _ =
          Store.Orders.notify_order_state_change(
            updated_order.id,
            updated_order.state,
            :provider_setup_ready
          )

      _ ->
        :ok
    end)
  end

  defp provider_setup_ready(%Order{} = order), do: {:ok, order}

  defp recoverable_pending_provider_setup_candidates(limit) do
    Repo.all(
      from(payment_intent in PaymentIntent,
        join: order in Order,
        on: order.id == payment_intent.order_id,
        where: ^recoverable_pending_provider_setup_dynamic(),
        order_by: [asc: order.provider_setup_started_at, asc: order.id],
        limit: ^limit,
        select:
          {payment_intent,
           %{
             order_id: order.id,
             checkout_key: order.checkout_key,
             state: order.state
           }}
      )
    )
  end

  defp emit_pending_provider_setup_state(checkout, payment_intent, phase, source)
       when is_map(checkout) and is_atom(phase) do
    case pending_provider_setup_state(checkout, payment_intent) do
      nil ->
        :ok

      classification ->
        :telemetry.execute(
          [:store, :checkout, :pending_provider_setup, :state],
          %{count: 1},
          %{
            classification: classification,
            phase: phase,
            provider: provider_to_string(payment_intent.provider),
            source: source
          }
        )
    end
  end

  defp emit_pending_provider_setup_state(_checkout, _payment_intent, _phase, _source), do: :ok

  defp pending_provider_setup_state(%{state: :pending_provider_setup}, payment_intent) do
    cond do
      not provider_reference_present?(payment_intent) ->
        :pending_no_refs

      payment_intent.state == :created ->
        :pending_refs_created_intent

      true ->
        nil
    end
  end

  defp pending_provider_setup_state(%{state: state}, payment_intent)
       when state != :pending_provider_setup do
    if provider_reference_present?(payment_intent) and
         payment_intent.state in [:submitted, :requires_action, :succeeded] do
      :recovered_finalized_local
    end
  end

  defp emit_local_provider_recovery(payment_intent, checkout, source) do
    if checkout.state != :pending_provider_setup and
         payment_intent.state in [:submitted, :requires_action, :succeeded] do
      :telemetry.execute(
        [:store, :checkout, :pending_provider_setup, :recovery],
        %{count: 1},
        %{provider: provider_to_string(payment_intent.provider), result: :ok, source: source}
      )
    end
  end

  defp fetch_order(order_id) when is_binary(order_id) do
    query =
      Order
      |> Ash.Query.filter(expr(id == ^order_id))
      |> Ash.Query.select([:id, :state, :version, :provider_setup_started_at, :checkout_key])

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found")}
      {:error, error} -> {:error, error}
    end
  end

  defp recover_pending_provider_setup_candidate({payment_intent, checkout}, {:ok, acc}, source) do
    case time_provider_setup_phase(:local_finalize, payment_intent.provider, fn ->
           reconcile_local_provider_setup(payment_intent, checkout, source: source)
         end) do
      {:ok, _payment_intent, updated_checkout} ->
        {:cont, {:ok, accumulate_recovered_checkout(acc, checkout, updated_checkout)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp accumulate_recovered_checkout(acc, checkout, updated_checkout) do
    if recovered_checkout?(checkout, updated_checkout) do
      %{
        recovered_count: acc.recovered_count + 1,
        order_ids: [checkout.order_id | acc.order_ids]
      }
    else
      acc
    end
  end

  defp recovered_checkout?(checkout, updated_checkout) do
    checkout.state == :pending_provider_setup and
      updated_checkout.state != :pending_provider_setup
  end

  defp request_provider_reference_phase(
         payment_intent,
         updated_checkout,
         payment_intent_key,
         input,
         provider_context
       ) do
    time_provider_setup_phase(:provider_request, input.provider, fn ->
      ensure_provider_reference(
        payment_intent,
        updated_checkout,
        payment_intent_key,
        input,
        provider_context
      )
    end)
  end

  defp finalize_provider_request(
         {:ok, updated_payment_intent},
         updated_checkout,
         _payment_intent
       ) do
    {:ok, updated_payment_intent, updated_checkout}
  end

  defp finalize_provider_request({:error, _reason} = error, updated_checkout, payment_intent) do
    emit_pending_provider_setup_state(
      updated_checkout,
      payment_intent,
      :provider_request,
      :request
    )

    error
  end

  defp recoverable_pending_provider_setup_dynamic do
    dynamic(
      [payment_intent, order],
      order.state == ^:pending_provider_setup and
        payment_intent.state in ^@recoverable_pending_provider_intent_states and
        (not is_nil(payment_intent.provider_session_id) or
           not is_nil(payment_intent.provider_payment_id) or
           not is_nil(payment_intent.provider_customer_ref) or
           not is_nil(payment_intent.provider_payment_method_ref) or
           not is_nil(payment_intent.provider_checkout_url) or
           not is_nil(payment_intent.provider_client_secret))
    )
  end

  defp time_provider_setup_phase(phase, provider, fun)
       when is_atom(phase) and is_function(fun, 0) do
    started_at = System.monotonic_time()
    result = fun.()

    :telemetry.execute(
      [:store, :checkout, :provider_setup],
      %{duration: System.monotonic_time() - started_at},
      %{
        phase: phase,
        provider: provider_to_string(provider),
        result: telemetry_result(result)
      }
    )

    result
  end

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp telemetry_result({:ok, %{duplicate?: true}}), do: :duplicate
  defp telemetry_result({:ok, _, _}), do: :ok
  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result({:error, _}), do: :error
end
