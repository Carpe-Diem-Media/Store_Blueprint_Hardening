defmodule Store.Subscriptions.Sbh1002ContractBindingTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.OrderLineItem
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  alias Store.Subscriptions.{PlanRevision, RenewalAttempt, Scheduler, Subscription}

  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures

  @revision_fields [
    :interval_unit,
    :interval_count,
    :currency,
    :amount_minor,
    :trial_days,
    :anchor_mode,
    :anchor_day_of_month,
    :billing_timezone,
    :term_mode,
    :term_cycles,
    :term_end_at,
    :access_on_past_due,
    :access_on_cancel,
    :grace_period_days,
    :max_retry_attempts,
    :retry_schedule_hours,
    :entitlement_kind,
    :entitlement_scope_key
  ]

  test "paid subscription creation binds the revision frozen on the order line" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_bind")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    revision = publish_revision!(plan)

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan, revision)

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    subscription = fetch_subscription_for_order!(order.id)
    assert Map.get(subscription, :current_plan_revision_id) == revision.id
  end

  test "forward subscription creation rejects an unresolved contract binding" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_forward_binding")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    %{order: order, line_item: line_item} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    attrs =
      subscription
      |> Map.from_struct()
      |> Map.take([
        :user_id,
        :subscription_plan_id,
        :variant_id,
        :status,
        :provider,
        :billing_mode,
        :quantity,
        :renewal_amount_minor,
        :renewal_currency,
        :membership_key,
        :started_at,
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at,
        :dunning_attempt_count,
        :source_order_id
      ])
      |> Map.merge(%{
        source_order_id: order.id,
        source_order_line_item_id: line_item.id,
        current_plan_revision_id: nil
      })

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Subscription
             |> Ash.Changeset.for_create(:create_from_order_line, attrs,
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert Enum.any?(errors, fn error ->
             error.field == :current_plan_revision_id and
               error.message == "subscription commercial contract is unresolved"
           end)
  end

  test "paid subscription creation rejects a revision belonging to another plan" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_mismatch")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan_a = SubscriptionsFixtures.create_subscription_plan!()
    plan_b = SubscriptionsFixtures.create_subscription_plan!()
    revision_b = publish_revision!(plan_b)

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan_a, revision_b)

    assert {:error, _error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert fetch_subscriptions_for_order(order.id) == []
  end

  test "paid subscription creation rejects a frozen draft revision" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_draft_evidence")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    draft_revision = create_draft_revision!(plan)

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan, draft_revision)

    assert {:error,
            %{
              code: "VALIDATION_ERROR",
              message: "purchased plan revision was never effective"
            }} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert draft_revision.status == :draft
    assert fetch_subscriptions_for_order(order.id) == []
  end

  test "paid subscription creation keeps a retired purchased revision after rotation" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_rotation")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    revision_x = publish_revision!(plan, %{amount_minor: 1_111})

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan, revision_x)

    assert {:ok, retired_x} =
             revision_x
             |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    revision_y = publish_revision!(plan, %{amount_minor: 2_222})
    assert retired_x.status == :retired
    assert revision_y.status == :effective

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    subscription = fetch_subscription_for_order!(order.id)
    assert Map.get(subscription, :current_plan_revision_id) == revision_x.id
  end

  test "initial scheduling uses the frozen revision after mutable plan drift" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_drift")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()

    revision =
      publish_revision!(plan, %{
        interval_unit: :day,
        interval_count: 2,
        amount_minor: 1_111
      })

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan, revision, %{
        amount_minor: revision.amount_minor
      })

    assert {:ok, _updated_plan} =
             plan
             |> Ash.Changeset.for_update(
               :update,
               %{interval_unit: :year, interval_count: 1, amount_minor: 9_999},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    subscription = fetch_subscription_for_order!(order.id)
    {:ok, expected_period} = Scheduler.initial_period(subscription.started_at, revision)

    assert subscription.current_period_end_at == expected_period.current_period_end_at
    assert subscription.renewal_amount_minor == revision.amount_minor
  end

  test "paid subscription creation uses the frozen revision after plan archival" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_archived_plan")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()

    revision =
      publish_revision!(plan, %{
        interval_unit: :day,
        interval_count: 2,
        amount_minor: 1_111
      })

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan, revision)

    assert {:ok, archived_plan} =
             plan
             |> Ash.Changeset.for_update(:archive, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert archived_plan.status == :archived

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    subscription = fetch_subscription_for_order!(order.id)
    {:ok, expected_period} = Scheduler.initial_period(subscription.started_at, revision)

    assert Map.get(subscription, :current_plan_revision_id) == revision.id
    assert subscription.renewal_amount_minor == revision.amount_minor
    assert subscription.current_period_end_at == expected_period.current_period_end_at
  end

  test "replay preserves the original frozen revision binding" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    revision = publish_revision!(plan)

    %{order: order} =
      create_paid_order_with_frozen_revision!(customer.id, variant, plan, revision)

    assert {:ok, %{created_count: 1, skipped_count: 0}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    first = fetch_subscription_for_order!(order.id)

    assert {:ok, %{created_count: 0, skipped_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    second = fetch_subscription_for_order!(order.id)
    assert first.id == second.id
    assert Map.get(second, :current_plan_revision_id) == revision.id
  end

  test "unresolved legacy subscriptions do not start renewal or mutate lifecycle state" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_legacy_renewal")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    clear_revision_binding!(subscription.id)
    before = fetch_subscription!(subscription.id)

    assert {:ok, result} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

    assert result.due_count == 1
    assert count_renewal_attempts(subscription.id) == 0

    after_attempt = fetch_subscription!(subscription.id)
    assert after_attempt.status == before.status
    assert after_attempt.next_renewal_at == before.next_renewal_at
    assert after_attempt.past_due_since_at == before.past_due_since_at
    assert after_attempt.next_retry_at == before.next_retry_at
    assert after_attempt.retry_suppressed_at == before.retry_suppressed_at
    assert after_attempt.dunning_attempt_count == before.dunning_attempt_count
  end

  test "paid renewal reconciliation leaves an unresolved legacy subscription untouched" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_legacy_reconcile")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:mutable-plan"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        dunning_attempt_count: 2,
        next_retry_at: DateTime.add(now, 3_600, :second)
      })

    payment_intent = fetch_payment_intent_for_order!(order.id)
    attempt = create_paid_renewal_attempt!(subscription, order, payment_intent)

    clear_revision_binding!(subscription.id)
    before_subscription = fetch_subscription!(subscription.id)
    before_attempt = fetch_attempt!(attempt.id)

    assert count_entitlements(subscription.id) == 0

    assert {:error,
            %{
              code: "VALIDATION_ERROR",
              message: "renewal attempt has no durable charged-contract binding"
            }} =
             SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(order.id,
               renewal_attempt_id: attempt.id
             )

    after_subscription = fetch_subscription!(subscription.id)
    after_attempt = fetch_attempt!(attempt.id)

    assert Map.take(after_subscription, [
             :current_plan_revision_id,
             :current_period_start_at,
             :current_period_end_at,
             :next_renewal_at,
             :status,
             :renewal_amount_minor,
             :renewal_currency,
             :membership_key,
             :dunning_attempt_count,
             :next_retry_at,
             :retry_suppressed_at,
             :past_due_since_at,
             :pending_subscription_plan_id,
             :pending_variant_id,
             :pending_renewal_amount_minor,
             :pending_renewal_currency,
             :change_effective_at
           ]) ==
             Map.take(before_subscription, [
               :current_plan_revision_id,
               :current_period_start_at,
               :current_period_end_at,
               :next_renewal_at,
               :status,
               :renewal_amount_minor,
               :renewal_currency,
               :membership_key,
               :dunning_attempt_count,
               :next_retry_at,
               :retry_suppressed_at,
               :past_due_since_at,
               :pending_subscription_plan_id,
               :pending_variant_id,
               :pending_renewal_amount_minor,
               :pending_renewal_currency,
               :change_effective_at
             ])

    assert Map.take(after_attempt, [:status, :order_id, :payment_intent_id, :updated_at]) ==
             Map.take(before_attempt, [:status, :order_id, :payment_intent_id, :updated_at])

    assert count_entitlements(subscription.id) == 0
  end

  test "unresolved legacy subscriptions reject queued commercial plan changes" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_02_legacy_change")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    current_plan = SubscriptionsFixtures.create_subscription_plan!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan)

    clear_revision_binding!(subscription.id)

    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               "subscription_id" => subscription.id,
               "subscription_plan_id" => target_plan.id
             })

    assert {:error, error} =
             SubscriptionsFacade.queue_subscription_plan_change_for_user(
               customer,
               subscription.id,
               input
             )

    assert error.code == "VALIDATION_ERROR"
    assert error.message == "subscription commercial contract is unresolved"

    unchanged = fetch_subscription!(subscription.id)
    assert unchanged.status == :active
    assert unchanged.pending_subscription_plan_id == nil
    assert unchanged.pending_variant_id == nil
    assert unchanged.pending_renewal_amount_minor == nil
    assert unchanged.pending_renewal_currency == nil
  end

  defp create_paid_order_with_frozen_revision!(user_id, variant, plan, revision, overrides \\ %{}) do
    overrides = Map.put_new(overrides, :create_plan_revision?, false)

    %{order: order, line_item: line_item} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        user_id,
        variant,
        plan,
        overrides
      )

    assert %{num_rows: 1} =
             Store.Repo.query!(
               "UPDATE order_line_items SET subscription_plan_revision_id_snapshot = $1 WHERE id = $2",
               [Ecto.UUID.dump!(revision.id), Ecto.UUID.dump!(line_item.id)]
             )

    %{order: order, line_item: reload_line_item!(line_item.id)}
  end

  defp reload_line_item!(line_item_id) do
    OrderLineItem
    |> Ash.Query.filter(expr(id == ^line_item_id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp clear_revision_binding!(subscription_id) do
    assert %{num_rows: 1} =
             Store.Repo.query!(
               "UPDATE subscriptions SET current_plan_revision_id = NULL WHERE id = $1",
               [Ecto.UUID.dump!(subscription_id)]
             )
  end

  defp count_renewal_attempts(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_entitlements(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.count!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent_for_order!(order_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp create_paid_renewal_attempt!(subscription, order, payment_intent) do
    period_start_at = subscription.current_period_end_at
    period_end_at = DateTime.add(period_start_at, 31, :day)

    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: subscription.id,
        period_start_at: period_start_at,
        period_end_at: period_end_at,
        renewal_key: Scheduler.renewal_key(subscription.id, period_start_at),
        status: :processing,
        order_id: order.id,
        payment_intent_id: payment_intent.id
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(attempt_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription_for_order!(order_id) do
    case fetch_subscriptions_for_order(order_id) do
      [%Subscription{} = subscription] -> subscription
      subscriptions -> flunk("expected one subscription, got: #{inspect(subscriptions)}")
    end
  end

  defp fetch_subscriptions_for_order(order_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_id == ^order_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp publish_revision!(plan, overrides \\ %{}) do
    revision = create_draft_revision!(plan, overrides)

    revision
    |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_draft_revision!(plan, overrides \\ %{}) do
    attrs =
      plan
      |> Map.take(@revision_fields)
      |> Map.put(:subscription_plan_id, plan.id)
      |> Map.merge(overrides)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
