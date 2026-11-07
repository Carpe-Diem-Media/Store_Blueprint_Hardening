# JC256 Task 2 audit test plan

> **For agentic workers:** Implement only the test file below. Keep provider enablement and runtime behavior unchanged.

**Goal:** Characterize trial and term configuration through checkout, paid activation, and provider-mode selection without changing production code or making provider calls.

**Architecture:** Add one `Store.DataCase` test module with `async: false` and the repository's ordinary SQL sandbox. The checkout case uses the real cart and checkout facade. The activation cases create paid source-order fixtures and call `Store.Subscriptions.Facade.create_subscriptions_from_paid_order_for_system/1`. Save and restore both affected application environment keys exactly, including deleting keys that were absent before a test.

**Tech Stack:** Elixir, ExUnit, Ash, Phoenix checkout facades, SQL Sandbox, Req.Test Stripe stub.

---

## File map

- Create `test/store/subscriptions/jc256_sale_activation_audit_test.exs`. It contains checkout, activation, provider-mode, and unsupported-provider characterization tests plus small fixture/query helpers.
- Do not edit production code, provider modules, existing fixtures, or existing tests.

## Task 1: Add the checkout and activation audit cases

**File:** `test/store/subscriptions/jc256_sale_activation_audit_test.exs`

Create the file with this complete module. Keep `async: false`; do not use committed fixtures, renewal helpers, or direct subscription inserts. The checkout case proves the purchased revision snapshot and price. The paid activation matrix covers both trial settings for each requested term configuration, including a fixed end in the past. The provider tests check actual mode selection with the feature flag off and on. Yoco is temporarily enabled only inside the unsupported-provider test and must fail without creating a subscription.

```elixir
defmodule Store.Subscriptions.JC256SaleActivationAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutStartInput}
  alias Store.Orders.OrderLineItem
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.{Scheduler, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  @past_end_at ~U[2020-01-01 00:00:00Z]

  setup context do
    previous_subscription_features = Application.fetch_env(:store, :subscription_features)
    previous_payments = Application.fetch_env(:store, :payments)

    on_exit(fn ->
      restore_env(:subscription_features, previous_subscription_features)
      restore_env(:payments, previous_payments)
    end)

    :ok = StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!()
    put_subscription_features(provider_managed_mode_enabled?: false)

    :ok
  end

  test "checkout accepts a nonzero trial and past fixed end while freezing its revision and price" do
    put_subscription_features(expose_purchase?: true)

    customer = SubscriptionsFixtures.create_customer!("jc256_checkout_audit")

    %{variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{base_variant_price_minor: 1_000})

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 1_999,
        term_mode: :fixed_end_at,
        term_cycles: nil,
        term_end_at: @past_end_at,
        trial_days: 14
      })

    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    token = Ash.UUIDv7.generate()

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = CartsFacade.add_item_for_user(customer, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, started} = Checkout.start_from_cart(customer, token, start_input)
    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, finalized} =
             Checkout.finalize_totals(customer, started.checkout_key, finalize_input)

    line_item = fetch_order_line_item!(finalized.order_id)
    assert line_item.subscription_plan_id_snapshot == plan.id
    assert line_item.subscription_plan_revision_id_snapshot == revision.id
    assert line_item.subscription_plan_key_snapshot == plan.key
    assert line_item.unit_price_minor == 1_999
    assert line_item.line_total_minor == 1_999
    assert line_item.net_line_total_minor == 1_999
    assert revision.trial_days == 14
    assert revision.term_mode == :fixed_end_at
    assert DateTime.compare(revision.term_end_at, @past_end_at) == :eq
  end

  test "paid activation binds each trial and term revision without shifting its initial period" do
    configurations = [
      %{term_mode: :until_canceled, term_cycles: nil, term_end_at: nil},
      %{term_mode: :fixed_cycles, term_cycles: 1, term_end_at: nil},
      %{term_mode: :fixed_cycles, term_cycles: 3, term_end_at: nil},
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: @past_end_at}
    ]

    for configuration <- configurations, trial_days <- [0, 14] do
      fixture = paid_fixture!(configuration, trial_days, :stripe)

      assert {:ok, %{created_count: 1, entitlement_issued_count: 0}} =
               SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
                 fixture.order.id
               )

      subscription = fetch_subscription_for_order!(fixture.order.id)
      line_item = fetch_order_line_item!(fixture.order.id)
      effect = fetch_access_effect!(subscription.id)

      assert subscription.status == :active
      assert subscription.current_plan_revision_id == fixture.revision.id
      assert line_item.subscription_plan_revision_id_snapshot == fixture.revision.id
      assert effect.status == :applied
      assert effect.plan_revision_id == fixture.revision.id
      assert effect.source_order_line_item_id == line_item.id
      assert is_nil(fixture.revision.entitlement_kind)
      assert is_nil(fixture.revision.entitlement_scope_key)

      assert {:ok, expected_period} =
               Scheduler.initial_period(subscription.started_at, fixture.revision)

      assert DateTime.compare(
               subscription.current_period_start_at,
               expected_period.current_period_start_at
             ) == :eq

      assert DateTime.compare(
               subscription.current_period_end_at,
               expected_period.current_period_end_at
             ) == :eq

      assert DateTime.compare(subscription.next_renewal_at, expected_period.next_renewal_at) ==
               :eq

      assert DateTime.compare(subscription.current_period_start_at, subscription.started_at) ==
               :eq
    end
  end

  test "Stripe mode follows the provider-managed feature flag without making provider calls" do
    fixture = paid_fixture!(%{term_mode: :until_canceled}, 0, :stripe)

    put_subscription_features(provider_managed_mode_enabled?: false)

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
               fixture.order.id
             )

    merchant_subscription = fetch_subscription_for_order!(fixture.order.id)
    assert merchant_subscription.billing_mode == :merchant_managed
    assert merchant_subscription.provider == :stripe

    provider_fixture = paid_fixture!(%{term_mode: :until_canceled}, 0, :stripe)
    put_subscription_features(provider_managed_mode_enabled?: true)

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
               provider_fixture.order.id
             )

    provider_subscription = fetch_subscription_for_order!(provider_fixture.order.id)
    assert provider_subscription.billing_mode == :provider_managed
    assert provider_subscription.provider == :stripe
    assert is_nil(provider_subscription.provider_subscription_id)

  end

  test "unsupported provider rejects activation when provider-managed selection is enabled" do
    put_subscription_features(provider_managed_mode_enabled?: true)
    enable_provider!(:yoco)
    yoco_fixture = paid_fixture!(%{term_mode: :until_canceled}, 0, :yoco)

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
               yoco_fixture.order.id
             )

    assert error.code == "SUBSCRIPTION_BILLING_MODE_UNSUPPORTED"
    assert subscriptions_for_order(yoco_fixture.order.id) == []
  end

  defp paid_fixture!(configuration, trial_days, provider) do
    customer = SubscriptionsFixtures.create_customer!("jc256_paid_activation_audit")
    clear_entitlement_cache!(customer.id)
    on_exit(fn -> clear_entitlement_cache!(customer.id) end)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(
        Map.merge(configuration, %{trial_days: trial_days})
      )

    revision = SubscriptionsFixtures.create_plan_revision!(plan, %{trial_days: trial_days})
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order, line_item: line_item} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          provider: provider,
          amount_minor: revision.amount_minor,
          currency: revision.currency
        }
      )

    assert line_item.subscription_plan_revision_id_snapshot == revision.id
    %{order: order, revision: revision}
  end

  defp put_subscription_features(overrides) do
    current = Application.get_env(:store, :subscription_features, [])
    Application.put_env(:store, :subscription_features, Keyword.merge(current, overrides))
  end

  defp enable_provider!(provider) do
    current = Application.get_env(:store, :payments, [])
    enabled = Keyword.get(current, :enabled_providers, [])
    Application.put_env(:store, :payments, Keyword.put(current, :enabled_providers, Enum.uniq([provider | enabled])))
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:store, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:store, key)

  defp clear_entitlement_cache!(user_id) do
    Cachex.del(Store.Entitlements.Cache, Store.Entitlements.Cache.cache_key(user_id))
    :ok
  end

  defp fetch_order_line_item!(order_id) do
    OrderLineItem
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.Query.sort(line_no: :asc)
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription_for_order!(order_id) do
    case subscriptions_for_order(order_id) do
      [%Subscription{} = subscription] -> subscription
      subscriptions -> flunk("expected one subscription, got: #{inspect(subscriptions)}")
    end
  end

  defp subscriptions_for_order(order_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_id == ^order_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_access_effect!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
```

