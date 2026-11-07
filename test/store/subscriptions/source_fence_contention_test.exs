defmodule Store.Subscriptions.SourceFenceContentionTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 60_000

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.Order
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, AccessEffectCurrentnessFence}
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput
  alias Store.Subscriptions.Queries.AppliedAccessVerificationQuery
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.RenewalCollectionAttempt
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  @start_timeout 30_000
  @transaction_timeout 30_000
  @task_timeout 10_000
  @blocking_timeout 8_000
  @jc247_b_barrier_timeout 15_000

  setup_all do
    assert_test_database!()

    pool_size = Repo.config()[:pool_size]

    unless is_integer(pool_size) and pool_size >= 3 do
      raise "real connection proof requires Store.Repo pool_size >= 3, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)

    {:ok, %{effective_repo_pool_size: pool_size}}
  end

  setup do
    direct_repo_owner = Sandbox.start_owner!(Store.DirectRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(direct_repo_owner) end)
    {:ok, direct_repo_owner: direct_repo_owner}
  end

  test "same subscription blocks while an independent subscription proceeds", context do
    fixtures = create_committed_sources!()

    try do
      run_contention!(fixtures, context.effective_repo_pool_size)
    after
      cleanup_owned_sources!(fixtures)
    end
  end

  test "duplicate EFFECTIVE workers serialize and converge one exact grant" do
    fixtures = create_committed_sources!()
    fixture = fixtures.x
    parent = self()

    try do
      workers =
        for _ <- 1..2 do
          Task.async(fn ->
            Repo.checkout(fn ->
              send(parent, {:effective_worker_ready, self()})

              receive do
                :execute -> Facade.execute_effective_access_effect_for_system(fixture.effect.id)
              after
                @task_timeout -> {:error, :barrier_timeout}
              end
            end)
          end)
        end

      worker_pids =
        for _ <- 1..2 do
          assert_receive {:effective_worker_ready, pid}, @task_timeout
          pid
        end

      Enum.each(worker_pids, &send(&1, :execute))
      results = Enum.map(workers, &Task.await(&1, @transaction_timeout))

      assert Enum.count(results, &(&1 == {:ok, :applied})) == 1
      assert Enum.count(results, &(&1 == {:ok, :noop})) == 1
      assert_effective_grant!(fixture)
    after
      cleanup_owned_sources!(fixtures)
    end
  end

  test "a newer target producer and EFFECTIVE executor serialize in both lock-arrival orders" do
    producer_first = create_committed_sources!()

    try do
      run_producer_executor_race!(producer_first.x, :producer_first)
      assert fetch_effect_status!(producer_first.x.effect.id) == "superseded"
      assert latest_effect_disposition!(producer_first.x.subscription.id) == "non_effective"
      assert grants_for_source!(producer_first.x.subscription.id) == []
    after
      cleanup_owned_sources!(producer_first)
    end

    executor_first = create_committed_sources!()

    try do
      run_producer_executor_race!(executor_first.x, :executor_first)
      assert fetch_effect_status!(executor_first.x.effect.id) == "applied"
      assert latest_effect_disposition!(executor_first.x.subscription.id) == "non_effective"
      assert_effective_grant!(executor_first.x)
    after
      cleanup_owned_sources!(executor_first)
    end
  end

  test "ordinary legacy issue and F1 convergence contend safely in both arrival orders" do
    legacy_first = create_committed_sources!()

    try do
      assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(legacy_first.y) end)
      unrelated_before = grants_for_source!(legacy_first.y.subscription.id)
      run_legacy_executor_race!(legacy_first.x, :legacy_first)
      assert_effective_grant!(legacy_first.x)
      assert grants_for_source!(legacy_first.y.subscription.id) == unrelated_before
    after
      cleanup_owned_sources!(legacy_first)
    end

    executor_first = create_committed_sources!()

    try do
      assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(executor_first.y) end)
      unrelated_before = grants_for_source!(executor_first.y.subscription.id)
      run_legacy_executor_race!(executor_first.x, :executor_first)
      assert_effective_grant!(executor_first.x)
      assert grants_for_source!(executor_first.y.subscription.id) == unrelated_before
    after
      cleanup_owned_sources!(executor_first)
    end
  end

  test "F2 holds the Subscription mutex through exact-source convergence and APPLIED commit" do
    fixtures = create_committed_sources!()
    fixture = prepare_non_effective_source!(fixtures.x)
    run_ref = make_ref()
    parent = self()

    try do
      {grant_barrier, barrier_pid, _grant_id} =
        start_source_grant_lock_barrier!(fixture, run_ref)

      executor =
        Task.async(fn ->
          Repo.checkout(fn ->
            executor_pid = backend_pid!()
            send(parent, {run_ref, :f2_executor_started, executor_pid})
            Facade.execute_suspension_access_effect_for_system(fixture.effect.id)
          end)
        end)

      executor_pid = receive_race_event!(run_ref, :f2_executor_started)

      executor_blockers =
        assert_blocked_by_barrier!(
          grant_barrier,
          run_ref,
          executor_pid,
          barrier_pid,
          :f2_executor_at_source_convergence
        )

      producer =
        Task.async(fn ->
          Repo.transaction(fn ->
            producer_pid = backend_pid!()
            send(parent, {run_ref, :f2_producer_started, producer_pid})
            establish_newer_non_effective_effect!(fixture)
          end)
        end)

      producer_pid = receive_race_event!(run_ref, :f2_producer_started)

      producer_blockers =
        assert_blocked_by_barrier!(
          grant_barrier,
          run_ref,
          producer_pid,
          executor_pid,
          :f2_producer_waiting_for_executor
        )

      status_before_release =
        read_effect_status_from_barrier!(grant_barrier, run_ref, fixture.effect.id)

      assert status_before_release == "required"
      send(grant_barrier.pid, {run_ref, :release})

      assert {:ok, :released} = Task.await(grant_barrier, @task_timeout)
      assert {:ok, :applied} = Task.await(executor, @transaction_timeout)

      assert {:ok, %AccessEffect{status: :required} = newer_effect} =
               Task.await(producer, @transaction_timeout)

      assert fetch_effect_status!(fixture.effect.id) == "applied"
      assert latest_effect_id!(fixture.subscription.id) == newer_effect.id
      assert latest_effect_disposition!(fixture.subscription.id) == "non_effective"

      assert [%EntitlementGrant{status: :revoked, revoked_reason: "grace_expired"}] =
               grants_for_source!(fixture.subscription.id)

      IO.puts(
        "F2_REAL_CONNECTION executor_pid=#{executor_pid} executor_blockers=#{inspect(executor_blockers)} " <>
          "producer_pid=#{producer_pid} producer_blockers=#{inspect(producer_blockers)} " <>
          "status_before_release=#{status_before_release} f2_committed_before_producer=true"
      )
    after
      cleanup_owned_sources!(fixtures)
    end
  end

  test "F2 re-proves currentness before recording a rollback after a newer target wins" do
    fixtures = create_committed_sources!()
    fixture = prepare_non_effective_source!(fixtures.x)
    run_ref = make_ref()
    parent = self()
    constraint = "jc246_fail_revoke_#{System.unique_integer([:positive])}"
    grant = hd(grants_for_source!(fixture.subscription.id))

    Repo.query!("""
    ALTER TABLE entitlement_grants
    ADD CONSTRAINT #{constraint}
    CHECK (status <> 'revoked' OR id <> '#{grant.id}')
    NOT VALID
    """)

    {grant_barrier, barrier_pid, _grant_id} =
      start_source_grant_lock_barrier!(fixture, run_ref)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :f2_failure_executor_started, executor_pid})
          Facade.execute_suspension_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :f2_failure_executor_started)

    assert_blocked_by_barrier!(
      grant_barrier,
      run_ref,
      executor_pid,
      barrier_pid,
      :f2_failure_executor_at_source_convergence
    )

    producer =
      Task.async(fn ->
        Repo.transaction(fn ->
          producer_pid = backend_pid!()
          send(parent, {run_ref, :f2_failure_producer_started, producer_pid})
          insert_newer_non_effective_effect_without_superseding!(fixture)
        end)
      end)

    producer_pid = receive_race_event!(run_ref, :f2_failure_producer_started)

    producer_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        producer_pid,
        executor_pid,
        :f2_failure_producer_waiting_for_executor
      )

    send(grant_barrier.pid, {run_ref, :release})

    try do
      assert {:ok, :released} = Task.await(grant_barrier, @task_timeout)
      assert {:error, _reason} = Task.await(executor, @transaction_timeout)

      assert {:ok, %AccessEffect{status: :required} = newer_effect} =
               Task.await(producer, @transaction_timeout)

      assert fetch_effect_status!(fixture.effect.id) == "superseded"
      assert fetch_effect_status!(newer_effect.id) == "required"

      assert [%EntitlementGrant{status: :active, revoked_at: nil}] =
               grants_for_source!(fixture.subscription.id)

      IO.puts(
        "F2_FAILURE_REPROOF executor_pid=#{executor_pid} producer_pid=#{producer_pid} " <>
          "producer_blockers=#{inspect(producer_blockers)} older_effect=superseded " <>
          "grant_rollback=complete"
      )
    after
      Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT IF EXISTS #{constraint}")
      cleanup_owned_sources!(fixtures)
    end
  end

  test "a delayed drift candidate cannot recreate access after a newer non-effective target" do
    fixtures = create_committed_sources!()
    fixture = fixtures.x
    run_ref = make_ref()
    parent = self()

    try do
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      scan_time = ~U[2097-01-01 00:00:00Z]

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.effect.id),
        scan_time
      ])

      old_effect = fetch_jc248_effect!(fixture.effect.id)

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

      assert {:ok, query} =
               AppliedAccessVerificationQuery.new(%{
                 as_of: scan_time,
                 after_inserted_at: scan_time,
                 after_id: "00000000-0000-0000-0000-000000000000",
                 limit: 1
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

              assert {:ok, :applied} =
                       Facade.execute_suspension_access_effect_for_system(effect.id)

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

  test "an APPLIED repair blocked behind a newer producer revalidates and leaves another source free" do
    fixtures = create_committed_sources!()

    try do
      fixture = fixtures.x

      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

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

  @tag :real_connections
  test "JC247-B paid recovery wins before the paused stale B executor", context do
    StripeAPIStub.setup_default(context)
    fixture = create_committed_b_due_fixture!("recovery_first")
    establish_jc247_b_initial_effective_access!(fixture)
    original_grant = hd(grants_for_source!(fixture.subscription.id))
    payment_phase = :atomics.new(1, [])
    :atomics.put(payment_phase, 1, 1)
    stub_b_payment_phase!(payment_phase)

    barrier = make_ref()
    handler_id = attach_jc247_b_dunning_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    failure_task = start_jc247_b_failure_task(context, fixture)
    assert_receive {:jc247_b_dunning_paused, ^barrier, subscription_id}, @task_timeout
    [original_effect, old_effect] = access_effects_for_subscription!(subscription_id)
    assert original_effect.disposition == :effective
    assert old_effect.disposition == :non_effective
    assert old_effect.status == :required

    :atomics.put(payment_phase, 1, 2)
    recovery_task = start_jc247_b_recovery_task(context, fixture, barrier)
    assert {:ok, :reconciled} = Task.await(recovery_task, @transaction_timeout)

    recovered_effect = latest_access_effect!(subscription_id)
    assert recovered_effect.id != old_effect.id
    assert recovered_effect.disposition == :effective
    assert recovered_effect.status == :applied
    assert active_grants_for_source!(subscription_id) != []

    grants_before_stale_executor = grants_for_source!(subscription_id)
    send(failure_task.pid, {barrier, :release_dunning})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @transaction_timeout)

    assert fetch_access_effect!(old_effect.id).status == :superseded
    assert grants_for_source!(subscription_id) == grants_before_stale_executor
    assert active_grants_for_source!(subscription_id) != []
    assert fetch_subscription!(subscription_id).status == :active
    assert Enum.any?(active_grants_for_source!(subscription_id), &(&1.id != original_grant.id))
    cleanup_committed_b_fixture!(fixture)
  end

  @tag :real_connections
  test "JC247-B convergence locks first, then paid recovery establishes newer EFFECTIVE access",
       context do
    StripeAPIStub.setup_default(context)
    fixture = create_committed_b_due_fixture!("b_executor_first")
    _original_effect = establish_jc247_b_initial_effective_access!(fixture)
    original_grant = hd(grants_for_source!(fixture.subscription.id))
    payment_phase = :atomics.new(1, [])
    :atomics.put(payment_phase, 1, 1)
    stub_b_payment_phase!(payment_phase)

    barrier = make_ref()
    handler_id = attach_jc247_b_dunning_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    failure_task = start_jc247_b_failure_task(context, fixture)

    assert_receive {:jc247_b_dunning_paused, ^barrier, subscription_id}, @task_timeout
    [original_effect, b_effect] = access_effects_for_subscription!(subscription_id)
    assert original_effect.disposition == :effective
    assert b_effect.disposition == :non_effective
    assert b_effect.status == :required
    attempt = fetch_attempt!(subscription_id)

    {attempt_barrier, attempt_barrier_pid} =
      start_jc247_b_recovery_order_barrier!(attempt.id, original_grant.id, barrier)

    :ok = Sandbox.checkin(Repo)

    executor_task = start_jc247_b_executor_task(b_effect.id, barrier)
    executor_pid = receive_jc247_b_event!(barrier, :executor_started)

    executor_blockers =
      await_jc247_b_lock_blocker!(
        executor_pid,
        attempt_barrier_pid,
        context.direct_repo_owner
      )

    :atomics.put(payment_phase, 1, 2)
    recovery_task = start_jc247_b_recovery_task(context, fixture, barrier)
    recovery_pid = receive_jc247_b_event!(barrier, :recovery_started)

    recovery_blockers =
      await_jc247_b_lock_blocker!(recovery_pid, executor_pid, context.direct_repo_owner)

    send(attempt_barrier.pid, {barrier, :release_b_grant_lock})
    assert_receive {^barrier, :b_grant_lock_released, ^attempt_barrier_pid}, @task_timeout
    assert {:ok, :applied} = Task.await(executor_task, @transaction_timeout)

    _attempt_blockers =
      await_jc247_b_lock_blocker!(
        recovery_pid,
        attempt_barrier_pid,
        context.direct_repo_owner
      )

    assert Enum.any?(grants_for_source!(subscription_id), fn grant ->
             grant.id == original_grant.id and grant.status == :revoked and
               grant.revoked_reason == "past_due_remove_immediately"
           end)

    send(attempt_barrier.pid, {barrier, :release_recovery_lock})
    assert {:ok, :released} = Task.await(attempt_barrier, @transaction_timeout)
    assert {:ok, :reconciled} = Task.await(recovery_task, @transaction_timeout)

    assert fetch_access_effect!(b_effect.id).status == :applied
    assert latest_access_effect!(subscription_id).disposition == :effective
    assert fetch_subscription!(subscription_id).status == :active

    assert active_grants_for_source!(subscription_id) != []
    assert Enum.any?(active_grants_for_source!(subscription_id), &(&1.id != original_grant.id))

    send(failure_task.pid, {barrier, :release_dunning})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @transaction_timeout)
    assert active_grants_for_source!(subscription_id) != []

    IO.puts(
      "JC247_B_RECOVERY_RACE order=b_executor_first executor_pid=#{executor_pid} " <>
        "executor_blockers=#{inspect(executor_blockers)} recovery_pid=#{recovery_pid} " <>
        "recovery_blockers=#{inspect(recovery_blockers)} b_applied_before_recovery=true"
    )

    cleanup_committed_b_fixture!(fixture)
  end

  defp run_contention!(%{x: source_x, y: source_y}, pool_size) do
    parent = self()
    run_ref = make_ref()

    task_a =
      start_waiting_task(run_ref, :start_a, fn ->
        run_source_task(parent, run_ref, :a_locked, source_x.effect.id, true)
      end)

    task_b =
      start_waiting_task(run_ref, :start_b, fn ->
        run_source_task(parent, run_ref, :b_started, source_x.effect.id, false)
      end)

    task_c =
      start_waiting_task(run_ref, :start_c, fn ->
        run_source_task(parent, run_ref, :c_started, source_y.effect.id, false)
      end)

    try do
      send(task_a.pid, {run_ref, :start_a})
      {a_pid, a_proof} = receive_event!(run_ref, :a_locked, @task_timeout)
      assert_current_proof!(a_proof, "task A")

      send(task_b.pid, {run_ref, :start_b})
      b_pid = receive_event!(run_ref, :b_started, @task_timeout)

      send(task_c.pid, {run_ref, :start_c})
      c_pid = receive_event!(run_ref, :c_started, @task_timeout)

      assert a_pid != b_pid
      assert a_pid != c_pid
      assert b_pid != c_pid

      c_result = await_task_result!(task_c, @task_timeout)
      assert {:ok, :current} = c_result

      blockers = await_blocking_pid!(b_pid, a_pid)

      send(task_a.pid, {run_ref, :release_a})

      a_result = await_task_result!(task_a, @task_timeout)
      b_result = await_task_result!(task_b, @task_timeout)
      assert {:ok, :current} = a_result
      assert {:ok, :current} = b_result

      IO.puts(
        "REAL_CONNECTIONS pool_size=#{pool_size} a_pid=#{a_pid} b_pid=#{b_pid} c_pid=#{c_pid} " <>
          "blockers=#{inspect(blockers)} c_current_before_a_release=true " <>
          "a_result=#{inspect(a_result)} b_result_after_release=#{inspect(b_result)}"
      )
    after
      send(task_a.pid, {run_ref, :release_a})
      send(task_b.pid, {run_ref, :cancel})
      send(task_c.pid, {run_ref, :cancel})
      stop_task_bounded(task_c)
      stop_task_bounded(task_b)
      stop_task_bounded(task_a)
    end
  end

  defp run_producer_executor_race!(fixture, :producer_first) do
    parent = self()
    run_ref = make_ref()

    producer =
      Task.async(fn ->
        Repo.transaction(fn ->
          producer_pid = backend_pid!()
          newer = establish_newer_non_effective_effect!(fixture)
          send(parent, {run_ref, :producer_locked, producer_pid, newer.id})
          wait_for_release!(run_ref)
        end)
      end)

    {producer_pid, newer_id} = receive_race_event!(run_ref, :producer_locked)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)
    await_blocking_pid!(executor_pid, producer_pid)
    send(producer.pid, {run_ref, :release})

    assert {:ok, _} = Task.await(producer, @task_timeout)
    assert {:ok, :noop} = Task.await(executor, @task_timeout)
    assert fetch_effect_status!(newer_id) == "required"
  end

  defp run_producer_executor_race!(fixture, :executor_first) do
    parent = self()
    run_ref = make_ref()

    assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
    {grant_barrier, barrier_pid, _grant_id} = start_source_grant_lock_barrier!(fixture, run_ref)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)

    executor_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        executor_pid,
        barrier_pid,
        :executor_at_source_convergence
      )

    producer =
      Task.async(fn ->
        Repo.transaction(fn ->
          producer_pid = backend_pid!()
          send(parent, {run_ref, :producer_started, producer_pid})
          effect = establish_newer_non_effective_effect!(fixture)
          effect
        end)
      end)

    producer_pid = receive_race_event!(run_ref, :producer_started)

    producer_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        producer_pid,
        executor_pid,
        :producer_waiting_for_executor
      )

    send(grant_barrier.pid, {run_ref, :release})

    assert {:ok, :released} = Task.await(grant_barrier, @task_timeout)
    assert {:ok, :applied} = Task.await(executor, @task_timeout)
    assert {:ok, %AccessEffect{status: :required}} = Task.await(producer, @task_timeout)

    IO.puts(
      "REAL_CONNECTIONS executor_first producer_vs_f1 executor_pid=#{executor_pid} " <>
        "grant_barrier_pid=#{barrier_pid} executor_blockers=#{inspect(executor_blockers)} " <>
        "producer_pid=#{producer_pid} producer_blockers=#{inspect(producer_blockers)} " <>
        "executor_committed_before_producer=true"
    )
  end

  defp run_legacy_executor_race!(fixture, :legacy_first) do
    parent = self()
    run_ref = make_ref()

    legacy =
      Task.async(fn ->
        Repo.transaction(fn ->
          legacy_pid = backend_pid!()
          :ok = issue_legacy_grant!(fixture)
          send(parent, {run_ref, :legacy_locked, legacy_pid})
          wait_for_release!(run_ref)
        end)
      end)

    legacy_pid = receive_race_event!(run_ref, :legacy_locked)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)
    await_blocking_pid!(executor_pid, legacy_pid)
    send(legacy.pid, {run_ref, :release})

    assert {:ok, :released} = Task.await(legacy, @task_timeout)
    assert {:ok, :applied} = Task.await(executor, @task_timeout)
  end

  defp run_legacy_executor_race!(fixture, :executor_first) do
    parent = self()
    run_ref = make_ref()

    assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
    {grant_barrier, barrier_pid, grant_id} = start_source_grant_lock_barrier!(fixture, run_ref)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)

    executor_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        executor_pid,
        barrier_pid,
        :executor_at_source_convergence
      )

    legacy =
      Task.async(fn ->
        Repo.transaction(fn ->
          legacy_pid = backend_pid!()
          send(parent, {run_ref, :legacy_started, legacy_pid})
          issue_legacy_grant!(fixture)
        end)
      end)

    legacy_pid = receive_race_event!(run_ref, :legacy_started)

    legacy_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        legacy_pid,
        executor_pid,
        :legacy_waiting_behind_f1
      )

    send(grant_barrier.pid, {run_ref, :release})

    assert {:ok, :released} = Task.await(grant_barrier, @task_timeout)
    assert {:ok, :applied} = Task.await(executor, @task_timeout)
    assert {:ok, :ok} = Task.await(legacy, @task_timeout)

    IO.puts(
      "REAL_CONNECTIONS executor_first legacy_vs_f1 executor_pid=#{executor_pid} " <>
        "grant_id=#{Ecto.UUID.cast!(grant_id)} grant_barrier_pid=#{barrier_pid} " <>
        "executor_blockers=#{inspect(executor_blockers)} legacy_pid=#{legacy_pid} " <>
        "legacy_blockers=#{inspect(legacy_blockers)} f1_committed_before_legacy=true"
    )
  end

  defp start_source_grant_lock_barrier!(fixture, run_ref) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            barrier_pid = backend_pid!()

            %{rows: [[grant_id]]} =
              Repo.query!(
                """
                SELECT id
                FROM entitlement_grants
                WHERE source_kind = 'subscription' AND source_id = $1
                ORDER BY id
                LIMIT 1
                FOR UPDATE
                """,
                [Ecto.UUID.dump!(fixture.subscription.id)]
              )

            send(parent, {run_ref, :grant_barrier_locked, barrier_pid, grant_id})
            await_barrier_observation!(run_ref)
          end,
          timeout: @transaction_timeout
        )
      end)

    {barrier_pid, grant_id} = receive_race_event!(run_ref, :grant_barrier_locked)
    {task, barrier_pid, grant_id}
  end

  defp assert_blocked_by_barrier!(barrier, run_ref, blocked_pid, expected_blocker_pid, label) do
    send(
      barrier.pid,
      {run_ref, :assert_blocked, blocked_pid, expected_blocker_pid, self(), label}
    )

    blockers = receive_race_event!(run_ref, {:blocking_observed, label})
    assert expected_blocker_pid in blockers
    blockers
  end

  defp await_barrier_observation!(run_ref) do
    receive do
      {^run_ref, :assert_blocked, blocked_pid, expected_blocker_pid, observer, label} ->
        blockers = await_blocking_pid!(blocked_pid, expected_blocker_pid)
        send(observer, {run_ref, {:blocking_observed, label}, blockers})
        await_barrier_observation!(run_ref)

      {^run_ref, :read_effect_status, effect_id, observer} ->
        %{rows: [[status]]} =
          Repo.query!(
            "SELECT status::text FROM access_effects WHERE id = $1",
            [Ecto.UUID.dump!(effect_id)]
          )

        send(observer, {run_ref, :effect_status_read, status})
        await_barrier_observation!(run_ref)

      {^run_ref, :release} ->
        :released
    after
      @transaction_timeout -> Repo.rollback(:source_lock_release_timeout)
    end
  end

  defp read_effect_status_from_barrier!(barrier, run_ref, effect_id) do
    send(barrier.pid, {run_ref, :read_effect_status, effect_id, self()})

    receive do
      {^run_ref, :effect_status_read, status} -> status
    after
      @task_timeout -> flunk("timed out reading AccessEffect status from the barrier connection")
    end
  end

  defp establish_newer_non_effective_effect!(fixture) do
    {:ok, %{rows: [[source_version]]}} =
      Repo.query(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

    attrs = %{
      subscription_id: fixture.subscription.id,
      source_version: source_version,
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: fixture.subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    {:ok, input} = EstablishAccessEffectInput.new(attrs)
    {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp prepare_non_effective_source!(fixture) do
    {:ok, effect} =
      Repo.transaction(fn ->
        {:ok, %{rows: [[source_version]]}} =
          Repo.query(
            "UPDATE subscriptions SET status = 'suspended', aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
            [Ecto.UUID.dump!(fixture.subscription.id)]
          )

        attrs = %{
          subscription_id: fixture.subscription.id,
          source_version: source_version,
          disposition: :non_effective,
          entitlement_kind: nil,
          entitlement_scope_key: nil,
          valid_from_at: nil,
          valid_until_at: nil,
          source_order_line_item_id: fixture.line_item.id,
          contract_change_id: fixture.subscription.current_contract_change_id,
          plan_revision_id: fixture.revision.id
        }

        {:ok, input} = EstablishAccessEffectInput.new(attrs)
        {:ok, effect} = Facade.establish_access_effect_for_system(input)
        :ok = issue_legacy_grant!(fixture)
        effect
      end)

    Map.put(fixture, :effect, effect)
  end

  defp insert_newer_non_effective_effect_without_superseding!(fixture) do
    {:ok, %{rows: [[source_version]]}} =
      Repo.query(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    id = Ash.UUIDv7.generate()

    new_effect = %{
      fixture.effect
      | id: id,
        status: :required,
        source_version: source_version,
        inserted_at: now,
        updated_at: now
    }

    fingerprint = AccessEffect.target_fingerprint(new_effect)

    Repo.query!(
      """
      INSERT INTO access_effects (
        id, subscription_id, source_version, disposition, entitlement_kind,
        entitlement_scope_key, valid_from_at, valid_until_at, target_fingerprint,
        inserted_at, updated_at, source_order_line_item_id, contract_change_id,
        plan_revision_id, status
      ) VALUES ($1, $2, $3, 'non_effective', NULL, NULL, NULL, NULL, $4,
                $5, $5, $6, $7, $8, 'required')
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(fixture.subscription.id),
        source_version,
        fingerprint,
        now,
        Ecto.UUID.dump!(fixture.line_item.id),
        optional_uuid_param(fixture.subscription.current_contract_change_id),
        Ecto.UUID.dump!(fixture.revision.id)
      ]
    )

    %{new_effect | target_fingerprint: fingerprint}
  end

  defp optional_uuid_param(nil), do: nil
  defp optional_uuid_param(uuid), do: Ecto.UUID.dump!(uuid)

  defp assert_effective_grant!(fixture) do
    assert [%EntitlementGrant{} = grant] = grants_for_source!(fixture.subscription.id)
    assert grant.status == :active
    assert grant.kind == fixture.effect.entitlement_kind
    assert grant.scope_key == fixture.effect.entitlement_scope_key
    assert grant.valid_from_at == fixture.effect.valid_from_at
    assert grant.valid_to_at == fixture.effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_jc248_effect!(id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_effect_status!(effect_id) do
    {:ok, %{rows: [[status]]}} =
      Repo.query("SELECT status::text FROM access_effects WHERE id = $1", [
        Ecto.UUID.dump!(effect_id)
      ])

    status
  end

  defp latest_effect_disposition!(subscription_id) do
    {:ok, %{rows: [[disposition]]}} =
      Repo.query(
        "SELECT disposition::text FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC LIMIT 1",
        [Ecto.UUID.dump!(subscription_id)]
      )

    disposition
  end

  defp latest_effect_id!(subscription_id) do
    {:ok, %{rows: [[id]]}} =
      Repo.query(
        "SELECT id::text FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC LIMIT 1",
        [Ecto.UUID.dump!(subscription_id)]
      )

    Ecto.UUID.cast!(id)
  end

  defp receive_race_event!(run_ref, event) do
    receive do
      {^run_ref, ^event, value} -> value
      {^run_ref, ^event, pid, value} -> {pid, value}
    after
      @task_timeout -> flunk("timed out waiting for #{event}")
    end
  end

  defp wait_for_release!(run_ref) do
    receive do
      {^run_ref, :release} -> :released
    after
      @transaction_timeout -> Repo.rollback(:source_lock_release_timeout)
    end
  end

  defp start_waiting_task(run_ref, start_tag, task_fun) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          receive do
            {^run_ref, ^start_tag} -> task_fun.()
            {^run_ref, :cancel} -> :cancelled
          after
            @start_timeout -> {:error, :start_timeout}
          end

        send(parent, {run_ref, :task_result, self(), result})
      end)

    %{pid: pid, monitor_ref: monitor_ref, run_ref: run_ref}
  end

  defp run_source_task(parent, run_ref, event, access_effect_id, hold_lock?) do
    Repo.transaction(
      fn ->
        backend_pid = backend_pid!()
        if event != :a_locked, do: send(parent, {run_ref, event, backend_pid})

        proof = AccessEffectCurrentnessFence.prove(access_effect_id)

        if event == :a_locked do
          send(parent, {run_ref, event, backend_pid, proof})
        end

        assert_current_proof!(proof, "#{event}")

        if hold_lock? do
          receive do
            {^run_ref, :release_a} -> :current
            {^run_ref, :cancel} -> Repo.rollback(:cancelled)
          after
            @transaction_timeout -> Repo.rollback(:source_lock_release_timeout)
          end
        else
          :current
        end
      end,
      timeout: @transaction_timeout
    )
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp receive_event!(run_ref, event, timeout) do
    receive do
      {^run_ref, ^event, value} -> value
      {^run_ref, ^event, pid, proof} -> {pid, proof}
    after
      timeout -> flunk("timed out waiting for #{event}")
    end
  end

  defp await_blocking_pid!(blocked_pid, expected_blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @blocking_timeout
    poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, [])
  end

  defp poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, last_blockers) do
    %{rows: [[blockers]]} =
      Repo.query!("SELECT pg_blocking_pids($1)", [blocked_pid], timeout: 1_000)

    cond do
      expected_blocker_pid in blockers ->
        blockers

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "PostgreSQL did not report backend #{expected_blocker_pid} blocking " <>
            "backend #{blocked_pid}; last pg_blocking_pids result was #{inspect(last_blockers)}"
        )

      true ->
        Process.sleep(25)
        poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, blockers)
    end
  end

  defp assert_current_proof!({:ok, %{status: :current}}, _label), do: :ok

  defp assert_current_proof!(proof, label) do
    raise "expected #{label} to prove a current AccessEffect, got #{inspect(proof)}"
  end

  defp await_task_result!(task, timeout) do
    receive do
      {run_ref, :task_result, pid, result}
      when run_ref == task.run_ref and pid == task.pid ->
        Process.demonitor(task.monitor_ref, [:flush])
        result

      {:DOWN, monitor_ref, :process, pid, reason}
      when monitor_ref == task.monitor_ref and pid == task.pid ->
        flunk("contention task exited before returning its result: #{inspect(reason)}")
    after
      timeout ->
        flunk("timed out waiting for contention task #{inspect(task.pid)}")
    end
  end

  defp stop_task_bounded(task) do
    if Process.alive?(task.pid) do
      receive do
        {run_ref, :task_result, pid, _result}
        when run_ref == task.run_ref and pid == task.pid ->
          await_task_exit_bounded(task)

        {:DOWN, monitor_ref, :process, pid, _reason}
        when monitor_ref == task.monitor_ref and pid == task.pid ->
          :ok
      after
        1_000 ->
          Process.exit(task.pid, :kill)
          await_task_exit_bounded(task)
      end
    else
      Process.demonitor(task.monitor_ref, [:flush])
      :ok
    end
  end

  defp await_task_exit_bounded(task) do
    receive do
      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == task.monitor_ref and pid == task.pid ->
        :ok
    after
      1_000 ->
        Process.exit(task.pid, :kill)

        receive do
          {:DOWN, monitor_ref, :process, pid, _reason}
          when monitor_ref == task.monitor_ref and pid == task.pid ->
            :ok
        after
          1_000 -> raise "contention task did not stop after bounded cleanup"
        end
    end
  end

  defp create_committed_sources! do
    assert_test_database!()

    case Repo.transaction(
           fn ->
             %{x: create_source_fixture!("x"), y: create_source_fixture!("y")}
           end,
           timeout: @transaction_timeout
         ) do
      {:ok, fixtures} ->
        fixtures

      {:error, reason} ->
        raise "unable to create committed contention sources: #{inspect(reason)}"
    end
  end

  defp create_source_fixture!(label) do
    unique = Ecto.UUID.generate()
    customer = SubscriptionsFixtures.create_customer!("f0_fence_#{label}_#{unique}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "f0-source-fence-#{label}-#{unique}"
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        create_payment_intent?: false
      })

    effect_input =
      input!(%{
        subscription_id: fixture.subscription.id,
        source_version: fixture.subscription.aggregate_version,
        disposition: :effective,
        entitlement_kind: fixture.revision.entitlement_kind,
        entitlement_scope_key: fixture.revision.entitlement_scope_key,
        valid_from_at: fixture.subscription.current_period_start_at,
        valid_until_at: fixture.subscription.current_period_end_at,
        source_order_line_item_id: fixture.line_item.id,
        contract_change_id: fixture.subscription.current_contract_change_id,
        plan_revision_id: fixture.revision.id
      })

    {:ok, effect} = Facade.establish_access_effect_for_system(effect_input)

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      variant_plan: variant_plan,
      plan: plan,
      effect: effect
    })
  end

  defp create_committed_b_due_fixture!(label) do
    assert_test_database!()
    now = db_now!()
    unique = Ecto.UUID.generate()
    customer = SubscriptionsFixtures.create_customer!("jc247_b_race_#{label}_#{unique}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7,
        access_on_past_due: :keep_during_grace,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc247-b-race-current-#{label}-#{unique}"
      })

    remove_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7,
        access_on_past_due: :remove_immediately,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc247-b-race-remove-#{label}-#{unique}"
      })

    current_variant_plan =
      SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)

    remove_variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, remove_plan.id)
    SubscriptionsFixtures.create_plan_revision!(remove_plan)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_billing_ref: "pm_jc247_b_#{label}_#{unique}",
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :microsecond)
      })

    Repo.query!(
      "UPDATE subscriptions SET next_renewal_at = current_period_end_at WHERE id = $1",
      [
        uuid_param!(fixture.subscription.id)
      ]
    )

    assert {:ok, plan_change_input} =
             QueueSubscriptionPlanChangeInput.new(%{
               "subscription_id" => fixture.subscription.id,
               "subscription_plan_id" => remove_plan.id
             })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(
               customer,
               fixture.subscription.id,
               plan_change_input
             )

    subscription = fetch_subscription!(queued.id)

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      variant_plan: current_variant_plan,
      remove_variant_plan: remove_variant_plan,
      plan: current_plan,
      remove_plan: remove_plan,
      subscription: subscription,
      run: fn ->
        Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: now)
      end
    })
  end

  defp cleanup_committed_b_fixture!(fixture) do
    subscription_id = uuid_param!(fixture.subscription.id)
    user_id = uuid_param!(fixture.customer.id)

    case Repo.transaction(
           fn ->
             Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])

             Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!(
               "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
               [user_id]
             )

             Repo.query!(
               "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL, current_contract_change_id = NULL WHERE id = $1",
               [subscription_id]
             )

             Repo.query!(
               "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
             )

             Repo.query!(
               """
               DELETE FROM renewal_collection_attempts
               WHERE renewal_attempt_id IN (
                 SELECT id FROM renewal_attempts WHERE subscription_id = $1
               )
               """,
               [subscription_id]
             )

             Repo.query!(
               "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
             )

             Repo.query!(
               "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
               [user_id]
             )

             Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

             Repo.query!(
               "DELETE FROM email_outboxes WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM fulfillment_orders WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])

             Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [
               user_id
             ])

             Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [
               uuid_param!(fixture.variant.id)
             ])

             Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
               uuid_param!(fixture.plan.id)
             ])

             Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
               uuid_param!(fixture.remove_plan.id)
             ])

             Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [
               uuid_param!(fixture.plan.id)
             ])

             Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [
               uuid_param!(fixture.remove_plan.id)
             ])

             Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
             Repo.query!("DELETE FROM products WHERE id = $1", [uuid_param!(fixture.product.id)])
             Repo.query!("DELETE FROM users WHERE id = $1", [uuid_param!(fixture.customer.id)])
           end,
           timeout: @transaction_timeout
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise "unable to clean JC247-B real-connection fixture: #{inspect(reason)}"
    end
  end

  defp issue_legacy_grant!(fixture) do
    subscription = %{
      id: fixture.subscription.id,
      user_id: fixture.subscription.user_id,
      current_period_end_at: fixture.subscription.current_period_end_at
    }

    plan = %{
      entitlement_kind: fixture.revision.entitlement_kind,
      entitlement_scope_key: fixture.revision.entitlement_scope_key
    }

    case EntitlementsFacade.issue_subscription_source_grant_strict_for_system(subscription, plan) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp establish_jc247_b_initial_effective_access!(fixture) do
    attrs = %{
      subscription_id: fixture.subscription.id,
      source_version: fixture.subscription.aggregate_version,
      disposition: :effective,
      entitlement_kind: fixture.revision.entitlement_kind,
      entitlement_scope_key: fixture.revision.entitlement_scope_key,
      valid_from_at: fixture.subscription.current_period_start_at,
      valid_until_at: fixture.subscription.current_period_end_at,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: fixture.subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)
    assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(effect.id)
    effect
  end

  defp stub_b_payment_phase!(phase) do
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      status = if :atomics.get(phase, 1) == 1, do: "canceled", else: "processing"

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => status})
      )
    end)
  end

  defp start_jc247_b_failure_task(context, fixture) do
    Task.async(fn ->
      Sandbox.allow(Store.DirectRepo, context.direct_repo_owner, self())
      Repo.checkout(fn -> fixture.run.() end)
    end)
  end

  defp start_jc247_b_recovery_task(context, fixture, barrier) do
    parent = self()

    Task.async(fn ->
      Sandbox.allow(Store.DirectRepo, context.direct_repo_owner, self())

      Repo.checkout(fn ->
        recovery_pid = backend_pid!()
        send(parent, {barrier, :recovery_started, recovery_pid})
        recover_jc247_b_paid_episode!(fixture)
      end)
    end)
  end

  defp start_jc247_b_executor_task(effect_id, barrier) do
    parent = self()

    Task.async(fn ->
      Repo.checkout(fn ->
        executor_pid = backend_pid!()
        send(parent, {barrier, :executor_started, executor_pid})
        Facade.execute_suspension_access_effect_for_system(effect_id)
      end)
    end)
  end

  defp start_jc247_b_recovery_order_barrier!(attempt_id, grant_id, barrier) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            barrier_pid = backend_pid!()

            Repo.query!("SELECT id FROM renewal_attempts WHERE id = $1 FOR UPDATE", [
              uuid_param!(attempt_id)
            ])

            Repo.query!("SAVEPOINT jc247_b_grant_row_lock")

            Repo.query!("SELECT id FROM entitlement_grants WHERE id = $1 FOR UPDATE", [
              uuid_param!(grant_id)
            ])

            send(parent, {barrier, :recovery_order_locks_acquired, barrier_pid})

            receive do
              {^barrier, :release_b_grant_lock} ->
                Repo.query!("ROLLBACK TO SAVEPOINT jc247_b_grant_row_lock")
                send(parent, {barrier, :b_grant_lock_released, barrier_pid})

                receive do
                  {^barrier, :release_recovery_lock} -> :released
                after
                  @transaction_timeout -> Repo.rollback(:recovery_lock_release_timeout)
                end
            after
              @transaction_timeout -> Repo.rollback(:b_grant_lock_release_timeout)
            end
          end,
          timeout: @transaction_timeout
        )
      end)

    barrier_pid = receive_jc247_b_event!(barrier, :recovery_order_locks_acquired)
    {task, barrier_pid}
  end

  defp attach_jc247_b_dunning_barrier!(owner, barrier, subscription_id) do
    handler_id = "jc247_b_dunning_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, %{subscription_id: event_subscription_id}, config ->
          if event_subscription_id == config.subscription_id do
            send(config.owner, {:jc247_b_dunning_paused, config.barrier, event_subscription_id})

            receive do
              {ref, :release_dunning} when ref == config.barrier -> :ok
            after
              @jc247_b_barrier_timeout -> raise "JC247-B dunning barrier timed out"
            end
          end
        end,
        %{owner: owner, barrier: barrier, subscription_id: subscription_id}
      )

    handler_id
  end

  defp recover_jc247_b_paid_episode!(fixture) do
    subscription = fetch_subscription!(fixture.subscription.id)
    attempt = fetch_attempt!(subscription.id)

    order =
      Ash.get!(Order, attempt.order_id,
        domain: Store.Orders,
        authorize?: false,
        context: %{system?: true}
      )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id,
               now: subscription.next_retry_at
             )

    collection = latest_collection_for_attempt!(attempt.id)
    refute collection.financial_outcome == :verified_failure
    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    assert handoff.renewal_attempt_id == attempt.id

    Facade.reconcile_paid_subscription_renewal_for_system(order.id,
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    )
  end

  defp latest_collection_for_attempt!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.last()
    |> case do
      nil -> raise "no renewal collection for attempt #{attempt_id}"
      collection -> collection
    end
  end

  defp mark_collection_successful!(collection) do
    payment_intent =
      Ash.get!(PaymentIntent, collection.payment_intent_id,
        domain: Store.Payments,
        authorize?: false,
        context: %{system?: true}
      )

    provider_reference =
      payment_intent.provider_payment_id || payment_intent.provider_request_reference

    provider_reference_kind =
      if payment_intent.provider_payment_id, do: :payment_intent, else: :transaction_reference

    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: provider_reference,
      provider_reference_kind: provider_reference_kind,
      provider_transaction_id: payment_intent.provider_payment_id || "pi_#{payment_intent.id}",
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert outcome in [:authoritative_success, :already_applied_success]

    updated =
      RenewalCollectionAttempt
      |> Ash.get!(collection.id,
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    assert updated.financial_outcome == :verified_success

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated.payment_attempt_id,
                 payment_intent_id: collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effects_for_subscription!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_access_effect!(id) do
    Ash.get!(AccessEffect, id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp latest_access_effect!(subscription_id) do
    subscription_id
    |> access_effects_for_subscription!()
    |> Enum.max_by(& &1.source_version)
  end

  defp active_grants_for_source!(subscription_id) do
    Enum.filter(grants_for_source!(subscription_id), &(&1.status == :active))
  end

  defp receive_jc247_b_event!(barrier, event) do
    receive do
      {^barrier, ^event, backend_pid} -> backend_pid
    after
      @task_timeout -> flunk("timed out waiting for JC247-B #{event}")
    end
  end

  defp await_jc247_b_lock_blocker!(blocked_pid, expected_blocker_pid, direct_repo_owner) do
    case Sandbox.allow(Store.DirectRepo, direct_repo_owner, self()) do
      :ok -> :ok
      {:already, :allowed} -> :ok
      other -> raise "could not allow direct Repo access for lock observation: #{inspect(other)}"
    end

    deadline = System.monotonic_time(:millisecond) + @blocking_timeout
    await_jc247_b_lock_blocker!(blocked_pid, expected_blocker_pid, deadline, [])
  end

  defp await_jc247_b_lock_blocker!(blocked_pid, expected_blocker_pid, deadline, last_blockers) do
    %{rows: [[blockers]]} =
      Store.DirectRepo.query!("SELECT pg_blocking_pids($1)", [blocked_pid])

    cond do
      expected_blocker_pid in blockers ->
        blockers

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "expected PostgreSQL backend #{expected_blocker_pid} to block #{blocked_pid}; " <>
            "last blockers were #{inspect(last_blockers)}"
        )

      true ->
        :erlang.yield()
        await_jc247_b_lock_blocker!(blocked_pid, expected_blocker_pid, deadline, blockers)
    end
  end

  defp db_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp input!(attrs) do
    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, error} -> raise "invalid contention AccessEffect input: #{inspect(error)}"
    end
  end

  defp cleanup_owned_sources!(fixtures) do
    assert_test_database!()

    case Repo.transaction(
           fn ->
             cleanup_owned_source!(fixtures.y)
             cleanup_owned_source!(fixtures.x)
           end,
           timeout: @transaction_timeout
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "unable to clean owned contention fixtures: #{inspect(reason)}"
    end
  end

  defp cleanup_owned_source!(fixture) do
    subscription_id = uuid_param!(fixture.subscription.id)
    item_id = uuid_param!(fixture.item.id)
    line_item_id = uuid_param!(fixture.line_item.id)
    order_id = uuid_param!(fixture.order.id)
    variant_plan_id = uuid_param!(fixture.variant_plan.id)
    revision_id = uuid_param!(fixture.revision.id)
    plan_id = uuid_param!(fixture.plan.id)
    product_id = uuid_param!(fixture.product.id)
    user_id = uuid_param!(fixture.customer.id)

    Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])
    Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])
    Repo.query!("DELETE FROM subscription_items WHERE id = $1", [item_id])
    Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
    Repo.query!("DELETE FROM email_outboxes WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
    Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])
    Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [variant_plan_id])
    Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [revision_id])
    Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
    Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
    Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

    :ok
  end

  defp uuid_param!(uuid), do: Ecto.UUID.dump!(uuid)

  defp assert_test_database! do
    expected_database =
      System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test") <>
        (System.get_env("STORE_TEST_DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") || "")

    actual_database = Repo.config()[:database]

    unless Mix.env() == :test and actual_database == expected_database do
      raise "contention test database guard failed: MIX_ENV=#{inspect(Mix.env())}, " <>
              "configured_database=#{inspect(actual_database)}, expected_database=#{inspect(expected_database)}"
    end

    :ok
  end
end
