defmodule Store.Subscriptions.Sbh2002RenewalImmediateCancellationTest do
  use Store.DataCase, async: false

  @normal_cancel_now_query_bound 20

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo

  alias Store.Subscriptions.{
    ContractChange,
    Facade,
    Inputs.QueueSubscriptionPlanChangeInput,
    RenewalAttempt,
    RenewalCollectionAttempt,
    Subscription
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "cancel-now re-evaluates its original intent after renewal checkpoint B wins" do
    fixture = create_committed_fixture!("b_wins_stale_cancel")
    enable_stripe!()

    parent = self()
    read_barrier = make_ref()
    read_count = :atomics.new(1, [])
    stale_query_phase = :atomics.new(1, [])
    :atomics.put(stale_query_phase, 1, 1)
    stale_query_counts = :atomics.new(2, [])
    dispatch_barrier = make_ref()
    dispatch_count = :atomics.new(1, [])
    provider_post_count = :atomics.new(1, [])
    cancel_start = make_ref()

    cancel_task =
      Task.async(fn ->
        send(parent, {:cancel_task_ready, self(), cancel_start})

        receive do
          {:start_cancel, ^cancel_start} ->
            Sandbox.unboxed_run(Repo, fn ->
              Facade.cancel_subscription_for_user(
                fixture.customer,
                fixture.subscription_id,
                :now
              )
            end)

          :abort ->
            :aborted
        end
      end)

    assert_receive {:cancel_task_ready, cancel_task_pid, ^cancel_start}
    facade_read_trace = trace_authorized_surface_reads(cancel_task_pid, :user)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(provider_post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    read_handler_id =
      attach_subscription_read_barrier(
        cancel_task_pid,
        parent,
        read_barrier,
        read_count,
        [1],
        :user,
        phase_counts: stale_query_counts,
        phase: stale_query_phase,
        phase_switch_read: 2
      )

    dispatch_handler_id =
      {__MODULE__, :renewal_before_dispatch, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        dispatch_handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_check],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id and
               :atomics.exchange(config.once, 1, 1) == 0 do
            send(
              config.owner,
              {:renewal_before_dispatch, config.barrier, metadata.renewal_attempt_id,
               metadata.collection_attempt_id}
            )

            barrier = config.barrier

            receive do
              {:release_renewal_dispatch, ^barrier} -> :ok
            after
              10_000 -> send(config.owner, {:renewal_dispatch_timeout, config.barrier})
            end
          end
        end,
        %{
          owner: parent,
          barrier: dispatch_barrier,
          once: dispatch_count,
          subscription_id: fixture.subscription_id
        }
      )

    on_exit(fn ->
      :telemetry.detach(read_handler_id)
      :telemetry.detach(dispatch_handler_id)
      stop_authorized_surface_read_trace(facade_read_trace)
      send(cancel_task.pid, :abort)
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    end)

    send(cancel_task.pid, {:start_cancel, cancel_start})

    assert_receive {:cancel_user_read, ^read_barrier, 1}, 10_000

    assert fixture_subscription_version(fixture.subscription_id) ==
             fixture.initial_aggregate_version

    renewal_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
            now: fixture.now
          )
        end)
      end)

    on_exit(fn ->
      send(renewal_task.pid, {:release_renewal_dispatch, dispatch_barrier})
    end)

    assert_receive {:renewal_before_dispatch, ^dispatch_barrier, renewal_attempt_id,
                    collection_attempt_id},
                   10_000

    renewal_snapshot =
      Sandbox.unboxed_run(Repo, fn ->
        %{
          subscription: fetch_subscription!(fixture.subscription_id),
          renewal_attempt: fetch_renewal_attempt!(renewal_attempt_id),
          collection_attempt: fetch_collection_attempt!(collection_attempt_id)
        }
      end)

    assert renewal_snapshot.subscription.aggregate_version ==
             fixture.initial_aggregate_version + 1

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    cancel_result = Task.await(cancel_task, 10_000)

    send(renewal_task.pid, {:release_renewal_dispatch, dispatch_barrier})
    assert {:ok, :processed} = Task.await(renewal_task, 10_000)

    canceled = fixture_subscription(fixture.subscription_id)

    assert match?(
             {:ok, %Subscription{status: :canceled, cancel_at_period_end: false}},
             cancel_result
           )

    assert authorized_surface_read_count(facade_read_trace) == 2
    assert renewal_snapshot.renewal_attempt.id

    assert renewal_snapshot.collection_attempt.renewal_attempt_id ==
             renewal_snapshot.renewal_attempt.id

    assert canceled.status == :canceled
    assert canceled.cancel_at_period_end == false
    assert canceled.aggregate_version == renewal_snapshot.subscription.aggregate_version + 1
    assert :atomics.get(provider_post_count, 1) == 0

    first_attempt_queries = :atomics.get(stale_query_counts, 1)
    reevaluation_queries = :atomics.get(stale_query_counts, 2)
    assert first_attempt_queries > 0
    assert reevaluation_queries > 0

    IO.puts(
      "JC-232 stale_first_attempt_queries=#{first_attempt_queries} " <>
        "stale_reevaluation_queries=#{reevaluation_queries} max_cancel_transactions=2"
    )

    assert {:ok, duplicate} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :now
               )
             end)

    assert duplicate.status == :canceled
    assert duplicate.cancel_at_period_end == false
    assert duplicate.aggregate_version == canceled.aggregate_version
  end

  test "normal cancel-now keeps the one-pass query path" do
    fixture = create_committed_fixture!("normal_cancel_now")

    {result, stats} =
      RepoStats.capture(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            fixture.subscription_id,
            :now
          )
        end)
      end)

    assert {:ok, %Subscription{status: :canceled, cancel_at_period_end: false}} = result
    assert stats.query_count <= @normal_cancel_now_query_bound

    IO.puts(
      "JC-232 normal_cancel_now_queries=#{stats.query_count} " <>
        "query_bound=#{@normal_cancel_now_query_bound}"
    )
  end

  test "cancel-now establishes current NON_EFFECTIVE target before transaction commit" do
    fixture = create_sandboxed_subscription_fixture!("cancel_effect_atomic")

    assert fixture.revision.access_on_cancel == :remove_immediately
    assert fixture.subscription.current_plan_revision_id == fixture.revision.id

    assert {:ok, canceled} =
             Repo.transaction(fn ->
               assert {:ok, canceled} =
                        Facade.cancel_subscription_for_user(
                          fixture.customer,
                          fixture.subscription_id,
                          :now
                        )

               assert [effect] = access_effect_rows!(fixture.subscription_id)
               assert effect.status == "required"
               assert effect.disposition == "non_effective"
               assert effect.source_version == canceled.aggregate_version
               assert effect.entitlement_kind == nil
               assert effect.entitlement_scope_key == nil
               assert effect.valid_from_at == nil
               assert effect.valid_until_at == nil
               assert effect.source_order_line_item_id == canceled.source_order_line_item_id
               assert effect.contract_change_id == canceled.current_contract_change_id
               assert effect.plan_revision_id == canceled.current_plan_revision_id

               canceled
             end)

    assert canceled.status == :canceled

    assert [effect] = access_effect_rows!(fixture.subscription_id)

    assert effect.source_version == canceled.aggregate_version
    assert effect.disposition == "non_effective"
  end

  test "cancel-now rolls back when NON_EFFECTIVE AccessEffect establishment fails" do
    fixture = create_sandboxed_subscription_fixture!("cancel_effect_rollback")

    assert fixture.revision.access_on_cancel == :remove_immediately
    assert fixture.subscription.current_plan_revision_id == fixture.revision.id

    {trigger_name, function_name} = fail_cancel_access_effect_insert!()
    before = fetch_subscription!(fixture.subscription_id)
    before_effect_count = access_effect_count!(fixture.subscription_id)

    try do
      Repo.query!(
        "SELECT set_config('store.f05_fail_cancel_effect_subscription', $1, false)",
        [fixture.subscription_id]
      )

      assert {:error, %Error{}} =
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :now
               )

      current = fetch_subscription!(fixture.subscription_id)
      assert current.status == :active
      assert current.cancel_at_period_end == false
      assert current.aggregate_version == before.aggregate_version
      assert access_effect_count!(fixture.subscription_id) == before_effect_count
    after
      Repo.query!("SELECT set_config('store.f05_fail_cancel_effect_subscription', '', false)")
      drop_cancel_access_effect_failure_trigger!(trigger_name, function_name)
    end
  end

  test "cancel-now rejects refreshed expired state without changing its command" do
    fixture = create_committed_fixture!("expired_wins_stale_cancel")
    parent = self()
    read_barrier = make_ref()
    read_count = :atomics.new(1, [])

    {cancel_task, cancel_start, cancel_task_pid} =
      start_gated_cancel_task(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            fixture.subscription_id,
            :now
          )
        end)
      end)

    facade_read_trace = trace_authorized_surface_reads(cancel_task_pid, :user)

    read_handler_id =
      attach_subscription_read_barrier(
        cancel_task_pid,
        parent,
        read_barrier,
        read_count,
        [1],
        :user
      )

    on_exit(fn ->
      :telemetry.detach(read_handler_id)
      stop_authorized_surface_read_trace(facade_read_trace)
      send(cancel_task.pid, :abort)
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    end)

    send(cancel_task.pid, {:start_cancel, cancel_start})
    assert_receive {:cancel_user_read, ^read_barrier, 1}, 10_000

    expired =
      Sandbox.unboxed_run(Repo, fn ->
        fixture.subscription_id
        |> fetch_subscription!()
        |> update_subscription!(:mark_expired_transition, %{})
      end)

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    cancel_result = Task.await(cancel_task, 10_000)
    current = fixture_subscription(fixture.subscription_id)
    contract_change = fetch_contract_change!(fixture.subscription_id)

    assert {:error, %Error{} = error} = cancel_result
    assert error.code in ["INVALID_TRANSITION", "VALIDATION_ERROR"]
    assert authorized_surface_read_count(facade_read_trace) == 2
    assert expired.status == :expired
    assert current.status == :expired
    assert current.cancel_at_period_end == false
    assert current.aggregate_version == expired.aggregate_version
    assert contract_change.status == :queued
  end

  test "a second aggregate conflict returns STALE_RECORD after one re-evaluation" do
    fixture = create_committed_fixture!("second_stale_cancel")
    parent = self()
    read_barrier = make_ref()
    read_count = :atomics.new(1, [])

    {cancel_task, cancel_start, cancel_task_pid} =
      start_gated_cancel_task(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            fixture.subscription_id,
            :now
          )
        end)
      end)

    facade_read_trace = trace_authorized_surface_reads(cancel_task_pid, :user)

    read_handler_id =
      attach_subscription_read_barrier(
        cancel_task_pid,
        parent,
        read_barrier,
        read_count,
        [1, 2],
        :user
      )

    on_exit(fn ->
      :telemetry.detach(read_handler_id)
      stop_authorized_surface_read_trace(facade_read_trace)
      send(cancel_task.pid, :abort)
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 2})
    end)

    send(cancel_task.pid, {:start_cancel, cancel_start})
    assert_receive {:cancel_user_read, ^read_barrier, 1}, 10_000

    first_winner =
      Sandbox.unboxed_run(Repo, fn ->
        fixture.subscription_id
        |> fetch_subscription!()
        |> update_subscription!(:mark_past_due_transition, %{
          billing_status_reason: "PAYMENT_FAILED",
          dunning_attempt_count: 1
        })
      end)

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    assert_receive {:cancel_user_read, ^read_barrier, 2}, 10_000

    second_winner =
      Sandbox.unboxed_run(Repo, fn ->
        fixture.subscription_id
        |> fetch_subscription!()
        |> update_subscription!(:set_provider_billing_reference, %{
          provider_customer_ref: "cus_jc232_second_writer",
          provider_billing_ref: "pm_jc232_second_writer"
        })
      end)

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 2})
    cancel_result = Task.await(cancel_task, 10_000)
    current = fixture_subscription(fixture.subscription_id)

    assert first_winner.aggregate_version == fixture.initial_aggregate_version + 1
    assert second_winner.aggregate_version == first_winner.aggregate_version + 1
    assert {:error, %Error{code: "STALE_RECORD"}} = cancel_result
    assert authorized_surface_read_count(facade_read_trace) == 2
    assert current.status == :past_due
    assert current.cancel_at_period_end == false
    assert current.aggregate_version == second_winner.aggregate_version
    assert current.provider_customer_ref == "cus_jc232_second_writer"
    assert current.provider_billing_ref == "pm_jc232_second_writer"
  end

  test "admin cancel-now re-evaluates through the admin authorization path" do
    fixture = create_committed_fixture!("admin_stale_cancel")

    Sandbox.unboxed_run(Repo, fn ->
      TestFixtures.assign_role!(fixture.customer, :admin)
    end)

    parent = self()
    read_barrier = make_ref()
    read_count = :atomics.new(1, [])

    {cancel_task, cancel_start, cancel_task_pid} =
      start_gated_cancel_task(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_admin(
            fixture.customer,
            fixture.subscription_id,
            :now
          )
        end)
      end)

    facade_read_trace = trace_authorized_surface_reads(cancel_task_pid, :admin)

    read_handler_id =
      attach_subscription_read_barrier(
        cancel_task_pid,
        parent,
        read_barrier,
        read_count,
        [1],
        :admin
      )

    on_exit(fn ->
      :telemetry.detach(read_handler_id)
      stop_authorized_surface_read_trace(facade_read_trace)
      send(cancel_task.pid, :abort)
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    end)

    send(cancel_task.pid, {:start_cancel, cancel_start})
    assert_receive {:cancel_user_read, ^read_barrier, 1}, 10_000

    winner =
      Sandbox.unboxed_run(Repo, fn ->
        fixture.subscription_id
        |> fetch_subscription!()
        |> update_subscription!(:mark_past_due_transition, %{
          billing_status_reason: "PAYMENT_FAILED",
          dunning_attempt_count: 1
        })
      end)

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    cancel_result = Task.await(cancel_task, 10_000)
    current = fixture_subscription(fixture.subscription_id)

    assert {:ok, %Subscription{status: :canceled, cancel_at_period_end: false}} = cancel_result
    assert authorized_surface_read_count(facade_read_trace) == 2
    assert winner.aggregate_version == fixture.initial_aggregate_version + 1
    assert current.status == :canceled
    assert current.cancel_at_period_end == false
    assert current.aggregate_version == winner.aggregate_version + 1
  end

  test "user stale retry stops when the original actor can no longer read the Subscription" do
    fixture = create_committed_fixture!("user_loses_stale_cancel_access")
    parent = self()
    read_barrier = make_ref()
    read_count = :atomics.new(1, [])

    {cancel_task, cancel_start, cancel_task_pid} =
      start_gated_cancel_task(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            fixture.subscription_id,
            :now
          )
        end)
      end)

    facade_read_trace = trace_authorized_surface_reads(cancel_task_pid, :user)

    read_handler_id =
      attach_subscription_read_barrier(
        cancel_task_pid,
        parent,
        read_barrier,
        read_count,
        [1],
        :user
      )

    on_exit(fn ->
      :telemetry.detach(read_handler_id)
      stop_authorized_surface_read_trace(facade_read_trace)
      send(cancel_task.pid, :abort)
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    end)

    send(cancel_task.pid, {:start_cancel, cancel_start})
    assert_receive {:cancel_user_read, ^read_barrier, 1}, 10_000

    winner =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, %{num_rows: 1}} =
          Repo.query(
            "UPDATE subscriptions SET user_id = $2, aggregate_version = aggregate_version + 1 WHERE id = $1",
            [Ecto.UUID.dump!(fixture.subscription_id), Ecto.UUID.dump!(fixture.other_customer_id)]
          )

        fetch_subscription!(fixture.subscription_id)
      end)

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier, 1})
    cancel_result = Task.await(cancel_task, 10_000)
    current = fixture_subscription(fixture.subscription_id)

    assert {:error, %Error{code: "SUBSCRIPTION_NOT_FOUND"}} = cancel_result
    assert authorized_surface_read_count(facade_read_trace) == 2
    assert :atomics.get(read_count, 1) == 2
    assert winner.aggregate_version == fixture.initial_aggregate_version + 1
    assert current.user_id == fixture.other_customer_id
    assert current.status == :active
    assert current.cancel_at_period_end == false
    assert current.aggregate_version == winner.aggregate_version

    assert {:ok, nil} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.get_subscription_for_user(fixture.customer, fixture.subscription_id)
             end)
  end

  defp create_committed_fixture!(suffix) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        unique = "#{suffix}_#{Ecto.UUID.generate()}"
        customer = SubscriptionsFixtures.create_customer!("jc232_#{unique}")
        other_customer = SubscriptionsFixtures.create_customer!("jc232_other_#{unique}")

        %{product: product, variant: variant} =
          SubscriptionsFixtures.create_subscription_sellable!()

        plan = SubscriptionsFixtures.create_subscription_plan!()
        attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
        target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_100})
        target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
        target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %{subscription: subscription, order: order, line_item: line_item, revision: revision} =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            provider_billing_ref: "pm_jc232_#{unique}",
            started_at: DateTime.add(now, -40 * 86_400, :second)
          })

        {:ok, change_input} =
          QueueSubscriptionPlanChangeInput.new(%{
            "subscription_id" => subscription.id,
            "subscription_plan_id" => target_plan.id
          })

        {:ok, queued_subscription} =
          Facade.queue_subscription_plan_change_for_user(
            customer,
            subscription.id,
            change_input
          )

        %{
          attachment_id: attachment.id,
          customer: customer,
          customer_id: customer.id,
          initial_aggregate_version: queued_subscription.aggregate_version,
          line_item_id: line_item.id,
          now: now,
          other_customer_id: other_customer.id,
          order_id: order.id,
          plan_id: plan.id,
          product_id: product.id,
          revision_id: revision.id,
          subscription_id: subscription.id,
          target_attachment_id: target_attachment.id,
          target_plan_id: target_plan.id,
          target_revision_id: target_revision.id
        }
      end)

    on_exit(fn -> cleanup_committed_fixture!(fixture) end)
    fixture
  end

  defp create_sandboxed_subscription_fixture!(suffix) do
    unique = "#{suffix}_#{Ecto.UUID.generate()}"
    customer = SubscriptionsFixtures.create_customer!("jc245_#{unique}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        access_on_cancel: :remove_immediately
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc245_#{unique}"
      })

    %{
      customer: customer,
      revision: revision,
      subscription: subscription,
      subscription_id: subscription.id
    }
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      sub_id = Ecto.UUID.dump!(fixture.subscription_id)
      user_id = Ecto.UUID.dump!(fixture.customer_id)
      other_user_id = Ecto.UUID.dump!(fixture.other_customer_id)

      Repo.query!(
        "DELETE FROM oban_jobs WHERE args->>'subscription_id' = $1 OR args->>'order_id' IN (SELECT id::text FROM orders WHERE user_id = $2)",
        [fixture.subscription_id, user_id]
      )

      Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 OR order_id IN (SELECT id FROM orders WHERE user_id = $2)",
        [sub_id, user_id]
      )

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

      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
        )

        Repo.query!(
          "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
          [sub_id]
        )

        Repo.query!(
          "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
        )
      end)

      Repo.query!(
        "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [sub_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [sub_id])

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [sub_id]
      )

      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [sub_id])

      Repo.query!("UPDATE subscriptions SET current_contract_change_id = NULL WHERE id = $1", [
        sub_id
      ])

      Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [sub_id])

      Repo.query!(
        "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])

      Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [
        Ecto.UUID.dump!(fixture.revision_id)
      ])

      Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [
        Ecto.UUID.dump!(fixture.attachment_id)
      ])

      Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [
        Ecto.UUID.dump!(fixture.target_revision_id)
      ])

      Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [
        Ecto.UUID.dump!(fixture.target_attachment_id)
      ])

      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [
        Ecto.UUID.dump!(fixture.plan_id)
      ])

      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [
        Ecto.UUID.dump!(fixture.target_plan_id)
      ])

      Repo.query!("DELETE FROM products WHERE id = $1", [Ecto.UUID.dump!(fixture.product_id)])

      Repo.query!("DELETE FROM role_assignments WHERE user_id IN ($1, $2)", [
        user_id,
        other_user_id
      ])

      Repo.query!("DELETE FROM users WHERE id = $1", [other_user_id])
      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end

  defp trace_authorized_surface_reads(pid, surface) do
    function = authorized_surface_read_function(surface)

    :erlang.trace_pattern({Facade, function, 2}, true, [:local])
    :erlang.trace(pid, true, [:call])

    {pid, function}
  end

  defp stop_authorized_surface_read_trace({pid, function}) do
    if Process.alive?(pid), do: :erlang.trace(pid, false, [:call])

    :erlang.trace_pattern({Facade, function, 2}, false, [:local])
  end

  defp authorized_surface_read_count({pid, function}) do
    collect_authorized_surface_read_trace(pid, function, 0)
  end

  defp collect_authorized_surface_read_trace(pid, function, count) do
    receive do
      {:trace, ^pid, :call, {Facade, ^function, [_actor, _subscription_id]}} ->
        collect_authorized_surface_read_trace(pid, function, count + 1)
    after
      0 ->
        count
    end
  end

  defp authorized_surface_read_function(:user), do: :get_subscription_for_user
  defp authorized_surface_read_function(:admin), do: :get_subscription_for_admin

  defp start_gated_cancel_task(operation) do
    parent = self()
    start_barrier = make_ref()

    task =
      Task.async(fn ->
        send(parent, {:cancel_task_ready, self(), start_barrier})

        receive do
          {:start_cancel, ^start_barrier} -> operation.()
          :abort -> :aborted
        end
      end)

    assert_receive {:cancel_task_ready, cancel_task_pid, ^start_barrier}, 10_000
    {task, start_barrier, cancel_task_pid}
  end

  defp attach_subscription_read_barrier(
         cancel_task_pid,
         owner,
         barrier,
         read_count,
         pause_on,
         surface,
         opts \\ []
       ) do
    handler_id = {__MODULE__, :authorized_subscription_read, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, config ->
          if self() == config.cancel_task_pid do
            record_cancel_query(config, metadata)
          end
        end,
        %{
          owner: owner,
          barrier: barrier,
          cancel_task_pid: cancel_task_pid,
          read_count: read_count,
          pause_on: pause_on,
          surface: surface,
          phase_counts: Keyword.get(opts, :phase_counts),
          phase: Keyword.get(opts, :phase, :atomics.new(1, [])),
          phase_switch_read: Keyword.get(opts, :phase_switch_read)
        }
      )

    handler_id
  end

  defp record_cancel_query(config, metadata) do
    matching_read? = subscription_query?(metadata, config.surface)
    read_no = if matching_read?, do: :atomics.add_get(config.read_count, 1, 1)

    if matching_read? and read_no == config.phase_switch_read do
      :atomics.put(config.phase, 1, 2)
    end

    if config.phase_counts do
      phase = :atomics.get(config.phase, 1)
      :atomics.add(config.phase_counts, phase, 1)
    end

    pause_cancel_read(config, matching_read?, read_no)
  end

  defp pause_cancel_read(config, true, read_no) do
    if read_no in config.pause_on, do: await_cancel_read(config, read_no)
  end

  defp pause_cancel_read(_config, _matching_read?, _read_no), do: :ok

  defp await_cancel_read(config, read_no) do
    send(config.owner, {:cancel_user_read, config.barrier, read_no})

    barrier = config.barrier

    receive do
      {:release_cancel_user_read, ^barrier, ^read_no} -> :ok
    after
      10_000 -> send(config.owner, {:cancel_user_read_timeout, config.barrier, read_no})
    end
  end

  defp subscription_query?(metadata, :user), do: user_subscription_query?(metadata)

  defp subscription_query?(metadata, :admin) do
    source = metadata |> Map.get(:source) |> to_string()
    query = metadata |> Map.get(:query, "") |> String.downcase()

    source == "subscriptions" and String.starts_with?(query, "select ") and
      String.contains?(query, "where") and
      String.contains?(query, "id")
  end

  defp user_subscription_query?(metadata) do
    source = metadata |> Map.get(:source) |> to_string()
    query = metadata |> Map.get(:query, "") |> String.downcase()

    case String.split(query, "where", parts: 2) do
      [_select, predicate] ->
        source == "subscriptions" and String.starts_with?(query, "select ") and
          String.contains?(predicate, "user_id")

      _ ->
        false
    end
  end

  defp fixture_subscription_version(subscription_id) do
    fixture_subscription(subscription_id).aggregate_version
  end

  defp access_effect_rows!(subscription_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT status::text, disposition::text, source_version, entitlement_kind::text,
               entitlement_scope_key, valid_from_at, valid_until_at,
               source_order_line_item_id::text, contract_change_id::text,
               plan_revision_id::text
        FROM access_effects
        WHERE subscription_id = $1
        ORDER BY source_version DESC, inserted_at DESC, id DESC
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    Enum.map(rows, fn [
                        status,
                        disposition,
                        source_version,
                        entitlement_kind,
                        entitlement_scope_key,
                        valid_from_at,
                        valid_until_at,
                        source_order_line_item_id,
                        contract_change_id,
                        plan_revision_id
                      ] ->
      %{
        status: status,
        disposition: disposition,
        source_version: source_version,
        entitlement_kind: entitlement_kind,
        entitlement_scope_key: entitlement_scope_key,
        valid_from_at: valid_from_at,
        valid_until_at: valid_until_at,
        source_order_line_item_id: source_order_line_item_id,
        contract_change_id: contract_change_id,
        plan_revision_id: plan_revision_id
      }
    end)
  end

  defp access_effect_count!(subscription_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM access_effects WHERE subscription_id = $1", [
        Ecto.UUID.dump!(subscription_id)
      ])

    count
  end

  defp fail_cancel_access_effect_insert! do
    suffix = System.unique_integer([:positive])
    trigger_name = "f05_fail_cancel_effect_#{suffix}"

    Repo.query!("""
      CREATE FUNCTION #{trigger_name}() RETURNS trigger
      LANGUAGE plpgsql
      AS $function$
      BEGIN
        IF NEW.subscription_id::text = current_setting('store.f05_fail_cancel_effect_subscription', true) THEN
          RAISE EXCEPTION 'injected F0.5 cancel AccessEffect insert failure';
        END IF;

        RETURN NEW;
      END;
      $function$;
    """)

    Repo.query!("""
      CREATE TRIGGER #{trigger_name}
      BEFORE INSERT ON access_effects
      FOR EACH ROW EXECUTE FUNCTION #{trigger_name}()
    """)

    {trigger_name, trigger_name}
  end

  defp drop_cancel_access_effect_failure_trigger!(trigger_name, function_name) do
    Repo.query!("DROP TRIGGER IF EXISTS #{trigger_name} ON access_effects")
    Repo.query!("DROP FUNCTION IF EXISTS #{function_name}()")
  end

  defp fixture_subscription(subscription_id) do
    Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(subscription_id) end)
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_renewal_attempt!(attempt_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_attempt!(collection_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^collection_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp update_subscription!(subscription, action, attrs) do
    subscription
    |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp enable_stripe! do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )
  end
end
