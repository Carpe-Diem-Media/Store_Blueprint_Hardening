defmodule Store.Payments.Providers.Paystack do
  @moduledoc """
  Paystack provider boundary adapter.

  Capabilities are conservative by default and explicit gating prevents
  unsupported recurring behavior from being enabled accidentally.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Payments.Providers.Paystack.{Response, Webhook}
  alias Store.Payments.Types.ProviderObservation
  alias Store.Support.Errors.Error
  alias Store.Support.HTTP.ReqClient

  @api_url "https://api.paystack.co"
  @environment "test"

  @doc """
  Decodes a Paystack API response into an observation or a customer-safe error.

  Diagnostics contain allowlisted provider values for operator use. A success
  observation still needs Store target validation before payment application.
  Recovery describes the next check for the existing attempt.
  """
  @spec decode_response(Response.operation(), Response.response()) :: Response.result()
  defdelegate decode_response(operation, response), to: Response, as: :decode

  @impl true
  def capabilities do
    %{
      supports_one_time_checkout?: true,
      supports_refunds?: true,
      supports_partial_refunds?: true,
      supports_tokenization?: false,
      supports_merchant_initiated_charges?: false,
      supports_provider_managed_subscriptions?: false,
      supports_same_request_replay?: false,
      supports_transaction_observation?: true,
      supports_request_reference_observation?: true,
      webhook_verification_mode: :offline_hmac,
      supports_webhooks?: true
    }
  end

  @impl true
  def renewal_collection_request_reference(collection_attempt_id)
      when is_binary(collection_attempt_id) do
    case Ecto.UUID.cast(collection_attempt_id) do
      {:ok, uuid} ->
        {:ok, "renewal-" <> String.replace(uuid, "-", "")}

      :error ->
        {:error, Error.new("VALIDATION_ERROR", "renewal collection identity must be a UUID")}
    end
  end

  def renewal_collection_request_reference(_collection_attempt_id) do
    {:error, Error.new("VALIDATION_ERROR", "renewal collection identity must be a UUID")}
  end

  @doc "Returns the provider environment accepted by the sandbox checkout adapter."
  @spec expected_environment() :: {:ok, String.t()}
  def expected_environment, do: {:ok, @environment}

  @impl true
  def observe_payment(
        %{provider_reference_kind: :transaction_reference, provider_reference: reference},
        opts
      ) do
    with :ok <- validate_reference(reference),
         {:ok, response} <- request(:verify, :get, "/transaction/verify/" <> reference, [], opts) do
      observation(response, reference)
    end
  end

  def observe_payment(_identity, _opts) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED",
       "Paystack verification requires a transaction reference"
     )}
  end

  @impl true
  def classify_payment_finality(%ProviderObservation{
        provider: :paystack,
        provider_environment: @environment,
        observation_source: :verification,
        raw_provider_status: "success",
        normalized_outcome: :authoritative_success
      }),
      do: :authoritative_success

  def classify_payment_finality(%ProviderObservation{
        provider: :paystack,
        provider_environment: @environment,
        observation_source: :verification,
        normalized_outcome: outcome
      })
      when outcome in [:failure_observation, :unresolved],
      do: :non_terminal

  def classify_payment_finality(%ProviderObservation{}), do: :unknown

  @impl true
  def create_intent(%{checkout_mode: :payment} = attrs, opts) do
    with {:ok, payload} <- checkout_payload(attrs),
         {:ok, response} <-
           request(:initialize, :post, "/transaction/initialize", [json: payload], opts) do
      checkout_result(response, payload.reference)
    end
  end

  def create_intent(_attrs, _opts) do
    {:error,
     Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "Paystack supports one-time checkout only")}
  end

  @impl true
  def charge_off_session(_attrs, _opts) do
    {:error, Error.new("PAYMENT_PROVIDER_DISABLED", "paystack recurring charges are disabled")}
  end

  @impl true
  defdelegate verify_webhook(headers, raw_body, opts), to: Webhook, as: :verify

  @impl true
  defdelegate normalize_webhook(payload), to: Webhook, as: :normalize

  defp checkout_payload(
         %{
           amount_minor: amount,
           currency: "ZAR",
           provider_request_reference: reference,
           customer_email: email,
           return_url: return_url
         } = attrs
       )
       when is_integer(amount) and amount > 0 and is_binary(email) and byte_size(email) > 0 and
              is_binary(return_url) and byte_size(return_url) > 0 do
    with false <- Map.get(attrs, :has_subscription_lines?, false),
         :ok <- validate_reference(reference) do
      {:ok,
       %{
         amount: amount,
         currency: "ZAR",
         reference: reference,
         email: email,
         channels: ["card"],
         callback_url: return_url
       }}
    else
      true ->
        {:error,
         Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "Paystack subscription checkout is disabled")}

      {:error, _} = error ->
        error
    end
  end

  defp checkout_payload(_attrs) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "Paystack checkout requires a positive ZAR amount and payer email"
     )}
  end

  defp checkout_result(%{checkout: %{reference: reference, authorization_url: url}}, reference),
    do: {:ok, %{provider: :paystack, provider_checkout_url: url}}

  defp checkout_result(%{error: %Error{} = error}, _reference), do: {:error, error}

  defp checkout_result(_response, _reference) do
    {:error, Error.new("PAYMENT_OUTCOME_UNRESOLVED", "We are checking the payment status.")}
  end

  defp observation(
         %{transaction: %{reference: reference, environment: @environment} = txn} = result,
         reference
       ) do
    {:ok,
     %ProviderObservation{
       provider: :paystack,
       provider_reference: reference,
       provider_reference_kind: :transaction_reference,
       provider_transaction_id: txn.id,
       observation_source: :verification,
       normalized_outcome: observation_outcome(result.outcome),
       raw_provider_status: provider_status(result.diagnostics.transaction_status),
       amount_minor: txn.amount_minor,
       currency: txn.currency,
       provider_environment: txn.environment,
       observed_at: DateTime.utc_now(),
       metadata: %{
         diagnostics: result.diagnostics,
         feedback: result.error,
         recovery: result.recovery
       }
     }}
  end

  defp observation(%{transaction: _}, _reference) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "Paystack verification returned a different reference or environment"
     )}
  end

  defp observation(%{error: %Error{} = error}, _reference), do: {:error, error}

  defp observation_outcome(:success_observation), do: :authoritative_success
  defp observation_outcome(:failure_observation), do: :failure_observation
  defp observation_outcome(:reversal_observation), do: :reversal_observation
  defp observation_outcome(_outcome), do: :unresolved

  defp provider_status(status) when is_binary(status), do: status
  defp provider_status(_status), do: "unknown"

  defp validate_reference(reference) when is_binary(reference) do
    if reference =~ ~r/\A[A-Za-z0-9][A-Za-z0-9.=-]{0,127}\z/ do
      :ok
    else
      validate_reference(nil)
    end
  end

  defp validate_reference(_reference),
    do: {:error, Error.new("VALIDATION_ERROR", "Paystack transaction reference is invalid")}

  defp request(operation, method, path, payload, opts) do
    config = Keyword.merge(Application.get_env(:store, :payments, [])[:paystack] || [], opts)

    with {:ok, key} <- restricted_key(config[:restricted_key]) do
      options =
        Keyword.merge(
          Keyword.get(config, :request_options, []),
          [
            url: @api_url <> path,
            headers: [{"authorization", "Bearer " <> key}],
            retry: false,
            redirect: false
          ] ++ payload
        )

      started_at = System.monotonic_time()
      result = decode_response(operation, transport_response(ReqClient.request(method, options)))

      :telemetry.execute(
        [:store, :payments, :paystack, :response],
        %{duration: System.monotonic_time() - started_at},
        Map.merge(result.diagnostics, %{
          operation: operation,
          outcome: result.outcome,
          recovery: result.recovery
        })
      )

      {:ok, result}
    end
  end

  defp restricted_key("rk_test_" <> suffix = key) when byte_size(suffix) > 0 do
    if suffix =~ ~r/\A[A-Za-z0-9_-]+\z/, do: {:ok, key}, else: restricted_key(nil)
  end

  defp restricted_key(_key),
    do:
      {:error,
       Error.new("PAYMENT_PROVIDER_DISABLED", "Paystack sandbox credentials are unavailable")}

  defp transport_response({:ok, %{status: status, body: body}}), do: {:ok, status, body}
  defp transport_response({:error, %{reason: :timeout}}), do: {:error, :timeout}
  defp transport_response({:error, _reason}), do: {:error, :connection}
end
