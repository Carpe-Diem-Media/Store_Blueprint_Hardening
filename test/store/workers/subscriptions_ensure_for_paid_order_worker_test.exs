defmodule Store.Workers.SubscriptionsEnsureForPaidOrderWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Repo

  alias Store.Subscriptions.{
    AccessEffect,
    StoredPaymentMethod,
    Subscription,
    SubscriptionItem
  }

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.Workers.EnsureSubscriptionsForPaidOrderWorker

  test "worker creates subscriptions from paid order and is replay-safe across duplicate runs" do
    customer = SubscriptionsFixtures.create_customer!("phase26_worker_ensure")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:worker"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          provider_customer_ref: "cus_worker_001",
          provider_billing_ref: "pm_worker_001"
        }
      )

    assert :ok = perform_job(EnsureSubscriptionsForPaidOrderWorker, %{"order_id" => order.id})
    assert :ok = perform_job(EnsureSubscriptionsForPaidOrderWorker, %{"order_id" => order.id})

    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    assert length(subscription_ids) == 1

    assert 1 ==
             SubscriptionItem
             |> Ash.Query.filter(expr(subscription_id in ^subscription_ids))
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    [subscription] =
      Subscription
      |> Ash.Query.filter(expr(id in ^subscription_ids))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert subscription.provider_customer_ref == "cus_worker_001"
    assert subscription.provider_billing_ref == "pm_worker_001"
    assert is_binary(subscription.stored_payment_method_id)

    assert 1 ==
             StoredPaymentMethod
             |> Ash.Query.filter(
               expr(
                 user_id == ^customer.id and provider_customer_ref == ^"cus_worker_001" and
                   provider_payment_method_ref == ^"pm_worker_001"
               )
             )
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  @tag :jc360_task04
  test "worker returns the first F1 error and paid-order replay creates no duplicate rows" do
    customer = SubscriptionsFixtures.create_customer!("jc360_worker_f1_failure")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc360:worker-f1:#{Ecto.UUID.generate()}"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order, line_item: line_item} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          provider_customer_ref: "cus_jc360_worker_f1",
          provider_billing_ref: "pm_jc360_worker_f1"
        }
      )

    order_before = fetch_order!(order.id)
    [payment_intent_before] = succeeded_payment_intents_for_order(order.id)
    assert order_before.state == :paid
    assert payment_intent_before.state == :succeeded

    with_effect_application_rejection!(line_item.id, fn ->
      assert {:error, %Error{} = first_error} =
               perform_job(EnsureSubscriptionsForPaidOrderWorker, %{"order_id" => order.id}),
             "expected the worker to return the facade's first F1 error"

      [subscription] = subscriptions_for_order(order.id)
      [item] = subscription_items_for_source_line(line_item.id)
      [effect] = access_effects_for_source_line(line_item.id)
      assert subscription.source_order_line_item_id == line_item.id
      assert item.subscription_id == subscription.id
      assert item.source_order_line_item_id == line_item.id
      assert effect.subscription_id == subscription.id
      assert effect.source_order_line_item_id == line_item.id
      assert effect.status == :failed_retryable
      assert is_binary(first_error.code)
    end)

    source_ids = %{
      subscription_ids: Enum.map(subscriptions_for_order(order.id), & &1.id),
      item_ids: Enum.map(subscription_items_for_source_line(line_item.id), & &1.id),
      effect_ids: Enum.map(access_effects_for_source_line(line_item.id), & &1.id)
    }

    assert :ok = perform_job(EnsureSubscriptionsForPaidOrderWorker, %{"order_id" => order.id})

    [subscription] = subscriptions_for_order(order.id)
    [effect] = access_effects_for_source_line(line_item.id)
    assert effect.status == :applied
    assert Enum.map(subscriptions_for_order(order.id), & &1.id) == source_ids.subscription_ids

    assert Enum.map(subscription_items_for_source_line(line_item.id), & &1.id) ==
             source_ids.item_ids

    assert Enum.map(access_effects_for_source_line(line_item.id), & &1.id) ==
             source_ids.effect_ids

    assert length(entitlements_for_subscription(subscription.id)) == 1

    assert {:ok, replay} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert replay.order_id == order.id
    assert replay.subscription_line_count == 1
    assert replay.created_count == 0
    assert replay.skipped_count == 1
    assert replay.entitlement_issued_count == 0

    assert Enum.map(subscriptions_for_order(order.id), & &1.id) == source_ids.subscription_ids

    assert Enum.map(subscription_items_for_source_line(line_item.id), & &1.id) ==
             source_ids.item_ids

    assert Enum.map(access_effects_for_source_line(line_item.id), & &1.id) ==
             source_ids.effect_ids

    assert length(entitlements_for_subscription(subscription.id)) == 1
    assert fetch_order!(order.id) == order_before
    assert succeeded_payment_intents_for_order(order.id) == [payment_intent_before]
  end

  defp with_effect_application_rejection!(line_item_id, fun) do
    constraint = "jc360_worker_reject_f1_#{System.unique_integer([:positive])}"

    try do
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.query!("""
      ALTER TABLE access_effects
      ADD CONSTRAINT #{constraint}
      CHECK (
        status <> 'applied' OR
        source_order_line_item_id <> #{uuid_sql_literal!(line_item_id)}
      )
      NOT VALID
      """)

      fun.()
    after
      Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
    end
  end

  defp uuid_sql_literal!(uuid) do
    {:ok, canonical_uuid} = Ecto.UUID.cast(uuid)
    "'#{canonical_uuid}'::uuid"
  end

  defp subscriptions_for_order(order_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_id == ^order_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp subscription_items_for_source_line(line_item_id) do
    SubscriptionItem
    |> Ash.Query.filter(expr(source_order_line_item_id == ^line_item_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effects_for_source_line(line_item_id) do
    AccessEffect
    |> Ash.Query.filter(expr(source_order_line_item_id == ^line_item_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp entitlements_for_subscription(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp succeeded_payment_intents_for_order(order_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(order_id == ^order_id and state == :succeeded))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(order_id) do
    Order
    |> Ash.Query.filter(expr(id == ^order_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> List.first()
  end
end
