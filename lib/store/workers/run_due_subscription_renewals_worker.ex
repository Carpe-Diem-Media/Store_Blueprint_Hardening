defmodule Store.Workers.RunDueSubscriptionRenewalsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, page} <- SubscriptionsFacade.list_due_renewal_job_page_for_system(opts),
         :ok <- enqueue_due_jobs(page.jobs),
         :ok <- enqueue_next_page(page, Keyword.fetch!(opts, :limit)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:discard, _reason} = discard -> discard
    end
  end

  def perform(_job), do: {:discard, "invalid due-renewal boundary job"}

  defp parse_opts(args) do
    with {:ok, now} <- parse_datetime(Map.get(args, "now")),
         {:ok, after_renewal_at} <- parse_datetime(Map.get(args, "after_renewal_at")),
         {:ok, after_id} <- parse_cursor_id(Map.get(args, "after_id")),
         true <- is_nil(after_renewal_at) or is_binary(after_id),
         {:ok, limit} <- parse_limit(Map.get(args, "limit", 100)) do
      opts = [limit: limit]
      opts = if now, do: Keyword.put(opts, :now, now), else: opts

      opts =
        if after_renewal_at,
          do: Keyword.put(opts, :after_renewal_at, after_renewal_at),
          else: opts

      opts = if after_id, do: Keyword.put(opts, :after_id, after_id), else: opts
      {:ok, opts}
    else
      _ -> {:discard, "invalid due-renewal page cursor"}
    end
  end

  defp enqueue_next_page(%{cursor: nil}, _limit), do: :ok

  defp enqueue_next_page(%{cursor: %{timestamp: timestamp, id: id}, now: now}, limit) do
    args = %{
      "now" => DateTime.to_iso8601(now),
      "after_id" => id,
      "limit" => limit
    }

    args =
      if timestamp,
        do: Map.put(args, "after_renewal_at", DateTime.to_iso8601(timestamp)),
        else: args

    case new(args) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_due_jobs(due_jobs) do
    Enum.reduce_while(due_jobs, :ok, fn due_job, :ok ->
      case enqueue_due_job(due_job) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp enqueue_due_job(due_job) do
    %{
      "subscription_id" => due_job.subscription_id,
      "renewal_key" => due_job.renewal_key
    }
    |> ProcessSubscriptionRenewalWorker.new(schedule_in: due_job.schedule_in)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp parse_cursor_id(nil), do: {:ok, nil}
  defp parse_cursor_id(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp parse_cursor_id(_value), do: :error

  defp parse_limit(value) do
    case value do
      value when is_integer(value) and value > 0 and value <= 500 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 and parsed <= 500 -> {:ok, parsed}
          _ -> {:ok, 100}
        end

      _ ->
        {:ok, 100}
    end
  end
end
