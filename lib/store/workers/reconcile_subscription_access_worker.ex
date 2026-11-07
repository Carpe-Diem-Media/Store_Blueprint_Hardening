defmodule Store.Workers.ReconcileSubscriptionAccessWorker do
  @moduledoc "Reconciles one Subscription against its latest durable AccessEffect."

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [
      period: 55,
      fields: [:worker, :queue, :args],
      states: [:suspended, :scheduled, :available, :executing, :retryable]
    ]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput
  alias Store.Support.Errors.Error

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id} = args}) do
    started = System.monotonic_time()

    result =
      with true <-
             Enum.all?(Map.keys(args), &(&1 in ["subscription_id", "expected_access_effect_id"])),
           {:ok, input} <-
             ReconcileSubscriptionAccessInput.new(%{
               subscription_id: subscription_id,
               expected_access_effect_id: args["expected_access_effect_id"]
             }),
           result <- SubscriptionsFacade.reconcile_subscription_access_for_system(input) do
        result
      else
        _ -> {:discard, "invalid source reconciliation identity/arguments/job"}
      end

    case result do
      {:discard, _reason} = discard ->
        discard

      {:ok, :applied_projection_pending} ->
        emit(started, subscription_id, args["expected_access_effect_id"], :execution_failure)

        {:error,
         Error.new("INTERNAL_ERROR", "source convergence committed with projection pending")}

      {:ok, outcome} ->
        emit(started, subscription_id, args["expected_access_effect_id"], outcome)
        :ok

      {:error, %Error{} = error} ->
        outcome =
          cond do
            error.meta[:reason] == :missing_access_effect -> :missing_authority
            error.code in ["VALIDATION_ERROR", "INVALID_STATE_TRANSITION"] -> :invariant_conflict
            true -> :execution_failure
          end

        emit(started, subscription_id, args["expected_access_effect_id"], outcome)
        {:error, error}

      {:error, reason} ->
        emit(started, subscription_id, args["expected_access_effect_id"], :execution_failure)
        {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "invalid source reconciliation identity/arguments/job"}

  defp emit(started, subscription_id, expected_id, outcome) do
    :telemetry.execute(
      [:store, :subscriptions, :source_reconciliation, :stop],
      %{duration: System.monotonic_time() - started},
      %{subscription_id: subscription_id, access_effect_id: expected_id, outcome: outcome}
    )
  end
end
