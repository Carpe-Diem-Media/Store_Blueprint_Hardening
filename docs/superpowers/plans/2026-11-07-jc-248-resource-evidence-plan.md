# JC-248 resource evidence implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Record two equivalent bounded samples of discovery and APPLIED repair, including natural PostgreSQL plans and resource cleanup.

**Architecture:** Add one focused test to the existing effective execution module. A dedicated process measures each operation, so the test process's fixture registrations and setup messages do not contaminate its mailbox or memory sample. Use existing DevCore services, pools and committed fixtures.

**Tech stack:** Elixir, ExUnit, RepoStats, PostgreSQL EXPLAIN, DBConnection metrics, DevCore.

## Task 8: Repeated bounded measurements

Modify `test/store/subscriptions/access_effect_effective_execution_test.exs`. Append measured results and limitations to `docs/superpowers/specs/2026-11-07-jc-248-entitlement-reconciliation-design.md`. No production change, new pool, vacuum, planner override, telemetry dependency or benchmark service is authorized.

- [ ] Add the test below. The fixed cursor isolates these committed fixtures from unrelated private diagnostic rows. Historical grants enter PostgreSQL as revoked immediately, rather than producing dead active-index entries through mass updates. Existing helpers create and clean owned rows. Setup, explicit corruption, EXPLAIN and cleanup SQL stay outside API query counts.

