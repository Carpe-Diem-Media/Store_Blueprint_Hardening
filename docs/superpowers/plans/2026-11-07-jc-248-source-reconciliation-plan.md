# JC-248 source reconciliation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Expose a typed source-only repair operation and a retryable worker that always derives its target from the current durable AccessEffect.

**Architecture:** Read the source and current effect through existing Ash-backed facade helpers. Route APPLIED to the reviewed repair boundary and nonterminal obligations to existing executors. Validate funded provenance inside those executors' existing source-locked transactions, before grant writes.

**Tech stack:** Elixir, Ash 3, PostgreSQL, Oban 2.24.1, DevCore.

## Files and boundaries

Create `lib/store/subscriptions/inputs/reconcile_subscription_access_input.ex` and `lib/store/workers/reconcile_subscription_access_worker.ex`. Modify `lib/store/subscriptions/facade.ex` and both existing AccessEffect execution test modules. Do not add a cron, discovery selector, inventory, new queue, dependency or source target. Subsequent tasks supply bounded discovery and real-connection proofs.

## Task 3: Source operation and worker

- [ ] Add regression tests before production changes. Reuse each module's committed fixture and cleanup helpers. Run all calls that own a transaction through `Sandbox.unboxed_run`. Add these effective-module aliases and tests.

```elixir
alias Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput
alias Store.Workers.ReconcileSubscriptionAccessWorker

test "source reconciliation accepts identities and rejects caller-supplied access truth" do
  id = Ecto.UUID.generate()
  assert {:ok, %ReconcileSubscriptionAccessInput{subscription_id: ^id}} =
    ReconcileSubscriptionAccessInput.new(%{subscription_id: id})
  for params <- [%{subscription_id: id, entitlement_kind: :membership_access},
                  %{subscription_id: "bad"},
                  %{subscription_id: id, expected_access_effect_id: "bad"}] do
    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
      ReconcileSubscriptionAccessInput.new(params)
  end
end

test "source worker re-drives a required target then repairs APPLIED drift" do
  fixture = create_committed_effective_effect_fixture!("jc248_source_worker")
  args = %{"subscription_id" => fixture.subscription.id,
    "expected_access_effect_id" => fixture.effect.id}
  assert :ok = Sandbox.unboxed_run(Repo, fn ->
    ReconcileSubscriptionAccessWorker.perform(%Oban.Job{args: args})
  end)
  assert_effective_grant!(fixture)
  snapshot = fetch_effect!(fixture.effect.id)
  Sandbox.unboxed_run(Repo, fn ->
    Repo.query!("DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)])
  end)
  assert :ok = Sandbox.unboxed_run(Repo, fn ->
    ReconcileSubscriptionAccessWorker.perform(%Oban.Job{args: args})
  end)
  assert_effective_grant!(fixture)
  assert fetch_effect!(fixture.effect.id) == snapshot
end

test "source operation fails closed when its durable authority is missing" do
  fixture = create_committed_effective_effect_fixture!("jc248_missing_authority")
  Sandbox.unboxed_run(Repo, fn ->
    Repo.query!("DELETE FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(fixture.effect.id)])
  end)
  assert {:ok, input} = ReconcileSubscriptionAccessInput.new(%{subscription_id: fixture.subscription.id})
  assert {:error, %Error{code: "VALIDATION_ERROR", meta: %{reason: :missing_access_effect,
    classification: :unclassified}}} = Sandbox.unboxed_run(Repo, fn ->
      Facade.reconcile_subscription_access_for_system(input)
    end)
  assert grants_for_source!(fixture.subscription.id) == []
  assert {:ok, nil} = Facade.get_current_access_effect_for_system(fixture.subscription)
end

test "source operation rejects an obsolete expected effect without applying either target" do
  fixture = create_committed_effective_effect_fixture!("jc248_expected_effect")
  assert {:ok, input} = ReconcileSubscriptionAccessInput.new(%{subscription_id: fixture.subscription.id,
    expected_access_effect_id: Ecto.UUID.generate()})
  assert {:ok, :stale} = Sandbox.unboxed_run(Repo, fn ->
    Facade.reconcile_subscription_access_for_system(input)
  end)
  assert fetch_effect!(fixture.effect.id).status == :required
  assert grants_for_source!(fixture.subscription.id) == []
end
```

