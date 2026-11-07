defmodule Store.Subscriptions.Sbh2005SuccessVsLateFailureDunningTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Comms.EmailOutbox
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo

  alias Store.Subscriptions.{
    Facade,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.StartInput

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  @system_context %{system?: true}

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "attempt failure storage errors do not settle dunning" do
    fixture = create_due_fixture!("jc235_attempt_storage_error")
    before_subscription = fetch_subscription!(fixture.subscription.id)
    provider_calls = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add_get(provider_calls, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    {trigger_name, function_name} =
      install_attempt_failure_rejection_trigger!(fixture.subscription.id)

    on_exit(fn -> drop_trigger_and_function!("renewal_attempts", trigger_name, function_name) end)

    handler_id = attach_dunning_counter(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %{code: "INTERNAL_ERROR"}} = fixture.run.()

    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    assert attempt.status == :processing
    assert fetch_subscription!(fixture.subscription.id) == before_subscription
    assert :atomics.get(provider_calls, 1) == 1
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "claim storage errors fail closed before provider collection or dunning" do
    fixture = create_due_fixture!("jc235_claim_storage_error")
    before_subscription = fetch_subscription!(fixture.subscription.id)
    {trigger_name, function_name} = install_claim_rejection_trigger!()

    on_exit(fn -> drop_trigger_and_function!("renewal_attempts", trigger_name, function_name) end)

    StripeAPIStub.stub_unexpected!("claim storage failure must stop before provider mutation")

    handler_id = attach_dunning_counter(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %{code: "INTERNAL_ERROR"}} = fixture.run.()

    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    assert attempt.status == :pending
    assert is_nil(attempt.failure_code)
    assert fetch_subscription!(fixture.subscription.id) == before_subscription
    assert count_collections_for_attempt(attempt.id) == 0
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "retry attempt identity is checked before dispatch and again after provider work",
       context do
    fixture = create_due_fixture!("jc247_retry_identity_race")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    past_due = fetch_subscription!(fixture.subscription.id)
    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    assert past_due.current_dunning_renewal_attempt_id == attempt.id

    other_attempt = create_sibling_attempt!(attempt)

    assert {:error, %{code: "RENEWAL_AUTHORITY_WITHDRAWN"}} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: other_attempt.id,
               subscription_id: fixture.subscription.id,
               now: past_due.next_retry_at
             })

    assert count_collections_for_attempt(other_attempt.id) == 0

    assert {:error, action_error} =
             past_due
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{billing_status_reason: "PAYMENT_FAILED"},
               context: @system_context,
               private_arguments: %{dunning_renewal_attempt_id: other_attempt.id}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: @system_context
             )

    assert inspect(action_error) =~ "current dunning RenewalAttempt identity cannot be replaced"

    assert {:error, missing_identity_error} =
             past_due
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{billing_status_reason: "PAYMENT_FAILED"},
               context: @system_context
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: @system_context
             )

    assert inspect(missing_identity_error) =~
             "current dunning RenewalAttempt identity cannot be replaced"

    assert fetch_subscription!(fixture.subscription.id).current_dunning_renewal_attempt_id ==
             attempt.id

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    parent = self()
    {:ok, barrier} = Agent.start_link(fn -> %{release_dispatch?: false} end)
    handler_id = attach_dispatch_release_barrier(fixture.subscription.id, parent, barrier)

    retry_task =
      Task.async(fn ->
        Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
          now: past_due.next_retry_at
        )
      end)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      release_dispatch_barrier(barrier)

      if Process.alive?(retry_task.pid) do
        Task.shutdown(retry_task, :brutal_kill)
      end
    end)

    assert_receive {:jc247_dispatch_released, ^barrier, _metadata}, 10_000
    :ok = Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], retry_task.pid)

    :ok =
      Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], retry_task.pid)

    Repo.query!(
      "UPDATE subscriptions SET current_dunning_renewal_attempt_id = $2 WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id), Ecto.UUID.dump!(other_attempt.id)]
    )

    Agent.update(barrier, &Map.put(&1, :release_dispatch?, true))
    assert {:error, _reason} = Task.await(retry_task, 10_000)

    unchanged = fetch_subscription!(fixture.subscription.id)
    assert unchanged.status == :past_due
    assert unchanged.current_dunning_renewal_attempt_id == other_attempt.id
    assert unchanged.dunning_attempt_count == 1
    assert fetch_attempt!(attempt.id).status == :processing
  end

  test "dunning write errors roll back the attempt failure" do
    fixture = create_due_fixture!("jc235_dunning_storage_error")
    before_subscription = fetch_subscription!(fixture.subscription.id)
    provider_calls = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add_get(provider_calls, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    {trigger_name, function_name} =
      install_status_rejection_trigger!("subscriptions", fixture.subscription.id, "past_due")

    on_exit(fn -> drop_trigger_and_function!("subscriptions", trigger_name, function_name) end)

    handler_id = attach_dunning_counter(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %{code: "INTERNAL_ERROR"}} = fixture.run.()

    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    assert attempt.status == :processing
    assert fetch_subscription!(fixture.subscription.id) == before_subscription
    assert :atomics.get(provider_calls, 1) == 1
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "ordinary terminal failure query count is measured on collection-attempt identity" do
    fixture = create_due_fixture!("jc235_failure_query_shape")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    {result, stats, protocol_query_count} = capture_dispatch_query_stats(fixture.run)

    IO.puts("JC-235 current collection-identity failure query_count=#{stats.query_count}")
    assert {:error, %{code: "PAYMENT_FAILED"}} = result
    assert stats.query_count > 0
    # The old 122-query allowance includes the renewal workload. Fresh dispatch adds six
    # session-protocol statements and four authority reads: PID, two acquisitions, two
    # current identity reads, confirmation, and two unlocks. The protocol statements are
    # counted below; the four current reads follow current_dispatch_identity/1.
    assert protocol_query_count == 6
    assert stats.query_count <= 122 + 10
    assert fetch_subscription!(fixture.subscription.id).status == :past_due
    assert fetch_attempt_for_subscription!(fixture.subscription.id).status == :failed
  end

  test "requires_action replay does not repeat attempt, dunning, provider, or outbox effects" do
    fixture = create_due_fixture!("jc235_requires_action_replay")
    provider_calls = :atomics.new(1, [])
    params_agent = start_supervised!({Agent, fn -> nil end})

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add_get(provider_calls, 1, 1)
      Agent.update(params_agent, fn _previous -> params end)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{
          "status" => "requires_action",
          "next_action" => %{
            "redirect_to_url" => %{"url" => "https://payments.example.test/authenticate/jc235"}
          }
        })
      )
    end)

    assert {:ok, :processed} = fixture.run.()

    attempt_before = fetch_attempt_for_subscription!(fixture.subscription.id)
    subscription_before = fetch_subscription!(fixture.subscription.id)
    [collection_before] = list_collections!(attempt_before.id)
    email_before = count_authentication_emails(attempt_before.order_id)
    assert attempt_before.status == :processing
    assert subscription_before.status == :past_due
    assert subscription_before.dunning_attempt_count == 1
    assert collection_before.financial_outcome == :requires_action
    assert email_before == 1
    assert :atomics.get(provider_calls, 1) == 1

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"
      params = Agent.get(params_agent, & &1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "requires_action"})
      )
    end)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: DateTime.add(subscription_before.failed_payment_boundary_at, -1, :second)
             )

    replayed_attempt = fetch_attempt!(attempt_before.id)
    replayed_subscription = fetch_subscription!(fixture.subscription.id)
    [replayed_collection] = list_collections!(attempt_before.id)

    assert replayed_attempt.status == attempt_before.status
    assert replayed_attempt.attempt_no == attempt_before.attempt_no

    assert replayed_subscription.dunning_attempt_count ==
             subscription_before.dunning_attempt_count

    assert replayed_subscription.aggregate_version == subscription_before.aggregate_version

    assert replayed_subscription.failed_payment_boundary_at ==
             subscription_before.failed_payment_boundary_at

    assert replayed_collection.id == collection_before.id
    assert replayed_collection.financial_outcome == :requires_action
    assert count_collections_for_attempt(attempt_before.id) == 1
    assert count_authentication_emails(attempt_before.order_id) == email_before
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "a failed requires_action settlement can replay the same collection after recovery" do
    fixture = create_due_fixture!("jc235_requires_action_crash_recovery")
    provider_calls = :atomics.new(1, [])
    params_agent = start_supervised!({Agent, fn -> nil end})
    before_subscription = fetch_subscription!(fixture.subscription.id)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add_get(provider_calls, 1, 1)
      Agent.update(params_agent, fn _previous -> params end)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "requires_action"})
      )
    end)

    {trigger_name, function_name} =
      install_status_rejection_trigger!("subscriptions", fixture.subscription.id, "past_due")

    on_exit(fn -> drop_trigger_and_function!("subscriptions", trigger_name, function_name) end)

    assert {:error, %{code: "INTERNAL_ERROR"}} = fixture.run.()
    assert fetch_subscription!(fixture.subscription.id) == before_subscription

    assert count_authentication_emails(
             fetch_attempt_for_subscription!(fixture.subscription.id).order_id
           ) == 0

    [collection_before] =
      fixture.subscription.id
      |> fetch_attempt_for_subscription!()
      |> then(&list_collections!(&1.id))

    assert collection_before.financial_outcome == :requires_action
    assert :atomics.get(provider_calls, 1) == 1

    drop_trigger_and_function!("subscriptions", trigger_name, function_name)

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"
      params = Agent.get(params_agent, & &1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "requires_action"})
      )
    end)

    assert {:ok, :processed} = fixture.run.()

    attempt_after = fetch_attempt_for_subscription!(fixture.subscription.id)
    subscription_after = fetch_subscription!(fixture.subscription.id)
    [collection_after] = list_collections!(attempt_after.id)

    assert subscription_after.status == :past_due
    assert subscription_after.dunning_attempt_count == 1
    assert attempt_after.status == :processing
    assert collection_after.id == collection_before.id
    assert collection_after.financial_outcome == :requires_action
    assert count_collections_for_attempt(attempt_after.id) == 1
    assert count_authentication_emails(attempt_after.order_id) == 0
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "exact paid success wins after requires_action evidence commits before auth settlement",
       context do
    fixture = create_due_fixture!("jc235_requires_action_paid_success_race")
    assert is_binary(fixture.subscription.stored_payment_method_id)
    parent = self()
    provider_calls = :atomics.new(1, [])
    settlement_barrier = make_ref()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add_get(provider_calls, 1, 1)
      send(parent, {:jc235_auth_provider_returned, params})

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{
          "status" => "requires_action",
          "next_action" => %{
            "redirect_to_url" => %{
              "url" => "https://payments.example.test/authenticate/jc235-race"
            }
          }
        })
      )
    end)

    dunning_handler_id = attach_dunning_counter(self())
    on_exit(fn -> :telemetry.detach(dunning_handler_id) end)

    start_ref = make_ref()

    renewal_task =
      Task.async(fn ->
        receive do
          {:start_renewal, ^start_ref} -> fixture.run.()
        end
      end)

    :ok = Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], renewal_task.pid)

    :ok =
      Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], renewal_task.pid)

    barrier_handler_id =
      attach_requires_action_commit_barrier(
        renewal_task.pid,
        parent,
        settlement_barrier
      )

    on_exit(fn ->
      send(renewal_task.pid, {:release_requires_action_commit, settlement_barrier})
      :telemetry.detach(barrier_handler_id)
      Process.exit(renewal_task.pid, :kill)
    end)

    send(renewal_task.pid, {:start_renewal, start_ref})
    assert_receive {:jc235_auth_provider_returned, params}, 10_000

    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    collection_id = Map.fetch!(params, "metadata[collection_attempt_id]")
    payment_intent_id = Map.fetch!(params, "metadata[local_intent_id]")

    assert_receive {:jc235_requires_action_evidence_committed, ^settlement_barrier}, 10_000

    collection = fetch_collection!(collection_id)
    assert collection.financial_outcome == :requires_action
    assert collection.payment_intent_id == payment_intent_id

    mark_collection_successful!(collection, db_now!())

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection_id)

    assert handoff.renewal_attempt_id == attempt.id
    assert handoff.collection_attempt_id == collection_id
    assert handoff.payment_intent_id == payment_intent_id

    send(renewal_task.pid, {:release_requires_action_commit, settlement_barrier})

    assert {:ok, :processed} = Task.await(renewal_task, 10_000)

    final_attempt = fetch_attempt!(attempt.id)
    final_subscription = fetch_subscription!(fixture.subscription.id)
    final_collection = fetch_collection!(collection_id)

    assert final_attempt.status == :succeeded
    assert final_attempt.attempt_no == attempt.attempt_no
    assert is_nil(final_attempt.failure_code)
    assert final_subscription.status == :active
    assert final_subscription.dunning_attempt_count == 0
    assert is_nil(final_subscription.failed_payment_boundary_at)
    assert final_collection.financial_outcome == :verified_success
    assert final_collection.payment_intent_id == payment_intent_id
    assert count_collections_for_attempt(attempt.id) == 1
    assert count_authentication_emails(attempt.order_id) == 0
    assert :atomics.get(provider_calls, 1) == 1
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "late provider failure after exact paid renewal application cannot reopen dunning",
       context do
    fixture =
      start_blocked_failure_charge!("jc235_late_failure_after_paid", context.sandbox_owners)

    handler_id = attach_dunning_counter(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    payment_intent = fetch_payment_intent!(fixture.payment_intent_id)
    collection = fetch_collection!(fixture.collection_id)

    mark_collection_successful!(collection, db_now!())
    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               fixture.attempt.order_id,
               renewal_attempt_id: fixture.attempt.id,
               collection_attempt_id: handoff.collection_attempt_id,
               payment_intent_id: handoff.payment_intent_id
             )

    paid = fetch_subscription!(fixture.subscription.id)
    assert paid.status == :active
    assert fetch_attempt!(fixture.attempt.id).status == :succeeded
    assert fetch_collection!(collection.id).financial_outcome == :verified_success

    Agent.update(fixture.barrier, &Map.put(&1, :release_dispatch?, true))
    assert {:ok, :processed} = Task.await(fixture.task, 10_000)

    final_attempt = fetch_attempt!(fixture.attempt.id)
    final_subscription = fetch_subscription!(fixture.subscription.id)
    final_collection = fetch_collection!(collection.id)

    assert final_attempt.status == :succeeded
    assert is_nil(final_attempt.failure_code)
    assert final_attempt.payment_intent_id == payment_intent.id
    assert final_subscription.status == :active
    assert final_subscription.aggregate_version == paid.aggregate_version
    assert final_subscription.dunning_attempt_count == 0
    assert is_nil(final_subscription.failed_payment_boundary_at)
    assert final_collection.id == fixture.collection_id
    assert final_collection.payment_intent_id == payment_intent.id
    assert final_collection.financial_outcome == :verified_success
    assert count_collections_for_attempt(fixture.attempt.id) == 1
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "late provider failure after immediate cancellation cannot reopen dunning", context do
    fixture =
      start_blocked_failure_charge!("jc235_late_failure_after_cancel", context.sandbox_owners)

    handler_id = attach_dunning_counter(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, canceled} =
             Facade.cancel_subscription_for_user(
               fixture.customer,
               fixture.subscription.id,
               :now
             )

    assert canceled.status == :canceled
    attempt_after_cancel = fetch_attempt!(fixture.attempt.id)
    [collection_after_cancel] = list_collections!(fixture.attempt.id)

    Agent.update(fixture.barrier, &Map.put(&1, :release_dispatch?, true))
    assert {:ok, :processed} = Task.await(fixture.task, 10_000)

    final_attempt = fetch_attempt!(fixture.attempt.id)
    final_subscription = fetch_subscription!(fixture.subscription.id)
    [final_collection] = list_collections!(fixture.attempt.id)

    assert final_attempt == attempt_after_cancel
    assert final_attempt.failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert final_subscription.status == :canceled
    assert final_subscription.dunning_attempt_count == canceled.dunning_attempt_count
    assert final_subscription.aggregate_version == canceled.aggregate_version
    assert final_collection.id == collection_after_cancel.id
    assert count_collections_for_attempt(fixture.attempt.id) == 1
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  defp create_due_fixture!(label) do
    now = db_now!()
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{label}",
        started_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :microsecond)
      })

    %{
      customer: customer,
      subscription: subscription,
      plan: plan,
      now: now,
      run: fn -> Facade.process_due_subscription_renewal_for_system(subscription.id, now: now) end
    }
  end

  defp create_sibling_attempt!(%RenewalAttempt{} = attempt) do
    attrs =
      attempt
      |> Map.from_struct()
      |> Map.take([
        :subscription_id,
        :period_start_at,
        :period_end_at,
        :plan_revision_id,
        :variant_id,
        :quantity,
        :amount_minor,
        :currency,
        :contract_change_id,
        :expected_subscription_version,
        :charged_contract_version,
        :charged_contract_snapshot
      ])
      |> Map.put(:renewal_key, attempt.renewal_key <> ":jc247:" <> Ecto.UUID.generate())

    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: @system_context)
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp start_blocked_failure_charge!(label, sandbox_owners) do
    fixture = create_due_fixture!(label)
    parent = self()

    {:ok, barrier} =
      Agent.start_link(fn -> %{release_dispatch?: false, params: nil} end)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      Agent.update(barrier, fn state -> %{state | params: params} end)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    handler_id = attach_failure_dispatch_barrier(fixture.subscription.id, parent, barrier)
    task = Task.async(fixture.run)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      release_dispatch_barrier(barrier)

      if Process.alive?(task.pid) do
        Task.shutdown(task, :brutal_kill)
      end
    end)

    assert_receive {:jc235_dispatch_released, ^barrier, params}, 10_000
    :ok = Sandbox.allow(Store.Repo, sandbox_owners[Store.Repo], task.pid)
    :ok = Sandbox.allow(Store.DirectRepo, sandbox_owners[Store.DirectRepo], task.pid)

    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    collection_id = Map.fetch!(params, "metadata[collection_attempt_id]")
    payment_intent_id = Map.fetch!(params, "metadata[local_intent_id]")

    Map.merge(fixture, %{
      task: task,
      barrier: barrier,
      attempt: attempt,
      collection_id: collection_id,
      payment_intent_id: payment_intent_id
    })
  end

  defp attach_dispatch_release_barrier(subscription_id, parent, barrier) do
    handler_id = {__MODULE__, :retry_dispatch_release, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_released],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id do
            send(config.parent, {:jc247_dispatch_released, config.barrier, metadata})
            wait_for_dispatch_release!(config.barrier)
          end
        end,
        %{parent: parent, subscription_id: subscription_id, barrier: barrier}
      )

    handler_id
  end

  defp attach_failure_dispatch_barrier(subscription_id, parent, barrier) do
    handler_id = {__MODULE__, :failure_dispatch_release, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_released],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id do
            params = Agent.get(config.barrier, & &1.params)
            send(config.parent, {:jc235_dispatch_released, config.barrier, params})
            wait_for_dispatch_release!(config.barrier)
          end
        end,
        %{parent: parent, subscription_id: subscription_id, barrier: barrier}
      )

    handler_id
  end

  defp wait_for_dispatch_release!(barrier) do
    wait_until(fn -> Agent.get(barrier, & &1.release_dispatch?) end, 2_000)

    unless Agent.get(barrier, & &1.release_dispatch?) do
      raise "renewal dispatch release barrier timed out"
    end
  end

  defp release_dispatch_barrier(barrier) do
    if Process.alive?(barrier) do
      Agent.update(barrier, &Map.put(&1, :release_dispatch?, true))
    end
  end

  defp capture_dispatch_query_stats(fun) do
    counter_key = {__MODULE__, :dispatch_protocol_query_count, make_ref()}
    handler_id = {__MODULE__, :dispatch_protocol_queries, make_ref()}
    Process.put(counter_key, 0)

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, config ->
          count_dispatch_protocol_query(metadata, config)
        end,
        %{owner: self(), counter_key: counter_key}
      )

    try do
      {result, stats} = RepoStats.capture(fun)
      {result, stats, Process.get(counter_key, 0)}
    after
      :telemetry.detach(handler_id)
      Process.delete(counter_key)
    end
  end

  defp count_dispatch_protocol_query(metadata, config) do
    if self() == config.owner do
      query = String.downcase(metadata.query || "")

      if String.contains?(query, "pg_backend_pid") or
           String.contains?(query, "pg_try_advisory_lock") or
           String.contains?(query, "pg_advisory_unlock") do
        Process.put(config.counter_key, Process.get(config.counter_key, 0) + 1)
      end
    end
  end

  defp mark_collection_successful!(collection, observed_at) do
    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    {provider_reference, provider_reference_kind} =
      if is_binary(payment_intent.provider_payment_id) do
        {payment_intent.provider_payment_id, :payment_intent}
      else
        {payment_intent.provider_request_reference, :transaction_reference}
      end

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
      observed_at: observed_at
    }

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert outcome in [:authoritative_success, :already_applied_success]
  end

  defp attach_dunning_counter(owner) do
    handler_id = "jc235_dunning_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, metadata, target ->
          send(target, {:jc235_dunning, metadata})
        end,
        owner
      )

    handler_id
  end

  defp attach_requires_action_commit_barrier(target_pid, owner, barrier) do
    handler_id = {__MODULE__, :requires_action_collection_commit, make_ref()}
    pending_key = {__MODULE__, :requires_action_collection_commit, barrier}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, config ->
          maybe_block_after_requires_action_evidence(metadata, config)
        end,
        %{target_pid: target_pid, owner: owner, barrier: barrier, pending_key: pending_key}
      )

    handler_id
  end

  defp maybe_block_after_requires_action_evidence(metadata, config) do
    query = String.downcase(String.trim(metadata.query || ""))

    cond do
      self() != config.target_pid ->
        :ok

      requires_action_collection_update?(query, metadata) ->
        Process.put(config.pending_key, true)

      transaction_end_query?(query) and Process.get(config.pending_key) ->
        Process.delete(config.pending_key)
        wait_for_requires_action_release(config)

      true ->
        :ok
    end
  end

  defp requires_action_collection_update?(query, metadata) do
    String.starts_with?(query, "update") and
      String.contains?(query, "renewal_collection_attempts") and
      String.contains?(query, "financial_outcome") and
      String.contains?(inspect(Map.get(metadata, :params, [])), "requires_action")
  end

  defp transaction_end_query?(query) do
    query == "commit" or String.starts_with?(query, "release savepoint")
  end

  defp wait_for_requires_action_release(config) do
    send(config.owner, {:jc235_requires_action_evidence_committed, config.barrier})

    receive do
      {:release_requires_action_commit, barrier} when barrier == config.barrier -> :ok
    after
      10_000 -> send(config.owner, {:jc235_requires_action_commit_timeout, config.barrier})
    end
  end

  defp install_attempt_failure_rejection_trigger!(subscription_id) do
    suffix = System.unique_integer([:positive])
    trigger_name = "jc235_reject_attempt_failure_#{suffix}"
    function_name = "jc235_reject_attempt_failure_fn_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.subscription_id::text = '#{subscription_id}' AND NEW.status = 'failed' THEN
        RAISE EXCEPTION 'injected JC-235 RenewalAttempt failure write error';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE OF status ON renewal_attempts
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp install_claim_rejection_trigger! do
    suffix = System.unique_integer([:positive])
    trigger_name = "jc235_reject_attempt_claim_#{suffix}"
    function_name = "jc235_reject_attempt_claim_fn_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF OLD.status = NEW.status AND NEW.status IN ('pending', 'failed') THEN
        RAISE EXCEPTION 'injected JC-235 RenewalAttempt claim storage error';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE OF updated_at ON renewal_attempts
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp install_status_rejection_trigger!(table, record_id, status) do
    suffix = System.unique_integer([:positive])
    trigger_name = "jc235_reject_#{table}_#{suffix}"
    function_name = "jc235_reject_#{table}_fn_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.id::text = '#{record_id}' AND NEW.status::text = '#{status}' THEN
        RAISE EXCEPTION 'injected JC-235 #{table} write failure';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE OF status ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp drop_trigger_and_function!(table, trigger_name, function_name) do
    Repo.query("DROP TRIGGER IF EXISTS #{trigger_name} ON #{table}")
    Repo.query("DROP FUNCTION IF EXISTS #{function_name}()")
    :ok
  end

  defp count_collections_for_attempt(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp list_collections!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.Query.sort(collection_ordinal: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp count_authentication_emails(order_id) do
    EmailOutbox
    |> Ash.Query.filter(
      expr(order_id == ^order_id and template_kind == :payment_authentication_required)
    )
    |> Ash.count!(domain: Store.Comms, authorize?: false, context: @system_context)
  end

  defp fetch_subscription!(id), do: read_one!(Subscription, id, Store.Subscriptions)
  defp fetch_attempt!(id), do: read_one!(RenewalAttempt, id, Store.Subscriptions)
  defp fetch_payment_intent!(id), do: read_one!(PaymentIntent, id, Store.Payments)
  defp fetch_collection!(id), do: read_one!(RenewalCollectionAttempt, id, Store.Subscriptions)

  defp fetch_attempt_for_subscription!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp read_one!(resource, id, domain) do
    resource
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: domain, authorize?: false, context: @system_context)
  end

  defp db_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp unique_label(label), do: "#{label}_#{System.unique_integer([:positive])}"

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      if attempts <= 0 do
        flunk("timed out waiting for provider release")
      else
        Process.sleep(5)
        wait_until(predicate, attempts - 1)
      end
    end
  end
end
