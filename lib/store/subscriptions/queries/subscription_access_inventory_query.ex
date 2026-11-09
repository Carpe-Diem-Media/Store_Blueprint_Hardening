defmodule Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery do
  @moduledoc "Fixed UUID bounds for diagnostic Subscription authority inventory."

  import Ecto.Query

  alias Store.Subscriptions.{AccessEffect, Subscription}
  alias Store.Support.Errors.Error

  @enforce_keys [:through_id]
  defstruct [:through_id, :after_id, limit: 100]

  @type t :: %__MODULE__{
          through_id: Ecto.UUID.t(),
          after_id: Ecto.UUID.t() | nil,
          limit: pos_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{through_id: through_id} = attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in [:through_id, :after_id, :limit])),
         {:ok, upper} <- Ecto.UUID.cast(through_id),
         {:ok, after_id} <- optional_uuid(Map.get(attrs, :after_id)),
         limit <- Map.get(attrs, :limit, 100),
         true <- is_integer(limit) and limit in 1..500,
         true <- is_nil(after_id) or Ecto.UUID.dump!(after_id) <= Ecto.UUID.dump!(upper) do
      {:ok, %__MODULE__{through_id: upper, after_id: after_id, limit: limit}}
    else
      _ -> invalid()
    end
  end

  def new(_attrs), do: invalid()

  @doc false
  @spec to_ecto(t()) :: Ecto.Query.t()
  def to_ecto(%__MODULE__{} = query) do
    window =
      from source in Subscription,
        where: source.id <= ^query.through_id,
        order_by: [asc: source.id],
        limit: ^query.limit

    window =
      if query.after_id,
        do: where(window, [source], source.id > ^query.after_id),
        else: window

    effects =
      from effect in AccessEffect,
        where: effect.subscription_id == parent_as(:source).id,
        select: 1

    from source in subquery(window),
      as: :source,
      order_by: [asc: source.id],
      select: %{
        id: source.id,
        user_id: source.user_id,
        aggregate_version: source.aggregate_version,
        source_order_line_item_id: source.source_order_line_item_id,
        current_contract_change_id: source.current_contract_change_id,
        current_plan_revision_id: source.current_plan_revision_id,
        has_access_effect?: exists(subquery(effects))
      }
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(id), do: Ecto.UUID.cast(id)

  defp invalid do
    {:error, Error.new("VALIDATION_ERROR", "invalid subscription authority inventory bounds")}
  end
end
