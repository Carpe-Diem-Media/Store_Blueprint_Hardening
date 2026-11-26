defmodule Store.Checkout.Inputs.CheckoutFinalizeInput do
  @moduledoc """
  Typed input contract for checkout totals finalization.
  """

  alias Store.Support.Errors.Error

  defstruct [:billing_country_code, :billing_region_code]

  @type t :: %__MODULE__{
          billing_country_code: String.t() | nil,
          billing_region_code: String.t() | nil
        }

  @allowed_keys [
    :billing_country_code,
    :billing_region_code,
    "billing_country_code",
    "billing_region_code"
  ]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    case Map.keys(params) -- @allowed_keys do
      [] ->
        with {:ok, country} <- location_code(params, :billing_country_code, ~r/\A[A-Z]{2}\z/),
             {:ok, region} <- location_code(params, :billing_region_code, ~r/\A[A-Z0-9-]{1,12}\z/) do
          {:ok, %__MODULE__{billing_country_code: country, billing_region_code: region}}
        end

      keys ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "unknown params: #{Enum.map_join(keys, ", ", &to_string/1)}"
         )}
    end
  end

  def new(_params), do: {:error, Error.new("VALIDATION_ERROR", "params must be a map")}

  defp location_code(params, key, pattern) do
    case Map.get(params, key, Map.get(params, Atom.to_string(key))) do
      value when value in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.upcase()

        if String.match?(normalized, pattern),
          do: {:ok, normalized},
          else: invalid_location()

      _ ->
        invalid_location()
    end
  end

  defp invalid_location, do: {:error, Error.new("INVALID_ADDRESS", "Invalid billing location")}
end
