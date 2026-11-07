# JC-248 concurrency proof implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Prove on separate PostgreSQL connections that delayed discovery and blocked repair cannot overwrite a newer target.

**Architecture:** Extend the existing required real-connection source-fence module, whose CI command already runs twice. Use the accepted verification and repair facades, with explicit task and fixture cleanup. Change production code only if a focused failing regression identifies a defect and root approves the correction within JC-248 scope.

**Tech stack:** Elixir, ExUnit, PostgreSQL physical connections, Ash, Oban manual testing, DevCore.

## Task 6: Concurrency proof

Modify only `test/store/subscriptions/source_fence_contention_test.exs`. Existing CI already includes the source-fence module in both required real-connection repetitions, so no new workflow or test pool is needed. Add aliases for `AppliedAccessVerificationQuery`, `ReconcileSubscriptionAccessInput` where used.

- [ ] Add this separate-connection delayed-target test to the source-fence module. Use the existing committed pair fixture and exact cleanup helper. A checked-out old worker deliberately owns no transaction while waiting. The later producer commits before the delayed repair runs. Test-only SQL simulates the durable source transition; it must establish the new target in the same transaction.

```elixir
test "a delayed drift candidate cannot recreate access after a newer non-effective target" do
  fixtures = create_committed_sources!()
  fixture = fixtures.x
  run_ref = make_ref()
  parent = self()

  try do
    assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
    scan_time = ~U[2097-01-01 00:00:00Z]
    Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
      Ecto.UUID.dump!(fixture.effect.id), scan_time
    ])
    old_effect = fetch_jc248_effect!(fixture.effect.id)

    Repo.query!(
      "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)]
    )

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: scan_time, after_inserted_at: scan_time,
               after_id: "00000000-0000-0000-0000-000000000000", limit: 1
             })

    assert {:ok, page} = Facade.verify_subscription_access_window_for_system(query)
    assert candidate = Enum.find(page.repairs, &(&1.subscription_id == fixture.subscription.id))
    assert candidate.expected_access_effect_id == old_effect.id

    old_worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          send(parent, {run_ref, :old_ready, backend_pid!(), Repo.in_transaction?()})

          receive do
            {^run_ref, :release} ->
              Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                subscription_id: candidate.subscription_id,
                expected_access_effect_id: candidate.expected_access_effect_id
              })
          after
            @task_timeout -> {:error, :barrier_timeout}
          end
        end)
      end)

    try do
      assert_receive {^run_ref, :old_ready, old_pid, false}, @task_timeout

      producer =
        Task.async(fn ->
          Repo.checkout(fn ->
            pid = backend_pid!()

            assert {:ok, effect} =
                     Repo.transaction(fn ->
                       Repo.query!(
                         "UPDATE subscriptions SET status = 'suspended' WHERE id = $1",
                         [Ecto.UUID.dump!(fixture.subscription.id)]
                       )

                       establish_newer_non_effective_effect!(fixture)
                     end)

            assert {:ok, :applied} = Facade.execute_suspension_access_effect_for_system(effect.id)
            {pid, effect.id}
          end)
        end)

      {producer_pid, current_id} =
        try do
          Task.await(producer, @transaction_timeout)
        after
          Task.shutdown(producer, :brutal_kill)
        end

      assert producer_pid != old_pid
      current_effect = fetch_jc248_effect!(current_id)
      current_grants = grants_for_source!(fixture.subscription.id)
      send(old_worker.pid, {run_ref, :release})
      assert {:ok, :stale} = Task.await(old_worker, @transaction_timeout)
      assert fetch_jc248_effect!(current_id) == current_effect
      assert fetch_jc248_effect!(old_effect.id) == old_effect
      assert grants_for_source!(fixture.subscription.id) == current_grants
      refute Enum.any?(current_grants, &(&1.status == :active))

      IO.puts(
        Jason.encode!(%{
          tag: "JC248_DELAYED_CANDIDATE",
          old_backend_pid: old_pid,
          producer_backend_pid: producer_pid,
          outcome: :stale,
          old_effect_id: old_effect.id,
          current_effect_id: current_id,
          transaction_during_barrier: false
        })
      )
    after
      Task.shutdown(old_worker, :brutal_kill)
    end
  after
    cleanup_owned_sources!(fixtures)
  end
end
```

- [ ] Verify every producer and repair task is awaited or terminated before fixture cleanup. Keep the nested cleanup structure when adding assertions; do not change production or cleanup timeouts.

- [ ] Add a real blocked-repair test with producer-first source locking. Reuse existing `backend_pid!`, `await_blocking_pid!`, `wait_for_release!` and committed fixture cleanup. The nested cleanup releases or terminates both task handles before deleting owned fixtures.

