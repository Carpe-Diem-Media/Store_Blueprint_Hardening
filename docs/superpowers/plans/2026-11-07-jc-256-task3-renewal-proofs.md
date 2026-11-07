# JC-256 renewal lifecycle audit proof plan

> **For agentic workers:** Add the exact test module below as `test/store/subscriptions/jc256_renewal_term_audit_test.exs`. Keep this characterization test-only. A failing assertion reports runtime behavior; it does not authorize a production fix in this task.

**Goal:** Prove through actual renewal dispatch and persisted records whether fixed-end and fixed-cycle terms constrain paid renewals.

**Architecture:** The module creates each fixture atomically in a committed transaction on an unboxed Repo connection, invokes the public renewal facade through unboxed connections, and verifies Stripe requests and persisted renewal, payment, and subscription rows. Each case owns a fresh customer, sellable, plan, subscription, and provider references. An exact-owner cleanup callback is registered immediately after fixture creation.

**Tech stack:** ExUnit, `Store.DataCase`, Ecto SQL Sandbox, Ash subscription fixture helpers, `Store.Subscriptions.Facade`, `Store.Payments`, and `Store.TestSupport.StripeAPIStub`.

---

## Target module

Create only `test/store/subscriptions/jc256_renewal_term_audit_test.exs` with this module. It has three ExUnit tests. The fixed-end test runs three independent fixtures, one second before, equal to, and one second after the charged period end. The fixed-cycle test runs `term_cycles` values 1 and 3 and requires N+1 successful paid reconciliations in each run.