The checkout plan copies the configured plan fields into an effective revision. The paid-order helper creates that effective revision when one does not yet exist and writes its ID onto the purchased line item. Each paid fixture supplies the revision amount and currency to the succeeded payment intent, so the fixture's payment evidence matches the frozen contract. Each paid fixture clears and registers cleanup for its newly created user's Cachex entitlement entry because SQL sandbox rollback does not roll back cache writes. A nil/nil entitlement pair is valid for initial activation, as confirmed by `initial_entitlement_pair_complete?/2` in the facade.

## Task 2: Run focused checks

Run the checks in this order. Save each command's output in `tmp/jc256/task2-<check>.log`. Do not use `--no-deps-check` or loosen strict Credo settings.

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format test/store/subscriptions/jc256_sale_activation_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/jc256_sale_activation_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/subscriptions/jc256_sale_activation_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
```

Expected results: formatting, the focused audit test file, strict Credo, and warnings-as-errors compilation all exit successfully. These tests characterize current behavior and must not assert unimplemented provider calls, successful Yoco activation, trial-period delay, trial access, or fixed-term completion. The provider flag-off case must allow Stripe's merchant-managed fallback because Stripe supports that mode.

## Scope and evidence

The test proves sale acceptance, purchased-revision binding, initial period calculation, and selected billing mode. It does not prove when a provider collects an initial customer payment, whether a customer receives access during trial, what happens at term completion, or any behavior in a second provider-managed account. No production provider enablement, live HTTP call, or runtime change belongs in this task.

## Root plan self-review

The error code matches the live facade and registry. The unsupported-provider case enables provider-managed selection in the test so a false provider capability still rejects activation. It is a separate fourth test. Setup fixes the baseline mode and restores the exact prior environment after each test. AccessEffect assertions also check its purchased revision and source line. No production code or committed fixture is needed.
