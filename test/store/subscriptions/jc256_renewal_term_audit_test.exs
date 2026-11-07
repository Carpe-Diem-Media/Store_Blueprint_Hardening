defmodule Store.Subscriptions.JC256RenewalTermAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Catalog.InventoryItem
  alias Store.Entitlements.Cache
  alias Store.Orders.{Order, PaymentApplication}
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.{Facade, RenewalAttempt, RenewalCollectionAttempt}
  alias Store.Subscriptions.{RenewalCollectionAttempts, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  @reference_at ~U[2026-06-01 00:00:00Z]

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "fixed end before, at, and after the renewal start boundary has no fresh dispatch" do
    for {label, term_end_at} <- [
          {"before", DateTime.add(@reference_at, -1, :second)},
          {"equal", @reference_at},
          {"after", DateTime.add(@reference_at, 1, :second)}
        ] do
      fixture =
        create_fixture!("fixed_end_#{label}", %{
          term_mode: :fixed_end_at,
          term_end_at: term_end_at
        })

      on_exit(fn -> cleanup_fixture!(fixture) end)

      assert [] =
               Sandbox.unboxed_run(Repo, fn -> fetch_attempts!(fixture.subscription.id) end)

      {subscription, attempt, collection, payment_intent, order} =
        reject_fresh_dispatch!(fixture, @reference_at)

      assert attempt.subscription_id == fixture.subscription.id
      assert collection.renewal_attempt_id == attempt.id
      assert payment_intent.order_id == order.id

      reached = prepare_legacy_success!(fixture, @reference_at, attempt.id)
      assert reached.source == :synthetic_legacy_possible_contact
      assert reached.order.id == order.id
      assert reached.order.grand_total_minor > 0
      assert reached.payment_intent.currency == reached.order.currency_code
      process_legacy_success!(reached)

      {paid_attempt, paid_collection, paid_intent, paid_order, applications} =
        fetch_paid_evidence!(attempt.id, collection.id)

      recovered_subscription =
        Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

      unchanged_fields = [
        :status,
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at
      ]

      assert Map.take(recovered_subscription, unchanged_fields) ==
               Map.take(subscription, unchanged_fields)

      snapshot = paid_attempt.charged_contract_snapshot
      assert snapshot["term_mode"] == "fixed_end_at"
      assert {:ok, snapshot_end_at, _offset} = DateTime.from_iso8601(snapshot["term_end_at"])
      assert DateTime.compare(snapshot_end_at, term_end_at) == :eq
      assert DateTime.compare(paid_attempt.period_start_at, @reference_at) == :eq

      assert DateTime.compare(
               paid_attempt.period_end_at,
               DateTime.add(@reference_at, 86_400, :second)
             ) == :eq

      assert DateTime.compare(subscription.current_period_end_at, @reference_at) == :eq
      assert DateTime.compare(subscription.next_renewal_at, @reference_at) == :eq
      assert paid_collection.financial_outcome == :verified_success
      assert paid_intent.state == :succeeded
      assert paid_order.state == :paid
      assert length(applications) == 1
      assert_success_handoff!(paid_attempt, paid_collection, paid_intent, paid_order)
    end
  end

  test "fixed cycle plans permit N plus one paid extensions through synthetic legacy recovery" do
    for cycles <- [1, 3] do
      fixture =
        create_fixture!("fixed_cycles_#{cycles}", %{
          term_mode: :fixed_cycles,
          term_cycles: cycles
        })

      on_exit(fn -> cleanup_fixture!(fixture) end)

      successful_period_ends =
        for _extension <- 1..(cycles + 1) do
          before =
            Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

          assert before.status == :active
          assert DateTime.compare(before.next_renewal_at, before.current_period_end_at) == :eq

          previous_attempts =
            Sandbox.unboxed_run(Repo, fn -> fetch_attempts!(fixture.subscription.id) end)

          assert Enum.all?(previous_attempts, &(&1.status == :succeeded))

          {_blocked_subscription, fresh_attempt, fresh_collection, _fresh_intent, _fresh_order} =
            reject_fresh_dispatch!(fixture, before.next_renewal_at, length(previous_attempts))

          reached = prepare_legacy_success!(fixture, before.next_renewal_at, fresh_attempt.id)
          assert reached.source == :synthetic_legacy_possible_contact
          assert reached.collection.id == fresh_collection.id
          process_legacy_success!(reached)

          {attempt, collection} = {reached.attempt, reached.collection}

          assert attempt.subscription_id == fixture.subscription.id
          assert attempt.payment_intent_id == collection.payment_intent_id
          assert collection.renewal_attempt_id == attempt.id
          assert attempt.charged_contract_snapshot["term_mode"] == "fixed_cycles"
          assert attempt.charged_contract_snapshot["term_cycles"] == cycles

          {paid_attempt, paid_collection, payment_intent, paid_order, applications} =
            fetch_paid_evidence!(attempt.id, collection.id)

          assert paid_attempt.order_id == reached.order.id
          assert paid_collection.financial_outcome == :verified_success
          assert payment_intent.state == :succeeded
          assert paid_order.grand_total_minor > 0
          assert paid_order.currency_code == payment_intent.currency
          assert length(applications) == 1

          assert {:ok, handoff} =
                   Sandbox.unboxed_run(Repo, fn ->
                     RenewalCollectionAttempts.success_handoff_for_system(collection.id)
                   end)

          assert handoff.order_id == paid_order.id
          assert handoff.renewal_attempt_id == attempt.id
          assert handoff.collection_attempt_id == collection.id
          assert handoff.payment_intent_id == collection.payment_intent_id

          assert {:ok, :reconciled} =
                   Sandbox.unboxed_run(Repo, fn ->
                     Facade.reconcile_paid_subscription_renewal_for_system(
                       handoff.order_id,
                       renewal_attempt_id: handoff.renewal_attempt_id,
                       collection_attempt_id: handoff.collection_attempt_id,
                       payment_intent_id: handoff.payment_intent_id
                     )
                   end)

          {paid_attempt, paid_subscription} =
            Sandbox.unboxed_run(Repo, fn ->
              {fetch_attempt!(attempt.id), fetch_subscription!(fixture.subscription.id)}
            end)

          assert paid_attempt.status == :succeeded
          assert paid_subscription.status == :active

          assert DateTime.compare(
                   paid_subscription.current_period_end_at,
                   before.current_period_end_at
                 ) == :gt

          assert DateTime.compare(
                   paid_subscription.current_period_end_at,
                   paid_attempt.period_end_at
                 ) == :eq

          assert not is_nil(paid_subscription.next_renewal_at)
          paid_attempt.period_end_at
        end

      assert length(successful_period_ends) == cycles + 1

      final_subscription =
        Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

      assert DateTime.compare(
               final_subscription.current_period_end_at,
               List.last(successful_period_ends)
             ) == :eq

      assert final_subscription.status == :active
      assert not is_nil(final_subscription.next_renewal_at)
    end
  end

  test "provider-managed label has no fresh dispatch and only synthetic legacy recovery" do
    fixture =
      create_fixture!("provider_managed", %{term_mode: :until_canceled}, :provider_managed)

    on_exit(fn -> cleanup_fixture!(fixture) end)

    {subscription, attempt, collection, _payment_intent, _order} =
      reject_fresh_dispatch!(fixture, @reference_at)

    reached = prepare_legacy_success!(fixture, @reference_at, attempt.id)
    assert reached.source == :synthetic_legacy_possible_contact
    process_legacy_success!(reached)

    {paid_attempt, paid_collection, payment_intent, order, applications} =
      fetch_paid_evidence!(attempt.id, collection.id)

    recovered_subscription =
      Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

    assert subscription.billing_mode == :provider_managed
    assert is_nil(subscription.provider_subscription_id)
    assert subscription.status == :active
    assert recovered_subscription.billing_mode == subscription.billing_mode
    assert recovered_subscription.provider_subscription_id == nil
    assert recovered_subscription.status == :active
    assert attempt.subscription_id == fixture.subscription.id
    assert paid_attempt.id == attempt.id
    assert paid_attempt.payment_intent_id == nil
    assert paid_collection.payment_intent_id == payment_intent.id
    assert paid_collection.renewal_attempt_id == attempt.id
    assert payment_intent.order_id == order.id
    assert order.grand_total_minor > 0
    assert order.currency_code == payment_intent.currency
    assert paid_collection.financial_outcome == :verified_success
    assert payment_intent.state == :succeeded
    assert order.state == :paid
    assert length(applications) == 1
    assert_success_handoff!(paid_attempt, paid_collection, payment_intent, order)
  end

  defp reject_fresh_dispatch!(fixture, now, prior_attempt_count \\ 0) do
    StripeAPIStub.stub_unexpected!("fresh renewal must not contact Stripe")
    before = Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

    assert {:error,
            %{
              code: "RENEWAL_DISPATCH_UNAVAILABLE",
              meta: %{reason: :provider_revocation_fencing_unsupported}
            }} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: now
               )
             end)

    {subscription, attempts, attempt, collection, payment_intent, order, applications} =
      Sandbox.unboxed_run(Repo, fn ->
        subscription = fetch_subscription!(fixture.subscription.id)
        attempts = fetch_attempts!(fixture.subscription.id)
        attempt = fetch_latest_attempt!(fixture.subscription.id)
        collection = fetch_collection!(attempt.id)

        payment_intent =
          fetch_payment_intent_by_key!(
            RenewalCollectionAttempts.payment_intent_key(collection.id)
          )

        order = fetch_order!(attempt.order_id)

        applications =
          PaymentApplication
          |> Ash.Query.filter(expr(order_id == ^order.id))
          |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})

        {subscription, attempts, attempt, collection, payment_intent, order, applications}
      end)

    assert length(attempts) == prior_attempt_count + 1
    assert attempt.subscription_id == fixture.subscription.id
    assert attempt.status == :processing
    assert collection.renewal_attempt_id == attempt.id
    assert collection.dispatch_state == :not_started
    assert collection.financial_outcome == :unresolved
    assert collection.payment_intent_id == nil
    assert collection.reservation_generation_id == nil
    assert payment_intent.order_id == order.id
    assert payment_intent.state == :created
    assert payment_intent.provider_payment_id == nil
    assert payment_intent.provider_customer_ref == nil
    assert order.state == :pending_payment
    assert order.grand_total_minor > 0
    assert applications == []
    assert subscription.status == before.status
    assert subscription.dunning_attempt_count == before.dunning_attempt_count
    assert subscription.retry_suppressed_at == before.retry_suppressed_at
    assert subscription.next_retry_at == before.next_retry_at
    assert subscription.current_period_start_at == before.current_period_start_at
    assert subscription.current_period_end_at == before.current_period_end_at
    assert subscription.next_renewal_at == before.next_renewal_at
    assert payment_intent.provider_payment_method_ref == nil
    assert attempt.payment_intent_id == nil
    assert Repo.get_by!(InventoryItem, variant_id: fixture.variant.id).reserved_count == 0
    {subscription, attempt, collection, payment_intent, order}
  end

  defp prepare_legacy_success!(fixture, now, attempt_id) do
    reached =
      Sandbox.unboxed_run(Repo, fn ->
        ReachedRenewalFixtures.prepare_reached!(fixture.subscription.id, now)
      end)

    assert reached.attempt.id == attempt_id
    assert reached.order.grand_total_minor > 0
    assert reached.order.currency_code == "USD"
    assert reached.payment_intent.order_id == reached.order.id
    assert reached.payment_intent.provider_customer_ref == fixture.refs.provider_customer
    assert reached.payment_intent.provider_payment_method_ref == fixture.refs.payment_method
    assert is_binary(reached.payment_intent.provider_payment_id)
    assert reached.collection.renewal_attempt_id == reached.attempt.id

    assert reached.payment_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(reached.collection.id)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    reached
  end

  defp process_legacy_success!(reached) do
    assert {:ok, :processed} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.process_due_subscription_renewal_for_system(
                 reached.attempt.subscription_id,
                 now: reached.now
               )
             end)
  end

  defp fetch_paid_evidence!(attempt_id, collection_id) do
    Sandbox.unboxed_run(Repo, fn ->
      attempt = fetch_attempt!(attempt_id)
      collection = fetch_collection!(attempt_id)
      payment_intent = fetch_payment_intent!(collection.payment_intent_id)
      order = fetch_order!(attempt.order_id)

      applications =
        PaymentApplication
        |> Ash.Query.filter(expr(order_id == ^order.id))
        |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})

      {attempt, collection, payment_intent, order, applications}
    end)
    |> then(fn {attempt, collection, intent, order, applications} ->
      assert collection.id == collection_id
      assert [application] = applications
      assert application.order_id == order.id
      assert application.payment_intent_id == intent.id
      assert intent.amount_received_minor == order.grand_total_minor
      {attempt, collection, intent, order, applications}
    end)
  end

  defp assert_success_handoff!(attempt, collection, payment_intent, order) do
    assert {:ok, handoff} =
             Sandbox.unboxed_run(Repo, fn ->
               RenewalCollectionAttempts.success_handoff_for_system(collection.id)
             end)

    assert handoff.order_id == order.id
    assert handoff.renewal_attempt_id == attempt.id
    assert handoff.collection_attempt_id == collection.id
    assert handoff.payment_intent_id == payment_intent.id
  end

  defp create_fixture!(label, term, billing_mode \\ :merchant_managed) do
    suffix = Ash.UUIDv7.generate()

    refs = %{
      provider_customer: "cus_jc256_#{suffix}",
      payment_method: "pm_jc256_#{suffix}"
    }

    {:ok, fixture} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transaction(
          fn ->
            customer = SubscriptionsFixtures.create_customer!("jc256_#{label}_#{suffix}")

            %{product: product, variant: variant} =
              SubscriptionsFixtures.create_subscription_sellable!()

            plan =
              SubscriptionsFixtures.create_subscription_plan!(
                Map.merge(
                  %{
                    interval_unit: :day,
                    interval_count: 1,
                    amount_minor: 2_600,
                    currency: "USD",
                    retry_schedule_hours: [0, 24, 72],
                    max_retry_attempts: 3,
                    grace_period_days: 7
                  },
                  term
                )
              )

            variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

            created =
              SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
                provider: :stripe,
                billing_mode: billing_mode,
                provider_customer_ref: refs.provider_customer,
                provider_billing_ref: refs.payment_method,
                started_at: DateTime.add(@reference_at, -86_400, :second),
                next_renewal_at: @reference_at
              })

            subscription = fetch_subscription!(created.subscription.id)

            %{
              customer: customer,
              product: product,
              variant: variant,
              variant_plan: variant_plan,
              plan: plan,
              revision: created.revision,
              subscription: subscription,
              item: created.item,
              order: created.order,
              line_item: created.line_item,
              refs: refs
            }
          end,
          timeout: 30_000
        )
      end)

    fixture
  end

  defp cleanup_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      Cachex.del(Cache, Cache.cache_key(fixture.customer.id))

      {:ok, _result} =
        Repo.transaction(
          fn ->
            subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
            user_id = Ecto.UUID.dump!(fixture.customer.id)
            variant_id = Ecto.UUID.dump!(fixture.variant.id)
            plan_id = Ecto.UUID.dump!(fixture.plan.id)
            product_id = Ecto.UUID.dump!(fixture.product.id)

            Repo.query!(
              "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
              [subscription_id]
            )

            Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

            Repo.query!(
              "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!(
              "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!(
              "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
              [user_id]
            )

            Repo.query!(
              "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL, current_contract_change_id = NULL WHERE id = $1",
              [subscription_id]
            )

            Repo.query!(
              "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
            )

            try do
              Repo.query!(
                "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
                [subscription_id]
              )
            after
              Repo.query!(
                "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
              )
            end

            Repo.query!(
              "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
              [user_id]
            )

            Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
              subscription_id
            ])

            Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
              subscription_id
            ])

            Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
              subscription_id
            ])

            Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

            Repo.query!(
              "DELETE FROM email_outboxes WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!(
              "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!(
              "DELETE FROM fulfillment_orders WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!(
              "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!(
              "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
              [user_id]
            )

            Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
            Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])

            Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [
              variant_id
            ])

            Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
            Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
            Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
            Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
            Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

            assert [[0]] =
                     Repo.query!("SELECT count(*) FROM subscriptions WHERE id = $1", [
                       subscription_id
                     ]).rows

            assert [[0]] =
                     Repo.query!("SELECT count(*) FROM users WHERE id = $1", [user_id]).rows

            assert [[0]] =
                     Repo.query!("SELECT count(*) FROM products WHERE id = $1", [product_id]).rows
          end,
          timeout: 30_000
        )

      assert [["O"]] =
               Repo.query!(
                 "SELECT tgenabled FROM pg_trigger WHERE tgname = 'renewal_collection_attempts_guard'"
               ).rows
    end)
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(period_start_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempts!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(id) do
    Ash.get!(RenewalAttempt, id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_collection!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent!(id) do
    Ash.get!(PaymentIntent, id,
      domain: Store.Payments,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_payment_intent_by_key!(key) do
    PaymentIntent
    |> Ash.Query.filter(expr(payment_intent_key == ^key))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    Ash.get!(Order, id,
      domain: Store.Orders,
      authorize?: false,
      context: %{system?: true}
    )
  end
end
