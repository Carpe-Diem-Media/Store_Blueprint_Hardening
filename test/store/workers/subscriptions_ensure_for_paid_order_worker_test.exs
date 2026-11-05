defmodule Store.Workers.SubscriptionsEnsureForPaidOrderWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
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
    fixture = create_committed_paid_order_fixture!("jc360_worker_f1_failure")

    Sandbox.unboxed_run(Repo, fn ->
      order_before = fetch_order!(fixture.order.id)
      [payment_intent_before] = succeeded_payment_intents_for_order(fixture.order.id)
      assert order_before.state == :paid
      assert payment_intent_before.state == :succeeded

      source_ids =
        with_effect_application_rejection!(fixture.line_item.id, fn ->
          assert {:error, %Error{} = first_error} =
                   perform_job(EnsureSubscriptionsForPaidOrderWorker, %{
                     "order_id" => fixture.order.id
                   }),
                 "expected the worker to return the facade's first F1 error"

          [subscription] = subscriptions_for_order(fixture.order.id)
          [item] = subscription_items_for_source_line(fixture.line_item.id)
          [effect] = access_effects_for_source_line(fixture.line_item.id)
          assert subscription.source_order_line_item_id == fixture.line_item.id
          assert item.subscription_id == subscription.id
          assert item.source_order_line_item_id == fixture.line_item.id
          assert effect.subscription_id == subscription.id
          assert effect.source_order_line_item_id == fixture.line_item.id
          assert effect.status == :failed_retryable
          assert is_binary(first_error.code)

          %{subscription_id: subscription.id, item_id: item.id, effect_id: effect.id}
        end)

      assert :ok =
               perform_job(EnsureSubscriptionsForPaidOrderWorker, %{
                 "order_id" => fixture.order.id
               })

      [subscription_after_duplicate] = subscriptions_for_order(fixture.order.id)
      [item_after_duplicate] = subscription_items_for_source_line(fixture.line_item.id)
      [effect_after_duplicate] = access_effects_for_source_line(fixture.line_item.id)
      assert subscription_after_duplicate.id == source_ids.subscription_id
      assert item_after_duplicate.id == source_ids.item_id
      assert effect_after_duplicate.id == source_ids.effect_id
      assert effect_after_duplicate.status == :failed_retryable
      assert entitlements_for_subscription(source_ids.subscription_id) == []
      assert fetch_order!(fixture.order.id) == order_before
      assert succeeded_payment_intents_for_order(fixture.order.id) == [payment_intent_before]

      assert {:ok, :applied} =
               SubscriptionsFacade.execute_effective_access_effect_for_system(
                 source_ids.effect_id
               )

      [applied_effect] = access_effects_for_source_line(fixture.line_item.id)
      assert applied_effect.id == source_ids.effect_id
      assert applied_effect.status == :applied

      [subscription_after_f1] = subscriptions_for_order(fixture.order.id)
      [item_after_f1] = subscription_items_for_source_line(fixture.line_item.id)
      assert subscription_after_f1.id == source_ids.subscription_id
      assert item_after_f1.id == source_ids.item_id

      [grant] = entitlements_for_subscription(source_ids.subscription_id)
      assert grant.user_id == subscription_after_f1.user_id
      assert grant.source_kind == :subscription
      assert grant.source_id == subscription_after_f1.id
      assert grant.kind == applied_effect.entitlement_kind
      assert grant.scope_key == applied_effect.entitlement_scope_key
      assert grant.status == :active
      assert grant.valid_from_at == applied_effect.valid_from_at
      assert grant.valid_to_at == applied_effect.valid_until_at
      assert grant.revoked_at == nil
      assert grant.revoked_reason == nil

      assert {:ok, replay} =
               SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
                 fixture.order.id
               )

      assert replay.order_id == fixture.order.id
      assert replay.subscription_line_count == 1
      assert replay.created_count == 0
      assert replay.skipped_count == 1
      assert replay.entitlement_issued_count == 0

      [subscription_after_replay] = subscriptions_for_order(fixture.order.id)
      [item_after_replay] = subscription_items_for_source_line(fixture.line_item.id)
      [effect_after_replay] = access_effects_for_source_line(fixture.line_item.id)
      [grant_after_replay] = entitlements_for_subscription(source_ids.subscription_id)
      assert subscription_after_replay.id == source_ids.subscription_id
      assert item_after_replay.id == source_ids.item_id
      assert effect_after_replay.id == source_ids.effect_id
      assert effect_after_replay.status == :applied
      assert grant_after_replay.id == grant.id
      assert fetch_order!(fixture.order.id) == order_before
      assert succeeded_payment_intents_for_order(fixture.order.id) == [payment_intent_before]
    end)
  end

  defp create_committed_paid_order_fixture!(prefix) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, fixture} =
          Repo.transaction(fn ->
            customer = SubscriptionsFixtures.create_customer!("#{prefix}_#{Ecto.UUID.generate()}")

            %{product: product, variant: variant} =
              SubscriptionsFixtures.create_subscription_sellable!()

            plan =
              SubscriptionsFixtures.create_subscription_plan!(%{
                entitlement_kind: :membership_access,
                entitlement_scope_key: "#{prefix}:#{Ecto.UUID.generate()}"
              })

            variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

            %{order: order, line_item: line_item, revision: revision} =
              SubscriptionsFixtures.create_paid_order_with_subscription_line!(
                customer.id,
                variant,
                plan,
                %{
                  provider_customer_ref: "cus_jc360_worker_f1",
                  provider_billing_ref: "pm_jc360_worker_f1"
                }
              )

            %{
              customer: customer,
              product: product,
              variant: variant,
              plan: plan,
              variant_plan: variant_plan,
              order: order,
              line_item: line_item,
              revision: revision
            }
          end)

        fixture
      end)

    on_exit(fn -> cleanup_committed_paid_order_fixture!(fixture) end)
    fixture
  end

  defp cleanup_committed_paid_order_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      order_id = Ecto.UUID.dump!(fixture.order.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      variant_plan_id = Ecto.UUID.dump!(fixture.variant_plan.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)
      user_id = Ecto.UUID.dump!(fixture.customer.id)

      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 Repo.query!(
                   """
                   DELETE FROM entitlement_grants
                   WHERE source_kind = 'subscription'
                     AND source_id IN (
                       SELECT id FROM subscriptions WHERE source_order_id = $1
                     )
                   """,
                   [order_id]
                 )

                 Repo.query!(
                   """
                   DELETE FROM access_effects
                   WHERE source_order_line_item_id = $1
                   """,
                   [line_item_id]
                 )

                 Repo.query!(
                   """
                   UPDATE subscriptions
                   SET current_dunning_renewal_attempt_id = NULL
                   WHERE source_order_id = $1
                   """,
                   [order_id]
                 )

                 Repo.query!(
                   """
                   DELETE FROM renewal_attempts
                   WHERE subscription_id IN (
                     SELECT id FROM subscriptions WHERE source_order_id = $1
                   )
                   """,
                   [order_id]
                 )

                 Repo.query!(
                   """
                   DELETE FROM subscription_items
                   WHERE source_order_line_item_id = $1
                   """,
                   [line_item_id]
                 )

                 Repo.query!("DELETE FROM subscriptions WHERE source_order_id = $1", [order_id])
                 Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
                 Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

                 Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [
                   variant_plan_id
                 ])

                 Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
                   plan_id
                 ])

                 Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
                 Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
                 Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
                 Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
                 :cleaned
               end)
    end)
  end

  defp with_effect_application_rejection!(line_item_id, fun) do
    constraint = "jc360_worker_reject_f1_#{System.unique_integer([:positive])}"

    try do
      assert {:ok, :added} =
               Repo.transaction(fn ->
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

                 :added
               end)

      fun.()
    after
      assert {:ok, :dropped} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL lock_timeout = '5s'")
                 Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
                 :dropped
               end)
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
