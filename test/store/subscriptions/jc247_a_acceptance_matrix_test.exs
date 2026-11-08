defmodule Store.Subscriptions.Jc247AAcceptanceMatrixTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.Order
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  @cursor_floor "00000000-0000-7000-8000-000000000000"
  @barrier_timeout 10_000

  setup context do
    StripeAPIStub.setup_default(context)
    {:ok, context: context}
  end

  test "TASK1 payment failure postcommit barrier sees exact effect id before F1", %{
    context: context
  } do
    fixture = create_due_fixture!("jc247mx_exact_id")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             run_failure_with_barrier!(context, fixture, barrier, fn effect ->
               assert effect.status == :required
             end)

    assert_durable_f1_outcome!(fixture.subscription.id, :applied)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 applied", %{context: context} do
    assert_payment_failure_outer_preserved(context, :applied, fn _effect -> :ok end)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 projection pending", %{
    context: context
  } do
    constraint = add_projection_pending_constraint!()

    assert_payment_failure_outer_preserved(context, :projection_pending, fn _effect -> :ok end,
      constraint: constraint
    )
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 superseded", %{context: context} do
    assert_payment_failure_outer_preserved(context, :superseded, fn effect ->
      subscription = reload_subscription!(effect.subscription_id)
      attempt = fetch_attempt!(subscription.id)
      establish_newer_non_effective_effect!(subscription, attempt)
    end)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 noop", %{context: context} do
    assert_payment_failure_outer_preserved(context, :noop, &mark_effect_applied!/1)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 error", %{context: context} do
    assert_payment_failure_outer_preserved(context, :error, fn _effect -> :ok end,
      grant_block: true
    )
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 applied", %{context: context} do
    assert_auth_outer_preserved(context, :applied, fn _effect -> :ok end)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 noop", %{context: context} do
    assert_auth_outer_preserved(context, :noop, &mark_effect_applied!/1)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 projection pending", %{
    context: context
  } do
    constraint = add_projection_pending_constraint!()

    assert_auth_outer_preserved(context, :projection_pending, fn _effect -> :ok end,
      constraint: constraint
    )
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 superseded", %{context: context} do
    assert_auth_outer_preserved(context, :superseded, fn effect ->
      subscription = reload_subscription!(effect.subscription_id)
      attempt = fetch_attempt!(subscription.id)
      establish_newer_non_effective_effect!(subscription, attempt)
    end)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 error", %{context: context} do
    assert_auth_outer_preserved(context, :error, fn _effect -> :ok end, grant_block: true)
  end

  test "TASK1 auth replay matrix — no second producer effect" do
    fixture = create_due_fixture!("jc247mx_auth_replay_matrix")
    StripeAPIStub.stub_unexpected!("legacy preparation must not contact Stripe")
    reached = ReachedRenewalFixtures.prepare_reached!(fixture.subscription.id, fixture.now)

    observation =
      ReachedRenewalFixtures.observation_body(reached, "requires_action", %{
        "next_action" => %{
          "redirect_to_url" => %{"url" => "https://payments.example.test/matrix-replay"}
        }
      })

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      observation
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: fixture.now
             )

    [first] = access_effects!(fixture.subscription.id)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      observation
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: reload_subscription!(fixture.subscription.id).failed_payment_boundary_at
             )

    assert [^first] = access_effects!(fixture.subscription.id)
  end

  test "TASK4 contract change X to Y reconciliation repairs provenance only", %{context: context} do
    fixture = create_contract_bound_due_fixture!("jc247mx_xy")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    change_x = fixture.change_x
    funded_revision_id = fixture.funded_revision_id
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    failure_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    subscription = reload_subscription!(subscription_id)
    [e1] = access_effects!(subscription_id)
    attempt = fetch_attempt!(subscription_id)

    assert e1.status == :required
    assert attempt.contract_change_id == change_x.id
    assert attempt.charged_contract_snapshot["access_on_past_due"] == "keep_during_grace"
    assert e1.plan_revision_id == funded_revision_id

    pointer = subscription.current_dunning_renewal_attempt_id
    boundary = subscription.failed_payment_boundary_at

    SubscriptionsFixtures.create_plan_revision!(fixture.plan_y)

    assert {:ok, queued_y} = queue_plan_change(fixture.customer, subscription.id, fixture.plan_y)
    change_y = fetch_contract_change!(queued_y.current_contract_change_id)
    subscription = reload_subscription!(subscription.id)

    assert subscription.current_contract_change_id == change_y.id
    assert fetch_attempt!(subscription.id).contract_change_id == change_x.id
    assert subscription.current_plan_revision_id == funded_revision_id
    assert subscription.failed_payment_boundary_at == boundary

    e1 = fetch_effect!(e1.id)
    assert e1.contract_change_id != change_y.id
    assert e1.plan_revision_id == subscription.current_plan_revision_id
    assert is_nil(e1.valid_from_at)
    assert e1.valid_until_at == subscription.failed_payment_boundary_at
    assert e1.contract_change_id != subscription.current_contract_change_id

    set_updated_at!([e1], DateTime.add(DateTime.utc_now(), -1, :second))

    reconcile_result =
      Facade.run_access_effect_target_order_reconciliation_for_system(
        limit: 50,
        as_of: DateTime.utc_now(),
        after_inserted_at: e1.inserted_at,
        after_id: @cursor_floor
      )

    assert {:ok, result} = reconcile_result

    assert result.repaired_count == 1
    rows = access_effect_rows!(subscription.id)
    assert length(rows) == 2

    e1_id = e1.id
    assert Enum.any?(rows, &(&1.status == "superseded" and &1.id == e1_id))

    e2_row =
      Enum.find(rows, fn row -> row.status == "required" and row.id != e1_id end)

    assert e2_row.contract_change_id == change_y.id
    assert e2_row.plan_revision_id == funded_revision_id

    e1 = fetch_effect!(e1.id)
    e2 = fetch_effect!(e2_row.id)
    assert e2.valid_from_at == e1.valid_from_at
    assert e2.valid_until_at == e1.valid_until_at

    send(failure_task.pid, {:jc247_release_keep_grace_sync, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @barrier_timeout)

    assert fetch_effect!(e1.id).status == :superseded
    assert latest_effect!(subscription.id).id == e2.id
    assert reload_subscription!(subscription.id).current_dunning_renewal_attempt_id == pointer
  end

  test "TASK5 unresolved V1 keep-grace effect executes after same-episode dunning bookkeeping", %{
    context: context
  } do
    fixture = create_due_fixture!("jc247mx_v1_after_v2")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    failure_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [e1] = access_effects!(subscription_id)
    assert e1.status == :required
    v1 = e1.source_version
    pointer = reload_subscription!(subscription_id).current_dunning_renewal_attempt_id
    boundary = reload_subscription!(subscription_id).failed_payment_boundary_at
    first_attempt = fetch_attempt!(subscription_id)
    first_collection = latest_collection_for_attempt!(first_attempt.id)

    :telemetry.detach(handler_id)

    retry =
      prepare_reached_observation!(
        subscription_id,
        reload_subscription!(subscription_id).next_retry_at,
        "canceled"
      )

    assert retry.attempt.id == first_attempt.id
    assert retry.order.id == first_attempt.order_id
    refute retry.collection.id == first_collection.id
    refute retry.payment_intent.id == first_collection.payment_intent_id

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(subscription_id, now: retry.now)

    subscription = reload_subscription!(subscription_id)
    assert subscription.aggregate_version > v1
    assert subscription.current_dunning_renewal_attempt_id == pointer
    assert subscription.failed_payment_boundary_at == boundary

    assert fetch_attempt!(subscription_id).charged_contract_snapshot ==
             first_attempt.charged_contract_snapshot

    assert [^e1] = access_effects!(subscription_id)

    send(failure_task.pid, {:jc247_release_keep_grace_sync, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @barrier_timeout)

    e1 = fetch_effect!(e1.id)
    assert e1.source_version < subscription.aggregate_version
    assert e1.status == :applied
    assert active_source_grants!(subscription_id) >= 1
  end

  test "TASK5 retry failure does not create second keep-grace producer effect" do
    fixture = create_due_fixture!("jc247mx_exact_replay")
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    [first] = access_effects!(subscription.id)
    attempt = fetch_attempt!(subscription.id)
    first_collection = latest_collection_for_attempt!(attempt.id)
    pointer = subscription.current_dunning_renewal_attempt_id
    boundary = subscription.failed_payment_boundary_at
    retry = prepare_reached_observation!(subscription.id, subscription.next_retry_at, "canceled")
    assert retry.attempt.id == attempt.id
    assert retry.order.id == attempt.order_id
    refute retry.collection.id == first_collection.id
    refute retry.payment_intent.id == first_collection.payment_intent_id

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: retry.now)

    subscription = reload_subscription!(fixture.subscription.id)
    assert subscription.current_dunning_renewal_attempt_id == pointer
    assert subscription.failed_payment_boundary_at == boundary

    assert fetch_attempt!(subscription.id).charged_contract_snapshot ==
             attempt.charged_contract_snapshot

    assert [^first] = access_effects!(subscription.id)
    assert {:ok, outcome} = Facade.execute_effective_access_effect_for_system(first.id)
    assert outcome in [:applied, :noop]
    assert fetch_effect!(first.id).status == :applied
  end

  @tag :real_connections
  test "TASK6 paused keep-grace sync loses to cancel-now non_effective effect", %{
    context: context
  } do
    fixture = create_due_fixture!("jc247mx_race_cancel")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    failure_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [keep_grace] = access_effects!(subscription_id)
    assert keep_grace.status == :required

    cancel_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())

        Facade.cancel_subscription_for_user(
          fixture.customer,
          subscription_id,
          :now
        )
      end)

    assert {:ok, %Subscription{status: :canceled}} = Task.await(cancel_task, @barrier_timeout)
    send(failure_task.pid, {:jc247_release_keep_grace_sync, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @barrier_timeout)

    subscription = reload_subscription!(subscription_id)
    assert subscription.status == :canceled
    assert active_source_grants!(subscription_id) == 0

    effects = access_effects!(subscription_id)

    assert Enum.any?(
             effects,
             &(&1.disposition == :non_effective and &1.status in [:applied, :required])
           )

    keep = fetch_effect!(keep_grace.id)
    assert keep.status in [:superseded, :applied]
    refute keep.status == :required and active_source_grants!(subscription_id) > 0
  end

  @tag :real_connections
  test "TASK6 paused keep-grace sync loses to exact paid recovery", %{context: context} do
    fixture = create_due_fixture!("jc247mx_race_recovery")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    failure_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [e1] = access_effects!(subscription_id)
    assert e1.status == :required

    past_due = reload_subscription!(subscription_id)
    assert past_due.status == :past_due
    assert %DateTime{} = past_due.next_retry_at
    attempt = fetch_attempt!(subscription_id)
    assert attempt.id == past_due.current_dunning_renewal_attempt_id
    order = fetch_order!(attempt.order_id)
    first_collection = latest_collection_for_attempt!(attempt.id)
    attempt_snapshot = attempt.charged_contract_snapshot
    source_version = past_due.aggregate_version
    boundary = past_due.failed_payment_boundary_at

    StripeAPIStub.stub_unexpected!("retry preparation must not submit a renewal charge")
    retry = ReachedRenewalFixtures.prepare_reached!(subscription_id, past_due.next_retry_at)
    assert retry.attempt.id == attempt.id
    assert retry.order.id == order.id
    assert retry.collection.renewal_attempt_id == attempt.id
    assert retry.attempt.order_id == order.id
    assert retry.payment_intent.id == retry.collection.payment_intent_id
    refute retry.collection.id == first_collection.id
    refute retry.payment_intent.id == first_collection.payment_intent_id
    assert fetch_attempt!(subscription_id).id == attempt.id
    after_prepare = reload_subscription!(subscription_id)
    assert after_prepare.current_dunning_renewal_attempt_id == attempt.id
    assert after_prepare.aggregate_version == source_version
    assert after_prepare.failed_payment_boundary_at == boundary
    assert fetch_attempt!(subscription_id).charged_contract_snapshot == attempt_snapshot
    assert [^e1] = access_effects!(subscription_id)

    StripeAPIStub.stub_payment_observation(
      retry.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(retry, "succeeded")
    )

    assert retry.payment_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(retry.collection.id)

    recovery_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())

        assert {:ok, observed} =
                 Store.Payments.Facade.observe_payment_intent_for_system(
                   %ObservePaymentIntentInput{
                     payment_intent_id: retry.payment_intent.id
                   }
                 )

        assert {:ok, %{outcome: outcome}} =
                 Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

        assert outcome in [:authoritative_success, :already_applied_success]

        assert {:ok, handoff} =
                 RenewalCollectionAttempts.success_handoff_for_system(retry.collection.id)

        assert handoff.renewal_attempt_id == attempt.id
        assert handoff.collection_attempt_id == retry.collection.id
        assert handoff.payment_intent_id == retry.payment_intent.id

        Facade.reconcile_paid_subscription_renewal_for_system(order.id, handoff_opts(handoff))
      end)

    assert {:ok, :reconciled} = Task.await(recovery_task, @barrier_timeout)
    send(failure_task.pid, {:jc247_release_keep_grace_sync, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @barrier_timeout)

    subscription = reload_subscription!(subscription_id)
    assert subscription.status == :active
    assert is_nil(subscription.current_dunning_renewal_attempt_id)
    assert active_source_grants!(subscription_id) >= 1

    e1 = fetch_effect!(e1.id)
    latest = latest_effect!(subscription_id)
    assert latest.id != e1.id
    assert latest.disposition == :effective
    assert latest.status == :applied
    assert e1.status == :superseded
    refute e1.valid_until_at == latest.valid_until_at and e1.valid_from_at == latest.valid_from_at
  end

  @tag :real_connections
  test "TASK6 paused keep-grace sync loses to grace-boundary suspension", %{context: context} do
    fixture = create_due_fixture!("jc247mx_race_suspend")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    failure_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [e1] = access_effects!(subscription_id)
    assert e1.status == :required

    suspend_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())

        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        boundary_at = DateTime.add(now, -1, :second)

        Repo.query!(
          """
          UPDATE subscriptions
          SET failed_payment_boundary_at = $2,
              retry_suppressed_at = $3,
              next_retry_at = NULL
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(subscription_id), boundary_at, now]
        )

        Facade.run_due_failed_payment_suspensions_for_system(now: now, limit: 20)
      end)

    assert {:ok, %{suspended_count: 1}} = Task.await(suspend_task, @barrier_timeout)
    send(failure_task.pid, {:jc247_release_keep_grace_sync, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @barrier_timeout)

    subscription = reload_subscription!(subscription_id)
    assert subscription.status == :suspended
    assert active_source_grants!(subscription_id) == 0

    e1 = fetch_effect!(e1.id)
    assert e1.status in [:superseded, :applied]
    assert Enum.any?(access_effects!(subscription_id), &(&1.disposition == :non_effective))
  end

  test "TASK7 unrelated subscription grant unchanged after keep-grace F1" do
    fixture = create_due_fixture!("jc247mx_isolation")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    subscription = reload_subscription!(fixture.subscription.id)

    %{variant: other_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    other_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "other-sub-grant"
      })

    SubscriptionsFixtures.attach_variant_plan!(other_variant.id, other_plan.id)

    other =
      SubscriptionsFixtures.create_subscription_fixture!(
        fixture.customer.id,
        other_variant,
        other_plan,
        %{provider_billing_ref: "pm_jc247mx_other"}
      )

    unrelated =
      EntitlementGrant
      |> Ash.Changeset.for_create(
        :issue,
        %{
          user_id: subscription.user_id,
          kind: :membership_access,
          scope_key: "other-subscription-grant",
          source_kind: :subscription,
          source_id: other.subscription.id,
          status: :active,
          valid_from_at: ~U[2020-01-01 00:00:00.000000Z],
          valid_to_at: ~U[2030-01-01 00:00:00.000000Z]
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})

    before_unrelated = snapshot_grant!(unrelated.id)
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()
    after_unrelated = snapshot_grant!(unrelated.id)

    assert after_unrelated == before_unrelated
    assert active_source_grants!(subscription.id) >= 1
    [effect] = access_effects!(subscription.id)
    assert effect.status == :applied
  end

  defp assert_payment_failure_outer_preserved(context, outcome, at_barrier_fn, opts \\ []) do
    fixture = create_due_fixture!("jc247mx_pf_#{System.unique_integer([:positive])}")
    fixture = prepare_fixture_for_facade!(fixture, "canceled")
    setup_f1_injection!(fixture, opts)

    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    grants_before = active_source_grants!(fixture.subscription.id)

    outer =
      run_failure_with_barrier!(context, fixture, barrier, fn effect ->
        refute Repo.in_transaction?()
        assert effect.status == :required
        at_barrier_fn.(effect)
      end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = outer
    assert reload_subscription!(fixture.subscription.id).status == :past_due
    assert_durable_f1_outcome!(fixture.subscription.id, outcome, grants_before: grants_before)
  end

  defp assert_auth_outer_preserved(context, outcome, at_barrier_fn, opts \\ []) do
    fixture = create_due_fixture!("jc247mx_auth_#{System.unique_integer([:positive])}")
    fixture = prepare_fixture_for_facade!(fixture, "requires_action")
    setup_f1_injection!(fixture, opts)

    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    grants_before = active_source_grants!(fixture.subscription.id)

    outer =
      run_auth_with_barrier!(context, fixture, barrier, fn effect ->
        assert effect.status == :required
        at_barrier_fn.(effect)
      end)

    assert {:ok, :processed} = outer
    assert reload_subscription!(fixture.subscription.id).status == :past_due
    assert_durable_f1_outcome!(fixture.subscription.id, outcome, grants_before: grants_before)
  end

  defp setup_f1_injection!(fixture, opts) do
    if Keyword.get(opts, :grant_block) do
      constraint = add_grant_block_constraint!(fixture.subscription.id)

      on_exit(fn ->
        Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT IF EXISTS #{constraint}")
      end)
    end

    if constraint = Keyword.get(opts, :constraint) do
      on_exit(fn ->
        Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
      end)
    end

    :ok
  end

  defp assert_durable_f1_outcome!(subscription_id, outcome, opts \\ []) do
    _grants_before = Keyword.get(opts, :grants_before, 0)
    [effect | _] = access_effects!(subscription_id)

    case outcome do
      :applied ->
        assert effect.status == :applied
        assert active_source_grants!(subscription_id) >= 1

      :projection_pending ->
        assert effect.status == :applied
        assert is_nil(effect.projection_delivered_at)
        assert is_list(effect.projection_user_ids)

      :superseded ->
        assert effect.status == :superseded
        assert Enum.any?(access_effects!(subscription_id), &(&1.id != effect.id))

      :noop ->
        assert effect.status == :applied
        assert length(access_effects!(subscription_id)) == 1

      :error ->
        assert effect.status in [:failed_retryable, :required, :failed]
        assert reload_subscription!(subscription_id).status == :past_due
    end
  end

  defp run_failure_with_barrier!(context, fixture, barrier, at_barrier_fn) do
    task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [effect] = access_effects!(subscription_id)
    at_barrier_fn.(effect)
    send(task.pid, {:jc247_release_keep_grace_sync, barrier})
    Task.await(task, @barrier_timeout)
  end

  defp run_auth_with_barrier!(context, fixture, barrier, at_barrier_fn) do
    run_failure_with_barrier!(context, fixture, barrier, at_barrier_fn)
  end

  defp attach_dunning_postcommit_barrier!(owner, barrier_ref, subscription_id) do
    handler_id = "jc247_dunning_barrier_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, %{subscription_id: sub_id}, config ->
          if sub_id == config.subscription_id do
            send(config.owner, {:jc247_postcommit_dunning, config.barrier_ref, sub_id})

            receive do
              {:jc247_release_keep_grace_sync, ref} when ref == config.barrier_ref -> :ok
            after
              @barrier_timeout -> raise "JC247 keep-grace sync barrier timed out"
            end
          end
        end,
        %{owner: owner, barrier_ref: barrier_ref, subscription_id: subscription_id}
      )

    handler_id
  end

  defp add_projection_pending_constraint! do
    constraint = "jc247mx_proj_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE access_effects
    ADD CONSTRAINT #{constraint}
    CHECK (projection_delivered_at IS NULL)
    NOT VALID
    """)

    on_exit(fn ->
      Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
    end)

    constraint
  end

  defp add_grant_block_constraint!(subscription_id) do
    constraint = "jc247mx_grant_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE entitlement_grants
    ADD CONSTRAINT #{constraint}
    CHECK (source_id <> '#{subscription_id}'::uuid OR status <> 'active')
    NOT VALID
    """)

    constraint
  end

  defp mark_effect_applied!(effect) do
    Repo.query!(
      "UPDATE access_effects SET status = 'applied' WHERE id = $1",
      [Ecto.UUID.dump!(effect.id)]
    )
  end

  defp queue_plan_change(customer, subscription_id, plan) do
    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: subscription_id,
               subscription_plan_id: plan.id
             })

    Facade.queue_subscription_plan_change_for_user(customer, subscription_id, input)
  end

  defp establish_newer_non_effective_effect!(subscription, attempt) do
    {:ok, %{rows: [[source_version]]}} =
      Repo.query(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
        [Ecto.UUID.dump!(subscription.id)]
      )

    current = reload_subscription!(subscription.id)

    attrs = %{
      subscription_id: current.id,
      source_version: source_version,
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: current.source_order_line_item_id,
      contract_change_id: current.current_contract_change_id,
      plan_revision_id: attempt.plan_revision_id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, _effect} = Facade.establish_access_effect_for_system(input)
  end

  defp create_contract_bound_due_fixture!(label) do
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD"
      })

    plan_x =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 4_700,
        currency: "EUR",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}-x"
      })

    plan_y =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 8_300,
        currency: "GBP",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}-y"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan_x.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan_y.id)
    SubscriptionsFixtures.create_plan_revision!(plan_x)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :microsecond),
        quantity: 1,
        provider_billing_ref: "pm_#{label}"
      })

    subscription = reload_subscription!(subscription.id)

    Repo.query!(
      "UPDATE subscriptions SET next_renewal_at = current_period_end_at WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    subscription = reload_subscription!(subscription.id)

    assert {:ok, input_x} =
             QueueSubscriptionPlanChangeInput.new(%{
               "subscription_id" => subscription.id,
               "subscription_plan_id" => plan_x.id
             })

    assert {:ok, queued_x} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, input_x)

    change_x = fetch_contract_change!(queued_x.current_contract_change_id)
    subscription = reload_subscription!(subscription.id)
    funded_revision_id = subscription.current_plan_revision_id

    assert subscription.current_contract_change_id == change_x.id
    assert change_x.status == :queued
    assert change_x.effective_at == subscription.current_period_end_at

    %{
      subscription: subscription,
      customer: customer,
      now: now,
      change_x: change_x,
      plan_y: plan_y,
      funded_revision_id: funded_revision_id,
      run: fn -> run_reached_fixture!(subscription.id, now, "canceled") end
    }
  end

  defp active_source_grants!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(
      expr(source_kind == :subscription and source_id == ^subscription_id and status == :active)
    )
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    |> length()
  end

  defp latest_effect!(subscription_id) do
    subscription_id
    |> access_effects!()
    |> Enum.max_by(& &1.source_version)
  end

  defp fetch_order!(id) do
    Order
    |> Ash.get!(id, domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp handoff_opts(handoff) do
    [
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    ]
  end

  defp latest_collection_for_attempt!(attempt_id) do
    Store.Subscriptions.RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.last()
    |> case do
      nil -> raise "no renewal collection for attempt #{attempt_id}"
      collection -> collection
    end
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
      subscription: subscription,
      customer: customer,
      now: now,
      run: fn -> run_reached_fixture!(subscription.id, now, "canceled") end
    }
  end

  defp run_reached_fixture!(subscription_id, now, status) do
    _reached = prepare_reached_observation!(subscription_id, now, status)
    Facade.process_due_subscription_renewal_for_system(subscription_id, now: now)
  end

  defp prepare_fixture_for_facade!(fixture, status) do
    _reached = prepare_reached_observation!(fixture.subscription.id, fixture.now, status)

    %{
      fixture
      | run: fn ->
          Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
            now: fixture.now
          )
        end
    }
  end

  defp prepare_reached_observation!(subscription_id, now, status) do
    StripeAPIStub.stub_unexpected!("legacy preparation must not contact Stripe")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription_id, now)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, status)
    )

    reached
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.get!(id, domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp snapshot_grant!(grant_id) do
    {:ok, %{rows: [row]}} =
      Repo.query(
        "SELECT status, valid_from_at, valid_to_at, revoked_at, revoked_reason FROM entitlement_grants WHERE id = $1",
        [Ecto.UUID.dump!(grant_id)]
      )

    row
  end

  defp fetch_effect!(id) do
    AccessEffect
    |> Ash.get!(id, domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effect_rows!(subscription_id) do
    {:ok, result} =
      Repo.query(
        """
        SELECT id::text, status, contract_change_id::text, plan_revision_id::text
        FROM access_effects
        WHERE subscription_id = $1
        ORDER BY source_version ASC
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    result.rows
    |> Enum.map(fn [id, status, contract_change_id, plan_revision_id] ->
      %{
        id: id,
        status: status,
        contract_change_id: contract_change_id,
        plan_revision_id: plan_revision_id
      }
    end)
  end

  defp set_updated_at!(effects, updated_at) do
    Enum.each(effects, fn effect ->
      Repo.query!("UPDATE access_effects SET updated_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(effect.id),
        updated_at
      ])
    end)
  end

  defp unique_label(label), do: "#{label}_#{Ecto.UUID.generate()}"

  defp db_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp reload_subscription!(id) do
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

  defp access_effects!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
