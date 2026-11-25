defmodule Store.Payments.Providers.Paystack.Webhook do
  @moduledoc false

  alias Store.Payments.Providers.Paystack.Response
  alias Store.Payments.Types.CanonicalReceipt
  alias Store.Support.Errors.Error

  @clock_tolerance 300
  @event_fields ~w(id reference amount currency status domain)

  @spec verify(map(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify(headers, raw_body, opts) do
    config = Application.get_env(:store, :payments, [])[:paystack] || []
    secrets = Keyword.get(opts, :signing_secrets, [config[:webhook_signing_secret]])
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, secrets} <- configured_secrets(secrets),
         {:ok, header} <- signature_header(Map.get(headers, "paystack-signature")),
         {:ok, timestamp, signatures} <- parse_header(header),
         :ok <- validate_signature(timestamp, signatures, raw_body, secrets, now) do
      case Jason.decode(raw_body) do
        {:ok, payload} when is_map(payload) -> {:ok, payload}
        _ -> invalid_payload()
      end
    end
  end

  @spec normalize(map()) :: {:ok, CanonicalReceipt.t()} | :ignore | {:error, Error.t()}
  def normalize(%{"event" => "charge.success", "data" => %{"reference" => reference} = data})
      when is_binary(reference) do
    if reference =~ ~r/\Acheckout-[a-f0-9]{32}\z/ do
      normalize_checkout(Map.take(data, @event_fields))
    else
      :ignore
    end
  end

  def normalize(%{"event" => event}) when is_binary(event) and event != "charge.success",
    do: :ignore

  def normalize(_payload), do: invalid_payload()

  defp normalize_checkout(data) do
    case Response.decode(:verify, {:ok, 200, %{"status" => true, "data" => data}}) do
      %{
        outcome: :success_observation,
        transaction: %{environment: "test", currency: "ZAR"} = transaction
      } ->
        {:ok,
         %CanonicalReceipt{
           provider: "paystack",
           provider_event_id: "charge.success:" <> transaction.id,
           provider_payment_id: transaction.id,
           provider_request_reference: transaction.reference,
           provider_environment: transaction.environment,
           event_type: "charge.success",
           amount_minor: transaction.amount_minor,
           currency: transaction.currency,
           status: :succeeded,
           raw_provider_status: "success",
           occurred_at: nil,
           raw_payload: %{"event" => "charge.success", "data" => data}
         }}

      _ ->
        invalid_payload()
    end
  end

  defp configured_secrets(secrets) do
    case Enum.filter(secrets, &valid_secret?/1) do
      [] ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_VERIFICATION_FAILED",
           "Paystack sandbox webhook signing credentials are unavailable"
         )}

      configured ->
        {:ok, configured}
    end
  end

  defp valid_secret?("whsec_" <> suffix), do: byte_size(suffix) > 0
  defp valid_secret?(_secret), do: false

  defp signature_header(nil),
    do: {:error, Error.new("PAYMENT_SIGNATURE_MISSING", "Paystack signature is missing")}

  defp signature_header([header]) when is_binary(header) and byte_size(header) <= 4096,
    do: {:ok, header}

  defp signature_header(_header), do: invalid_signature()

  defp parse_header(header) do
    {timestamps, signatures} =
      header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({[], []}, &parse_signature_field/2)

    case {timestamps, signatures} do
      {[timestamp], [_ | _]} -> {:ok, timestamp, signatures}
      _ -> invalid_signature()
    end
  end

  defp parse_signature_field("t=" <> timestamp, {timestamps, signatures}),
    do: {[timestamp | timestamps], signatures}

  defp parse_signature_field("v1=whk_" <> field, {timestamps, signatures} = parsed) do
    with [key_id, hex] <- String.split(field, ":", parts: 2),
         true <- byte_size(key_id) > 0 and byte_size(hex) == 128,
         {:ok, signature} <- Base.decode16(hex, case: :lower) do
      {timestamps, [signature | signatures]}
    else
      _ -> parsed
    end
  end

  defp parse_signature_field(_field, parsed), do: parsed

  defp validate_signature(timestamp, signatures, raw_body, secrets, now) do
    with true <- timestamp =~ ~r/\A[0-9]{1,12}\z/,
         {signed_at, ""} <- Integer.parse(timestamp),
         true <- abs(now - signed_at) <= @clock_tolerance,
         true <- signature_matches?(secrets, signatures, [timestamp, ".", raw_body]) do
      :ok
    else
      _ -> invalid_signature()
    end
  end

  defp signature_matches?(secrets, signatures, signed_payload) do
    Enum.any?(secrets, fn secret ->
      expected = :crypto.mac(:hmac, :sha512, secret, signed_payload)
      Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected))
    end)
  end

  defp invalid_signature,
    do: {:error, Error.new("PAYMENT_SIGNATURE_INVALID", "Paystack signature is invalid")}

  defp invalid_payload,
    do: {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "Paystack webhook payload is invalid")}
end
