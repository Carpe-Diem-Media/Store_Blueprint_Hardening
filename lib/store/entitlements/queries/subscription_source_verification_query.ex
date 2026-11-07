defmodule Store.Entitlements.Queries.SubscriptionSourceVerificationQuery do
  @moduledoc false

  import Ecto.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Support.Errors.Error

  @allowed_keys [:source_ids]
  @fields [
    :id,
    :user_id,
    :kind,
    :scope_key,
    :source_kind,
    :source_id,
    :status,
    :valid_from_at,
    :valid_to_at,
    :revoked_at,
    :revoked_reason
  ]

  @enforce_keys [:source_ids]
  defstruct [:source_ids]

  @type t :: %__MODULE__{source_ids: [Ecto.UUID.t()]}

  @spec new(map()) :: {:ok, t()} | {:error, Store.Support.Errors.Error.t()}
  def new(%{source_ids: source_ids} = params)
      when is_list(source_ids) and length(source_ids) <= 500 do
    with true <- Enum.all?(Map.keys(params), &(&1 in @allowed_keys)),
         {:ok, canonical_ids} <- cast_ids(source_ids) do
      {:ok, %__MODULE__{source_ids: Enum.uniq(canonical_ids)}}
    else
      _ -> invalid_query()
    end
  end

  def new(_params), do: invalid_query()

  @doc false
  @spec to_ecto(t()) :: Ecto.Query.t()
  def to_ecto(%__MODULE__{source_ids: source_ids}) do
    grants =
      from grant in EntitlementGrant,
        where:
          fragment("? = 'subscription' AND ? = 'active'", grant.source_kind, grant.status) and
            grant.source_id == type(parent_as(:requested).id, Ecto.UUID),
        order_by: [asc: grant.id],
        limit: 2,
        select: map(grant, ^@fields)

    from requested in fragment(
           "SELECT unnest(?::uuid[]) AS id",
           type(^source_ids, {:array, Ecto.UUID})
         ),
         as: :requested,
         inner_lateral_join: grant in subquery(grants),
         on: true,
         select: grant
  end

  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, canonical_id} -> {:cont, {:ok, [canonical_id | acc]}}
        :error -> {:halt, invalid_query()}
      end
    end)
    |> case do
      {:ok, casted} -> {:ok, Enum.reverse(casted)}
      error -> error
    end
  end

  defp invalid_query do
    {:error, Error.new("VALIDATION_ERROR", "invalid subscription source verification query")}
  end
end
