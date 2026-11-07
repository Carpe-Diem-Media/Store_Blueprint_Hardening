# JC-248 exact-source repair proof implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Prove that APPLIED repair restores the whole current source outcome while preserving terminal evidence, historical rows and independently valid sources.

**Architecture:** Extend the existing committed-fixture execution tests. Exercise the accepted repair boundary without changing production behavior or reconstructing targets from mutable Plans. Correctness calls and committed fixture mutations run through `Sandbox.unboxed_run`.

**Tech stack:** Elixir, ExUnit, Ash, PostgreSQL, Cachex, Phoenix.PubSub, DevCore.

## Task 7: Whole-source acceptance matrix

Modify only `test/store/subscriptions/access_effect_effective_execution_test.exs` and `test/store/subscriptions/access_effect_non_effective_execution_test.exs`. Reuse their existing helpers. Do not refactor unrelated tests or add a production testing hook. If a regression exposes a defect, report its failed assertion and proposed correction to root before changing production code.

- [x] Add this effective pair case. Two sources belong to different valid users. Corrupt the owned source's active target row to the other owner, kind and scope, then add another obsolete active row and valid revoked history. The independent source remains valid throughout. Snapshot the entire APPLIED effect and all historical attributes before repair.

```elixir
test "APPLIED repair restores the whole source and preserves other users and history" do
  fixture = create_committed_effective_effect_fixture!("jc248_exact_pair")
  independent = create_committed_effective_effect_fixture!("jc248_exact_independent")

  Sandbox.unboxed_run(Repo, fn ->
    assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
    assert {:ok, :applied} =
             Facade.execute_effective_access_effect_for_system(independent.effect.id)

    [original] = grants_for_source!(fixture.subscription.id)

    Repo.query!(
      "UPDATE entitlement_grants SET user_id = $2, kind = 'discount_tier', scope_key = $3 WHERE id = $1",
      [Ecto.UUID.dump!(original.id), Ecto.UUID.dump!(independent.subscription.user_id),
       "#{fixture.effect.id}:wrong-target"]
    )

    create_grant!(fixture, "#{fixture.effect.id}:obsolete-active", fixture.effect.valid_from_at)
    insert_revoked_history!(fixture, 1, DateTime.utc_now())
  end)

  effect_before = fetch_effect!(fixture.effect.id)
  source_before = grants_for_source!(fixture.subscription.id)
  inactive_before = Enum.reject(source_before, &(&1.status == :active))
  obsolete_ids = source_before |> Enum.filter(&(&1.status == :active)) |> Enum.map(& &1.id)
  independent_before = grants_for_source!(independent.subscription.id)
  assert length(obsolete_ids) == 2
  assert length(inactive_before) == 1

  user_ids = [fixture.subscription.user_id, independent.subscription.user_id]

  Enum.each(user_ids, fn user_id ->
    :ok = Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(user_id))
    assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(user_id), :jc248_stale_owner)
  end)

  try do
    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect.id)
             end)

    source_after = grants_for_source!(fixture.subscription.id)
    assert [target] = Enum.filter(source_after, &(&1.status == :active))
    assert target.user_id == fixture.subscription.user_id
    assert target.kind == fixture.effect.entitlement_kind
    assert target.scope_key == fixture.effect.entitlement_scope_key
    assert target.valid_from_at == fixture.effect.valid_from_at
    assert target.valid_to_at == fixture.effect.valid_until_at
    assert target.revoked_at == nil
    assert target.revoked_reason == nil

    Enum.each(obsolete_ids, fn id ->
      assert %{status: :revoked, revoked_reason: "subscription_source_reconciliation"} =
               Enum.find(source_after, &(&1.id == id))
    end)

    Enum.each(inactive_before, fn historical ->
      assert Enum.find(source_after, &(&1.id == historical.id)) == historical
    end)

    assert fetch_effect!(fixture.effect.id) == effect_before
    assert grants_for_source!(independent.subscription.id) == independent_before

    Enum.each(user_ids, fn user_id ->
      assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(user_id))
      assert_receive {:entitlements_invalidated, ^user_id,
                      "subscription_source_reconciliation", _at}
    end)
  after
    Enum.each(user_ids, fn user_id ->
      Phoenix.PubSub.unsubscribe(Store.PubSub, Cache.topic(user_id))
      Cachex.del(Cache, Cache.cache_key(user_id))
    end)
  end
end
```

- [x] Add this effective empty-target case to the same module. An empty effective target succeeds by leaving no active row for this source, even when another source remains active.

