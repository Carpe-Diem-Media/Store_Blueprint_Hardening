defmodule Store.Subscriptions.JC256SaleActivationAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutStartInput}
  alias Store.Entitlements.Cache, as: EntitlementCache
  alias Store.Orders.{Order, OrderLineItem, PaymentApplication}
  alias Store.Payments
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Providers
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

  test "a positive-trial purchase has matching financial evidence before activation and replay" do
    fixture =
      paid_fixture!(%{term_mode: :fixed_end_at, term_end_at: @past_end_at}, 14, :stripe)

    order = fetch_order!(fixture.order.id)
    line_item = fetch_order_line_item!(order.id)
    [payment_intent] = payment_intents_for_order(order.id)
    [application] = payment_applications_for_order(order.id)

    assert order.state == :paid
    assert %DateTime{} = order.totals_finalized_at
    assert order.grand_total_minor == 1_999
    assert order.items_subtotal_minor == line_item.net_line_total_minor
    assert order.grand_total_minor == line_item.net_line_total_minor
    assert order.shipping_total_minor == 0
    assert order.currency_code == fixture.revision.currency
    assert payment_intent.state == :succeeded
    assert payment_intent.amount_received_minor == order.grand_total_minor
    assert payment_intent.currency == order.currency_code
    assert application.order_id == order.id
    assert application.payment_intent_id == payment_intent.id
    assert line_item.subscription_plan_revision_id_snapshot == fixture.revision.id
    assert fixture.revision.trial_days == 14

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    subscription = fetch_subscription_for_order!(order.id)
    effect = fetch_access_effect!(subscription.id)
    assert subscription.status == :active
    assert subscription.current_plan_revision_id == fixture.revision.id
    assert effect.status == :applied
    assert effect.source_order_line_item_id == line_item.id

    assert {:ok, %{created_count: 0, skipped_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert fetch_subscription_for_order!(order.id).id == subscription.id
    assert fetch_access_effect!(subscription.id).id == effect.id
    assert payment_applications_for_order(order.id) == [application]
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

  test "Stripe mode follows the provider-managed feature flag without activation provider calls" do
    fixture = paid_fixture!(%{term_mode: :until_canceled}, 0, :stripe)

    put_subscription_features(provider_managed_mode_enabled?: false)

    assert {:ok, %{created_count: 1}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

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

  test "synthetic Yoco purchase rejects activation when provider-managed selection is enabled" do
    put_subscription_features(provider_managed_mode_enabled?: true)
    enable_provider!(:yoco)
    yoco_fixture = synthetic_paid_fixture!(%{term_mode: :until_canceled}, 0, :yoco)

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
               yoco_fixture.order.id
             )

    assert error.code == "SUBSCRIPTION_BILLING_MODE_UNSUPPORTED"
    assert subscriptions_for_order(yoco_fixture.order.id) == []
  end

  defp paid_fixture!(configuration, trial_days, :stripe) do
    put_subscription_features(expose_purchase?: true)

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

    assert finalized.grand_total_minor == revision.amount_minor
    assert finalized.grand_total_minor > 0
    assert {:ok, intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    StripeAPIStub.stub_payment_intent(fn _conn, _params ->
      flunk("unexpected merchant collection POST during initial checkout")
    end)

    assert {:ok, intent_result} =
             Payments.create_intent_for_order(customer, started.checkout_key, intent_input)

    payment_intent = fetch_payment_intent!(intent_result.payment_intent_id)
    assert payment_intent.amount_received_minor == finalized.grand_total_minor
    assert payment_intent.currency == finalized.currency_code
    assert payment_intent.state == :submitted
    assert is_binary(payment_intent.provider_payment_id)

    StripeAPIStub.stub_payment_observation(payment_intent.provider_payment_id, %{
      "amount" => payment_intent.amount_received_minor,
      "amount_received" => payment_intent.amount_received_minor,
      "currency" => String.downcase(payment_intent.currency),
      "id" => payment_intent.provider_payment_id,
      "livemode" => false,
      "metadata" => %{"local_intent_id" => payment_intent.id},
      "status" => "succeeded"
    })

    assert {:ok, observation} =
             Providers.observe_payment(:stripe, %{
               provider_reference: payment_intent.provider_payment_id,
               provider_reference_kind: :payment_intent
             })

    assert observation.normalized_outcome == :authoritative_success
    StripeAPIStub.stub_unexpected!()

    assert {:ok, _application} =
             Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    order = fetch_order!(started.order_id)
    paid_intent = fetch_payment_intent!(payment_intent.id)
    line_item = fetch_order_line_item!(order.id)
    [application] = payment_applications_for_order(order.id)

    assert order.state == :paid
    assert %DateTime{} = order.totals_finalized_at
    assert order.grand_total_minor == finalized.grand_total_minor
    assert order.items_subtotal_minor == line_item.net_line_total_minor
    assert order.currency_code == finalized.currency_code
    assert line_item.line_total_minor == order.grand_total_minor
    assert line_item.net_line_total_minor == order.grand_total_minor
    assert line_item.subscription_plan_revision_id_snapshot == revision.id
    assert application.order_id == order.id
    assert application.payment_intent_id == payment_intent.id
    assert paid_intent.state == :succeeded
    assert paid_intent.amount_received_minor == order.grand_total_minor
    assert paid_intent.currency == order.currency_code

    %{order: order, revision: revision}
  end

  defp synthetic_paid_fixture!(configuration, trial_days, provider) do
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

  defp fetch_payment_intent!(payment_intent_id) do
    Ash.get!(PaymentIntent, payment_intent_id,
      domain: Store.Payments,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp put_subscription_features(overrides) do
    current = Application.get_env(:store, :subscription_features, [])
    Application.put_env(:store, :subscription_features, Keyword.merge(current, overrides))
  end

  defp enable_provider!(provider) do
    current = Application.get_env(:store, :payments, [])
    enabled = Keyword.get(current, :enabled_providers, [])

    Application.put_env(
      :store,
      :payments,
      Keyword.put(current, :enabled_providers, Enum.uniq([provider | enabled]))
    )
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:store, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:store, key)

  defp clear_entitlement_cache!(user_id) do
    Cachex.del(EntitlementCache, EntitlementCache.cache_key(user_id))
    :ok
  end

  defp fetch_order_line_item!(order_id) do
    OrderLineItem
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.Query.sort(line_no: :asc)
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(order_id) do
    Ash.get!(Order, order_id,
      domain: Store.Orders,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp payment_intents_for_order(order_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp payment_applications_for_order(order_id) do
    PaymentApplication
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
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
