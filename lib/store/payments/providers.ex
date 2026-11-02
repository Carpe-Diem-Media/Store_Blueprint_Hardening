defmodule Store.Payments.Providers do
  @moduledoc """
  Provider adapter resolver and boundary wrapper.

  Resolution is fail-closed: unknown providers are rejected and never routed
  to an implicit fallback adapter.
  """

  alias Store.Payments.Providers.{PayFast, Paystack, PeachPayments, Stripe, Yoco}
  alias Store.Payments.Types.{ProviderObservation, RenewalCollectionChargeRequest}
  alias Store.Support.Errors.Error

  @type known_provider :: :stripe | :payfast | :paystack | :yoco | :peach_payments
  @type normalized_provider :: known_provider() | :unknown
  @type provider :: known_provider() | String.t()
  @type enabled_provider_config :: [provider()] | String.t() | nil
  @type fault_mode :: :none | :slow | :timeout | :error | :crash

  @known_providers [:stripe, :payfast, :paystack, :yoco, :peach_payments]

  @provider_aliases %{
    "stripe" => :stripe,
    "payfast" => :payfast,
    "paystack" => :paystack,
    "yoco" => :yoco,
    "peach" => :peach_payments,
    "peach_payments" => :peach_payments,
    "peach-payments" => :peach_payments
  }

  @spec known_providers() :: [known_provider()]
  def known_providers do
    Enum.map(@known_providers, & &1)
  end

  @spec known_provider?(term()) :: boolean()
  def known_provider?(provider), do: provider in @known_providers

  @spec adapter(provider()) :: {:ok, module()} | {:error, Error.t()}
  def adapter(provider) do
    case normalize_provider(provider) do
      :stripe -> {:ok, Stripe}
      :payfast -> {:ok, PayFast}
      :paystack -> {:ok, Paystack}
      :yoco -> {:ok, Yoco}
      :peach_payments -> {:ok, PeachPayments}
      :unknown -> {:error, unsupported_provider_error(provider)}
    end
  end

  @spec capabilities(provider()) :: map() | {:error, Error.t()}
  def capabilities(provider) do
    case adapter(provider) do
      {:ok, module} -> module.capabilities()
      {:error, error} -> {:error, error}
    end
  end

  @spec renewal_collection_request_reference(provider(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def renewal_collection_request_reference(provider, collection_attempt_id)
      when is_binary(collection_attempt_id) do
    with {:ok, module} <- adapter(provider),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :renewal_collection_request_reference, 1) do
      module.renewal_collection_request_reference(collection_attempt_id)
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_UNSUPPORTED",
           "provider does not define a renewal collection request reference"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  def renewal_collection_request_reference(_provider, _collection_attempt_id) do
    {:error, Error.new("VALIDATION_ERROR", "renewal collection identity must be a UUID")}
  end

  @spec expected_environment(provider()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def expected_environment(provider) do
    with {:ok, module} <- adapter(provider) do
      if Code.ensure_loaded?(module) and function_exported?(module, :expected_environment, 0) do
        module.expected_environment()
      else
        {:ok, nil}
      end
    end
  end

  @spec observe_payment(provider(), map(), keyword()) ::
          {:ok, Store.Payments.Types.ProviderObservation.t()} | {:error, term()}
  def observe_payment(provider, identity, opts \\ [])
      when is_map(identity) and is_list(opts) do
    with {:ok, module} <- adapter(provider),
         capabilities <- module.capabilities(),
         true <- Map.get(capabilities, :supports_transaction_observation?, false),
         true <-
           Map.get(identity, :provider_reference_kind) != :transaction_reference or
             Map.get(capabilities, :supports_request_reference_observation?, false) do
      module.observe_payment(identity, opts)
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED",
           "provider observation is unsupported",
           %{
             provider: normalize_provider(provider) |> Atom.to_string()
           }
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec classify_payment_finality(provider(), ProviderObservation.t()) ::
          :authoritative_success | :terminal_non_success | :non_terminal | :unknown
  def classify_payment_finality(provider, %ProviderObservation{} = observation) do
    with {:ok, module} <- adapter(provider),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :classify_payment_finality, 1) do
      module.classify_payment_finality(observation)
    else
      _ -> :unknown
    end
  end

  @spec create_intent(provider(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_intent(provider, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, module} <- adapter(provider) do
      maybe_inject_create_intent(provider, module, attrs, opts)
    end
  end

  @spec charge_off_session(
          provider(),
          RenewalCollectionChargeRequest.t() | map(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def charge_off_session(provider, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, module} <- adapter(provider) do
      module.charge_off_session(attrs, opts)
    end
  end

  @spec verify_webhook(provider(), map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_webhook(provider, headers, raw_body, opts \\ [])
      when is_map(headers) and is_binary(raw_body) and is_list(opts) do
    with {:ok, module} <- adapter(provider) do
      module.verify_webhook(headers, raw_body, opts)
    end
  end

  @spec normalize_webhook(provider(), map()) :: {:ok, term()} | {:error, term()}
  def normalize_webhook(provider, payload) when is_map(payload) do
    with {:ok, module} <- adapter(provider) do
      module.normalize_webhook(payload)
    end
  end

  @spec normalize_provider(provider()) :: normalized_provider()
  def normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  def normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@provider_aliases, &1, :unknown))
  end

  def normalize_provider(_provider), do: :unknown

  @spec normalize_enabled_providers(enabled_provider_config()) ::
          {:ok, [known_provider()]} | {:error, Error.t()}
  def normalize_enabled_providers(nil), do: {:ok, []}

  def normalize_enabled_providers(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> normalize_enabled_provider_list()
  end

  def normalize_enabled_providers(value) when is_list(value),
    do: normalize_enabled_provider_list(value)

  def normalize_enabled_providers(_value) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "enabled payment providers config must be a comma-separated string or list"
     )}
  end

  @spec enabled_providers() :: [known_provider()]
  def enabled_providers do
    config_value =
      :store
      |> Application.get_env(:payments, [])
      |> Keyword.get(:enabled_providers, [])

    case normalize_enabled_providers(config_value) do
      {:ok, providers} -> providers
      {:error, _error} -> []
    end
  end

  @spec default_purchase_provider_for_ui() :: known_provider() | nil
  def default_purchase_provider_for_ui do
    configured =
      :store
      |> Application.get_env(:payments, [])
      |> Keyword.get(:default_purchase_provider_for_ui)

    enabled = enabled_providers()

    case normalize_provider(configured) do
      known when known in @known_providers ->
        if known in enabled, do: known, else: nil

      _ ->
        nil
    end
  end

  @spec ensure_enabled_provider(known_provider()) :: :ok | {:error, Error.t()}
  def ensure_enabled_provider(provider) when provider in @known_providers do
    if provider in enabled_providers() do
      :ok
    else
      {:error,
       Error.new("PAYMENT_PROVIDER_DISABLED", "payment provider is disabled", %{
         provider: Atom.to_string(provider),
         enabled_providers: supported_enabled_providers()
       })}
    end
  end

  def ensure_enabled_provider(provider), do: {:error, unsupported_provider_error(provider)}

  @spec selection_required_error() :: Error.t()
  def selection_required_error do
    Error.new("PAYMENT_PROVIDER_SELECTION_REQUIRED", "payment provider selection is required", %{
      supported_providers: supported_providers()
    })
  end

  defp unsupported_provider_error(provider) do
    Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "unsupported payment provider", %{
      provider: provider_metadata(provider),
      supported_providers: supported_providers()
    })
  end

  defp maybe_inject_create_intent(provider, module, attrs, opts) do
    case fault_injection_config(provider) do
      %{mode: :none} ->
        module.create_intent(attrs, opts)

      %{mode: :slow, delay_ms: delay_ms} = config ->
        notify_fault_hook(config, :slow)
        Process.sleep(delay_ms)
        module.create_intent(attrs, opts)

      %{mode: :timeout, delay_ms: delay_ms} = config ->
        notify_fault_hook(config, :timeout)
        Process.sleep(delay_ms)

        {:error,
         Error.new("PAYMENT_PROVIDER_TIMEOUT", "payment provider timed out", %{
           provider: provider_metadata(provider),
           delay_ms: delay_ms
         })}

      %{mode: :error, delay_ms: delay_ms} = config ->
        notify_fault_hook(config, :error)

        if delay_ms > 0 do
          Process.sleep(delay_ms)
        end

        {:error,
         Error.new("PAYMENT_PROVIDER_DOWN", "payment provider is unavailable", %{
           provider: provider_metadata(provider),
           delay_ms: delay_ms
         })}

      %{mode: :crash, delay_ms: delay_ms} = config ->
        notify_fault_hook(config, :crash)

        if delay_ms > 0 do
          Process.sleep(delay_ms)
        end

        exit({:payment_provider_fault, normalize_provider(provider), :crash})
    end
  end

  defp fault_injection_config(provider) do
    if Mix.env() == :test do
      config =
        Application.get_env(:store, :payment_provider_fault_injection, [])
        |> Enum.into(%{})

      configured_provider = Map.get(config, :provider)

      if fault_injection_enabled_for_provider?(configured_provider, provider) do
        %{
          mode: normalize_fault_mode(Map.get(config, :mode)),
          delay_ms: normalize_delay_ms(Map.get(config, :delay_ms, 0)),
          notify_pid: Map.get(config, :notify_pid),
          notify_ref: Map.get(config, :notify_ref)
        }
      else
        %{mode: :none, delay_ms: 0, notify_pid: nil, notify_ref: nil}
      end
    else
      %{mode: :none, delay_ms: 0, notify_pid: nil, notify_ref: nil}
    end
  end

  defp fault_injection_enabled_for_provider?(nil, _provider), do: true

  defp fault_injection_enabled_for_provider?(configured_provider, provider) do
    normalize_provider(configured_provider) == normalize_provider(provider)
  end

  defp normalize_fault_mode(mode) when mode in [:slow, :timeout, :error, :crash], do: mode
  defp normalize_fault_mode("slow"), do: :slow
  defp normalize_fault_mode("timeout"), do: :timeout
  defp normalize_fault_mode("error"), do: :error
  defp normalize_fault_mode("crash"), do: :crash
  defp normalize_fault_mode(_mode), do: :none

  defp normalize_delay_ms(value) when is_integer(value), do: max(value, 0)
  defp normalize_delay_ms(_value), do: 0

  defp notify_fault_hook(%{notify_pid: pid, notify_ref: ref}, mode)
       when is_pid(pid) and not is_nil(ref) do
    send(pid, {:payment_provider_fault, mode, :entered, ref})
  end

  defp notify_fault_hook(_config, _mode), do: :ok

  defp normalize_enabled_provider_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_provider(value) do
        known when known in @known_providers ->
          {:cont, {:ok, [known | acc]}}

        :unknown ->
          {:halt,
           {:error,
            Error.new(
              "PAYMENT_PROVIDER_UNSUPPORTED",
              "enabled payment provider is unsupported",
              %{
                provider: provider_metadata(value),
                supported_providers: supported_providers()
              }
            )}}
      end
    end)
    |> case do
      {:ok, providers} ->
        {:ok, providers |> Enum.reverse() |> Enum.uniq()}

      {:error, error} ->
        {:error, error}
    end
  end

  defp supported_providers do
    Enum.map(@known_providers, &Atom.to_string/1)
  end

  defp supported_enabled_providers do
    enabled_providers()
    |> Enum.map(&Atom.to_string/1)
  end

  defp provider_metadata(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_metadata(provider) when is_binary(provider), do: String.trim(provider)
  defp provider_metadata(provider), do: inspect(provider)
end
