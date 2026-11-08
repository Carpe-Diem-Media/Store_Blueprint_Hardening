defmodule Store.Subscriptions.FacadeTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Ecto.Adapters.SQL.Sandbox

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput

  alias Store.Catalog.{
    InventoryItem,
    ProductOption,
    ProductOptionValue,
    Variant,
    VariantOptionSelection
  }

  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutStartInput}
  alias Store.Comms.EmailOutbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.{InventoryReservation, Order, OrderLineItem, PaymentApplication}
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.{CreateIntentForOrderInput, ObservePaymentIntentInput}
  alias Store.Payments.{PaymentAttempt, PaymentIntent}
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Subscriptions.AccessEffectTargetOrder
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Support.Errors.Error

  alias Store.Subscriptions.{
    AccessEffect,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription,
    SubscriptionItem
  }

  alias Store.Subscriptions.Inputs.{
    EstablishAccessEffectInput,
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput,
    StartSubscriptionPaymentMethodUpdateInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  setup context do
    previous = Application.get_env(:store, :payments, [])
    previous_subscription_features = Application.get_env(:store, :subscription_features, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
      Application.put_env(:store, :subscription_features, previous_subscription_features)
    end)

    :ok
  end

  @tag :jc360_task01
  test "paid-order activation persists exact EFFECTIVE effects and applies them before returning" do
    fixture = create_paid_order_with_two_revision_lines!("jc360_paid_create")
    %{order: order, line_items: line_items, revisions: revisions, plans: plans} = fixture

    assert {:ok, first} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert first.subscription_line_count == 2
    assert first.created_count == 2
    assert first.skipped_count == 0
    assert first.entitlement_issued_count == 2

    subscriptions = subscriptions_for_order(order.id)
    assert length(subscriptions) == 2

    for {line_item, revision, plan} <- Enum.zip([line_items, revisions, plans]) do
      assert revision.status in [:effective, :retired]
      assert line_item.subscription_plan_id_snapshot == plan.id
      assert line_item.subscription_plan_revision_id_snapshot == revision.id
      assert revision.subscription_plan_id == plan.id

      assert [subscription] =
               Enum.filter(subscriptions, &(&1.source_order_line_item_id == line_item.id))

      assert subscription.status == :active
      assert subscription.source_order_id == order.id
      assert subscription.source_order_line_item_id == line_item.id
      assert subscription.subscription_plan_id == plan.id
      assert subscription.current_plan_revision_id == revision.id
      assert subscription.aggregate_version > 0
      assert %DateTime{} = subscription.current_period_start_at
      assert %DateTime{} = subscription.current_period_end_at

      assert DateTime.compare(
               subscription.current_period_start_at,
               subscription.current_period_end_at
             ) == :lt

      assert [%SubscriptionItem{} = item] = subscription_items_for_source_line(line_item.id)
      assert item.subscription_id == subscription.id
      assert item.source_order_line_item_id == line_item.id
      assert item.variant_id == line_item.variant_id_snapshot
      assert item.quantity == line_item.quantity
      assert item.plan_key_snapshot == line_item.subscription_plan_key_snapshot

      assert {:ok, [%AccessEffect{} = effect]} = current_access_effects(subscription.id)
      assert effect.subscription_id == subscription.id
      assert effect.source_version == subscription.aggregate_version
      assert effect.disposition == :effective
      assert effect.status == :applied
      assert effect.source_order_line_item_id == line_item.id
      assert effect.plan_revision_id == revision.id
      assert effect.contract_change_id == nil
      assert effect.entitlement_kind == revision.entitlement_kind
      assert effect.entitlement_scope_key == revision.entitlement_scope_key
      assert effect.valid_from_at == subscription.current_period_start_at
      assert effect.valid_until_at == subscription.current_period_end_at
    end

    assert count_subscription_items_for_order(order.id) == 2
    assert count_access_effects_for_order(order.id) == 2
    assert count_entitlements_for_order(order.id) == 2

    assert {:ok, second} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert second.subscription_line_count == 2
    assert second.created_count == 0
    assert second.skipped_count == 2
    assert second.entitlement_issued_count == 0

    assert length(subscriptions_for_order(order.id)) == 2
    assert count_subscription_items_for_order(order.id) == 2
    assert count_access_effects_for_order(order.id) == 2
    assert count_entitlements_for_order(order.id) == 2
  end

  @tag :jc360_financial_fixture
  test "paid checkout activation uses matching totals and provider-observed payment evidence" do
    subscription_features = Application.get_env(:store, :subscription_features, [])

    Application.put_env(
      :store,
      :subscription_features,
      Keyword.put(subscription_features, :expose_purchase?, true)
    )

    customer = SubscriptionsFixtures.create_customer!("jc360_financial_activation")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 1_999,
        currency: "USD",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc360:financial:#{Ecto.UUID.generate()}"
      })

    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    _variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    checkout_token = Ash.UUIDv7.generate()

    assert {:ok, cart_item_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = CartsFacade.add_item_for_user(customer, checkout_token, cart_item_input)
    assert {:ok, checkout_start_input} = CheckoutStartInput.new(%{})

    assert {:ok, checkout} =
             Checkout.start_from_cart(customer, checkout_token, checkout_start_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, finalized} =
             Checkout.finalize_totals(customer, checkout.checkout_key, finalize_input)

    order = fetch_order!(checkout.order_id)

    assert [line_item] =
             OrderLineItem
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert order.state == :pending_payment
    assert order.grand_total_minor > 0
    assert order.items_subtotal_minor == order.grand_total_minor
    assert order.shipping_total_minor == 0
    assert order.currency_code == "USD"
    assert finalized.grand_total_minor == order.grand_total_minor
    assert line_item.quantity == 1
    assert line_item.unit_price_minor == revision.amount_minor
    assert line_item.line_total_minor == order.grand_total_minor
    assert line_item.net_line_total_minor == order.grand_total_minor
    assert line_item.currency == order.currency_code
    assert line_item.subscription_plan_id_snapshot == plan.id
    assert line_item.subscription_plan_revision_id_snapshot == revision.id

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:ok, intent_result} =
             Store.Payments.create_intent_for_order(
               customer,
               checkout.checkout_key,
               create_intent_input
             )

    payment_intent = fetch_payment_intent!(intent_result.payment_intent_id)
    assert payment_intent.state == :submitted
    assert payment_intent.amount_received_minor == order.grand_total_minor
    assert payment_intent.currency == order.currency_code
    assert is_binary(payment_intent.provider_payment_id)

    StripeAPIStub.stub_payment_observation(payment_intent.provider_payment_id, %{
      "amount" => payment_intent.amount_received_minor,
      "amount_received" => payment_intent.amount_received_minor,
      "currency" => String.downcase(payment_intent.currency),
      "id" => payment_intent.provider_payment_id,
      "livemode" => false,
      "metadata" => %{
        "local_intent_id" => payment_intent.id,
        "order_id" => order.id
      },
      "status" => "succeeded"
    })

    assert {:ok, observation} =
             PaymentsFacade.observe_payment_intent_for_system(%ObservePaymentIntentInput{
               payment_intent_id: payment_intent.id
             })

    assert observation.eligibility == :eligible

    assert %PaymentAttempt{
             observation_source: "verification",
             outcome: "authoritative_success",
             amount_minor: amount_minor,
             currency: currency,
             provider_environment: "test"
           } = observation.evidence

    assert amount_minor == order.grand_total_minor
    assert currency == order.currency_code

    assert {:ok, payment_result} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(observation)

    assert payment_result.outcome == :authoritative_success
    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
    assert fetch_order!(order.id).state == :paid

    assert [%PaymentApplication{payment_intent_id: payment_intent_id}] =
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert payment_intent_id == payment_intent.id

    assert {:ok, activation} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert activation.subscription_line_count == 1
    assert activation.created_count == 1
    assert activation.skipped_count == 0
    assert activation.entitlement_issued_count == 1

    assert [subscription] = subscriptions_for_order(order.id)
    assert subscription.source_order_id == order.id
    assert subscription.source_order_line_item_id == line_item.id
    assert subscription.current_plan_revision_id == revision.id
    assert [%SubscriptionItem{} = item] = subscription_items_for_source_line(line_item.id)
    assert item.subscription_id == subscription.id

    assert {:ok, [%AccessEffect{} = effect]} = current_access_effects(subscription.id)
    assert effect.status == :applied
    assert effect.source_order_line_item_id == line_item.id
    assert effect.plan_revision_id == revision.id
    assert [%EntitlementGrant{status: :active} = grant] = [fetch_entitlement!(subscription.id)]
    assert grant.source_id == subscription.id
    assert grant.kind == effect.entitlement_kind
    assert grant.scope_key == effect.entitlement_scope_key
  end

  @tag :jc360_task11
  test "paid activation and replay report bounded operation-only measurements" do
    samples =
      for line_count <- [1, 2], sample <- 1..4 do
        prefix = "jc360_measure_activation_#{line_count}_#{sample}"

        fixture =
          if line_count == 1,
            do: create_paid_order_fixture!(prefix),
            else: create_paid_order_with_two_revision_lines!(prefix)

        {activation, activation_stats, activation_us} =
          measured_operation(fn ->
            SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
          end)

        assert {:ok, activation_result} = activation
        assert activation_result.created_count == line_count
        assert activation_result.entitlement_issued_count == line_count

        {replay, replay_stats, replay_us} =
          measured_operation(fn ->
            SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
          end)

        assert {:ok, replay_result} = replay
        assert replay_result.created_count == 0
        assert replay_result.skipped_count == line_count
        assert replay_result.entitlement_issued_count == 0
        assert length(subscriptions_for_order(fixture.order.id)) == line_count
        assert count_access_effects_for_order(fixture.order.id) == line_count
        assert count_entitlements_for_order(fixture.order.id) == line_count

        activation_row =
          measurement_row(
            "paid_activation",
            sample,
            line_count,
            activation_us,
            activation_stats,
            fixture
          )

        replay_row =
          measurement_row(
            "paid_activation_replay",
            sample,
            line_count,
            replay_us,
            replay_stats,
            fixture
          )

        IO.puts(Jason.encode!(activation_row))
        IO.puts(Jason.encode!(replay_row))
        {line_count, activation_us, replay_us}
      end

    one_line = Enum.filter(samples, &(elem(&1, 0) == 1))
    two_lines = Enum.filter(samples, &(elem(&1, 0) == 2))

    IO.puts(
      Jason.encode!(%{
        tag: "JC360_MEASUREMENTS",
        operation: "paid_activation_latency_summary",
        sample_count_per_fanout: 4,
        one_line_activation_latency_us: latency_summary(one_line, 1),
        one_line_replay_latency_us: latency_summary(one_line, 2),
        two_line_activation_latency_us: latency_summary(two_lines, 1),
        two_line_replay_latency_us: latency_summary(two_lines, 2),
        workload:
          "four equivalent fresh one-line and four two-line paid-order activations and replays",
        limits: "descriptive only; four samples per fanout; no capacity claim"
      })
    )
  end

  @tag :jc360_task01
  test "a committed initial establishment component stays REQUIRED until explicit F1 execution" do
    # This committed component fixture does not pause the public paid-order facade before F1.
    fixture = create_committed_initial_effect_fixture!("jc360_component")

    required = fetch_access_effect!(fixture.effect.id)
    assert required.status == :required
    assert required.disposition == :effective
    assert required.subscription_id == fixture.subscription.id
    assert required.source_version == fixture.subscription.aggregate_version
    assert required.source_order_line_item_id == fixture.line_item.id
    assert required.plan_revision_id == fixture.revision.id
    assert required.contract_change_id == nil
    assert required.entitlement_kind == fixture.revision.entitlement_kind
    assert required.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert required.valid_from_at == fixture.subscription.current_period_start_at
    assert required.valid_until_at == fixture.subscription.current_period_end_at

    target_before_f1 = AccessEffectTargetOrder.evidence_from_access_effect(required)

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    applied = fetch_access_effect!(fixture.effect.id)
    assert applied.status == :applied
    assert AccessEffectTargetOrder.evidence_from_access_effect(applied) == target_before_f1
    assert applied.source_version == required.source_version
    assert applied.target_fingerprint == required.target_fingerprint
  end

  @tag :jc360_task01
  test "an item insert failure rolls back every newly created paid-order line" do
    fixture = create_paid_order_with_two_revision_lines!("jc360_item_rollback")
    second_line = List.last(fixture.line_items)

    result =
      with_item_insert_rejection!(second_line.id, fn ->
        SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      end)

    assert {:error, _reason} = result
    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task01
  test "an AccessEffect insert failure rolls back every newly created paid-order line" do
    fixture = create_paid_order_with_two_revision_lines!("jc360_effect_rollback")
    second_revision = List.last(fixture.revisions)

    result =
      with_effect_insert_rejection!(second_revision.id, fn ->
        SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      end)

    assert {:error, _reason} = result,
           "expected the rejected second AccessEffect to abort source creation, got #{inspect(result)}"

    assert_no_initial_activation_rows!(fixture)
  end

  test "initial activation rolls back when a purchased revision has an invalid billing timezone" do
    fixture = create_paid_order_with_two_revision_lines!("jc255_invalid_activation_timezone")
    second_revision = List.last(fixture.revisions)

    Repo.query!(
      "UPDATE plan_revisions SET billing_timezone = $1 WHERE id = $2",
      ["Not/A_Real_Zone", Ecto.UUID.dump!(second_revision.id)]
    )

    StripeAPIStub.stub_unexpected!("invalid billing timezone must fail before provider work")

    assert {:error, %Error{code: "INVALID_BILLING_TIMEZONE"}} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task01
  test "initial activation rejects a persisted same-plan revision mismatch" do
    fixture = create_paid_order_with_two_revision_lines!("jc360_same_plan_revision")
    [purchased_line | _] = fixture.line_items
    different_revision = fixture.same_plan_revision

    result =
      with_subscription_insert_mutation!(
        purchased_line.id,
        "NEW.current_plan_revision_id := #{uuid_sql_literal!(different_revision.id)};",
        fn ->
          SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
        end
      )

    if match?({:ok, _}, result) do
      assert [subscription] =
               Enum.filter(
                 subscriptions_for_order(fixture.order.id),
                 &(&1.source_order_line_item_id == purchased_line.id)
               )

      assert subscription.current_plan_revision_id == different_revision.id
    end

    assert {:error,
            %Error{
              code: "TARGET_ORDER_UNPROVABLE",
              message: "funded PlanRevision does not match the Subscription current plan revision"
            }} = result,
           "expected the persisted purchased-revision mismatch to fail closed, got #{inspect(result)}"

    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task01
  test "initial activation rejects foreign, missing, and never-effective purchased revisions" do
    foreign_fixture = create_paid_order_fixture!("jc360_foreign_revision")
    foreign_plan = SubscriptionsFixtures.create_subscription_plan!()
    foreign_revision = SubscriptionsFixtures.create_plan_revision!(foreign_plan)
    replace_order_line_revision!(foreign_fixture.line_item.id, foreign_revision.id)

    assert_initial_activation_rejected!(
      foreign_fixture,
      "purchased plan revision does not belong"
    )

    missing_fixture =
      create_paid_order_fixture!("jc360_missing_revision", %{}, %{create_plan_revision?: false})

    assert_initial_activation_rejected!(
      missing_fixture,
      "subscription commercial contract is unresolved"
    )

    draft_fixture = create_paid_order_fixture!("jc360_draft_revision")
    draft_revision = create_draft_plan_revision!(draft_fixture.revision)
    replace_order_line_revision!(draft_fixture.line_item.id, draft_revision.id)

    assert_initial_activation_rejected!(
      draft_fixture,
      "purchased plan revision was never effective"
    )
  end

  @tag :jc360_task01
  test "initial activation rolls back when persisted period boundaries are invalid" do
    fixture = create_paid_order_fixture!("jc360_invalid_period")

    result =
      with_subscription_insert_mutation!(
        fixture.line_item.id,
        "NEW.current_period_end_at := NEW.current_period_start_at;",
        fn ->
          SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
        end
      )

    if match?({:ok, _}, result) do
      assert [subscription] = subscriptions_for_order(fixture.order.id)
      assert subscription.current_period_start_at == subscription.current_period_end_at
    end

    assert {:error,
            %Error{
              code: "TARGET_ORDER_UNPROVABLE",
              message:
                "current subscription period evidence is required to derive the effective target"
            }} = result,
           "expected invalid persisted period evidence to fail closed, got #{inspect(result)}"

    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task01
  test "initial activation fails closed for an incomplete purchased entitlement pair" do
    fixture =
      create_paid_order_fixture!("jc360_incomplete_pair", %{
        entitlement_kind: nil,
        entitlement_scope_key: "jc360:scope_without_kind"
      })

    assert fixture.revision.entitlement_kind == nil
    assert fixture.revision.entitlement_scope_key == "jc360:scope_without_kind"

    result =
      SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert {:error,
            %Error{
              code: "TARGET_ORDER_UNPROVABLE",
              message: "PlanRevision entitlement pair must be complete or exactly nil"
            }} = result,
           "expected the incomplete purchased entitlement pair to fail closed, got #{inspect(result)}"

    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task02
  test "public paid-order activation keeps the five documented result keys and types" do
    fixture = create_paid_order_fixture!("jc360_result_contract")

    assert {:ok, result} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert Enum.sort(Map.keys(result)) ==
             Enum.sort([
               :order_id,
               :subscription_line_count,
               :created_count,
               :skipped_count,
               :entitlement_issued_count
             ])

    assert {:ok, _uuid} = Ecto.UUID.cast(result.order_id)
    assert result.order_id == fixture.order.id
    assert result.subscription_line_count == 1
    assert is_integer(result.created_count) and result.created_count >= 0
    assert is_integer(result.skipped_count) and result.skipped_count >= 0

    assert is_integer(result.entitlement_issued_count) and
             result.entitlement_issued_count >= 0
  end

  @tag :jc360_task02
  test "complete purchased pair returns APPLIED with the exact source grant" do
    fixture = create_paid_order_fixture!("jc360_public_complete_pair")

    assert {:ok, result} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert result.created_count == 1
    assert result.skipped_count == 0
    assert result.entitlement_issued_count == 1

    assert [subscription] = subscriptions_for_order(fixture.order.id)
    assert [effect] = access_effects_for_source_line(fixture.line_item.id)
    assert effect.subscription_id == subscription.id
    assert effect.source_version == subscription.aggregate_version
    assert effect.disposition == :effective
    assert effect.status == :applied
    assert effect.source_order_line_item_id == fixture.line_item.id
    assert effect.plan_revision_id == fixture.revision.id
    assert effect.contract_change_id == nil
    assert effect.entitlement_kind == fixture.revision.entitlement_kind
    assert effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert effect.valid_from_at == subscription.current_period_start_at
    assert effect.valid_until_at == subscription.current_period_end_at

    assert [grant] = entitlements_for_subscription(subscription.id)
    assert grant.user_id == subscription.user_id
    assert grant.source_kind == :subscription
    assert grant.source_id == subscription.id
    assert grant.kind == effect.entitlement_kind
    assert grant.scope_key == effect.entitlement_scope_key
    assert grant.status == :active
    assert grant.valid_from_at == effect.valid_from_at
    assert grant.valid_to_at == effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  @tag :jc360_task02
  test "nil/nil purchased pair stays EFFECTIVE with an empty grant target" do
    fixture =
      create_paid_order_fixture!("jc360_public_empty_target", %{
        entitlement_kind: nil,
        entitlement_scope_key: nil
      })

    assert {:ok, result} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert result.created_count == 1
    assert result.skipped_count == 0
    assert result.entitlement_issued_count == 0

    assert [subscription] = subscriptions_for_order(fixture.order.id)
    assert [effect] = access_effects_for_source_line(fixture.line_item.id)
    assert effect.status == :applied
    assert effect.disposition == :effective
    assert effect.subscription_id == subscription.id
    assert effect.source_order_line_item_id == fixture.line_item.id
    assert effect.plan_revision_id == fixture.revision.id
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == subscription.current_period_end_at

    assert entitlements_for_subscription(subscription.id) == []
  end

  @tag :jc360_task02
  test "initial activation rejects a purchased pair with no kind and leaves no source rows" do
    fixture =
      create_paid_order_fixture!("jc360_public_missing_kind", %{
        entitlement_kind: nil,
        entitlement_scope_key: "jc360:missing_kind_scope"
      })

    result =
      SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert {:error,
            %Error{
              code: "TARGET_ORDER_UNPROVABLE",
              message: "PlanRevision entitlement pair must be complete or exactly nil"
            }} = result

    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task02
  test "initial activation rejects a purchased pair with no scope and leaves no source rows" do
    fixture = create_paid_order_fixture!("jc360_public_missing_scope")

    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE plan_revisions SET entitlement_scope_key = NULL WHERE id = $1",
               [Ecto.UUID.dump!(fixture.revision.id)]
             )

    result =
      SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert {:error,
            %Error{
              code: "TARGET_ORDER_UNPROVABLE",
              message: "PlanRevision entitlement pair must be complete or exactly nil"
            }} = result

    assert_no_initial_activation_rows!(fixture)
  end

  @tag :jc360_task02
  test "paid-order replay adds no effect and reports zero additional entitlements after F1 noop" do
    fixture = create_committed_initial_effect_fixture!("jc360_public_replay")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    grants_before_replay =
      Sandbox.unboxed_run(Repo, fn -> entitlements_for_subscription(fixture.subscription.id) end)

    assert {:ok, :noop} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    effects_before_replay =
      Sandbox.unboxed_run(Repo, fn -> access_effects_for_source_line(fixture.line_item.id) end)

    assert {:ok, result} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
                 fixture.order.id
               )
             end)

    assert result.order_id == fixture.order.id
    assert result.subscription_line_count == 1
    assert result.created_count == 0
    assert result.skipped_count == 1
    assert result.entitlement_issued_count == 0

    assert Sandbox.unboxed_run(Repo, fn ->
             access_effects_for_source_line(fixture.line_item.id)
           end) == effects_before_replay

    assert Sandbox.unboxed_run(Repo, fn ->
             entitlements_for_subscription(fixture.subscription.id)
           end) == grants_before_replay
  end

  @tag :jc360_task02
  test "initial grant uses the persisted period instead of the legacy issue-time interval" do
    fixture = create_paid_order_fixture!("jc360_no_legacy_issue")
    persisted_period_start = ~U[2020-01-01 00:00:00Z]

    result =
      with_subscription_insert_mutation!(
        fixture.line_item.id,
        "NEW.current_period_start_at := '2020-01-01 00:00:00Z'::timestamptz;",
        fn ->
          SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
        end
      )

    assert {:ok, result} = result

    assert result.entitlement_issued_count == 1
    assert [subscription] = subscriptions_for_order(fixture.order.id)
    assert DateTime.compare(subscription.current_period_start_at, persisted_period_start) == :eq

    assert [grant] = entitlements_for_subscription(subscription.id)
    assert grant.kind == fixture.revision.entitlement_kind
    assert grant.scope_key == fixture.revision.entitlement_scope_key
    assert DateTime.compare(grant.valid_from_at, persisted_period_start) == :eq
    assert grant.valid_to_at == subscription.current_period_end_at

    assert [effect] = access_effects_for_source_line(fixture.line_item.id)
    assert DateTime.compare(effect.valid_from_at, persisted_period_start) == :eq
    assert effect.valid_until_at == subscription.current_period_end_at
  end

  @tag :jc360_task02
  test "projection-pending F1 still counts a newly applied complete target once" do
    fixture = create_paid_order_fixture!("jc360_projection_pending")

    result =
      with_projection_pending_constraint!(fn ->
        SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      end)

    assert {:ok, result} = result
    assert result.created_count == 1
    assert result.entitlement_issued_count == 1

    assert [subscription] = subscriptions_for_order(fixture.order.id)
    assert [effect] = access_effects_for_source_line(fixture.line_item.id)
    assert effect.status == :applied
    assert effect.projection_user_ids == [subscription.user_id]
    assert effect.projection_delivered_at == nil

    assert [grant] = entitlements_for_subscription(subscription.id)
    assert grant.status == :active
    assert grant.kind == fixture.revision.entitlement_kind
    assert grant.scope_key == fixture.revision.entitlement_scope_key
  end

  @tag :jc360_task02
  test "superseded initial effect adds no grant and source replay reports zero issued" do
    fixture = create_committed_initial_effect_fixture!("jc360_superseded_replay")

    assert %{num_rows: 1} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.query!(
                 "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
                 [Ecto.UUID.dump!(fixture.subscription.id)]
               )
             end)

    advanced_subscription =
      Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(fixture.subscription.id) end)

    assert {:ok, newer_effect} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.establish_access_effect_for_system(
                 initial_effect_input!(advanced_subscription, fixture.revision)
               )
             end)

    assert fetch_access_effect_unboxed!(fixture.effect.id).status == :superseded
    assert newer_effect.status == :required

    effects_before_terminal_noop =
      Sandbox.unboxed_run(Repo, fn -> access_effects_for_source_line(fixture.line_item.id) end)

    effect_ids_before_terminal_noop =
      MapSet.new(Enum.map(effects_before_terminal_noop, & &1.id))

    assert effect_ids_before_terminal_noop == MapSet.new([fixture.effect.id, newer_effect.id])

    grants_before_terminal_noop =
      Sandbox.unboxed_run(Repo, fn -> entitlements_for_subscription(fixture.subscription.id) end)

    assert grants_before_terminal_noop == []

    assert {:ok, :noop} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert fetch_access_effect_unboxed!(fixture.effect.id).status == :superseded

    effects_after_terminal_noop =
      Sandbox.unboxed_run(Repo, fn -> access_effects_for_source_line(fixture.line_item.id) end)

    assert MapSet.new(Enum.map(effects_after_terminal_noop, & &1.id)) ==
             effect_ids_before_terminal_noop

    assert Sandbox.unboxed_run(Repo, fn ->
             entitlements_for_subscription(fixture.subscription.id)
           end) == grants_before_terminal_noop

    assert {:ok, result} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
                 fixture.order.id
               )
             end)

    assert result.order_id == fixture.order.id
    assert result.subscription_line_count == 1
    assert result.created_count == 0
    assert result.skipped_count == 1
    assert result.entitlement_issued_count == 0

    effects_after_replay =
      Sandbox.unboxed_run(Repo, fn -> access_effects_for_source_line(fixture.line_item.id) end)

    assert MapSet.new(Enum.map(effects_after_replay, & &1.id)) ==
             effect_ids_before_terminal_noop

    assert Sandbox.unboxed_run(Repo, fn ->
             entitlements_for_subscription(fixture.subscription.id)
           end) == grants_before_terminal_noop

    assert fetch_access_effect_unboxed!(fixture.effect.id).status == :superseded
    assert fetch_access_effect_unboxed!(newer_effect.id).status == :required
  end

  @tag :jc360_task04
  test "paid-order F1 failure preserves ordered committed sources and leaves later IDs recoverable" do
    fixture = create_paid_order_with_three_revision_lines!("jc360_ordered_f1_failure")
    [_first_line, failed_line, _unattempted_line] = fixture.line_items
    order_before = fetch_order!(fixture.order.id)
    [payment_intent_before] = succeeded_payment_intents_for_order(fixture.order.id)

    assert order_before.state == :paid
    assert payment_intent_before.state == :succeeded

    result =
      with_effect_application_rejection!(failed_line.id, fn ->
        SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      end)

    assert {:error, %Error{}} = result,
           "expected the first F1 failure to reach the facade, got #{inspect(result)}"

    assert fetch_order!(fixture.order.id) == order_before
    assert succeeded_payment_intents_for_order(fixture.order.id) == [payment_intent_before]

    subscriptions = subscriptions_for_order(fixture.order.id)
    assert length(subscriptions) == 3
    assert count_subscription_items_for_order(fixture.order.id) == 3
    assert count_access_effects_for_order(fixture.order.id) == 3

    line_results =
      Enum.zip(fixture.line_items, [:applied, :failed_retryable, :required])
      |> Enum.map(fn {line_item, expected_status} ->
        [subscription] =
          Enum.filter(subscriptions, &(&1.source_order_line_item_id == line_item.id))

        [item] = subscription_items_for_source_line(line_item.id)
        [effect] = access_effects_for_source_line(line_item.id)

        assert item.subscription_id == subscription.id
        assert item.source_order_line_item_id == line_item.id
        assert effect.id
        assert effect.subscription_id == subscription.id
        assert effect.source_order_line_item_id == line_item.id
        assert effect.source_version == subscription.aggregate_version
        assert effect.status == expected_status

        {subscription, effect}
      end)

    effect_ids = Enum.map(line_results, fn {_subscription, effect} -> effect.id end)
    assert MapSet.size(MapSet.new(effect_ids)) == 3

    [
      {first_subscription, first_effect},
      {failed_subscription, _failed_effect},
      {unattempted_subscription, unattempted_effect}
    ] = line_results

    [first_grant] = entitlements_for_subscription(first_subscription.id)
    assert first_grant.source_kind == :subscription
    assert first_grant.source_id == first_subscription.id
    assert first_grant.kind == first_effect.entitlement_kind
    assert first_grant.scope_key == first_effect.entitlement_scope_key
    assert first_grant.status == :active
    assert entitlements_for_subscription(failed_subscription.id) == []
    assert entitlements_for_subscription(unattempted_subscription.id) == []

    assert {:ok, :applied} =
             SubscriptionsFacade.execute_effective_access_effect_for_system(unattempted_effect.id)

    assert fetch_access_effect!(unattempted_effect.id).status == :applied
    assert length(entitlements_for_subscription(unattempted_subscription.id)) == 1
    assert fetch_order!(fixture.order.id) == order_before
    assert succeeded_payment_intents_for_order(fixture.order.id) == [payment_intent_before]
  end

  @tag :jc360_task06
  test "paid-order replay does not reconstruct an effect for a historical source after plan mutation" do
    customer = SubscriptionsFixtures.create_customer!("jc360_historical_no_effect")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc360_historical:#{Ecto.UUID.generate()}"
      })

    _variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    historical =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert historical.revision.entitlement_kind == :membership_access
    assert historical.subscription.current_plan_revision_id == historical.revision.id
    assert historical.order.state == :paid
    assert historical.line_item.subscription_plan_revision_id_snapshot == historical.revision.id

    order_before = fetch_order!(historical.order.id)
    [payment_intent_before] = succeeded_payment_intents_for_order(historical.order.id)
    assert [subscription_before] = subscriptions_for_order(historical.order.id)
    assert subscription_before.id == historical.subscription.id
    assert subscription_before.source_order_line_item_id == historical.line_item.id
    assert [item_before] = subscription_items_for_source_line(historical.line_item.id)
    assert access_effects_for_source_line(historical.line_item.id) == []
    assert entitlements_for_subscription(historical.subscription.id) == []

    changed_scope = "jc360_historical:changed:#{Ecto.UUID.generate()}"

    changed_plan =
      plan
      |> Ash.Changeset.for_update(
        :update,
        %{entitlement_kind: :digital_library, entitlement_scope_key: changed_scope},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert changed_plan.entitlement_kind == :digital_library
    assert changed_plan.entitlement_scope_key == changed_scope
    assert historical.revision.entitlement_kind == :membership_access
    assert historical.revision.entitlement_scope_key != changed_scope

    assert {:ok, replay} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(
               historical.order.id
             )

    assert replay.order_id == historical.order.id
    assert replay.subscription_line_count == 1
    assert replay.created_count == 0
    assert replay.skipped_count == 1
    assert replay.entitlement_issued_count == 0

    assert [%Subscription{} = subscription_after] = subscriptions_for_order(historical.order.id)
    assert subscription_after.id == subscription_before.id
    assert subscription_after.source_order_line_item_id == historical.line_item.id

    assert [%SubscriptionItem{id: item_id}] =
             subscription_items_for_source_line(historical.line_item.id)

    assert item_id == item_before.id
    assert access_effects_for_source_line(historical.line_item.id) == []
    assert entitlements_for_subscription(historical.subscription.id) == []
    assert fetch_order!(historical.order.id) == order_before
    assert succeeded_payment_intents_for_order(historical.order.id) == [payment_intent_before]
  end

  test "run_due_renewals_for_system records unsupported fresh dispatch without dunning" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_renew_success")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:all"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_success",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    previous_period_end = subscription.current_period_end_at
    StripeAPIStub.stub_unexpected!("unsupported renewal dispatch must not contact Stripe")

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    renewed = fetch_subscription!(subscription.id)
    assert renewed.current_period_end_at == previous_period_end
    assert renewed.status == :active
    assert renewed.dunning_attempt_count == 0

    attempt = fetch_latest_attempt!(renewed.id)
    assert attempt.status == :processing
    assert is_binary(attempt.order_id)
    assert attempt.payment_intent_id == nil
    assert fetch_order!(attempt.order_id).state == :pending_payment

    [collection] =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert collection.dispatch_state == :not_started
    assert collection.financial_outcome == :unresolved
    assert collection.payment_intent_id == nil

    payment_intent_key = RenewalCollectionAttempts.payment_intent_key(collection.id)

    payment_intent =
      PaymentIntent
      |> Ash.Query.filter(expr(payment_intent_key == ^payment_intent_key))
      |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert payment_intent.state == :created
    assert payment_intent.provider_payment_id == nil
    assert payment_intent.provider_payment_method_ref == nil
  end

  test "run_due_renewals_for_system marks subscription past_due and attempt failed when chargeability is missing" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_renew_fail")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "PAYMENT_METHOD_REQUIRED"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_METHOD_REQUIRED"
  end

  test "zero retry allowance leaves an exhausted renewal past_due without suspension effects" do
    customer = SubscriptionsFixtures.create_customer!("jc265_zero_retry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 0,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc265-zero-retry"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    parent = self()
    handler_id = {__MODULE__, :jc265_dunning_exhaustion, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn event, measurements, metadata, pid ->
          send(pid, {List.to_tuple(event), measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

    assert_receive {{:store, :subscriptions, :dunning}, %{count: 1}, dunning_metadata}
    assert dunning_metadata.subscription_id == subscription.id
    assert dunning_metadata.status == :past_due

    exhausted = fetch_subscription!(subscription.id)
    assert exhausted.status == :past_due
    assert exhausted.dunning_attempt_count == 1
    assert %DateTime{} = exhausted.retry_suppressed_at
    assert is_nil(exhausted.ended_at)
    assert is_nil(exhausted.canceled_at)
    assert is_nil(exhausted.canceled_reason)
    assert is_nil(exhausted.next_retry_at)

    assert {:ok, detail} =
             SubscriptionsFacade.get_subscription_detail_for_user(customer, subscription.id)

    assert detail.action_capabilities.can_cancel_now?
    assert detail.action_capabilities.can_cancel_at_period_end?
    assert detail.action_capabilities.can_queue_plan_change?
    assert detail.action_capabilities.can_queue_variant_change?

    entitlement = fetch_entitlement!(subscription.id)
    assert entitlement.status == :active

    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
  end

  test "run_due_renewals_for_system requires stored payment method to be active" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_inactive_method")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_inactive",
        stored_payment_method_status: :inactive,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "PAYMENT_METHOD_REQUIRED"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_METHOD_REQUIRED"
  end

  test "run_due_renewals_for_system fails closed when provider is disabled" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    customer = SubscriptionsFixtures.create_customer!("phase26_sub_provider_disabled")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_phase26_provider_disabled",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)
    assert result.due_count == 1
    assert result.success_count == 0
    assert result.failed_count == 1

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "PAYMENT_PROVIDER_DISABLED"

    attempt = fetch_latest_attempt!(updated.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_PROVIDER_DISABLED"
  end

  test "run_due_renewals_for_system emits tick, renewal attempt, and dunning telemetry" do
    customer = SubscriptionsFixtures.create_customer!("phase29_subs_telemetry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    parent = self()
    handler_id = {__MODULE__, :phase29_subscriptions, System.unique_integer([:positive])}

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    :telemetry.attach_many(
      handler_id,
      [
        [:store, :subscriptions, :tick],
        [:store, :subscriptions, :renewal_attempt],
        [:store, :subscriptions, :dunning]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {List.to_tuple(event), measurements, metadata})
      end,
      parent
    )

    try do
      assert {:ok, %{due_count: 1, failed_count: 1}} =
               SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

      assert_receive {{:store, :subscriptions, :dunning}, %{count: 1}, dunning_metadata}
      assert dunning_metadata.subscription_id == subscription.id
      assert dunning_metadata.status == :past_due

      assert_receive {{:store, :subscriptions, :renewal_attempt}, renewal_measurements,
                      renewal_metadata}

      assert renewal_metadata.subscription_id == subscription.id
      assert renewal_metadata.outcome == :error
      assert renewal_measurements.duration > 0

      assert_receive {{:store, :subscriptions, :tick}, tick_measurements, tick_metadata}
      assert tick_measurements.due_count == 1
      assert tick_measurements.failed_count == 1
      assert tick_measurements.success_count == 0
      assert tick_metadata.due_count == 1
    after
      :telemetry.detach(handler_id)
    end
  end

  test "physical renewal applies exact-ID success after reserving inventory and live shipping" do
    customer = SubscriptionsFixtures.create_customer!("phase27_physical_success")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_price_minor: 2_500,
        base_variant_stock_on_hand: 10
      })

    variant = set_variant_weight!(base_variant, 750)

    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_100})
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_physical_success",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 450
      })

    StripeAPIStub.stub_unexpected!("renewal preparation must not submit a charge")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    renewal_order = reached.order
    renewal_payment_intent = reached.payment_intent

    StripeAPIStub.stub_payment_observation(
      renewal_payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert renewal_order.shipping_method_code == "GROUND"
    assert renewal_order.shipping_quote_amount_minor == 450
    assert renewal_order.shipping_total_minor == 450
    assert renewal_order.grand_total_minor == 2_550
    assert fetch_order!(renewal_order.id).state == :paid
    assert fetch_payment_intent!(renewal_payment_intent.id).amount_received_minor == 2_550
    assert fetch_payment_intent!(renewal_payment_intent.id).state == :succeeded

    reservation = fetch_reservation!(renewal_order.id, variant.id)
    assert reservation.state == :consumed

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 9
  end

  test "a legacy reached fixture retains the exact collection claim and key" do
    customer = SubscriptionsFixtures.create_customer!("jc229_dispatch_claim_before_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_dispatch_claim_before_provider",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("fresh renewal preparation must not submit a charge")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    collection = reached.collection
    payment_intent = reached.payment_intent

    assert collection.collection_ordinal == 1
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert payment_intent.payment_intent_key == "renewal-collection:" <> collection.id
    assert payment_intent.provider_request_reference == payment_intent.payment_intent_key
    assert payment_intent.id == reached.attempt.payment_intent_id
  end

  test "unobservable legacy reached renewal stays unresolved without a provider POST" do
    customer = SubscriptionsFixtures.create_customer!("jc229_unknown_provider_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 2_600,
        max_retry_attempts: 2,
        retry_schedule_hours: [0, 24]
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_unknown_provider_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!(
      "reached renewal without a provider ID must not contact Stripe"
    )

    reached =
      ReachedRenewalFixtures.prepare_reached!(subscription.id, now, provider_payment_id: nil)

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    collection = reached.collection

    assert collection.collection_ordinal == 1
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert collection.payment_intent_id == reached.payment_intent.id
    assert collection.id == reached.collection.id
    assert fetch_payment_intent!(reached.payment_intent.id).provider_payment_id == nil
  end

  test "exact requires-action observation is replayed without a charge POST" do
    customer = SubscriptionsFixtures.create_customer!("jc229_requires_action_split_state")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_requires_action_split_state",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    payment_intent = reached.payment_intent
    collection = reached.collection
    observation = ReachedRenewalFixtures.observation_body(reached, "requires_action")
    StripeAPIStub.stub_payment_observation(payment_intent.provider_payment_id, observation)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    payment_intent_count = Store.Repo.aggregate(PaymentIntent, :count, :id)
    subscription_before_replay = fetch_subscription!(subscription.id)
    attempt_before_replay = fetch_latest_attempt!(subscription.id)
    StripeAPIStub.stub_unexpected!("requires-action PaymentIntent must not be charged again")

    StripeAPIStub.stub_payment_observation(payment_intent.provider_payment_id, observation)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    observed_collection = fetch_collection_for_attempt!(attempt.id)
    assert observed_collection.id == collection.id
    assert observed_collection.financial_outcome == :requires_action
    assert fetch_payment_intent!(payment_intent.id).state == :requires_action
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == payment_intent_count

    subscription_after_replay = fetch_subscription!(subscription.id)
    attempt_after_replay = fetch_latest_attempt!(subscription.id)

    assert subscription_after_replay.dunning_attempt_count ==
             subscription_before_replay.dunning_attempt_count

    assert attempt_after_replay.attempt_no == attempt_before_replay.attempt_no
  end

  test "canceled reached collection applies exact requires-action observation without a POST" do
    customer = SubscriptionsFixtures.create_customer!("jc229_canceled_requires_action")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_canceled_requires_action",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    payment_intent = reached.payment_intent
    collection = reached.collection

    assert {:ok, %{status: :canceled}} =
             SubscriptionsFacade.cancel_subscription_for_user(customer, subscription.id, :now)

    payment_intent_count = Store.Repo.aggregate(PaymentIntent, :count, :id)

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "requires_action")
    )

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert fetch_subscription!(subscription.id).status == :canceled
    observed_collection = fetch_collection_for_attempt!(attempt.id)
    assert observed_collection.id == collection.id
    assert observed_collection.financial_outcome == :requires_action
    assert fetch_payment_intent!(payment_intent.id).state == :requires_action
    assert Store.Repo.aggregate(PaymentIntent, :count, :id) == payment_intent_count
  end

  test "reached collection recovery after cancellation does not submit another charge" do
    customer = SubscriptionsFixtures.create_customer!("jc229_canceled_reached_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_canceled_reached_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")

    reached =
      ReachedRenewalFixtures.prepare_reached!(subscription.id, now, provider_payment_id: nil)

    first_collection_id = reached.collection.id
    first_payment_intent_id = reached.payment_intent.id

    assert {:ok, %{status: :canceled}} =
             SubscriptionsFacade.cancel_subscription_for_user(customer, subscription.id, :now)

    StripeAPIStub.stub_unexpected!("canceled reached collection must not submit another charge")

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert fetch_subscription!(subscription.id).status == :canceled

    attempt = fetch_latest_attempt!(subscription.id)

    collections =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert [%RenewalCollectionAttempt{} = collection] = collections
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert collection.id == first_collection_id
    assert collection.payment_intent_id == first_payment_intent_id
    assert collection.collection_ordinal == 1
  end

  test "reached collection recovery after suspension does not dispatch another charge" do
    customer = SubscriptionsFixtures.create_customer!("jc229_suspended_reached_replay")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_suspended_reached_replay",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")

    reached =
      ReachedRenewalFixtures.prepare_reached!(subscription.id, now, provider_payment_id: nil)

    first_collection_id = reached.collection.id
    first_payment_intent_id = reached.payment_intent.id

    past_due =
      fetch_subscription!(subscription.id)
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{
          billing_status_reason: "PAYMENT_FAILED",
          past_due_since_at: DateTime.add(now, -86_400, :second),
          failed_payment_boundary_at: DateTime.add(now, -1, :second),
          dunning_attempt_count: 1,
          next_retry_at: nil,
          retry_suppressed_at: now
        },
        context: %{system?: true},
        private_arguments: %{
          dunning_renewal_attempt_id: fetch_collection!(first_collection_id).renewal_attempt_id
        }
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    suspended =
      past_due
      |> Ash.Changeset.for_update(
        :mark_suspended_transition,
        %{billing_status_reason: "PAYMENT_FAILED"},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert suspended.status == :suspended

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert fetch_subscription!(subscription.id).status == :suspended

    attempt = fetch_latest_attempt!(subscription.id)

    collections =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert [%RenewalCollectionAttempt{} = collection] = collections
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
    assert collection.id == first_collection_id
    assert collection.payment_intent_id == first_payment_intent_id
    assert collection.collection_ordinal == 1
  end

  test "terminal observation keeps its retry occurrence while the next dispatch is refused" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("jc229_terminal_collection_retry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 2_600,
        max_retry_attempts: 2,
        retry_schedule_hours: [0, 24]
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_jc229_terminal_collection_retry",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("a renewal POST is unavailable")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "canceled")
    )

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    first_collection = fetch_collection!(reached.collection.id)
    first_intent = fetch_payment_intent!(reached.payment_intent.id)
    order = fetch_order!(attempt.order_id)

    assert first_collection.collection_ordinal == 1
    assert first_collection.financial_outcome == :verified_terminal_financial_non_success
    assert first_collection.payment_intent_id == first_intent.id
    assert first_intent.state == :failed
    assert order.state == :pending_payment

    assert {:error,
            %{
              code: "RENEWAL_DISPATCH_UNAVAILABLE",
              meta: %{reason: :provider_revocation_fencing_unsupported}
            }} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    [first_collection, second_collection] =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.Query.sort(collection_ordinal: :asc)
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    updated_order = fetch_order!(order.id)

    assert second_collection.collection_ordinal == 2
    assert second_collection.renewal_attempt_id == attempt.id
    assert second_collection.id != first_collection.id
    assert second_collection.payment_intent_id == nil
    assert second_collection.financial_outcome == :unresolved
    assert second_collection.dispatch_state == :not_started

    second_payment_intent_key = RenewalCollectionAttempts.payment_intent_key(second_collection.id)

    second_payment_intent =
      PaymentIntent
      |> Ash.Query.filter(expr(payment_intent_key == ^second_payment_intent_key))
      |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert second_payment_intent.order_id == order.id
    assert second_payment_intent.provider_payment_id == nil
    assert second_payment_intent.state == :created
    assert updated_order.id == order.id
    assert updated_order.state == :pending_payment
    assert first_collection.financial_outcome == :verified_terminal_financial_non_success

    assert fetch_subscription!(subscription.id).current_period_end_at ==
             subscription.current_period_end_at
  end

  test "a stale legacy PaymentIntent cannot apply against an existing collection identity" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("jc229_stale_legacy_pi")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_600})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc229_stale_legacy_pi",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_unexpected!("legacy identity test must not submit a renewal charge")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    order = reached.order
    collection = reached.collection
    collection_intent = reached.payment_intent

    assert {:ok, _locally_failed} =
             collection_intent
             |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
             |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:ok, stale_result} =
             Store.Payments.create_or_reuse_payment_intent(
               %{
                 order_id: order.id,
                 amount_received_minor: collection_intent.amount_received_minor,
                 currency: collection_intent.currency,
                 provider: collection_intent.provider,
                 payment_intent_key: "jc229_stale_legacy:#{Ecto.UUID.generate()}"
               },
               context: %{system?: true}
             )

    stale_intent =
      stale_result.payment_intent
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "UPDATE renewal_attempts SET payment_intent_id = $2::uuid WHERE id = $1::uuid",
               [Ecto.UUID.dump!(attempt.id), Ecto.UUID.dump!(stale_intent.id)]
             )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Store.Payments.apply_payment_success_once(stale_intent.id)

    assert fetch_order!(order.id).state == :pending_payment

    assert 0 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert fetch_collection!(collection.id).payment_intent_id == collection_intent.id
  end

  test "exact-ID success observations with mismatched evidence cannot pay a renewal order" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    cases = [
      {"amount_mismatch", 2_500, %{"amount_received" => 2_499}},
      {"currency_mismatch", 2_600, %{"currency" => "zar"}},
      {"environment_mismatch", 2_700, %{"livemode" => true}},
      {"missing_id", 2_750, %{"id" => nil}},
      {"missing_evidence", 2_800,
       %{"amount_received" => nil, "amount" => nil, "currency" => nil, "livemode" => nil}}
    ]

    for {suffix, amount_minor, overrides} <- cases do
      customer = SubscriptionsFixtures.create_customer!("phase28_#{suffix}")
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: amount_minor})
      _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{subscription: subscription} =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
          provider: :stripe,
          provider_billing_ref: "pm_phase28_#{suffix}",
          next_renewal_at: DateTime.add(now, -10, :second)
        })

      StripeAPIStub.stub_unexpected!("renewal preparation must not submit a charge")
      reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
      order = reached.order
      payment_intent = reached.payment_intent

      StripeAPIStub.stub_payment_observation(
        payment_intent.provider_payment_id,
        ReachedRenewalFixtures.observation_body(reached, "succeeded", overrides)
      )

      assert {:error, _error} =
               SubscriptionsFacade.process_due_subscription_renewal_for_system(
                 subscription.id,
                 now: now
               )

      assert fetch_order!(order.id).state == :pending_payment
      assert fetch_payment_intent!(payment_intent.id).state == :submitted
      assert fetch_latest_attempt!(subscription.id).status == :processing

      assert 0 ==
               PaymentApplication
               |> Ash.Query.filter(expr(order_id == ^order.id))
               |> Ash.count!(domain: Store.Orders, authorize?: false)
    end
  end

  test "physical renewal hard blocker suppresses retries when shipping cost surges" do
    customer = SubscriptionsFixtures.create_customer!("phase27_physical_surge")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 10
      })

    variant = set_variant_weight!(base_variant, 500)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_physical_surge",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    %{shipping_rule: shipping_rule} =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 1_000
      })

    assert {:error, error} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert error.code == "SHIPPING_COST_SURGE"

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :past_due
    assert updated.billing_status_reason == "SHIPPING_COST_SURGE"
    assert %DateTime{} = updated.retry_suppressed_at
    assert updated.next_retry_at == nil

    attempt = fetch_latest_attempt!(subscription.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "SHIPPING_COST_SURGE"
    assert updated.dunning_attempt_count == 1
    assert attempt.charged_contract_snapshot["max_retry_attempts"] == 3

    assert {:ok, []} = SubscriptionsFacade.list_due_renewal_jobs_for_system(now: now, limit: 10)

    shipping_rule
    |> Ash.Changeset.for_update(:update, %{shipping_cost_minor: 400}, context: %{system?: true})
    |> Ash.update!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    target_plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(target_plan)

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    assert {:ok, repaired} =
             SubscriptionsFacade.queue_subscription_plan_change_for_user(
               customer,
               subscription.id,
               input
             )

    assert repaired.status == :past_due
    assert repaired.dunning_attempt_count == 1
    assert repaired.retry_suppressed_at == nil
    assert %DateTime{} = repaired.next_retry_at

    assert_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => subscription.id}
    )
  end

  test "physical fresh preparation without stock does not claim dunning or a reservation" do
    customer = SubscriptionsFixtures.create_customer!("phase27_physical_oos")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 0
      })

    variant = set_variant_weight!(base_variant, 300)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_physical_oos",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 400
      })

    StripeAPIStub.stub_unexpected!("fresh renewal preparation must not submit a charge")

    assert {:error, error} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert error.code == "RENEWAL_DISPATCH_UNAVAILABLE"
    assert error.meta == %{reason: :provider_revocation_fencing_unsupported}

    updated = fetch_subscription!(subscription.id)
    assert updated.status == :active
    assert updated.dunning_attempt_count == 0
    assert updated.retry_suppressed_at == nil
    assert updated.next_retry_at == subscription.next_retry_at

    attempt = fetch_latest_attempt!(subscription.id)
    assert attempt.status == :processing
    assert Repo.get_by!(InventoryItem, variant_id: variant.id).reserved_count == 0
    assert Repo.aggregate(PaymentApplication, :count, :id) == 0
  end

  test "physical renewal retains inventory through unresolved and successful exact-ID observations" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("phase27_physical_release")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 1
      })

    variant = set_variant_weight!(base_variant, 250)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_phase27_physical_release",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    _shipping =
      configure_shipping_profile!(source_order, variant, %{
        baseline_amount_minor: 400,
        live_amount_minor: 400
      })

    StripeAPIStub.stub_unexpected!("renewal preparation must not submit a charge")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    assert attempt.status == :processing
    payment_intent = reached.payment_intent
    assert payment_intent.provider_payment_id
    reservation = fetch_reservation!(reached.order.id, variant.id)
    assert reservation.state == :active

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "processing")
    )

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert :processing == fetch_latest_attempt!(subscription.id).status
    assert :pending_payment == fetch_order!(attempt.order_id).state
    assert :active == fetch_reservation!(attempt.order_id, variant.id).state
    assert 0 == Repo.aggregate(PaymentApplication, :count, :id)

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert :paid == fetch_order!(attempt.order_id).state
    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert 1 == Repo.aggregate(PaymentApplication, :count, :id)
    assert :consumed == fetch_reservation!(attempt.order_id, variant.id).state
  end

  test "legacy pending projections cannot select a renewal contract" do
    customer = SubscriptionsFixtures.create_customer!("phase27_sub_reconcile")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    %{variant: upgraded_variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 1_999})
    upgraded_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_999})
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    _upgrade_attachment =
      SubscriptionsFixtures.attach_variant_plan!(upgraded_variant.id, upgraded_plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase27_reconcile",
        next_renewal_at: DateTime.add(now, -10, :second),
        pending_variant_id: upgraded_variant.id,
        pending_subscription_plan_id: upgraded_plan.id,
        pending_renewal_amount_minor: upgraded_plan.amount_minor,
        pending_renewal_currency: upgraded_plan.currency,
        change_effective_at: now
      })

    attempts_before = Repo.aggregate(RenewalAttempt, :count, :id)
    orders_before = Repo.aggregate(Order, :count, :id)
    intents_before = Repo.aggregate(PaymentIntent, :count, :id)
    StripeAPIStub.stub_unexpected!("legacy pending projections must fail closed")

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert Repo.aggregate(RenewalAttempt, :count, :id) == attempts_before
    assert Repo.aggregate(Order, :count, :id) == orders_before
    assert Repo.aggregate(PaymentIntent, :count, :id) == intents_before

    unresolved = fetch_subscription!(subscription.id)
    assert unresolved.subscription_plan_id == plan.id
    assert unresolved.variant_id == variant.id
    assert unresolved.pending_subscription_plan_id == upgraded_plan.id
    assert unresolved.pending_variant_id == upgraded_variant.id
    assert unresolved.pending_renewal_amount_minor == upgraded_plan.amount_minor
    assert unresolved.pending_renewal_currency == upgraded_plan.currency
  end

  test "failed-payment suspension runs independently from retry discovery" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_grace")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        grace_period_days: 1,
        retry_schedule_hours: [24, 72, 120],
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:silver"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: nil,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

    past_due_subscription = fetch_subscription!(subscription.id)
    assert past_due_subscription.status == :past_due
    assert %DateTime{} = past_due_subscription.failed_payment_boundary_at

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(
               past_due_subscription,
               plan
             )

    assert {:ok, retry_result} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now, limit: 20)

    assert retry_result.due_count == 0

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    assert {:ok, %{suspended_count: 1}} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system(limit: 20)

    suspended = fetch_subscription!(subscription.id)
    assert suspended.status == :suspended
    assert is_nil(suspended.ended_at)
    assert is_nil(suspended.canceled_at)
    assert is_nil(suspended.canceled_reason)
    assert is_nil(suspended.next_retry_at)

    assert {:ok, effects} = current_access_effects(subscription.id)

    assert [effect] =
             Enum.filter(effects, fn %AccessEffect{disposition: disposition} ->
               disposition == :non_effective
             end)

    assert effect.status == :required

    assert {:ok, :applied} =
             SubscriptionsFacade.execute_suspension_access_effect_for_system(effect.id)

    entitlement = fetch_entitlement!(subscription.id)
    assert entitlement.status == :revoked
    assert entitlement.revoked_reason == "grace_expired"

    assert 0 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(subscription_id == ^subscription.id and template_kind == :access_ended)
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system(limit: 20)
  end

  test "create_subscriptions_from_paid_order_for_system fails closed when provider selection is missing" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_missing_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        %{
          create_payment_intent?: false
        }
      )

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert error.code == "SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED"
    assert 0 == count_subscriptions_for_order_line(order.id)
  end

  test "create_subscriptions_from_paid_order_for_system fails closed when provider is disabled" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    customer = SubscriptionsFixtures.create_customer!("phase26_sub_disabled_provider")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    assert {:error, error} =
             SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

    assert error.code == "PAYMENT_PROVIDER_DISABLED"
    assert 0 == count_subscriptions_for_order_line(order.id)
  end

  test "queue plan and variant changes use the requested dimension and live dimensions" do
    customer = SubscriptionsFixtures.create_customer!("phase27_boundary_queue")

    %{product: product, variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{base_variant_price_minor: 1_000})

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "current-plan",
        amount_minor: 1_000
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "target-plan",
        amount_minor: 2_500
      })

    invalid_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "invalid-plan",
        amount_minor: 4_000
      })

    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    target_variant =
      create_variant_target!(product.id, %{
        price_minor: 4_500,
        title: "Boundary Variant"
      })

    _target_variant_attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, target_plan.id)

    _target_variant_current_plan_attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, current_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider_customer_ref: "cus_boundary_001",
        provider_billing_ref: "pm_boundary_001"
      })

    {:ok, plan_input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    assert {:ok, queued_plan} =
             SubscriptionsFacade.queue_subscription_plan_change_for_user(
               customer,
               subscription.id,
               plan_input
             )

    assert queued_plan.pending_subscription_plan_id == target_plan.id
    assert queued_plan.pending_variant_id == nil
    assert queued_plan.pending_renewal_amount_minor == target_plan.amount_minor
    assert queued_plan.pending_renewal_currency == target_plan.currency

    {:ok, variant_input} =
      QueueSubscriptionVariantChangeInput.new(%{
        "subscription_id" => subscription.id,
        "variant_id" => target_variant.id
      })

    assert {:ok, queued_variant} =
             SubscriptionsFacade.queue_subscription_variant_change_for_user(
               customer,
               subscription.id,
               variant_input
             )

    assert queued_variant.pending_variant_id == target_variant.id
    assert queued_variant.pending_subscription_plan_id == target_plan.id
    assert queued_variant.pending_renewal_amount_minor == target_plan.amount_minor
    assert queued_variant.pending_renewal_currency == target_plan.currency

    contract_change =
      ContractChange
      |> Ash.Query.filter(expr(id == ^queued_variant.current_contract_change_id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert contract_change.target_plan_revision_id == target_revision.id
    assert contract_change.target_variant_id == target_variant.id

    {:ok, invalid_plan_input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => invalid_plan.id
      })

    assert {:error, error} =
             SubscriptionsFacade.queue_subscription_plan_change_for_user(
               customer,
               subscription.id,
               invalid_plan_input
             )

    assert error.code == "VARIANT_PLAN_UNAVAILABLE"
  end

  test "start_subscription_payment_method_update_for_user creates a setup-purpose intent" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_boundary_123",
        publishable_key: "pk_test_boundary_123",
        request_options: StripeAPIStub.req_options()
      ]
    )

    customer = SubscriptionsFixtures.create_customer!("phase27_payment_method_update")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_setup_001",
        provider_billing_ref: "pm_setup_existing"
      })

    {:ok, input} =
      StartSubscriptionPaymentMethodUpdateInput.new(%{"subscription_id" => subscription.id})

    assert {:ok, result} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               customer,
               subscription.id,
               input
             )

    assert result.provider == :stripe
    assert result.publishable_key == "pk_test_boundary_123"
    assert result.client_secret =~ "seti_test_"

    payment_intent = fetch_payment_intent!(result.payment_intent_id)
    assert payment_intent.purpose == :subscription_payment_method_update
    assert payment_intent.subscription_id == subscription.id
    assert payment_intent.provider_customer_ref == "cus_setup_001"
    assert payment_intent.provider_payment_id =~ "seti_test_"
    assert payment_intent.state == :submitted
  end

  defp create_paid_order_fixture!(prefix, plan_overrides \\ %{}, order_overrides \\ %{}) do
    customer = SubscriptionsFixtures.create_customer!(prefix)
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan_overrides =
      Map.merge(
        %{
          entitlement_kind: :membership_access,
          entitlement_scope_key: "#{prefix}:#{Ecto.UUID.generate()}"
        },
        plan_overrides
      )

    plan = SubscriptionsFixtures.create_subscription_plan!(plan_overrides)
    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{order: order, line_item: line_item, revision: revision} =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(
        customer.id,
        variant,
        plan,
        order_overrides
      )

    %{
      customer: customer,
      product: product,
      variant: variant,
      variant_plan: variant_plan,
      plan: plan,
      order: order,
      line_item: line_item,
      line_items: [line_item],
      revision: revision,
      revisions: [revision],
      plans: [plan]
    }
  end

  defp create_paid_order_with_two_revision_lines!(prefix) do
    fixture = create_paid_order_fixture!(prefix)

    retired_revision =
      fixture.revision
      |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    same_plan_revision = SubscriptionsFixtures.create_plan_revision!(fixture.plan)

    second_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "#{prefix}:second:#{Ecto.UUID.generate()}"
      })

    _second_variant_plan =
      SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, second_plan.id)

    second_revision = SubscriptionsFixtures.create_plan_revision!(second_plan)

    second_line =
      create_subscription_order_line_for_revision!(
        fixture.order,
        fixture.variant,
        second_plan,
        second_revision,
        2
      )

    Map.merge(fixture, %{
      line_items: [fixture.line_item, second_line],
      revisions: [retired_revision, second_revision],
      plans: [fixture.plan, second_plan],
      same_plan_revision: same_plan_revision
    })
  end

  defp measured_operation(fun) do
    started_at = System.monotonic_time(:microsecond)
    {result, stats} = RepoStats.capture(fun)
    {result, stats, System.monotonic_time(:microsecond) - started_at}
  end

  defp measurement_row(operation, sample, line_count, duration_us, stats, fixture) do
    Map.merge(stats, %{
      tag: "JC360_MEASUREMENTS",
      operation: operation,
      sample: sample,
      sample_count: 4,
      source_line_count: line_count,
      order_id: fixture.order.id,
      source_order_line_item_ids: Enum.map(fixture.line_items, & &1.id),
      wall_duration_us: duration_us,
      queue_time_unit: "native telemetry units",
      query_time_unit: "native telemetry units",
      decode_time_unit: "native telemetry units",
      workload_class: "hot"
    })
  end

  defp percentile(values, fraction) do
    sorted = Enum.sort(values)
    index = max(1, ceil(length(sorted) * fraction))
    Enum.at(sorted, index - 1)
  end

  defp latency_summary(samples, latency_index) do
    values = Enum.map(samples, &elem(&1, latency_index))

    %{
      p50_us: percentile(values, 0.50),
      p95_us: percentile(values, 0.95),
      p99_us: percentile(values, 0.99)
    }
  end

  defp create_paid_order_with_three_revision_lines!(prefix) do
    fixture = create_paid_order_with_two_revision_lines!(prefix)

    third_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "#{prefix}:third:#{Ecto.UUID.generate()}"
      })

    _third_variant_plan =
      SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, third_plan.id)

    third_revision = SubscriptionsFixtures.create_plan_revision!(third_plan)

    third_line =
      create_subscription_order_line_for_revision!(
        fixture.order,
        fixture.variant,
        third_plan,
        third_revision,
        3
      )

    Map.merge(fixture, %{
      line_items: fixture.line_items ++ [third_line],
      revisions: fixture.revisions ++ [third_revision],
      plans: fixture.plans ++ [third_plan]
    })
  end

  defp create_subscription_order_line_for_revision!(order, variant, plan, revision, line_no) do
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
        sku_snapshot: variant.sku || "JC360-SUB-LINE",
        product_title_snapshot: "JC360 subscription product",
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

  defp create_draft_plan_revision!(%PlanRevision{} = revision) do
    fields = [
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

    attrs =
      revision
      |> Map.take(fields)
      |> Map.put(:subscription_plan_id, revision.subscription_plan_id)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp replace_order_line_revision!(line_item_id, revision_id) do
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE order_line_items SET subscription_plan_revision_id_snapshot = $1 WHERE id = $2",
               [Ecto.UUID.dump!(revision_id), Ecto.UUID.dump!(line_item_id)]
             )
  end

  defp assert_initial_activation_rejected!(fixture, expected_message) do
    result =
      SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert {:error, %{code: "VALIDATION_ERROR", message: message}} = result
    assert message =~ expected_message
    assert_no_initial_activation_rows!(fixture)
  end

  defp assert_no_initial_activation_rows!(fixture) do
    assert subscriptions_for_order(fixture.order.id) == []
    assert count_subscription_items_for_order(fixture.order.id) == 0
    assert count_access_effects_for_order(fixture.order.id) == 0
    assert count_entitlements_for_order(fixture.order.id) == 0

    Enum.each(fixture.line_items, fn line_item ->
      assert subscription_items_for_source_line(line_item.id) == []
      assert access_effects_for_source_line(line_item.id) == []
    end)
  end

  defp with_item_insert_rejection!(line_item_id, fun) do
    constraint = "jc360_reject_item_#{System.unique_integer([:positive])}"

    try do
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.query!("""
      ALTER TABLE subscription_items
      ADD CONSTRAINT #{constraint}
      CHECK (source_order_line_item_id <> #{uuid_sql_literal!(line_item_id)})
      NOT VALID
      """)

      fun.()
    after
      Repo.query!("ALTER TABLE subscription_items DROP CONSTRAINT IF EXISTS #{constraint}")
    end
  end

  defp with_effect_insert_rejection!(revision_id, fun) do
    constraint = "jc360_reject_effect_#{System.unique_integer([:positive])}"

    try do
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.query!("""
      ALTER TABLE access_effects
      ADD CONSTRAINT #{constraint}
      CHECK (plan_revision_id <> #{uuid_sql_literal!(revision_id)})
      NOT VALID
      """)

      fun.()
    after
      Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
    end
  end

  defp with_effect_application_rejection!(line_item_id, fun) do
    constraint = "jc360_reject_f1_#{System.unique_integer([:positive])}"

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

  defp with_projection_pending_constraint!(fun) do
    constraint = "jc360_projection_pending_#{System.unique_integer([:positive])}"

    try do
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.query!("""
      ALTER TABLE access_effects
      ADD CONSTRAINT #{constraint}
      CHECK (projection_delivered_at IS NULL)
      NOT VALID
      """)

      fun.()
    after
      Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
    end
  end

  defp with_subscription_insert_mutation!(line_item_id, assignment, fun) do
    unique = System.unique_integer([:positive])
    function_name = "jc360_subscription_mutation_#{unique}"
    trigger_name = "jc360_subscription_mutation_#{unique}"

    try do
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.query!("""
      CREATE FUNCTION #{function_name}() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.source_order_line_item_id = #{uuid_sql_literal!(line_item_id)} THEN
          #{assignment}
        END IF;
        RETURN NEW;
      END;
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER #{trigger_name}
      BEFORE INSERT ON subscriptions
      FOR EACH ROW EXECUTE FUNCTION #{function_name}()
      """)

      fun.()
    after
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger_name} ON subscriptions")
      Repo.query!("DROP FUNCTION IF EXISTS #{function_name}()")
    end
  end

  defp uuid_sql_literal!(uuid) do
    {:ok, canonical_uuid} = Ecto.UUID.cast(uuid)
    "'#{canonical_uuid}'::uuid"
  end

  defp create_committed_initial_effect_fixture!(prefix) do
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

            source =
              SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

            input = initial_effect_input!(source.subscription, source.revision)
            {:ok, effect} = SubscriptionsFacade.establish_access_effect_for_system(input)

            Map.merge(source, %{
              customer: customer,
              product: product,
              variant: variant,
              variant_plan: variant_plan,
              plan: plan,
              effect: effect
            })
          end)

        fixture
      end)

    on_exit(fn -> cleanup_committed_initial_effect_fixture!(fixture) end)
    fixture
  end

  defp initial_effect_input!(%Subscription{} = subscription, %PlanRevision{} = revision) do
    {:ok, target} = AccessEffectTargetOrder.derive_current_target(subscription, revision)

    attrs =
      Map.merge(target, %{
        subscription_id: subscription.id,
        source_version: subscription.aggregate_version
      })

    {:ok, input} = EstablishAccessEffectInput.new(attrs)
    input
  end

  defp cleanup_committed_initial_effect_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_plan_id = Ecto.UUID.dump!(fixture.variant_plan.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)
      user_id = Ecto.UUID.dump!(fixture.subscription.user_id)

      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [
                   subscription_id
                 ])

                 Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!(
                   "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
                   [subscription_id]
                 )

                 Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
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

      assert_committed_initial_effect_fixture_removed!(fixture)
    end)
  end

  defp assert_committed_initial_effect_fixture_removed!(fixture) do
    subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
    line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
    order_id = Ecto.UUID.dump!(fixture.order.id)
    effect_id = Ecto.UUID.dump!(fixture.effect.id)
    variant_id = Ecto.UUID.dump!(fixture.variant.id)
    variant_plan_id = Ecto.UUID.dump!(fixture.variant_plan.id)
    product_id = Ecto.UUID.dump!(fixture.product.id)
    plan_id = Ecto.UUID.dump!(fixture.plan.id)
    user_id = Ecto.UUID.dump!(fixture.subscription.user_id)

    checks = [
      {"subscriptions",
       "SELECT count(*) FROM subscriptions WHERE id = $1 OR source_order_id = $2 OR source_order_line_item_id = $3",
       [subscription_id, order_id, line_item_id]},
      {"subscription_items",
       "SELECT count(*) FROM subscription_items WHERE subscription_id = $1 OR source_order_line_item_id = $2",
       [subscription_id, line_item_id]},
      {"access_effects",
       "SELECT count(*) FROM access_effects WHERE id = $1 OR subscription_id = $2 OR source_order_line_item_id = $3",
       [effect_id, subscription_id, line_item_id]},
      {"entitlement_grants", "SELECT count(*) FROM entitlement_grants WHERE source_id = $1",
       [subscription_id]},
      {"renewal_attempts", "SELECT count(*) FROM renewal_attempts WHERE subscription_id = $1",
       [subscription_id]},
      {"order_line_items", "SELECT count(*) FROM order_line_items WHERE id = $1", [line_item_id]},
      {"order_adjustments", "SELECT count(*) FROM order_adjustments WHERE order_id = $1",
       [order_id]},
      {"fulfillment_orders", "SELECT count(*) FROM fulfillment_orders WHERE order_id = $1",
       [order_id]},
      {"payment_intents", "SELECT count(*) FROM payment_intents WHERE order_id = $1", [order_id]},
      {"orders", "SELECT count(*) FROM orders WHERE id = $1", [order_id]},
      {"variant_subscription_plans",
       "SELECT count(*) FROM variant_subscription_plans WHERE id = $1", [variant_plan_id]},
      {"plan_revisions", "SELECT count(*) FROM plan_revisions WHERE subscription_plan_id = $1",
       [plan_id]},
      {"subscription_plans", "SELECT count(*) FROM subscription_plans WHERE id = $1", [plan_id]},
      {"variants", "SELECT count(*) FROM variants WHERE id = $1", [variant_id]},
      {"products", "SELECT count(*) FROM products WHERE id = $1", [product_id]},
      {"users", "SELECT count(*) FROM users WHERE id = $1", [user_id]}
    ]

    Enum.each(checks, fn {table, query, params} ->
      assert %{rows: [[0]]} = Repo.query!(query, params),
             "committed fixture cleanup left rows in #{table}"
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

  defp count_access_effects_for_order(order_id) do
    subscription_ids = Enum.map(subscriptions_for_order(order_id), & &1.id)

    AccessEffect
    |> Ash.Query.filter(expr(subscription_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_access_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_access_effect_unboxed!(effect_id) do
    Sandbox.unboxed_run(Repo, fn -> fetch_access_effect!(effect_id) end)
  end

  defp count_subscriptions_for_order_line(order_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_id == ^order_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_subscription_items_for_order(order_id) do
    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    SubscriptionItem
    |> Ash.Query.filter(expr(subscription_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_entitlements_for_order(order_id) do
    subscription_ids =
      Subscription
      |> Ash.Query.filter(expr(source_order_id == ^order_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id in ^subscription_ids))
    |> Ash.count!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp entitlements_for_subscription(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_collection!(collection_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^collection_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_for_attempt!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp current_access_effects(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :desc)
    |> Ash.read(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_entitlement!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_payment_intent!(payment_intent_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^payment_intent_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> List.first()
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

  defp fetch_reservation!(order_id, variant_id) do
    InventoryReservation
    |> Ash.Query.filter(expr(order_id == ^order_id and variant_id == ^variant_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp configure_shipping_profile!(%Order{} = order, %Variant{} = variant, overrides) do
    zone = create_shipping_zone!("US", "CA")
    method = create_shipping_method!("GROUND")
    _tax_rate = create_tax_rate!("US", "CA")

    shipping_rule =
      create_shipping_rule!(
        zone.id,
        method.id,
        Map.get(overrides, :live_amount_minor, Map.get(overrides, :baseline_amount_minor, 400))
      )

    {:ok, request} =
      QuoteRequest.new(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: max(variant.weight_grams || 0, 0)
      })

    {:ok, options} = ShippingFacade.quote_options_for_system(request)
    option = Enum.find(options, &(&1.shipping_method_code == method.code))
    assert option

    addressed_order =
      order
      |> Ash.Changeset.for_update(
        :set_shipping_address,
        %{
          shipping_country_code: "US",
          shipping_region_code: "CA",
          shipping_postal_code: "94105",
          shipping_address_line1: "1 Market St",
          shipping_address_line2: "Suite 100"
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    method_order =
      addressed_order
      |> Ash.Changeset.for_update(
        :set_shipping_method,
        %{shipping_rate_code: method.code},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    baseline_amount = Map.get(overrides, :baseline_amount_minor, option.amount_minor)

    quoted_order =
      method_order
      |> Ash.Changeset.for_update(
        :set_shipping_quote_evidence,
        %{
          shipping_quote_hash: "baseline-#{System.unique_integer([:positive])}",
          shipping_quote_currency_code: option.currency_code,
          shipping_quote_amount_minor: baseline_amount,
          shipping_weight_grams: option.shipping_weight_grams,
          shipping_method_code: method.code,
          shipping_zone_id: option.zone_id
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    %{order: quoted_order, shipping_rule: shipping_rule}
  end

  defp create_shipping_zone!(country_code, region_code) do
    ShippingZone
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "SUB-ZONE-#{System.unique_integer([:positive])}",
        country_code: country_code,
        region_code: region_code,
        active: true
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_method!(code) do
    ShippingMethod
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, name: code, active: true, sort_order: 100},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_rule!(zone_id, method_id, shipping_cost_minor) do
    ShippingRateRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "SUB-RULE-#{System.unique_integer([:positive])}",
        shipping_zone_id: zone_id,
        shipping_method_id: method_id,
        currency: "USD",
        shipping_cost_minor: shipping_cost_minor,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_tax_rate!(country_code, region_code) do
    TaxRate
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "SUB-TAX-#{System.unique_integer([:positive])}",
        country_code: country_code,
        region_code: region_code,
        product_tax_category: "STANDARD",
        rate_basis_points: 0,
        shipping_taxable: true,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  defp set_variant_weight!(%Variant{} = variant, weight_grams) do
    variant
    |> Ash.Changeset.for_update(
      :update,
      %{weight_grams: weight_grams},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end

  defp create_variant_target!(product_id, overrides) do
    option =
      ProductOption
      |> Ash.Changeset.for_create(
        :create,
        %{
          product_id: product_id,
          name: "Edition #{System.unique_integer([:positive])}",
          slug: "edition-#{System.unique_integer([:positive])}",
          position: 1,
          selection_required: false
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    value =
      ProductOptionValue
      |> Ash.Changeset.for_create(
        :create,
        %{
          product_option_id: option.id,
          name: "Collector #{System.unique_integer([:positive])}",
          slug: "collector-#{System.unique_integer([:positive])}",
          position: 1
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    archived_variant =
      Variant
      |> Ash.Changeset.for_create(
        :create,
        %{
          product_id: product_id,
          sku: "BOUNDARY-#{System.unique_integer([:positive])}",
          title: Map.get(overrides, :title, "Boundary Variant"),
          currency_code: Map.get(overrides, :currency_code, "USD"),
          price_minor: Map.get(overrides, :price_minor, 3_500),
          status: :archived
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    _inventory =
      InventoryItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          variant_id: archived_variant.id,
          stock_on_hand: 20,
          reserved_count: 0,
          allow_oversell: false
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    _selection =
      VariantOptionSelection
      |> Ash.Changeset.for_create(
        :create,
        %{
          variant_id: archived_variant.id,
          product_option_id: option.id,
          product_option_value_id: value.id
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    archived_variant
    |> Ash.Changeset.for_update(
      :update,
      %{status: :active},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end
end