- [ ] Add a non-effective worker regression with `create_committed_suspended_effect_fixture!`, its `subscription_id` and `effect_id`, expecting `:ok`, no active exact-source grants and APPLIED. Add a caller-transaction regression using `Repo.transaction` inside `unboxed_run`, asserting a VALIDATION_ERROR and unchanged effect/grants. Add immutable-provenance regression tests in both modules: create a fixture and a foreign fixture, update only the tested Subscription's `source_order_line_item_id` to the foreign line item, call the typed source operation, expect VALIDATION_ERROR and unchanged effect/grants, and restore the original pointer in `after` before fixture cleanup. The effect fingerprint remains valid, so the test exercises commercial provenance rather than F0 fingerprint rejection. Use existing fixture field names and helpers, not test seams in production.

- [ ] Run both execution modules to RED and preserve `tmp/jc248/task3-red.log`. Confirm missing APIs or the missing provenance guard cause failures before production changes.

- [ ] Implement this strictly bounded input. It accepts atom-keyed internal maps, matching the verification queries. Unknown fields cannot introduce caller-authored grant truth.

```elixir
defmodule Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput do
  @moduledoc "Source identity and optional expected target for system entitlement reconciliation."
  alias Store.Support.Errors.Error
  @enforce_keys [:subscription_id]
  defstruct [:subscription_id, :expected_access_effect_id]
  @type t :: %__MODULE__{subscription_id: Ecto.UUID.t(), expected_access_effect_id: Ecto.UUID.t() | nil}
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{subscription_id: id} = params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in [:subscription_id, :expected_access_effect_id])),
         {:ok, source_id} <- Ecto.UUID.cast(id),
         {:ok, expected_id} <- optional_uuid(Map.get(params, :expected_access_effect_id)) do
      {:ok, %__MODULE__{subscription_id: source_id, expected_access_effect_id: expected_id}}
    else
      _ -> invalid()
    end
  end
  def new(_params), do: invalid()
  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(id), do: Ecto.UUID.cast(id)
  defp invalid, do: {:error, Error.new("VALIDATION_ERROR", "invalid source reconciliation identity")}
end
```

- [ ] Add the input alias and this facade operation. `fetch_subscription_for_renewal/1` and `read_current_access_effect/1` already exist and call resource actions. Selection is diagnostic until the called executor proves currentness again under its source lock. An expected-ID mismatch does not authorize execution of the stale target; existing recovery remains responsible for allowed stale nonterminal supersession.

```elixir
@doc """
Reconciles one Subscription source against its current durable AccessEffect.

Accepts source identity only. Missing authority fails closed, and execution rechecks
currentness under the existing source fence. Owns its correctness transaction through
the selected executor and delivers grant projections after commit.
"""
@spec reconcile_subscription_access_for_system(ReconcileSubscriptionAccessInput.t()) ::
  {:ok, :repaired | :already_converged | :stale | :applied | :applied_projection_pending | :superseded | :noop}
  | {:error, Error.t() | term()}
def reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{} = input) do
  if Repo.in_transaction?() do
    {:error, Error.new("VALIDATION_ERROR", "source reconciliation must own its correctness transaction")}
  else
    with {:ok, canonical} <- ReconcileSubscriptionAccessInput.new(Map.from_struct(input)),
         {:ok, _source} <- fetch_subscription_for_renewal(canonical.subscription_id),
         {:ok, effect} <- read_current_access_effect(canonical.subscription_id) do
      reconcile_selected_source_effect(canonical, effect)
    end
  end
end
def reconcile_subscription_access_for_system(_input),
  do: {:error, Error.new("VALIDATION_ERROR", "typed source reconciliation input is required")}

defp reconcile_selected_source_effect(input, nil) do
  {:error, Error.new("VALIDATION_ERROR", "Subscription source has no durable AccessEffect authority",
    %{reason: :missing_access_effect, classification: :unclassified, subscription_id: input.subscription_id})}
end
defp reconcile_selected_source_effect(%{expected_access_effect_id: expected}, %{id: id})
     when not is_nil(expected) and expected != id, do: {:ok, :stale}
defp reconcile_selected_source_effect(_input, %AccessEffect{status: :applied, id: id}),
  do: repair_applied_access_effect_for_system(id)
defp reconcile_selected_source_effect(_input, %AccessEffect{status: status, disposition: disposition, id: id})
     when status in [:required, :pending, :failed_retryable] do
  case disposition do
    :effective -> execute_effective_access_effect_for_system(id)
    :non_effective -> execute_suspension_access_effect_for_system(id)
  end
end
defp reconcile_selected_source_effect(_input, %AccessEffect{}) do
  {:error, Error.new("INVALID_STATE_TRANSITION", "latest AccessEffect is not executable authority")}
end
```

- [ ] Add a shared private provenance guard and invoke it before any nonterminal transition or grant write inside each existing executor's source-locked path. Do not add another preflight transaction or change F0 stale supersession. Both helper call sites already run under F0's Subscription lock.