```elixir
@tag :jc248_resource_evidence
test "JC248 discovery and repair have repeated bounded resource evidence" do
  for repetition <- 1..2 do
    fixtures =
      Enum.map(1..16, fn index ->
        create_committed_effective_effect_fixture!("jc248_resource_#{repetition}_#{index}")
      end)

    timestamp = DateTime.add(~U[2094-01-01 00:00:00Z], repetition, :day)

    try do
      Sandbox.unboxed_run(Repo, fn ->
        Enum.each(fixtures, fn fixture ->
          assert {:ok, :applied} =
                   Facade.execute_effective_access_effect_for_system(fixture.effect.id)

          insert_revoked_history!(fixture, 128, timestamp)

          Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
            Ecto.UUID.dump!(fixture.effect.id), timestamp
          ])
        end)
      end)

      assert {:ok, page_query} =
               AppliedAccessVerificationQuery.new(%{
                 as_of: timestamp,
                 after_inserted_at: timestamp,
                 after_id: "00000000-0000-0000-0000-000000000000",
                 limit: 16
               })

      for page_size <- [1, 16] do
        query = %{page_query | limit: page_size}
        sample = jc248_measure_operation!(fn ->
          Facade.verify_subscription_access_window_for_system(query)
        end)

        assert {:ok, result} = sample.result
        assert result.healthy_count == page_size
        assert result.raw_count == page_size
        assert result.repairs == []
        assert result.conflicts == []
        assert sample.stats.query_count == 2
        jc248_print_measurement!(sample, repetition, "healthy_verification_#{page_size}")
      end

      Sandbox.unboxed_run(Repo, fn ->
        ids = Enum.map(fixtures, & &1.subscription.id)
        assert {:ok, grants_query} = SubscriptionSourceVerificationQuery.new(%{source_ids: ids})
        sorted_ids = BinaryUuidSort.sort_uuids(ids)
        <<first::unsigned-big-128>> = Ecto.UUID.dump!(hd(sorted_ids))
        predecessor = Ecto.UUID.load!(<<(first - 1)::unsigned-big-128>>)

        assert {:ok, inventory_query} =
                 SubscriptionAccessInventoryQuery.new(%{
                   through_id: List.last(sorted_ids), after_id: predecessor, limit: 16
                 })

        for {operation, query} <- [
              {"applied_window", AppliedAccessVerificationQuery.to_ecto(page_query)},
              {"active_source_batch", SubscriptionSourceVerificationQuery.to_ecto(grants_query)},
              {"authority_inventory", SubscriptionAccessInventoryQuery.to_ecto(inventory_query)}
            ] do
          {sql, params} = EctoSQL.to_sql(:all, Repo, query)
          %{rows: [[plan]]} =
            Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

          IO.puts("JC248_RESOURCE_QUERY_PLAN " <> Jason.encode!(%{
            repetition: repetition, operation: operation, plan: plan,
            sources: 16, initially_revoked_rows_per_source: 128,
            explicit_statistics_refresh: false, planner_override: false,
            limits: "natural local plan; fixture volume and existing private diagnostic rows only"
          }))
        end
      end)

      fixture = hd(fixtures)
      effect_before = fetch_effect!(fixture.effect.id)
      history_before = grants_for_source!(fixture.subscription.id)
                       |> Enum.reject(&(&1.status == :active))
      assert length(history_before) == 128

      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1 AND status = 'active'",
          [Ecto.UUID.dump!(fixture.subscription.id)]
        )
      end)

      repair_sample = jc248_measure_operation!(fn ->
        Facade.repair_applied_access_effect_for_system(fixture.effect.id)
      end)

      assert repair_sample.result == {:ok, :repaired}
      assert fetch_effect!(fixture.effect.id) == effect_before
      after_grants = grants_for_source!(fixture.subscription.id)
      assert length(Enum.filter(after_grants, &(&1.status == :active))) == 1

      Enum.each(history_before, fn historical ->
        assert Enum.find(after_grants, &(&1.id == historical.id)) == historical
      end)

      jc248_print_measurement!(repair_sample, repetition, "applied_missing_grant_repair")

      stale_timestamp = DateTime.add(timestamp, 1, :second)

      Sandbox.unboxed_run(Repo, fn ->
        create_newer_untransitioned_effect!(fixture)
        Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
          Ecto.UUID.dump!(fixture.effect.id), stale_timestamp
        ])
      end)

      assert {:ok, stale_query} =
               AppliedAccessVerificationQuery.new(%{
                 as_of: stale_timestamp, after_inserted_at: stale_timestamp,
                 after_id: "00000000-0000-0000-0000-000000000000", limit: 1
               })

      stale_sample = jc248_measure_operation!(fn ->
        Facade.verify_subscription_access_window_for_system(stale_query)
      end)

      assert {:ok, %{raw_count: 1, stale_count: 1, repairs: []}} = stale_sample.result
      assert stale_sample.stats.query_count == 1
      jc248_print_measurement!(stale_sample, repetition, "stale_verification_1")
    after
      Enum.each(fixtures, &cleanup_fixture!/1)
    end

    Sandbox.unboxed_run(Repo, fn ->
      ids = Enum.map(fixtures, &Ecto.UUID.dump!(&1.subscription.id))

      for {table, predicate} <- [
            {"subscriptions", "id"}, {"access_effects", "subscription_id"},
            {"entitlement_grants", "source_id"}
          ] do
        assert %{rows: [[0]]} =
                 Repo.query!("SELECT count(*) FROM " <> table <> " WHERE " <>
                   predicate <> " = ANY($1::uuid[])", [ids])
      end
    end)

    IO.puts("JC248_RESOURCE_CLEANUP " <> Jason.encode!(%{
      repetition: repetition, owned_subscription_rows: 0,
      owned_effect_rows: 0, owned_grant_rows: 0,
      limits: "owned fixture identities only; unrelated database rows preserved"
    }))
  end
end
```

- [ ] Add these helpers to the same test module. Measure the Store.Repo API separately from queue operations on DirectRepo. Check process dictionary cleanup for RepoStats and compare pool metrics after the measurement process returns. The Sandbox owner can hold one connection, so compare to the actual baseline instead of asserting all four connections are ready.

