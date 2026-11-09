defmodule Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput do
  @moduledoc """
  Identifies a Subscription whose durable AccessEffect authority should be reconciled.
  """

  alias Store.Support.Errors.Error

  @enforce_keys [:subscription_id]
  defstruct [:subscription_id, expected_access_effect_id: nil]

  @type t :: %__MODULE__{
          subscription_id: Ecto.UUID.t(),
          expected_access_effect_id: Ecto.UUID.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    allowed = [:subscription_id, :expected_access_effect_id]

    with true <- Enum.all?(Map.keys(params), &(&1 in allowed)),
         {:ok, subscription_id} <- uuid(value(params, :subscription_id)),
         {:ok, expected_id} <- optional_uuid(value(params, :expected_access_effect_id)) do
      {:ok, %__MODULE__{subscription_id: subscription_id, expected_access_effect_id: expected_id}}
    else
      _ -> invalid()
    end
  end

  def new(_params), do: invalid()

  defp value(params, key), do: Map.get(params, key)
  defp uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp uuid(_value), do: :error
  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: uuid(value)

  defp invalid do
    {:error, Error.new("VALIDATION_ERROR", "invalid source reconciliation identity")}
  end
end
