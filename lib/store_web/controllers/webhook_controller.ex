defmodule StoreWeb.WebhookController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.Providers
  alias Store.Payments.WebhookReceipt
  alias Store.Support.Errors.Error
  alias Store.Workers.ProcessRefundWebhookReceiptWorker
  alias Store.Workers.ProcessWebhookReceiptWorker
  alias StoreWeb.API.ErrorResponder
  alias StoreWeb.PaymentIngressTelemetry

  plug(StoreWeb.Plugs.RequestRateLimit, [scope: :webhook] when action in [:create])

  @job_unique_opts [
    fields: [:worker, :args],
    states: [:available, :scheduled, :executing, :retryable, :completed],
    period: 86_400
  ]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"provider" => provider}) when is_binary(provider) do
    started_at = System.monotonic_time()

    case run_create(conn, provider) do
      {:ok, conn, normalized_provider, receipt_id} ->
        conn =
          conn
          |> put_status(acknowledgement_status(normalized_provider))
          |> json(%{data: %{webhook_receipt_id: receipt_id}})

        PaymentIngressTelemetry.emit_response(
          :webhook,
          normalized_provider,
          started_at,
          conn.status,
          :ok
        )

        conn

      {:ignore, conn, normalized_provider} ->
        conn = send_resp(conn, 200, "")

        PaymentIngressTelemetry.emit_response(
          :webhook,
          normalized_provider,
          started_at,
          conn.status,
          :ok
        )

        conn

      {:error, normalized_provider, error} ->
        rendered = ErrorResponder.render(conn, error)

        PaymentIngressTelemetry.emit_response(
          :webhook,
          normalized_provider,
          started_at,
          rendered.status,
          :error,
          PaymentIngressTelemetry.telemetry_error_code({:error, error})
        )

        rendered

      {:discard, normalized_provider, reason} ->
        error = Error.new("VALIDATION_ERROR", reason)
        rendered = ErrorResponder.render(conn, error)

        PaymentIngressTelemetry.emit_response(
          :webhook,
          normalized_provider,
          started_at,
          rendered.status,
          :discard,
          error.code
        )

        rendered
    end
  end

  def create(conn, _params) do
    ErrorResponder.render(conn, Error.new("VALIDATION_ERROR", "provider is required"))
  end

  defp run_create(conn, provider) do
    telemetry_provider = telemetry_provider(provider)

    received_started_at = System.monotonic_time()

    with {:ok, normalized_provider} <- normalize_provider_param(provider),
         {:ok, raw_body, conn} <- extract_raw_body(conn),
         headers <- headers_to_map(conn.req_headers),
         {:ok, canonical_receipt} <-
           verify_and_normalize(normalized_provider, headers, raw_body, :webhook),
         {:ok, receipt_result} <-
           ingest_receipt(normalized_provider, raw_body, headers, canonical_receipt, :webhook),
         :ok <-
           emit_webhook_received(
             normalized_provider,
             canonical_receipt,
             receipt_result,
             received_started_at
           ),
         enqueue_started_at = System.monotonic_time(),
         {:ok, enqueue_result} <-
           enqueue_processing_job(receipt_result, canonical_receipt.event_type, :webhook),
         :ok <-
           emit_webhook_enqueued(
             normalized_provider,
             canonical_receipt,
             receipt_result,
             {:ok, enqueue_result},
             enqueue_started_at
           ) do
      {:ok, conn, normalized_provider, receipt_result.receipt.id}
    else
      :ignore -> {:ignore, conn, telemetry_provider}
      {:error, error} -> {:error, telemetry_provider, error}
      {:discard, reason} -> {:discard, telemetry_provider, reason}
    end
  end

  defp acknowledgement_status(:paystack), do: :ok
  defp acknowledgement_status(_provider), do: :accepted

  defp extract_raw_body(conn) do
    case conn.assigns[:raw_body] do
      raw_body when is_binary(raw_body) ->
        {:ok, raw_body, conn}

      _ ->
        {:error,
         Error.new(
           "PAYMENT_PAYLOAD_INVALID",
           "raw webhook body was not captured; ensure Plug.Parsers body_reader is configured"
         )}
    end
  end

  defp verify_and_normalize(provider, headers, raw_body, route) do
    PaymentIngressTelemetry.measure(:verify, route, provider, fn ->
      with {:ok, payload} <- Providers.verify_webhook(provider, headers, raw_body, []) do
        Providers.normalize_webhook(provider, payload)
      end
    end)
  end

  defp ingest_receipt(provider, raw_body, headers, canonical_receipt, route) do
    PaymentIngressTelemetry.capture_repo_stage(:persist, route, provider, fn ->
      idempotency_key =
        canonical_receipt.provider_idempotency_key ||
          "#{provider}:#{canonical_receipt.provider_event_id}"

      {stored_body, stored_headers} =
        receipt_evidence(provider, raw_body, headers, canonical_receipt)

      with {:ok, input} <-
             WebhookReceiptIngestInput.new(%{
               provider: provider,
               idempotency_key: idempotency_key,
               payload_sha256: sha256_hex(raw_body),
               verification_status: "verified",
               processing_status: "new",
               provider_event_id: canonical_receipt.provider_event_id,
               event_type: canonical_receipt.event_type,
               verified_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
               raw_body: stored_body,
               headers: stored_headers
             }) do
        PaymentsFacade.ingest_webhook_receipt_for_system(input)
      end
    end)
  end

  defp receipt_evidence(:paystack, _raw_body, _headers, canonical_receipt),
    do: {Jason.encode!(canonical_receipt.raw_payload), %{}}

  defp receipt_evidence(_provider, raw_body, headers, _canonical_receipt),
    do: {raw_body, headers}

  # A resend also repairs a receipt left without an Oban job by an interrupted handoff.
  defp enqueue_processing_job(
         %{
           receipt: %WebhookReceipt{provider: :paystack, processing_status: status} = receipt,
           duplicate?: true
         },
         event_type,
         route
       )
       when status != "processed" do
    enqueue_processing_job(%{receipt: receipt}, event_type, route)
  end

  defp enqueue_processing_job(%{receipt: receipt, duplicate?: true}, _event_type, route) do
    PaymentIngressTelemetry.capture_repo_stage(:enqueue, route, receipt.provider, fn ->
      {:ok, :duplicate}
    end)
  end

  defp enqueue_processing_job(%{receipt: receipt}, event_type, route) do
    worker = processing_worker(event_type)

    PaymentIngressTelemetry.capture_repo_stage(:enqueue, route, receipt.provider, fn ->
      %{"webhook_receipt_id" => receipt.id}
      |> worker.new(unique: @job_unique_opts)
      |> Oban.insert()
    end)
  end

  defp emit_webhook_received(provider, canonical_receipt, receipt_result, started_at) do
    PaymentIngressTelemetry.emit_webhook_received(
      :webhook,
      provider,
      canonical_receipt,
      receipt_result,
      started_at
    )
  end

  defp emit_webhook_enqueued(
         provider,
         canonical_receipt,
         receipt_result,
         enqueue_result,
         started_at
       ) do
    PaymentIngressTelemetry.emit_webhook_enqueued(
      :webhook,
      provider,
      canonical_receipt,
      receipt_result,
      enqueue_result,
      started_at
    )
  end

  defp processing_worker(event_type) when is_binary(event_type) do
    if refund_event_type?(event_type) do
      ProcessRefundWebhookReceiptWorker
    else
      ProcessWebhookReceiptWorker
    end
  end

  defp processing_worker(_event_type), do: ProcessWebhookReceiptWorker

  defp refund_event_type?(event_type) do
    String.starts_with?(event_type, "refund.") or event_type == "charge.refunded"
  end

  defp headers_to_map(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], fn values -> [value | values] end)
    end)
    |> Enum.into(%{}, fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  defp normalize_provider_param(provider) when is_binary(provider) do
    case Providers.normalize_provider(provider) do
      :unknown ->
        {:error,
         Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is unsupported", %{
           provider: provider,
           supported_providers: Providers.known_providers() |> Enum.map(&Atom.to_string/1)
         })}

      known ->
        if Providers.known_provider?(known) do
          {:ok, known}
        else
          {:error,
           Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is unsupported", %{
             provider: provider,
             supported_providers: Providers.known_providers() |> Enum.map(&Atom.to_string/1)
           })}
        end
    end
  end

  defp sha256_hex(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp telemetry_provider(provider) when is_binary(provider) do
    case Providers.normalize_provider(provider) do
      :unknown -> provider
      known -> known
    end
  end
end
