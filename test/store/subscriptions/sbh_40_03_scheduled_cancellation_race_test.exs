defmodule Store.Subscriptions.Sbh4003ScheduledCancellationRaceTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Catalog.Variant
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.PaymentIntent
  alias Store.Repo

  alias Store.Subscriptions.{
    AccessEffect,
    ContractChange,
    Facade,
    RenewalAttempt,
    RenewalCollectionAttempt,
    Subscription,
    SubscriptionPlan
  }

  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "a scheduled cancellation commits after renewal selection and before B" do
    # INVARIANT=DO_NOT_RENEW commits before B; the same worker intent replays to a no-op.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=bind before locked reload or break worker re-evaluation.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_pre_b",
        started_at: DateTime.add(now, -20 * 86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)

    assert DateTime.compare(fixture.subscription.current_period_end_at, now) == :gt

    assert {:ok, [due_job]} =
             unboxed(fn ->
               Facade.list_due_renewal_jobs_for_system(now: now, limit: 10)
             end)

    assert due_job.subscription_id == fixture.subscription_id

    renewal_job_args = %{
      "subscription_id" => due_job.subscription_id,
      "renewal_key" => due_job.renewal_key
    }

    {target_plan, target_revision} =
      create_future_plan!(fixture, "jc243_pre_b_target", 2_900)

    assert {:ok, queued} = queue_plan_change!(fixture, target_plan)
    queued_change = fetch_contract_change!(queued.current_contract_change_id)

    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    owner = self()
    barrier = :pre_b_subscription_read
    handler_id = telemetry_handler_id("pre-b")

    task =
      Task.async(fn ->
        send(owner, {:renewal_ready, self()})

        receive do
          :start_renewal ->
            unboxed(fn ->
              ProcessSubscriptionRenewalWorker.perform(%Oban.Job{args: renewal_job_args})
            end)
        after
          5_000 -> {:error, :renewal_start_barrier_timeout}
        end
      end)

    assert_receive {:renewal_ready, task_pid}, 5_000

    attach_repo_query_barrier!(handler_id, task_pid, owner, barrier, &subscription_read_query?/1)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(task_pid, :start_renewal)
    assert_receive {:repo_query_barrier, ^barrier, ^task_pid, query}, 5_000
    assert subscription_read_query?(query)

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    assert scheduled.cancel_at_period_end_at == fixture.subscription.current_period_end_at
    assert is_nil(scheduled.cancel_after_renewal_attempt_id)
    assert is_nil(scheduled.current_contract_change_id)
    assert Map.get(fetch_contract_change!(queued_change.id), :status) == :canceled

    send(task_pid, {:release_repo_query_barrier, barrier})
    renewal_result = Task.await(task, 10_000)
    :ok = :telemetry.detach(handler_id)

    assert {:error, %{code: "STALE_RECORD"}} = renewal_result
    assert [] == renewal_attempts(fixture.subscription_id)
    assert count_collections(fixture.subscription_id) == 0
    assert :atomics.get(post_count, 1) == 0

    current_before_retry = fetch_subscription!(fixture.subscription_id)

    assert current_before_retry.cancel_at_period_end_at ==
             fixture.subscription.current_period_end_at

    assert is_nil(current_before_retry.cancel_after_renewal_attempt_id)

    retry_result =
      unboxed(fn ->
        ProcessSubscriptionRenewalWorker.perform(%Oban.Job{args: renewal_job_args})
      end)

    assert :ok = retry_result
    assert [] == renewal_attempts(fixture.subscription_id)
    assert count_collections(fixture.subscription_id) == 0
    assert :atomics.get(post_count, 1) == 0

    current = fetch_subscription!(fixture.subscription_id)
    assert current.cancel_at_period_end_at == fixture.subscription.current_period_end_at
    assert is_nil(current.cancel_after_renewal_attempt_id)

    assert {:ok, rescinded} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :rescind_period_end
               )
             end)

    rescinded_change = fetch_contract_change!(rescinded.current_contract_change_id)
    assert rescinded_change.id != queued_change.id
    assert rescinded_change.instruction_kind == :renew_unchanged

    assert rescinded_change.target_plan_revision_id ==
             fixture.subscription.current_plan_revision_id

    assert rescinded_change.target_plan_revision_id != target_revision.id
    assert Map.get(fetch_contract_change!(queued_change.id), :status) == :canceled
    assert current_contract_change(fixture.subscription_id).id == rescinded_change.id
  end

  test "B commits before scheduled cancellation and preserves the unclaimed occurrence" do
    # INVARIANT=B commits before scheduling, so cancellation binds to and preserves that occurrence.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=replace the B-bound attempt or collection after scheduling.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_b_first_scheduled",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    owner = self()
    barrier = :b_before_c_scheduled
    handler_id = telemetry_handler_id("b-before-c-scheduled")

    task =
      Task.async(fn ->
        send(owner, {:renewal_ready, self()})

        receive do
          :start_renewal ->
            unboxed(fn ->
              Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
                now: now
              )
            end)
        after
          5_000 -> {:error, :renewal_start_barrier_timeout}
        end
      end)

    assert_receive {:renewal_ready, task_pid}, 5_000
    attach_dispatch_barrier!(handler_id, task_pid, owner, barrier, fixture.subscription_id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(task_pid, :start_renewal)

    assert_receive {:dispatch_barrier, ^barrier, ^task_pid, metadata}, 5_000
    assert is_binary(metadata.renewal_attempt_id)
    assert is_binary(metadata.collection_attempt_id)

    [attempt_before] = renewal_attempts(fixture.subscription_id)
    collection_before = fetch_collection!(metadata.collection_attempt_id)
    assert attempt_before.id == metadata.renewal_attempt_id
    assert collection_before.renewal_attempt_id == attempt_before.id
    assert collection_before.dispatch_state == :not_started
    assert count_collections(fixture.subscription_id) == 1

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt_before.id
    assert is_nil(scheduled.cancel_at_period_end_at)
    assert fetch_collection!(collection_before.id).dispatch_state == :not_started
    assert :atomics.get(post_count, 1) == 0

    send(task_pid, {:release_dispatch_barrier, barrier})
    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} = Task.await(task, 10_000)

    [attempt_after] = renewal_attempts(fixture.subscription_id)
    collection_after = fetch_collection!(collection_before.id)
    assert attempt_after.id == attempt_before.id
    assert collection_after.id == collection_before.id
    assert collection_after.renewal_attempt_id == attempt_before.id
    assert collection_after.dispatch_state == :not_started
    assert collection_after.financial_outcome == :unresolved
    assert count_collections(fixture.subscription_id) == 1
    assert :atomics.get(post_count, 1) == 0

    current = fetch_subscription!(fixture.subscription_id)
    assert current.cancel_after_renewal_attempt_id == attempt_before.id
    assert is_nil(current.cancel_at_period_end_at)
  end

  test "immediate cancellation after B withdraws authority from the unclaimed collection" do
    # INVARIANT=immediate cancellation withdraws renewal authority while the collection stays unclaimed.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=allow a provider claim after immediate cancellation.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_b_first_immediate",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    owner = self()
    barrier = :b_before_c_immediate
    handler_id = telemetry_handler_id("b-before-c-immediate")

    task =
      Task.async(fn ->
        send(owner, {:renewal_ready, self()})

        receive do
          :start_renewal ->
            unboxed(fn ->
              Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
                now: now
              )
            end)
        after
          5_000 -> {:error, :renewal_start_barrier_timeout}
        end
      end)

    assert_receive {:renewal_ready, task_pid}, 5_000
    attach_dispatch_barrier!(handler_id, task_pid, owner, barrier, fixture.subscription_id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(task_pid, :start_renewal)

    assert_receive {:dispatch_barrier, ^barrier, ^task_pid, metadata}, 5_000
    [attempt_before] = renewal_attempts(fixture.subscription_id)
    collection_before = fetch_collection!(metadata.collection_attempt_id)
    assert attempt_before.id == metadata.renewal_attempt_id
    assert collection_before.dispatch_state == :not_started

    assert {:ok, canceled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :now
               )
             end)

    assert canceled.status == :canceled
    assert :atomics.get(post_count, 1) == 0

    send(task_pid, {:release_dispatch_barrier, barrier})
    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} = Task.await(task, 10_000)

    [attempt_after] = renewal_attempts(fixture.subscription_id)
    collection_after = fetch_collection!(collection_before.id)
    assert attempt_after.id == attempt_before.id
    assert attempt_after.failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert collection_after.id == collection_before.id
    assert collection_after.dispatch_state == :not_started
    assert collection_after.financial_outcome == :unresolved
    assert collection_after.reservation_generation_id == nil
    assert count_collections(fixture.subscription_id) == 1
    assert :atomics.get(post_count, 1) == 0
    assert fetch_subscription!(fixture.subscription_id).status == :canceled

    assert {:ok, :noop} =
             unboxed(fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
                 now: DateTime.add(now, 86_400, :second)
               )
             end)

    assert [same_attempt] = renewal_attempts(fixture.subscription_id)
    assert same_attempt.id == attempt_before.id
    assert fetch_collection!(collection_before.id) == collection_after
    assert count_collections(fixture.subscription_id) == 1
    assert :atomics.get(post_count, 1) == 0
  end

  test "an unpaid B-bound occurrence stays awaiting until exact commercial reconciliation" do
    # INVARIANT=PaymentApplication success alone does not fund the scheduled cancellation boundary.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=promote the awaiting target from financial success alone.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_unpaid_bound",
        started_at: DateTime.add(now, -80 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    StripeAPIStub.stub_unexpected!("reached renewal must not submit another charge")

    reached =
      unboxed(fn -> ReachedRenewalFixtures.prepare_reached!(fixture.subscription_id, now) end)

    attempt = reached.attempt
    assert DateTime.compare(attempt.period_end_at, now) == :lt
    collection = reached.collection

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(scheduled.cancel_at_period_end_at)

    boundary_now = DateTime.add(attempt.period_end_at, 1, :microsecond)
    owner = self()
    barrier = :unpaid_boundary_selection
    handler_id = telemetry_handler_id("unpaid-boundary")

    task =
      Task.async(fn ->
        send(owner, {:boundary_ready, self()})

        receive do
          :run_boundary ->
            unboxed(fn ->
              Facade.run_due_scheduled_cancellations_for_system(now: boundary_now)
            end)
        after
          5_000 -> {:error, :boundary_start_barrier_timeout}
        end
      end)

    assert_receive {:boundary_ready, task_pid}, 5_000

    attach_repo_query_barrier!(
      handler_id,
      task_pid,
      owner,
      barrier,
      &scheduled_selector_query?/1
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(task_pid, :run_boundary)
    assert_receive {:repo_query_barrier, ^barrier, ^task_pid, query}, 5_000
    assert scheduled_selector_query?(query)

    payment_intent = reached.payment_intent

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    assert {:ok, observed} =
             unboxed(fn ->
               PaymentsFacade.observe_payment_intent_for_system(%ObservePaymentIntentInput{
                 payment_intent_id: payment_intent.id
               })
             end)

    assert {:ok, %{outcome: outcome}} =
             unboxed(fn -> PaymentsFacade.apply_observed_payment_outcome_for_system(observed) end)

    assert outcome in [:authoritative_success, :already_applied_success]

    assert fetch_collection!(collection.id).financial_outcome == :verified_success
    assert count_payment_applications(attempt.order_id) == 1

    send(task_pid, {:release_repo_query_barrier, barrier})
    assert {:ok, %{due_count: 0, canceled_count: 0}} = Task.await(task, 10_000)

    awaiting = fetch_subscription!(fixture.subscription_id)
    assert awaiting.status == :active
    assert awaiting.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(awaiting.cancel_at_period_end_at)
    assert access_effects(fixture.subscription_id) == []

    assert {:ok, %{due_count: 0, canceled_count: 0}} =
             unboxed(fn ->
               Facade.run_due_scheduled_cancellations_for_system(now: boundary_now)
             end)

    assert {:ok, :reconciled} =
             unboxed(fn ->
               Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
                 renewal_attempt_id: attempt.id,
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               )
             end)

    canceled = fetch_subscription!(fixture.subscription_id)
    assert canceled.status == :canceled
    assert canceled.current_period_end_at == attempt.period_end_at
    assert canceled.canceled_at == attempt.period_end_at
    assert canceled.ended_at == attempt.period_end_at
    assert is_nil(canceled.cancel_after_renewal_attempt_id)
    assert is_nil(canceled.cancel_at_period_end_at)
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert count_payment_applications(attempt.order_id) == 1
  end

  test "rescission commits after due work selection and before the boundary lock" do
    # INVARIANT=rescission wins before the locked terminal transition, and the stale worker rechecks the instruction.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=terminalize from the pre-lock candidate without reloading.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_rescind_first",
        started_at: DateTime.add(now, -20 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    boundary_at = scheduled.cancel_at_period_end_at
    worker_now = DateTime.add(boundary_at, 1, :microsecond)
    owner = self()
    barrier = :rescind_before_terminal_lock
    handler_id = telemetry_handler_id("rescind-before-terminal")

    task =
      Task.async(fn ->
        send(owner, {:boundary_ready, self()})

        receive do
          :run_boundary ->
            unboxed(fn -> Facade.run_due_scheduled_cancellations_for_system(now: worker_now) end)
        after
          5_000 -> {:error, :boundary_start_barrier_timeout}
        end
      end)

    assert_receive {:boundary_ready, task_pid}, 5_000

    attach_repo_query_barrier!(
      handler_id,
      task_pid,
      owner,
      barrier,
      &scheduled_selector_query?/1
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(task_pid, :run_boundary)
    assert_receive {:repo_query_barrier, ^barrier, ^task_pid, query}, 5_000
    assert scheduled_selector_query?(query)

    assert {:ok, rescinded} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :rescind_period_end
               )
             end)

    assert rescinded.status == :active
    refute rescinded.cancel_at_period_end
    assert is_nil(rescinded.cancel_at_period_end_at)
    assert is_nil(rescinded.cancel_after_renewal_attempt_id)
    rescinded_change = fetch_contract_change!(rescinded.current_contract_change_id)
    assert rescinded_change.instruction_kind == :renew_unchanged

    assert rescinded_change.target_plan_revision_id ==
             fixture.subscription.current_plan_revision_id

    send(task_pid, {:release_repo_query_barrier, barrier})
    assert {:ok, %{due_count: 1, canceled_count: 0, failed_count: 0}} = Task.await(task, 10_000)

    current = fetch_subscription!(fixture.subscription_id)
    assert current.status == :active
    assert current.aggregate_version == rescinded.aggregate_version
    refute current.cancel_at_period_end
    assert current.current_contract_change_id == rescinded_change.id
    assert access_effects(fixture.subscription_id) == []
    assert count_scheduled_cancellation_outboxes(fixture.subscription_id) == 0
  end

  test "scheduled boundary selection changes exactly at T" do
    # INVARIANT=the due selector is exclusive before T and inclusive at T; late execution preserves T.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=change the scheduled boundary comparator
    # or use execution time as the effective end.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_exact_boundary",
        started_at: DateTime.add(now, -20 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    boundary_at = scheduled.cancel_at_period_end_at
    before_boundary = DateTime.add(boundary_at, -1, :microsecond)
    after_boundary = DateTime.add(boundary_at, 1, :microsecond)

    assert {:ok, %{due_count: 0, canceled_count: 0}} =
             unboxed(fn ->
               Facade.run_due_scheduled_cancellations_for_system(now: before_boundary)
             end)

    assert fetch_subscription!(fixture.subscription_id).status == :active

    assert {:ok, %{due_count: 1, canceled_count: 1}} =
             unboxed(fn ->
               Facade.run_due_scheduled_cancellations_for_system(now: boundary_at)
             end)

    canceled = fetch_subscription!(fixture.subscription_id)
    assert canceled.status == :canceled
    assert canceled.canceled_at == boundary_at
    assert canceled.ended_at == boundary_at

    assert {:ok, %{due_count: 0, canceled_count: 0}} =
             unboxed(fn ->
               Facade.run_due_scheduled_cancellations_for_system(now: after_boundary)
             end)

    assert fetch_subscription!(fixture.subscription_id).canceled_at == boundary_at
  end

  test "a committed boundary defeats stale rescission and leaves old intent canceled" do
    # INVARIANT=CANCELED is terminal, so a rescission prepared from old state cannot restore an instruction.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=apply the stale rescission after
    # terminalization without version validation.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_boundary_first",
        started_at: DateTime.add(now, -20 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)

    {target_plan, _target_revision} =
      create_future_plan!(fixture, "jc243_boundary_old_target", 3_100)

    assert {:ok, queued} = queue_plan_change!(fixture, target_plan)
    old_change = fetch_contract_change!(queued.current_contract_change_id)

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    assert Map.get(fetch_contract_change!(old_change.id), :status) == :canceled
    boundary_at = scheduled.cancel_at_period_end_at
    worker_now = DateTime.add(boundary_at, 1, :microsecond)
    owner = self()
    barrier = :stale_rescind_loaded_schedule
    handler_id = telemetry_handler_id("stale-rescind")

    task =
      Task.async(fn ->
        send(owner, {:rescind_ready, self()})

        receive do
          :start_rescind ->
            unboxed(fn ->
              Facade.cancel_subscription_for_user(
                fixture.customer,
                fixture.subscription_id,
                :rescind_period_end
              )
            end)
        after
          5_000 -> {:error, :rescind_start_barrier_timeout}
        end
      end)

    assert_receive {:rescind_ready, task_pid}, 5_000
    attach_repo_query_barrier!(handler_id, task_pid, owner, barrier, &subscription_read_query?/1)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(task_pid, :start_rescind)
    assert_receive {:repo_query_barrier, ^barrier, ^task_pid, query}, 5_000
    assert subscription_read_query?(query)

    assert {:ok, %{due_count: 1, canceled_count: 1, failed_count: 0}} =
             unboxed(fn ->
               Facade.run_due_scheduled_cancellations_for_system(now: worker_now)
             end)

    canceled_before_release = fetch_subscription!(fixture.subscription_id)
    assert canceled_before_release.status == :canceled
    assert canceled_before_release.canceled_at == boundary_at
    assert canceled_before_release.ended_at == boundary_at

    send(task_pid, {:release_repo_query_barrier, barrier})
    rescind_result = Task.await(task, 10_000)

    assert {:error,
            %{
              code: "VALIDATION_ERROR",
              message: "only a current scheduled cancellation can be rescinded"
            }} = rescind_result

    canceled = fetch_subscription!(fixture.subscription_id)
    assert canceled.status == :canceled
    assert is_nil(canceled.current_contract_change_id)
    assert is_nil(canceled.cancel_at_period_end_at)
    assert is_nil(canceled.cancel_after_renewal_attempt_id)
    assert Map.get(fetch_contract_change!(old_change.id), :status) == :canceled
    assert contract_changes(fixture.subscription_id) == [fetch_contract_change!(old_change.id)]
  end

  test "duplicate late boundary workers commit one terminal effect and replay one email" do
    # INVARIANT=duplicate candidates serialize to one terminal transition and one current source version.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=let a stale effect or worker overwrite the terminal source version.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_duplicate_boundary",
        started_at: DateTime.add(now, -20 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)

    subscription = fetch_subscription!(fixture.subscription_id)

    assert {:ok, old_effect_input} =
             EstablishAccessEffectInput.new(%{
               subscription_id: subscription.id,
               source_version: subscription.aggregate_version,
               disposition: :effective,
               entitlement_kind: :membership_access,
               entitlement_scope_key: fixture.plan_scope_key,
               valid_from_at: subscription.current_period_start_at,
               valid_until_at: subscription.current_period_end_at,
               source_order_line_item_id: fixture.line_item_id,
               contract_change_id: nil,
               plan_revision_id: subscription.current_plan_revision_id
             })

    assert {:ok, old_effect} =
             unboxed(fn -> Facade.establish_access_effect_for_system(old_effect_input) end)

    assert {:ok, scheduled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :period_end
               )
             end)

    boundary_at = scheduled.cancel_at_period_end_at
    late_now = DateTime.add(boundary_at, 5 * 60, :second)
    owner = self()
    barrier = :duplicate_due_candidate

    handler_ids = [
      telemetry_handler_id("duplicate-worker-a"),
      telemetry_handler_id("duplicate-worker-b")
    ]

    tasks =
      handler_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {handler_id, index} ->
        task =
          Task.async(fn ->
            send(owner, {:boundary_ready, index, self()})

            receive do
              :run_boundary ->
                unboxed(fn ->
                  Facade.run_due_scheduled_cancellations_for_system(now: late_now)
                end)
            after
              5_000 -> {:error, :boundary_start_barrier_timeout}
            end
          end)

        assert_receive {:boundary_ready, ^index, task_pid}, 5_000

        attach_repo_query_barrier!(
          handler_id,
          task_pid,
          owner,
          barrier,
          &scheduled_selector_query?/1
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)
        {task, task_pid}
      end)

    Enum.each(tasks, fn {_task, task_pid} -> send(task_pid, :run_boundary) end)

    selected =
      for _ <- 1..2 do
        assert_receive {:repo_query_barrier, ^barrier, selected_pid, query}, 5_000
        assert scheduled_selector_query?(query)
        selected_pid
      end

    assert length(Enum.uniq(selected)) == 2

    Enum.each(tasks, fn {_task, task_pid} ->
      send(task_pid, {:release_repo_query_barrier, barrier})
    end)

    results = Enum.map(tasks, fn {task, _task_pid} -> Task.await(task, 10_000) end)
    assert Enum.all?(results, &match?({:ok, %{due_count: 1, failed_count: 0}}, &1))
    assert Enum.sum(Enum.map(results, fn {:ok, result} -> result.canceled_count end)) == 1

    canceled = fetch_subscription!(fixture.subscription_id)
    assert canceled.status == :canceled
    assert canceled.canceled_at == boundary_at
    assert canceled.ended_at == boundary_at
    assert canceled.current_period_end_at == boundary_at
    assert canceled.aggregate_version == scheduled.aggregate_version + 1
    assert is_nil(canceled.current_contract_change_id)
    assert is_nil(canceled.cancel_at_period_end_at)
    assert is_nil(canceled.cancel_after_renewal_attempt_id)

    terminal_effect = fetch_current_access_effect!(fixture.subscription_id)
    assert terminal_effect.disposition == :non_effective
    assert is_nil(terminal_effect.valid_from_at)
    assert terminal_effect.source_version == canceled.aggregate_version
    assert terminal_effect.source_version > old_effect.source_version
    assert count_effects_at_version(fixture.subscription_id, canceled.aggregate_version) == 1
    assert count_contract_changes(fixture.subscription_id) == 0

    outbox_key = scheduled_cancellation_email_key(fixture.subscription_id, boundary_at)
    assert count_outbox_key(fixture.subscription_id, outbox_key) == 1

    _stale_effect_result =
      unboxed(fn -> Facade.establish_access_effect_for_system(old_effect_input) end)

    assert fetch_current_access_effect!(fixture.subscription_id).id == terminal_effect.id

    unboxed(fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription_id)

      Repo.query!(
        "DELETE FROM oban_jobs WHERE args->>'email_outbox_id' IN (SELECT id::text FROM email_outboxes WHERE subscription_id = $1 AND idempotency_key = $2)",
        [subscription_id, outbox_key]
      )

      Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 AND idempotency_key = $2",
        [subscription_id, outbox_key]
      )
    end)

    assert count_outbox_key(fixture.subscription_id, outbox_key) == 0

    assert {:ok, %{replay_count: 1, failed_count: 0}} =
             unboxed(fn -> Facade.replay_scheduled_cancellation_notifications_for_system() end)

    assert {:ok, %{replay_count: 0, failed_count: 0}} =
             unboxed(fn -> Facade.replay_scheduled_cancellation_notifications_for_system() end)

    assert count_outbox_key(fixture.subscription_id, outbox_key) == 1

    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :noop} =
             unboxed(fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
                 now: late_now
               )
             end)

    assert renewal_attempts(fixture.subscription_id) == []
    assert :atomics.get(post_count, 1) == 0
  end

  test "immediate cancellation after C reconciles late success on the exact collection" do
    # INVARIANT=C may have crossed before cancel-now, but late success must preserve payment truth
    # without reactivating the Subscription.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=replace the dispatched collection or
    # reactivate the canceled Subscription on reconciliation.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_post_c_success",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    owner = self()

    reached =
      unboxed(fn -> ReachedRenewalFixtures.prepare_reached!(fixture.subscription_id, now) end)

    barrier = :provider_observation_after_c
    observation = ReachedRenewalFixtures.observation_body(reached, "succeeded")

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"

      assert conn.request_path ==
               "/v1/payment_intents/#{reached.payment_intent.provider_payment_id}"

      send(owner, {:provider_observation, self()})

      receive do
        {:release_provider_observation, ^barrier} ->
          StripeAPIStub.json_response(conn, observation)
      after
        10_000 -> raise "timed out at exact-ID observation barrier after cancellation"
      end
    end)

    task =
      Task.async(fn ->
        unboxed(fn ->
          Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
            now: now
          )
        end)
      end)

    assert_receive {:provider_observation, provider_pid}, 5_000
    attempt_before = reached.attempt
    collection_before = reached.collection

    assert collection_before.dispatch_state == :may_have_been_reached

    assert {:ok, canceled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :now
               )
             end)

    assert canceled.status == :canceled
    assert fetch_collection!(collection_before.id).id == collection_before.id
    assert fetch_collection!(collection_before.id).dispatch_state == :may_have_been_reached
    assert count_collections(fixture.subscription_id) == 1

    send(provider_pid, {:release_provider_observation, barrier})
    assert {:ok, :processed} = Task.await(task, 10_000)
    payment_intent = fetch_payment_intent!(reached.payment_intent.id)

    assert fetch_collection!(collection_before.id).financial_outcome == :verified_success
    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
    assert count_payment_applications(attempt_before.order_id) == 1

    assert {:ok, %{rows: [["paid"]]}} =
             Repo.query("SELECT state FROM orders WHERE id = $1", [
               Ecto.UUID.dump!(attempt_before.order_id)
             ])

    assert {:ok, :noop} =
             unboxed(fn ->
               Facade.reconcile_paid_subscription_renewal_for_system(attempt_before.order_id,
                 renewal_attempt_id: attempt_before.id,
                 collection_attempt_id: collection_before.id,
                 payment_intent_id: payment_intent.id
               )
             end)

    canceled_after_replay = fetch_subscription!(fixture.subscription_id)
    assert canceled_after_replay.status == :canceled
    assert fetch_attempt!(attempt_before.id).id == attempt_before.id
    assert fetch_collection!(collection_before.id).id == collection_before.id
    assert count_collections(fixture.subscription_id) == 1
    assert count_payment_applications(attempt_before.order_id) == 1
    assert count_refunds_for(attempt_before.order_id, payment_intent.id) == 1
    assert payment_intent.state == :succeeded

    assert {:ok, :noop} =
             unboxed(fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
                 now: DateTime.add(now, 86_400, :second)
               )
             end)

    assert count_collections(fixture.subscription_id) == 1
    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
  end

  test "immediate cancellation after C blocks a future collection after verified non-success" do
    # INVARIANT=a terminal non-success after C must not authorize another provider collection after cancel-now.
    # PRODUCTION_MUTATION_THAT_WOULD_BREAK_THIS_TEST=retry or replace the collection after the
    # canceled Subscription receives terminal failure evidence.
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      create_committed_subscription_fixture!("jc243_post_c_failure",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      )

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    owner = self()

    reached =
      unboxed(fn -> ReachedRenewalFixtures.prepare_reached!(fixture.subscription_id, now) end)

    barrier = :provider_observation_after_c_failure
    observation = ReachedRenewalFixtures.observation_body(reached, "canceled")

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"

      assert conn.request_path ==
               "/v1/payment_intents/#{reached.payment_intent.provider_payment_id}"

      send(owner, {:provider_observation, self()})

      receive do
        {:release_provider_observation, ^barrier} ->
          StripeAPIStub.json_response(conn, observation)
      after
        10_000 -> raise "timed out at exact-ID observation barrier after cancellation"
      end
    end)

    task =
      Task.async(fn ->
        unboxed(fn ->
          Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
            now: now
          )
        end)
      end)

    assert_receive {:provider_observation, provider_pid}, 5_000
    attempt_before = reached.attempt
    collection_before = reached.collection
    assert collection_before.dispatch_state == :may_have_been_reached

    assert {:ok, canceled} =
             unboxed(fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription_id,
                 :now
               )
             end)

    assert canceled.status == :canceled
    assert fetch_collection!(collection_before.id).id == collection_before.id

    send(provider_pid, {:release_provider_observation, barrier})
    assert {:ok, :processed} = Task.await(task, 10_000)

    payment_intent = fetch_payment_intent!(reached.payment_intent.id)

    terminal_collection = fetch_collection!(collection_before.id)
    [attempt_after] = renewal_attempts(fixture.subscription_id)
    assert attempt_after.id == attempt_before.id
    assert terminal_collection.id == collection_before.id
    assert terminal_collection.dispatch_state == :may_have_been_reached
    assert terminal_collection.financial_outcome == :verified_terminal_financial_non_success
    assert payment_intent.state == :failed
    assert count_collections(fixture.subscription_id) == 1
    assert count_payment_applications(attempt_before.order_id) == 0

    assert {:ok, :noop} =
             unboxed(fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
                 now: DateTime.add(now, 86_400, :second)
               )
             end)

    assert fetch_subscription!(fixture.subscription_id).status == :canceled
    assert count_collections(fixture.subscription_id) == 1
  end

  defp telemetry_handler_id(prefix) do
    "jc243-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp attach_repo_query_barrier!(handler_id, task_pid, owner, barrier, predicate) do
    query_count = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, config ->
          query = Map.get(metadata, :query, "")

          if self() == config.task_pid and config.predicate.(query) and
               :atomics.add_get(config.query_count, 1, 1) == 1 do
            send(config.owner, {:repo_query_barrier, config.barrier, self(), query})
            barrier = config.barrier

            receive do
              {:release_repo_query_barrier, ^barrier} -> :ok
            after
              10_000 -> raise "timed out at repository query barrier #{config.barrier}"
            end
          end
        end,
        %{
          task_pid: task_pid,
          owner: owner,
          barrier: barrier,
          predicate: predicate,
          query_count: query_count
        }
      )

    :ok
  end

  defp attach_dispatch_barrier!(handler_id, task_pid, owner, barrier, subscription_id) do
    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_check],
        fn _event, _measurements, metadata, config ->
          if self() == config.task_pid and metadata.subscription_id == config.subscription_id do
            send(config.owner, {:dispatch_barrier, config.barrier, self(), metadata})
            barrier = config.barrier

            receive do
              {:release_dispatch_barrier, ^barrier} -> :ok
            after
              10_000 -> raise "timed out at renewal dispatch barrier #{config.barrier}"
            end
          end
        end,
        %{task_pid: task_pid, owner: owner, barrier: barrier, subscription_id: subscription_id}
      )

    :ok
  end

  defp subscription_read_query?(query) when is_binary(query) do
    normalized = String.downcase(query)

    String.contains?(normalized, "subscriptions") and
      String.contains?(normalized, "where") and
      not String.contains?(normalized, "for update")
  end

  defp subscription_read_query?(_query), do: false

  defp scheduled_selector_query?(query) when is_binary(query) do
    normalized = String.downcase(query)

    String.contains?(normalized, "subscriptions") and
      String.contains?(normalized, "cancel_at_period_end_at") and
      String.contains?(normalized, "<=") and
      String.contains?(normalized, "status") and
      not String.contains?(normalized, "for update")
  end

  defp scheduled_selector_query?(_query), do: false

  defp unboxed(fun) when is_function(fun, 0) do
    Sandbox.unboxed_run(Repo, fn ->
      Sandbox.unboxed_run(Store.DirectRepo, fun)
    end)
  end

  defp create_committed_subscription_fixture!(prefix, opts) do
    Sandbox.unboxed_run(Repo, fn ->
      unique = "#{prefix}_#{Ecto.UUID.generate()}"
      customer = SubscriptionsFixtures.create_customer!(unique)

      %{product: product, variant: variant} =
        SubscriptionsFixtures.create_subscription_sellable!()

      plan =
        SubscriptionsFixtures.create_subscription_plan!(%{
          entitlement_kind: :membership_access,
          entitlement_scope_key: "membership:#{unique}"
        })

      attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
      started_at = Keyword.get(opts, :started_at)

      subscription_attrs = %{
        provider_billing_ref: "pm_#{unique}"
      }

      subscription_attrs =
        if match?(%DateTime{}, started_at),
          do: Map.put(subscription_attrs, :started_at, started_at),
          else: subscription_attrs

      next_renewal_at = Keyword.get(opts, :next_renewal_at)

      subscription_attrs =
        if match?(%DateTime{}, next_renewal_at),
          do: Map.put(subscription_attrs, :next_renewal_at, next_renewal_at),
          else: subscription_attrs

      %{subscription: subscription, order: order, line_item: line_item, revision: revision} =
        SubscriptionsFixtures.create_subscription_fixture!(
          customer.id,
          variant,
          plan,
          subscription_attrs
        )

      %{
        attachment_id: attachment.id,
        customer: customer,
        customer_id: customer.id,
        line_item_id: line_item.id,
        order_id: order.id,
        plan_id: plan.id,
        plan_scope_key: "membership:#{unique}",
        product_id: product.id,
        revision_id: revision.id,
        subscription: subscription,
        subscription_id: subscription.id,
        variant_id: variant.id
      }
    end)
  end

  defp cleanup_committed_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      sub_id = Ecto.UUID.dump!(fixture.subscription_id)
      user_id = Ecto.UUID.dump!(fixture.customer_id)
      product_id = Ecto.UUID.dump!(fixture.product_id)
      variant_id = Ecto.UUID.dump!(fixture.variant_id)

      {:ok, %{rows: [[plan_ids]]}} =
        Repo.query(
          "SELECT array_agg(subscription_plan_id) FROM variant_subscription_plans WHERE variant_id = $1",
          [variant_id]
        )

      plan_ids = Enum.map(plan_ids, &db_uuid/1)

      Repo.query!(
        """
        DELETE FROM oban_jobs
        WHERE args->>'subscription_id' = $1
          OR args->>'order_id' IN (SELECT id::text FROM orders WHERE user_id = $2)
          OR args->>'email_outbox_id' IN (
            SELECT id::text FROM email_outboxes
            WHERE subscription_id = $1::text::uuid
               OR order_id IN (SELECT id FROM orders WHERE user_id = $2::uuid)
               OR refund_id IN (
                 SELECT id FROM refunds
                 WHERE order_id IN (SELECT id FROM orders WHERE user_id = $2::uuid)
               )
          )
        """,
        [fixture.subscription_id, user_id]
      )

      Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 OR refund_id IN (SELECT id FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $2))",
        [sub_id, user_id]
      )

      Repo.query!(
        "DELETE FROM refund_attempts WHERE refund_id IN (SELECT id FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [
          user_id
        ]
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
        "UPDATE subscriptions SET cancel_at_period_end = false, cancel_at_period_end_at = NULL, cancel_after_renewal_attempt_id = NULL WHERE id = $1",
        [sub_id]
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

      Repo.query!(
        "DELETE FROM plan_revisions WHERE subscription_plan_id IN (SELECT subscription_plan_id FROM variant_subscription_plans WHERE variant_id = $1)",
        [variant_id]
      )

      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])

      Repo.query!("DELETE FROM subscription_plans WHERE id = ANY($1)", [plan_ids])
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end

  defp renewal_attempts(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_future_plan!(fixture, prefix, amount_minor) do
    Sandbox.unboxed_run(Repo, fn ->
      variant =
        Variant
        |> Ash.Query.filter(expr(id == ^fixture.variant_id))
        |> Ash.read_one!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

      plan =
        SubscriptionsFixtures.create_subscription_plan!(%{
          amount_minor: amount_minor,
          entitlement_kind: :membership_access,
          entitlement_scope_key: "membership:#{prefix}:#{Ecto.UUID.generate()}"
        })

      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
      revision = SubscriptionsFixtures.create_plan_revision!(plan)
      {plan, revision}
    end)
  end

  defp queue_plan_change!(fixture, %SubscriptionPlan{} = plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => fixture.subscription_id,
        "subscription_plan_id" => plan.id
      })

    unboxed(fn ->
      Facade.queue_subscription_plan_change_for_user(
        fixture.customer,
        fixture.subscription_id,
        input
      )
    end)
  end

  defp fetch_attempt!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection!(id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp current_contract_change(subscription_id) do
    case fetch_subscription!(subscription_id).current_contract_change_id do
      nil -> nil
      id -> fetch_contract_change!(id)
    end
  end

  defp contract_changes(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(ordering_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_contract_changes(subscription_id) do
    length(contract_changes(subscription_id))
  end

  defp db_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value
  defp db_uuid(value), do: Ecto.UUID.dump!(value)

  defp count_payment_applications(order_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query("SELECT count(*) FROM payment_applications WHERE order_id = $1", [
        Ecto.UUID.dump!(order_id)
      ])

    count
  end

  defp access_effects(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_current_access_effect!(subscription_id) do
    {:ok, effect} =
      Facade.get_current_access_effect_for_system(fetch_subscription!(subscription_id))

    effect
  end

  defp count_effects_at_version(subscription_id, source_version) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        "SELECT count(*) FROM access_effects WHERE subscription_id = $1 AND source_version = $2",
        [Ecto.UUID.dump!(subscription_id), source_version]
      )

    count
  end

  defp scheduled_cancellation_email_key(subscription_id, boundary_at) do
    boundary = DateTime.to_iso8601(DateTime.truncate(boundary_at, :microsecond))

    "membership_access_ended:sub:#{subscription_id}:reason:canceled_period_end:period_end:#{boundary}"
  end

  defp count_outbox_key(subscription_id, key) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        "SELECT count(*) FROM email_outboxes WHERE subscription_id = $1 AND idempotency_key = $2",
        [Ecto.UUID.dump!(subscription_id), key]
      )

    count
  end

  defp count_refunds_for(order_id, payment_intent_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        "SELECT count(*) FROM refunds WHERE order_id = $1 AND payment_intent_id = $2",
        [Ecto.UUID.dump!(order_id), Ecto.UUID.dump!(payment_intent_id)]
      )

    count
  end

  defp count_scheduled_cancellation_outboxes(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        """
        SELECT count(*)
        FROM email_outboxes
        WHERE subscription_id = $1
          AND idempotency_key LIKE $2
        """,
        [
          Ecto.UUID.dump!(subscription_id),
          "membership_access_ended:sub:%:reason:canceled_period_end:period_end:%"
        ]
      )

    count
  end

  defp count_collections(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        "SELECT count(*) FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
        [Ecto.UUID.dump!(subscription_id)]
      )

    count
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
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
