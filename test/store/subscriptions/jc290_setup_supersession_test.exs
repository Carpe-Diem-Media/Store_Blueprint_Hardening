defmodule Store.Subscriptions.JC290SetupSupersessionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.Subscriptions.{StoredPaymentMethod, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessWebhookReceiptWorker

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "a replayed applied setup cannot replace a newer setup" do
    {customer, subscription} = setup_fixture!("replay")
    original = subscription.provider_billing_ref

    first = start_setup!(customer, subscription)
    first_intent = fetch_intent!(first.payment_intent_id)
    succeed_setup!(first_intent, "pm_jc290_first", "evt_jc290_first")
    applied_first = fetch_intent!(first_intent.id)
    first_marker = Map.get(applied_first, :setup_binding_applied_at)
    assert %DateTime{} = first_marker
    first_version = fetch_subscription!(subscription.id).aggregate_version

    second = start_setup!(customer, subscription)
    second_intent = fetch_intent!(second.payment_intent_id)
    succeed_setup!(second_intent, "pm_jc290_second", "evt_jc290_second")
    second_binding = fetch_subscription!(subscription.id)
    second_marker = Map.get(fetch_intent!(second_intent.id), :setup_binding_applied_at)
    assert %DateTime{} = second_marker

    assert second_binding.provider_billing_ref == "pm_jc290_second"
    second_version = second_binding.aggregate_version

    assert :ok = Facade.handle_payment_method_update_succeeded_for_system(second_intent.id)
    assert fetch_subscription!(subscription.id).aggregate_version == second_version

    assert :ok = Facade.handle_payment_method_update_succeeded_for_system(first_intent.id)

    current = fetch_subscription!(subscription.id)
    assert current.provider_billing_ref == "pm_jc290_second"
    assert current.aggregate_version == second_version
    assert current.aggregate_version > first_version

    assert Map.get(fetch_intent!(first_intent.id), :setup_binding_applied_at) == first_marker
    assert Map.get(fetch_intent!(second_intent.id), :setup_binding_applied_at) == second_marker
    assert fetch_intent!(first_intent.id).state == :succeeded
    assert fetch_intent!(second_intent.id).state == :succeeded
    assert fetch_stored_method!("pm_jc290_first").status == :active
    refute original == current.provider_billing_ref
  end

  test "a pending setup cannot bind after a newer setup start fails at the provider" do
    {customer, subscription} = setup_fixture!("provider_failure")
    original = subscription.provider_billing_ref

    first = start_setup!(customer, subscription)
    first_intent = fetch_intent!(first.payment_intent_id)

    StripeAPIStub.stub_setup_intent(fn conn, _params ->
      conn
      |> Plug.Conn.put_status(503)
      |> StripeAPIStub.json_response(%{
        "error" => %{"code" => "api_error", "message" => "provider unavailable"}
      })
    end)

    assert {:error, _reason} = start_setup_result(customer, subscription)

    failed_setup =
      PaymentIntent
      |> Ash.Query.filter(
        expr(
          subscription_id == ^subscription.id and
            purpose == :subscription_payment_method_update and id != ^first_intent.id
        )
      )
      |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert failed_setup.subscription_setup_generation ==
             first_intent.subscription_setup_generation + 1

    assert fetch_subscription!(subscription.id).payment_method_setup_generation ==
             failed_setup.subscription_setup_generation

    assert failed_setup.payment_intent_key ==
             "pm-update:v2:#{subscription.id}:#{failed_setup.subscription_setup_generation}"

    assert failed_setup.state == :created
    assert failed_setup.provider_payment_id == nil

    succeed_setup!(first_intent, "pm_jc290_obsolete", "evt_jc290_obsolete")

    assert fetch_subscription!(subscription.id).provider_billing_ref == original
    assert fetch_intent!(first_intent.id).state == :succeeded
    assert Map.get(fetch_intent!(first_intent.id), :setup_binding_applied_at) == nil
    assert {:ok, nil} = fetch_stored_method("pm_jc290_obsolete")
  end

  test "success for an older setup cannot bind while a newer setup is pending" do
    {customer, subscription} = setup_fixture!("newer_pending")
    original = subscription.provider_billing_ref

    first = start_setup!(customer, subscription)
    first_intent = fetch_intent!(first.payment_intent_id)
    _second = start_setup!(customer, subscription)

    succeed_setup!(first_intent, "pm_jc290_older", "evt_jc290_older")

    assert fetch_subscription!(subscription.id).provider_billing_ref == original
    assert Map.get(fetch_intent!(first_intent.id), :setup_binding_applied_at) == nil
    assert {:ok, nil} = fetch_stored_method("pm_jc290_older")
  end

  test "a direct binding write supersedes a pending setup" do
    {customer, subscription} = setup_fixture!("direct_binding")
    setup = start_setup!(customer, subscription)
    intent = fetch_intent!(setup.payment_intent_id)
    current_before_direct = fetch_subscription!(subscription.id)

    direct_method =
      StoredPaymentMethod
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          user_id: customer.id,
          provider: :stripe,
          provider_customer_ref: "cus_jc290_direct",
          provider_payment_method_ref: "pm_jc290_direct",
          status: :active
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    direct =
      current_before_direct
      |> Ash.Changeset.for_update(
        :set_provider_billing_reference,
        %{
          provider_customer_ref: direct_method.provider_customer_ref,
          provider_billing_ref: direct_method.provider_payment_method_ref,
          stored_payment_method_id: direct_method.id
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    succeed_setup!(intent, "pm_jc290_superseded_by_direct", "evt_jc290_direct")

    current = fetch_subscription!(subscription.id)
    assert current.provider_billing_ref == "pm_jc290_direct"
    assert current.provider_customer_ref == direct_method.provider_customer_ref
    assert current.stored_payment_method_id == direct_method.id
    assert current.aggregate_version == direct.aggregate_version
    assert fetch_intent!(intent.id).state == :succeeded
    assert Map.get(fetch_intent!(intent.id), :setup_binding_applied_at) == nil
    assert {:ok, nil} = fetch_stored_method("pm_jc290_superseded_by_direct")
  end

  test "setup start inside an existing transaction creates no intent and makes no provider request" do
    {customer, subscription} = setup_fixture!("outer_transaction")
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_setup_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      StripeAPIStub.json_response(conn, StripeAPIStub.setup_intent_response(params))
    end)

    before_generation = Map.get(subscription, :payment_method_setup_generation)

    assert {:ok, {:error, %Store.Support.Errors.Error{code: "VALIDATION_ERROR"}}} =
             Repo.transaction(fn -> start_setup_result(customer, subscription) end)

    current = fetch_subscription!(subscription.id)
    assert Map.get(current, :payment_method_setup_generation) == before_generation
    assert :atomics.get(posts, 1) == 0

    payment_intent_count =
      PaymentIntent
      |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
      |> Ash.count!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert payment_intent_count == 0
  end

  test "marker failure rolls back the setup method and subscription binding" do
    {customer, subscription} = setup_fixture!("marker_rollback")
    setup = start_setup!(customer, subscription)
    intent = fetch_intent!(setup.payment_intent_id)
    mark_setup_intent_succeeded!(intent, "pm_jc290_rollback")
    started_subscription = fetch_subscription!(subscription.id)
    original_version = started_subscription.aggregate_version

    constraint = "jc290_setup_marker_#{String.replace(intent.id, "-", "")}"

    Repo.query!(
      "ALTER TABLE payment_intents ADD CONSTRAINT #{constraint} CHECK (id <> '#{intent.id}'::uuid OR setup_binding_applied_at IS NULL)"
    )

    try do
      assert {:error, _reason} =
               Facade.handle_payment_method_update_succeeded_for_system(intent.id)

      current = fetch_subscription!(subscription.id)
      assert current.provider_billing_ref == subscription.provider_billing_ref
      assert current.aggregate_version == original_version
      assert fetch_intent!(intent.id).state == :succeeded
      assert Map.get(fetch_intent!(intent.id), :setup_binding_applied_at) == nil
      assert {:ok, nil} = fetch_stored_method("pm_jc290_rollback")
    after
      Repo.query!("ALTER TABLE payment_intents DROP CONSTRAINT IF EXISTS #{constraint}")
    end

    assert :ok = Facade.handle_payment_method_update_succeeded_for_system(intent.id)
    assert fetch_subscription!(subscription.id).provider_billing_ref == "pm_jc290_rollback"
    assert Map.get(fetch_intent!(intent.id), :setup_binding_applied_at)
    assert {:ok, _method} = fetch_stored_method("pm_jc290_rollback")
  end

  test "a historical setup intent without generation evidence is a binding no-op" do
    {_customer, subscription} = setup_fixture!("historical")
    original = subscription.provider_billing_ref

    intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: :stripe,
          purpose: :subscription_payment_method_update,
          subscription_id: subscription.id,
          provider_customer_ref: subscription.provider_customer_ref,
          amount_received_minor: 0,
          currency: "USD",
          payment_intent_key: "jc290:historical:#{subscription.id}"
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      |> then(fn created ->
        created
        |> Ash.Changeset.for_update(
          :set_provider_reference,
          %{
            provider: :stripe,
            purpose: :subscription_payment_method_update,
            subscription_id: subscription.id,
            provider_payment_id: "seti_jc290_historical_#{Ecto.UUID.generate()}",
            provider_customer_ref: subscription.provider_customer_ref
          },
          context: %{system?: true}
        )
        |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      end)
      |> then(fn created ->
        created
        |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
        |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      end)

    succeed_setup!(intent, "pm_jc290_historical", "evt_jc290_historical")

    assert fetch_subscription!(subscription.id).provider_billing_ref == original
    assert fetch_intent!(intent.id).state == :succeeded
    assert Map.get(fetch_intent!(intent.id), :setup_binding_applied_at) == nil
    assert {:ok, nil} = fetch_stored_method("pm_jc290_historical")
  end

  defp setup_fixture!(label) do
    customer = SubscriptionsFixtures.create_customer!("jc290_setup_#{label}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_jc290_#{label}",
        provider_billing_ref: "pm_jc290_original_#{label}"
      })

    {customer, fetch_subscription!(subscription.id)}
  end

  defp start_setup!(customer, subscription) do
    assert {:ok, result} = start_setup_result(customer, subscription)
    result
  end

  defp start_setup_result(customer, subscription) do
    input = %StartSubscriptionPaymentMethodUpdateInput{subscription_id: subscription.id}

    Facade.start_subscription_payment_method_update_for_user(customer, subscription.id, input)
  end

  defp succeed_setup!(intent, method_ref, event_id) do
    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(:ingest, %{
        provider: "stripe",
        provider_event_id: event_id,
        event_type: "setup_intent.succeeded",
        verification_status: "verified",
        processing_status: "new",
        raw_body: setup_success_body(intent, method_ref, event_id),
        headers: %{"content-type" => ["application/json"]}
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             ProcessWebhookReceiptWorker.perform(%Oban.Job{
               args: %{"webhook_receipt_id" => receipt.id}
             })
  end

  defp mark_setup_intent_succeeded!(intent, method_ref) do
    intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{provider_payment_method_ref: method_ref},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp setup_success_body(intent, method_ref, event_id) do
    provider_intent_id = intent.provider_payment_id

    Jason.encode!(%{
      "id" => event_id,
      "created" => 1_700_000_000,
      "livemode" => false,
      "type" => "setup_intent.succeeded",
      "data" => %{
        "object" => %{
          "id" => provider_intent_id,
          "livemode" => false,
          "status" => "succeeded",
          "currency" => String.downcase(intent.currency),
          "customer" => intent.provider_customer_ref,
          "payment_method" => method_ref,
          "metadata" => %{
            "local_intent_id" => intent.id,
            "subscription_id" => intent.subscription_id,
            "currency" => intent.currency
          }
        }
      }
    })
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_stored_method!(provider_ref) do
    assert {:ok, method} = fetch_stored_method(provider_ref)
    method
  end

  defp fetch_stored_method(provider_ref) do
    StoredPaymentMethod
    |> Ash.Query.filter(expr(provider_payment_method_ref == ^provider_ref))
    |> Ash.read_one(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