```elixir
defp jc248_measure_operation!(operation) do
  pool_before = jc248_pool_metrics()

  task = Task.async(fn ->
    Sandbox.unboxed_run(Repo, fn ->
      :erlang.garbage_collect()
      {:memory, memory_before} = Process.info(self(), :memory)
      {:message_queue_len, mailbox_before} = Process.info(self(), :message_queue_len)
      handlers_before = length(:telemetry.list_handlers([:store, :repo, :query]))
      dictionary_before = Process.get_keys() |> MapSet.new()
      {gc_before, words_before, _} = :erlang.statistics(:garbage_collection)
      started = System.monotonic_time(:microsecond)
      {result, stats} = RepoStats.capture(operation)
      wall_us = System.monotonic_time(:microsecond) - started
      {:memory, memory_after} = Process.info(self(), :memory)
      :erlang.garbage_collect()
      {:memory, memory_after_gc} = Process.info(self(), :memory)
      {:message_queue_len, mailbox_after} = Process.info(self(), :message_queue_len)
      handlers_after = length(:telemetry.list_handlers([:store, :repo, :query]))
      {gc_after, words_after, _} = :erlang.statistics(:garbage_collection)

      added_repo_stats_keys =
        Process.get_keys() |> MapSet.new() |> MapSet.difference(dictionary_before)
        |> Enum.filter(fn key ->
          is_tuple(key) and tuple_size(key) > 0 and elem(key, 0) == RepoStats
        end)

      assert added_repo_stats_keys == []
      assert handlers_after == handlers_before
      assert mailbox_before == 0
      assert mailbox_after == 0
      refute Repo.in_transaction?()

      %{result: result, stats: stats, wall_us: wall_us,
        memory_before_gc_bytes: memory_before, memory_after_bytes: memory_after,
        memory_after_gc_bytes: memory_after_gc,
        mailbox_before: mailbox_before, mailbox_after: mailbox_after,
        handlers_before: handlers_before, handlers_after: handlers_after,
        global_gc_count_delta: gc_after - gc_before,
        global_reclaimed_words_delta: words_after - words_before,
        transaction_after: false, repo_stats_dictionary_keys_remaining: 0}
    end)
  end)

  try do
    sample = Task.await(task, 30_000)
    pool_after = jc248_pool_metrics()
    assert pool_after == pool_before
    Map.merge(sample, %{pool_before: pool_before, pool_after: pool_after})
  after
    Task.shutdown(task, :brutal_kill)
  end
end

defp jc248_pool_metrics do
  meta = Ecto.Adapter.lookup_meta(Repo)
  DBConnection.get_connection_metrics(meta.pid, pool: Keyword.fetch!(meta.opts, :pool))
  |> Enum.map(&Map.take(&1, [:ready_conn_count, :checkout_queue_length]))
end

defp jc248_print_measurement!(sample, repetition, operation) do
  sample |> Map.delete(:result)
  |> Map.merge(%{tag: "JC248_RESOURCE_MEASUREMENT", repetition: repetition,
    operation: operation, sources: 16, initially_revoked_rows_per_source: 128,
    telemetry_time_unit: "native units",
    limits: "two equivalent bounded local repetitions; global GC is process-external; no capacity or stable-memory claim"})
  |> Jason.encode!() |> IO.puts()
end
```

- [ ] Parse and run the new evidence test. This adds proof of existing behavior and may pass immediately. Do not manufacture a RED result. If pool metrics differ, identify the owner or pending return before changing an assertion; do not replace the check with a fixed sleep or omit cleanup. Remove a metric only if the installed Sandbox pool cannot supply it, and document that dimension as UNMEASURED.
- [ ] Read every measurement and each natural plan. Record actual query counts, wall and queue times, memory before and after GC, mailbox and handler counts, pool return and exact owned cleanup. Identify selected indexes, sequential scans, rows filtered and history volume. Returned index rows do not necessarily reveal internal dead-entry visits; record that dimension as UNMEASURED when the plan does not expose it. No hidden ANALYZE, VACUUM or forced-plan settings are permitted. Background autovacuum is not controlled by this test. If stale statistics explain a slow plan, record that first plan and any explicit bounded follow-up separately.
- [ ] Replace the design's pending-evidence paragraphs with observed results. Discovery's two-row active result bound does not bound source history locked by repair. The locked provenance validation added one fixed SQL read to the existing executor baseline; a non-null captured reference adds one exact historical PK read. Do not describe either cost as zero.
- [ ] Preserve the limits. Production capacity, multi-node behavior, allocator/RSS trends, arbitrary source-history fanout, and durable PubSub delivery after retry exhaustion remain UNMEASURED. Two local samples do not prove stable memory or no accumulation.
- [ ] Run both execution modules, format, positional scoped strict Credo, compile warnings-as-errors and migration alignment. Self-review and commit only the test module and design. Report exact head and observed evidence for independent spec and quality reviews.

Every Mix command uses this sequential prefix:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix`

Root self-review checked helper names, native UUID ordering, fixed historical cursors, initial revoked-history insertion, exact APPLIED preservation, dedicated-process ownership and cleanup. All code blocks must parse before dispatch. The final ticket review and full repository gates follow this task.
