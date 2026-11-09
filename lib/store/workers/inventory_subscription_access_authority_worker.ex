defmodule Store.Workers.InventorySubscriptionAccessAuthorityWorker do
  @moduledoc "Reports missing persisted authority in bounded Subscription inventory pages."

  use Oban.Worker,
    queue: :ops,
    priority: 3,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args], states: :incomplete]

  require Logger

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery

  @allowed_args ["through_id", "after_id", "limit"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    if Enum.all?(Map.keys(args), &(&1 in @allowed_args)),
      do: perform_args(args),
      else: {:discard, "invalid subscription authority inventory arguments"}
  end

  def perform(_job), do: {:discard, "invalid subscription authority inventory job"}

  defp perform_args(args) do
    case parse_query(args) do
      {:empty, _} ->
        report([])
        :ok

      {:ok, query} ->
        run_page(query)

      {:discard, _reason} = discard ->
        discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_page(query) do
    case SubscriptionsFacade.list_subscription_access_inventory_window_for_system(query) do
      {:ok, rows} ->
        report(rows)
        enqueue_next_page(rows, query)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_query(args) do
    cond do
      not valid_limit?(Map.get(args, "limit", 100)) ->
        {:discard, "invalid subscription authority inventory bounds"}

      Map.has_key?(args, "after_id") and not is_binary(args["after_id"]) ->
        {:discard, "invalid subscription authority inventory bounds"}

      cursor_supplied?(args) and not Map.has_key?(args, "through_id") ->
        {:discard, "inventory cursor requires a fixed upper bound"}

      cursor_supplied?(args) and not Map.has_key?(args, "limit") ->
        {:discard, "inventory cursor requires its page limit"}

      true ->
        parse_bounded_query(args)
    end
  end

  defp parse_bounded_query(args) do
    case parse_upper_bound(args) do
      {:ok, nil} -> {:empty, nil}
      {:ok, through_id} -> build_query(args, through_id)
      {:error, reason} -> {:error, reason}
      _ -> {:discard, "invalid subscription authority inventory bounds"}
    end
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit in 1..500

  defp cursor_supplied?(args), do: Map.has_key?(args, "after_id") and not is_nil(args["after_id"])

  defp build_query(args, through_id) do
    with after_id when is_nil(after_id) or is_binary(after_id) <- Map.get(args, "after_id"),
         {:ok, query} <-
           SubscriptionAccessInventoryQuery.new(%{
             through_id: through_id,
             after_id: after_id,
             limit: Map.get(args, "limit", 100)
           }) do
      {:ok, query}
    else
      {:error, %Store.Support.Errors.Error{code: "VALIDATION_ERROR"}} ->
        {:discard, "invalid subscription authority inventory bounds"}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:discard, "invalid subscription authority inventory bounds"}
    end
  end

  defp parse_upper_bound(args) do
    case Map.fetch(args, "through_id") do
      :error -> SubscriptionsFacade.subscription_access_inventory_upper_bound_for_system()
      {:ok, value} when is_binary(value) -> Ecto.UUID.cast(value)
      _ -> :error
    end
  end

  defp enqueue_next_page(rows, query) when length(rows) == query.limit do
    last = List.last(rows)

    %{
      "through_id" => query.through_id,
      "after_id" => last.id,
      "limit" => query.limit
    }
    |> new(schedule_in: 1)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_next_page(_rows, _query), do: :ok

  defp report(rows) do
    missing = Enum.filter(rows, &(not &1.has_access_effect?))

    :telemetry.execute(
      [:store, :subscriptions, :access_authority_inventory, :page],
      %{raw_count: length(rows), missing_count: length(missing)},
      %{}
    )

    Enum.each(missing, fn row ->
      Logger.warning("subscription_access_authority_missing",
        subscription_id: row.id,
        classification: :unclassified,
        source_order_line_item_id: row.source_order_line_item_id,
        queued_contract_change_id: row.current_contract_change_id,
        plan_revision_id: row.current_plan_revision_id
      )

      :telemetry.execute(
        [:store, :subscriptions, :access_authority_inventory, :missing],
        %{count: 1},
        %{
          subscription_id: row.id,
          classification: :unclassified,
          source_order_line_item_id: row.source_order_line_item_id,
          queued_contract_change_id: row.current_contract_change_id,
          plan_revision_id: row.current_plan_revision_id
        }
      )
    end)
  end
end
