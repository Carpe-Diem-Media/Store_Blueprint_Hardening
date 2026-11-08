defmodule Store.Workers.RunSubscriptionAccessEffectRecoveryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Queries.PendingAccessRepairDeliveryQuery

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, result} <-
           SubscriptionsFacade.run_subscription_access_effect_recovery_for_system(opts),
         :ok <- enqueue_next_page(result, Keyword.get(opts, :limit, 100), args) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:discard, _reason} = discard -> discard
    end
  end

  def perform(_job), do: {:discard, "invalid AccessEffect recovery job"}

  defp parse_opts(args) do
    with {:ok, as_of} <- parse_datetime(Map.get(args, "as_of")),
         {:ok, execution_after_updated_at} <-
           parse_datetime(Map.get(args, "execution_after_updated_at")),
         {:ok, effective_execution_after_updated_at} <-
           parse_datetime(Map.get(args, "effective_execution_after_updated_at")),
         {:ok, projection_after_inserted_at} <-
           parse_datetime(Map.get(args, "projection_after_inserted_at")),
         {:ok, repair_delivery_after_inserted_at} <-
           parse_datetime(Map.get(args, "repair_delivery_after_inserted_at")),
         {:ok, limit} <- parse_limit(Map.get(args, "limit", 100)),
         :ok <- validate_optional_id(Map.get(args, "execution_after_id")),
         :ok <-
           validate_cursor_pair(
             Map.get(args, "effective_execution_after_updated_at"),
             Map.get(args, "effective_execution_after_id")
           ),
         :ok <- validate_optional_id(Map.get(args, "effective_execution_after_id")),
         :ok <- validate_optional_id(Map.get(args, "projection_after_id")),
         :ok <-
           validate_cursor_pair(
             Map.get(args, "repair_delivery_after_inserted_at"),
             Map.get(args, "repair_delivery_after_id")
           ),
         :ok <- validate_optional_id(Map.get(args, "repair_delivery_after_id")),
         :ok <-
           validate_repair_delivery_bounds(
             as_of,
             repair_delivery_after_inserted_at,
             Map.get(args, "repair_delivery_after_id")
           ) do
      opts =
        [
          limit: limit,
          skip_execution: Map.get(args, "skip_execution", false),
          skip_effective_execution: Map.get(args, "skip_effective_execution", false),
          skip_projection: Map.get(args, "skip_projection", false),
          skip_repair_delivery: Map.get(args, "skip_repair_delivery", false)
        ]
        |> put_optional(:as_of, as_of)
        |> put_optional(:execution_after_updated_at, execution_after_updated_at)
        |> put_optional(:execution_after_id, Map.get(args, "execution_after_id"))
        |> put_optional(
          :effective_execution_after_updated_at,
          effective_execution_after_updated_at
        )
        |> put_optional(
          :effective_execution_after_id,
          Map.get(args, "effective_execution_after_id")
        )
        |> put_optional(:projection_after_inserted_at, projection_after_inserted_at)
        |> put_optional(:projection_after_id, Map.get(args, "projection_after_id"))
        |> put_optional(:repair_delivery_after_inserted_at, repair_delivery_after_inserted_at)
        |> put_optional(:repair_delivery_after_id, Map.get(args, "repair_delivery_after_id"))

      {:ok, opts}
    else
      _ -> {:discard, "invalid AccessEffect recovery cursor"}
    end
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp enqueue_next_page(
         %{
           effective_execution_cursor: nil,
           execution_cursor: nil,
           projection_cursor: nil,
           repair_delivery_cursor: nil
         },
         _limit,
         _args
       ),
       do: :ok

  defp enqueue_next_page(result, limit, args) do
    continuation = %{
      "as_of" => DateTime.to_iso8601(result.as_of),
      "limit" => limit,
      "skip_execution" => is_nil(result.execution_cursor),
      "skip_effective_execution" => is_nil(result.effective_execution_cursor),
      "skip_projection" => is_nil(result.projection_cursor),
      "skip_repair_delivery" => is_nil(result.repair_delivery_cursor)
    }

    continuation = add_cursor(continuation, result.execution_cursor, :execution)

    continuation =
      add_cursor(continuation, result.effective_execution_cursor, :effective_execution)

    continuation = add_cursor(continuation, result.projection_cursor, :projection)
    continuation = add_cursor(continuation, result.repair_delivery_cursor, :repair_delivery)

    continuation =
      if Map.has_key?(args, "sweep_id"),
        do: Map.put(continuation, "sweep_id", args["sweep_id"]),
        else: continuation

    continuation
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_cursor(args, nil, _stream), do: args

  defp add_cursor(args, %{timestamp: timestamp, id: id}, :execution) do
    args
    |> Map.put("execution_after_updated_at", DateTime.to_iso8601(timestamp))
    |> Map.put("execution_after_id", id)
  end

  defp add_cursor(args, %{timestamp: timestamp, id: id}, :effective_execution) do
    args
    |> Map.put("effective_execution_after_updated_at", DateTime.to_iso8601(timestamp))
    |> Map.put("effective_execution_after_id", id)
  end

  defp add_cursor(args, %{timestamp: timestamp, id: id}, :projection) do
    args
    |> Map.put("projection_after_inserted_at", DateTime.to_iso8601(timestamp))
    |> Map.put("projection_after_id", id)
  end

  defp add_cursor(args, %{timestamp: timestamp, id: id}, :repair_delivery) do
    args
    |> Map.put("repair_delivery_after_inserted_at", DateTime.to_iso8601(timestamp))
    |> Map.put("repair_delivery_after_id", id)
  end

  defp validate_optional_id(nil), do: :ok
  defp validate_optional_id(value) when is_binary(value), do: :ok
  defp validate_optional_id(_value), do: :error

  defp validate_cursor_pair(nil, nil), do: :ok

  defp validate_cursor_pair(timestamp, id) when is_binary(timestamp) and is_binary(id),
    do: :ok

  defp validate_cursor_pair(_timestamp, _id), do: :error

  defp validate_repair_delivery_bounds(_as_of, nil, nil), do: :ok

  defp validate_repair_delivery_bounds(as_of, timestamp, id) do
    case PendingAccessRepairDeliveryQuery.new(%{
           as_of: as_of,
           after_inserted_at: timestamp,
           after_id: id
         }) do
      {:ok, _query} -> :ok
      {:error, _reason} -> :error
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

  defp parse_limit(value) when is_integer(value) and value in 1..500, do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in 1..500 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_limit(_value), do: :error
end
