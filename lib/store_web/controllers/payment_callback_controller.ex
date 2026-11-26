defmodule StoreWeb.PaymentCallbackController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.Providers
  alias Store.Support.Errors.Error
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
          |> put_status(:accepted)
          |> json(%{data: %{webhook_receipt_id: receipt_id}})

        PaymentIngressTelemetry.emit_response(
          :callback,
          normalized_provider,
          started_at,
          conn.status,
          :ok
        )

        conn

      {:error, normalized_provider, error} ->
        rendered = ErrorResponder.render(conn, error)

        PaymentIngressTelemetry.emit_response(
          :callback,
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
          :callback,
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
           verify_and_normalize(normalized_provider, headers, raw_body, :callback),
         {:ok, receipt_result} <-
           ingest_receipt(normalized_provider, raw_body, headers, canonical_receipt, :callback),
         :ok <-
           emit_webhook_received(
             normalized_provider,
             canonical_receipt,
             receipt_result,
             received_started_at
           ),
         enqueue_started_at = System.monotonic_time(),
         {:ok, enqueue_result} <- enqueue_processing_job(receipt_result, :callback),
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
      {:error, error} -> {:error, telemetry_provider, error}
      {:discard, reason} -> {:discard, telemetry_provider, reason}
    end
  end

  defp extract_raw_body(conn) do
    case conn.assigns[:raw_body] do
      raw_body when is_binary(raw_body) ->
        {:ok, raw_body, conn}

      _ ->
        {:error,
         Error.new(
           "PAYMENT_PAYLOAD_INVALID",
           "raw callback body was not captured; ensure Plug.Parsers body_reader is configured"
         )}
    end
  end

  defp verify_and_normalize(:paystack, _headers, _raw_body, _route) do
    {:error, Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "Paystack events use the webhook route")}
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
               raw_body: raw_body,
               headers: headers
             }) do
        PaymentsFacade.ingest_webhook_receipt_for_system(input)
      end
    end)
  end

  defp enqueue_processing_job(%{receipt: receipt, duplicate?: true}, route) do
    PaymentIngressTelemetry.capture_repo_stage(:enqueue, route, receipt.provider, fn ->
      {:ok, :duplicate}
    end)
  end

  defp enqueue_processing_job(%{receipt: receipt}, route) do
    PaymentIngressTelemetry.capture_repo_stage(:enqueue, route, receipt.provider, fn ->
      %{"webhook_receipt_id" => receipt.id}
      |> ProcessWebhookReceiptWorker.new(unique: @job_unique_opts)
      |> Oban.insert()
    end)
  end

  defp emit_webhook_received(provider, canonical_receipt, receipt_result, started_at) do
    PaymentIngressTelemetry.emit_webhook_received(
      :callback,
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
      :callback,
      provider,
      canonical_receipt,
      receipt_result,
      enqueue_result,
      started_at
    )
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
