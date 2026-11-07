defmodule Store.Workers.VerifySubscriptionAccessWorker do
  @moduledoc "Verifies a bounded APPLIED window and schedules exact source repairs."

  use Oban.Worker,
    queue: :ops,
    priority: 3,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args], states: :incomplete]

  require Logger

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Queries.AppliedAccessVerificationQuery
  alias Store.Workers.ReconcileSubscriptionAccessWorker

  @allowed_args ["as_of", "after_inserted_at", "after_id", "limit"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, query} <- parse_query(args),
         {:ok, result} <- SubscriptionsFacade.verify_subscription_access_window_for_system(query),
         :ok <- enqueue_repairs(result.repairs),
         :ok <- enqueue_next_page(result, query.limit) do
      report(result)
      :ok
    else
      {:discard, _reason} = discard -> discard
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "invalid subscription access verification job"}

  defp parse_query(args) do
    with true <- Enum.all?(Map.keys(args), &(&1 in @allowed_args)),
         true <-
           not cursor_supplied?(args) or
             (Map.has_key?(args, "as_of") and Map.has_key?(args, "limit")),
         true <- valid_cursor_args?(args),
         {:ok, as_of} <- parse_as_of(args),
         {:ok, after_inserted_at} <- parse_datetime(Map.get(args, "after_inserted_at")),
         after_id <- Map.get(args, "after_id"),
         true <- is_nil(after_id) or is_binary(after_id),
         true <- is_nil(after_inserted_at) == is_nil(after_id),
         {:ok, query} <-
           AppliedAccessVerificationQuery.new(%{
             as_of: as_of,
             after_inserted_at: after_inserted_at,
             after_id: after_id,
             limit: Map.get(args, "limit", 100)
           }) do
      {:ok, query}
    else
      _ -> {:discard, "invalid subscription access verification bounds"}
    end
  end

  defp cursor_supplied?(args),
    do: Map.has_key?(args, "after_inserted_at") or Map.has_key?(args, "after_id")

  defp valid_cursor_args?(args) do
    if cursor_supplied?(args) do
      is_binary(args["after_inserted_at"]) and is_binary(args["after_id"])
    else
      true
    end
  end

  defp parse_as_of(args) do
    case Map.fetch(args, "as_of") do
      :error -> {:ok, DateTime.utc_now()}
      {:ok, value} -> parse_datetime(value)
    end
  end

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp enqueue_repairs(repairs) do
    Enum.reduce_while(repairs, :ok, fn candidate, :ok ->
      candidate
      |> ReconcileSubscriptionAccessWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp enqueue_next_page(%{cursor: nil}, _limit), do: :ok

  defp enqueue_next_page(%{cursor: cursor, as_of: as_of}, limit) do
    %{
      "as_of" => DateTime.to_iso8601(as_of),
      "after_inserted_at" => DateTime.to_iso8601(cursor.timestamp),
      "after_id" => cursor.id,
      "limit" => limit
    }
    |> new(schedule_in: 1)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp report(result) do
    :telemetry.execute(
      [:store, :subscriptions, :access_verification, :page],
      Map.take(result, [:raw_count, :current_count, :stale_count, :healthy_count])
      |> Map.merge(%{
        repair_count: length(result.repairs),
        conflict_count: length(result.conflicts)
      }),
      %{}
    )

    Enum.each(result.conflicts, fn conflict ->
      Logger.error("subscription_access_authority_conflict",
        subscription_id: conflict.subscription_id,
        access_effect_id: conflict.access_effect_id,
        reason: conflict.reason
      )

      :telemetry.execute(
        [:store, :subscriptions, :access_verification, :conflict],
        %{count: 1},
        conflict
      )
    end)
  end
end
