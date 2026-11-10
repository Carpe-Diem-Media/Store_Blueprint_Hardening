defmodule Store.Subscriptions.JC375QueuedReplayAuthorizationTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionVariantChangeInput
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Scheduler
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  @system_context %{system?: true}

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("JC-258 direct authorization audit must not call Stripe")
    :ok
  end

  test "support cannot replay an identical queued target" do
    for state <- [:active, :past_due], kind <- [:plan, :variant] do
      prefix = "jc258_support_replay_#{state}_#{kind}"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      fixture =
        subscription_fixture!(prefix, nil, %{
          started_at: if(state == :past_due, do: DateTime.add(now, -62, :day), else: now)
        })

      target = replay_target!(fixture, kind)
      input = replay_input!(fixture, kind, target)
      admin = actor_with_role!(:admin, "#{prefix}_admin")

      assert {:ok, seeded} =
               queue_replay_target(kind, admin, fixture.subscription.id, input)

      seeded_change_id = seeded.current_contract_change_id
      assert is_binary(seeded_change_id)
      seeded_change = fetch_contract_change!(seeded_change_id)
      assert subscription_renewal_jobs(fixture.subscription.id) == []

      if state == :past_due do
        mark_replay_fixture_past_due!(fixture.subscription.id, now)
        past_due = fetch_subscription!(fixture.subscription.id)
        assert past_due.status == :past_due
        assert DateTime.compare(past_due.current_period_end_at, now) in [:lt, :eq]
        assert DateTime.compare(past_due.next_retry_at, now) == :lt
        assert DateTime.compare(past_due.failed_payment_boundary_at, now) == :gt
        assert is_nil(past_due.retry_suppressed_at)
      end

      before = fetch_subscription!(fixture.subscription.id)
      assert subscription_renewal_jobs(fixture.subscription.id) == []
      assert before.current_plan_revision_id == fixture.revision.id

      assert fetch_contract_change!(seeded_change_id).effective_at == seeded_change.effective_at
      before_change_ids = contract_change_ids(fixture.subscription.id)
      support = actor_with_role!(:support, "#{prefix}_support")

      assert {:error, %{code: "FORBIDDEN"}} =
               queue_replay_target(kind, support, fixture.subscription.id, input)

      after_first_replay = fetch_subscription!(fixture.subscription.id)
      assert replayed_projection(after_first_replay, kind) == replayed_projection(before, kind)
      assert after_first_replay.aggregate_version == before.aggregate_version
      assert fetch_contract_change!(seeded_change_id).effective_at == seeded_change.effective_at
      assert contract_change_ids(fixture.subscription.id) == before_change_ids
      assert subscription_renewal_jobs(fixture.subscription.id) == []

      assert {:error, %{code: "FORBIDDEN"}} =
               queue_replay_target(kind, support, fixture.subscription.id, input)

      assert replayed_projection(fetch_subscription!(fixture.subscription.id), kind) ==
               replayed_projection(before, kind)

      assert fetch_subscription!(fixture.subscription.id).aggregate_version ==
               before.aggregate_version

      assert fetch_contract_change!(seeded_change_id).effective_at == seeded_change.effective_at
      assert contract_change_ids(fixture.subscription.id) == before_change_ids
      assert subscription_renewal_jobs(fixture.subscription.id) == []
    end
  end

  test "support cannot replace a queued target" do
    for state <- [:active, :past_due], kind <- [:plan, :variant] do
      prefix = "jc375_distinct_#{state}_#{kind}"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      fixture = subscription_fixture!(prefix, nil, %{started_at: DateTime.add(now, -62, :day)})
      first = replay_input!(fixture, kind, replay_target!(fixture, kind))
      second = replay_input!(fixture, kind, replay_target!(fixture, kind))
      admin = actor_with_role!(:admin, "#{prefix}_admin")
      support = actor_with_role!(:support, "#{prefix}_support")
      assert {:ok, seeded} = queue_replay_target(kind, admin, fixture.subscription.id, first)
      if state == :past_due, do: mark_replay_fixture_past_due!(fixture.subscription.id, now)
      before = fetch_subscription!(fixture.subscription.id)
      change = fetch_contract_change!(seeded.current_contract_change_id)
      changes = contract_change_ids(before.id)

      for _ <- 1..2 do
        assert {:error, %{code: "FORBIDDEN"}} =
                 queue_replay_target(kind, support, before.id, second)

        assert fetch_subscription!(before.id) == before
        assert fetch_contract_change!(change.id) == change
        assert contract_change_ids(before.id) == changes
        assert subscription_renewal_jobs(before.id) == []
      end
    end
  end

  test "authorized owner, admin and super admin retain queued target identity" do
    for role <- [:owner, :admin, :super_admin], kind <- [:plan, :variant] do
      prefix = "jc375_authorized_#{role}_#{kind}"
      fixture = subscription_fixture!(prefix, nil, %{})
      input = replay_input!(fixture, kind, replay_target!(fixture, kind))
      actor = if role == :owner, do: fixture.customer, else: actor_with_role!(role, prefix)
      queue = if role == :owner, do: &queue_owner_target/4, else: &queue_replay_target/4
      assert {:ok, seeded} = queue.(kind, actor, fixture.subscription.id, input)
      assert {:ok, replayed} = queue.(kind, actor, fixture.subscription.id, input)
      assert replayed.current_contract_change_id == seeded.current_contract_change_id
      assert replayed.aggregate_version == seeded.aggregate_version
      assert subscription_renewal_jobs(seeded.id) == []
    end
  end

  test "authorized past due replay retains renewal identity and respects retry suppression" do
    for kind <- [:plan, :variant], suppressed? <- [false, true] do
      prefix = "jc375_due_#{kind}_#{suppressed?}"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      fixture = subscription_fixture!(prefix, nil, %{started_at: DateTime.add(now, -62, :day)})
      input = replay_input!(fixture, kind, replay_target!(fixture, kind))
      admin = actor_with_role!(:admin, prefix)
      assert {:ok, seeded} = queue_replay_target(kind, admin, fixture.subscription.id, input)
      mark_replay_fixture_past_due!(fixture.subscription.id, now, suppressed?)
      before = fetch_subscription!(fixture.subscription.id)
      assert {:ok, period} = Scheduler.next_period(before.current_period_end_at, fixture.revision)
      expected_key = Scheduler.renewal_key(before.id, period.current_period_end_at)

      for _ <- 1..2 do
        assert {:ok, replay} = queue_replay_target(kind, admin, before.id, input)
        assert replay.current_contract_change_id == seeded.current_contract_change_id
        assert replay.aggregate_version == before.aggregate_version
        jobs = subscription_renewal_jobs(before.id)

        if suppressed? do
          assert jobs == []
        else
          assert [%Oban.Job{args: %{"renewal_key" => ^expected_key}}] = jobs
        end
      end
    end
  end

  test "unresolved bound renewal identity does not enqueue a replay" do
    for kind <- [:plan, :variant] do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      fixture =
        subscription_fixture!("jc375_unresolved_#{kind}", nil, %{
          started_at: DateTime.add(now, -62, :day)
        })

      input = replay_input!(fixture, kind, replay_target!(fixture, kind))
      admin = actor_with_role!(:admin, "jc375_unresolved_#{kind}")
      assert {:ok, seeded} = queue_replay_target(kind, admin, fixture.subscription.id, input)
      mark_replay_fixture_past_due!(fixture.subscription.id, now)
      before = fetch_subscription!(fixture.subscription.id)

      attempt =
        RenewalAttempt
        |> Ash.Changeset.for_create(
          :create_or_reuse,
          %{
            subscription_id: before.id,
            period_start_at: before.current_period_end_at,
            period_end_at: DateTime.add(before.current_period_end_at, 30, :day),
            renewal_key: "jc375-unresolved-#{Ash.UUIDv7.generate()}",
            status: :pending,
            attempt_no: 1
          },
          context: @system_context
        )
        |> Ash.create!(domain: Store.Subscriptions, context: @system_context)

      assert is_nil(attempt.plan_revision_id)
      assert {:ok, replay} = queue_replay_target(kind, admin, before.id, input)
      assert replay.current_contract_change_id == seeded.current_contract_change_id
      assert replay.aggregate_version == before.aggregate_version
      assert subscription_renewal_jobs(before.id) == []
    end
  end

  @tag :real_connections
  test "concurrent owner and support replays serialize on the locked subscription" do
    fixture = create_committed_subscription_fixture!()

    support =
      Sandbox.unboxed_run(Store.Repo, fn -> actor_with_role!(:support, "jc375_contention") end)

    on_exit(fn ->
      Sandbox.unboxed_run(Store.Repo, fn ->
        Store.Repo.query!("DELETE FROM role_assignments WHERE user_id = $1", [
          Ecto.UUID.dump!(support.id)
        ])

        Store.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(support.id)])
      end)

      delete_committed_subscription_fixture!(fixture)
    end)

    input = plan_change_input!(fixture.subscription_id, fixture.plan_a_id)

    assert {:ok, seeded} =
             Sandbox.unboxed_run(Store.Repo, fn ->
               queue_owner_target(:plan, fixture.customer, fixture.subscription_id, input)
             end)

    before =
      Sandbox.unboxed_run(Store.Repo, fn ->
        {fetch_subscription!(fixture.subscription_id),
         fetch_contract_change!(seeded.current_contract_change_id)}
      end)

    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Store.Repo, fn ->
          Store.Repo.transaction(fn ->
            %{rows: [[pid]]} = Store.Repo.query!("SELECT pg_backend_pid()")

            Store.Repo.query!("SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(fixture.subscription_id)
            ])

            send(parent, {:jc375_locked, pid})

            receive do
              :release -> :released
            after
              10_000 -> Store.Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    assert_receive {:jc375_locked, pid}

    tasks =
      for {role, actor} <- [owner: fixture.customer, support: support] do
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            send(parent, {:jc375_started, role})

            if role == :owner do
              queue_owner_target(:plan, actor, fixture.subscription_id, input)
            else
              queue_replay_target(:plan, actor, fixture.subscription_id, input)
            end
          end)
        end)
      end

    assert_receive {:jc375_started, :owner}
    assert_receive {:jc375_started, :support}
    await_blocked_writers!(pid, 2)
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)
    [owner_result, support_result] = Enum.map(tasks, &Task.await(&1, 10_000))
    assert {:ok, replayed} = owner_result
    assert {:error, %{code: "FORBIDDEN"}} = support_result
    assert replayed.current_contract_change_id == seeded.current_contract_change_id
    assert replayed.aggregate_version == seeded.aggregate_version

    Sandbox.unboxed_run(Store.Repo, fn ->
      assert {fetch_subscription!(fixture.subscription_id),
              fetch_contract_change!(seeded.current_contract_change_id)} == before

      assert contract_change_ids(fixture.subscription_id) ==
               MapSet.new([seeded.current_contract_change_id])

      assert subscription_renewal_jobs(fixture.subscription_id) == []
    end)
  end

  @tag :real_connections
  test "stale replays re-evaluate authorization against the reloaded subscription" do
    for role <- [:support, :owner] do
      fixture = create_committed_subscription_fixture!()

      support =
        Sandbox.unboxed_run(Store.Repo, fn -> actor_with_role!(:support, "jc375_stale") end)

      on_exit(fn ->
        Sandbox.unboxed_run(Store.Repo, fn ->
          Store.Repo.query!("DELETE FROM role_assignments WHERE user_id = $1", [
            Ecto.UUID.dump!(support.id)
          ])

          Store.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(support.id)])
        end)

        delete_committed_subscription_fixture!(fixture)
      end)

      input = plan_change_input!(fixture.subscription_id, fixture.plan_a_id)

      seeded =
        Sandbox.unboxed_run(Store.Repo, fn ->
          {:ok, seeded} =
            queue_owner_target(:plan, fixture.customer, fixture.subscription_id, input)

          seeded
        end)

      parent = self()
      event = [:store, :subscriptions, :contract_change, :before_persist]
      handler = "jc375-stale-#{System.unique_integer([:positive])}"
      subscription_id = fixture.subscription_id

      :ok =
        :telemetry.attach(
          handler,
          event,
          fn _, _, metadata, _ ->
            if metadata.subscription_id == subscription_id do
              attempt = Process.get(handler, 0) + 1
              Process.put(handler, attempt)
              send(parent, {:jc375_attempt, role, attempt, self(), metadata.intent_kind})

              if attempt == 1 do
                receive do
                  {:jc375_resume, ^handler} -> :ok
                after
                  10_000 -> raise "stale replay release timed out"
                end
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      sql_handler = handler <> "-sql"

      :ok =
        :telemetry.attach(
          sql_handler,
          [:store, :repo, :query],
          fn _, _, metadata, _ ->
            if Process.get(handler, 0) == 2 and
                 String.contains?(metadata.query, "contract_changes") do
              send(parent, {:jc375_retry_target_read, role, self()})
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(sql_handler) end)

      replay =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            if role == :support do
              queue_replay_target(:plan, support, subscription_id, input)
            else
              queue_owner_target(:plan, fixture.customer, subscription_id, input)
            end
          end)
        end)

      assert_receive {:jc375_attempt, ^role, 1, replay_pid, :plan_change}, 10_000

      mutation =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            Store.Repo.transaction(fn ->
              subscription = fetch_subscription!(subscription_id)
              assert subscription.aggregate_version == seeded.aggregate_version

              subscription
              |> Ash.Changeset.for_update(:advance_payment_method_setup_generation, %{},
                context: @system_context
              )
              |> Ash.update!(domain: Store.Subscriptions, actor: nil, context: @system_context)
            end)
          end)
        end)

      assert {:ok, updated} = Task.await(mutation, 10_000)
      assert updated.aggregate_version == seeded.aggregate_version + 1
      assert updated.current_contract_change_id == seeded.current_contract_change_id

      before =
        Sandbox.unboxed_run(Store.Repo, fn ->
          {fetch_subscription!(subscription_id),
           fetch_contract_change!(seeded.current_contract_change_id)}
        end)

      send(replay_pid, {:jc375_resume, handler})
      assert_receive {:jc375_attempt, ^role, 2, ^replay_pid, :plan_change}, 10_000
      result = Task.await(replay, 10_000)
      assert_receive {:jc375_retry_target_read, ^role, ^replay_pid}, 1_000

      case role do
        :support ->
          assert {:error, %{code: "FORBIDDEN"}} = result

        :owner ->
          assert {:ok, replayed} = result
          assert replayed.current_contract_change_id == seeded.current_contract_change_id
          assert replayed.aggregate_version == updated.aggregate_version
      end

      refute_receive {:jc375_attempt, ^role, 3, ^replay_pid, _}, 0

      Sandbox.unboxed_run(Store.Repo, fn ->
        assert {fetch_subscription!(subscription_id),
                fetch_contract_change!(seeded.current_contract_change_id)} == before

        assert contract_change_ids(subscription_id) ==
                 MapSet.new([seeded.current_contract_change_id])

        assert subscription_renewal_jobs(subscription_id) == []
      end)

      :ok = :telemetry.detach(handler)
      :ok = :telemetry.detach(sql_handler)
    end
  end

  defp subscription_fixture!(prefix, customer, overrides) do
    customer = customer || SubscriptionsFixtures.create_customer!("#{prefix}_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_#{prefix}",
        provider_billing_ref: "pm_#{prefix}",
        started_at:
          Map.get(overrides, :started_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
      })

    Map.merge(fixture, %{customer: customer, plan: plan, variant: variant})
  end

  defp attach_revision_to_plan!(fixture) do
    plan = SubscriptionsFixtures.create_subscription_plan!()

    _attachment =
      SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, plan.id)

    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    %{plan: plan, revision: revision}
  end

  defp attach_target_variant!(fixture) do
    %{variant: target_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    _attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, fixture.plan.id)

    target_variant
  end

  defp replay_target!(fixture, :plan), do: attach_revision_to_plan!(fixture)
  defp replay_target!(fixture, :variant), do: attach_target_variant!(fixture)

  defp replay_input!(fixture, :plan, target),
    do: plan_change_input!(fixture.subscription.id, target.plan.id)

  defp replay_input!(fixture, :variant, target),
    do: variant_change_input!(fixture.subscription.id, target.id)

  defp queue_replay_target(:plan, actor, subscription_id, input),
    do: Facade.queue_subscription_plan_change_for_admin(actor, subscription_id, input)

  defp queue_replay_target(:variant, actor, subscription_id, input),
    do: Facade.queue_subscription_variant_change_for_admin(actor, subscription_id, input)

  defp queue_owner_target(:plan, actor, subscription_id, input),
    do: Facade.queue_subscription_plan_change_for_user(actor, subscription_id, input)

  defp queue_owner_target(:variant, actor, subscription_id, input),
    do: Facade.queue_subscription_variant_change_for_user(actor, subscription_id, input)

  defp replayed_projection(subscription, :plan),
    do:
      {subscription.status, subscription.pending_subscription_plan_id,
       subscription.current_contract_change_id}

  defp replayed_projection(subscription, :variant),
    do:
      {subscription.status, subscription.pending_variant_id,
       subscription.current_contract_change_id}

  defp mark_replay_fixture_past_due!(subscription_id, now, suppressed? \\ false) do
    changeset =
      fetch_subscription!(subscription_id)
      |> Ash.Changeset.for_update(:mark_past_due_transition, %{
        billing_status_reason: "payment_failed",
        past_due_since_at: DateTime.add(now, -86_400, :second),
        failed_payment_boundary_at: DateTime.add(now, 86_400, :second),
        dunning_attempt_count: 1,
        next_retry_at: DateTime.add(now, -1, :second),
        retry_suppressed_at: if(suppressed?, do: now, else: nil)
      })

    assert changeset.valid?

    assert {:ok, _updated} =
             Ash.update(changeset,
               domain: Store.Subscriptions,
               actor: nil,
               context: @system_context
             )
  end

  defp plan_change_input!(subscription_id, target_plan_id) do
    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               "subscription_id" => subscription_id,
               "subscription_plan_id" => target_plan_id
             })

    input
  end

  defp variant_change_input!(subscription_id, target_variant_id) do
    assert {:ok, input} =
             QueueSubscriptionVariantChangeInput.new(%{
               "subscription_id" => subscription_id,
               "variant_id" => target_variant_id
             })

    input
  end

  defp actor_with_role!(role, prefix) do
    actor = TestFixtures.register_user!(email: TestFixtures.unique_email(prefix))
    _assignment = TestFixtures.assign_role!(actor, role)
    actor
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> List.first()
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> List.first()
  end

  defp contract_change_ids(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp subscription_renewal_jobs(subscription_id) do
    all_enqueued(worker: Store.Workers.ProcessSubscriptionRenewalWorker)
    |> Enum.filter(&(&1.args["subscription_id"] == subscription_id))
  end

  defp await_blocked_writers!(blocker_pid, expected, attempts_left \\ 500)

  defp await_blocked_writers!(blocker_pid, expected, attempts_left)
       when attempts_left > 0 do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query(
        """
        SELECT count(*)
        FROM pg_stat_activity waiting
        WHERE waiting.wait_event_type = 'Lock'
          AND (
            $1 = ANY(pg_blocking_pids(waiting.pid))
            OR EXISTS (
              SELECT 1
              FROM pg_stat_activity direct_waiter
              WHERE $1 = ANY(pg_blocking_pids(direct_waiter.pid))
                AND direct_waiter.pid = ANY(pg_blocking_pids(waiting.pid))
            )
          )
        """,
        [blocker_pid]
      )

    if count >= expected do
      :ok
    else
      Process.sleep(10)
      await_blocked_writers!(blocker_pid, expected, attempts_left - 1)
    end
  end

  defp await_blocked_writers!(_blocker_pid, expected, _attempts_left) do
    flunk("expected #{expected} Subscription writers to wait for the held aggregate lock")
  end

  defp create_committed_subscription_fixture! do
    Sandbox.unboxed_run(Store.Repo, fn ->
      customer = SubscriptionsFixtures.create_customer!("sbh_10_06_concurrent")
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      current_plan = SubscriptionsFixtures.create_subscription_plan!()
      plan_a = SubscriptionsFixtures.create_subscription_plan!()
      plan_b = SubscriptionsFixtures.create_subscription_plan!()
      SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan_a.id)
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan_b.id)
      revision_a = SubscriptionsFixtures.create_plan_revision!(plan_a)
      revision_b = SubscriptionsFixtures.create_plan_revision!(plan_b)

      %{subscription: subscription, order: order, line_item: line_item, revision: revision} =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan)

      %{
        customer: customer,
        amount_minor: revision.amount_minor,
        customer_id: customer.id,
        currency: revision.currency,
        effective_at: subscription.next_renewal_at,
        line_item_id: line_item.id,
        order_id: order.id,
        plan_ids: [current_plan.id, plan_a.id, plan_b.id],
        product_id: variant.product_id,
        revision_ids: [revision.id, revision_a.id, revision_b.id],
        revision_a_id: revision_a.id,
        revision_b_id: revision_b.id,
        subscription_id: subscription.id,
        variant_id: variant.id,
        plan_a_id: plan_a.id,
        plan_b_id: plan_b.id
      }
    end)
  end

  defp delete_committed_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      Store.Repo.query!(
        "UPDATE subscriptions SET current_contract_change_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(fixture.subscription_id)]
      )

      Store.Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
        Ecto.UUID.dump!(fixture.subscription_id)
      ])

      Store.Repo.query!("DELETE FROM subscriptions WHERE id = $1", [
        Ecto.UUID.dump!(fixture.subscription_id)
      ])

      Store.Repo.query!("DELETE FROM order_line_items WHERE id = $1", [
        Ecto.UUID.dump!(fixture.line_item_id)
      ])

      Store.Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [
        Ecto.UUID.dump!(fixture.order_id)
      ])

      Store.Repo.query!("DELETE FROM plan_revisions WHERE id = ANY($1)", [
        Enum.map(fixture.revision_ids, &Ecto.UUID.dump!/1)
      ])

      Store.Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [
        Ecto.UUID.dump!(fixture.variant_id)
      ])

      Store.Repo.query!("DELETE FROM subscription_plans WHERE id = ANY($1)", [
        Enum.map(fixture.plan_ids, &Ecto.UUID.dump!/1)
      ])

      Store.Repo.query!("DELETE FROM orders WHERE id = $1", [Ecto.UUID.dump!(fixture.order_id)])

      Store.Repo.query!("DELETE FROM products WHERE id = $1", [
        Ecto.UUID.dump!(fixture.product_id)
      ])

      Store.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(fixture.customer_id)])
    end)
  end
end
