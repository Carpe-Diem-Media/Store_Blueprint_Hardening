defmodule Store.Subscriptions.Sbh3005DunningAdversarialBoundaryTest do
  use Store.DataCase, async: false

  alias Ash.Resource.Info
  alias Ash.Type.UUID, as: UUIDType

  import Ash.Expr
  require Ash.Query

  alias Store.Comms.EmailOutbox
  alias Store.Orders.Order
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Providers
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo

  alias Store.Subscriptions.{
    Facade,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.{
    ClaimDispatchInput,
    PaymentIntentBindingInput,
    ReservationGenerationInput,
    StartInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  @system_context %{system?: true}

  setup context do
    previous_payments = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("dunning adversarial tests must not submit provider mutations")

    on_exit(fn -> Application.put_env(:store, :payments, previous_payments) end)

    :ok
  end

  test "dunning renewal attempt identity is represented by a private nullable UUID" do
    attribute = Info.attribute(Subscription, :current_dunning_renewal_attempt_id)

    relationship = Info.relationship(Subscription, :current_dunning_renewal_attempt)

    assert attribute
    assert attribute.type == UUIDType
    assert attribute.allow_nil? == true
    assert attribute.public? == false

    assert relationship.destination == RenewalAttempt
    assert relationship.source_attribute == :current_dunning_renewal_attempt_id
    assert relationship.attribute_writable? == false
  end

  describe "retry timing" do
    # Invariant: due selection is false one microsecond before the persisted retry time, and true at and after it.
    # Mutation caught: changing the selector comparison from <= to < drops the exact-time retry.
    test "selects a retry before, at, and after its persisted timestamp" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!("jc240_retry_offsets", now,
          max_retry_attempts: 2,
          retry_schedule_hours: [1, 24],
          grace_period_days: 7
        )

      assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
      failed = fetch_subscription!(subscription.id)
      attempt = fetch_current_attempt!(subscription.id)
      assert failed.status == :past_due
      assert failed.current_dunning_renewal_attempt_id == attempt.id

      [keep_grace_effect] = access_effect_rows!(subscription.id)
      assert keep_grace_effect.disposition == "effective"
      effects_after_first_failure = access_effect_rows!(subscription.id)
      assert %DateTime{} = failed.next_retry_at
      retry_at = failed.next_retry_at
      assert retry_at == DateTime.add(now, 1, :hour)

      before_retry_at = DateTime.add(retry_at, -1, :microsecond)
      assert due_retry?(subscription.id, before_retry_at) == false

      assert {:ok, %{due_count: 0}} =
               Facade.run_due_renewals_for_system(now: before_retry_at, limit: 20)

      assert due_retry?(subscription.id, retry_at)
      assert due_retry?(subscription.id, DateTime.add(retry_at, 1, :microsecond))

      assert {:ok, %{due_count: 1, failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: retry_at, limit: 20)

      retried = fetch_subscription!(subscription.id)
      assert retried.status == :past_due
      assert retried.dunning_attempt_count == 2
      assert retried.current_dunning_renewal_attempt_id == attempt.id
      assert access_effect_rows!(subscription.id) == effects_after_first_failure
    end
  end

  describe "failed-payment boundary timing" do
    # Invariant: boundary selection excludes T-1µs and includes T and T+1µs; execution suspends only once.
    # Mutation caught: changing the boundary selector from <= to < drops the exact-time transition.
    test "selects the explicit boundary and suspends once at equality" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!("jc240_boundary_offsets", now,
          max_retry_attempts: 0,
          retry_schedule_hours: [0],
          grace_period_days: 0
        )

      assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
      past_due = fetch_subscription!(subscription.id)
      boundary_at = past_due.failed_payment_boundary_at

      assert boundary_at == now
      refute subscription.id in due_boundary_ids(DateTime.add(boundary_at, -1, :microsecond))
      assert subscription.id in due_boundary_ids(boundary_at)
      assert subscription.id in due_boundary_ids(DateTime.add(boundary_at, 1, :microsecond))

      assert {:ok, %{due_count: 0, suspended_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(
                 now: DateTime.add(boundary_at, -1, :microsecond),
                 limit: 20
               )

      assert fetch_subscription!(subscription.id).status == :past_due

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).status == :suspended

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(
                 now: DateTime.add(boundary_at, 1, :microsecond),
                 limit: 20
               )
    end
  end

  describe "provider checkpoint boundary" do
    # Invariant: equality with the persisted boundary is denied by the strict SQL comparator.
    # Mutation caught: changing the atomic claim predicate from < to <= permits dispatch at equality.
    test "provider claim SQL keeps the strict database-clock-before-boundary contract" do
      source = File.read!("lib/store/subscriptions/renewal_collection_attempts.ex")

      [_before_claim, claim_and_after] =
        String.split(source, "defp claim_collection_dispatch(", parts: 2)

      [claim_code, _after_claim] =
        String.split(claim_and_after, "defp collection_boundary_claim_allowed?", parts: 2)

      normalized = String.replace(claim_code, ~r/\s+/, " ")

      assert String.contains?(normalized, "clock_timestamp() < $5::timestamptz")
      refute String.contains?(normalized, "clock_timestamp() <= $5::timestamptz")
    end

    # Invariant: a retry strictly before its bound boundary creates one distinct exact collection.
    # Mutation caught: reusing the failed collection identity or assigning the retry to another attempt.
    test "a retry before the boundary starts one exact collection once" do
      occurrence =
        create_failed_then_inflight_occurrence!("jc240_preboundary_start",
          max_retry_attempts: 1,
          retry_schedule_hours: [0],
          grace_period_days: 7
        )

      failed = fetch_subscription!(occurrence.subscription.id)
      assert failed.status == :past_due
      assert failed.next_retry_at == occurrence.now

      assert DateTime.compare(
               occurrence.inflight_reached.now,
               failed.failed_payment_boundary_at
             ) == :lt

      assert occurrence.failed_collection.financial_outcome ==
               :verified_terminal_financial_non_success

      assert occurrence.inflight_collection.dispatch_state == :may_have_been_reached
      assert occurrence.inflight_collection.financial_outcome == :unresolved
      assert occurrence.failed_collection.id != occurrence.inflight_collection.id
      assert occurrence.failed_collection.renewal_attempt_id == occurrence.attempt.id
      assert occurrence.inflight_collection.renewal_attempt_id == occurrence.attempt.id
      assert occurrence.attempt.order_id == occurrence.order.id
      assert occurrence.inflight_reached.payment_intent.order_id == occurrence.order.id

      assert occurrence.inflight_reached.payment_intent.id ==
               occurrence.inflight_collection.payment_intent_id

      assert occurrence.inflight_reached.payment_intent.payment_intent_key ==
               RenewalCollectionAttempts.payment_intent_key(occurrence.inflight_collection.id)

      StripeAPIStub.stub_payment_observation(
        occurrence.inflight_reached.payment_intent.provider_payment_id,
        ReachedRenewalFixtures.observation_body(occurrence.inflight_reached, "processing")
      )

      for _ <- 1..2 do
        assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
                 Facade.process_due_subscription_renewal_for_system(occurrence.subscription.id,
                   now: occurrence.inflight_reached.now
                 )
      end

      assert [%RenewalCollectionAttempt{} = first, %RenewalCollectionAttempt{} = retry] =
               list_collections!(occurrence.attempt.id)

      assert first.id == occurrence.failed_collection.id
      assert retry.id == occurrence.inflight_collection.id
      assert retry.dispatch_state == :may_have_been_reached
    end

    # Invariant: the persisted retry intent cannot authorize dispatch after the live DB boundary is reached.
    # Mutation caught: removing the database-clock predicate admits a stale typed claim.
    test "a retry scheduled at boundary equality is denied after the live boundary advances" do
      assert_boundary_retry_denied!("jc240_at_boundary", 0)
    end

    # Invariant: a persisted boundary one microsecond behind the claim still prevents provider dispatch.
    # Mutation caught: removing the database-clock predicate admits a stale typed claim.
    test "a retry scheduled after boundary equality is denied after the live boundary advances" do
      assert_boundary_retry_denied!("jc240_after_boundary", 1)
    end

    # Invariant: a checkpointed collection remains reconcilable after suspension.
    # Mutation caught: starting a replacement collection creates a second provider mutation.
    test "a reached collection remains recoverable after the boundary" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!(
          "jc240_inflight_boundary",
          now,
          [max_retry_attempts: 2, retry_schedule_hours: [0, 24], grace_period_days: 7],
          %{provider_billing_ref: "pm_jc240_inflight"}
        )

      reached = prepare_legacy_collection!(subscription.id, now)
      attempt = fetch_current_attempt!(subscription.id)
      [collection] = list_collections!(attempt.id)
      assert collection.id == reached.collection.id
      assert collection.dispatch_state == :may_have_been_reached

      boundary_at = DateTime.add(db_now!(), -1, :second)

      StripeAPIStub.stub_payment_observation(
        reached.payment_intent.provider_payment_id,
        ReachedRenewalFixtures.observation_body(reached, "processing")
      )

      Repo.query!(
        "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, past_due_since_at = $2, failed_payment_boundary_at = $3, next_retry_at = NULL, retry_suppressed_at = $2 WHERE id = $1",
        [Ecto.UUID.dump!(subscription.id), DateTime.add(boundary_at, -7, :day), boundary_at]
      )

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert {:ok, recovered} =
               RenewalCollectionAttempts.recover_reached_for_subscription_for_system(
                 subscription.id,
                 boundary_at
               )

      assert recovered.collection_attempt.id == collection.id
      assert recovered.payment_intent.id == collection.payment_intent_id
      assert recovered.collection_attempt.dispatch_state == :may_have_been_reached
      assert length(list_collections!(attempt.id)) == 1
    end
  end

  describe "retry exhaustion composition" do
    # Invariant: exhausting the retry budget suppresses retries but preserves PAST_DUE and its bound boundary.
    # Mutation caught: converting exhaustion to SUSPENDED or EXPIRED, or clearing the independent boundary.
    test "exhausted PAST_DUE leaves retry selection and remains boundary-discoverable" do
      first_failure_at = DateTime.add(db_now!(), -30, :day)

      %{subscription: subscription} =
        create_due_subscription!("jc240_exhausted", first_failure_at,
          max_retry_attempts: 1,
          retry_schedule_hours: [0, 24],
          grace_period_days: 7
        )

      StripeAPIStub.stub_unexpected!("retry exhaustion must not reach Stripe")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure_at, limit: 20)

      first_failure = fetch_subscription!(subscription.id)
      attempt = fetch_current_attempt!(subscription.id)
      boundary_at = first_failure.failed_payment_boundary_at
      assert first_failure.status == :past_due
      assert first_failure.current_dunning_renewal_attempt_id == attempt.id
      assert first_failure.next_retry_at == first_failure_at
      assert DateTime.compare(first_failure.next_retry_at, boundary_at) == :lt

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure.next_retry_at, limit: 20)

      exhausted = fetch_subscription!(subscription.id)
      assert exhausted.status == :past_due
      assert exhausted.dunning_attempt_count == 2
      assert %DateTime{} = exhausted.retry_suppressed_at
      assert is_nil(exhausted.next_retry_at)
      assert exhausted.failed_payment_boundary_at == boundary_at
      assert exhausted.current_dunning_renewal_attempt_id == attempt.id
      refute due_retry?(subscription.id, boundary_at)
      assert subscription.id in due_boundary_ids(boundary_at)

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(subscription.id)
      assert suspended.status == :suspended
      assert suspended.current_dunning_renewal_attempt_id == attempt.id
      assert suspended.aggregate_version == exhausted.aggregate_version + 1

      effect = suspension_access_effect_row!(subscription.id)
      assert effect.source_version == suspended.aggregate_version
      assert effect.status == "required"
      assert effect.disposition == "non_effective"
      assert is_nil(effect.valid_from_at)
      effects_after_suspension = access_effect_rows!(subscription.id)
      suspended_version = suspended.aggregate_version

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).aggregate_version == suspended_version
      assert access_effect_rows!(subscription.id) == effects_after_suspension
    end

    # Invariant: max_retry_attempts=0 suppresses the first retry while preserving boundary discovery.
    # Mutation caught: allowing retry selection or removing the row from the failed-payment selector.
    test "zero retries reaches SUSPENDED through the independent boundary path" do
      first_failure_at = DateTime.add(db_now!(), -30, :day)

      %{subscription: subscription} =
        create_due_subscription!("jc240_zero_retry", first_failure_at,
          max_retry_attempts: 0,
          retry_schedule_hours: [0, 24],
          grace_period_days: 7
        )

      StripeAPIStub.stub_unexpected!("zero retry allowance must not reach Stripe")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure_at, limit: 20)

      exhausted = fetch_subscription!(subscription.id)
      attempt = fetch_current_attempt!(subscription.id)
      boundary_at = exhausted.failed_payment_boundary_at
      assert exhausted.status == :past_due
      assert exhausted.current_dunning_renewal_attempt_id == attempt.id
      assert exhausted.dunning_attempt_count == 1
      assert %DateTime{} = exhausted.retry_suppressed_at
      assert is_nil(exhausted.next_retry_at)
      refute due_retry?(subscription.id, boundary_at)
      assert subscription.id in due_boundary_ids(boundary_at)

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(subscription.id)
      assert suspended.status == :suspended
      assert suspended.current_dunning_renewal_attempt_id == attempt.id
      assert suspended.aggregate_version == exhausted.aggregate_version + 1
      effect = suspension_access_effect_row!(subscription.id)
      assert effect.source_version == suspended.aggregate_version
      assert effect.disposition == "non_effective"
      assert is_nil(effect.valid_from_at)

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).aggregate_version == suspended.aggregate_version
    end

    # Invariant: changing current Plan and PlanRevision after binding cannot alter the bound retry or boundary policy.
    # Mutation caught: reading retry count, retry offsets, grace, or access policy from the mutable current Plan.
    test "mutable Plan changes cannot rewrite a bound dunning episode" do
      first_failure_at = db_now!()

      %{subscription: subscription, plan: plan} =
        create_due_subscription!("jc240_bound_policy", first_failure_at,
          max_retry_attempts: 3,
          retry_schedule_hours: [2, 5, 72],
          grace_period_days: 7
        )

      StripeAPIStub.stub_unexpected!("missing current chargeability must not reach Stripe")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure_at, limit: 20)

      first_failure = fetch_subscription!(subscription.id)
      attempt = fetch_current_attempt!(subscription.id)
      boundary_at = first_failure.failed_payment_boundary_at
      assert first_failure.current_dunning_renewal_attempt_id == attempt.id
      assert attempt.charged_contract_snapshot["retry_schedule_hours"] == [2, 5, 72]
      assert attempt.charged_contract_snapshot["max_retry_attempts"] == 3
      assert attempt.charged_contract_snapshot["grace_period_days"] == 7
      assert attempt.charged_contract_snapshot["access_on_past_due"] == "keep_during_grace"
      assert first_failure.next_retry_at == DateTime.add(first_failure_at, 2, :hour)
      baseline_effects = access_effect_rows!(subscription.id)

      updated_plan =
        plan
        |> Ash.Changeset.for_update(
          :update,
          %{
            max_retry_attempts: 0,
            retry_schedule_hours: [0],
            grace_period_days: 0,
            access_on_past_due: :remove_immediately
          },
          context: @system_context
        )
        |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: @system_context)

      {:ok, old_revision} =
        PlanRevision.get_effective_for_plan(plan.id,
          authorize?: false,
          context: @system_context
        )

      assert {:ok, retired_revision} =
               old_revision
               |> Ash.Changeset.for_update(:retire, %{}, context: @system_context)
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: @system_context
               )

      assert retired_revision.status == :retired
      new_revision = SubscriptionsFixtures.create_plan_revision!(updated_plan)
      assert new_revision.id != attempt.plan_revision_id
      assert new_revision.status == :effective

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure.next_retry_at, limit: 20)

      after_retry = fetch_subscription!(subscription.id)
      assert after_retry.status == :past_due
      assert after_retry.current_dunning_renewal_attempt_id == attempt.id
      assert after_retry.dunning_attempt_count == 2
      assert after_retry.failed_payment_boundary_at == boundary_at
      assert after_retry.next_retry_at == DateTime.add(first_failure_at, 5, :hour)
      assert is_nil(after_retry.retry_suppressed_at)

      assert fetch_current_attempt!(subscription.id).charged_contract_snapshot ==
               attempt.charged_contract_snapshot

      assert updated_plan.access_on_past_due == :remove_immediately
      assert access_effect_rows!(subscription.id) == baseline_effects
    end
  end

  test "pointer-bearing past_due rejects activate_now while legacy null-pointer recovery remains valid" do
    occurrence = create_failed_then_inflight_occurrence!("jc247_activate_now_pointer")
    past_due = fetch_subscription!(occurrence.subscription.id)

    assert past_due.current_dunning_renewal_attempt_id == occurrence.attempt.id

    assert {:error, _reason} =
             past_due
             |> Ash.Changeset.for_update(:activate_now, %{}, context: @system_context)
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: @system_context
             )

    unchanged = fetch_subscription!(occurrence.subscription.id)
    assert unchanged.status == :past_due
    assert unchanged.current_dunning_renewal_attempt_id == occurrence.attempt.id

    Repo.query!(
      "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(occurrence.subscription.id)]
    )

    legacy = fetch_subscription!(occurrence.subscription.id)

    assert {:ok, recovered} =
             legacy
             |> Ash.Changeset.for_update(:activate_now, %{}, context: @system_context)
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: @system_context
             )

    assert recovered.status == :active
    assert is_nil(recovered.current_dunning_renewal_attempt_id)
  end

  test "cancel-now and expiry clear current dunning attempt identity" do
    for {label, action, target_status} <- [
          {"cancel", :cancel_now_transition, :canceled},
          {"expire", :mark_expired_transition, :expired}
        ] do
      occurrence = create_failed_then_inflight_occurrence!("jc247_terminal_#{label}")
      source = fetch_subscription!(occurrence.subscription.id)

      assert source.current_dunning_renewal_attempt_id == occurrence.attempt.id

      assert {:ok, terminal} =
               source
               |> Ash.Changeset.for_update(
                 action,
                 %{canceled_reason: "jc247_#{label}"},
                 context: @system_context
               )
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: @system_context
               )

      assert terminal.status == target_status
      assert is_nil(terminal.current_dunning_renewal_attempt_id)
    end
  end

  describe "success and failure ordering" do
    # Invariant: the last authorized retry may cross before the boundary and apply one exact paid period.
    # Mutation caught: suppressing the final allowed retry or reapplying the period/effect on boundary replay.
    test "final authorized retry succeeds before the boundary and makes the later sweep stale" do
      occurrence =
        create_failed_then_inflight_occurrence!("jc240_final_retry_success",
          max_retry_attempts: 1
        )

      failed = fetch_subscription!(occurrence.subscription.id)
      boundary_at = failed.failed_payment_boundary_at
      assert failed.status == :past_due
      assert failed.dunning_attempt_count == 1
      assert failed.next_retry_at == occurrence.now
      assert DateTime.compare(occurrence.now, boundary_at) == :lt
      assert occurrence.inflight_collection.dispatch_state == :may_have_been_reached

      mark_collection_successful!(occurrence.inflight_collection)

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.inflight_collection.id)

      before_success = fetch_subscription!(occurrence.subscription.id)
      assert before_success.current_dunning_renewal_attempt_id == occurrence.attempt.id

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      active = fetch_subscription!(occurrence.subscription.id)
      assert active.status == :active
      assert is_nil(active.current_dunning_renewal_attempt_id)
      assert active.current_period_start_at == occurrence.attempt.period_start_at
      assert active.current_period_end_at == occurrence.attempt.period_end_at
      assert active.aggregate_version == before_success.aggregate_version + 1
      assert active.dunning_attempt_count == 0
      assert is_nil(active.past_due_since_at)
      assert is_nil(active.failed_payment_boundary_at)
      assert is_nil(active.next_retry_at)
      assert is_nil(active.retry_suppressed_at)
      effects_after_success = access_effect_rows!(occurrence.subscription.id)

      assert Enum.count(effects_after_success, &(&1.source_version == active.aggregate_version)) <=
               1

      assert length(Enum.uniq_by(effects_after_success, & &1.source_version)) ==
               length(effects_after_success)

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      final = fetch_subscription!(occurrence.subscription.id)
      assert final.aggregate_version == active.aggregate_version
      assert final.current_period_end_at == active.current_period_end_at
      assert access_effect_rows!(occurrence.subscription.id) == effects_after_success
    end

    # Invariant: exact success recovers exhausted PAST_DUE once; replay leaves period and targets unchanged.
    # Mutation caught: retaining dunning state or applying the paid period/effect twice.
    test "exact success recovers exhausted PAST_DUE once and replay is inert" do
      occurrence = create_bound_occurrence!("jc240_exhausted_success")
      past_due_since_at = DateTime.add(occurrence.now, -6, :day)
      boundary_at = DateTime.add(past_due_since_at, 7, :day)

      exhausted =
        mark_past_due!(occurrence.subscription.id, %{
          billing_status_reason: "PAYMENT_FAILED",
          past_due_since_at: past_due_since_at,
          failed_payment_boundary_at: boundary_at,
          dunning_attempt_count: 4,
          next_retry_at: nil,
          retry_suppressed_at: occurrence.now
        })

      assert exhausted.status == :past_due
      assert boundary_at == DateTime.add(occurrence.now, 1, :day)
      refute due_retry?(occurrence.subscription.id, boundary_at)

      mark_collection_successful!(occurrence.collection)

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      recovered = fetch_subscription!(occurrence.subscription.id)
      assert recovered.status == :active
      assert recovered.current_period_start_at == occurrence.attempt.period_start_at
      assert recovered.current_period_end_at == occurrence.attempt.period_end_at
      assert recovered.dunning_attempt_count == 0
      assert is_nil(recovered.past_due_since_at)
      assert is_nil(recovered.failed_payment_boundary_at)
      assert is_nil(recovered.retry_suppressed_at)
      assert is_nil(recovered.next_retry_at)

      effects_after_recovery = access_effect_rows!(occurrence.subscription.id)

      assert Enum.count(
               effects_after_recovery,
               &(&1.source_version == recovered.aggregate_version)
             ) <= 1

      assert length(Enum.uniq_by(effects_after_recovery, & &1.source_version)) ==
               length(effects_after_recovery)

      assert Enum.count(effects_after_recovery, &(&1.disposition == "effective")) <= 1

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      replayed = fetch_subscription!(occurrence.subscription.id)
      assert replayed.aggregate_version == recovered.aggregate_version
      assert replayed.current_period_end_at == recovered.current_period_end_at
      assert access_effect_rows!(occurrence.subscription.id) == effects_after_recovery
    end

    # Invariant: exact current occurrence recovers PAST_DUE or SUSPENDED after failure evidence.
    # Mutation caught: rejecting an authorized same-occurrence success or recovering from another occurrence.
    test "late exact success recovers the same occurrence from PAST_DUE and SUSPENDED" do
      Enum.each([:past_due, :suspended], fn source_status ->
        occurrence = create_failed_then_inflight_occurrence!("jc240_late_#{source_status}")

        source =
          if source_status == :suspended do
            set_boundary_in_past!(occurrence.subscription.id, occurrence.now)

            assert {:ok, %{suspended_count: 1}} =
                     Facade.run_due_failed_payment_suspensions_for_system(
                       now: db_now!(),
                       limit: 20
                     )

            fetch_subscription!(occurrence.subscription.id)
          else
            fetch_subscription!(occurrence.subscription.id)
          end

        assert source.status == source_status
        assert occurrence.inflight_collection.renewal_attempt_id == occurrence.attempt.id

        mark_collection_successful!(occurrence.inflight_collection)

        {:ok, handoff} =
          RenewalCollectionAttempts.success_handoff_for_system(occurrence.inflight_collection.id)

        assert {:ok, :reconciled} =
                 Facade.reconcile_paid_subscription_renewal_for_system(
                   occurrence.order.id,
                   handoff_opts(handoff)
                 )

        recovered = fetch_subscription!(occurrence.subscription.id)
        assert recovered.status == :active
        assert recovered.current_period_start_at == occurrence.attempt.period_start_at
        assert recovered.current_period_end_at == occurrence.attempt.period_end_at
        assert is_nil(recovered.past_due_since_at)
        assert is_nil(recovered.failed_payment_boundary_at)
        assert is_nil(recovered.retry_suppressed_at)
        assert is_nil(recovered.next_retry_at)
        assert fetch_current_attempt!(occurrence.subscription.id).id == occurrence.attempt.id
      end)
    end

    # Invariant: authoritative success cannot be regressed by later failure evidence.
    # Mutation caught: applying stale failure after success moves the Subscription back into dunning.
    test "success first keeps stale failure observation from regressing dunning or access" do
      occurrence = create_bound_occurrence!("jc240_success_first")
      mark_collection_successful!(occurrence.collection)

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      active = fetch_subscription!(occurrence.subscription.id)
      active_effects = access_effect_rows!(occurrence.subscription.id)
      payment_intent = fetch_payment_intent!(occurrence.collection.payment_intent_id)
      _late_failure = record_failure_observation!(payment_intent, db_now!())

      assert {:ok, %{due_count: 0, suspended_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(
                 now: DateTime.add(occurrence.attempt.period_end_at, 30, :day),
                 limit: 20
               )

      unchanged = fetch_subscription!(occurrence.subscription.id)
      assert unchanged.status == :active
      assert unchanged.aggregate_version == active.aggregate_version
      assert is_nil(unchanged.failed_payment_boundary_at)
      assert is_nil(unchanged.past_due_since_at)
      assert is_nil(unchanged.retry_suppressed_at)
      assert is_nil(unchanged.next_retry_at)
      assert access_effect_rows!(occurrence.subscription.id) == active_effects

      assert Enum.all?(
               list_collections!(occurrence.attempt.id),
               &(&1.id == occurrence.collection.id)
             )

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      assert fetch_subscription!(occurrence.subscription.id).aggregate_version ==
               active.aggregate_version
    end

    # Invariant: replay for one failed collection identity cannot multiply dunning or communications.
    # Mutation caught: applying the same collection failure twice increments retry count or creates another effect row.
    test "duplicate failure observation leaves dunning, retry, access, and outbox evidence unchanged" do
      occurrence = create_failed_then_inflight_occurrence!("jc240_duplicate_failure")
      before = fetch_subscription!(occurrence.subscription.id)
      assert before.current_dunning_renewal_attempt_id == occurrence.attempt.id
      before_effects = access_effect_rows!(occurrence.subscription.id)
      before_outbox_count = email_outbox_count(occurrence.subscription.id)
      before_collections = Enum.map(list_collections!(occurrence.attempt.id), & &1.id)
      first_payment_intent = fetch_payment_intent!(occurrence.failed_collection.payment_intent_id)

      _replayed_observation = record_failure_observation!(first_payment_intent, db_now!())

      after_replay = fetch_subscription!(occurrence.subscription.id)
      assert after_replay.status == before.status
      assert after_replay.dunning_attempt_count == before.dunning_attempt_count
      assert after_replay.next_retry_at == before.next_retry_at
      assert after_replay.retry_suppressed_at == before.retry_suppressed_at
      assert after_replay.failed_payment_boundary_at == before.failed_payment_boundary_at

      assert after_replay.current_dunning_renewal_attempt_id ==
               before.current_dunning_renewal_attempt_id

      assert after_replay.aggregate_version == before.aggregate_version
      assert access_effect_rows!(occurrence.subscription.id) == before_effects
      assert email_outbox_count(occurrence.subscription.id) == before_outbox_count
      assert Enum.map(list_collections!(occurrence.attempt.id), & &1.id) == before_collections
      assert fetch_current_attempt!(occurrence.subscription.id).id == occurrence.attempt.id
    end
  end

  describe "terminal guards and access target ordering" do
    # Invariant: CANCELED and EXPIRED cannot use same-occurrence success to recover suspension.
    # Mutation caught: admitting SUSPENDED recovery from either terminal state.
    test "terminal subscriptions stay terminal after exact payment success" do
      Enum.each([:canceled, :expired], fn terminal_status ->
        occurrence = create_bound_occurrence!("jc240_terminal_#{terminal_status}")
        set_boundary_in_past!(occurrence.subscription.id, occurrence.now)

        assert {:ok, %{suspended_count: 1}} =
                 Facade.run_due_failed_payment_suspensions_for_system(now: db_now!(), limit: 20)

        suspended = fetch_subscription!(occurrence.subscription.id)

        transition =
          if terminal_status == :canceled,
            do: :cancel_now_transition,
            else: :mark_expired_transition

        assert {:ok, _terminal} =
                 suspended
                 |> Ash.Changeset.for_update(transition, %{}, context: @system_context)
                 |> Ash.update(
                   domain: Store.Subscriptions,
                   authorize?: false,
                   context: @system_context
                 )

        mark_collection_successful!(occurrence.collection)

        {:ok, handoff} =
          RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

        result =
          Facade.reconcile_paid_subscription_renewal_for_system(
            occurrence.order.id,
            handoff_opts(handoff)
          )

        assert fetch_subscription!(occurrence.subscription.id).status == terminal_status
        assert fetch_current_attempt!(occurrence.subscription.id).status != :succeeded

        assert Enum.all?(
                 access_effect_rows!(occurrence.subscription.id),
                 &(&1.disposition == "non_effective")
               )

        assert match?({:ok, :noop}, result) or match?({:error, _}, result)
      end)
    end

    # Invariant: suspension target N is superseded by an effective recovery target at N+1.
    # Mutation caught: reusing N for recovery or allowing the older suspension effect to become current again.
    test "suspension and recovery AccessEffect versions increase monotonically" do
      occurrence = create_bound_occurrence!("jc240_access_order")
      boundary_at = set_boundary_in_past!(occurrence.subscription.id, occurrence.now)

      assert {:ok, %{suspended_count: 1}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(occurrence.subscription.id)
      [suspension_effect] = access_effect_rows!(occurrence.subscription.id)
      assert suspension_effect.source_version == suspended.aggregate_version
      assert suspension_effect.disposition == "non_effective"

      mark_collection_successful!(occurrence.collection)

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      active = fetch_subscription!(occurrence.subscription.id)
      effects = access_effect_rows!(occurrence.subscription.id)
      assert active.status == :active
      assert active.aggregate_version == suspended.aggregate_version + 1
      assert length(effects) == 2
      [recovery_effect, old_effect] = Enum.sort_by(effects, & &1.source_version, :desc)
      assert recovery_effect.source_version == suspension_effect.source_version + 1
      assert recovery_effect.source_version == active.aggregate_version
      assert recovery_effect.status == "applied"
      assert recovery_effect.disposition == "effective"

      assert recovery_effect.valid_from_at ==
               DateTime.to_naive(occurrence.attempt.period_start_at)

      assert recovery_effect.valid_until_at == DateTime.to_naive(active.current_period_end_at)

      assert old_effect.source_version == suspension_effect.source_version
      assert old_effect.status == "superseded"
      assert old_effect.disposition == "non_effective"
      assert is_nil(old_effect.valid_from_at)
      assert Enum.count(effects, &(&1.disposition == "effective")) == 1
    end
  end

  describe "occurrence and boundary concurrency" do
    # Invariant: success evidence from an older RenewalAttempt cannot recover a newer suspended episode.
    # Mutation caught: any paid occurrence for the Subscription reactivates its current suspended episode.
    test "success from a different occurrence cannot recover the current suspension" do
      old_occurrence = create_bound_occurrence!("jc240_different_occurrence")
      mark_collection_successful!(old_occurrence.collection)

      {:ok, old_handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(old_occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 old_occurrence.order.id,
                 handoff_opts(old_handoff)
               )

      next_period_at = old_occurrence.attempt.period_end_at

      new_reached =
        prepare_legacy_collection!(old_occurrence.subscription.id, next_period_at)

      assert :ok == apply_dunning_failure!(new_reached.collection, next_period_at)

      new_attempt = fetch_current_attempt!(old_occurrence.subscription.id)
      assert new_attempt.id != old_occurrence.attempt.id
      assert new_attempt.renewal_key != old_occurrence.attempt.renewal_key
      assert new_reached.collection.id != old_occurrence.collection.id
      assert new_reached.payment_intent.id == new_reached.collection.payment_intent_id
      assert new_reached.attempt.order_id == new_reached.order.id

      boundary_at = set_boundary_in_past!(old_occurrence.subscription.id, next_period_at)

      assert {:ok, %{suspended_count: 1}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(old_occurrence.subscription.id)
      effects_before_replay = access_effect_rows!(old_occurrence.subscription.id)
      assert suspended.status == :suspended
      assert hd(effects_before_replay).disposition == "non_effective"

      _same_old_success_replay =
        mark_collection_successful!(old_occurrence.collection)

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 old_occurrence.order.id,
                 handoff_opts(old_handoff)
               )

      unchanged = fetch_subscription!(old_occurrence.subscription.id)
      assert unchanged.status == :suspended
      assert unchanged.aggregate_version == suspended.aggregate_version
      assert access_effect_rows!(old_occurrence.subscription.id) == effects_before_replay

      refute Enum.any?(
               effects_before_replay,
               &(&1.status == "required" and &1.disposition == "effective")
             )
    end

    # Invariant: competing boundary runs serialize to one suspension version and one current non-effective target.
    # Mutation caught: allowing two transactions to commit a suspension or duplicate AccessEffect targets.
    test "competing boundary runs commit one suspension transition" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!("jc240_boundary_race", now,
          max_retry_attempts: 0,
          retry_schedule_hours: [0],
          grace_period_days: 0
        )

      StripeAPIStub.stub_unexpected!("boundary suspension must not call a payment provider")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: now, limit: 20)

      past_due = fetch_subscription!(subscription.id)
      boundary_at = past_due.failed_payment_boundary_at
      assert boundary_at == now
      parent = self()

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            send(parent, {:jc240_boundary_waiting, index, self()})

            receive do
              :jc240_run_boundary ->
                Facade.run_due_failed_payment_suspensions_for_system(
                  now: boundary_at,
                  limit: 20
                )
            after
              5_000 -> {:error, :boundary_barrier_timeout}
            end
          end)
        end

      waiting =
        for _ <- 1..2 do
          assert_receive {:jc240_boundary_waiting, index, pid}, 5_000
          {index, pid}
        end

      assert Enum.map(waiting, &elem(&1, 0)) |> Enum.sort() == [1, 2]
      Enum.each(waiting, fn {_index, pid} -> send(pid, :jc240_run_boundary) end)
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Enum.sum(Enum.map(results, fn {:ok, result} -> result.suspended_count end)) == 1

      suspended = fetch_subscription!(subscription.id)
      assert suspended.status == :suspended
      assert suspended.aggregate_version == past_due.aggregate_version + 1
      effect = suspension_access_effect_row!(subscription.id)
      assert effect.source_version == suspended.aggregate_version
      assert effect.disposition == "non_effective"

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).aggregate_version == suspended.aggregate_version
      assert suspension_access_effect_row!(subscription.id) == effect
    end
  end

  defp create_bound_occurrence!(label) do
    now = db_now!()

    %{subscription: subscription} =
      create_due_subscription!(
        label,
        now,
        [max_retry_attempts: 3, retry_schedule_hours: [0, 24, 72], grace_period_days: 7],
        %{provider_billing_ref: "pm_#{label}"}
      )

    reached = prepare_legacy_collection!(subscription.id, now)
    attempt = reached.attempt
    collection = reached.collection
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert collection.renewal_attempt_id == attempt.id
    assert reached.payment_intent.order_id == reached.order.id

    %{
      now: now,
      subscription: subscription,
      attempt: attempt,
      order: reached.order,
      collection: collection,
      payment_intent: reached.payment_intent,
      reached: reached
    }
  end

  defp create_failed_then_inflight_occurrence!(label, plan_overrides \\ []) do
    now = db_now!()

    %{subscription: subscription} =
      create_due_subscription!(
        label,
        now,
        Keyword.merge(
          [max_retry_attempts: 3, retry_schedule_hours: [0, 24, 72], grace_period_days: 7],
          plan_overrides
        ),
        %{provider_billing_ref: "pm_#{label}"}
      )

    failed_collection = prepare_legacy_collection!(subscription.id, now)
    assert :ok == apply_dunning_failure!(failed_collection.collection, now)

    first_failure = fetch_subscription!(subscription.id)
    assert first_failure.status == :past_due
    retry_at = first_failure.next_retry_at
    assert %DateTime{} = retry_at

    retry_reached = prepare_legacy_collection!(subscription.id, retry_at)

    attempt = fetch_current_attempt!(subscription.id)
    assert length(list_collections!(attempt.id)) == 2
    [failed, inflight_collection] = list_collections!(attempt.id)
    assert failed.id == failed_collection.collection.id
    assert failed.dispatch_state == :may_have_been_reached
    assert inflight_collection.dispatch_state == :may_have_been_reached
    assert inflight_collection.financial_outcome == :unresolved
    assert inflight_collection.id == retry_reached.collection.id
    assert inflight_collection.payment_intent_id == retry_reached.payment_intent.id
    assert retry_reached.attempt.id == attempt.id
    assert retry_reached.attempt.order_id == retry_reached.order.id

    %{
      now: now,
      subscription: subscription,
      attempt: attempt,
      order: retry_reached.order,
      failed_collection: failed,
      inflight_collection: inflight_collection,
      failed_reached: failed_collection,
      inflight_reached: retry_reached
    }
  end

  defp mark_collection_successful!(collection) do
    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    reached = %{
      payment_intent: payment_intent,
      order: fetch_order!(payment_intent.order_id),
      attempt: fetch_attempt!(collection.renewal_attempt_id)
    }

    observed = observe_reached!(reached, "succeeded")

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

    assert outcome in [:authoritative_success, :already_applied_success]
    updated_collection = fetch_collection!(collection.id)

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated_collection.payment_attempt_id,
                 payment_intent_id: collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )

    updated_collection
  end

  defp prepare_legacy_collection!(subscription_id, now) do
    StripeAPIStub.stub_unexpected!("legacy preparation must not contact Stripe")
    ReachedRenewalFixtures.prepare_reached!(subscription_id, now)
  end

  defp observe_reached!(reached, status) do
    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, status)
    )

    assert {:ok, observed} =
             Store.Payments.Facade.observe_payment_intent_for_system(%ObservePaymentIntentInput{
               payment_intent_id: reached.payment_intent.id
             })

    observed
  end

  defp apply_dunning_failure!(collection, now) do
    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    reached = %{
      payment_intent: payment_intent,
      order: fetch_order!(payment_intent.order_id),
      attempt: fetch_attempt!(collection.renewal_attempt_id)
    }

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "canceled")
    )

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(
               reached.attempt.subscription_id,
               now: now
             )

    assert fetch_collection!(collection.id).financial_outcome ==
             :verified_terminal_financial_non_success

    :ok
  end

  defp record_failure_observation!(payment_intent, observed_at) do
    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: payment_intent.provider_payment_id,
      provider_reference_kind: :payment_intent,
      provider_transaction_id: payment_intent.provider_payment_id,
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :failure_observation,
      raw_provider_status: "canceled",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: observed_at
    }

    Store.Payments.record_and_apply_payment_observation_for_system(payment_intent, observation)
  end

  defp mark_past_due!(subscription_id, attrs) do
    subscription = fetch_subscription!(subscription_id)

    subscription
    |> Ash.Changeset.for_update(:mark_past_due_transition, attrs, context: @system_context)
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp set_boundary_in_past!(subscription_id, _business_now) do
    boundary_at = DateTime.add(db_now!(), -1, :second)
    past_due_since_at = DateTime.add(boundary_at, -7, :day)
    retry_suppressed_at = db_now!()

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, past_due_since_at = $2, failed_payment_boundary_at = $3, next_retry_at = NULL, retry_suppressed_at = $4 WHERE id = $1",
      [
        Ecto.UUID.dump!(subscription_id),
        past_due_since_at,
        boundary_at,
        retry_suppressed_at
      ]
    )

    boundary_at
  end

  defp suspension_access_effect_row!(subscription_id) do
    case Enum.find(access_effect_rows!(subscription_id), &(&1.disposition == "non_effective")) do
      %{} = effect -> effect
      nil -> flunk("expected suspension AccessEffect for subscription #{subscription_id}")
    end
  end

  defp access_effect_rows!(subscription_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT source_version, status::text, disposition::text, valid_from_at, valid_until_at FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC",
        [Ecto.UUID.dump!(subscription_id)]
      )

    Enum.map(rows, fn [source_version, status, disposition, valid_from_at, valid_until_at] ->
      %{
        source_version: source_version,
        status: status,
        disposition: disposition,
        valid_from_at: valid_from_at,
        valid_until_at: valid_until_at
      }
    end)
  end

  defp email_outbox_count(subscription_id) do
    EmailOutbox
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.count!(domain: Store.Comms, authorize?: false, context: @system_context)
  end

  defp handoff_opts(handoff) do
    [
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    ]
  end

  defp create_due_subscription!(label, now, plan_overrides, subscription_overrides \\ %{}) do
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(
        Map.merge(
          %{
            interval_unit: :day,
            interval_count: 1,
            retry_schedule_hours: [0, 24, 72],
            max_retry_attempts: 3,
            grace_period_days: 7,
            entitlement_kind: :membership_access,
            entitlement_scope_key: "membership:#{label}"
          },
          Map.new(plan_overrides)
        )
      )

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    started_at = DateTime.add(now, -86_400, :second)

    fixture_overrides =
      Map.merge(
        %{started_at: started_at, next_renewal_at: DateTime.add(now, -1, :microsecond)},
        subscription_overrides
      )

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(
        customer.id,
        variant,
        plan,
        fixture_overrides
      )

    %{subscription: subscription, customer: customer, variant: variant, plan: plan}
  end

  defp due_retry?(subscription_id, now) do
    assert {:ok, jobs} = Facade.list_due_renewal_jobs_for_system(now: now, limit: 100)
    Enum.any?(jobs, &(&1.subscription_id == subscription_id))
  end

  defp assert_boundary_retry_denied!(label, offset_microseconds) do
    origin = DateTime.add(db_now!(), -30 * 86_400, :second)

    %{subscription: subscription} =
      create_due_subscription!(
        label,
        origin,
        [max_retry_attempts: 1, retry_schedule_hours: [0], grace_period_days: 0],
        %{provider_billing_ref: "pm_#{label}"}
      )

    first_reached = prepare_legacy_collection!(subscription.id, origin)
    assert :ok == apply_dunning_failure!(first_reached.collection, origin)

    failed = fetch_subscription!(subscription.id)
    original_boundary_at = failed.failed_payment_boundary_at
    retry_at = failed.next_retry_at
    assert retry_at == original_boundary_at
    assert failed.retry_suppressed_at == nil
    attempt = fetch_current_attempt!(subscription.id)
    order = fetch_order!(attempt.order_id)
    retry_collection = start_retry_collection!(attempt, retry_at)
    retry_intent = create_collection_payment_intent!(retry_collection, order, attempt)

    assert {:ok, %{collection_attempt: bound_collection}} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: retry_collection.id,
                 payment_intent_id: retry_intent.id
               }
             )

    assert bound_collection.dispatch_state == :not_started

    retry_now = DateTime.add(retry_at, offset_microseconds, :microsecond)
    assert due_retry?(subscription.id, retry_now)

    boundary_at = persist_boundary_at_claim_seam!(subscription.id, offset_microseconds)
    assert DateTime.compare(retry_now, boundary_at) == :lt

    assert {:ok, generation_result} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(
               %ReservationGenerationInput{
                 collection_attempt_id: retry_collection.id,
                 now: retry_now
               }
             )

    retry_collection = generation_result

    assert {:error,
            %{
              code: "RENEWAL_AUTHORITY_WITHDRAWN",
              message:
                "Subscription authority was withdrawn at the provider submission checkpoint"
            }} =
             RenewalCollectionAttempts.claim_dispatch_for_system(%ClaimDispatchInput{
               collection_attempt_id: retry_collection.id,
               expected_epoch: retry_collection.dispatch_epoch,
               now: retry_now
             })

    persisted_retry = fetch_collection!(retry_collection.id)
    assert persisted_retry.dispatch_state == :not_started
    assert persisted_retry.payment_intent_id == retry_intent.id
    assert persisted_retry.reservation_generation_id == retry_collection.reservation_generation_id
    assert persisted_retry.renewal_attempt_id == attempt.id
    assert attempt.order_id == order.id
    assert retry_intent.order_id == order.id

    assert retry_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(retry_collection.id)

    assert fetch_collection!(first_reached.collection.id).financial_outcome ==
             :verified_terminal_financial_non_success

    after_claim = fetch_subscription!(subscription.id)
    assert after_claim.current_dunning_renewal_attempt_id == attempt.id
    assert after_claim.failed_payment_boundary_at == boundary_at
    assert after_claim.next_retry_at == retry_at

    [first_collection, denied_collection] = list_collections!(attempt.id)
    assert first_collection.dispatch_state == :may_have_been_reached
    assert denied_collection.id == retry_collection.id
    assert denied_collection.payment_intent_id == retry_intent.id
    assert denied_collection.dispatch_state == :not_started

    assert denied_collection.reservation_generation_id ==
             retry_collection.reservation_generation_id

    assert fetch_subscription!(subscription.id).failed_payment_boundary_at == boundary_at
    assert length(list_collections!(attempt.id)) == 2
  end

  defp start_retry_collection!(attempt, now) do
    assert {:ok, input} =
             StartInput.new(%{
               renewal_attempt_id: attempt.id,
               now: now
             })

    assert {:ok, collection} = RenewalCollectionAttempts.start_for_system(input)
    collection
  end

  defp create_collection_payment_intent!(collection, order, attempt) do
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, provider_request_reference} =
             Providers.renewal_collection_request_reference(subscription.provider, collection.id)

    assert {:ok, result} =
             Store.Payments.create_or_reuse_payment_intent(
               %{
                 order_id: order.id,
                 amount_received_minor: order.grand_total_minor,
                 currency: attempt.currency,
                 provider: subscription.provider,
                 payment_intent_key: RenewalCollectionAttempts.payment_intent_key(collection.id),
                 provider_request_reference: provider_request_reference
               },
               context: @system_context
             )

    result.payment_intent
  end

  defp persist_boundary_at_claim_seam!(subscription_id, 0) do
    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() WHERE id = $1",
      [Ecto.UUID.dump!(subscription_id)]
    )

    fetch_subscription!(subscription_id).failed_payment_boundary_at
  end

  defp persist_boundary_at_claim_seam!(subscription_id, 1) do
    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 microsecond' WHERE id = $1",
      [Ecto.UUID.dump!(subscription_id)]
    )

    fetch_subscription!(subscription_id).failed_payment_boundary_at
  end

  defp due_boundary_ids(now) do
    Subscription
    |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{now: now, limit: 100})
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> Enum.map(& &1.id)
  end

  defp db_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp fetch_attempt!(id) do
    Ash.get!(RenewalAttempt, id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: @system_context
    )
  end

  defp fetch_current_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp list_collections!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> Enum.sort_by(& &1.collection_ordinal)
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: @system_context)
  end

  defp fetch_collection!(id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp fetch_order!(id) do
    Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: @system_context)
  end

  defp unique_label(label), do: "#{label}_#{System.unique_integer([:positive])}"
end
