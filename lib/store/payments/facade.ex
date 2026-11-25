defmodule Store.Payments.Facade do
  @moduledoc """
  Consumer and system-scoped surfaces for payment intents and webhook receipts.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.AuditLog
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.Inputs.RenewalCancellationRemediationInput
  alias Store.Payments.Inputs.RenewalOrderPaymentApplicationInput
  alias Store.Payments.Inputs.RenewalPaymentApplicationInput
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.Interlocks
  alias Store.Payments.ObservationReconciliation
  alias Store.Payments.{PaymentIntent, Providers, WebhookReceipt}
  alias Store.Payments.Queries.{PaymentIntentIndexQuery, PaymentIntentShowQuery}
  alias Store.Payments.Refunds
  alias Store.Support.Errors.Normalize

  @doc "Returns the enabled gateway that the storefront may explicitly select for a purchase."
  @spec purchase_provider_for_public() :: Providers.known_provider() | nil
  defdelegate purchase_provider_for_public(), to: Providers, as: :default_purchase_provider_for_ui

  @spec observe_payment_intent_for_system(ObservePaymentIntentInput.t()) ::
          {:ok, ObservationReconciliation.result()} | {:error, term()}
  def observe_payment_intent_for_system(%ObservePaymentIntentInput{} = input) do
    ObservationReconciliation.observe_payment_intent(input)
  end

  @spec apply_observed_payment_outcome_for_system(map()) ::
          {:ok,
           %{
             outcome: Store.Payments.PaymentOutcomeResolver.outcome(),
             payment_intent: map()
           }}
          | {:error, term()}
  def apply_observed_payment_outcome_for_system(observation_result)
      when is_map(observation_result) do
    Store.Payments.apply_observed_payment_outcome_for_system(observation_result)
  end

  @spec renewal_payment_application_status_for_system(RenewalPaymentApplicationInput.t()) ::
          {:ok, :applied | :unapplied} | {:error, Store.Support.Errors.Error.t()}
  def renewal_payment_application_status_for_system(%RenewalPaymentApplicationInput{} = input) do
    Interlocks.renewal_payment_application_status_for_system(input)
  end

  @spec serialize_renewal_order_payment_application_for_system(
          RenewalOrderPaymentApplicationInput.t()
        ) :: {:ok, :unapplied} | {:error, Store.Support.Errors.Error.t()}
  def serialize_renewal_order_payment_application_for_system(
        %RenewalOrderPaymentApplicationInput{} = input
      ) do
    Interlocks.serialize_renewal_order_payment_application_for_system(input)
  end

  @spec serialize_renewal_payment_application_for_system(RenewalPaymentApplicationInput.t()) ::
          {:ok, :applied | :unapplied} | {:error, Store.Support.Errors.Error.t()}
  def serialize_renewal_payment_application_for_system(%RenewalPaymentApplicationInput{} = input) do
    Interlocks.serialize_renewal_payment_application_for_system(input)
  end

  @spec request_renewal_cancellation_remediation_for_system(
          RenewalCancellationRemediationInput.t()
        ) :: {:ok, Store.Payments.Refund.t()} | {:error, term()}
  def request_renewal_cancellation_remediation_for_system(
        %RenewalCancellationRemediationInput{} = input
      ) do
    Refunds.request_renewal_cancellation_remediation_for_system(input)
  end

  @spec record_and_apply_payment_observation_for_system(
          PaymentIntent.t(),
          Store.Payments.Types.ProviderObservation.t()
        ) ::
          {:ok,
           %{
             evidence: Store.Payments.PaymentAttempt.t(),
             outcome: Store.Payments.PaymentOutcomeResolver.outcome(),
             payment_intent: map()
           }}
          | {:error, term()}
  def record_and_apply_payment_observation_for_system(
        %PaymentIntent{} = payment_intent,
        %Store.Payments.Types.ProviderObservation{} = observation
      ) do
    Store.Payments.record_and_apply_payment_observation_for_system(payment_intent, observation)
  end

  @spec list_payment_intents_for_admin(map(), PaymentIntentIndexQuery.t()) ::
          {:ok, [PaymentIntent.t()]} | {:error, term()}
  def list_payment_intents_for_admin(actor, %PaymentIntentIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      PaymentIntent
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Store.Payments, actor: actor) do
      {:ok, intents} -> {:ok, intents}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_payment_intent_for_admin(map(), PaymentIntentShowQuery.t()) ::
          {:ok, PaymentIntent.t() | nil} | {:error, term()}
  def get_payment_intent_for_admin(actor, %PaymentIntentShowQuery{id: id}) when is_map(actor) do
    ash_query = Ash.Query.for_read(PaymentIntent, :get_for_admin, %{id: id}, actor: actor)

    case Ash.read_one(ash_query, domain: Store.Payments, actor: actor) do
      {:ok, intent} -> {:ok, intent}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec ingest_webhook_receipt_for_system(WebhookReceiptIngestInput.t()) ::
          {:ok, %{receipt: WebhookReceipt.t(), duplicate?: boolean()}} | {:error, term()}
  def ingest_webhook_receipt_for_system(%WebhookReceiptIngestInput{} = input) do
    candidate_id = Ash.UUIDv7.generate()

    attrs =
      input
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, attrs)
    |> Ash.Changeset.force_change_attribute(:id, candidate_id)
    |> Ash.create(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> normalize_ingest_result(candidate_id)
  end

  @spec get_webhook_receipt_for_system(Ecto.UUID.t()) ::
          {:ok, WebhookReceipt.t() | nil} | {:error, term()}
  def get_webhook_receipt_for_system(webhook_receipt_id) when is_binary(webhook_receipt_id) do
    case WebhookReceipt.get_for_system(webhook_receipt_id,
           context: %{system?: true},
           authorize?: false
         ) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec process_payment_webhook_receipt_for_system(WebhookReceipt.t()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt_for_system(%WebhookReceipt{} = receipt) do
    started_at = System.monotonic_time()

    case mark_processing(receipt) do
      {:ok, processing_receipt} ->
        result =
          with :ok <- Providers.ensure_enabled_provider(processing_receipt.provider) do
            Store.Payments.process_payment_webhook_receipt(processing_receipt,
              context: %{system?: true}
            )
          end

        case mark_terminal_status(processing_receipt, result) do
          :ok ->
            emit_webhook_processed_telemetry(
              :webhook_processed,
              processing_receipt,
              result,
              started_at
            )

            result

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  @spec process_refund_webhook_receipt_for_system(WebhookReceipt.t()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt_for_system(%WebhookReceipt{} = receipt) do
    started_at = System.monotonic_time()

    case mark_processing(receipt) do
      {:ok, processing_receipt} ->
        result =
          with :ok <- Providers.ensure_enabled_provider(processing_receipt.provider) do
            Store.Payments.process_refund_webhook_receipt(processing_receipt,
              context: %{system?: true}
            )
          end

        case mark_terminal_status(processing_receipt, result) do
          :ok ->
            emit_webhook_processed_telemetry(
              :refund_webhook_processed,
              processing_receipt,
              result,
              started_at
            )

            result

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  @spec purge_expired_webhook_evidence_for_system(keyword()) ::
          {:ok, %{purged_count: non_neg_integer(), receipt_ids: [Ecto.UUID.t()]}}
          | {:error, term()}
  def purge_expired_webhook_evidence_for_system(opts \\ []) when is_list(opts) do
    retention_days =
      opts
      |> Keyword.get(
        :retention_days,
        Application.get_env(:store, :operations, []) |> Keyword.get(:webhook_retention_days, 30)
      )

    limit = Keyword.get(opts, :limit, 100)

    cutoff =
      DateTime.utc_now() |> DateTime.add(-retention_days, :day) |> DateTime.truncate(:microsecond)

    query =
      WebhookReceipt
      |> Ash.Query.filter(expr(received_at < ^cutoff and is_nil(evidence_purged_at)))
      |> Ash.Query.sort(received_at: :asc, id: :asc)
      |> Ash.Query.limit(limit)

    with {:ok, receipts} <-
           Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}),
         {:ok, purged_ids} <- purge_receipts(receipts) do
      :ok = maybe_audit_purge(purged_ids, cutoff)
      {:ok, %{purged_count: length(purged_ids), receipt_ids: purged_ids}}
    else
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  defp normalize_ingest_result({:ok, %WebhookReceipt{} = receipt}, candidate_id) do
    {:ok,
     %{
       receipt: receipt,
       duplicate?: receipt.id != candidate_id
     }}
  end

  defp normalize_ingest_result({:error, error}, _candidate_id),
    do: {:error, Normalize.normalize(error)}

  defp mark_processing(%WebhookReceipt{processing_status: "processed"} = receipt),
    do: {:ok, receipt}

  defp mark_processing(%WebhookReceipt{} = receipt) do
    receipt
    |> Ash.Changeset.for_update(:mark_processing, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
  end

  defp mark_terminal_status(receipt, :ok), do: mark_processed(receipt)
  defp mark_terminal_status(receipt, {:discard, _reason}), do: mark_processed(receipt)

  defp mark_terminal_status(receipt, {:error, reason}) do
    normalized = Normalize.normalize(reason)
    mark_failed(receipt, normalized)
  end

  defp mark_processed(%WebhookReceipt{} = receipt) do
    receipt
    |> Ash.Changeset.for_update(
      :mark_processed,
      %{processed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)},
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> case do
      {:ok, _receipt} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp mark_failed(%WebhookReceipt{} = receipt, normalized_error) do
    attrs = %{
      error_code: normalized_error.code,
      error_detail: normalized_error.message,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    receipt
    |> Ash.Changeset.for_update(:mark_failed, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> case do
      {:ok, _receipt} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp purge_receipts(receipts) do
    purged_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    receipts
    |> Enum.reduce_while({:ok, []}, fn receipt, {:ok, acc} ->
      attrs = %{raw_body: "[PURGED]", headers: %{}, evidence_purged_at: purged_at}

      case receipt
           |> Ash.Changeset.for_update(:purge_evidence, attrs, context: %{system?: true})
           |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true}) do
        {:ok, _updated} -> {:cont, {:ok, [receipt.id | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, purged_ids} -> {:ok, Enum.reverse(purged_ids)}
      other -> other
    end
  end

  defp maybe_audit_purge([], _cutoff), do: :ok

  defp maybe_audit_purge(receipt_ids, cutoff) do
    AuditLog
    |> Ash.Changeset.for_create(
      :create,
      %{
        action: "WEBHOOK_EVIDENCE_PURGED",
        resource: "webhook_receipts",
        meta: %{
          purged_count: length(receipt_ids),
          receipt_ids: Enum.take(receipt_ids, 20),
          cutoff: DateTime.to_iso8601(cutoff)
        }
      },
      context: %{system?: true}
    )
    |> Ash.create(domain: Store.Admin, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _audit_log} -> :ok
      {:error, _error} -> :ok
    end
  end

  defp emit_webhook_processed_telemetry(
         name,
         receipt,
         result,
         started_at,
         fallback_outcome \\ nil
       ) do
    :telemetry.execute(
      [:store, :payments, name],
      %{duration: System.monotonic_time() - started_at},
      %{
        provider: receipt.provider,
        outcome: webhook_outcome(result, fallback_outcome),
        receipt_id: receipt.id,
        provider_event_id: receipt.provider_event_id
      }
    )
  end

  defp webhook_outcome({:ok, _value}, _fallback), do: :ok
  defp webhook_outcome(:ok, _fallback), do: :ok
  defp webhook_outcome({:discard, _reason}, _fallback), do: :discard
  defp webhook_outcome({:error, _reason}, _fallback), do: :error
  defp webhook_outcome(_result, fallback) when not is_nil(fallback), do: fallback
  defp webhook_outcome(_result, _fallback), do: :unknown
end