```elixir
defp validate_current_access_effect_provenance(effect, subscription_id) do
  with {:ok, current_provenance} <- lock_access_effect_subscription(subscription_id),
       :ok <- validate_access_effect_provenance(effect, current_provenance) do
    validate_access_effect_target_entitlement(effect, current_provenance)
  end
end

# First clauses in converge_current_effective_access_effect/1's existing with:
with :ok <- validate_current_access_effect_provenance(effect, subscription_id),
     {:ok, pending_effect} <- access_effect_to_pending(effect),
     {:ok, input} <- effective_source_convergence_input(subscription_id, user_id, effect),
     {:ok, convergence} <- converge_effective_access_source(input),
     {:ok, applied_effect} <- mark_effective_access_effect_applied(pending_effect, convergence) do
  {:applied, applied_effect, convergence.projection_user_ids}
else
  {:error, {:effective_execution_failure, reason}} -> Repo.rollback({:effective_execution_failure, reason})
  {:error, reason} -> Repo.rollback({:effective_proof_failure, reason})
end

# First clauses in execute_current_non_effective_access_effect/1's existing with:
with :ok <- validate_current_access_effect_provenance(effect, subscription_id),
     {:ok, subscription} <- fetch_subscription_for_renewal(subscription_id),
     reason when is_binary(reason) <- non_effective_access_effect_reason(subscription),
     {:ok, input} <- non_effective_source_convergence_input(subscription_id, user_id, effect, reason) do
  execute_current_non_effective_with_input(effect, input)
else
  {:error, reason} -> Repo.rollback({:non_effective_proof_failure, reason})
  _reason -> Repo.rollback({:non_effective_proof_failure, Error.new("INVALID_STATE_TRANSITION",
    "current NON_EFFECTIVE AccessEffect lacks persisted revocation-reason evidence")})
end
```

- [ ] Implement the worker. Use finite uniqueness so an orphaned executing job cannot suppress all future rediscovery. Completed, cancelled and discarded jobs do not suppress new repairs. Queue state never marks business convergence. A committed execution with pending projection must trigger a retry through the source boundary.

```elixir
defmodule Store.Workers.ReconcileSubscriptionAccessWorker do
  @moduledoc false
  use Oban.Worker, queue: :subscriptions, max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args], states: :incomplete]
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput
  alias Store.Support.Errors.Error
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id} = args}) do
    if Enum.all?(Map.keys(args), &(&1 in ["subscription_id", "expected_access_effect_id"])) do
      case ReconcileSubscriptionAccessInput.new(%{subscription_id: id,
             expected_access_effect_id: Map.get(args, "expected_access_effect_id")}) do
        {:ok, input} -> execute(input)
        {:error, _reason} -> {:discard, "invalid source reconciliation identity"}
      end
    else
      {:discard, "invalid source reconciliation arguments"}
    end
  end
  def perform(_job), do: {:discard, "invalid source reconciliation job"}
  defp execute(input) do
    started = System.monotonic_time()
    result = Facade.reconcile_subscription_access_for_system(input)
    :telemetry.execute([:store, :subscriptions, :source_reconciliation, :stop],
      %{duration: System.monotonic_time() - started},
      %{subscription_id: input.subscription_id, access_effect_id: input.expected_access_effect_id,
        outcome: outcome(result)})
    case result do
      {:ok, :applied_projection_pending} ->
        {:error, Error.new("INTERNAL_ERROR", "source convergence committed with projection pending")}
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
  defp outcome({:ok, value}), do: value
  defp outcome({:error, %Error{meta: %{reason: :missing_access_effect}}}), do: :missing_authority
  defp outcome({:error, %Error{code: code}}) when code in ["VALIDATION_ERROR", "INVALID_STATE_TRANSITION"],
    do: :invariant_conflict
  defp outcome({:error, _reason}), do: :execution_failure
end
```

- [ ] Run the focused modules to GREEN, strict Credo on changed files and format check. Existing fixed query-count checks may need exactly one extra provenance read for each executor. Update only the documented fixed allowance if an observed failure proves that exact extra query; preserve batch/N+1 bounds. Add worker malformed-argument and telemetry-outcome assertions, and verify source replay does not change APPLIED identity.
- [ ] Self-review the full task diff, commit, and report exact RED/GREEN commands and results. Separate specification and quality reviewers follow before the next implementation task.

Use sequential commands with this prefix for every Mix invocation:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix`

Focused test arguments are `test test/store/subscriptions/access_effect_effective_execution_test.exs test/store/subscriptions/access_effect_non_effective_execution_test.exs`. No other agent or root may run Mix while the implementer owns it. Do not weaken provenance validation to satisfy tests; diagnose fixture or compatibility conflicts first.
