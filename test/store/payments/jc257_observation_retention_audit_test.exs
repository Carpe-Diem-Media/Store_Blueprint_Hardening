defmodule Store.Payments.JC257ObservationRetentionAuditTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{Order, PaymentApplication}

  alias Store.Payments.{
    PaymentAttempt,
    PaymentIntent,
    ProviderEvent,
    WebhookReceipt
  }

  alias Store.Payments.Facade
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessWebhookReceiptWorker

  @amount_minor 2_500
  @provider_occurred_at ~U[2023-11-14 22:13:20Z]

  setup context do
    :ok = StripeAPIStub.setup_default(context)
    :ok
  end

  test "GET observations retain one PaymentIntent reference and apply success only on explicit request" do
    order = create_order!()
    provider_payment_id = "pi_jc257_#{Ash.UUIDv7.generate()}"
    payment_intent = create_submitted_payment_intent!(order)
    payment_intent = set_provider_payment_id!(payment_intent, provider_payment_id)
    request_count = start_supervised!({Agent, fn -> 0 end})

    StripeAPIStub.stub_observation(fn conn ->
      Agent.update(request_count, &(&1 + 1))
      assert conn.method == "GET"
      assert conn.request_path == "/v1/payment_intents/#{provider_payment_id}"

      StripeAPIStub.json_response(
        conn,
        stripe_payment_intent(provider_payment_id, "processing", payment_intent.id)
      )
    end)

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, unresolved} = Facade.observe_payment_intent_for_system(input)
    assert Agent.get(request_count, & &1) == 1
    assert unresolved.eligibility == {:error, :observation_not_authoritative_success}
    assert unresolved.observation.normalized_outcome == :unresolved
    assert unresolved.observation.provider_reference == provider_payment_id
    assert unresolved.observation.provider_transaction_id == provider_payment_id
    assert unresolved.observation.provider_occurred_at == nil
    assert %DateTime{} = unresolved.observation.observed_at
    assert unresolved.evidence.provider_reference == provider_payment_id
    assert unresolved.evidence.provider_occurred_at == nil
    assert unresolved.evidence.observed_at == unresolved.observation.observed_at
    assert fetch_payment_intent!(payment_intent.id).provider_payment_id == provider_payment_id
    assert fetch_payment_intent!(payment_intent.id).state == :submitted
    assert fetch_order!(order.id).grand_total_minor == @amount_minor
    assert fetch_order!(order.id).state == :pending_payment
    assert 0 == payment_application_count(order.id)
    assert 0 == owned_receipt_count(payment_intent.id, provider_payment_id)

    assert {:ok, %{outcome: :unresolved}} =
             Facade.apply_observed_payment_outcome_for_system(unresolved)

    assert fetch_payment_intent!(payment_intent.id).state == :submitted
    assert fetch_order!(order.id).state == :pending_payment
    assert 0 == payment_application_count(order.id)
    assert Agent.get(request_count, & &1) == 1

    StripeAPIStub.stub_observation(fn conn ->
      Agent.update(request_count, &(&1 + 1))
      assert conn.method == "GET"
      assert conn.request_path == "/v1/payment_intents/#{provider_payment_id}"

      StripeAPIStub.json_response(
        conn,
        stripe_payment_intent(provider_payment_id, "succeeded", payment_intent.id)
      )
    end)

    assert {:ok, succeeded} = Facade.observe_payment_intent_for_system(input)
    assert Agent.get(request_count, & &1) == 2
    assert succeeded.eligibility == :eligible
    assert succeeded.observation.normalized_outcome == :authoritative_success
    assert succeeded.observation.provider_reference == provider_payment_id
    assert succeeded.observation.provider_transaction_id == provider_payment_id
    assert succeeded.observation.provider_occurred_at == nil
    assert succeeded.evidence.provider_reference == provider_payment_id
    assert succeeded.evidence.provider_occurred_at == nil
    assert fetch_payment_intent!(payment_intent.id).provider_payment_id == provider_payment_id
    assert fetch_payment_intent!(payment_intent.id).state == :submitted
    assert fetch_order!(order.id).state == :pending_payment
    assert 0 == payment_application_count(order.id)
    assert 0 == owned_receipt_count(payment_intent.id, provider_payment_id)

    attempts = fetch_payment_attempts!(payment_intent.id)
    assert length(attempts) == 2

    assert Enum.map(attempts, & &1.outcome) |> Enum.sort() == [
             "authoritative_success",
             "unresolved"
           ]

    Enum.each(attempts, fn attempt ->
      assert attempt.observation_source == "verification"
      assert attempt.provider == :stripe
      assert attempt.provider_reference == provider_payment_id
      assert attempt.provider_transaction_id == provider_payment_id
      assert attempt.provider_event_id == nil
      assert attempt.provider_occurred_at == nil
      assert %DateTime{} = attempt.observed_at
    end)

    assert {:ok, %{outcome: :authoritative_success}} =
             Facade.apply_observed_payment_outcome_for_system(succeeded)

    assert {:ok, %{outcome: :already_applied_success}} =
             Facade.apply_observed_payment_outcome_for_system(succeeded)

    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
    assert fetch_payment_intent!(payment_intent.id).provider_payment_id == provider_payment_id
    assert fetch_order!(order.id).state == :paid
    assert 1 == payment_application_count(order.id)
    assert Agent.get(request_count, & &1) == 2
    assert 0 == owned_receipt_count(payment_intent.id, provider_payment_id)
  end

  test "purging one verified webhook receipt retains its normalized provider and payment evidence" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order)
    provider_payment_id = "pi_jc257_#{Ash.UUIDv7.generate()}"
    webhook_event_id = "evt_jc257_#{Ash.UUIDv7.generate()}"
    payment_intent = set_provider_payment_id!(payment_intent, provider_payment_id)

    receipt =
      create_verified_webhook_receipt!(payment_intent, provider_payment_id, webhook_event_id)

    StripeAPIStub.stub_unexpected!("webhook processing must not call Stripe")

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    provider_event = fetch_provider_event!(webhook_event_id)
    payment_attempt = fetch_webhook_payment_attempt!(payment_intent.id, webhook_event_id)
    processed_receipt = fetch_receipt!(receipt.id)

    assert provider_event.provider == :stripe
    assert provider_event.provider_event_id == webhook_event_id
    assert provider_event.event_type == "payment_intent.succeeded"
    assert is_binary(provider_event.payload_sha256)

    assert payment_attempt.provider_event_id == webhook_event_id
    assert payment_attempt.provider_reference == provider_payment_id
    assert payment_attempt.provider_transaction_id == provider_payment_id
    assert payment_attempt.observation_source == "webhook"
    assert payment_attempt.outcome == "authoritative_success"
    assert DateTime.compare(payment_attempt.provider_occurred_at, @provider_occurred_at) == :eq
    assert DateTime.compare(payment_attempt.observed_at, receipt.received_at) == :eq

    refute DateTime.compare(payment_attempt.provider_occurred_at, payment_attempt.observed_at) ==
             :eq

    assert processed_receipt.processing_status == "processed"
    assert processed_receipt.raw_body == receipt.raw_body
    assert processed_receipt.headers == receipt.headers

    purged_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, purged_receipt} =
             processed_receipt
             |> Ash.Changeset.for_update(
               :purge_evidence,
               %{raw_body: "[PURGED]", headers: %{}, evidence_purged_at: purged_at},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Payments,
               authorize?: false,
               context: %{system?: true}
             )

    assert purged_receipt.raw_body == "[PURGED]"
    assert purged_receipt.headers == %{}
    assert DateTime.compare(purged_receipt.evidence_purged_at, purged_at) == :eq
    assert purged_receipt.provider_event_id == webhook_event_id
    assert purged_receipt.payload_sha256 == receipt.payload_sha256

    persisted_provider_event = fetch_provider_event!(webhook_event_id)

    persisted_payment_attempt =
      fetch_webhook_payment_attempt!(payment_intent.id, webhook_event_id)

    assert persisted_provider_event.id == provider_event.id
    assert persisted_provider_event.payload_sha256 == provider_event.payload_sha256
    assert persisted_payment_attempt.id == payment_attempt.id

    retained_fields = [
      :provider_event_id,
      :provider_reference,
      :provider_transaction_id,
      :observation_source,
      :outcome,
      :amount_minor,
      :currency,
      :provider_environment,
      :payload_sha256
    ]

    assert Map.take(persisted_payment_attempt, retained_fields) ==
             Map.take(payment_attempt, retained_fields)

    assert DateTime.compare(
             persisted_payment_attempt.provider_occurred_at,
             payment_attempt.provider_occurred_at
           ) == :eq

    assert DateTime.compare(persisted_payment_attempt.observed_at, payment_attempt.observed_at) ==
             :eq

    assert DateTime.compare(persisted_payment_attempt.provider_occurred_at, @provider_occurred_at) ==
             :eq

    assert DateTime.compare(persisted_payment_attempt.observed_at, receipt.received_at) == :eq
    assert :paid == fetch_order!(order.id).state
    assert 1 == payment_application_count(order.id)
  end

  defp create_order! do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("jc257_payment_audit"))

    Order
    |> Ash.Changeset.for_create(:create, %{user_id: user.id})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: "USD",
        grand_total_minor: @amount_minor,
        items_subtotal_minor: @amount_minor,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp create_submitted_payment_intent!(order) do
    PaymentIntent
    |> Ash.Changeset.for_create(:create, %{
      order_id: order.id,
      amount_received_minor: @amount_minor,
      currency: "USD",
      provider: :stripe
    })
    |> Ash.create!(domain: Store.Payments, authorize?: false)
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp set_provider_payment_id!(payment_intent, provider_payment_id) do
    payment_intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{provider_payment_id: provider_payment_id},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp stripe_payment_intent(provider_payment_id, status, local_intent_id) do
    %{
      "amount" => @amount_minor,
      "amount_received" => @amount_minor,
      "currency" => "usd",
      "id" => provider_payment_id,
      "livemode" => false,
      "metadata" => %{"local_intent_id" => local_intent_id},
      "status" => status
    }
  end

  defp create_verified_webhook_receipt!(payment_intent, provider_payment_id, webhook_event_id) do
    received_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    raw_body =
      Jason.encode!(%{
        "id" => webhook_event_id,
        "created" => DateTime.to_unix(@provider_occurred_at),
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => provider_payment_id,
            "amount_received" => @amount_minor,
            "currency" => "usd",
            "livemode" => false,
            "metadata" => %{"local_intent_id" => payment_intent.id},
            "status" => "succeeded"
          }
        }
      })

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, %{
      provider: :stripe,
      provider_event_id: webhook_event_id,
      event_type: "payment_intent.succeeded",
      verification_status: "verified",
      processing_status: "new",
      raw_body: raw_body,
      headers: %{"content-type" => ["application/json"]},
      received_at: received_at
    })
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false)
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_receipt!(id) do
    WebhookReceipt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_provider_event!(event_id) do
    ProviderEvent
    |> Ash.Query.filter(expr(provider == :stripe and provider_event_id == ^event_id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_webhook_payment_attempt!(payment_intent_id, event_id) do
    PaymentAttempt
    |> Ash.Query.filter(
      expr(payment_intent_id == ^payment_intent_id and provider_event_id == ^event_id)
    )
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_attempts!(payment_intent_id) do
    PaymentAttempt
    |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp payment_application_count(order_id) do
    PaymentApplication
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  defp owned_receipt_count(payment_intent_id, provider_payment_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)
        FROM webhook_receipts
        WHERE position($1 in raw_body) > 0 OR position($2 in raw_body) > 0
        """,
        [payment_intent_id, provider_payment_id]
      )

    count
  end
end
