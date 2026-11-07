defmodule Store.Subscriptions.Sbh1005ChargedContractReconciliationTest do
  use Store.DataCase, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent

  alias Store.Subscriptions.{
    AccessEffect,
    ContractChange,
    Facade,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription,
    SubscriptionItem
  }

  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a successful bound renewal applies the exact charged contract" do
    fixture = charged_bound_renewal!("sbh_10_05_exact", quantity: 3)

    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      revision: revision,
      contract_change: contract_change,
      collection: collection
    } = fixture

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    assert handoff.order_id == order.id
    assert handoff.renewal_attempt_id == attempt.id
    assert handoff.collection_attempt_id == collection.id

    before = fetch_subscription!(subscription.id)
    assert attempt.plan_revision_id == revision.id
    assert attempt.quantity == 3
    assert attempt.amount_minor == contract_change.target_amount_minor
    assert attempt.currency == contract_change.target_currency
    assert contract_change.status == :bound_to_renewal

    decoy_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 5,
        amount_minor: 2_700,
        currency: "GBP"
      })

    %{variant: decoy_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    # Mutable current projections must not replace the contract charged by this
    # occurrence. Future-target projections remain empty here.
    Store.Repo.query!(
      "UPDATE subscriptions SET subscription_plan_id = $1, variant_id = $2, renewal_amount_minor = 17, renewal_currency = 'CAD', quantity = 9 WHERE id = $3",
      [
        Ecto.UUID.dump!(decoy_plan.id),
        Ecto.UUID.dump!(decoy_variant.id),
        Ecto.UUID.dump!(subscription.id)
      ]
    )

    Store.Repo.query!(
      "UPDATE subscription_plans SET entitlement_kind = 'membership_access', entitlement_scope_key = 'platinum' WHERE id = $1",
      [Ecto.UUID.dump!(revision.subscription_plan_id)]
    )

    {result, stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-230 first charged application query_count=#{stats.query_count}")
    assert stats.query_count > 0
    assert {:ok, :reconciled} = result

    applied = fetch_subscription!(subscription.id)
    assert applied.current_plan_revision_id == revision.id
    assert applied.subscription_plan_id == revision.subscription_plan_id
    assert applied.variant_id == attempt.variant_id
    assert applied.quantity == attempt.quantity
    assert applied.renewal_amount_minor == attempt.amount_minor
    assert applied.renewal_currency == attempt.currency
    assert applied.current_period_start_at == attempt.period_start_at
    assert applied.current_period_end_at == attempt.period_end_at
    assert applied.membership_key == revision.entitlement_scope_key

    assert [%EntitlementGrant{kind: :membership_access, scope_key: "gold", status: :active}] =
             active_grants_for(subscription.id)

    assert applied.aggregate_version == before.aggregate_version + 1
    assert fetch_contract_change!(contract_change.id).status == :applied
    assert fetch_attempt!(attempt.id).status == :succeeded

    [renewal_effect] = access_effect_records!(subscription.id)
    assert renewal_effect.disposition == :effective
    assert renewal_effect.status == :applied
    assert renewal_effect.source_version == applied.aggregate_version
    assert datetime_equal?(renewal_effect.valid_from_at, attempt.period_start_at)
    assert datetime_equal?(renewal_effect.valid_until_at, attempt.period_end_at)
    assert renewal_effect.plan_revision_id == attempt.plan_revision_id

    assert [%EntitlementGrant{} = grant] = active_grants_for(subscription.id)
    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at
  end

  test "an ordinary charged renewal executes its exact EFFECTIVE effect through F1",
       %{sandbox_owners: sandbox_owners} do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      collection: collection
    } = charged_bound_renewal!("jc245_ordinary_effective_predecessor")

    current_revision =
      read_one!(PlanRevision, subscription.current_plan_revision_id, Store.Subscriptions)

    charged_revision = read_one!(PlanRevision, attempt.plan_revision_id, Store.Subscriptions)

    predecessor_attrs = %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: :effective,
      entitlement_kind: current_revision.entitlement_kind,
      entitlement_scope_key: current_revision.entitlement_scope_key,
      valid_from_at:
        if(
          is_nil(current_revision.entitlement_kind) and
            is_nil(current_revision.entitlement_scope_key),
          do: nil,
          else: subscription.current_period_start_at
        ),
      valid_until_at: subscription.current_period_end_at,
      source_order_line_item_id: subscription.source_order_line_item_id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: current_revision.id
    }

    assert {:ok, predecessor_input} = EstablishAccessEffectInput.new(predecessor_attrs)
    assert {:ok, predecessor} = Facade.establish_access_effect_for_system(predecessor_input)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    {result, calls} =
      trace_renewal_writer_calls(
        fn ->
          Facade.reconcile_paid_subscription_renewal_for_system(
            order.id,
            handoff_opts(handoff)
          )
        end,
        sandbox_owners
      )

    assert result == {:ok, :reconciled}

    [persisted_predecessor, renewal_effect] = access_effect_records!(subscription.id)
    assert persisted_predecessor.id == predecessor.id
    assert persisted_predecessor.disposition == :effective
    assert persisted_predecessor.status == :superseded
    assert renewal_effect.disposition == :effective
    assert renewal_effect.status == :applied
    assert renewal_effect.valid_from_at == attempt.period_start_at
    assert renewal_effect.valid_until_at == attempt.period_end_at
    assert fetch_attempt!(attempt.id).status == :succeeded

    assert [%EntitlementGrant{status: :active} = grant] = active_grants_for(subscription.id)
    assert grant.kind == charged_revision.entitlement_kind
    assert grant.scope_key == charged_revision.entitlement_scope_key
    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at

    assert Enum.filter(calls, &(&1.module == EntitlementsFacade)) == []

    subscription_after_first = fetch_subscription!(subscription.id)
    grant_id = grant.id

    {replay_result, replay_calls} =
      trace_renewal_writer_calls(
        fn ->
          Facade.reconcile_paid_subscription_renewal_for_system(
            order.id,
            handoff_opts(handoff)
          )
        end,
        sandbox_owners
      )

    assert replay_result == {:ok, :noop}
    assert Enum.filter(replay_calls, &(&1.module == EntitlementsFacade)) == []

    subscription_after_replay = fetch_subscription!(subscription.id)

    assert subscription_after_replay.current_period_start_at ==
             subscription_after_first.current_period_start_at

    assert subscription_after_replay.current_period_end_at ==
             subscription_after_first.current_period_end_at

    assert subscription_after_replay.current_plan_revision_id ==
             subscription_after_first.current_plan_revision_id

    assert fetch_attempt!(attempt.id).id == attempt.id
    assert length(access_effect_records!(subscription.id)) == 2

    assert [%EntitlementGrant{id: ^grant_id} = replayed_grant] =
             active_grants_for(subscription.id)

    assert replayed_grant.valid_from_at == attempt.period_start_at
    assert replayed_grant.valid_to_at == attempt.period_end_at
  end

  test "initial paid activation applies its exact EFFECTIVE AccessEffect through F1",
       %{sandbox_owners: sandbox_owners} do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_05_initial_activation")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:initial"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order, line_item: line_item, revision: purchased_revision} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan
      )

    {result, calls} =
      trace_initial_paid_entitlement_call(
        fn -> Facade.create_subscriptions_from_paid_order_for_system(order.id) end,
        sandbox_owners
      )

    assert {:ok, activation} = result
    assert calls == []

    assert Enum.sort(Map.keys(activation)) ==
             Enum.sort([
               :order_id,
               :subscription_line_count,
               :created_count,
               :skipped_count,
               :entitlement_issued_count
             ])

    assert is_binary(activation.order_id)
    assert activation.created_count == 1
    assert activation.skipped_count == 0
    assert activation.subscription_line_count == 1
    assert activation.entitlement_issued_count == 1

    assert Enum.all?(
             [
               activation.subscription_line_count,
               activation.created_count,
               activation.skipped_count,
               activation.entitlement_issued_count
             ],
             &is_integer/1
           )

    assert activation.order_id == order.id

    persisted_line_item = read_one!(OrderLineItem, line_item.id, Store.Orders)
    persisted_revision = read_one!(PlanRevision, purchased_revision.id, Store.Subscriptions)

    assert persisted_line_item.order_id == order.id
    assert persisted_line_item.subscription_plan_revision_id_snapshot == persisted_revision.id
    assert persisted_revision.subscription_plan_id == plan.id

    assert [%Subscription{} = activated_subscription] =
             Subscription
             |> Ash.Query.filter(expr(source_order_id == ^order.id))
             |> Ash.read!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert activated_subscription.source_order_id == order.id
    assert activated_subscription.source_order_line_item_id == persisted_line_item.id
    assert activated_subscription.subscription_plan_id == persisted_revision.subscription_plan_id
    assert activated_subscription.current_plan_revision_id == persisted_revision.id
    assert activated_subscription.aggregate_version > 0
    assert %DateTime{} = activated_subscription.current_period_start_at
    assert %DateTime{} = activated_subscription.current_period_end_at

    assert DateTime.compare(
             activated_subscription.current_period_start_at,
             activated_subscription.current_period_end_at
           ) == :lt

    assert [%SubscriptionItem{} = item] =
             SubscriptionItem
             |> Ash.Query.filter(expr(source_order_line_item_id == ^persisted_line_item.id))
             |> Ash.read!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert item.subscription_id == activated_subscription.id
    assert item.source_order_line_item_id == persisted_line_item.id

    assert [%AccessEffect{} = effect] = access_effect_records!(activated_subscription.id)
    assert effect.subscription_id == activated_subscription.id
    assert effect.source_order_line_item_id == persisted_line_item.id
    assert effect.source_version == activated_subscription.aggregate_version
    assert effect.disposition == :effective
    assert effect.status == :applied
    assert effect.plan_revision_id == persisted_revision.id
    assert effect.contract_change_id == nil
    assert effect.entitlement_kind == persisted_revision.entitlement_kind
    assert effect.entitlement_scope_key == persisted_revision.entitlement_scope_key
    assert effect.valid_from_at == activated_subscription.current_period_start_at
    assert effect.valid_until_at == activated_subscription.current_period_end_at

    assert [%EntitlementGrant{} = grant] = grants_for_source!(activated_subscription.id)
    assert grant.user_id == activated_subscription.user_id
    assert grant.source_kind == :subscription
    assert grant.source_id == activated_subscription.id
    assert grant.kind == effect.entitlement_kind
    assert grant.scope_key == effect.entitlement_scope_key
    assert grant.status == :active
    assert grant.valid_from_at == effect.valid_from_at
    assert grant.valid_to_at == effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  test "a charged nil/nil target keeps valid_from_at nil in its AccessEffect" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_nil_target", target_entitlement: {nil, nil})

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    applied = fetch_subscription!(subscription.id)
    assert applied.status == :active

    [effect] = access_effect_rows!(subscription.id)
    [effect_record] = access_effect_records!(subscription.id)
    assert effect.disposition == "effective"
    assert effect.status == "applied"
    assert effect.source_version == applied.aggregate_version
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert datetime_equal?(effect.valid_until_at, attempt.period_end_at)
    assert effect_record.id
    assert effect_record.status == :applied
    assert active_grants_for(subscription.id) == []

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    [replayed_effect] = access_effect_rows!(subscription.id)
    [replayed_effect_record] = access_effect_records!(subscription.id)
    assert replayed_effect.status == "applied"
    assert replayed_effect_record.id == effect_record.id
    assert replayed_effect_record.status == :applied
    assert replayed_effect.valid_from_at == nil
    assert datetime_equal?(replayed_effect.valid_until_at, attempt.period_end_at)
    assert active_grants_for(subscription.id) == []
  end

  test "suspended charged renewal executes its exact EFFECTIVE target before attempt success" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc245_suspended_direct_f1", success?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)
    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    effects = access_effect_records!(subscription.id)
    assert [predecessor, renewal_effect] = Enum.sort_by(effects, & &1.source_version)
    assert predecessor.disposition == :non_effective
    assert renewal_effect.disposition == :effective
    assert renewal_effect.status == :applied
    assert renewal_effect.plan_revision_id == attempt.plan_revision_id
    assert renewal_effect.valid_from_at == attempt.period_start_at
    assert renewal_effect.valid_until_at == attempt.period_end_at
    assert fetch_attempt!(attempt.id).status == :succeeded

    assert [%EntitlementGrant{} = grant] = active_grants_for(subscription.id)
    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  test "projection pending is a successful suspended paid-renewal handoff" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc245_projection_pending_handoff", success?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)
    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    constraint = "jc245_pending_projection_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE access_effects
    ADD CONSTRAINT #{constraint}
    CHECK (projection_delivered_at IS NULL)
    NOT VALID
    """)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT #{constraint}")

    assert fetch_attempt!(attempt.id).status == :succeeded
    [_, renewal_effect] = access_effect_records!(subscription.id)
    assert renewal_effect.status == :applied
    assert renewal_effect.projection_delivered_at == nil
    assert [%EntitlementGrant{} = grant] = active_grants_for(subscription.id)
    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at
  end

  test "ordinary renewal F1 failure preserves committed payment truth and recovers the exact effect" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc300_f1_failure_recovery")

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    constraint = "jc300_reject_renewal_grant_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE entitlement_grants
    ADD CONSTRAINT #{constraint}
    CHECK (source_id <> '#{subscription.id}'::uuid OR status <> 'active')
    NOT VALID
    """)

    assert {:error, _reason} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT #{constraint}")

    committed_subscription = fetch_subscription!(subscription.id)
    assert committed_subscription.current_plan_revision_id == attempt.plan_revision_id
    assert committed_subscription.current_period_start_at == attempt.period_start_at
    assert committed_subscription.current_period_end_at == attempt.period_end_at
    assert fetch_contract_change!(attempt.contract_change_id).status == :applied
    assert fetch_order!(order.id).state == :paid
    assert fetch_payment_intent!(collection.payment_intent_id).state == :succeeded
    assert fetch_collection!(collection.id).financial_outcome == :verified_success
    assert fetch_attempt!(attempt.id).status != :succeeded
    assert grants_for_source!(subscription.id) == []

    [failed_effect] = access_effect_records!(subscription.id)
    assert failed_effect.disposition == :effective
    assert failed_effect.status == :failed_retryable
    assert failed_effect.plan_revision_id == attempt.plan_revision_id
    assert failed_effect.valid_from_at == attempt.period_start_at
    assert failed_effect.valid_until_at == attempt.period_end_at

    failed_effect = fetch_access_effect!(failed_effect.id)
    cursor_start = DateTime.add(failed_effect.updated_at, -1, :microsecond)
    as_of = DateTime.add(failed_effect.updated_at, 1, :microsecond)

    assert {:ok, recovery} =
             Facade.run_subscription_access_effect_recovery_for_system(
               limit: 100,
               as_of: as_of,
               effective_execution_after_updated_at: cursor_start,
               effective_execution_after_id: "00000000-0000-0000-0000-000000000000"
             )

    assert recovery.effective_execution_count >= 1
    assert fetch_access_effect!(failed_effect.id).status == :applied
    assert [%EntitlementGrant{} = grant] = active_grants_for(subscription.id)
    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at

    version_after_commit = committed_subscription.aggregate_version

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    replayed_subscription = fetch_subscription!(subscription.id)
    assert replayed_subscription.aggregate_version == version_after_commit
    assert replayed_subscription.current_period_end_at == attempt.period_end_at
    assert fetch_contract_change!(attempt.contract_change_id).status == :applied
    assert fetch_order!(order.id).state == :paid
    assert fetch_payment_intent!(collection.payment_intent_id).state == :succeeded
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert [replayed_effect] = access_effect_records!(subscription.id)
    assert replayed_effect.id == failed_effect.id
    assert replayed_effect.status == :applied
    assert length(grants_for_source!(subscription.id)) == 1
  end

  test "ordinary renewal projection failure stays successful and repairs without grant mutation" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc300_projection_repair")

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    constraint = "jc300_projection_pending_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE access_effects
    ADD CONSTRAINT #{constraint}
    CHECK (projection_delivered_at IS NULL)
    NOT VALID
    """)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT #{constraint}")

    assert fetch_order!(order.id).state == :paid
    assert fetch_payment_intent!(collection.payment_intent_id).state == :succeeded
    assert fetch_attempt!(attempt.id).status == :succeeded
    [applied_effect] = access_effect_records!(subscription.id)
    assert applied_effect.disposition == :effective
    assert applied_effect.status == :applied
    assert applied_effect.projection_delivered_at == nil

    assert [%EntitlementGrant{} = grant] = active_grants_for(subscription.id)
    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at

    grant_rows_before_repair =
      grants_for_source!(subscription.id)
      |> Enum.map(&{&1.id, &1.status, &1.valid_from_at, &1.valid_to_at})

    assert :ok =
             Facade.repair_suspension_access_effect_projection_for_system(applied_effect.id)

    repaired_effect = fetch_access_effect!(applied_effect.id)
    assert repaired_effect.status == :applied
    assert %DateTime{} = repaired_effect.projection_delivered_at

    grant_rows_after_repair =
      grants_for_source!(subscription.id)
      |> Enum.map(&{&1.id, &1.status, &1.valid_from_at, &1.valid_to_at})

    assert grant_rows_after_repair == grant_rows_before_repair
  end

  test "a suspended renewal retry identifies its historical effect after a newer target commits" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc245_historical_retry_after_newer_target", success?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)
    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    [predecessor] = access_effect_records!(subscription.id)
    assert predecessor.disposition == :non_effective

    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    constraint = "jc245_block_legacy_issue_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE entitlement_grants
    ADD CONSTRAINT #{constraint}
    CHECK (source_id <> '#{subscription.id}'::uuid OR status <> 'active')
    NOT VALID
    """)

    assert {:error, _reason} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    [_, failed_renewal_effect] = access_effect_records!(subscription.id)
    assert failed_renewal_effect.disposition == :effective
    assert failed_renewal_effect.status == :failed_retryable

    newer_effect = establish_newer_non_effective_effect!(subscription, attempt)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    assert fetch_access_effect!(failed_renewal_effect.id).status == :superseded
    assert fetch_access_effect!(newer_effect.id).status == :required
    assert latest_access_effect!(subscription.id).id == newer_effect.id
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert grants_for_source!(subscription.id) == []
    assert length(access_effect_rows!(subscription.id)) == 3

    Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT #{constraint}")
  end

  test "an exact charged replay leaves the applied subscription version unchanged" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_replay", quantity: 2)

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    # Current main rejects this bound attempt. After the reconciliation path is
    # implemented, replay must keep the same aggregate version and target.
    {first_result, first_stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-230 first charged application query_count=#{first_stats.query_count}")
    assert first_stats.query_count > 0
    assert {:ok, :reconciled} = first_result

    version = fetch_subscription!(subscription.id).aggregate_version

    {replay_result, replay_stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-230 exact charged replay query_count=#{replay_stats.query_count}")
    assert replay_stats.query_count > 0
    assert {:ok, :noop} = replay_result

    assert fetch_subscription!(subscription.id).aggregate_version == version
    assert fetch_attempt!(attempt.id).status == :succeeded
  end

  test "an exact paid bound occurrence recovers an exhausted past_due subscription once" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_30_03_exhausted_paid_recovery")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    first_failure_at = DateTime.add(now, -3 * 86_400, :second)

    exhausted =
      fetch_subscription!(subscription.id)
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{
          billing_status_reason: "PAYMENT_FAILED",
          past_due_since_at: first_failure_at,
          dunning_attempt_count: 4,
          next_retry_at: nil,
          retry_suppressed_at: now
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert exhausted.status == :past_due
    assert exhausted.dunning_attempt_count == 4
    assert %DateTime{} = exhausted.retry_suppressed_at
    assert attempt.charged_contract_snapshot["max_retry_attempts"] == 3

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    recovered = fetch_subscription!(subscription.id)
    assert recovered.status == :active
    assert recovered.dunning_attempt_count == 0
    assert recovered.past_due_since_at == nil
    assert recovered.billing_status_reason == nil
    assert recovered.next_retry_at == nil
    assert recovered.retry_suppressed_at == nil
    assert fetch_attempt!(attempt.id).status == :succeeded

    version = recovered.aggregate_version

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    assert fetch_subscription!(subscription.id).aggregate_version == version
    assert fetch_attempt!(attempt.id).status == :succeeded
  end

  test "authoritative exact success before the boundary sweep prevents suspension" do
    %{subscription: subscription, attempt: attempt, order: order} =
      charged_bound_renewal!("jc239_success_precedes_suspension")

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)

    assert {:ok, result} = Facade.run_due_failed_payment_suspensions_for_system(limit: 20)
    assert result.due_count == 1
    assert result.suspended_count == 0
    assert result.failed_count == 0

    recovered = fetch_subscription!(subscription.id)
    assert recovered.status == :active
    assert is_nil(recovered.failed_payment_boundary_at)
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert fetch_order!(order.id).state == :paid
  end

  test "a later exact same-occurrence success recovers suspension and clears its boundary once" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc239_success_recovers_suspension", success?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)

    assert {:ok, result} = Facade.run_due_failed_payment_suspensions_for_system(limit: 20)
    assert result.suspended_count == 1
    suspended = fetch_subscription!(subscription.id)
    assert suspended.status == :suspended
    assert %DateTime{} = suspended.failed_payment_boundary_at
    [suspension_effect] = access_effect_rows!(subscription.id)
    assert suspension_effect.source_version == suspended.aggregate_version
    assert suspension_effect.disposition == "non_effective"

    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    recovered = fetch_subscription!(subscription.id)
    assert recovered.status == :active
    assert is_nil(recovered.failed_payment_boundary_at)
    assert fetch_attempt!(attempt.id).status == :succeeded

    [active_effect, old_suspension_effect] = access_effect_rows!(subscription.id)
    assert active_effect.source_version == recovered.aggregate_version
    assert active_effect.status == "applied"
    assert active_effect.disposition == "effective"
    assert active_effect.plan_revision_id == attempt.plan_revision_id
    assert active_effect.entitlement_kind == "membership_access"

    assert active_effect.entitlement_scope_key ==
             attempt.charged_contract_snapshot["entitlement_scope_key"]

    assert old_suspension_effect.source_version == suspension_effect.source_version
    assert old_suspension_effect.status == "superseded"
    assert old_suspension_effect.disposition == "non_effective"

    version = recovered.aggregate_version

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    assert fetch_subscription!(subscription.id).aggregate_version == version
    assert is_nil(fetch_subscription!(subscription.id).failed_payment_boundary_at)
    assert length(access_effect_rows!(subscription.id)) == 2
  end

  test "failure to establish the recovery AccessEffect rolls back paid suspension recovery" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc239_recovery_effect_rollback", success?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)
    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    suspended = fetch_subscription!(subscription.id)
    fail_access_effect_insert!(subscription.id)
    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:error, _reason} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    after_failure = fetch_subscription!(subscription.id)
    assert after_failure.status == :suspended
    assert after_failure.aggregate_version == suspended.aggregate_version
    assert after_failure.failed_payment_boundary_at == suspended.failed_payment_boundary_at
    assert fetch_attempt!(attempt.id).status != :succeeded

    [effect] = access_effect_rows!(subscription.id)
    assert effect.source_version == suspended.aggregate_version
    assert effect.disposition == "non_effective"
  end

  test "the first requires_action result fixes the boundary from the bound occurrence policy" do
    %{subscription: subscription, attempt: attempt, revision: revision, now: now} =
      charged_bound_renewal!("jc239_auth_required_boundary", success?: false)

    reached = reached_collection!(attempt)
    grace_period_days = attempt.charged_contract_snapshot["grace_period_days"]

    Store.Repo.query!(
      "UPDATE subscription_plans SET grace_period_days = $1 WHERE id = $2",
      [grace_period_days + 30, Ecto.UUID.dump!(revision.subscription_plan_id)]
    )

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "requires_action")
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    past_due = fetch_subscription!(subscription.id)

    assert past_due.status == :past_due
    assert past_due.current_dunning_renewal_attempt_id == attempt.id
    assert past_due.past_due_since_at == now

    assert past_due.failed_payment_boundary_at ==
             DateTime.add(now, grace_period_days * 86_400, :second)
             |> DateTime.truncate(:microsecond)

    assert past_due.next_retry_at == nil
    assert %DateTime{} = past_due.retry_suppressed_at

    due_ids =
      Subscription
      |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{
        now: past_due.failed_payment_boundary_at,
        limit: 20
      })
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    assert subscription.id in due_ids
  end

  test "paid recovery cannot clear a different current dunning RenewalAttempt" do
    recovery = charged_bound_renewal!("jc247_recovery_identity", success?: true)
    recovered_attempt = recovery.attempt

    wrong_pointer_attempt =
      recovered_attempt
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
      |> Map.put(:renewal_key, recovered_attempt.renewal_key <> ":jc247:" <> Ecto.UUID.generate())
      |> then(fn attrs ->
        RenewalAttempt
        |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
        |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      end)

    now = recovery.now
    past_due_since_at = DateTime.add(now, -1, :day)
    boundary_at = DateTime.add(past_due_since_at, 7, :day)

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(recovery.collection.id)

    Store.Repo.query!(
      """
      UPDATE subscriptions
      SET status = 'past_due',
          current_dunning_renewal_attempt_id = $2,
          billing_status_reason = 'PAYMENT_FAILED',
          past_due_since_at = $3,
          failed_payment_boundary_at = $4,
          dunning_attempt_count = 1,
          next_retry_at = NULL,
          retry_suppressed_at = $5
      WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(recovery.subscription.id),
        Ecto.UUID.dump!(wrong_pointer_attempt.id),
        past_due_since_at,
        boundary_at,
        now
      ]
    )

    assert {:error, _reason} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               recovery.order.id,
               handoff_opts(handoff)
             )

    unchanged = fetch_subscription!(recovery.subscription.id)
    assert unchanged.status == :past_due
    assert unchanged.current_dunning_renewal_attempt_id == wrong_pointer_attempt.id
    assert unchanged.current_dunning_renewal_attempt_id != recovered_attempt.id
    assert unchanged.past_due_since_at == past_due_since_at
    assert unchanged.failed_payment_boundary_at == boundary_at
    assert unchanged.dunning_attempt_count == 1
  end

  test "replayed requires_action after a Plan change preserves the bound boundary and starts no collection" do
    %{
      subscription: subscription,
      attempt: attempt,
      revision: revision,
      now: now,
      collection: collection
    } =
      charged_bound_renewal!("jc239_auth_required_replay", success?: false)

    reached = reached_collection!(attempt)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "requires_action")
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    first = fetch_subscription!(subscription.id)
    boundary = first.failed_payment_boundary_at
    grace_days = attempt.charged_contract_snapshot["grace_period_days"]

    Store.Repo.query!(
      "UPDATE subscription_plans SET grace_period_days = $1 WHERE id = $2",
      [grace_days + 30, Ecto.UUID.dump!(revision.subscription_plan_id)]
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id,
               now: DateTime.add(boundary, -1, :second)
             )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id,
               now: boundary
             )

    replayed = fetch_subscription!(subscription.id)
    assert replayed.past_due_since_at == first.past_due_since_at
    assert replayed.failed_payment_boundary_at == boundary

    assert replayed.failed_payment_boundary_at ==
             DateTime.add(now, grace_days * 86_400, :second)
             |> DateTime.truncate(:microsecond)

    assert fetch_collection!(collection.id).id == collection.id

    assert [[1]] ==
             Store.Repo.query!(
               "SELECT count(*) FROM renewal_collection_attempts WHERE renewal_attempt_id = $1",
               [Ecto.UUID.dump!(attempt.id)]
             ).rows
  end

  test "a different attempt id cannot recover a suspended occurrence" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("jc239_different_occurrence", success?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    set_past_due_boundary!(subscription.id, now)
    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:error, _reason} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               Keyword.put(handoff_opts(handoff), :renewal_attempt_id, Ecto.UUID.generate())
             )

    assert fetch_subscription!(subscription.id).status == :suspended
    assert fetch_attempt!(attempt.id).status != :succeeded
    assert Enum.all?(access_effect_rows!(subscription.id), &(&1.disposition == "non_effective"))
  end

  test "CANCELED and EXPIRED subscriptions cannot be recovered by later success" do
    Enum.each([:canceled, :expired], fn terminal_status ->
      %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
        charged_bound_renewal!("jc239_terminal_#{terminal_status}", success?: false)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      set_past_due_boundary!(subscription.id, now)
      assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

      suspended = fetch_subscription!(subscription.id)

      transition =
        if terminal_status == :canceled,
          do: :cancel_now_transition,
          else: :mark_expired_transition

      assert {:ok, _terminal} =
               suspended
               |> Ash.Changeset.for_update(transition, %{}, context: %{system?: true})
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: %{system?: true}
               )

      mark_collection_successful!(collection)
      assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

      result =
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )

      assert fetch_subscription!(subscription.id).status == terminal_status
      assert fetch_attempt!(attempt.id).status != :succeeded
      assert Enum.all?(access_effect_rows!(subscription.id), &(&1.disposition == "non_effective"))

      if terminal_status == :canceled do
        assert {:ok, :noop} = result
      else
        assert {:error, _reason} = result
      end
    end)
  end

  test "paid renewal reconciliation rejects a wrong collection or supplied PaymentIntent ID" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_wrong_handoff_ids")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    before = fetch_subscription!(subscription.id)

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               Keyword.put(handoff_opts(handoff), :collection_attempt_id, Ecto.UUID.generate())
             )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               Keyword.put(handoff_opts(handoff), :payment_intent_id, Ecto.UUID.generate())
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.aggregate_version == before.aggregate_version
    assert after_subscription.current_period_start_at == before.current_period_start_at
    assert after_subscription.current_period_end_at == before.current_period_end_at
    assert after_subscription.current_plan_revision_id == before.current_plan_revision_id
    assert fetch_contract_change!(attempt.contract_change_id).status == :bound_to_renewal
    assert fetch_attempt!(attempt.id).status != :succeeded
  end

  test "the exact collection PaymentIntent overrides a stale RenewalAttempt pointer" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_stale_attempt_pointer")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    stale_intent = create_other_payment_intent!(subscription, order)

    Store.Repo.query!(
      "UPDATE renewal_attempts SET payment_intent_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(stale_intent.id), Ecto.UUID.dump!(attempt.id)]
    )

    assert fetch_attempt!(attempt.id).payment_intent_id == stale_intent.id

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    assert fetch_attempt!(attempt.id).payment_intent_id == handoff.payment_intent_id
  end

  test "a PaymentApplication for another PaymentIntent fails before commercial mutation" do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      contract_change: contract_change,
      collection: collection
    } = charged_bound_renewal!("sbh_10_05_mismatched_application")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    other_intent = create_other_payment_intent!(subscription, order)
    before = fetch_subscription!(subscription.id)

    Store.Repo.query!(
      "UPDATE payment_applications SET payment_intent_id = $1 WHERE order_id = $2",
      [Ecto.UUID.dump!(other_intent.id), Ecto.UUID.dump!(order.id)]
    )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.aggregate_version == before.aggregate_version
    assert after_subscription.current_period_start_at == before.current_period_start_at
    assert after_subscription.current_period_end_at == before.current_period_end_at
    assert fetch_contract_change!(contract_change.id).status == :bound_to_renewal
    assert fetch_attempt!(attempt.id).status != :succeeded
  end

  test "unchanged paid renewal reconciles with an exact revision and records query count" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_05_unchanged")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_900,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(DateTime.utc_now(), -86_410, :second),
        next_renewal_at: DateTime.add(DateTime.utc_now(), -10, :second),
        quantity: 2,
        provider_billing_ref: "pm_sbh_10_05_unchanged"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    collection = fetch_collection_for_attempt!(attempt.id)
    order = fetch_order!(attempt.order_id)
    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    opts = handoff_opts(handoff)

    {result, stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(order.id, opts)
      end)

    IO.puts("JC-230 unchanged reconciliation query_count=#{stats.query_count}")
    assert {:ok, :reconciled} = result
    assert stats.query_count > 0
    applied = fetch_subscription!(subscription.id)
    assert applied.current_plan_revision_id == attempt.plan_revision_id
    assert applied.quantity == attempt.quantity
    assert applied.renewal_amount_minor == attempt.amount_minor
    assert applied.renewal_currency == attempt.currency
  end

  test "a bound ContractChange can be applied through its private action" do
    %{contract_change: contract_change} = charged_bound_renewal!("sbh_10_05_action")

    assert Info.action(ContractChange, :apply)

    assert {:ok, applied} =
             contract_change
             |> Ash.Changeset.for_update(:apply, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert applied.status == :applied
  end

  test "extend_period accepts charged fields and excludes future-target projections" do
    action = Info.action(Subscription, :extend_period, :update)

    assert :current_plan_revision_id in action.accept
    assert :quantity in action.accept

    refute :current_contract_change_id in action.accept
    refute :pending_variant_id in action.accept
    refute :pending_subscription_plan_id in action.accept
    refute :pending_renewal_amount_minor in action.accept
    refute :pending_renewal_currency in action.accept
    refute :change_effective_at in action.accept
  end

  test "a bound renewal rejects each mismatch in its immutable ContractChange target" do
    for dimension <- [
          :target_revision,
          :target_variant,
          :quantity,
          :amount,
          :currency,
          :effective_at,
          :subscription_id
        ] do
      fixture = charged_bound_renewal!("sbh_10_05_mismatch_#{dimension}", quantity: 2)

      %{
        subscription: subscription,
        attempt: attempt,
        order: order,
        contract_change: change,
        collection: collection
      } = fixture

      {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

      mismatch_contract_change!(dimension, change, fixture)
      before = fetch_subscription!(subscription.id)

      assert {:error, %{code: "VALIDATION_ERROR"}} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 order.id,
                 handoff_opts(handoff)
               )

      after_subscription = fetch_subscription!(subscription.id)

      assert Map.take(after_subscription, [
               :subscription_plan_id,
               :current_plan_revision_id,
               :variant_id,
               :quantity,
               :renewal_amount_minor,
               :renewal_currency,
               :current_period_start_at,
               :current_period_end_at,
               :aggregate_version
             ]) ==
               Map.take(before, [
                 :subscription_plan_id,
                 :current_plan_revision_id,
                 :variant_id,
                 :quantity,
                 :renewal_amount_minor,
                 :renewal_currency,
                 :current_period_start_at,
                 :current_period_end_at,
                 :aggregate_version
               ])

      assert fetch_contract_change!(change.id).status == :bound_to_renewal
      assert fetch_attempt!(attempt.id).status != :succeeded
    end
  end

  test "a bound retired revision remains the paid renewal target after a newer revision is published" do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      revision: revision,
      collection: collection
    } =
      charged_bound_renewal!("sbh_10_05_retired_revision")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    {:ok, _} =
      revision
      |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
      |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    revised_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 6,
        amount_minor: 9_900,
        currency: "CAD",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "platinum"
      })

    newer_revision = SubscriptionsFixtures.create_plan_revision!(revised_plan)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    applied = fetch_subscription!(subscription.id)
    assert attempt.plan_revision_id == revision.id
    assert applied.current_plan_revision_id == revision.id
    assert applied.subscription_plan_id == revision.subscription_plan_id
    refute applied.current_plan_revision_id == newer_revision.id
  end

  test "paid renewal reconciliation preserves an exact queued N+1 target" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      fixture = charged_bound_renewal!("sbh_10_05_later_target")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    later_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_100, currency: "GBP"})

    SubscriptionsFixtures.attach_variant_plan!(
      fixture.contract_change.target_variant_id,
      later_plan.id
    )

    later_revision = SubscriptionsFixtures.create_plan_revision!(later_plan)
    actor = fixture.customer

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => later_plan.id
      })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(actor, subscription.id, input)

    before = fetch_subscription!(subscription.id)
    queued_before = fetch_contract_change!(queued.current_contract_change_id)

    {reconciliation_result, stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-233 paid reconciliation with N+1 target query_count=#{stats.query_count}")
    assert stats.query_count > 0
    assert {:ok, :reconciled} = reconciliation_result

    after_subscription = fetch_subscription!(subscription.id)
    queued_after = fetch_contract_change!(queued_before.id)
    assert after_subscription.current_plan_revision_id == attempt.plan_revision_id
    assert after_subscription.subscription_plan_id == fixture.revision.subscription_plan_id
    assert after_subscription.variant_id == attempt.variant_id
    assert after_subscription.quantity == attempt.quantity
    assert after_subscription.renewal_amount_minor == attempt.amount_minor
    assert after_subscription.renewal_currency == attempt.currency
    assert after_subscription.current_period_start_at == attempt.period_start_at
    assert after_subscription.current_period_end_at == attempt.period_end_at
    assert after_subscription.current_contract_change_id == queued_before.id
    assert after_subscription.pending_subscription_plan_id == before.pending_subscription_plan_id
    assert after_subscription.pending_variant_id == before.pending_variant_id
    assert after_subscription.pending_renewal_amount_minor == before.pending_renewal_amount_minor
    assert after_subscription.pending_renewal_currency == before.pending_renewal_currency
    assert after_subscription.change_effective_at == before.change_effective_at
    assert queued_after.status == :queued
    assert queued_after.subscription_id == subscription.id
    assert queued_after.target_plan_revision_id == later_revision.id
    assert queued_after.target_amount_minor == later_revision.amount_minor
    assert queued_after.target_currency == later_revision.currency
    assert queued_after.effective_at == after_subscription.current_period_end_at
    assert queued_after.target_variant_id == attempt.variant_id
    assert queued_after.target_quantity == attempt.quantity
    assert fetch_contract_change!(attempt.contract_change_id).status == :applied
    assert fetch_attempt!(attempt.id).status == :succeeded

    [renewal_effect] = access_effect_records!(subscription.id)
    assert renewal_effect.status == :applied
    assert renewal_effect.disposition == :effective
    assert renewal_effect.plan_revision_id == attempt.plan_revision_id
    assert renewal_effect.entitlement_kind == fixture.revision.entitlement_kind
    assert renewal_effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert renewal_effect.valid_from_at == attempt.period_start_at
    assert renewal_effect.valid_until_at == attempt.period_end_at

    assert [%EntitlementGrant{} = charged_grant] = active_grants_for(subscription.id)
    assert charged_grant.kind == fixture.revision.entitlement_kind
    assert charged_grant.scope_key == fixture.revision.entitlement_scope_key
    assert charged_grant.valid_from_at == attempt.period_start_at
    assert charged_grant.valid_to_at == attempt.period_end_at

    applied_version = after_subscription.aggregate_version
    grant_id = charged_grant.id

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    replayed = fetch_subscription!(subscription.id)
    assert replayed.aggregate_version == applied_version
    assert replayed.current_contract_change_id == queued_before.id
    assert fetch_contract_change!(queued_before.id) == queued_after
    assert [replayed_effect] = access_effect_records!(subscription.id)
    assert replayed_effect.id == renewal_effect.id
    assert replayed_effect.status == :applied

    assert [%EntitlementGrant{id: ^grant_id} = replayed_grant] =
             active_grants_for(subscription.id)

    assert replayed_grant.valid_from_at == attempt.period_start_at
    assert replayed_grant.valid_to_at == attempt.period_end_at

    assert [attempt.contract_change_id, queued_before.id] ==
             subscription_contract_change_ids!(subscription.id)
  end

  test "paid renewal reconciliation rejects a queued target at the bound boundary" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      fixture = charged_bound_renewal!("sbh_10_05_bound_boundary_target")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    later_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_100})

    SubscriptionsFixtures.attach_variant_plan!(
      fixture.contract_change.target_variant_id,
      later_plan.id
    )

    SubscriptionsFixtures.create_plan_revision!(later_plan)

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => later_plan.id
      })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(
               fixture.customer,
               subscription.id,
               input
             )

    queued_before = fetch_contract_change!(queued.current_contract_change_id)
    assert queued_before.effective_at == attempt.period_end_at

    Store.Repo.query!(
      "UPDATE contract_changes SET effective_at = $1 WHERE id = $2",
      [attempt.period_start_at, Ecto.UUID.dump!(queued_before.id)]
    )

    Store.Repo.query!(
      "UPDATE subscriptions SET change_effective_at = $1 WHERE id = $2",
      [attempt.period_start_at, Ecto.UUID.dump!(subscription.id)]
    )

    queued_at_bound_boundary = fetch_contract_change!(queued_before.id)
    before_subscription = fetch_subscription!(subscription.id)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.aggregate_version == before_subscription.aggregate_version
    assert after_subscription == before_subscription
    assert fetch_contract_change!(queued_before.id) == queued_at_bound_boundary
    assert fetch_contract_change!(attempt.contract_change_id).status == :bound_to_renewal
    assert fetch_attempt!(attempt.id).status != :succeeded
  end

  test "paid renewal reconciliation rejects a broken N+1 predecessor chain" do
    assert_corrupted_n_plus_one_lineage_fails!(:broken_predecessor)
  end

  test "paid renewal reconciliation rejects an invalid N+1 intermediate lifecycle" do
    assert_corrupted_n_plus_one_lineage_fails!(:intermediate_lifecycle)
  end

  test "paid renewal reconciliation rejects a wrong N+1 target boundary" do
    assert_corrupted_n_plus_one_lineage_fails!(:wrong_boundary)
  end

  test "ContractChange apply rejects queued, superseded, and canceled states" do
    for terminal_state <- [:queued, :superseded, :canceled] do
      %{contract_change: change} = charged_bound_renewal!("sbh_10_05_apply_#{terminal_state}")

      Store.Repo.query!(
        "UPDATE contract_changes SET status = $1 WHERE id = $2",
        [Atom.to_string(terminal_state), Ecto.UUID.dump!(change.id)]
      )

      current = fetch_contract_change!(change.id)

      assert {:error, _} =
               current
               |> Ash.Changeset.for_update(:apply, %{}, context: %{system?: true})
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: %{system?: true}
               )

      assert fetch_contract_change!(change.id).status == terminal_state
    end
  end

  test "retry after the access-sync crash preserves a later target and reuses the charged entitlement snapshot",
       %{sandbox_owners: sandbox_owners} do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      customer: customer,
      contract_change: contract_change,
      collection: collection,
      revision: revision
    } =
      charged_bound_renewal!("sbh_10_05_crash_replay")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    later_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_300, currency: "GBP"})

    SubscriptionsFixtures.attach_variant_plan!(contract_change.target_variant_id, later_plan.id)
    later_revision = SubscriptionsFixtures.create_plan_revision!(later_plan)

    {:ok, queued} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => later_plan.id
      })

    assert {:ok, queued_subscription} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, queued)

    later_change = fetch_contract_change!(queued_subscription.current_contract_change_id)
    future_projection = fetch_subscription!(subscription.id)

    crash_once = :atomics.new(1, [])
    handler_id = "jc230-crash-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :paid_renewal_access_sync],
        fn _event, _measurements, _metadata, state ->
          if :atomics.compare_exchange(state, 1, 0, 1) == :ok do
            send(parent, {:jc230_crashing_reconciliation, self()})
            Process.exit(self(), :kill)
          end
        end,
        crash_once
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {child, monitor} =
      spawn_monitor(fn ->
        receive do
          :start_reconciliation ->
            Facade.reconcile_paid_subscription_renewal_for_system(
              order.id,
              handoff_opts(handoff)
            )
        end
      end)

    :ok = Sandbox.allow(Store.Repo, sandbox_owners[Store.Repo], child)
    :ok = Sandbox.allow(Store.DirectRepo, sandbox_owners[Store.DirectRepo], child)
    send(child, :start_reconciliation)
    assert_receive {:jc230_crashing_reconciliation, ^child}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 1_000

    committed = fetch_subscription!(subscription.id)
    assert committed.current_plan_revision_id == revision.id
    assert committed.current_period_end_at == attempt.period_end_at
    assert committed.current_contract_change_id == later_change.id

    assert committed.pending_subscription_plan_id ==
             future_projection.pending_subscription_plan_id

    assert committed.pending_variant_id == future_projection.pending_variant_id

    assert committed.pending_renewal_amount_minor ==
             future_projection.pending_renewal_amount_minor

    assert committed.pending_renewal_currency == future_projection.pending_renewal_currency
    assert committed.change_effective_at == future_projection.change_effective_at
    assert fetch_contract_change!(contract_change.id).status == :applied
    assert fetch_attempt!(attempt.id).status != :succeeded
    version = fetch_subscription!(subscription.id).aggregate_version
    :ok = :telemetry.detach(handler_id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    replayed = fetch_subscription!(subscription.id)
    assert replayed.aggregate_version == version
    assert replayed.current_period_end_at == attempt.period_end_at
    assert replayed.current_contract_change_id == later_change.id
    assert replayed.pending_subscription_plan_id == future_projection.pending_subscription_plan_id
    assert replayed.pending_variant_id == future_projection.pending_variant_id
    assert replayed.pending_renewal_amount_minor == future_projection.pending_renewal_amount_minor
    assert replayed.pending_renewal_currency == future_projection.pending_renewal_currency
    assert replayed.change_effective_at == future_projection.change_effective_at
    assert fetch_contract_change!(later_change.id) == later_change
    assert later_change.status == :queued
    assert later_change.target_plan_revision_id == later_revision.id
    assert later_change.target_variant_id == attempt.variant_id
    assert later_change.target_quantity == attempt.quantity
    assert later_change.effective_at == attempt.period_end_at

    assert [contract_change.id, later_change.id] ==
             subscription_contract_change_ids!(subscription.id)

    assert fetch_contract_change!(contract_change.id).status == :applied
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert replayed.membership_key == "gold"

    assert [%EntitlementGrant{kind: :membership_access, scope_key: "gold", status: :active}] =
             active_grants_for(subscription.id)
  end

  defp charged_bound_renewal!(token, opts \\ []) do
    customer = SubscriptionsFixtures.create_customer!(token)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD"
      })

    {target_entitlement_kind, target_entitlement_scope_key} =
      Keyword.get(opts, :target_entitlement, {:membership_access, "gold"})

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 4_700,
        currency: "EUR",
        entitlement_kind: target_entitlement_kind,
        entitlement_scope_key: target_entitlement_scope_key
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    quantity = Keyword.get(opts, :quantity, 1)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second),
        quantity: quantity,
        provider_billing_ref: "pm_#{token}"
      })

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, input)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    assert attempt.contract_change_id == contract_change.id
    order = reached.order
    collection = reached.collection
    if Keyword.get(opts, :success?, true), do: mark_collection_successful!(collection)

    %{
      subscription: subscription,
      customer: customer,
      attempt: fetch_attempt!(attempt.id),
      order: order,
      collection: fetch_collection!(collection.id),
      revision: revision,
      contract_change: fetch_contract_change!(contract_change.id),
      now: now
    }
  end

  defp access_effect_rows!(subscription_id) do
    {:ok, %{rows: rows}} =
      Store.Repo.query(
        """
        SELECT source_version, status::text, disposition::text, plan_revision_id::text,
               entitlement_kind::text, entitlement_scope_key,
               valid_from_at, valid_until_at
        FROM access_effects
        WHERE subscription_id = $1
        ORDER BY source_version DESC
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    Enum.map(rows, fn [
                        source_version,
                        status,
                        disposition,
                        plan_revision_id,
                        entitlement_kind,
                        scope_key,
                        valid_from_at,
                        valid_until_at
                      ] ->
      %{
        source_version: source_version,
        status: status,
        disposition: disposition,
        plan_revision_id: plan_revision_id,
        entitlement_kind: entitlement_kind,
        entitlement_scope_key: scope_key,
        valid_from_at: valid_from_at,
        valid_until_at: valid_until_at
      }
    end)
  end

  defp access_effect_records!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_access_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp latest_access_effect!(subscription_id) do
    subscription_id
    |> access_effect_records!()
    |> Enum.max_by(& &1.source_version)
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp establish_newer_non_effective_effect!(subscription, attempt) do
    {:ok, %{rows: [[source_version]]}} =
      Repo.query(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
        [Ecto.UUID.dump!(subscription.id)]
      )

    current = fetch_subscription!(subscription.id)

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
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp fail_access_effect_insert!(subscription_id) do
    function_name = "jc239_fail_recovery_effect_#{System.unique_integer([:positive])}"

    Store.Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.subscription_id::text = current_setting('store.jc239_fail_recovery_effect_subscription', true) THEN
        RAISE EXCEPTION 'injected JC-239 recovery AccessEffect insert failure';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Store.Repo.query!("""
    CREATE TRIGGER #{function_name}
    BEFORE INSERT ON access_effects
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    Store.Repo.query!(
      "SELECT set_config('store.jc239_fail_recovery_effect_subscription', $1, true)",
      [subscription_id]
    )
  end

  defp set_past_due_boundary!(subscription_id, now) do
    boundary_at = DateTime.add(now, -1, :second)

    subscription = fetch_subscription!(subscription_id)

    assert {:ok, past_due} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{
                 past_due_since_at: DateTime.add(now, -86_400, :second),
                 failed_payment_boundary_at: boundary_at,
                 dunning_attempt_count: 1,
                 next_retry_at: nil,
                 retry_suppressed_at: now
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert past_due.status == :past_due
    past_due
  end

  defp queue_post_b_lineage_targets!(fixture, _token) do
    [first_y, z] =
      for amount_minor <- [6_100, 7_300] do
        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            amount_minor: amount_minor,
            currency: "GBP"
          })

        SubscriptionsFixtures.attach_variant_plan!(
          fixture.contract_change.target_variant_id,
          plan.id
        )

        SubscriptionsFixtures.create_plan_revision!(plan)

        {:ok, input} =
          QueueSubscriptionPlanChangeInput.new(%{
            "subscription_id" => fixture.subscription.id,
            "subscription_plan_id" => plan.id
          })

        assert {:ok, queued} =
                 Facade.queue_subscription_plan_change_for_user(
                   fixture.customer,
                   fixture.subscription.id,
                   input
                 )

        fetch_contract_change!(queued.current_contract_change_id)
      end

    y = fetch_contract_change!(first_y.id)

    assert y.status == :superseded
    assert z.status == :queued
    assert y.predecessor_contract_change_id == fixture.contract_change.id
    assert z.predecessor_contract_change_id == y.id
    assert z.effective_at == fixture.attempt.period_end_at

    {y, z}
  end

  defp corrupt_n_plus_one_lineage!(:broken_predecessor, fixture, _y, z) do
    Store.Repo.query!(
      "UPDATE contract_changes SET predecessor_contract_change_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(fixture.contract_change.id), Ecto.UUID.dump!(z.id)]
    )
  end

  defp corrupt_n_plus_one_lineage!(:intermediate_lifecycle, _fixture, y, _z) do
    Store.Repo.query!("UPDATE contract_changes SET status = 'applied' WHERE id = $1", [
      Ecto.UUID.dump!(y.id)
    ])
  end

  defp corrupt_n_plus_one_lineage!(:wrong_boundary, fixture, _y, z) do
    Store.Repo.query!("UPDATE contract_changes SET effective_at = $1 WHERE id = $2", [
      fixture.attempt.period_start_at,
      Ecto.UUID.dump!(z.id)
    ])
  end

  defp assert_corrupted_n_plus_one_lineage_fails!(corruption) do
    token = "sbh_10_05_lineage_#{corruption}_#{System.unique_integer([:positive])}"
    fixture = charged_bound_renewal!(token)
    %{subscription: subscription, attempt: attempt, collection: collection} = fixture
    {y, z} = queue_post_b_lineage_targets!(fixture, token)

    corrupt_n_plus_one_lineage!(corruption, fixture, y, z)

    before_subscription = fetch_subscription!(subscription.id)
    before_attempt = fetch_attempt!(attempt.id)
    before_x = fetch_contract_change!(fixture.contract_change.id)
    before_y = fetch_contract_change!(y.id)
    before_z = fetch_contract_change!(z.id)

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert before_subscription.current_contract_change_id == z.id
    assert before_x.status == :bound_to_renewal

    assert before_y.status ==
             if(corruption == :intermediate_lifecycle, do: :applied, else: :superseded)

    assert before_z.status == :queued

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               fixture.order.id,
               handoff_opts(handoff)
             )

    assert fetch_subscription!(subscription.id) == before_subscription
    assert fetch_attempt!(attempt.id) == before_attempt
    assert fetch_contract_change!(fixture.contract_change.id) == before_x
    assert fetch_contract_change!(y.id) == before_y
    assert fetch_contract_change!(z.id) == before_z
  end

  defp create_other_payment_intent!(subscription, order) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{
        order_id: order.id,
        amount_received_minor: 0,
        currency: order.currency_code,
        provider: subscription.provider,
        subscription_id: subscription.id,
        payment_intent_key: "sbh_10_05_other_pi:#{Ecto.UUID.generate()}"
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mismatch_contract_change!(dimension, change, fixture) do
    {field, value} = mismatch_contract_change_target(dimension, fixture)

    Store.Repo.query!("UPDATE contract_changes SET #{field} = $1 WHERE id = $2", [
      value,
      Ecto.UUID.dump!(change.id)
    ])
  end

  defp mismatch_contract_change_target(:target_revision, _fixture) do
    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 7_777,
        currency: "CAD"
      })

    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    {:target_plan_revision_id, Ecto.UUID.dump!(revision.id)}
  end

  defp mismatch_contract_change_target(:target_variant, _fixture) do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    {:target_variant_id, Ecto.UUID.dump!(variant.id)}
  end

  defp mismatch_contract_change_target(:quantity, fixture),
    do: {:target_quantity, fixture.attempt.quantity + 1}

  defp mismatch_contract_change_target(:amount, fixture),
    do: {:target_amount_minor, fixture.attempt.amount_minor + 1}

  defp mismatch_contract_change_target(:currency, fixture) do
    currency = if fixture.attempt.currency == "USD", do: "EUR", else: "USD"
    {:target_currency, currency}
  end

  defp mismatch_contract_change_target(:effective_at, fixture) do
    effective_at = DateTime.add(fixture.attempt.period_start_at, 1, :second)
    {:effective_at, effective_at}
  end

  defp mismatch_contract_change_target(:subscription_id, _fixture) do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()

    other_customer =
      SubscriptionsFixtures.create_customer!(
        "sbh_10_05_foreign_#{System.unique_integer([:positive])}"
      )

    %{subscription: other} =
      SubscriptionsFixtures.create_subscription_fixture!(other_customer.id, variant, plan)

    {:subscription_id, Ecto.UUID.dump!(other.id)}
  end

  defp mark_collection_successful!(collection) do
    attempt = fetch_attempt!(collection.renewal_attempt_id)

    reached = %{
      attempt: attempt,
      order: fetch_order!(attempt.order_id),
      collection: collection,
      payment_intent: fetch_payment_intent!(collection.payment_intent_id)
    }

    payment_intent = reached.payment_intent

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    assert {:ok, observed} =
             PaymentsFacade.observe_payment_intent_for_system(%ObservePaymentIntentInput{
               payment_intent_id: payment_intent.id
             })

    assert {:ok, %{outcome: outcome}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(observed)

    assert outcome in [:authoritative_success, :already_applied_success]
    updated = fetch_collection!(reached.collection.id)

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated.payment_attempt_id,
                 payment_intent_id: reached.collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )
  end

  defp reached_collection!(attempt) do
    collection = fetch_collection_for_attempt!(attempt.id)

    %{
      attempt: attempt,
      order: fetch_order!(attempt.order_id),
      collection: collection,
      payment_intent: fetch_payment_intent!(collection.payment_intent_id)
    }
  end

  defp handoff_opts(handoff) do
    [
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    ]
  end

  defp fetch_subscription!(id), do: read_one!(Subscription, id, Store.Subscriptions)
  defp fetch_attempt!(id), do: read_one!(RenewalAttempt, id, Store.Subscriptions)
  defp fetch_contract_change!(id), do: read_one!(ContractChange, id, Store.Subscriptions)
  defp fetch_order!(id), do: read_one!(Order, id, Store.Orders)
  defp fetch_payment_intent!(id), do: read_one!(PaymentIntent, id, Store.Payments)
  defp fetch_collection!(id), do: read_one!(RenewalCollectionAttempt, id, Store.Subscriptions)

  defp subscription_contract_change_ids!(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(ordering_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> Enum.map(& &1.id)
  end

  defp read_one!(resource, id, domain) do
    resource
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: domain, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_for_attempt!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp active_grants_for(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_id == ^subscription_id and status == :active))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp datetime_equal?(left, %DateTime{} = right) do
    left =
      case left do
        %DateTime{} = dt -> dt
        %NaiveDateTime{} = naive -> DateTime.from_naive!(naive, "Etc/UTC")
      end

    DateTime.compare(left, right) == :eq
  end

  defp trace_renewal_writer_calls(operation, sandbox_owners) do
    direct_writer_mfa =
      {EntitlementsFacade, :issue_subscription_source_grant_strict_for_system, 2}

    trace_calls_in_child(operation, direct_writer_mfa, sandbox_owners)
  end

  defp trace_initial_paid_entitlement_call(operation, sandbox_owners) do
    mfa = {EntitlementsFacade, :issue_subscription_entitlement_for_system, 2}

    assert {:module, EntitlementsFacade} = Code.ensure_loaded(EntitlementsFacade)
    trace_calls_in_child(operation, mfa, sandbox_owners)
  end

  defp trace_calls_in_child(operation, mfa, sandbox_owners) do
    start_ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          {:run_traced_operation, ^start_ref} -> operation.()
        end
      end)

    :ok = Sandbox.allow(Store.Repo, sandbox_owners[Store.Repo], task.pid)
    :ok = Sandbox.allow(Store.DirectRepo, sandbox_owners[Store.DirectRepo], task.pid)

    :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(task.pid, true, [:call])
    send(task.pid, {:run_traced_operation, start_ref})

    try do
      result = Task.await(task, 10_000)
      {result, collect_renewal_writer_calls(task.pid, [])}
    after
      if Process.alive?(task.pid), do: :erlang.trace(task.pid, false, [:call])

      :erlang.trace_pattern(mfa, false, [:global])
    end
  end

  defp collect_renewal_writer_calls(pid, calls) do
    receive do
      {:trace, ^pid, :call, {module, function, args}} ->
        collect_renewal_writer_calls(
          pid,
          [%{module: module, function: function, args: args} | calls]
        )
    after
      0 ->
        Enum.reverse(calls)
    end
  end
end
