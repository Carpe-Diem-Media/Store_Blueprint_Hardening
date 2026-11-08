defmodule Store.Subscriptions.Sbh2003RenewalVsContractChangeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias Store.Subscriptions.{
    ContractChange,
    Facade,
    PlanRevision,
    RenewalAttempt,
    Scheduler,
    Subscription
  }

  alias Store.Subscriptions.Inputs.{
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a plan change queued after B takes effect at the bound renewal end" do
    fixture = fixture!("unchanged_plan")
    attempt = bind_renewal!(fixture)

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, queued} =
             queue_plan_change(fixture.customer, attempt.subscription_id, target_plan)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)

    assert contract_change.status == :queued
    assert contract_change.target_plan_revision_id == revision.id
    assert contract_change.target_variant_id == fixture.variant.id
    assert contract_change.target_amount_minor == revision.amount_minor
    assert contract_change.target_currency == revision.currency
    assert queued.change_effective_at == attempt.period_end_at
  end

  test "a committed queue target is the exact contract bound by checkpoint B" do
    fixture_suffix = "queue_before_b_#{Ecto.UUID.generate()}"

    fixture =
      Sandbox.unboxed_run(Store.Repo, fn -> fixture!(fixture_suffix) end)

    queued_variant =
      Sandbox.unboxed_run(Store.Repo, fn ->
        %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
        SubscriptionsFixtures.attach_variant_plan!(variant.id, fixture.plan.id)
        variant
      end)

    on_exit(fn -> cleanup_stale_retry_fixture!(fixture, queued_variant, fixture.plan) end)

    barrier = make_ref()

    queue_task =
      Task.async(fn ->
        receive do
          {:queue_first, ^barrier} -> :ok
        end

        Sandbox.unboxed_run(Store.Repo, fn ->
          queue_variant_change(fixture.customer, fixture.subscription.id, queued_variant)
        end)
      end)

    send(queue_task.pid, {:queue_first, barrier})
    assert {:ok, queued} = Task.await(queue_task, 10_000)
    queued_change = fetch_contract_change!(queued.current_contract_change_id)

    assert {:ok, :processed} =
             Sandbox.unboxed_run(Store.Repo, fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: fixture.now
               )
             end)

    {attempt, bound_change} =
      Sandbox.unboxed_run(Store.Repo, fn ->
        attempt = fetch_latest_attempt!(fixture.subscription.id)
        {attempt, fetch_contract_change!(attempt.contract_change_id)}
      end)

    assert bound_change.id == queued_change.id
    assert bound_change.status == :bound_to_renewal
    assert attempt.contract_change_id == queued_change.id
    assert attempt.variant_id == queued_change.target_variant_id
    assert attempt.quantity == queued_change.target_quantity
    assert attempt.plan_revision_id == queued_change.target_plan_revision_id
    assert attempt.amount_minor == queued_change.target_amount_minor
    assert attempt.currency == queued_change.target_currency
  end

  test "retrying occurrence N cannot bind its queued N+1 target" do
    fixture = fixture!("retry_occurrence_with_n_plus_one")

    bound_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_900})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, bound_plan.id)
    bound_revision = SubscriptionsFixtures.create_plan_revision!(bound_plan)

    assert {:ok, queued_bound} =
             queue_plan_change(fixture.customer, fixture.subscription.id, bound_plan)

    attempt = bind_renewal!(%{fixture | subscription: queued_bound})
    bound_change = fetch_contract_change!(attempt.contract_change_id)
    assert attempt.plan_revision_id == bound_revision.id

    future_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_900})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, future_plan.id)
    future_revision = SubscriptionsFixtures.create_plan_revision!(future_plan)

    assert {:ok, queued_future} =
             queue_plan_change(fixture.customer, fixture.subscription.id, future_plan)

    future_change = fetch_contract_change!(queued_future.current_contract_change_id)
    assert future_change.status == :queued
    assert future_change.predecessor_contract_change_id == bound_change.id
    assert future_change.target_plan_revision_id == future_revision.id
    assert future_change.target_variant_id == attempt.variant_id
    assert future_change.target_quantity == attempt.quantity
    assert future_change.target_amount_minor == future_revision.amount_minor
    assert future_change.target_currency == future_revision.currency
    assert future_change.effective_at == attempt.period_end_at

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    retried_attempt = fetch_latest_attempt!(fixture.subscription.id)
    subscription = fetch_subscription!(fixture.subscription.id)

    assert retried_attempt.id == attempt.id
    assert retried_attempt.contract_change_id == bound_change.id
    assert fetch_contract_change!(bound_change.id).status == :bound_to_renewal
    assert subscription.current_contract_change_id == future_change.id
    assert fetch_contract_change!(future_change.id) == future_change

    contract_changes =
      ContractChange
      |> Ash.Query.filter(expr(subscription_id == ^fixture.subscription.id))
      |> Ash.Query.sort(ordering_version: :asc)
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert Enum.map(contract_changes, & &1.id) == [bound_change.id, future_change.id]
  end

  test "same queue command rebuilds the B-aware target after PostgreSQL rolls back its insert" do
    fixture = fixture!("rollback_rebuild")

    bound_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_900})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, bound_plan.id)
    SubscriptionsFixtures.create_plan_revision!(bound_plan)

    assert {:ok, queued_bound} =
             queue_plan_change(fixture.customer, fixture.subscription.id, bound_plan)

    attempt = bind_renewal!(%{fixture | subscription: queued_bound})
    bound_change = fetch_contract_change!(attempt.contract_change_id)
    assert bound_change.status == :bound_to_renewal

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_900})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => fixture.subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    subscription_before = fetch_subscription!(fixture.subscription.id)
    trigger_suffix = System.unique_integer([:positive])
    trigger_name = "jc233_reject_contract_change_#{trigger_suffix}"
    function_name = "jc233_reject_contract_change_fn_#{trigger_suffix}"

    Store.Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.subscription_id::text = current_setting('store.jc233_fail_contract_change_subscription_id', true) THEN
        RAISE EXCEPTION 'injected JC-233 contract change insert failure';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Store.Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON contract_changes
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    assert {:ok, %{rows: [[configured_subscription_id]]}} =
             Store.Repo.query(
               "SELECT set_config('store.jc233_fail_contract_change_subscription_id', $1, true)",
               [fixture.subscription.id]
             )

    assert configured_subscription_id == fixture.subscription.id

    assert {:error, %{code: "INTERNAL_ERROR"}} =
             Facade.queue_subscription_plan_change_for_user(
               fixture.customer,
               fixture.subscription.id,
               input
             )

    after_rollback = fetch_subscription!(fixture.subscription.id)
    assert after_rollback == subscription_before
    assert fetch_contract_change!(bound_change.id) == bound_change

    attempt_after_rollback = fetch_latest_attempt!(fixture.subscription.id)
    assert attempt_after_rollback.id == attempt.id
    assert attempt_after_rollback.contract_change_id == bound_change.id
    assert attempt_after_rollback.variant_id == attempt.variant_id
    assert attempt_after_rollback.quantity == attempt.quantity
    assert attempt_after_rollback.period_end_at == attempt.period_end_at

    target_revision_after_rollback = fetch_plan_revision!(target_revision.id)

    contract_changes_after_rollback = list_contract_changes!(fixture.subscription.id)
    assert Enum.map(contract_changes_after_rollback, & &1.id) == [bound_change.id]

    Store.Repo.query!(
      "SELECT set_config('store.jc233_fail_contract_change_subscription_id', '', true)"
    )

    assert {:ok, retried_subscription} =
             Facade.queue_subscription_plan_change_for_user(
               fixture.customer,
               fixture.subscription.id,
               input
             )

    rebuilt_change = fetch_contract_change!(retried_subscription.current_contract_change_id)

    assert rebuilt_change.status == :queued
    assert rebuilt_change.predecessor_contract_change_id == bound_change.id
    assert rebuilt_change.target_plan_revision_id == target_revision_after_rollback.id
    assert rebuilt_change.target_variant_id == attempt_after_rollback.variant_id
    assert rebuilt_change.target_quantity == attempt_after_rollback.quantity
    assert rebuilt_change.target_amount_minor == target_revision_after_rollback.amount_minor
    assert rebuilt_change.target_currency == target_revision_after_rollback.currency
    assert rebuilt_change.effective_at == attempt_after_rollback.period_end_at
    assert fetch_contract_change!(bound_change.id).status == :bound_to_renewal

    assert Enum.map(list_contract_changes!(fixture.subscription.id), & &1.id) ==
             [bound_change.id, rebuilt_change.id]
  end

  test "records query counts for queue composition and supersession profiles" do
    ordinary_plan = fixture!("perf_ordinary_plan")
    ordinary_target_plan = create_target_plan!(ordinary_plan.variant)

    record_query_count!("ordinary_plan_queue", fn ->
      queue_plan_change(
        ordinary_plan.customer,
        ordinary_plan.subscription.id,
        ordinary_target_plan
      )
    end)

    ordinary_variant = fixture!("perf_ordinary_variant")
    ordinary_target_variant = create_variant_for_plan!(ordinary_variant.plan)

    record_query_count!("ordinary_variant_queue", fn ->
      queue_variant_change(
        ordinary_variant.customer,
        ordinary_variant.subscription.id,
        ordinary_target_variant
      )
    end)

    post_b_plan = fixture!("perf_post_b_plan")
    bind_renewal!(post_b_plan)
    post_b_target_plan = create_target_plan!(post_b_plan.variant)

    record_query_count!("post_b_plan_queue", fn ->
      queue_plan_change(post_b_plan.customer, post_b_plan.subscription.id, post_b_target_plan)
    end)

    post_b_variant = fixture!("perf_post_b_variant")
    bind_renewal!(post_b_variant)
    post_b_target_variant = create_variant_for_plan!(post_b_variant.plan)

    record_query_count!("post_b_variant_queue", fn ->
      queue_variant_change(
        post_b_variant.customer,
        post_b_variant.subscription.id,
        post_b_target_variant
      )
    end)

    supersession = fixture!("perf_supersession")
    first_target_plan = create_target_plan!(supersession.variant)
    second_target_plan = create_target_plan!(supersession.variant)

    assert {:ok, _first_queued} =
             queue_plan_change(
               supersession.customer,
               supersession.subscription.id,
               first_target_plan
             )

    record_query_count!("supersession", fn ->
      queue_plan_change(
        supersession.customer,
        supersession.subscription.id,
        second_target_plan
      )
    end)
  end

  test "a stale queue command retries its typed intent against renewal checkpoint B" do
    fixture_suffix = "stale_retry_#{Ecto.UUID.generate()}"

    fixture =
      Sandbox.unboxed_run(Store.Repo, fn -> fixture!(fixture_suffix) end)

    %{variant: queued_variant, target_plan: target_plan, target_revision: target_revision} =
      Sandbox.unboxed_run(Store.Repo, fn ->
        %{variant: queued_variant} = SubscriptionsFixtures.create_subscription_sellable!()
        SubscriptionsFixtures.attach_variant_plan!(queued_variant.id, fixture.plan.id)
        target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_100})
        SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
        SubscriptionsFixtures.attach_variant_plan!(queued_variant.id, target_plan.id)
        target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
        %{variant: queued_variant, target_plan: target_plan, target_revision: target_revision}
      end)

    on_exit(fn -> cleanup_stale_retry_fixture!(fixture, queued_variant, target_plan) end)

    assert {:ok, pre_b_queue} =
             Sandbox.unboxed_run(Store.Repo, fn ->
               queue_variant_change(fixture.customer, fixture.subscription.id, queued_variant)
             end)

    parent = self()
    barrier = make_ref()
    once = :atomics.new(1, [])
    handler_id = {__MODULE__, :stale_contract_queue, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :contract_change, :before_persist],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id and
               metadata.intent_kind == :plan_change and
               :atomics.exchange(config.once, 1, 1) == 0 do
            send(config.owner, {:queue_before_persist, config.barrier})

            receive do
              {:release_queue, ^barrier} -> :ok
            end
          end
        end,
        %{owner: parent, barrier: barrier, once: once, subscription_id: fixture.subscription.id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    queue_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Store.Repo, fn ->
          queue_plan_change(fixture.customer, fixture.subscription.id, target_plan)
        end)
      end)

    assert_receive {:queue_before_persist, ^barrier}, 10_000

    assert {:ok, :processed} =
             Sandbox.unboxed_run(Store.Repo, fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: fixture.now
               )
             end)

    attempt =
      Sandbox.unboxed_run(Store.Repo, fn ->
        fetch_latest_attempt!(fixture.subscription.id)
      end)

    send(queue_task.pid, {:release_queue, barrier})
    assert {:ok, queued} = Task.await(queue_task, 10_000)

    {bound_contract, queued_contract} =
      Sandbox.unboxed_run(Store.Repo, fn ->
        {fetch_contract_change!(pre_b_queue.current_contract_change_id),
         fetch_contract_change!(queued.current_contract_change_id)}
      end)

    assert bound_contract.status == :bound_to_renewal
    assert attempt.contract_change_id == bound_contract.id
    assert queued_contract.predecessor_contract_change_id == bound_contract.id
    assert queued_contract.target_variant_id == attempt.variant_id
    assert queued_contract.target_quantity == attempt.quantity
    assert queued_contract.target_plan_revision_id == target_revision.id
    assert queued_contract.effective_at == attempt.period_end_at
    assert queued_contract.ordering_version > bound_contract.ordering_version
  end

  test "a queue command returns STALE_RECORD after its bounded stale retries" do
    fixture_suffix = "retry_limit_#{Ecto.UUID.generate()}"

    fixture =
      Sandbox.unboxed_run(Store.Repo, fn -> fixture!(fixture_suffix) end)

    target_plan =
      Sandbox.unboxed_run(Store.Repo, fn ->
        plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_200})
        SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, plan.id)
        SubscriptionsFixtures.create_plan_revision!(plan)
        plan
      end)

    on_exit(fn -> cleanup_stale_retry_fixture!(fixture, fixture.variant, target_plan) end)

    parent = self()
    barrier = make_ref()
    attempts = :atomics.new(1, [])
    handler_id = {__MODULE__, :stale_contract_retry_limit, System.unique_integer([:positive])}

    queue_task =
      Task.async(fn ->
        receive do
          {:start_queue, ^barrier} -> :ok
        end

        Sandbox.unboxed_run(Store.Repo, fn ->
          queue_plan_change(fixture.customer, fixture.subscription.id, target_plan)
        end)
      end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :contract_change, :before_persist],
        fn _event, _measurements, metadata, config ->
          if self() == config.task_pid and
               metadata.subscription_id == config.subscription_id and
               metadata.intent_kind == :plan_change do
            attempt = :atomics.add_get(config.attempts, 1, 1)

            if attempt <= 3 do
              send(config.owner, {:queue_persist_attempt, config.barrier, attempt})

              receive do
                {:release_queue_attempt, ^barrier, ^attempt} -> :ok
              end
            end
          end
        end,
        %{
          owner: parent,
          barrier: barrier,
          attempts: attempts,
          subscription_id: fixture.subscription.id,
          task_pid: queue_task.pid
        }
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(queue_task.pid, {:start_queue, barrier})

    for attempt_number <- 1..3 do
      assert_receive {:queue_persist_attempt, ^barrier, ^attempt_number}, 10_000

      Sandbox.unboxed_run(Store.Repo, fn ->
        subscription =
          Subscription
          |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
          |> Ash.read_one!(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true}
          )

        subscription
        |> Ash.Changeset.for_update(
          :set_provider_billing_reference,
          %{
            provider_customer_ref: "cus_retry_limit_#{attempt_number}",
            provider_billing_ref: "pm_retry_limit_#{attempt_number}"
          },
          context: %{system?: true}
        )
        |> Ash.update!(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )
      end)

      send(queue_task.pid, {:release_queue_attempt, barrier, attempt_number})
    end

    assert {:error, %{code: "STALE_RECORD"}} = Task.await(queue_task, 10_000)
    assert :atomics.get(attempts, 1) == 3

    assert Sandbox.unboxed_run(Store.Repo, fn ->
             ContractChange
             |> Ash.Query.filter(expr(subscription_id == ^fixture.subscription.id))
             |> Ash.read!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
           end) == []
  end

  test "a legacy subscription without period end queues at next renewal" do
    fixture = fixture!("legacy_period_end")
    effective_at = DateTime.add(fixture.now, 86_400, :second)

    subscription =
      fixture.subscription
      |> Ash.Changeset.for_update(
        :extend_period,
        %{current_period_end_at: nil, next_renewal_at: effective_at},
        context: %{system?: true}
      )
      |> Ash.update!(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert %Subscription{} = subscription
    assert {:ok, queued} = queue_plan_change(fixture.customer, subscription.id, target_plan)
    assert queued.change_effective_at == effective_at
  end

  test "ambiguous current renewal attempts fail closed without creating a target" do
    fixture = fixture!("ambiguous_attempts")
    {period_start_at, period_end_at} = current_renewal_period(fixture)

    create_attempt!(fixture.subscription, period_start_at, period_end_at, "first")
    create_attempt!(fixture.subscription, period_start_at, period_end_at, "second")

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             queue_plan_change(fixture.customer, fixture.subscription.id, target_plan)

    assert_no_contract_change!(fixture.subscription.id)
  end

  test "an incomplete current renewal attempt fails closed without creating a target" do
    fixture = fixture!("incomplete_attempt")
    {period_start_at, period_end_at} = current_renewal_period(fixture)

    create_attempt!(fixture.subscription, period_start_at, period_end_at, "incomplete")

    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             queue_plan_change(fixture.customer, fixture.subscription.id, target_plan)

    assert_no_contract_change!(fixture.subscription.id)
  end

  test "a plan change after B composes from the contract bound to the renewal" do
    fixture = fixture!("bound_plan")
    %{variant: bound_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    SubscriptionsFixtures.attach_variant_plan!(bound_variant.id, fixture.plan.id)

    assert {:ok, queued_variant} =
             queue_variant_change(fixture.customer, fixture.subscription.id, bound_variant)

    attempt = bind_renewal!(%{fixture | subscription: queued_variant})
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_300})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(bound_variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert attempt.variant_id == bound_variant.id
    assert attempt.quantity == 3

    assert {:ok, queued} =
             queue_plan_change(fixture.customer, attempt.subscription_id, target_plan)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)
    bound_contract_change = fetch_contract_change!(attempt.contract_change_id)

    assert contract_change.predecessor_contract_change_id == attempt.contract_change_id
    assert bound_contract_change.status == :bound_to_renewal
    assert contract_change.target_plan_revision_id == target_revision.id
    assert contract_change.target_variant_id == attempt.variant_id
    assert contract_change.target_quantity == attempt.quantity
    assert contract_change.target_amount_minor == target_revision.amount_minor
    assert queued.change_effective_at == attempt.period_end_at
  end

  test "a variant change after B preserves the plan bound to the renewal" do
    fixture = fixture!("bound_variant")
    bound_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, bound_plan.id)
    bound_revision = SubscriptionsFixtures.create_plan_revision!(bound_plan)

    assert {:ok, queued_bound} =
             queue_plan_change(fixture.customer, fixture.subscription.id, bound_plan)

    attempt = bind_renewal!(%{fixture | subscription: queued_bound})
    %{variant: target_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    SubscriptionsFixtures.attach_variant_plan!(target_variant.id, fixture.plan.id)
    SubscriptionsFixtures.attach_variant_plan!(target_variant.id, bound_plan.id)

    assert attempt.plan_revision_id == bound_revision.id

    assert {:ok, queued} =
             queue_variant_change(fixture.customer, attempt.subscription_id, target_variant)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)
    bound_contract_change = fetch_contract_change!(attempt.contract_change_id)

    assert contract_change.predecessor_contract_change_id == attempt.contract_change_id
    assert bound_contract_change.status == :bound_to_renewal
    assert contract_change.target_plan_revision_id == attempt.plan_revision_id
    assert contract_change.target_variant_id == target_variant.id
    assert contract_change.target_amount_minor == attempt.amount_minor
    assert contract_change.target_currency == attempt.currency
    assert queued.change_effective_at == attempt.period_end_at
  end

  defp fixture!(suffix) do
    customer = SubscriptionsFixtures.create_customer!("sbh_20_03_#{suffix}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{interval_unit: :day})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    due_boundary = DateTime.add(now, -10, :second)
    started_at = DateTime.add(due_boundary, -86_400, :second)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: started_at,
        quantity: 3,
        provider_billing_ref: "pm_sbh_20_03_#{suffix}"
      })

    %{
      customer: customer,
      variant: variant,
      plan: plan,
      revision: revision,
      subscription: subscription,
      now: now
    }
  end

  defp current_renewal_period(%{subscription: subscription, revision: revision}) do
    {:ok, period} = Scheduler.next_period(subscription.current_period_end_at, revision)
    period_end_at = period.current_period_end_at

    {subscription.current_period_end_at, period_end_at}
  end

  defp create_attempt!(subscription, period_start_at, period_end_at, suffix) do
    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: subscription.id,
        period_start_at: period_start_at,
        period_end_at: period_end_at,
        renewal_key: "sbh_20_03:#{subscription.id}:#{suffix}",
        status: :pending
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp assert_no_contract_change!(subscription_id) do
    query = ContractChange |> Ash.Query.filter(expr(subscription_id == ^subscription_id))

    assert {:ok, []} =
             Ash.read(query,
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  defp bind_renewal!(fixture) do
    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    fetch_latest_attempt!(fixture.subscription.id)
  end

  defp queue_plan_change(actor, subscription_id, plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription_id,
        "subscription_plan_id" => plan.id
      })

    Facade.queue_subscription_plan_change_for_user(actor, subscription_id, input)
  end

  defp queue_variant_change(actor, subscription_id, variant) do
    {:ok, input} =
      QueueSubscriptionVariantChangeInput.new(%{
        "subscription_id" => subscription_id,
        "variant_id" => variant.id
      })

    Facade.queue_subscription_variant_change_for_user(actor, subscription_id, input)
  end

  defp record_query_count!(label, operation) do
    {result, stats} = RepoStats.capture(operation)
    IO.puts("JC-233 #{label} query_count=#{stats.query_count}")
    assert {:ok, %Subscription{}} = result
    assert stats.query_count > 0
    stats.query_count
  end

  defp create_target_plan!(variant) do
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_100})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    SubscriptionsFixtures.create_plan_revision!(plan)
    plan
  end

  defp create_variant_for_plan!(plan) do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    variant
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_plan_revision!(id) do
    PlanRevision
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_contract_changes!(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(ordering_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp cleanup_stale_retry_fixture!(fixture, queued_variant, target_plan) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      user_id = Ecto.UUID.dump!(fixture.customer.id)
      product_ids = [fixture.variant.product_id, queued_variant.product_id]
      variant_ids = [fixture.variant.id, queued_variant.id]
      plan_ids = [fixture.plan.id, target_plan.id]

      Store.Repo.query!(
        "UPDATE subscriptions SET current_contract_change_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Store.Repo.query!(
        """
        DELETE FROM oban_jobs
        WHERE args->>'subscription_id' = $1
          OR args->>'order_id' IN (SELECT id::text FROM orders WHERE user_id = $2)
        """,
        [fixture.subscription.id, user_id]
      )

      Store.Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 OR order_id IN (SELECT id FROM orders WHERE user_id = $2)",
        [subscription_id, user_id]
      )

      Store.Repo.query!(
        "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Store.Repo.query!(
        "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Store.Repo.query!(
        "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Store.Repo.query!(
        "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Store.Repo.transaction(fn ->
        Store.Repo.query!(
          "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
        )

        Store.Repo.query!(
          "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
          [subscription_id]
        )

        Store.Repo.query!(
          "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
        )
      end)

      Store.Repo.query!(
        "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Store.Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Store.Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

      Store.Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [subscription_id]
      )

      Store.Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

      Store.Repo.query!(
        "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Store.Repo.query!(
        "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Store.Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
      Store.Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])

      Store.Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = ANY($1)", [
        Enum.map(plan_ids, &Ecto.UUID.dump!/1)
      ])

      Store.Repo.query!(
        "DELETE FROM variant_subscription_plans WHERE variant_id = ANY($1)",
        [Enum.map(variant_ids, &Ecto.UUID.dump!/1)]
      )

      Store.Repo.query!("DELETE FROM subscription_plans WHERE id = ANY($1)", [
        Enum.map(plan_ids, &Ecto.UUID.dump!/1)
      ])

      Store.Repo.transaction(fn ->
        Store.Repo.query!("DELETE FROM products WHERE id = ANY($1)", [
          Enum.map(product_ids, &Ecto.UUID.dump!/1)
        ])

        Store.Repo.query!("DELETE FROM variants WHERE id = ANY($1)", [
          Enum.map(variant_ids, &Ecto.UUID.dump!/1)
        ])
      end)

      Store.Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end
end