```elixir
defmodule Store.Subscriptions.JC256RenewalTermAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.{Facade, RenewalAttempt, RenewalCollectionAttempt}
  alias Store.Subscriptions.{RenewalCollectionAttempts, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  @reference_at ~U[2026-06-01 00:00:00Z]

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "fixed end at before, equal to, and after the charged period end still reaches merchant dispatch" do
    for {label, term_end_at} <- [
          {"before", DateTime.add(@reference_at, -1, :second)},
          {"equal", @reference_at},
          {"after", DateTime.add(@reference_at, 1, :second)}
        ] do
      fixture = create_fixture!("fixed_end_#{label}", %{term_mode: :fixed_end_at, term_end_at: term_end_at})
      on_exit(fn -> cleanup_fixture!(fixture) end)
      dispatch_ref = make_ref()
      parent = self()

      StripeAPIStub.stub_payment_intent(fn conn, params ->
        send(parent, {dispatch_ref, :post, params})
        StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
      end)

      assert [] =
               Sandbox.unboxed_run(Repo, fn -> fetch_attempts!(fixture.subscription.id) end)

      assert {:ok, :processed} =
               Sandbox.unboxed_run(Repo, fn ->
                 Facade.process_due_subscription_renewal_for_system(
                   fixture.subscription.id,
                   now: @reference_at
                 )
               end)

      assert_receive {^dispatch_ref, :post, params}
      refute_receive {^dispatch_ref, :post, _extra_params}, 0
      assert params["customer"] == fixture.refs.provider_customer
      assert params["payment_method"] == fixture.refs.payment_method

      {subscription, attempt, collection, payment_intent} =
        Sandbox.unboxed_run(Repo, fn ->
          subscription = fetch_subscription!(fixture.subscription.id)
          attempt = fetch_latest_attempt!(fixture.subscription.id)
          collection = fetch_collection!(attempt.id)
          payment_intent = fetch_payment_intent!(collection.payment_intent_id)
          {subscription, attempt, collection, payment_intent}
        end)

      assert subscription.status == :active
      assert attempt.subscription_id == fixture.subscription.id
      assert attempt.order_id == payment_intent.order_id
      assert params["metadata[subscription_id]"] == fixture.subscription.id
      assert params["metadata[renewal_attempt_id]"] == attempt.id
      assert params["metadata[order_id]"] == attempt.order_id
      assert params["metadata[local_intent_id]"] == payment_intent.id
      assert attempt.payment_intent_id == collection.payment_intent_id
      assert collection.renewal_attempt_id == attempt.id
      assert payment_intent.id == collection.payment_intent_id
      assert payment_intent.order_id == attempt.order_id
      assert collection.financial_outcome == :verified_success
      assert payment_intent.state == :succeeded

      snapshot = attempt.charged_contract_snapshot
      assert snapshot["term_mode"] == "fixed_end_at"
      assert {:ok, snapshot_end_at, _offset} = DateTime.from_iso8601(snapshot["term_end_at"])
      assert DateTime.compare(snapshot_end_at, term_end_at) == :eq
      assert DateTime.compare(attempt.period_start_at, @reference_at) == :eq
      assert DateTime.compare(attempt.period_end_at, DateTime.add(@reference_at, 86_400, :second)) == :eq
      assert DateTime.compare(subscription.current_period_end_at, @reference_at) == :eq
      assert DateTime.compare(subscription.next_renewal_at, @reference_at) == :eq
    end
  end

  test "fixed cycle plans permit N plus one successful paid period extensions" do
    for cycles <- [1, 3] do
      fixture =
        create_fixture!("fixed_cycles_#{cycles}", %{
          term_mode: :fixed_cycles,
          term_cycles: cycles
        })

      on_exit(fn -> cleanup_fixture!(fixture) end)
      dispatch_ref = make_ref()
      parent = self()

      StripeAPIStub.stub_payment_intent(fn conn, params ->
        send(parent, {dispatch_ref, :post, params})
        StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
      end)

      successful_period_ends =
        for _extension <- 1..(cycles + 1) do
          before = Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)
          assert before.status == :active
          assert DateTime.compare(before.next_renewal_at, before.current_period_end_at) == :eq
          previous_attempts = Sandbox.unboxed_run(Repo, fn -> fetch_attempts!(fixture.subscription.id) end)
          assert Enum.all?(previous_attempts, &(&1.status == :succeeded))

          assert {:ok, :processed} =
                   Sandbox.unboxed_run(Repo, fn ->
                     Facade.process_due_subscription_renewal_for_system(
                       fixture.subscription.id,
                       now: before.next_renewal_at
                     )
                   end)

          assert_receive {^dispatch_ref, :post, params}
          refute_receive {^dispatch_ref, :post, _extra_params}, 0
          assert params["customer"] == fixture.refs.provider_customer
          assert params["payment_method"] == fixture.refs.payment_method

          {attempt, collection} =
            Sandbox.unboxed_run(Repo, fn ->
              attempt = fetch_latest_attempt!(fixture.subscription.id)
              {attempt, fetch_collection!(attempt.id)}
            end)

          assert attempt.subscription_id == fixture.subscription.id
          assert params["metadata[subscription_id]"] == fixture.subscription.id
          assert params["metadata[renewal_attempt_id]"] == attempt.id
          assert params["metadata[order_id]"] == attempt.order_id
          assert params["metadata[local_intent_id]"] == collection.payment_intent_id
          assert attempt.payment_intent_id == collection.payment_intent_id
          assert collection.renewal_attempt_id == attempt.id
          assert attempt.charged_contract_snapshot["term_mode"] == "fixed_cycles"
          assert attempt.charged_contract_snapshot["term_cycles"] == cycles

          {paid_collection, payment_intent} =
            Sandbox.unboxed_run(Repo, fn ->
              {fetch_collection!(attempt.id), fetch_payment_intent!(collection.payment_intent_id)}
            end)

          assert paid_collection.financial_outcome == :verified_success
          assert payment_intent.state == :succeeded

          assert {:ok, handoff} =
                   Sandbox.unboxed_run(Repo, fn ->
                     RenewalCollectionAttempts.success_handoff_for_system(collection.id)
                   end)

          assert handoff.order_id == attempt.order_id
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
          assert DateTime.compare(paid_subscription.current_period_end_at, before.current_period_end_at) == :gt
          assert DateTime.compare(paid_subscription.current_period_end_at, paid_attempt.period_end_at) == :eq
          assert not is_nil(paid_subscription.next_renewal_at)
          paid_attempt.period_end_at
        end

      assert length(successful_period_ends) == cycles + 1
      final_subscription =
        Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

      assert DateTime.compare(final_subscription.current_period_end_at, List.last(successful_period_ends)) == :eq
      assert final_subscription.status == :active
      assert not is_nil(final_subscription.next_renewal_at)
    end
  end

  test "provider-managed subscription still dispatches a merchant Stripe collection" do
    fixture = create_fixture!("provider_managed", %{term_mode: :until_canceled}, :provider_managed)
    on_exit(fn -> cleanup_fixture!(fixture) end)
    dispatch_ref = make_ref()
    parent = self()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      send(parent, {dispatch_ref, :post, params})
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)

    assert {:ok, :processed} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: @reference_at
               )
             end)

    assert_receive {^dispatch_ref, :post, params}
    refute_receive {^dispatch_ref, :post, _extra_params}, 0

    {subscription, attempt, collection, payment_intent} =
      Sandbox.unboxed_run(Repo, fn ->
        subscription = fetch_subscription!(fixture.subscription.id)
        attempt = fetch_latest_attempt!(fixture.subscription.id)
        collection = fetch_collection!(attempt.id)
        {subscription, attempt, collection, fetch_payment_intent!(collection.payment_intent_id)}
      end)

    assert subscription.billing_mode == :provider_managed
    assert is_nil(subscription.provider_subscription_id)
    assert subscription.status == :active
    assert params["customer"] == fixture.refs.provider_customer
    assert params["payment_method"] == fixture.refs.payment_method
    assert params["metadata[subscription_id]"] == fixture.subscription.id
    assert params["metadata[renewal_attempt_id]"] == attempt.id
    assert params["metadata[order_id]"] == attempt.order_id
    assert params["metadata[local_intent_id]"] == payment_intent.id
    assert attempt.subscription_id == fixture.subscription.id
    assert attempt.payment_intent_id == collection.payment_intent_id
    assert collection.renewal_attempt_id == attempt.id
    assert payment_intent.order_id == attempt.order_id
    assert collection.financial_outcome == :verified_success
    assert payment_intent.state == :succeeded
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
            %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

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
      Cachex.del(Store.Entitlements.Cache, Store.Entitlements.Cache.cache_key(fixture.customer.id))

      {:ok, _result} =
        Repo.transaction(
          fn ->
            subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
            user_id = Ecto.UUID.dump!(fixture.customer.id)
            variant_id = Ecto.UUID.dump!(fixture.variant.id)
            plan_id = Ecto.UUID.dump!(fixture.plan.id)
            product_id = Ecto.UUID.dump!(fixture.product.id)

            Repo.query!("DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1", [subscription_id])
            Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])
            Repo.query!("DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))", [user_id])
            Repo.query!("UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL, current_contract_change_id = NULL WHERE id = $1", [subscription_id])
            Repo.query!("ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard")

            try do
              Repo.query!("DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)", [subscription_id])
            after
              Repo.query!("ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard")
            end

            Repo.query!("DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))", [user_id])
            Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
            Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [subscription_id])
            Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
            Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
            Repo.query!("DELETE FROM email_outboxes WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM fulfillment_orders WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
            Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
            Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])
            Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
            Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
            Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
            Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
            Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
            Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

            assert [[0]] =
                     Repo.query!("SELECT count(*) FROM subscriptions WHERE id = $1", [subscription_id]).rows

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
end
```

