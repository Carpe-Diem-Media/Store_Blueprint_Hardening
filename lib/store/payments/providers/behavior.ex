defmodule Store.Payments.Providers.Behaviour do
  @moduledoc """
  Contract for payment-provider adapters.

  Adapters are boundary-only modules: they build/verify/normalize provider payloads
  and must not perform DB writes or domain state transitions.
  """

  alias Store.Payments.Types.CanonicalReceipt
  alias Store.Payments.Types.ProviderObservation
  alias Store.Payments.Types.RenewalCollectionChargeRequest

  @type capability_map :: %{
          optional(:supports_one_time_checkout?) => boolean(),
          optional(:supports_refunds?) => boolean(),
          optional(:supports_partial_refunds?) => boolean(),
          optional(:supports_tokenization?) => boolean(),
          optional(:supports_merchant_initiated_charges?) => boolean(),
          optional(:supports_provider_managed_subscriptions?) => boolean(),
          optional(:webhook_verification_mode) =>
            :offline_hmac | :remote_verify | :ip_allowlist_plus_signature,
          optional(:supports_webhooks?) => boolean(),
          optional(:supports_transaction_observation?) => boolean(),
          optional(:supports_same_request_replay?) => boolean(),
          optional(:supports_request_reference_observation?) => boolean()
        }

  @callback capabilities() :: capability_map()

  @callback create_intent(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @callback charge_off_session(RenewalCollectionChargeRequest.t() | map(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback renewal_collection_request_reference(String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback verify_webhook(map(), binary(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback normalize_webhook(map()) :: {:ok, CanonicalReceipt.t()} | :ignore | {:error, term()}

  @callback observe_payment(map(), keyword()) ::
              {:ok, ProviderObservation.t()} | {:error, term()}

  @callback classify_payment_finality(ProviderObservation.t()) ::
              :authoritative_success | :terminal_non_success | :non_terminal | :unknown
  @optional_callbacks classify_payment_finality: 1, renewal_collection_request_reference: 1
end
