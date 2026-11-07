# JC-248 APPLIED source repair implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Repair drift against an exact current APPLIED AccessEffect without changing its record or historical targets.

**Architecture:** The Subscriptions facade owns the correctness transaction and existing currentness/provenance checks. A narrow Entitlements facade variant compares the locked source before sharing the existing convergence writes. Projection invalidation occurs after commit and can be repeated on an already-converged source.

**Tech stack:** Elixir, Ash 3, PostgreSQL through DevCore, existing Cachex and PubSub wrappers.

## Task 1: Current APPLIED source repair

Files: modify `lib/store/subscriptions/facade.ex`, `lib/store/entitlements/facade.ex`, `test/store/subscriptions/access_effect_effective_execution_test.exs`, and `test/store/subscriptions/access_effect_non_effective_execution_test.exs`. Do not modify the existing currentness fence or effect lifecycle actions. No migration is needed for this task.

- [x] Add these regression tests to their existing modules, using the existing private fixture and read helpers.

Effective execution module:

```elixir
test "JC248 repairs missing APPLIED access without reopening the effect" do
  fixture = create_committed_effective_effect_fixture!("jc248_missing")
  assert {:ok, :applied} = Sandbox.unboxed_run(Repo, fn ->
    Facade.execute_effective_access_effect_for_system(fixture.effect.id)
  end)
  before_effect = fetch_effect!(fixture.effect.id)
  Sandbox.unboxed_run(Repo, fn ->
    Repo.query!("DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)])
  end)
  Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.subscription.user_id))
  assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(fixture.subscription.user_id), :stale)
  assert {:ok, :repaired} = Sandbox.unboxed_run(Repo, fn ->
    Facade.repair_applied_access_effect_for_system(fixture.effect.id)
  end)
  assert_effective_grant!(fixture)
  assert fetch_effect!(fixture.effect.id) == before_effect
  assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(fixture.subscription.user_id))
  assert_receive {:entitlements_invalidated, _, "subscription_source_reconciliation", _}
  before_grants = grants_for_source!(fixture.subscription.id)
  assert {:ok, :already_converged} = Sandbox.unboxed_run(Repo, fn ->
    Facade.repair_applied_access_effect_for_system(fixture.effect.id)
  end)
  assert grants_for_source!(fixture.subscription.id) == before_grants
  assert fetch_effect!(fixture.effect.id) == before_effect
end

test "JC248 repairs APPLIED validity drift against persisted target evidence" do
  fixture = create_committed_effective_effect_fixture!("jc248_validity")
  assert {:ok, :applied} = Sandbox.unboxed_run(Repo, fn ->
    Facade.execute_effective_access_effect_for_system(fixture.effect.id)
  end)
  before_effect = fetch_effect!(fixture.effect.id)
  Sandbox.unboxed_run(Repo, fn ->
    Repo.query!("UPDATE entitlement_grants SET valid_to_at = valid_to_at + interval '1 day' WHERE source_kind = 'subscription' AND source_id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)])
  end)
  assert {:ok, :repaired} = Sandbox.unboxed_run(Repo, fn ->
    Facade.repair_applied_access_effect_for_system(fixture.effect.id)
  end)
  assert_effective_grant!(fixture)
  assert fetch_effect!(fixture.effect.id) == before_effect
end
```

Non-effective execution module:

```elixir
test "JC248 repairs stale reactivation without reopening APPLIED non-effective authority" do
  fixture = create_committed_suspended_effect_fixture!("jc248_reactivation")
  assert {:ok, :applied} = Sandbox.unboxed_run(Repo, fn ->
    Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
  end)
  before_effect = fetch_effect!(fixture.effect_id)
  Sandbox.unboxed_run(Repo, fn ->
    Repo.query!("UPDATE entitlement_grants SET status = 'active', revoked_at = NULL, revoked_reason = NULL WHERE id = $1",
      [Ecto.UUID.dump!(fixture.grant_id)])
  end)
  assert {:ok, :repaired} = Sandbox.unboxed_run(Repo, fn ->
    Facade.repair_applied_access_effect_for_system(fixture.effect_id)
  end)
  assert [%EntitlementGrant{status: :revoked, revoked_reason: "subscription_source_reconciliation"}] =
    grants_for_source!(fixture.subscription_id)
  assert fetch_effect!(fixture.effect_id) == before_effect
  before_grants = grants_for_source!(fixture.subscription_id)
  assert {:ok, :already_converged} = Sandbox.unboxed_run(Repo, fn ->
    Facade.repair_applied_access_effect_for_system(fixture.effect_id)
  end)
  assert grants_for_source!(fixture.subscription_id) == before_grants
end
```

- [x] Run RED and preserve output. Use this environment for every Mix command, and serialize all commands:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/access_effect_effective_execution_test.exs test/store/subscriptions/access_effect_non_effective_execution_test.exs`

Expected RED: the three new behavioral tests fail because the public repair function does not exist. Existing tests must retain their assertions.

- [x] Add this Entitlements facade method and shared helper extraction. Keep the existing public convergence behavior unchanged. `build_source_convergence_result/3` contains the current result struct construction; both old writes and the already-converged branch use it.

```elixir
@doc """
Repairs an exact source target inside a caller-owned, source-locked transaction.
Returns all affected source users even when no grant write is needed.
"""
@spec reconcile_subscription_source_grants_for_system(SubscriptionSourceConvergenceInput.t()) ::
  {:ok, {:repaired | :already_converged, SourceConvergenceResult.t()}} | {:error, term()}
def reconcile_subscription_source_grants_for_system(%SubscriptionSourceConvergenceInput{} = input) do
  if Repo.in_transaction?() do
    with {:ok, validated} <- SubscriptionSourceConvergenceInput.new(Map.from_struct(input)),
         {:ok, rows} <- lock_subscription_source_grants(validated),
         {:ok, state} <- SourceConvergence.derive_locked_source_state(validated, rows) do
      active = Enum.filter(rows, &(&1.status == :active))
      case SourceConvergence.validate_final_active_set(validated, state.matching_target_id, active) do
        :ok ->
          {:ok, {:already_converged,
            build_source_convergence_result(validated, state, state.matching_target_id)}}
        {:error, _mismatch} ->
          with {:ok, result} <- converge_locked_subscription_source(validated, state, rows) do
            {:ok, {:repaired, result}}
          end
      end
    end
  else
    source_convergence_validation_error()
  end
end

def reconcile_subscription_source_grants_for_system(_input),
  do: source_convergence_validation_error()

defp converge_subscription_source_grants_in_transaction(input) do
  with {:ok, locked_rows} <- lock_subscription_source_grants(input),
       {:ok, state} <- SourceConvergence.derive_locked_source_state(input, locked_rows) do
    converge_locked_subscription_source(input, state, locked_rows)
  end
end

defp converge_locked_subscription_source(input, state, locked_rows) do
  with {:ok, target_grant_id} <- converge_source_target(input, state),
       :ok <- revoke_active_non_targets(input, state, target_grant_id, locked_rows),
       {:ok, active_rows} <- read_final_active_subscription_grants(input),
       :ok <- SourceConvergence.validate_final_active_set(input, target_grant_id, active_rows) do
    {:ok, build_source_convergence_result(input, state, target_grant_id)}
  end
end

defp build_source_convergence_result(input, state, target_grant_id) do
  %SourceConvergenceResult{
    mode: state.mode,
    subscription_id: input.subscription_id,
    target_grant_id: target_grant_id,
    revoked_grant_ids: state.active_non_target_ids,
    projection_user_ids: state.projection_user_ids
  }