## Evidence and boundaries

- `SubscriptionsFixtures.create_subscription_fixture!/4` accepts `started_at`, `next_renewal_at`, provider references, and `billing_mode`. Its writes run inside the one unboxed transaction.
- `Facade.process_due_subscription_renewal_for_system/2` is the runtime entry point. Current accepted behavior to assert is `{:ok, :processed}` plus a captured merchant Stripe POST and persisted subscription status other than `:expired`.
- `apply_off_session_renewal_response` records the successful Stripe response through the payment observation facade. Assert the returned collection has `financial_outcome == :verified_success` and its PaymentIntent has `state == :succeeded`. Then require the exact result from `RenewalCollectionAttempts.success_handoff_for_system/1` and `{:ok, :reconciled}` from the renewal facade before counting an extension.
- Parse JSON `term_end_at` with `DateTime.from_iso8601/1` and compare instants with `DateTime.compare/2`; do not compare serialized precision strings.
- Assert subscription, order, attempt, collection, payment intent, customer, payment method, term mode, term value, and charged period references match the fixture records.
- Do not assert an idealized expiration result. These tests characterize the current runtime. Do not edit production code or dilute the explicit current-runtime assertions if they fail.
- The provider-managed case sets the persisted billing mode directly, asserts `provider_subscription_id` is nil, and proves the actual merchant Stripe POST with its persisted renewal/payment identities. Task 2 separately proves initial billing-mode selection.
- Do not add a trial lifecycle test unless it proves a distinct real renewal lifecycle. The existing `jc256_contract_configuration_audit_test.exs` only covers stored fields and pure scheduler boundaries, so report trial lifecycle behavior as **INCONCLUSIVE**.
- No live provider calls, database resets, broad deletes, global cache clears, resource convergence assertions, or changes outside the target test file.

## Required verification

Run the focused module, format check, strict Credo check, and warnings-as-errors compile through DevCore using the required environment:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/jc256_renewal_term_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format test/store/subscriptions/jc256_renewal_term_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/subscriptions/jc256_renewal_term_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
```

Report each observed command result. If the current facade or fixture APIs make the prescribed evidence impossible, give the concrete missing field, return shape, or relationship and leave that case unresolved. Do not replace it with inferred evidence.

## Root plan self-review

The tests assert the current dispatch and payment path, not an idealized term implementation. Fixed-end cases include a pre-cutoff control and expired/equal boundaries with no prior B occurrence. The cycle test counts only verified successful collections with exact paid handoffs and reconciled period growth. It makes no decision about counting the initial paid period. The provider-managed fixture proves dispatch of an already labeled record; Task 2 separately proves initial flag selection. Cleanup starts with the exact user cache key and deletes only fixture owners. No test collector process is needed.
