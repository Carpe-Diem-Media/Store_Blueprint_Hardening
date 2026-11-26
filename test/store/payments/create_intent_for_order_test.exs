defmodule Store.Payments.CreateIntentForOrderTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Digital.{DigitalAsset, ProductDigitalLink}
  alias Store.Digital.Facade, as: DigitalFacade
  alias Store.Digital.Queries.DownloadGrantIndexQuery
  alias Store.Digital.Workers.IssueGrantsForPaidOrderWorker
  alias Store.Orders.Order
  alias Store.Orders.PaymentApplication
  alias Store.Payments
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.{CreateIntentForOrderInput, ObservePaymentIntentInput}
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.Interlocks
  alias Store.Payments.PaymentIntent
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.EnsureFulfillmentForPaidOrderWorker
  alias Store.Workers.ExpirePendingProviderSetupOrdersWorker
  alias Store.Workers.ProcessWebhookReceiptWorker

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "create_intent_for_order requires finalized totals" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert error.code == "VALIDATION_ERROR"
  end

  test "create_intent_for_order uses finalized totals and is idempotent" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

    selection =
      quote_selection!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, shipping_input} =
             CheckoutShippingInput.new(%{
               "recipient_name" => "Jane Customer",
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "phone" => "555-555-1212",
               "quote_hash" => selection.quote_hash,
               "shipping_method_code" => selection.shipping_method_code
             })

    assert {:ok, _checkout_with_shipping} =
             Checkout.set_shipping(actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, finalized_checkout} =
             Checkout.finalize_totals(actor, checkout_start.checkout_key, finalize_input)

    assert finalized_checkout.totals_finalized?
    assert finalized_checkout.grand_total_minor > 0

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:ok, first} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert first.amount_minor == finalized_checkout.grand_total_minor
    assert first.currency == finalized_checkout.currency_code
    assert first.state == :submitted
    assert is_binary(first.provider_session_id)
    assert is_binary(first.redirect_url)
    ready_order = fetch_order!(checkout_start.order_id)
    assert ready_order.state == :pending_payment
    assert is_nil(ready_order.provider_setup_started_at)

    assert {:ok, second} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert second.payment_intent_id == first.payment_intent_id
    assert second.payment_intent_key == first.payment_intent_key
    assert second.duplicate? == true
  end

  test "create_intent_for_order denies guest actor when checkout includes digital-linked items" do
    token = Ash.UUIDv7.generate()
    guest_actor = %{cart_token: token}
    {variant_id, _admin, _product} = published_variant_with_admin!()
    create_digital_link_for_variant!(variant_id)
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

    selection =
      quote_selection!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, shipping_input} =
             CheckoutShippingInput.new(%{
               "recipient_name" => "Digital Guest",
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "phone" => "555-555-1212",
               "quote_hash" => selection.quote_hash,
               "shipping_method_code" => selection.shipping_method_code
             })

    assert {:ok, _checkout_with_shipping} =
             Checkout.set_shipping(guest_actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(guest_actor, checkout_start.checkout_key, finalize_input)

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} =
             Payments.create_intent_for_order(
               guest_actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert error.code == "DIGITAL_GRANT_DENIED"
  end

  test "create_intent_for_order rejects unknown provider input before persisting" do
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

    selection =
      quote_selection!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, shipping_input} =
             CheckoutShippingInput.new(%{
               "recipient_name" => "Provider Test",
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "phone" => "555-555-1212",
               "quote_hash" => selection.quote_hash,
               "shipping_method_code" => selection.shipping_method_code
             })

    assert {:ok, _checkout_with_shipping} =
             Checkout.set_shipping(actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(actor, checkout_start.checkout_key, finalize_input)

    assert {:error, error} = CreateIntentForOrderInput.new(%{"provider" => "not_real"})
    assert error.code == "PAYMENT_PROVIDER_UNSUPPORTED"

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^checkout_start.order_id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "create_intent_for_order rejects disabled provider and does not persist intent" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}
    variant_id = published_variant_id!()
    create_pricing_rules!()

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, checkout_start} = Checkout.start_from_cart(nil, token, start_input)

    selection =
      quote_selection!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, shipping_input} =
             CheckoutShippingInput.new(%{
               "recipient_name" => "Provider Disabled Test",
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "phone" => "555-555-1212",
               "quote_hash" => selection.quote_hash,
               "shipping_method_code" => selection.shipping_method_code
             })

    assert {:ok, _checkout_with_shipping} =
             Checkout.set_shipping(actor, checkout_start.checkout_key, shipping_input)

    assert {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    assert {:ok, _finalized_checkout} =
             Checkout.finalize_totals(actor, checkout_start.checkout_key, finalize_input)

    assert {:ok, create_intent_input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} =
             Payments.create_intent_for_order(
               actor,
               checkout_start.checkout_key,
               create_intent_input
             )

    assert error.code == "PAYMENT_PROVIDER_DISABLED"

    assert 0 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^checkout_start.order_id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "Paystack checkout binds the exact reference and applies verified payment once" do
    {user, checkout} = finalized_paystack_checkout!()
    reference = "checkout-" <> String.replace(checkout.order_id, "-", "")
    amount = checkout.grand_total_minor

    configure_paystack!(amount, "failed")
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})

    assert {:ok, first} = Payments.create_intent_for_order(user, checkout.checkout_key, input)
    assert first.redirect_url == "https://checkout.paystack.com/test-session"
    assert first.state == :submitted

    assert_receive {:paystack_initialized,
                    %{
                      "reference" => ^reference,
                      "amount" => ^amount,
                      "currency" => "ZAR",
                      "email" => payer_email
                    }}

    assert payer_email == to_string(user.email)

    assert Store.Repo.get!(PaymentIntent, first.payment_intent_id).provider_request_reference ==
             reference

    assert {:ok, %{duplicate?: true, redirect_url: same_url}} =
             Payments.create_intent_for_order(user, checkout.checkout_key, input)

    assert same_url == first.redirect_url
    refute_received {:paystack_initialized, _}

    verification = %ObservePaymentIntentInput{payment_intent_id: first.payment_intent_id}
    assert {:ok, failure} = PaymentsFacade.observe_payment_intent_for_system(verification)
    assert failure.observation.normalized_outcome == :failure_observation
    assert failure.observation.metadata.feedback.code == "PAYMENT_FAILED"

    assert {:ok, %{outcome: :unresolved}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(failure)

    assert fetch_order!(checkout.order_id).state == :pending_payment

    configure_paystack!(amount + 1, "success")

    assert {:ok, %{eligibility: {:error, :amount_mismatch}} = mismatched} =
             PaymentsFacade.observe_payment_intent_for_system(verification)

    assert {:ok, %{outcome: :reconciliation_required}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(mismatched)

    assert fetch_order!(checkout.order_id).state == :pending_payment

    configure_paystack!(amount, "success")

    assert {:ok, %{eligibility: :eligible} = success} =
             PaymentsFacade.observe_payment_intent_for_system(verification)

    assert {:ok, %{outcome: :authoritative_success}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(success)

    assert {:ok, %{outcome: :already_applied_success}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(success)

    assert fetch_order!(checkout.order_id).state == :paid
  end

  test "an intent from the old Paystack scaffold requires review before dispatch" do
    {user, checkout} = finalized_paystack_checkout!()
    configure_paystack!(checkout.grand_total_minor, "ongoing")

    assert {:ok, %{payment_intent: legacy}} =
             Payments.create_or_reuse_payment_intent(%{
               order_id: checkout.order_id,
               amount_received_minor: checkout.grand_total_minor,
               currency: "ZAR",
               provider: :paystack
             })

    assert legacy.provider_request_reference == nil
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})

    assert {:error,
            %{code: "PAYMENT_OUTCOME_UNRESOLVED", meta: %{reason: :missing_durable_reference}}} =
             Payments.create_intent_for_order(user, checkout.checkout_key, input)

    refute_received {:paystack_initialized, _}
    assert Store.Repo.get!(PaymentIntent, legacy.id).provider_request_reference == nil
  end

  test "overlapping Pay clicks share one reference and a later click resumes the winning URL" do
    {user, checkout} = finalized_paystack_checkout!()
    test_pid = self()
    {:ok, submissions} = Agent.start_link(fn -> 0 end)

    configure_paystack!(checkout.grand_total_minor, "ongoing", fn conn, request ->
      case Agent.get_and_update(submissions, fn count -> {count, count + 1} end) do
        0 ->
          send(test_pid, {:initialize_waiting, self()})

          receive do
            :finish_initialize -> paystack_initialize_success(conn, request)
          after
            8_000 -> paystack_error(conn, 408, "request_timeout")
          end

        1 ->
          paystack_error(conn, 400, "duplicate_reference")
      end
    end)

    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})
    pay = fn -> Payments.create_intent_for_order(user, checkout.checkout_key, input) end
    first_click = Task.async(pay)
    first_request = receive_paystack_initialization!()

    provider_pid =
      receive do
        {:initialize_waiting, pid} -> pid
      after
        2_000 -> flunk("Paystack initialize never reached the response barrier")
      end

    try do
      assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} = pay.()
      assert receive_paystack_initialization!() == first_request
      assert fetch_order!(checkout.order_id).state == :pending_provider_setup
    after
      send(provider_pid, :finish_initialize)
    end

    assert {:ok, first} = Task.await(first_click)

    assert {:ok, %{duplicate?: true, payment_intent_id: id, redirect_url: url}} = pay.()
    assert id == first.payment_intent_id
    assert url == first.redirect_url
    assert_single_paystack_intent!(checkout.order_id, id, first_request["reference"])
    assert Agent.get(submissions, & &1) == 2
  end

  test "lost initialize response holds the original reference until verification proves payment" do
    {user, checkout} = finalized_paystack_checkout!()
    amount = checkout.grand_total_minor
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})
    pay = fn -> Payments.create_intent_for_order(user, checkout.checkout_key, input) end

    configure_paystack!(amount, :not_found, fn conn, _ ->
      paystack_error(conn, 408, "request_timeout")
    end)

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} = pay.()
    request = receive_paystack_initialization!()
    intent = Store.Repo.get_by!(PaymentIntent, order_id: checkout.order_id)
    assert intent.state == :created
    assert intent.provider_checkout_url == nil
    assert fetch_order!(checkout.order_id).state == :pending_provider_setup

    verification = %ObservePaymentIntentInput{payment_intent_id: intent.id}

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             PaymentsFacade.observe_payment_intent_for_system(verification)

    configure_paystack!(amount, "ongoing", fn conn, _ ->
      paystack_error(conn, 400, "duplicate_reference")
    end)

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} = pay.()
    assert receive_paystack_initialization!() == request
    assert_single_paystack_intent!(checkout.order_id, intent.id, request["reference"])

    assert {:ok, ongoing} = PaymentsFacade.observe_payment_intent_for_system(verification)

    assert {:ok, %{outcome: :unresolved}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(ongoing)

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Interlocks.apply_payment_success_once(intent)

    assert payment_application_count(checkout.order_id) == 0

    configure_paystack!(amount, "success")

    assert {:ok, %{eligibility: :eligible} = success} =
             PaymentsFacade.observe_payment_intent_for_system(verification)

    assert {:ok, %{outcome: :authoritative_success}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(success)

    assert {:ok, %{outcome: :already_applied_success}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(success)

    assert fetch_order!(checkout.order_id).state == :paid
    assert Store.Repo.get!(PaymentIntent, intent.id).state == :succeeded
    assert payment_application_count(checkout.order_id) == 1
    assert {:error, %{code: "PAYMENT_ALREADY_SUCCEEDED"}} = pay.()
    refute_received {:paystack_initialized, _}
  end

  test "a verified success after stale setup cancellation does not apply payment" do
    {user, checkout} = finalized_paystack_checkout!()
    amount = checkout.grand_total_minor
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})

    configure_paystack!(amount, "ongoing", fn conn, _ ->
      paystack_error(conn, 408, "request_timeout")
    end)

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             Payments.create_intent_for_order(user, checkout.checkout_key, input)

    request = receive_paystack_initialization!()
    order = fetch_order!(checkout.order_id)
    intent = Store.Repo.get_by!(PaymentIntent, order_id: order.id)
    assert order.state == :pending_provider_setup
    future = DateTime.add(order.provider_setup_started_at, 61, :second)

    assert {:ok, %{recovered_count: 0, swept_count: 1, order_ids: [order_id]}} =
             ExpirePendingProviderSetupOrdersWorker.sweep(future, ttl_seconds: 60)

    assert order_id == order.id
    assert fetch_order!(order.id).state == :cancelled
    refute_received {:paystack_initialized, _}

    configure_paystack!(amount, "success")
    verification = %ObservePaymentIntentInput{payment_intent_id: intent.id}

    assert {:ok, %{eligibility: :eligible} = success} =
             PaymentsFacade.observe_payment_intent_for_system(verification)

    assert {:error,
            %{code: "PAYMENT_EVENT_UNVERIFIED", message: "order is not in a payable state"}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(success)

    assert fetch_order!(order.id).state == :cancelled
    assert Store.Repo.get!(PaymentIntent, intent.id).state == :created
    assert payment_application_count(order.id) == 0
    assert_single_paystack_intent!(order.id, intent.id, request["reference"])
  end

  test "a refresh after a lost redirect obtains the stored Paystack URL without dispatching again" do
    {user, checkout} = finalized_paystack_checkout!()
    configure_paystack!(checkout.grand_total_minor, "ongoing")
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})

    # Discard the first caller's response to simulate a disconnect during navigation.
    Task.async(fn ->
      assert {:ok, _} = Payments.create_intent_for_order(user, checkout.checkout_key, input)
    end)
    |> Task.await()

    request = receive_paystack_initialization!()
    intent = Store.Repo.get_by!(PaymentIntent, order_id: checkout.order_id)

    assert {:ok, %{duplicate?: true, payment_intent_id: id, redirect_url: url}} =
             Payments.create_intent_for_order(user, checkout.checkout_key, input)

    assert id == intent.id
    assert url == intent.provider_checkout_url
    assert URI.parse(url).host == "checkout.paystack.com"
    assert_single_paystack_intent!(checkout.order_id, id, request["reference"])
    refute_received {:paystack_initialized, _}
  end

  test "CER-PT-002/003: competing verified Paystack evidence and late failure preserve one grant" do
    {variant_id, _, _} = published_variant_with_admin!("ZAR", :digital)
    digital_link = create_digital_link_for_variant!(variant_id)
    create_pricing_rules!("ZA", "WC", "ZAR")
    {user, checkout} = start_paystack_checkout!(variant_id)

    {:ok, finalize} =
      CheckoutFinalizeInput.new(%{billing_country_code: "ZA", billing_region_code: "WC"})

    assert {:ok, %{shipping_required?: false, shipping_total_minor: 0} = checkout} =
             Checkout.finalize_totals(user, checkout.checkout_key, finalize)

    other_user = TestFixtures.register_user!(email: TestFixtures.unique_email("other_buyer"))
    {:ok, grants_query} = DownloadGrantIndexQuery.new(%{})
    grant_job_args = %{"order_id" => checkout.order_id}
    reference = "checkout-" <> String.replace(checkout.order_id, "-", "")
    amount = checkout.grand_total_minor

    configure_paystack!(amount + 1, "success", fn conn, _ ->
      paystack_error(conn, 408, "request_timeout")
    end)

    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "paystack"})

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             Payments.create_intent_for_order(user, checkout.checkout_key, input)

    assert %{"reference" => ^reference} = receive_paystack_initialization!()
    intent = Store.Repo.get_by!(PaymentIntent, order_id: checkout.order_id)
    verify_input = %ObservePaymentIntentInput{payment_intent_id: intent.id}

    raw_body =
      Jason.encode!(%{
        event: "charge.success",
        data: %{
          id: 123_456_789,
          status: "success",
          reference: reference,
          domain: "test",
          amount: amount,
          currency: "ZAR"
        }
      })

    {:ok, input} =
      WebhookReceiptIngestInput.new(%{
        provider: :paystack,
        idempotency_key: "paystack:charge.success:123456789",
        provider_event_id: "charge.success:123456789",
        event_type: "charge.success",
        verification_status: "verified",
        raw_body: raw_body,
        headers: %{}
      })

    assert {:ok, %{receipt: receipt}} =
             PaymentsFacade.ingest_webhook_receipt_for_system(input)

    job = %Oban.Job{args: %{"webhook_receipt_id" => receipt.id}}

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             ProcessWebhookReceiptWorker.perform(job)

    assert fetch_order!(checkout.order_id).state == :pending_provider_setup
    assert payment_application_count(checkout.order_id) == 0
    refute_enqueued(worker: IssueGrantsForPaidOrderWorker, args: grant_job_args)
    assert {:ok, []} = DigitalFacade.list_download_grants_for_user(user, grants_query)
    configure_paystack!(amount, "failed")
    assert {:ok, earlier_failure} = PaymentsFacade.observe_payment_intent_for_system(verify_input)
    assert earlier_failure.observation.normalized_outcome == :failure_observation

    assert {:ok, %{outcome: :unresolved}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(earlier_failure)

    configure_paystack!(amount, "success")
    assert {:ok, verified} = PaymentsFacade.observe_payment_intent_for_system(verify_input)

    assert {:error, :interrupted_before_commit} =
             Repo.transaction(fn ->
               assert {:ok, %{outcome: :authoritative_success}} =
                        PaymentsFacade.apply_observed_payment_outcome_for_system(verified)

               assert payment_application_count(checkout.order_id) == 1
               assert [%Oban.Job{}] = grant_jobs(grant_job_args)
               Repo.rollback(:interrupted_before_commit)
             end)

    assert fetch_order!(checkout.order_id).state == :pending_provider_setup
    assert payment_application_count(checkout.order_id) == 0
    assert grant_jobs(grant_job_args) == []
    refute_enqueued(worker: IssueGrantsForPaidOrderWorker, args: grant_job_args)

    # Independent evidence delivery processes enter reconciliation together.
    verification =
      Task.async(fn ->
        receive do
          :apply -> PaymentsFacade.apply_observed_payment_outcome_for_system(verified)
        end
      end)

    webhook =
      Task.async(fn ->
        receive do
          :apply -> ProcessWebhookReceiptWorker.perform(job)
        end
      end)

    send(verification.pid, :apply)
    send(webhook.pid, :apply)
    assert {:ok, %{outcome: outcome}} = Task.await(verification)
    assert outcome in [:authoritative_success, :already_applied_success]
    assert :ok = Task.await(webhook)
    assert fetch_order!(checkout.order_id).state == :paid
    assert payment_application_count(checkout.order_id) == 1
    assert {:ok, []} = DigitalFacade.list_download_grants_for_user(user, grants_query)

    refute_enqueued(
      worker: EnsureFulfillmentForPaidOrderWorker,
      args: grant_job_args
    )

    assert [grant_job] = grant_jobs(grant_job_args)
    assert :ok = IssueGrantsForPaidOrderWorker.perform(grant_job)

    assert {:ok, [grant]} = DigitalFacade.list_download_grants_for_user(user, grants_query)
    assert grant.order_id == checkout.order_id
    assert grant.digital_asset_id == digital_link.digital_asset_id
    assert grant.status == :active
    assert {:ok, []} = DigitalFacade.list_download_grants_for_user(other_user, grants_query)

    assert {:ok, %{outcome: :already_applied_success}} =
             PaymentsFacade.apply_observed_payment_outcome_for_system(earlier_failure)

    assert :ok = ProcessWebhookReceiptWorker.perform(job)

    assert [^grant_job] = grant_jobs(grant_job_args)

    assert :ok = IssueGrantsForPaidOrderWorker.perform(grant_job)

    assert {:ok, [%{id: grant_id}]} =
             DigitalFacade.list_download_grants_for_user(user, grants_query)

    assert grant_id == grant.id
    assert fetch_order!(checkout.order_id).state == :paid
    assert payment_application_count(checkout.order_id) == 1
  end

  defp grant_jobs(args) do
    Oban.Testing.all_enqueued(Repo, worker: IssueGrantsForPaidOrderWorker, args: args)
  end

  test "a cart with only a download-linked product still requires a shipping quote" do
    variant_id = published_variant_id!("ZAR")
    _digital_link = create_digital_link_for_variant!(variant_id)
    {user, checkout} = start_paystack_checkout!(variant_id)
    {:ok, finalize} = CheckoutFinalizeInput.new(%{})

    assert {:error, %{code: "SHIPPING_RATE_NOT_FOUND"}} =
             Checkout.finalize_totals(user, checkout.checkout_key, finalize)
  end

  defp finalized_paystack_checkout! do
    variant_id = published_variant_id!("ZAR")
    create_pricing_rules!("ZA", "WC", "ZAR")
    {user, checkout} = start_paystack_checkout!(variant_id)

    selection =
      quote_selection!(%{
        destination_country_code: "ZA",
        destination_region_code: "WC",
        destination_postal_code: "8001",
        currency_code: "ZAR",
        shipping_weight_grams: 0
      })

    {:ok, shipping} =
      CheckoutShippingInput.new(%{
        "recipient_name" => "Paystack Customer",
        "address_line1" => "1 Main St",
        "city" => "Cape Town",
        "country_code" => "ZA",
        "region_code" => "WC",
        "postal_code" => "8001",
        "phone" => "0215551212",
        "quote_hash" => selection.quote_hash,
        "shipping_method_code" => selection.shipping_method_code
      })

    {:ok, _checkout} = Checkout.set_shipping(user, checkout.checkout_key, shipping)
    {:ok, finalize} = CheckoutFinalizeInput.new(%{})
    {:ok, checkout} = Checkout.finalize_totals(user, checkout.checkout_key, finalize)
    {user, checkout}
  end

  defp start_paystack_checkout!(variant_id) do
    token = Ash.UUIDv7.generate()
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("paystack_payer"))

    {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    {:ok, _cart} = CartsFacade.add_item_for_user(user, token, add_input)
    {:ok, start_input} = CheckoutStartInput.new(%{})
    {:ok, checkout} = Checkout.start_from_cart(user, token, start_input)
    {user, checkout}
  end

  defp configure_paystack!(amount, payment_status, initialize \\ &paystack_initialize_success/2) do
    owner = self()

    plug = fn
      %{method: "POST", request_path: "/transaction/initialize"} = conn ->
        {:ok, data, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(data)
        send(owner, {:paystack_initialized, request})
        initialize.(conn, request)

      %{method: "GET", request_path: "/transaction/verify/" <> reference} = conn ->
        stub_paystack_verification(conn, reference, amount, payment_status)
    end

    previous = Application.get_env(:store, :payments, [])

    Application.put_env(
      :store,
      :payments,
      Keyword.merge(previous,
        enabled_providers: [:paystack],
        paystack: [restricted_key: "rk_test_fixture", request_options: [plug: plug]]
      )
    )
  end

  defp receive_paystack_initialization! do
    receive do
      {:paystack_initialized, request} -> request
    after
      2_000 -> flunk("Paystack initialize request was not sent")
    end
  end

  defp assert_single_paystack_intent!(order_id, intent_id, reference) do
    assert [%PaymentIntent{id: ^intent_id, provider_request_reference: ^reference}] =
             Store.Repo.all(from intent in PaymentIntent, where: intent.order_id == ^order_id)
  end

  defp payment_application_count(order_id) do
    Store.Repo.aggregate(
      from(application in PaymentApplication, where: application.order_id == ^order_id),
      :count
    )
  end

  defp paystack_initialize_success(conn, request) do
    paystack_reply(conn, %{
      "reference" => request["reference"],
      "access_code" => "test-session",
      "authorization_url" => "https://checkout.paystack.com/test-session"
    })
  end

  defp stub_paystack_verification(conn, _reference, _amount, :not_found),
    do: paystack_error(conn, 404, "transaction_not_found")

  defp stub_paystack_verification(conn, reference, amount, status) do
    paystack_reply(conn, %{
      "id" => 123_456_789,
      "reference" => reference,
      "domain" => "test",
      "amount" => amount,
      "currency" => "ZAR",
      "status" => status
    })
  end

  defp paystack_error(conn, http_status, code) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(http_status, Jason.encode!(%{"status" => false, "code" => code}))
  end

  defp paystack_reply(conn, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => true, "data" => data}))
  end

  defp create_pricing_rules!(country \\ "US", region \\ "CA", currency \\ "USD") do
    unique = System.unique_integer([:positive])
    method_code = "GROUND-#{unique}"

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: method_code, name: "Ground #{unique}", active: true, sort_order: 100},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "#{country}-#{region}-#{unique}",
          country_code: country,
          region_code: region,
          active: true
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _rate =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND_RULE_#{unique}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: currency,
          shipping_cost_minor: 500,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "#{region}-STANDARD-#{unique}",
          country_code: country,
          region_code: region,
          product_tax_category: "STANDARD",
          rate_basis_points: 800,
          shipping_taxable: true,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(order_id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp quote_selection!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

    %{
      quote_hash: option.quote_hash,
      shipping_method_code: option.shipping_method_code
    }
  end

  defp published_variant_id!(currency \\ "USD") do
    {variant_id, _admin, _product} = published_variant_with_admin!(currency)
    variant_id
  end

  defp published_variant_with_admin!(currency \\ "USD", kind \\ :simple) do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("phase21_pay_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase21-pay-#{System.unique_integer([:positive])}",
          title: "Phase 21 Pay Product",
          product_kind: kind,
          base_variant_sku: "P21-PAY-#{System.unique_integer([:positive])}",
          base_variant_currency_code: currency,
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 50
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    {published.default_variant_id, admin, published}
  end

  defp create_digital_link_for_variant!(variant_id) do
    digital_asset =
      DigitalAsset
      |> Ash.Changeset.for_create(:create, %{
        key: "phase24-digital-link-#{System.unique_integer([:positive])}",
        title: "Phase 24 Digital Link",
        content_type: "application/pdf",
        byte_size: 1024,
        storage_provider: "s3",
        storage_bucket: "downloads-bucket",
        storage_object_key: "assets/phase24.pdf",
        status: :active
      })
      |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})

    ProductDigitalLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        variant_id: variant_id,
        digital_asset_id: digital_asset.id,
        position: 0
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end
end
