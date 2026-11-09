defmodule Store.Subscriptions.JC366SupportPaymentSetupAuthorizationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    previous_payments = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_jc366_test",
        secret_key: "sk_test_jc366",
        publishable_key: "pk_test_jc366",
        request_options: StripeAPIStub.req_options()
      ]
    )

    on_exit(fn ->
      Application.put_env(:store, :payments, previous_payments)
    end)

    :ok
  end

  test "support can read a subscription but cannot start or supersede setup" do
    {owner, support, subscription} = setup_fixture!("support")

    owner_request_tag = {:jc366_owner_setup_request, subscription.id}
    test_pid = self()

    StripeAPIStub.stub_setup_intent(fn conn, params ->
      send(test_pid, owner_request_tag)
      StripeAPIStub.json_response(conn, StripeAPIStub.setup_intent_response(params))
    end)

    assert {:ok, owner_setup} =
             Facade.start_subscription_payment_method_update_for_user(
               owner,
               subscription.id,
               setup_input(subscription.id)
             )

    assert_receive ^owner_request_tag, 1_000
    original_subscription = fetch_subscription!(subscription.id)
    original_intents = setup_intent_snapshot(subscription.id)
    support_request_tag = {:jc366_support_setup_request, subscription.id}

    StripeAPIStub.stub_setup_intent(fn conn, params ->
      send(test_pid, support_request_tag)
      StripeAPIStub.json_response(conn, StripeAPIStub.setup_intent_response(params))
    end)

    assert {:ok, %Subscription{id: id}} =
             Facade.get_subscription_for_admin(support, subscription.id)

    assert id == subscription.id

    assert {:ok, support_detail} =
             Facade.get_subscription_detail_for_admin(support, subscription.id)

    assert support_detail.action_capabilities.payment_method_update_provider == :stripe
    refute support_detail.action_capabilities.can_update_payment_method?

    result =
      Facade.start_subscription_payment_method_update_for_admin(
        support,
        subscription.id,
        setup_input(subscription.id)
      )

    provider_requests = drain_messages(support_request_tag)
    current_subscription = fetch_subscription!(subscription.id)
    current_intents = setup_intent_snapshot(subscription.id)

    observed = %{
      forbidden?: match?({:error, %Error{code: "FORBIDDEN"}}, result),
      credential_disclosed?:
        match?({:ok, %{client_secret: secret}} when is_binary(secret) and secret != "", result),
      provider_requests: provider_requests,
      subscription_unchanged?:
        Map.take(current_subscription, [
          :payment_method_setup_generation,
          :aggregate_version,
          :provider_billing_ref
        ]) ==
          Map.take(original_subscription, [
            :payment_method_setup_generation,
            :aggregate_version,
            :provider_billing_ref
          ]),
      prior_setup_unchanged?:
        Map.fetch!(current_intents, owner_setup.payment_intent_id) ==
          Map.fetch!(original_intents, owner_setup.payment_intent_id),
      no_new_setup_intents?:
        MapSet.new(Map.keys(current_intents)) == MapSet.new(Map.keys(original_intents))
    }

    assert %{
             forbidden?: true,
             credential_disclosed?: false,
             provider_requests: 0,
             subscription_unchanged?: true,
             prior_setup_unchanged?: true,
             no_new_setup_intents?: true
           } == observed
  end

  test "support is denied direct setup generation and PaymentIntent actions" do
    {_owner, support, subscription} = setup_fixture!("direct")
    generation = fetch_subscription!(subscription.id).payment_method_setup_generation
    intents = setup_intent_snapshot(subscription.id)
    StripeAPIStub.stub_unexpected!("direct support setup writes must not contact Stripe")

    generation_result =
      subscription
      |> Ash.Changeset.for_update(:advance_payment_method_setup_generation, %{})
      |> Ash.update(domain: Store.Subscriptions, actor: support)

    intent_result =
      PaymentIntent
      |> Ash.Changeset.for_create(:create_subscription_setup, %{
        provider: :stripe,
        subscription_id: subscription.id,
        amount_received_minor: 0,
        currency: "USD",
        provider_customer_ref: subscription.provider_customer_ref,
        payment_intent_key: "pm-update:v2:#{subscription.id}:#{generation + 1}",
        subscription_setup_generation: generation + 1
      })
      |> Ash.create(domain: Store.Payments, actor: support)

    observed = %{
      generation_action_forbidden?: forbidden_error?(generation_result),
      intent_action_forbidden?: forbidden_error?(intent_result),
      generation_unchanged?:
        fetch_subscription!(subscription.id).payment_method_setup_generation == generation,
      no_setup_intents_created?: setup_intent_snapshot(subscription.id) == intents
    }

    assert %{
             generation_action_forbidden?: true,
             intent_action_forbidden?: true,
             generation_unchanged?: true,
             no_setup_intents_created?: true
           } == observed
  end

  test "admin and super_admin can start payment-method setup" do
    {_owner, _support, subscription} = setup_fixture!("privileged")

    for role <- [:admin, :super_admin] do
      actor = TestFixtures.register_user!(email: TestFixtures.unique_email("jc366_#{role}"))
      _assignment = TestFixtures.assign_role!(actor, role)

      assert {:ok, detail} = Facade.get_subscription_detail_for_admin(actor, subscription.id)
      assert detail.action_capabilities.payment_method_update_provider == :stripe
      assert detail.action_capabilities.can_update_payment_method?

      assert {:ok, %{client_secret: client_secret, payment_intent_id: intent_id}} =
               Facade.start_subscription_payment_method_update_for_admin(
                 actor,
                 subscription.id,
                 setup_input(subscription.id)
               )

      assert client_secret =~ "seti_test_"

      assert %PaymentIntent{
               purpose: :subscription_payment_method_update,
               subscription_id: subscription_id,
               state: :submitted
             } = fetch_payment_intent!(intent_id)

      assert subscription_id == subscription.id
    end
  end

  test "subscription owner can continue to start setup through the user facade" do
    {owner, _support, subscription} = setup_fixture!("owner")

    assert {:ok, detail} = Facade.get_subscription_detail_for_user(owner, subscription.id)
    assert detail.action_capabilities.payment_method_update_provider == :stripe
    assert detail.action_capabilities.can_update_payment_method?

    assert {:ok, %{client_secret: client_secret, payment_intent_id: intent_id}} =
             Facade.start_subscription_payment_method_update_for_user(
               owner,
               subscription.id,
               setup_input(subscription.id)
             )

    assert client_secret =~ "seti_test_"
    assert fetch_payment_intent!(intent_id).subscription_id == subscription.id
  end

  defp setup_fixture!(label) do
    owner = SubscriptionsFixtures.create_customer!("jc366_owner_#{label}")
    support = TestFixtures.register_user!(email: TestFixtures.unique_email("jc366_support"))
    _support_role = TestFixtures.assign_role!(support, :support)

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(owner.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_jc366_#{label}",
        provider_billing_ref: "pm_jc366_#{label}"
      })

    {owner, support, subscription}
  end

  defp setup_input(subscription_id) do
    %StartSubscriptionPaymentMethodUpdateInput{subscription_id: subscription_id}
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp setup_intent_snapshot(subscription_id) do
    PaymentIntent
    |> Ash.Query.filter(
      expr(
        subscription_id == ^subscription_id and
          purpose == :subscription_payment_method_update
      )
    )
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> Map.new(fn intent ->
      {intent.id,
       Map.take(intent, [
         :state,
         :payment_intent_key,
         :provider_payment_id,
         :provider_client_secret,
         :subscription_setup_generation
       ])}
    end)
  end

  defp fetch_payment_intent!(intent_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^intent_id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp drain_messages(tag, count \\ 0) do
    receive do
      ^tag -> drain_messages(tag, count + 1)
    after
      0 -> count
    end
  end

  defp forbidden_error?({:error, error}) do
    match?(%Error{code: "FORBIDDEN"}, Normalize.normalize(error))
  end

  defp forbidden_error?(_result), do: false
end