end
```

- [x] Add the Subscriptions public facade method and private helpers below. Use the existing aliases, notification wrapper and provenance validators. The constant reason is operational metadata for a newly repaired grant, not a status-derived business decision. A later task adds source-level routing and worker discovery.

```elixir
@doc """
Repairs drift against a current APPLIED AccessEffect without changing its record.
Owns the source-fenced transaction. Stale effects are skipped. A projection error
is returned after durable convergence; repeating the call retries invalidation.
"""
@spec repair_applied_access_effect_for_system(Ecto.UUID.t()) ::
  {:ok, :repaired | :already_converged | :stale} | {:error, term()}
def repair_applied_access_effect_for_system(effect_id) do
  if Repo.in_transaction?() do
    {:error, Error.new("VALIDATION_ERROR", "APPLIED source repair must own its correctness transaction")}
  else
    Repo.transaction(fn -> repair_applied_access_effect_in_transaction(effect_id) end)
    |> finish_applied_access_effect_repair()
  end
end

defp repair_applied_access_effect_in_transaction(effect_id) do
  case AccessEffectCurrentnessFence.prove(effect_id) do
    {:ok, %{status: :stale}} -> :stale
    {:ok, %{status: :current, access_effect: %AccessEffect{status: :applied}} = evidence} ->
      repair_current_applied_access_effect(evidence)
    {:ok, _evidence} ->
      Repo.rollback(Error.new("INVALID_STATE_TRANSITION", "source drift repair requires a current APPLIED AccessEffect"))
    {:error, reason} -> Repo.rollback(reason)
  end
end

defp repair_current_applied_access_effect(%{source: source, access_effect: effect}) do
  with {:ok, provenance} <- lock_access_effect_subscription(source.subscription_id),
       :ok <- validate_access_effect_provenance(effect, provenance),
       :ok <- validate_access_effect_target_entitlement(effect, provenance),
       {:ok, input} <- applied_source_repair_input(source, effect),
       {:ok, {outcome, convergence}} <-
         EntitlementsFacade.reconcile_subscription_source_grants_for_system(input) do
    {outcome, effect, convergence.projection_user_ids}
  else
    {:error, reason} -> Repo.rollback(reason)
  end
end

defp applied_source_repair_input(source, effect) do
  SubscriptionSourceConvergenceInput.new(%{
    subscription_id: source.subscription_id,
    user_id: source.user_id,
    disposition: effect.disposition,
    entitlement_kind: effect.entitlement_kind,
    entitlement_scope_key: effect.entitlement_scope_key,
    valid_from_at: effect.valid_from_at,
    valid_until_at: effect.valid_until_at,
    reason: "subscription_source_reconciliation",
    access_effect_id: effect.id,
    source_version: effect.source_version,
    target_fingerprint: effect.target_fingerprint
  })
end

defp finish_applied_access_effect_repair({:ok, :stale}), do: {:ok, :stale}
defp finish_applied_access_effect_repair({:error, reason}),
  do: {:error, Normalize.normalize(reason)}

defp finish_applied_access_effect_repair({:ok, {outcome, effect, user_ids}}) do
  :ok = AshNotifications.notify_post_commit([], context: %{
    flow: :repair_applied_access_effect,
    subscription_id: effect.subscription_id,
    access_effect_id: effect.id
  })
  case EntitlementsFacade.invalidate_subscription_source_users_after_commit_for_system(
    user_ids, "subscription_source_reconciliation") do
    :ok -> {:ok, outcome}
    {:error, reason} -> {:error, Normalize.normalize(reason)}
  end
end
```

- [x] Run the two focused modules to GREEN, strict Credo for affected production/tests, and format the four files with explicit MIX_ENV=test. Preserve logs in ignored `tmp/jc248/`.
- [x] Review the whole change for notification ordering, source identity, binary UUID lock ordering, no APPLIED writes, no changes to normal executor semantics and no fixture leaks. Commit only these four implementation/test files.

Task 1 does not complete JC-248. Bounded APPLIED verification, source-level routing, missing-authority inventory, Oban sweep wiring, full acceptance matrix and runtime/query evidence remain subsequent tasks on the same ticket branch.
