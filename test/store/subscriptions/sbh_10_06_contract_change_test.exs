defmodule Store.Subscriptions.Sbh1006ContractChangeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.Order
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionVariantChangeInput

  alias Store.Subscriptions.{
    AccessEffect,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    Subscription,
    SubscriptionPlan
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a queued target keeps the exact effective revision after publication changes" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_exact_revision")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan)

    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, queued} = queue_plan_change(customer, subscription, target_plan)
    assert is_binary(Map.get(queued, :current_contract_change_id))

    contract_change = fetch_contract_change!(Map.get(queued, :current_contract_change_id))
    assert Map.get(contract_change, :target_plan_revision_id) == target_revision.id
    assert Map.get(contract_change, :target_variant_id) == variant.id
    assert Map.get(contract_change, :target_quantity) == subscription.quantity
    assert Map.get(contract_change, :target_amount_minor) == target_revision.amount_minor
    assert Map.get(contract_change, :target_currency) == target_revision.currency

    target_revision
    |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    replacement_revision =
      SubscriptionsFixtures.create_plan_revision!(target_plan, %{amount_minor: 4_100})

    persisted = fetch_contract_change!(contract_change.id)
    assert Map.get(persisted, :target_plan_revision_id) == target_revision.id
    assert Map.get(persisted, :target_plan_revision_id) != replacement_revision.id
    assert Map.get(persisted, :target_amount_minor) == target_revision.amount_minor
  end

  test "a plan change without an effective revision leaves the subscription untouched" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_no_revision")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!()
    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        pending_renewal_amount_minor: 1_300,
        pending_renewal_currency: "CAD"
      })

    before = fetch_subscription!(subscription.id)

    assert {:error, %Error{}} = queue_plan_change(customer, before, target_plan)

    after_subscription = fetch_subscription!(subscription.id)
    assert Map.get(after_subscription, :current_contract_change_id) == nil

    assert Map.take(after_subscription, [
             :pending_subscription_plan_id,
             :pending_variant_id,
             :pending_renewal_amount_minor,
             :pending_renewal_currency,
             :change_effective_at,
             :aggregate_version
           ]) ==
             Map.take(before, [
               :pending_subscription_plan_id,
               :pending_variant_id,
               :pending_renewal_amount_minor,
               :pending_renewal_currency,
               :change_effective_at,
               :aggregate_version
             ])

    assert list_contract_changes(subscription.id) == []
  end

  test "new changes require an active plan and an available target variant" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_change_eligibility")
    %{variant: live_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    %{variant: unavailable_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    archived_plan = SubscriptionsFixtures.create_subscription_plan!()

    SubscriptionsFixtures.attach_variant_plan!(live_variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(live_variant.id, archived_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(unavailable_variant.id, current_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, live_variant, current_plan)

    SubscriptionsFixtures.create_plan_revision!(archived_plan)

    archived_plan
    |> Ash.Changeset.for_update(:update, %{status: :archived}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    unavailable_variant
    |> Ash.Changeset.for_update(:update, %{status: :archived}, context: %{system?: true})
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    before = fetch_subscription!(subscription.id)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             queue_plan_change(customer, before, archived_plan)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             queue_variant_change(
               customer,
               fetch_subscription!(subscription.id),
               unavailable_variant
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.current_contract_change_id == nil
    assert after_subscription.aggregate_version == before.aggregate_version
    assert list_contract_changes(subscription.id) == []
  end

  test "a later plan change supersedes the prior identity and becomes current" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_supersession")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    plan_a = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_100})
    plan_b = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_100})

    for plan <- [current_plan, plan_a, plan_b] do
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    end

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan)

    revision_a = SubscriptionsFixtures.create_plan_revision!(plan_a)
    revision_b = SubscriptionsFixtures.create_plan_revision!(plan_b)

    assert {:ok, after_a} = queue_plan_change(customer, subscription, plan_a)
    contract_a = fetch_contract_change!(Map.get(after_a, :current_contract_change_id))

    assert {:ok, after_b} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), plan_b)

    contract_b = fetch_contract_change!(Map.get(after_b, :current_contract_change_id))
    reloaded_a = fetch_contract_change!(contract_a.id)

    assert contract_a.id != contract_b.id
    assert Map.get(reloaded_a, :status) == :superseded
    assert Map.get(contract_b, :status) == :queued
    assert Map.get(contract_b, :target_plan_revision_id) == revision_b.id
    assert Map.get(contract_b, :predecessor_contract_change_id) == contract_a.id
    assert Map.get(contract_b, :supersedes_contract_change_id) == contract_a.id
    assert Map.get(contract_b, :ordering_version) > Map.get(contract_a, :ordering_version)
    assert Map.get(after_b, :current_contract_change_id) == contract_b.id
    assert Map.get(contract_a, :target_plan_revision_id) == revision_a.id
  end

  test "a variant change composes from ContractChange when pending projections drift" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_dimension_scope")
    %{variant: live_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    %{variant: future_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 1_700})
    future_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_700})
    drift_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 9_700})

    for variant <- [live_variant, future_variant], plan <- [live_plan, future_plan, drift_plan] do
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    end

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, live_variant, live_plan, %{
        quantity: 3
      })

    future_revision = SubscriptionsFixtures.create_plan_revision!(future_plan)
    SubscriptionsFixtures.create_plan_revision!(drift_plan)

    assert {:ok, after_plan} = queue_plan_change(customer, subscription, future_plan)

    first_contract_change =
      fetch_contract_change!(Map.get(after_plan, :current_contract_change_id))

    corrupted_effective_at = DateTime.add(first_contract_change.effective_at, 7 * 86_400, :second)

    Store.Repo.query!(
      "UPDATE subscriptions SET pending_subscription_plan_id = $2, pending_variant_id = $3, pending_renewal_amount_minor = $4, pending_renewal_currency = $5, change_effective_at = $6 WHERE id = $1",
      [
        Ecto.UUID.dump!(subscription.id),
        Ecto.UUID.dump!(drift_plan.id),
        Ecto.UUID.dump!(live_variant.id),
        99_999,
        "EUR",
        corrupted_effective_at
      ]
    )

    drifted_subscription = fetch_subscription!(subscription.id)
    assert drifted_subscription.pending_subscription_plan_id == drift_plan.id
    assert drifted_subscription.pending_variant_id == live_variant.id
    assert drifted_subscription.pending_renewal_amount_minor == 99_999
    assert drifted_subscription.pending_renewal_currency == "EUR"
    assert drifted_subscription.change_effective_at == corrupted_effective_at

    future_revision
    |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    replacement_revision =
      SubscriptionsFixtures.create_plan_revision!(future_plan, %{amount_minor: 4_100})

    assert {:ok, after_variant} =
             queue_variant_change(customer, drifted_subscription, future_variant)

    contract = fetch_contract_change!(Map.get(after_variant, :current_contract_change_id))
    assert Map.get(contract, :target_plan_revision_id) == future_revision.id
    assert Map.get(contract, :target_plan_revision_id) != replacement_revision.id
    assert Map.get(contract, :target_variant_id) == future_variant.id
    assert Map.get(contract, :target_quantity) == 3
    assert Map.get(contract, :target_amount_minor) == future_revision.amount_minor
    assert Map.get(contract, :target_amount_minor) != replacement_revision.amount_minor
    assert Map.get(contract, :target_currency) == future_revision.currency
    assert Map.get(contract, :instruction_kind) == :variant_change
    assert Map.get(contract, :effective_at) == first_contract_change.effective_at
    assert Map.get(fetch_contract_change!(first_contract_change.id), :status) == :superseded

    assert Map.get(contract, :predecessor_contract_change_id) ==
             first_contract_change.id

    assert Map.get(contract, :supersedes_contract_change_id) ==
             first_contract_change.id

    assert after_variant.pending_subscription_plan_id == future_plan.id
    assert after_variant.pending_variant_id == future_variant.id
    assert after_variant.pending_renewal_amount_minor == future_revision.amount_minor
    assert after_variant.pending_renewal_currency == future_revision.currency
    assert after_variant.change_effective_at == first_contract_change.effective_at
  end

  test "a plan change preserves the queued variant and live quantity" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_plan_preserves_variant")
    %{variant: live_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    %{variant: future_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 1_600})
    future_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_600})

    for variant <- [live_variant, future_variant], plan <- [live_plan, future_plan] do
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    end

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, live_variant, live_plan, %{
        quantity: 2
      })

    future_revision = SubscriptionsFixtures.create_plan_revision!(future_plan)

    assert {:ok, after_variant} =
             queue_variant_change(customer, subscription, future_variant)

    variant_change = fetch_contract_change!(Map.get(after_variant, :current_contract_change_id))

    assert Map.get(variant_change, :target_plan_revision_id) ==
             subscription.current_plan_revision_id

    assert Map.get(variant_change, :target_variant_id) == future_variant.id

    assert {:ok, after_plan} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), future_plan)

    contract = fetch_contract_change!(Map.get(after_plan, :current_contract_change_id))
    assert Map.get(contract, :target_plan_revision_id) == future_revision.id
    assert Map.get(contract, :target_variant_id) == future_variant.id
    assert Map.get(contract, :target_quantity) == 2
    assert Map.get(contract, :target_amount_minor) == future_revision.amount_minor
    assert Map.get(contract, :target_currency) == future_revision.currency
    assert Map.get(contract, :predecessor_contract_change_id) == variant_change.id
    assert Map.get(fetch_contract_change!(variant_change.id), :status) == :superseded
    assert after_plan.pending_subscription_plan_id == future_plan.id
    assert after_plan.pending_variant_id == future_variant.id
  end

  test "cancellation and rescission create a new unchanged instruction without resurrection" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_rescind")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 1_800})
    plan_a = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_800})
    plan_b = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 3_800})

    for plan <- [live_plan, plan_a, plan_b] do
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    end

    %{subscription: subscription, revision: live_revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, live_plan, %{
        quantity: 2
      })

    SubscriptionsFixtures.create_plan_revision!(plan_a)
    SubscriptionsFixtures.create_plan_revision!(plan_b)

    assert {:ok, after_a} = queue_plan_change(customer, subscription, plan_a)
    contract_a = fetch_contract_change!(Map.get(after_a, :current_contract_change_id))

    assert {:ok, after_b} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), plan_b)

    contract_b = fetch_contract_change!(Map.get(after_b, :current_contract_change_id))

    assert {:ok, canceled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert Map.get(canceled, :current_contract_change_id) == nil
    assert Map.get(fetch_contract_change!(contract_b.id), :status) == :canceled
    assert Map.get(fetch_contract_change!(contract_a.id), :status) == :superseded
    assert canceled.pending_subscription_plan_id == nil
    assert canceled.pending_variant_id == nil

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             queue_plan_change(customer, canceled, plan_a)

    assert {:ok, rescinded} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :rescind_period_end)

    contract_c = fetch_contract_change!(Map.get(rescinded, :current_contract_change_id))

    assert contract_c.id not in [contract_a.id, contract_b.id]
    assert Map.get(contract_c, :status) == :queued
    assert Map.get(contract_c, :instruction_kind) == :renew_unchanged
    assert Map.get(contract_c, :target_plan_revision_id) == live_revision.id
    assert Map.get(contract_c, :target_variant_id) == variant.id
    assert Map.get(contract_c, :target_quantity) == 2
    assert Map.get(contract_c, :target_amount_minor) == subscription.renewal_amount_minor
    assert Map.get(contract_c, :target_currency) == subscription.renewal_currency
    assert Map.get(contract_c, :predecessor_contract_change_id) == contract_b.id
    assert Map.get(contract_c, :supersedes_contract_change_id) == nil
    refute rescinded.cancel_at_period_end
    assert Map.get(fetch_contract_change!(contract_a.id), :status) == :superseded
    assert Map.get(fetch_contract_change!(contract_b.id), :status) == :canceled
  end

  test "rescission preserves a retired revision from the live Subscription" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_rescind_retired")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    live_plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, live_plan.id)

    %{subscription: subscription, revision: live_revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, live_plan)

    live_revision
    |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    effective_replacement = SubscriptionsFixtures.create_plan_revision!(live_plan)

    assert {:ok, _canceled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert {:ok, rescinded} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :rescind_period_end)

    contract = fetch_contract_change!(Map.get(rescinded, :current_contract_change_id))
    assert Map.get(contract, :target_plan_revision_id) == live_revision.id
    assert Map.get(contract, :target_plan_revision_id) != effective_replacement.id
  end

  test "contract change lookup uses durable evidence when compatibility projections drift" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_projection")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_400})
    drift_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 9_400})

    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan)

    assert {:ok, queued} = queue_plan_change(customer, subscription, target_plan)
    contract_change_id = Map.get(queued, :current_contract_change_id)

    Store.Repo.query!(
      "UPDATE subscriptions SET pending_subscription_plan_id = $2, pending_renewal_amount_minor = $3, pending_renewal_currency = $4 WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id), Ecto.UUID.dump!(drift_plan.id), 99_999, "EUR"]
    )

    contract_change = current_contract_change(subscription.id)

    assert contract_change.id == contract_change_id
    assert Map.get(contract_change, :target_plan_revision_id) == revision.id
    assert Map.get(contract_change, :target_amount_minor) == revision.amount_minor
    assert Map.get(contract_change, :target_currency) == revision.currency
  end

  test "unresolved legacy pending fields do not create a contract change and block renewal" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_legacy_pending")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_10_06_legacy",
        next_renewal_at: DateTime.add(now, -10, :second),
        pending_subscription_plan_id: plan.id,
        pending_variant_id: variant.id,
        pending_renewal_amount_minor: 7_700,
        pending_renewal_currency: "EUR",
        change_effective_at: now
      })

    assert current_contract_change(subscription.id) == nil
    assert list_contract_changes(subscription.id) == []

    attempts_before = count_rows("renewal_attempts", subscription.id)
    orders_before = Store.Repo.aggregate(Order, :count, :id)
    intents_before = Store.Repo.aggregate(PaymentIntent, :count, :id)
    StripeAPIStub.stub_unexpected!("legacy pending data must block provider work")

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert count_rows("renewal_attempts", subscription.id) == attempts_before
    assert Store.Repo.aggregate(Order, :count, :id) == orders_before
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == intents_before

    assert current_contract_change(subscription.id) == nil
  end

  test "an orphaned queued ContractChange fails closed before attempt or provider work" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_renewal_guard")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_billing_ref: "pm_sbh_10_06_queued",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    SubscriptionsFixtures.create_plan_revision!(target_plan)
    assert {:ok, _queued} = queue_plan_change(customer, subscription, target_plan)
    clear_legacy_projection!(subscription.id)

    Store.Repo.query!(
      "UPDATE subscriptions SET current_contract_change_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    attempts_before = count_rows("renewal_attempts", subscription.id)
    orders_before = Store.Repo.aggregate(Order, :count, :id)
    intents_before = Store.Repo.aggregate(PaymentIntent, :count, :id)
    StripeAPIStub.stub_unexpected!("queued ContractChange must not start provider work")

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert count_rows("renewal_attempts", subscription.id) == attempts_before
    assert Store.Repo.aggregate(Order, :count, :id) == orders_before
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == intents_before
  end

  test "a newly queued ContractChange blocks legacy paid reconciliation" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_reconcile_guard")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 5_300})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_billing_ref: "pm_sbh_10_06_reconcile",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    renewal_order = reached.order
    period_end_before = fetch_subscription!(subscription.id).current_period_end_at

    SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, _queued} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), target_plan)

    clear_legacy_projection!(subscription.id)

    mark_collection_successful!(reached)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               renewal_order.id,
               exact_reconciliation_opts!(attempt)
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.current_period_end_at == period_end_before
    assert after_subscription.subscription_plan_id == current_plan.id
    assert Map.get(after_subscription, :current_contract_change_id) != nil
    assert fetch_attempt!(attempt.id).status == :processing
  end

  test "a bound ContractChange renewal applies its exact charged AccessEffect target" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_bound_effective_target")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:current"
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 5_700,
        currency: "EUR",
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:charged"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_billing_ref: "pm_sbh_10_06_bound_effective_target",
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
    assert {:ok, queued} = queue_plan_change(customer, subscription, target_plan)

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    contract_change_id = Map.get(queued, :current_contract_change_id)
    assert attempt.plan_revision_id == target_revision.id
    assert attempt.contract_change_id == contract_change_id

    bound_change = fetch_contract_change!(attempt.contract_change_id)
    assert bound_change.status == :bound_to_renewal
    assert bound_change.target_plan_revision_id == target_revision.id

    mark_collection_successful!(reached)

    Store.Repo.query!(
      "UPDATE subscription_plans SET entitlement_kind = 'membership_access', entitlement_scope_key = 'membership:decoy' WHERE id = $1",
      [Ecto.UUID.dump!(target_plan.id)]
    )

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               attempt.order_id,
               exact_reconciliation_opts!(attempt)
             )

    [effect] =
      AccessEffect
      |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
      |> Ash.Query.sort(source_version: :asc)
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    charged_revision =
      PlanRevision
      |> Ash.Query.filter(expr(id == ^attempt.plan_revision_id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert effect.disposition == :effective
    assert effect.status == :applied
    assert effect.plan_revision_id == attempt.plan_revision_id
    assert effect.entitlement_kind == charged_revision.entitlement_kind
    assert effect.entitlement_scope_key == charged_revision.entitlement_scope_key
    assert effect.entitlement_scope_key == "library:charged"
    assert effect.valid_from_at == attempt.period_start_at
    assert effect.valid_until_at == attempt.period_end_at

    applied = fetch_subscription!(subscription.id)
    assert applied.current_plan_revision_id == target_revision.id
    assert fetch_contract_change!(attempt.contract_change_id).status == :applied

    assert [%EntitlementGrant{kind: :digital_library, scope_key: "library:charged"} = grant] =
             EntitlementGrant
             |> Ash.Query.filter(expr(source_id == ^subscription.id and status == :active))
             |> Ash.read!(
               domain: Store.Entitlements,
               authorize?: false,
               context: %{system?: true}
             )

    assert grant.valid_from_at == attempt.period_start_at
    assert grant.valid_to_at == attempt.period_end_at
  end

  test "a succeeded reconciliation replay ignores a later ContractChange" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_succeeded_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_700})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_billing_ref: "pm_sbh_10_06_succeeded_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    renewal_order = reached.order
    payment_intent = reached.payment_intent

    mark_collection_successful!(reached)

    assert {:ok, %{applied?: false}} =
             Store.Payments.apply_payment_success_once(payment_intent.id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               renewal_order.id,
               exact_reconciliation_opts!(attempt)
             )

    succeeded_attempt = fetch_attempt!(attempt.id)
    assert succeeded_attempt.status == :succeeded

    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, queued} =
             queue_plan_change(customer, fetch_subscription!(subscription.id), target_plan)

    contract_change_id = Map.get(queued, :current_contract_change_id)
    contract_before_replay = fetch_contract_change!(contract_change_id)
    subscription_before_replay = fetch_subscription!(subscription.id)

    assert contract_before_replay.target_plan_revision_id == target_revision.id
    assert contract_before_replay.status == :queued

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               renewal_order.id,
               exact_reconciliation_opts!(attempt)
             )

    assert fetch_attempt!(attempt.id).status == :succeeded

    subscription_after_replay = fetch_subscription!(subscription.id)

    assert Map.take(subscription_after_replay, [
             :current_period_start_at,
             :current_period_end_at,
             :next_renewal_at,
             :subscription_plan_id,
             :variant_id,
             :renewal_amount_minor,
             :renewal_currency,
             :membership_key,
             :aggregate_version,
             :current_contract_change_id,
             :pending_subscription_plan_id,
             :pending_variant_id,
             :pending_renewal_amount_minor,
             :pending_renewal_currency,
             :change_effective_at
           ]) ==
             Map.take(subscription_before_replay, [
               :current_period_start_at,
               :current_period_end_at,
               :next_renewal_at,
               :subscription_plan_id,
               :variant_id,
               :renewal_amount_minor,
               :renewal_currency,
               :membership_key,
               :aggregate_version,
               :current_contract_change_id,
               :pending_subscription_plan_id,
               :pending_variant_id,
               :pending_renewal_amount_minor,
               :pending_renewal_currency,
               :change_effective_at
             ])

    contract_after_replay = fetch_contract_change!(contract_change_id)

    assert Map.take(contract_after_replay, [
             :id,
             :status,
             :ordering_version,
             :target_plan_revision_id,
             :target_variant_id,
             :target_quantity,
             :target_amount_minor,
             :target_currency
           ]) ==
             Map.take(contract_before_replay, [
               :id,
               :status,
               :ordering_version,
               :target_plan_revision_id,
               :target_variant_id,
               :target_quantity,
               :target_amount_minor,
               :target_currency
             ])
  end

  test "legacy pending projection cannot be promoted by paid reconciliation" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_06_legacy_paid")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_10_06_legacy_paid",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    renewal_order = reached.order
    before = fetch_subscription!(subscription.id)

    Store.Repo.query!(
      "UPDATE subscriptions SET pending_subscription_plan_id = $2, pending_renewal_amount_minor = $3, pending_renewal_currency = $4 WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id), Ecto.UUID.dump!(target_plan.id), 8_800, "EUR"]
    )

    mark_collection_successful!(reached)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               renewal_order.id,
               exact_reconciliation_opts!(attempt)
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.current_period_end_at == before.current_period_end_at
    assert after_subscription.renewal_amount_minor == before.renewal_amount_minor
    assert after_subscription.renewal_currency == before.renewal_currency
    assert after_subscription.pending_renewal_amount_minor == 8_800
    assert after_subscription.pending_renewal_currency == "EUR"
    assert fetch_attempt!(attempt.id).status == :processing
  end

  test "a stale concurrent queue writer re-evaluates and replaces writer A's target" do
    fixture = create_committed_subscription_fixture!()
    on_exit(fn -> delete_committed_subscription_fixture!(fixture) end)

    input_a = plan_change_input_for(fixture.subscription_id, fixture.plan_a_id)
    input_b = plan_change_input_for(fixture.subscription_id, fixture.plan_b_id)
    parent = self()

    lock_holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Store.Repo, fn ->
          Store.Repo.transaction(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Store.Repo.query("SELECT pg_backend_pid()")

            Store.Repo.query!(
              "SELECT aggregate_version FROM subscriptions WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(fixture.subscription_id)]
            )

            send(parent, {:subscription_locked, backend_pid})

            receive do
              :release -> :released
            after
              10_000 -> Store.Repo.rollback(:lock_holder_timeout)
            end
          end)
        end)
      end)

    assert_receive {:subscription_locked, holder_pid}

    writer_a = start_queue_writer(fixture, input_a, :a, parent)
    assert_receive {:queue_writer_started, :a}
    await_blocked_writers!(holder_pid, 1)

    writer_b = start_queue_writer(fixture, input_b, :b, parent)
    assert_receive {:queue_writer_started, :b}

    await_blocked_writers!(holder_pid, 2)

    send(lock_holder.pid, :release)
    assert {:ok, :released} = Task.await(lock_holder, 10_000)
    assert {:ok, _writer_a_subscription} = Task.await(writer_a, 10_000)
    assert {:ok, _writer_b_subscription} = Task.await(writer_b, 10_000)

    [queued_contract] =
      Enum.filter(list_contract_changes(fixture.subscription_id), &(&1.status == :queued))

    [superseded_contract] =
      Enum.filter(list_contract_changes(fixture.subscription_id), &(&1.status == :superseded))

    subscription = fetch_subscription!(fixture.subscription_id)

    assert Map.get(subscription, :current_contract_change_id) == queued_contract.id

    assert queued_contract.target_plan_revision_id in [
             fixture.revision_a_id,
             fixture.revision_b_id
           ]

    assert queued_contract.supersedes_contract_change_id == superseded_contract.id
    assert length(list_contract_changes(fixture.subscription_id)) == 2
  end

  test "PostgreSQL rejects competing current queued targets for one Subscription" do
    fixture = create_committed_subscription_fixture!()
    on_exit(fn -> delete_committed_subscription_fixture!(fixture) end)

    parent = self()
    change_resource = contract_change_resource()
    assert Code.ensure_loaded?(change_resource)

    tasks =
      [10, 11]
      |> Enum.map(fn ordering_version ->
        attrs = %{
          subscription_id: fixture.subscription_id,
          target_plan_revision_id: fixture.revision_a_id,
          target_variant_id: fixture.variant_id,
          target_quantity: 1,
          target_amount_minor: 2_400,
          target_currency: "USD",
          effective_at: fixture.effective_at,
          instruction_kind: :renew_unchanged,
          ordering_version: ordering_version
        }

        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            Store.Repo.transaction(fn ->
              {:ok, %{rows: [[backend_pid]]}} = Store.Repo.query("SELECT pg_backend_pid()")
              send(parent, {:contract_change_writer_ready, self(), backend_pid})

              receive do
                :insert -> :ok
              end

              change_resource
              |> Ash.Changeset.for_create(:queue, attrs, context: %{system?: true})
              |> Ash.create(
                domain: Store.Subscriptions,
                authorize?: false,
                context: %{system?: true},
                return_notifications?: true
              )
              |> case do
                {:ok, contract_change, _notifications} -> contract_change
                {:ok, contract_change} -> contract_change
                {:error, reason} -> Store.Repo.rollback(reason)
              end
            end)
          end)
        end)
      end)

    backend_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:contract_change_writer_ready, _pid, backend_pid}
        backend_pid
      end)

    assert length(Enum.uniq(backend_pids)) == 2
    Enum.each(tasks, &send(&1.pid, :insert))

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert count_queued_contract_changes(fixture.subscription_id) == 1
  end

  defp queue_plan_change(actor, subscription, %SubscriptionPlan{} = plan) do
    input = plan_change_input(subscription, plan)

    Facade.queue_subscription_plan_change_for_user(actor, subscription.id, input)
  end

  defp queue_variant_change(actor, subscription, variant) do
    {:ok, input} =
      QueueSubscriptionVariantChangeInput.new(%{
        "subscription_id" => subscription.id,
        "variant_id" => variant.id
      })

    Facade.queue_subscription_variant_change_for_user(actor, subscription.id, input)
  end

  defp plan_change_input(subscription, %SubscriptionPlan{} = plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => plan.id
      })

    input
  end

  defp contract_change_resource, do: Module.concat(Store.Subscriptions, ContractChange)

  defp fetch_contract_change!(id) do
    resource = contract_change_resource()
    assert Code.ensure_loaded?(resource)

    resource
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_contract_changes(subscription_id) do
    resource = contract_change_resource()
    assert Code.ensure_loaded?(resource)

    resource
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(ordering_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp current_contract_change(subscription_id) do
    case Map.get(fetch_subscription!(subscription_id), :current_contract_change_id) do
      nil -> nil
      contract_change_id -> fetch_contract_change!(contract_change_id)
    end
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection!(id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp exact_reconciliation_opts!(attempt) do
    collection =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    [
      renewal_attempt_id: attempt.id,
      collection_attempt_id: collection.id,
      payment_intent_id: collection.payment_intent_id
    ]
  end

  defp mark_collection_successful!(reached) do
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

    updated_collection = fetch_collection!(reached.collection.id)
    assert updated_collection.financial_outcome == :verified_success
    assert is_binary(updated_collection.payment_attempt_id)

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated_collection.payment_attempt_id,
                 payment_intent_id: reached.collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )
  end

  defp count_rows(table, subscription_id)
       when table in ["renewal_attempts"] do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query("SELECT count(*) FROM #{table} WHERE subscription_id = $1", [
        Ecto.UUID.dump!(subscription_id)
      ])

    count
  end

  defp count_queued_contract_changes(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query(
        "SELECT count(*) FROM contract_changes WHERE subscription_id = $1 AND status = 'queued'",
        [Ecto.UUID.dump!(subscription_id)]
      )

    count
  end

  defp clear_legacy_projection!(subscription_id) do
    Store.Repo.query!(
      "UPDATE subscriptions SET pending_subscription_plan_id = NULL, pending_variant_id = NULL, pending_renewal_amount_minor = NULL, pending_renewal_currency = NULL, change_effective_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(subscription_id)]
    )
  end

  defp plan_change_input_for(subscription_id, plan_id) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription_id,
        "subscription_plan_id" => plan_id
      })

    input
  end

  defp start_queue_writer(fixture, input, writer_name, parent) do
    Task.async(fn ->
      Sandbox.unboxed_run(Store.Repo, fn ->
        send(parent, {:queue_writer_started, writer_name})

        Facade.queue_subscription_plan_change_for_user(
          fixture.customer,
          fixture.subscription_id,
          input
        )
      end)
    end)
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
