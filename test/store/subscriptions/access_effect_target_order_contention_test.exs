defmodule Store.Subscriptions.AccessEffectTargetOrderContentionTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 60_000

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.Cache
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Types.EntitlementSet
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, PlanRevision, Subscription, SubscriptionItem}
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures

  import Ash.Expr
  require Ash.Query

  @transaction_timeout 30_000
  @task_timeout 15_000
  @blocking_timeout 8_000
  @cursor_floor "00000000-0000-7000-8000-000000000000"

  setup_all do
    assert_test_database!()

    pool_size = Repo.config()[:pool_size]

    unless is_integer(pool_size) and pool_size >= 3 do
      raise "target-order contention proof requires Repo pool_size >= 3, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)

    {:ok, effective_repo_pool_size: pool_size}
  end

  setup do
    direct_repo_owner = Sandbox.start_owner!(Store.DirectRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(direct_repo_owner) end)
    {:ok, direct_repo_owner: direct_repo_owner}
  end

  test "cancellation producer and F0.5 serialize in both lock-arrival orders", context do
    producer_first = create_committed_source!("producer_first")

    try do
      run_race!(producer_first, :producer_first, context.direct_repo_owner)
      assert_final_effective_target!(producer_first)
    after
      cleanup_owned_source!(producer_first)
    end

    reconciler_first = create_committed_source!("reconciler_first")

    try do
      run_race!(reconciler_first, :reconciler_first, context.direct_repo_owner)
      assert_pre_cancellation_effect_derived_from_source!(reconciler_first)
      assert_final_effective_target!(reconciler_first)

      IO.puts(
        "F0_5_CONTENTION pool_size=#{context.effective_repo_pool_size} both_orders=serialized"
      )
    after
      cleanup_owned_source!(reconciler_first)
    end
  end

  @tag :jc360_task09
  test "cancel now commits a newer target before delayed initial F1 returns terminal noop",
       context do
    # This controls the committed-fixture F1 boundary, not the public paid-order facade dispatch.
    fixture = create_committed_initial_activation_source!("jc360_task09_cancel_first")

    try do
      assert_committed_initial_activation_source!(fixture)

      :ok = Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.customer.id))
      cache_key = Cache.cache_key(fixture.customer.id)
      assert {:ok, true} = Cachex.put(Cache, cache_key, :jc360_task09_before_cancel)

      run_ref = make_ref()
      task_a = start_initial_effect_task(run_ref, fixture.effect.id, context.direct_repo_owner)

      try do
        assert_receive {^run_ref, :initial_f1_waiting, initial_backend_pid, false}, @task_timeout

        assert effect_identity_snapshot!(fixture.subscription.id) == [
                 {fixture.effect.id, fixture.effect.source_version, :required}
               ]

        task_b = start_cancel_now_task(run_ref, fixture, context.direct_repo_owner)

        try do
          assert_receive {^run_ref, :cancel_now_started, cancellation_backend_pid, false},
                         @task_timeout

          assert initial_backend_pid != cancellation_backend_pid
          send(task_b.pid, {run_ref, :run_cancel_now})

          assert_receive {^run_ref, :cancel_now_completed, cancel_result, false}, @task_timeout
          assert_task_exit!(task_b, @task_timeout)

          assert {:ok, %Subscription{status: :canceled} = canceled_result} = cancel_result
          canceled = fetch_subscription!(fixture.subscription.id)
          assert cancellation_summary(canceled_result) == cancellation_summary(canceled)
          assert canceled.status == :canceled
          assert canceled.canceled_reason == "user_request"
          assert canceled.aggregate_version > fixture.subscription.aggregate_version
          assert current_effect_count!(canceled.id, canceled.aggregate_version) == 1

          cancellation_effect =
            fetch_effect_for_source_version!(canceled.id, canceled.aggregate_version)

          assert cancellation_effect.id != fixture.effect.id
          assert cancellation_effect.status == :applied
          assert cancellation_effect.disposition == :non_effective
          assert cancellation_effect.source_version == canceled.aggregate_version
          assert cancellation_effect.source_order_line_item_id == fixture.line_item.id
          assert cancellation_effect.contract_change_id == canceled.current_contract_change_id
          assert cancellation_effect.plan_revision_id == fixture.revision.id
          assert cancellation_effect.entitlement_kind == nil
          assert cancellation_effect.entitlement_scope_key == nil
          assert cancellation_effect.valid_from_at == nil
          assert cancellation_effect.valid_until_at == nil
          assert cancellation_effect.projection_user_ids == [fixture.customer.id]
          assert %DateTime{} = cancellation_effect.projection_delivered_at

          superseded_before_f1 = fetch_access_effect!(fixture.effect.id)
          assert superseded_before_f1.status == :superseded
          effects_before_f1 = effect_identity_snapshot!(fixture.subscription.id)

          assert effects_before_f1 == [
                   {fixture.effect.id, fixture.effect.source_version, :superseded},
                   {cancellation_effect.id, canceled.aggregate_version, :applied}
                 ]

          assert_receive {:entitlements_invalidated, invalidated_user_id,
                          "non_effective_access_effect_applied", _at},
                         @task_timeout

          assert invalidated_user_id == fixture.customer.id
          assert {:ok, nil} = Cachex.get(Cache, cache_key)

          grants_before_f1 = grants_for_source!(fixture.subscription.id)
          assert grants_before_f1 == []

          assert {:ok, %EntitlementSet{} = projection_before_f1} =
                   EntitlementsFacade.entitlement_set_for_user(fixture.customer)

          assert projection_before_f1.user_id == fixture.customer.id
          assert projection_before_f1.grants == []

          send(task_a.pid, {run_ref, :execute_initial_f1})

          assert_receive {^run_ref, :initial_f1_completed, {:ok, :noop}, false}, @task_timeout
          assert_task_exit!(task_a, @task_timeout)

          superseded_after_f1 = fetch_access_effect!(fixture.effect.id)
          assert superseded_after_f1.status == :superseded
          assert fetch_access_effect!(cancellation_effect.id).status == :applied
          assert effect_identity_snapshot!(fixture.subscription.id) == effects_before_f1

          grants_after_f1 = grants_for_source!(fixture.subscription.id)
          assert Enum.map(grants_after_f1, & &1.id) == Enum.map(grants_before_f1, & &1.id)
          assert grants_after_f1 == grants_before_f1

          assert {:ok, ^projection_before_f1} =
                   EntitlementsFacade.entitlement_set_for_user(fixture.customer)

          assert {:ok, ^projection_before_f1} = Cachex.get(Cache, cache_key)

          IO.puts(
            "JC360_TASK09 cancellation_first initial_backend_pid=#{initial_backend_pid} " <>
              "cancellation_backend_pid=#{cancellation_backend_pid} " <>
              "initial_status_before_f1=#{superseded_before_f1.status} " <>
              "initial_f1_result=noop grants_unchanged=true"
          )
        after
          send(task_b.pid, {run_ref, :run_cancel_now})
          await_task_exit!(task_b, @task_timeout)
        end
      after
        send(task_a.pid, {run_ref, :execute_initial_f1})
        await_task_exit!(task_a, @task_timeout)
      end
    after
      cleanup_owned_source!(fixture)
      Cachex.del(Cache, Cache.cache_key(fixture.customer.id))
    end
  end

  @tag :jc360_task10
  test "initial F1 locks the source before cancel now and cancellation wins", context do
    fixture = create_committed_initial_activation_source!("jc360_task10_activation_first")

    try do
      assert_committed_initial_activation_source!(fixture)

      :ok = Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.customer.id))
      cache_key = Cache.cache_key(fixture.customer.id)
      assert {:ok, true} = Cachex.put(Cache, cache_key, :jc360_task10_before_activation)

      :ok = Sandbox.checkin(Repo)
      race = run_activation_locks_first_race!(fixture, context)
      assert_task10_final_state!(fixture, cache_key, race.cancel_result)

      IO.puts(
        "JC360_TASK10 activation_first pool_size=#{context.effective_repo_pool_size} " <>
          "A=#{race.backend_a} B=#{race.backend_b} C=#{race.backend_c} " <>
          "candidate=#{fixture.effect.id} " <>
          "C_blocks_A_before_B=#{inspect(race.candidate_blockers_before_cancel)} " <>
          "C_blocks_A=#{inspect(race.candidate_blockers_before_release)} " <>
          "A_blocks_B=#{inspect(race.cancellation_blockers)} " <>
          "C_reconfirmed_blocks_A=true initial=applied cancellation=applied " <>
          "final_grants=one_revoked projection=empty"
      )
    after
      cleanup_owned_source!(fixture)
      Cachex.del(Cache, Cache.cache_key(fixture.customer.id))
    end
  end

  defp run_activation_locks_first_race!(fixture, context) do
    run_ref = make_ref()

    barrier =
      start_candidate_effect_lock_barrier!(
        run_ref,
        fixture.effect.id,
        context.direct_repo_owner
      )

    try do
      assert barrier.access_effect_id == fixture.effect.id

      race =
        run_initial_f1_while_candidate_is_locked!(
          fixture,
          context.direct_repo_owner,
          run_ref,
          barrier
        )

      Map.merge(race, %{backend_c: barrier.backend_pid})
    after
      release_candidate_effect_barrier!(barrier, run_ref)
    end
  end

  defp run_initial_f1_while_candidate_is_locked!(fixture, direct_repo_owner, run_ref, barrier) do
    task_a = start_initial_effect_task(run_ref, fixture.effect.id, direct_repo_owner)

    try do
      assert_receive {^run_ref, :initial_f1_waiting, backend_a, false}, @task_timeout
      assert backend_a != barrier.backend_pid

      send(task_a.pid, {run_ref, :execute_initial_f1})

      candidate_blockers_before_cancel =
        assert_candidate_effect_blocked_by_barrier!(
          barrier,
          run_ref,
          backend_a,
          barrier.backend_pid,
          :initial_f1_waiting_on_candidate
        )

      cancellation_race =
        run_cancel_now_while_f1_waits!(
          fixture,
          direct_repo_owner,
          run_ref,
          barrier,
          task_a,
          backend_a
        )

      Map.merge(cancellation_race, %{
        backend_a: backend_a,
        candidate_blockers_before_cancel: candidate_blockers_before_cancel
      })
    after
      send(task_a.pid, {run_ref, :execute_initial_f1})
      release_candidate_effect_barrier!(barrier, run_ref)
      await_task_exit!(task_a, @task_timeout)
    end
  end

  defp run_cancel_now_while_f1_waits!(
         fixture,
         direct_repo_owner,
         run_ref,
         barrier,
         task_a,
         backend_a
       ) do
    task_b = start_cancel_now_task(run_ref, fixture, direct_repo_owner)

    try do
      assert_receive {^run_ref, :cancel_now_started, backend_b, false}, @task_timeout
      assert length(Enum.uniq([backend_a, backend_b, barrier.backend_pid])) == 3

      send(task_b.pid, {run_ref, :run_cancel_now})

      cancellation_blockers =
        assert_candidate_effect_blocked_by_barrier!(
          barrier,
          run_ref,
          backend_b,
          backend_a,
          :cancel_now_waiting_on_subscription
        )

      candidate_blockers_before_release =
        assert_candidate_effect_blocked_by_barrier!(
          barrier,
          run_ref,
          backend_a,
          barrier.backend_pid,
          :initial_f1_still_waiting_on_candidate
        )

      assert backend_a in cancellation_blockers
      assert barrier.backend_pid in candidate_blockers_before_release
      assert {:ok, :released} = release_candidate_effect_barrier!(barrier, run_ref)

      assert_receive {^run_ref, :initial_f1_completed, f1_result, false}, @task_timeout
      assert_task_exit!(task_a, @task_timeout)
      assert f1_result == {:ok, :applied}
      assert fetch_access_effect!(fixture.effect.id).status == :applied

      assert_receive {^run_ref, :cancel_now_completed, cancel_result, false}, @task_timeout
      assert_task_exit!(task_b, @task_timeout)

      %{
        backend_b: backend_b,
        cancellation_blockers: cancellation_blockers,
        candidate_blockers_before_release: candidate_blockers_before_release,
        cancel_result: cancel_result
      }
    after
      send(task_b.pid, {run_ref, :run_cancel_now})
      release_candidate_effect_barrier!(barrier, run_ref)
      send(task_a.pid, {run_ref, :execute_initial_f1})
      await_task_exit!(task_b, @task_timeout)
    end
  end

  defp assert_task10_final_state!(fixture, cache_key, cancel_response) do
    assert {:ok, %Subscription{status: :canceled} = cancel_result} = cancel_response
    canceled = fetch_subscription!(fixture.subscription.id)
    assert cancellation_summary(cancel_result) == cancellation_summary(canceled)
    assert canceled.status == :canceled
    assert canceled.canceled_reason == "user_request"
    assert canceled.aggregate_version > fixture.subscription.aggregate_version

    initial_effect = fetch_access_effect!(fixture.effect.id)
    assert initial_effect.status == :applied
    assert initial_effect.disposition == :effective
    assert initial_effect.source_order_line_item_id == fixture.line_item.id
    assert initial_effect.source_version == fixture.subscription.aggregate_version

    assert current_effect_count!(canceled.id, canceled.aggregate_version) == 1

    cancellation_effect =
      fetch_effect_for_source_version!(canceled.id, canceled.aggregate_version)

    assert cancellation_effect.id != initial_effect.id
    assert cancellation_effect.source_version > initial_effect.source_version
    assert cancellation_effect.status == :applied
    assert cancellation_effect.disposition == :non_effective
    assert cancellation_effect.source_order_line_item_id == fixture.line_item.id
    assert cancellation_effect.contract_change_id == canceled.current_contract_change_id
    assert cancellation_effect.plan_revision_id == fixture.revision.id
    assert is_nil(cancellation_effect.entitlement_kind)
    assert is_nil(cancellation_effect.entitlement_scope_key)
    assert is_nil(cancellation_effect.valid_from_at)
    assert is_nil(cancellation_effect.valid_until_at)
    assert cancellation_effect.projection_user_ids == [fixture.customer.id]
    assert %DateTime{} = cancellation_effect.projection_delivered_at

    assert effect_identity_snapshot!(fixture.subscription.id) == [
             {initial_effect.id, initial_effect.source_version, :applied},
             {cancellation_effect.id, canceled.aggregate_version, :applied}
           ]

    assert_receive {:entitlements_invalidated, user_id, "effective_access_effect_applied", _at},
                   @task_timeout

    assert_receive {:entitlements_invalidated, cancellation_user_id,
                    "non_effective_access_effect_applied", _at},
                   @task_timeout

    assert user_id == fixture.customer.id
    assert cancellation_user_id == fixture.customer.id
    assert {:ok, nil} = Cachex.get(Cache, cache_key)

    assert [%EntitlementGrant{} = grant] = grants_for_source!(fixture.subscription.id)
    assert grant.status == :revoked
    assert grant.revoked_reason == "canceled_now"
    assert %DateTime{} = grant.revoked_at
    assert grant.user_id == fixture.customer.id
    assert grant.source_kind == :subscription
    assert grant.source_id == fixture.subscription.id
    assert grant.kind == fixture.revision.entitlement_kind
    assert grant.scope_key == fixture.revision.entitlement_scope_key
    assert grant.valid_from_at == initial_effect.valid_from_at
    assert grant.valid_to_at == initial_effect.valid_until_at
    assert active_grants_for!(fixture.subscription.id) == []

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM subscriptions WHERE source_order_line_item_id = $1",
               [Ecto.UUID.dump!(fixture.line_item.id)]
             )

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM subscription_items WHERE source_order_line_item_id = $1",
               [Ecto.UUID.dump!(fixture.line_item.id)]
             )

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM access_effects WHERE subscription_id = $1",
               [Ecto.UUID.dump!(fixture.subscription.id)]
             )

    assert {:ok, %EntitlementSet{} = projection} =
             EntitlementsFacade.entitlement_set_for_user(fixture.customer)

    assert projection.user_id == fixture.customer.id
    assert projection.grants == []
    assert {:ok, ^projection} = Cachex.get(Cache, cache_key)
  end

  defp run_race!(fixture, order, direct_repo_owner) do
    parent = self()
    run_ref = make_ref()

    holder = Task.async(fn -> run_holder_task(order, fixture, parent, run_ref) end)

    assert_receive {^run_ref, :holder_ready}, @task_timeout
    :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, holder.pid)
    send(holder.pid, {run_ref, :start_holder})

    assert_receive {^run_ref, :holder_locked, holder_backend_pid, _holder_result}, @task_timeout

    contender =
      Task.async(fn ->
        send(parent, {run_ref, :contender_ready})

        receive do
          {^run_ref, :start_contender} -> :ok
        end

        Repo.transaction(
          fn -> run_contender_transaction(order, fixture, parent, run_ref) end,
          timeout: @transaction_timeout
        )
      end)

    assert_receive {^run_ref, :contender_ready}, @task_timeout
    :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, contender.pid)
    send(contender.pid, {run_ref, :start_contender})

    assert_receive {^run_ref, :contender_started, contender_backend_pid}, @task_timeout
    assert contender_backend_pid != holder_backend_pid
    blockers = await_blocking_pid!(contender_backend_pid, holder_backend_pid)

    send(holder.pid, {run_ref, :release_holder})
    assert {:ok, _holder_result} = Task.await(holder, @task_timeout)

    contender_result = Task.await(contender, @task_timeout)

    contender_summary =
      case {order, contender_result} do
        {:producer_first, {:ok, %{noop_count: noop_count, repaired_count: repaired_count}}} ->
          assert noop_count >= 1
          "noop=#{noop_count},repaired=#{repaired_count}"

        {:reconciler_first, {:ok, %Store.Subscriptions.Subscription{status: :canceled}}} ->
          "canceled=true"

        other ->
          flunk("unexpected #{order} contention result #{inspect(other)}")
      end

    IO.puts(
      "F0_5_CONTENTION order=#{order} holder_pid=#{holder_backend_pid} " <>
        "contender_pid=#{contender_backend_pid} blockers=#{inspect(blockers)} " <>
        "result=#{contender_summary}"
    )
  end

  defp run_contender_transaction(order, fixture, parent, run_ref) do
    contender_backend_pid = backend_pid!()
    send(parent, {run_ref, :contender_started, contender_backend_pid})

    case order do
      :producer_first -> reconcile!(fixture)
      :reconciler_first -> cancel_now!(fixture)
    end
  end

  defp run_holder_task(order, fixture, parent, run_ref) do
    send(parent, {run_ref, :holder_ready})

    receive do
      {^run_ref, :start_holder} ->
        Repo.transaction(
          fn -> run_holder_transaction(order, fixture, parent, run_ref) end,
          timeout: @transaction_timeout
        )
    end
  end

  defp run_holder_transaction(order, fixture, parent, run_ref) do
    result =
      case order do
        :producer_first -> cancel_now!(fixture)
        :reconciler_first -> reconcile!(fixture)
      end

    holder_backend_pid = backend_pid!()
    send(parent, {run_ref, :holder_locked, holder_backend_pid, result})

    receive do
      {^run_ref, :release_holder} -> result
    after
      @transaction_timeout -> Repo.rollback(:holder_release_timeout)
    end
  end

  defp cancel_now!(fixture) do
    case Facade.cancel_subscription_for_user(fixture.customer, fixture.subscription.id, :now) do
      {:ok, canceled} -> canceled
      other -> Repo.rollback({:cancel_failed, other})
    end
  end

  defp reconcile!(fixture) do
    case Facade.run_access_effect_target_order_reconciliation_for_system(
           limit: 1,
           as_of: fixture.through_inserted_at,
           after_inserted_at: fixture.after_inserted_at,
           after_id: @cursor_floor
         ) do
      {:ok, result} -> result
      other -> Repo.rollback({:reconciliation_failed, other})
    end
  end

  defp create_committed_source!(label) do
    Repo.transaction(
      fn ->
        unique = Ecto.UUID.generate()
        customer = SubscriptionsFixtures.create_customer!("f05_contention_#{label}_#{unique}")

        %{product: product, variant: variant} =
          SubscriptionsFixtures.create_subscription_sellable!()

        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            entitlement_kind: :membership_access,
            entitlement_scope_key: "f05-contention-#{label}-#{unique}",
            access_on_cancel: :keep_until_period_end
          })

        variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

        fixture =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            create_payment_intent?: false
          })

        assert fixture.revision.access_on_cancel == :keep_until_period_end
        assert fixture.subscription.current_plan_revision_id == fixture.revision.id

        stale_input =
          input!(%{
            subscription_id: fixture.subscription.id,
            source_version: fixture.subscription.aggregate_version,
            disposition: :non_effective,
            entitlement_kind: nil,
            entitlement_scope_key: nil,
            valid_from_at: nil,
            valid_until_at: nil,
            source_order_line_item_id: fixture.line_item.id,
            contract_change_id: fixture.subscription.current_contract_change_id,
            plan_revision_id: fixture.revision.id
          })

        {:ok, candidate} = Facade.establish_access_effect_for_system(stale_input)

        Repo.query!(
          "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
          [
            Ecto.UUID.dump!(fixture.subscription.id)
          ]
        )

        inserted_at = candidate.inserted_at

        Map.merge(fixture, %{
          customer: customer,
          product: product,
          variant: variant,
          plan: plan,
          variant_plan: variant_plan,
          candidate: candidate,
          pre_cancellation_source_version: fixture.subscription.aggregate_version + 1,
          through_inserted_at: inserted_at,
          after_inserted_at: inserted_at
        })
      end,
      timeout: @transaction_timeout
    )
    |> case do
      {:ok, fixture} ->
        fixture

      {:error, reason} ->
        raise "unable to create target-order contention source: #{inspect(reason)}"
    end
  end

  defp create_committed_initial_activation_source!(label) do
    Repo.transaction(
      fn ->
        unique = Ecto.UUID.generate()
        customer = SubscriptionsFixtures.create_customer!("#{label}_#{unique}")

        %{product: product, variant: variant} =
          SubscriptionsFixtures.create_subscription_sellable!()

        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            access_on_cancel: :remove_immediately,
            entitlement_kind: :digital_library,
            entitlement_scope_key: "#{label}:#{unique}"
          })

        variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

        fixture =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            create_payment_intent?: true
          })

        effect =
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
          |> establish_initial_access_effect!()

        Map.merge(fixture, %{
          customer: customer,
          product: product,
          variant: variant,
          plan: plan,
          variant_plan: variant_plan,
          effect: effect
        })
      end,
      timeout: @transaction_timeout
    )
    |> case do
      {:ok, fixture} ->
        fixture

      {:error, reason} ->
        raise "unable to create committed initial activation fixture: #{inspect(reason)}"
    end
  end

  defp establish_initial_access_effect!(input) do
    case Facade.establish_access_effect_for_system(input) do
      {:ok, access_effect} -> access_effect
      other -> Repo.rollback({:initial_effect_establishment_failed, other})
    end
  end

  defp assert_committed_initial_activation_source!(fixture) do
    order = fetch_order!(fixture.order.id)
    line_item = fetch_order_line_item!(fixture.line_item.id)
    payment_intent = fetch_succeeded_payment_intent!(order.id)
    subscription = fetch_subscription!(fixture.subscription.id)
    item = fetch_subscription_item!(fixture.item.id)
    revision = fetch_plan_revision!(fixture.revision.id)
    effect = fetch_access_effect!(fixture.effect.id)

    assert order.state == :paid
    assert order.user_id == fixture.customer.id
    assert payment_intent.order_id == order.id
    assert line_item.order_id == order.id
    assert line_item.subscription_plan_id_snapshot == fixture.plan.id
    assert line_item.subscription_plan_revision_id_snapshot == revision.id

    assert revision.subscription_plan_id == fixture.plan.id
    assert revision.status in [:effective, :retired]
    assert revision.access_on_cancel == :remove_immediately
    assert revision.entitlement_kind == :digital_library
    assert is_binary(revision.entitlement_scope_key)

    assert subscription.status == :active
    assert subscription.source_order_id == order.id
    assert subscription.source_order_line_item_id == line_item.id
    assert subscription.subscription_plan_id == revision.subscription_plan_id
    assert subscription.current_plan_revision_id == revision.id
    assert subscription.aggregate_version == fixture.subscription.aggregate_version
    assert %DateTime{} = subscription.current_period_start_at
    assert %DateTime{} = subscription.current_period_end_at

    assert DateTime.compare(
             subscription.current_period_start_at,
             subscription.current_period_end_at
           ) == :lt

    assert item.subscription_id == subscription.id
    assert item.source_order_line_item_id == line_item.id

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM subscriptions WHERE source_order_line_item_id = $1",
               [Ecto.UUID.dump!(line_item.id)]
             )

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM subscription_items WHERE source_order_line_item_id = $1",
               [Ecto.UUID.dump!(line_item.id)]
             )

    assert effect.status == :required
    assert effect.disposition == :effective
    assert effect.subscription_id == subscription.id
    assert effect.source_version == subscription.aggregate_version
    assert effect.source_order_line_item_id == line_item.id
    assert effect.contract_change_id == subscription.current_contract_change_id
    assert effect.plan_revision_id == revision.id
    assert effect.entitlement_kind == revision.entitlement_kind
    assert effect.entitlement_scope_key == revision.entitlement_scope_key
    assert effect.valid_from_at == subscription.current_period_start_at
    assert effect.valid_until_at == subscription.current_period_end_at
    assert AccessEffect.persisted_fingerprint_status(effect) == :v2_match
    assert current_effect_count!(subscription.id, subscription.aggregate_version) == 1
    assert grants_for_source!(subscription.id) == []
  end

  defp start_initial_effect_task(run_ref, effect_id, direct_repo_owner) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, self())

        Repo.checkout(fn ->
          backend_pid = backend_pid!()
          send(parent, {run_ref, :initial_f1_waiting, backend_pid, Repo.in_transaction?()})

          f1_result =
            receive do
              {^run_ref, :execute_initial_f1} ->
                Facade.execute_effective_access_effect_for_system(effect_id)
            after
              @task_timeout -> {:error, :initial_f1_release_timeout}
            end

          send(parent, {run_ref, :initial_f1_completed, f1_result, Repo.in_transaction?()})
          f1_result
        end)
      end)

    %{pid: pid, monitor_ref: monitor_ref}
  end

  defp start_cancel_now_task(run_ref, fixture, direct_repo_owner) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, self())

        Repo.checkout(fn ->
          backend_pid = backend_pid!()
          send(parent, {run_ref, :cancel_now_started, backend_pid, Repo.in_transaction?()})

          :ok =
            receive do
              {^run_ref, :run_cancel_now} -> :ok
            after
              @task_timeout -> {:error, :cancel_now_start_timeout}
            end

          cancel_result =
            Facade.cancel_subscription_for_user(
              fixture.customer,
              fixture.subscription.id,
              :now
            )

          send(parent, {run_ref, :cancel_now_completed, cancel_result, Repo.in_transaction?()})
          cancel_result
        end)
      end)

    %{pid: pid, monitor_ref: monitor_ref}
  end

  defp start_candidate_effect_lock_barrier!(run_ref, access_effect_id, direct_repo_owner) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, self())

        transaction_result =
          Repo.transaction(
            fn ->
              backend_pid = backend_pid!()

              %{rows: [[locked_effect_id]]} =
                Repo.query!(
                  "SELECT id FROM access_effects WHERE id = $1 FOR UPDATE",
                  [Ecto.UUID.dump!(access_effect_id)],
                  timeout: @task_timeout
                )

              locked_effect_id = Ecto.UUID.cast!(locked_effect_id)

              send(
                parent,
                {run_ref, :candidate_effect_barrier_locked, backend_pid, locked_effect_id}
              )

              await_candidate_effect_barrier!(run_ref)
            end,
            timeout: @transaction_timeout
          )

        send(parent, {run_ref, :candidate_effect_barrier_completed, transaction_result})
      end)

    receive do
      {^run_ref, :candidate_effect_barrier_locked, backend_pid, ^access_effect_id} ->
        %{
          pid: pid,
          monitor_ref: monitor_ref,
          backend_pid: backend_pid,
          access_effect_id: access_effect_id
        }
    after
      @task_timeout -> flunk("timed out acquiring the exact candidate AccessEffect row lock")
    end
  end

  defp await_candidate_effect_barrier!(run_ref) do
    receive do
      {^run_ref, :observe_blockers, blocked_pid, expected_blocker_pid, observer, label} ->
        blockers = await_blocking_pid!(blocked_pid, expected_blocker_pid)

        send(observer, {run_ref, {:candidate_effect_blockers, label}, blockers})
        await_candidate_effect_barrier!(run_ref)

      {^run_ref, :release_candidate_effect} ->
        :released
    after
      @transaction_timeout -> Repo.rollback(:candidate_effect_lock_release_timeout)
    end
  end

  defp assert_candidate_effect_blocked_by_barrier!(
         barrier,
         run_ref,
         blocked_pid,
         expected_blocker_pid,
         label
       ) do
    send(
      barrier.pid,
      {run_ref, :observe_blockers, blocked_pid, expected_blocker_pid, self(), label}
    )

    receive do
      {^run_ref, {:candidate_effect_blockers, ^label}, blockers} ->
        assert expected_blocker_pid in blockers
        blockers
    after
      @task_timeout -> flunk("timed out observing PostgreSQL blocker evidence for #{label}")
    end
  end

  defp release_candidate_effect_barrier!(barrier, run_ref) do
    if Process.alive?(barrier.pid) do
      send(barrier.pid, {run_ref, :release_candidate_effect})

      receive do
        {^run_ref, :candidate_effect_barrier_completed, transaction_result} ->
          await_task_exit!(barrier, @task_timeout)
          transaction_result
      after
        @task_timeout ->
          Process.exit(barrier.pid, :kill)
          flunk("candidate AccessEffect barrier did not finish after release")
      end
    else
      Process.demonitor(barrier.monitor_ref, [:flush])
      :already_released
    end
  end

  defp input!(attrs) do
    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise "invalid target-order contention effect: #{inspect(reason)}"
    end
  end

  defp assert_final_effective_target!(fixture) do
    subscription = fetch_subscription!(fixture.subscription.id)
    assert {:ok, effect} = Facade.get_current_access_effect_for_system(subscription)

    assert subscription.status == :canceled
    assert subscription.canceled_reason == "user_request"
    assert %DateTime{} = subscription.canceled_at
    assert effect.status in [:required, :pending, :failed_retryable, :applied]
    assert effect.disposition == :effective
    assert effect.source_version == subscription.aggregate_version
    assert effect.entitlement_kind == fixture.revision.entitlement_kind
    assert effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert effect.valid_from_at == subscription.current_period_start_at
    assert effect.valid_until_at == subscription.current_period_end_at
    assert effect.source_order_line_item_id == subscription.source_order_line_item_id
    assert effect.contract_change_id == subscription.current_contract_change_id
    assert effect.plan_revision_id == subscription.current_plan_revision_id
    assert effect.plan_revision_id == fixture.revision.id
    assert current_effect_count!(subscription.id, subscription.aggregate_version) == 1

    assert {:ok, outcome} = Facade.execute_effective_access_effect_for_system(effect.id)
    assert outcome in [:applied, :applied_projection_pending, :noop]

    assert {:ok, current_effect} = Facade.get_current_access_effect_for_system(subscription)
    assert current_effect.id == effect.id
    assert current_effect.disposition == :effective
    assert current_effect.source_version == subscription.aggregate_version

    assert [grant] = active_grants_for!(subscription.id)
    assert grant.source_kind == :subscription
    assert grant.source_id == subscription.id
    assert grant.kind == current_effect.entitlement_kind
    assert grant.scope_key == current_effect.entitlement_scope_key
    assert grant.valid_from_at == current_effect.valid_from_at
    assert grant.valid_to_at == current_effect.valid_until_at
  end

  defp assert_pre_cancellation_effect_derived_from_source!(fixture) do
    effect =
      fetch_effect_for_source_version!(
        fixture.subscription.id,
        fixture.pre_cancellation_source_version
      )

    assert effect.disposition == :effective
    assert effect.source_version == fixture.pre_cancellation_source_version
    assert effect.entitlement_kind == fixture.revision.entitlement_kind
    assert effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert effect.valid_from_at == fixture.subscription.current_period_start_at
    assert effect.valid_until_at == fixture.subscription.current_period_end_at
    assert effect.source_order_line_item_id == fixture.subscription.source_order_line_item_id
    assert effect.contract_change_id == fixture.subscription.current_contract_change_id
    assert effect.plan_revision_id == fixture.revision.id
    assert current_effect_count!(fixture.subscription.id, effect.source_version) == 1

    assert fixture.candidate.disposition == :non_effective
    assert fetch_access_effect!(fixture.candidate.id).status == :superseded
  end

  defp current_effect_count!(subscription_id, source_version) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM access_effects WHERE subscription_id = $1 AND source_version = $2
        """,
        [Ecto.UUID.dump!(subscription_id), source_version]
      )

    count
  end

  defp fetch_access_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(order_id) do
    Ash.get!(Order, order_id, domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_order_line_item!(line_item_id) do
    Ash.get!(OrderLineItem, line_item_id,
      domain: Store.Orders,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_succeeded_payment_intent!(order_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(order_id == ^order_id and state == :succeeded))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_plan_revision!(revision_id) do
    Ash.get!(PlanRevision, revision_id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_subscription_item!(item_id) do
    Ash.get!(SubscriptionItem, item_id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp cancellation_summary(subscription) do
    Map.take(subscription, [
      :id,
      :status,
      :aggregate_version,
      :canceled_at,
      :ended_at,
      :canceled_reason,
      :current_plan_revision_id,
      :current_period_start_at,
      :current_period_end_at
    ])
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp effect_identity_snapshot!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> Enum.map(&{&1.id, &1.source_version, &1.status})
  end

  defp assert_task_exit!(%{pid: pid, monitor_ref: monitor_ref}, timeout) do
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, timeout
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp await_task_exit!(%{pid: pid, monitor_ref: monitor_ref}, timeout) do
    if Process.alive?(pid) do
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, :normal} -> :ok
        {:DOWN, ^monitor_ref, :process, ^pid, reason} -> flunk("task exited: #{inspect(reason)}")
      after
        timeout ->
          Process.exit(pid, :kill)
          flunk("contention task did not stop after release")
      end
    end

    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp fetch_effect_for_source_version!(subscription_id, source_version) do
    AccessEffect
    |> Ash.Query.filter(
      expr(subscription_id == ^subscription_id and source_version == ^source_version)
    )
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp active_grants_for!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(
      expr(source_kind == :subscription and source_id == ^subscription_id and status == :active)
    )
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Store.Subscriptions.Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
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
          "PostgreSQL did not report backend #{expected_blocker_pid} blocking #{blocked_pid}; " <>
            "last pg_blocking_pids result was #{inspect(last_blockers)}"
        )

      true ->
        :erlang.yield()
        poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, blockers)
    end
  end

  defp cleanup_owned_source!(fixture) do
    assert {:ok, _cleanup_result} =
             Repo.transaction(
               fn ->
                 subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
                 item_id = Ecto.UUID.dump!(fixture.item.id)
                 line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
                 order_id = Ecto.UUID.dump!(fixture.order.id)
                 variant_plan_id = Ecto.UUID.dump!(fixture.variant_plan.id)
                 revision_id = Ecto.UUID.dump!(fixture.revision.id)
                 plan_id = Ecto.UUID.dump!(fixture.plan.id)
                 product_id = Ecto.UUID.dump!(fixture.product.id)
                 customer_id = Ecto.UUID.dump!(fixture.customer.id)

                 Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!(
                   "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
                   [subscription_id]
                 )

                 Repo.query!("DELETE FROM email_outboxes WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!("DELETE FROM subscription_items WHERE id = $1", [item_id])
                 Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
                 Repo.query!("DELETE FROM email_outboxes WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
                 Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

                 Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [
                   variant_plan_id
                 ])

                 Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [revision_id])
                 Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
                 Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
                 Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
                 Repo.query!("DELETE FROM users WHERE id = $1", [customer_id])
               end,
               timeout: @transaction_timeout
             )

    assert_owned_fixture_rows_absent!(fixture)
    :ok
  end

  defp assert_owned_fixture_rows_absent!(fixture) do
    owned_rows = [
      {"access_effects", "subscription_id", fixture.subscription.id},
      {"entitlement_grants", "source_id", fixture.subscription.id},
      {"subscription_items", "id", fixture.item.id},
      {"subscriptions", "id", fixture.subscription.id},
      {"email_outboxes", "subscription_id", fixture.subscription.id},
      {"email_outboxes", "order_id", fixture.order.id},
      {"payment_intents", "order_id", fixture.order.id},
      {"fulfillment_orders", "order_id", fixture.order.id},
      {"order_adjustments", "order_id", fixture.order.id},
      {"order_line_items", "id", fixture.line_item.id},
      {"orders", "id", fixture.order.id},
      {"variant_subscription_plans", "id", fixture.variant_plan.id},
      {"plan_revisions", "id", fixture.revision.id},
      {"subscription_plans", "id", fixture.plan.id},
      {"variants", "id", fixture.variant.id},
      {"products", "id", fixture.product.id},
      {"users", "id", fixture.customer.id}
    ]

    Enum.each(owned_rows, fn {table, column, id} ->
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} = $1", [
                 Ecto.UUID.dump!(id)
               ])
    end)
  end

  defp assert_test_database! do
    expected_database =
      System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test") <>
        (System.get_env("STORE_TEST_DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") || "")

    actual_database = Repo.config()[:database]

    unless Mix.env() == :test and actual_database == expected_database do
      raise "contention test database guard failed: MIX_ENV=#{inspect(Mix.env())}, " <>
              "configured_database=#{inspect(actual_database)}, expected_database=#{inspect(expected_database)}"
    end
  end
end
