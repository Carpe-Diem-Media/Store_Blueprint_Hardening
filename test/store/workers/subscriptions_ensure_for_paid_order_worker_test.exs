defmodule Store.Workers.SubscriptionsEnsureForPaidOrderWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.AccessEffectTargetOrder
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput

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

  @tag :jc360_task06
  test "duplicate paid-order jobs preserve every existing effect lifecycle state and source identity" do
    fixture = create_committed_paid_order_fixture!("jc360_worker_replay_states", 4)
    [applied_line, failed_line, pending_line, superseded_line] = fixture.line_items

    Sandbox.unboxed_run(Repo, fn ->
      order_before = fetch_order!(fixture.order.id)
      [payment_intent_before] = succeeded_payment_intents_for_order(fixture.order.id)
      assert order_before.state == :paid
      assert payment_intent_before.state == :succeeded

      assert {:error, %Error{}} =
               with_effect_application_rejection!(failed_line.id, fn ->
                 perform_job(EnsureSubscriptionsForPaidOrderWorker, %{
                   "order_id" => fixture.order.id
                 })
               end)

      [pending_effect] = access_effects_for_source_line(pending_line.id)
      assert pending_effect.status == :required

      assert {:ok, %{id: pending_effect_id, status: :pending}} =
               SubscriptionsFacade.mark_access_effect_pending_for_system(pending_effect)

      assert pending_effect_id == pending_effect.id

      [superseded_subscription] =
        Enum.filter(subscriptions_for_order(fixture.order.id), fn subscription ->
          subscription.source_order_line_item_id == superseded_line.id
        end)

      assert %{num_rows: 1} =
               Repo.query!(
                 "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
                 [Ecto.UUID.dump!(superseded_subscription.id)]
               )

      superseded_subscription = fetch_subscription!(superseded_subscription.id)

      {:ok, superseding_input} =
        initial_effect_input!(superseded_subscription, List.last(fixture.revisions))

      assert {:ok, superseding_effect} =
               SubscriptionsFacade.establish_access_effect_for_system(superseding_input)

      superseding_effect_id = superseding_effect.id

      assert [superseded_effect, persisted_superseding_effect] =
               access_effects_for_source_line(superseded_line.id)
               |> Enum.sort_by(& &1.source_version)

      assert superseded_effect.status == :superseded
      assert persisted_superseding_effect.id == superseding_effect_id
      assert persisted_superseding_effect.status == :required

      before_replay = paid_order_replay_snapshot(fixture)
      assert length(before_replay) == 4

      assert Enum.map(before_replay, &Enum.map(&1.effects, fn effect -> effect.status end)) ==
               [[:applied], [:failed_retryable], [:pending], [:superseded, :required]]

      assert Enum.sum(Enum.map(before_replay, &length(&1.effects))) == 5
      assert Enum.sum(Enum.map(before_replay, &length(&1.grants))) == 1
      assert Enum.map(before_replay, &length(&1.items)) == [1, 1, 1, 1]

      assert [%{effects: [%{status: :applied}]}] =
               Enum.filter(before_replay, &(&1.line_item_id == applied_line.id))

      assert :ok =
               perform_job(EnsureSubscriptionsForPaidOrderWorker, %{
                 "order_id" => fixture.order.id
               })

      assert paid_order_replay_snapshot(fixture) == before_replay

      assert :ok =
               perform_job(EnsureSubscriptionsForPaidOrderWorker, %{
                 "order_id" => fixture.order.id
               })

      assert paid_order_replay_snapshot(fixture) == before_replay

      assert {:ok, replay} =
               SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
                 fixture.order.id
               )

      assert replay.order_id == fixture.order.id
      assert replay.subscription_line_count == 4
      assert replay.created_count == 0
      assert replay.skipped_count == 4
      assert replay.entitlement_issued_count == 0
      assert paid_order_replay_snapshot(fixture) == before_replay
      assert fetch_order!(fixture.order.id) == order_before
      assert succeeded_payment_intents_for_order(fixture.order.id) == [payment_intent_before]
    end)
  end

  defp create_committed_paid_order_fixture!(prefix, line_count \\ 1) do
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

            additional_sources =
              create_additional_paid_order_sources!(line_count, prefix, order, variant)

            plans = [plan | Enum.map(additional_sources, & &1.plan)]
            revisions = [revision | Enum.map(additional_sources, & &1.revision)]
            variant_plans = [variant_plan | Enum.map(additional_sources, & &1.variant_plan)]
            line_items = [line_item | Enum.map(additional_sources, & &1.line_item)]

            %{
              customer: customer,
              product: product,
              variant: variant,
              plan: plan,
              variant_plan: variant_plan,
              variant_plans: variant_plans,
              order: order,
              line_item: line_item,
              line_items: line_items,
              revision: revision,
              revisions: revisions,
              plans: plans
            }
          end)

        fixture
      end)

    on_exit(fn -> cleanup_committed_paid_order_fixture!(fixture) end)
    fixture
  end

  defp create_additional_paid_order_sources!(line_count, prefix, order, variant) do
    line_numbers = if line_count > 1, do: 2..line_count, else: []

    Enum.map(line_numbers, fn line_no ->
      additional_plan =
        SubscriptionsFixtures.create_subscription_plan!(%{
          entitlement_kind: :membership_access,
          entitlement_scope_key: "#{prefix}:line#{line_no}:#{Ecto.UUID.generate()}"
        })

      variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, additional_plan.id)
      additional_revision = SubscriptionsFixtures.create_plan_revision!(additional_plan)

      additional_line =
        create_paid_order_line_for_revision!(
          order,
          variant,
          additional_plan,
          additional_revision,
          line_no
        )

      %{
        line_item: additional_line,
        plan: additional_plan,
        revision: additional_revision,
        variant_plan: variant_plan
      }
    end)
  end

  defp create_paid_order_line_for_revision!(order, variant, plan, revision, line_no) do
    OrderLineItem
    |> Ash.Changeset.for_create(
      :create,
      %{
        order_id: order.id,
        line_no: line_no,
        currency: String.upcase(revision.currency),
        quantity: 1,
        unit_price_minor: revision.amount_minor,
        line_total_minor: revision.amount_minor,
        sku_snapshot: variant.sku || "JC360-WORKER-SUB-LINE",
        product_title_snapshot: "JC360 worker subscription product",
        variant_title_snapshot: variant.title || "Default",
        variant_id_snapshot: variant.id,
        subscription_plan_id_snapshot: plan.id,
        subscription_plan_revision_id_snapshot: revision.id,
        subscription_plan_key_snapshot: plan.key,
        subscription_interval_unit_snapshot: Atom.to_string(revision.interval_unit),
        subscription_interval_count_snapshot: revision.interval_count,
        discount_allocated_minor: 0,
        net_line_total_minor: revision.amount_minor,
        tax_category_snapshot: "STANDARD",
        tax_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp cleanup_committed_paid_order_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      order_id = Ecto.UUID.dump!(fixture.order.id)
      line_item_ids = Enum.map(fixture.line_items, &Ecto.UUID.dump!(&1.id))
      variant_plan_ids = Enum.map(fixture.variant_plans, &Ecto.UUID.dump!(&1.id))
      plan_ids = Enum.map(fixture.plans, &Ecto.UUID.dump!(&1.id))
      product_id = Ecto.UUID.dump!(fixture.product.id)
      user_id = Ecto.UUID.dump!(fixture.customer.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)

      subscription_ids =
        Repo.query!("SELECT id FROM subscriptions WHERE source_order_id = $1", [order_id]).rows
        |> Enum.map(&List.first/1)

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
                   WHERE subscription_id IN (
                     SELECT id FROM subscriptions WHERE source_order_id = $1
                   )
                   """,
                   [order_id]
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
                   WHERE subscription_id IN (
                     SELECT id FROM subscriptions WHERE source_order_id = $1
                   )
                   """,
                   [order_id]
                 )

                 Repo.query!("DELETE FROM subscriptions WHERE source_order_id = $1", [order_id])
                 Repo.query!("DELETE FROM order_line_items WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM payment_applications WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

                 delete_committed_paid_order_variant_plans!(variant_plan_ids)

                 delete_committed_paid_order_plans!(plan_ids)

                 Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
                 Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
                 Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
                 :cleaned
               end)

      assert_committed_paid_order_fixture_removed!(fixture, %{
        order_id: order_id,
        line_item_ids: line_item_ids,
        variant_plan_ids: variant_plan_ids,
        plan_ids: plan_ids,
        product_id: product_id,
        variant_id: variant_id,
        user_id: user_id,
        subscription_ids: subscription_ids
      })
    end)
  end

  defp delete_committed_paid_order_plans!(plan_ids) do
    Enum.each(plan_ids, fn plan_id ->
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
    end)
  end

  defp delete_committed_paid_order_variant_plans!(variant_plan_ids) do
    Enum.each(variant_plan_ids, fn variant_plan_id ->
      Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [variant_plan_id])
    end)
  end

  defp assert_committed_paid_order_fixture_removed!(fixture, ids) do
    checks = [
      {"subscriptions", "SELECT count(*) FROM subscriptions WHERE source_order_id = $1",
       [ids.order_id]},
      {"orders", "SELECT count(*) FROM orders WHERE id = $1", [ids.order_id]},
      {"order_line_items", "SELECT count(*) FROM order_line_items WHERE order_id = $1",
       [ids.order_id]},
      {"order_adjustments", "SELECT count(*) FROM order_adjustments WHERE order_id = $1",
       [ids.order_id]},
      {"fulfillment_orders", "SELECT count(*) FROM fulfillment_orders WHERE order_id = $1",
       [ids.order_id]},
      {"payment_intents", "SELECT count(*) FROM payment_intents WHERE order_id = $1",
       [ids.order_id]},
      {"products", "SELECT count(*) FROM products WHERE id = $1", [ids.product_id]},
      {"variants", "SELECT count(*) FROM variants WHERE id = $1", [ids.variant_id]},
      {"users", "SELECT count(*) FROM users WHERE id = $1", [ids.user_id]}
    ]

    Enum.each(checks, fn {table, query, params} ->
      assert %{rows: [[0]]} = Repo.query!(query, params),
             "committed fixture cleanup left rows in #{table}"
    end)

    Enum.each(ids.line_item_ids, fn line_item_id ->
      checks = [
        {"subscription_items",
         "SELECT count(*) FROM subscription_items WHERE source_order_line_item_id = $1"},
        {"access_effects",
         "SELECT count(*) FROM access_effects WHERE source_order_line_item_id = $1"}
      ]

      Enum.each(checks, fn {table, query} ->
        assert %{rows: [[0]]} = Repo.query!(query, [line_item_id]),
               "committed fixture cleanup left rows in #{table}"
      end)
    end)

    Enum.each(ids.subscription_ids, fn subscription_id ->
      checks = [
        {"entitlement_grants", "SELECT count(*) FROM entitlement_grants WHERE source_id = $1"},
        {"renewal_attempts", "SELECT count(*) FROM renewal_attempts WHERE subscription_id = $1"}
      ]

      Enum.each(checks, fn {table, query} ->
        assert %{rows: [[0]]} = Repo.query!(query, [subscription_id]),
               "committed fixture cleanup left rows in #{table}"
      end)
    end)

    Enum.each(ids.variant_plan_ids, fn variant_plan_id ->
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM variant_subscription_plans WHERE id = $1", [
                 variant_plan_id
               ])
    end)

    Enum.each(ids.plan_ids, fn plan_id ->
      for {table, query} <- [
            {"plan_revisions",
             "SELECT count(*) FROM plan_revisions WHERE subscription_plan_id = $1"},
            {"subscription_plans", "SELECT count(*) FROM subscription_plans WHERE id = $1"}
          ] do
        assert %{rows: [[0]]} = Repo.query!(query, [plan_id]),
               "committed fixture cleanup left rows in #{table}"
      end
    end)

    assert length(fixture.line_items) == length(ids.line_item_ids)
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

  defp initial_effect_input!(subscription, revision) do
    {:ok, target} = AccessEffectTargetOrder.derive_current_target(subscription, revision)

    target
    |> Map.merge(%{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version
    })
    |> EstablishAccessEffectInput.new()
  end

  defp paid_order_replay_snapshot(fixture) do
    subscriptions = subscriptions_for_order(fixture.order.id)

    Enum.map(fixture.line_items, fn line_item ->
      [subscription] =
        Enum.filter(subscriptions, &(&1.source_order_line_item_id == line_item.id))

      [item] = subscription_items_for_source_line(line_item.id)

      effects =
        line_item.id
        |> access_effects_for_source_line()
        |> Enum.sort_by(& &1.source_version)
        |> Enum.map(fn effect ->
          Map.take(effect, [
            :id,
            :subscription_id,
            :source_order_line_item_id,
            :plan_revision_id,
            :source_version,
            :status,
            :disposition,
            :entitlement_kind,
            :entitlement_scope_key,
            :valid_from_at,
            :valid_until_at,
            :target_fingerprint,
            :projection_user_ids,
            :projection_delivered_at,
            :inserted_at,
            :updated_at
          ])
        end)

      grants =
        subscription.id
        |> entitlements_for_subscription()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn grant ->
          Map.take(grant, [
            :id,
            :user_id,
            :source_kind,
            :source_id,
            :kind,
            :scope_key,
            :status,
            :valid_from_at,
            :valid_to_at,
            :revoked_at,
            :revoked_reason
          ])
        end)

      %{
        line_item_id: line_item.id,
        subscription:
          Map.take(subscription, [
            :id,
            :source_order_id,
            :source_order_line_item_id,
            :subscription_plan_id,
            :current_plan_revision_id,
            :aggregate_version,
            :current_period_start_at,
            :current_period_end_at
          ]),
        items: [
          Map.take(item, [
            :id,
            :subscription_id,
            :source_order_line_item_id,
            :variant_id,
            :quantity,
            :plan_key_snapshot,
            :amount_minor_snapshot,
            :currency_snapshot,
            :interval_unit_snapshot,
            :interval_count_snapshot
          ])
        ],
        effects: effects,
        grants: grants
      }
    end)
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

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
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