```elixir
test "APPLIED empty effective target removes stale rows only for its own source" do
  fixture = create_committed_effective_effect_fixture!("jc248_exact_empty", target: :empty)
  independent = create_committed_effective_effect_fixture!("jc248_empty_independent")

  Sandbox.unboxed_run(Repo, fn ->
    assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
    assert {:ok, :applied} =
             Facade.execute_effective_access_effect_for_system(independent.effect.id)

    for suffix <- ["a", "b"] do
      create_grant!(fixture, "#{fixture.effect.id}:stale:#{suffix}",
        fixture.subscription.current_period_start_at)
    end
  end)

  effect_before = fetch_effect!(fixture.effect.id)
  independent_before = grants_for_source!(independent.subscription.id)

  assert {:ok, :repaired} =
           Sandbox.unboxed_run(Repo, fn ->
             Facade.repair_applied_access_effect_for_system(fixture.effect.id)
           end)

  assert grants = grants_for_source!(fixture.subscription.id)
  assert length(grants) == 2
  assert Enum.all?(grants, &(&1.status == :revoked))
  assert grants_for_source!(independent.subscription.id) == independent_before
  assert fetch_effect!(fixture.effect.id) == effect_before

  assert {:ok, :already_converged} =
           Sandbox.unboxed_run(Repo, fn ->
             Facade.repair_applied_access_effect_for_system(fixture.effect.id)
           end)

  assert grants_for_source!(fixture.subscription.id) == grants
  assert fetch_effect!(fixture.effect.id) == effect_before
end
```

- [x] Add this non-effective case in the non-effective module. Its existing helper owns and cleans the independent Subscription. Existing revoked and expired evidence must retain all attributes.

```elixir
test "APPLIED non-effective repair preserves historical evidence and another source" do
  fixture = create_committed_suspended_effect_fixture!("jc248_exact_non_effective")
  independent = create_other_subscription_fixture!(fixture)
  now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

  assert {:ok, :applied} =
           Sandbox.unboxed_run(Repo, fn ->
             Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
           end)

  effect_before = fetch_effect!(fixture.effect_id)

  for suffix <- ["a", "b"] do
    create_grant!(fixture, "#{fixture.effect_id}:stale:#{suffix}", :active,
      valid_from_at: DateTime.add(now, -60, :second),
      valid_to_at: DateTime.add(now, 3_600, :second))
  end

  create_grant!(fixture, "#{fixture.effect_id}:expired-history", :expired,
    valid_from_at: DateTime.add(now, -7_200, :second),
    valid_to_at: DateTime.add(now, -3_600, :second))

  independent_grant =
    create_grant!(fixture, "#{fixture.effect_id}:other-source", :active,
      source_id: independent.id,
      valid_from_at: DateTime.add(now, -60, :second),
      valid_to_at: DateTime.add(now, 3_600, :second))

  history_before =
    fixture.subscription_id |> grants_for_source!() |> Enum.reject(&(&1.status == :active))

  independent_before = fetch_grant!(independent_grant.id)

  assert {:ok, :repaired} =
           Sandbox.unboxed_run(Repo, fn ->
             Facade.repair_applied_access_effect_for_system(fixture.effect_id)
           end)

  source_after = grants_for_source!(fixture.subscription_id)
  refute Enum.any?(source_after, &(&1.status == :active))

  Enum.each(history_before, fn historical ->
    assert entitlement_grant_attributes(Enum.find(source_after, &(&1.id == historical.id))) ==
             entitlement_grant_attributes(historical)
  end)

  assert fetch_grant!(independent_grant.id) == independent_before
  assert fetch_effect!(fixture.effect_id) == effect_before
end
```

- [x] Run the two execution modules before changing any production behavior. These prove existing repair invariants and may pass immediately. Do not manufacture a RED result. A real failure requires systematic debugging and a focused root decision.
- [x] Run format checks, scoped positional strict Credo, compile warnings-as-errors and migration alignment. Self-review and commit only the two test modules. Report exact head, observed test counts and any unresolved limitation. Independent spec review precedes quality review.

Every Mix command uses the sequential command prefix:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix`

Root self-review checked helper signatures, source ownership, full APPLIED comparisons, historical metadata preservation and cleanup. A separate measurement task supplies bounded resource and natural query-plan evidence before final repository checks.

Implementation `8f03342b0e1ae4ac4952942f6e57dc0e92ecfef9` passed independent specification and quality reviews against its verified parent `ba2ff322a6f8186fde12a46e903d303fe75ac17d`. Root inspected the full 181-line diff and observed the saved final run with 74 tests and zero failures. Format, scoped strict Credo, warnings-as-errors compile, migration alignment and diff checks passed. No production defect or production change arose from this proof task.
