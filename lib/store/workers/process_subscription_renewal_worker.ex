defmodule Store.Workers.ProcessSubscriptionRenewalWorker do
  @moduledoc false

  # Cancelled occurrences require an explicit retry after reviewed provider
  # fencing support exists; recurring sweeps must not recreate unsupported work.
  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:suspended, :available, :scheduled, :executing, :retryable, :completed, :cancelled]
    ]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id} = args})
      when is_binary(subscription_id) do
    opts =
      case Map.get(args, "renewal_key") do
        renewal_key when is_binary(renewal_key) -> [renewal_key: renewal_key]
        _ -> []
      end

    case SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription_id, opts) do
      {:ok, :processed} ->
        :ok

      {:ok, :noop} ->
        :ok

      {:error,
       %{
         code: "RENEWAL_DISPATCH_UNAVAILABLE",
         meta: %{reason: :provider_revocation_fencing_unsupported} = meta
       } = reason}
      when not is_map_key(meta, :cleanup_failure) and not is_map_key(meta, :preflight_failure) ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing subscription_id"}
end