```elixir
test "an APPLIED repair blocked behind a newer producer revalidates and leaves another source free" do
  fixtures = create_committed_sources!()

  try do
    fixture = fixtures.x
    assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

    assert {:ok, :applied} =
             Facade.execute_effective_access_effect_for_system(fixtures.y.effect.id)

    old_effect = fetch_jc248_effect!(fixture.effect.id)
    independent_grants = grants_for_source!(fixtures.y.subscription.id)

    Repo.query!(
      "UPDATE entitlement_grants SET valid_to_at = valid_to_at + interval '1 day' WHERE source_kind = 'subscription' AND source_id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)]
    )

    run_ref = make_ref()
    parent = self()

    producer =
      Task.async(fn ->
        Repo.checkout(fn ->
          producer_pid = backend_pid!()

          assert {:ok, effect} =
                   Repo.transaction(
                     fn ->
                       Repo.query!(
                         "UPDATE subscriptions SET status = 'suspended' WHERE id = $1",
                         [Ecto.UUID.dump!(fixture.subscription.id)]
                       )

                       effect = establish_newer_non_effective_effect!(fixture)
                       send(parent, {run_ref, :producer_holding, producer_pid, effect.id})
                       wait_for_release!(run_ref)
                       effect
                     end,
                     timeout: @transaction_timeout
                   )

          {effect.id, Facade.execute_suspension_access_effect_for_system(effect.id)}
        end)
      end)

    try do
      assert_receive {^run_ref, :producer_holding, producer_pid, current_id}, @task_timeout

      repair =
        Task.async(fn ->
          Repo.checkout(fn ->
            send(parent, {run_ref, :repair_started, backend_pid!()})
            Facade.repair_applied_access_effect_for_system(fixture.effect.id)
          end)
        end)

      try do
        assert_receive {^run_ref, :repair_started, repair_pid}, @task_timeout
        assert producer_pid != repair_pid
        blockers = await_blocking_pid!(repair_pid, producer_pid)
        assert producer_pid in blockers

        assert {:ok, :already_converged} =
                 Facade.repair_applied_access_effect_for_system(fixtures.y.effect.id)

        assert grants_for_source!(fixtures.y.subscription.id) == independent_grants
        send(producer.pid, {run_ref, :release})
        assert {:ok, :stale} = Task.await(repair, @transaction_timeout)
        assert {^current_id, {:ok, :applied}} = Task.await(producer, @transaction_timeout)

        assert %AccessEffect{status: :applied, disposition: :non_effective} =
                 fetch_jc248_effect!(current_id)

        assert fetch_jc248_effect!(fixture.effect.id) == old_effect
        refute Enum.any?(grants_for_source!(fixture.subscription.id), &(&1.status == :active))

        IO.puts(
          Jason.encode!(%{
            tag: "JC248_FENCE_CONTENTION",
            producer_backend_pid: producer_pid,
            repair_backend_pid: repair_pid,
            blocking_backend_pids: blockers,
            independent_source_progress: true,
            repair_outcome: :stale
          })
        )
      after
        Task.shutdown(repair, :brutal_kill)
      end
    after
      send(producer.pid, {run_ref, :release})
      Task.shutdown(producer, :brutal_kill)
    end
  after
    cleanup_owned_sources!(fixtures)
  end
end
```

- [ ] Add the exact effect reader used above. It is test-only and reads through the resource action.

```elixir
defp fetch_jc248_effect!(id) do
  AccessEffect
  |> Ash.Query.filter(expr(id == ^id))
  |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
end
```

## Validation and handoff

- [ ] Run both focused execution modules and all four required real-connection modules. Run the required real-connection command twice and preserve distinct logs. Existing CI already runs the four paths below twice.

```text
test/store/subscriptions/source_fence_contention_test.exs
test/store/subscriptions/access_effect_target_order_contention_test.exs
test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs
test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs
```

- [ ] Run format checks, scoped strict Credo with positional file paths, compile warnings-as-errors and migration alignment. Self-review/commit only the real-connection test changes, with exact head and observed limits. Independent spec and quality review follow. A separate Task7 covers the remaining exact-source acceptance matrix and repeated resource measurements. Root then inspects the entire ticket diff, removes temporary implementation plans from the final PR diff while retaining ignored local copies/history, and runs the complete repository gates and exact-head reviews before publication.

Every Mix command is sequential and uses:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix`

Use `test --only real_connections` followed by the four paths for the required repetitions. Do not start another test pool or PostgreSQL/Redis stack. No production edits, test skips, weakened query bounds or timing guarantees are authorized by a passing fixture run.

Root self-review confirmed the two test bodies and reader parse as Elixir, task cleanup precedes owned fixture cleanup, and existing required CI paths cover both repetitions. Production capacity and arbitrary source-history fanout are outside this task.
