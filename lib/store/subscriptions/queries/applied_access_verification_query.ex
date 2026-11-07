defmodule Store.Subscriptions.Queries.AppliedAccessVerificationQuery do
  @moduledoc false

  import Ecto.Query

  alias Store.Subscriptions.{AccessEffect, PlanRevision, Subscription}

  alias Store.Support.Errors.Error

  @allowed_keys [:as_of, :after_inserted_at, :after_id, :limit]
  @max_limit 500

  @enforce_keys [:as_of]
  defstruct [:as_of, :after_inserted_at, :after_id, limit: 100]

  @type t :: %__MODULE__{
          as_of: DateTime.t(),
          after_inserted_at: DateTime.t() | nil,
          after_id: Ecto.UUID.t() | nil,
          limit: pos_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{as_of: %DateTime{} = as_of} = params) do
    with :ok <- validate_keys(params),
         {:ok, limit} <- validate_limit(Map.get(params, :limit, 100)),
         {:ok, after_inserted_at, after_id} <- validate_cursor(params, as_of) do
      {:ok,
       %__MODULE__{
         as_of: utc_microseconds(as_of),
         after_inserted_at: after_inserted_at,
         after_id: after_id,
         limit: limit
       }}
    end
  end

  def new(_params), do: invalid_query()

  @doc false
  @spec to_ecto(t()) :: Ecto.Query.t()
  def to_ecto(%__MODULE__{} = query) do
    window =
      from effect in AccessEffect,
        where: fragment("? = 'applied'", effect.status) and effect.inserted_at <= ^query.as_of,
        order_by: [asc: effect.inserted_at, asc: effect.id],
        limit: ^query.limit

    window = maybe_after(window, query.after_inserted_at, query.after_id)

    newer_effect =
      from newer in AccessEffect,
        where:
          newer.subscription_id == parent_as(:effect).subscription_id and
            newer.source_version > parent_as(:effect).source_version,
        select: 1

    from effect in subquery(window),
      as: :effect,
      join: source in Subscription,
      on: source.id == effect.subscription_id,
      left_join: revision in PlanRevision,
      on: revision.id == source.current_plan_revision_id,
      order_by: [asc: effect.inserted_at, asc: effect.id],
      select: %{
        effect: effect,
        current?: not exists(subquery(newer_effect)),
        source: %{
          subscription_id: source.id,
          user_id: source.user_id,
          aggregate_version: source.aggregate_version,
          source_order_line_item_id: source.source_order_line_item_id,
          current_contract_change_id: source.current_contract_change_id,
          current_plan_revision_id: source.current_plan_revision_id
        },
        revision: %{
          id: revision.id,
          entitlement_kind: revision.entitlement_kind,
          entitlement_scope_key: revision.entitlement_scope_key
        }
      }
  end

  defp maybe_after(query, nil, nil), do: query

  defp maybe_after(query, inserted_at, id) do
    where(
      query,
      [effect],
      effect.inserted_at > ^inserted_at or
        (effect.inserted_at == ^inserted_at and effect.id > ^id)
    )
  end

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &(&1 in @allowed_keys)), do: :ok, else: invalid_query()
  end

  defp validate_limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, limit}
  defp validate_limit(_limit), do: invalid_query()

  defp validate_cursor(params, as_of) do
    case {Map.get(params, :after_inserted_at), Map.get(params, :after_id)} do
      {nil, nil} ->
        {:ok, nil, nil}

      {%DateTime{} = inserted_at, id} when is_binary(id) ->
        with {:ok, canonical_id} <- Ecto.UUID.cast(id),
             inserted_at <- utc_microseconds(inserted_at),
             true <- DateTime.compare(inserted_at, utc_microseconds(as_of)) != :gt do
          {:ok, inserted_at, canonical_id}
        else
          _ -> invalid_query()
        end

      _ ->
        invalid_query()
    end
  end

  defp utc_microseconds(datetime) do
    datetime |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)
  end

  defp invalid_query do
    {:error, Error.new("VALIDATION_ERROR", "invalid APPLIED verification query")}
  end
end
