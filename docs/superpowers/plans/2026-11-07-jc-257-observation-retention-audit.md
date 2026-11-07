# JC-257 observation and retention audit implementation plan

> **For agentic workers:** Use subagent-driven-development or executing-plans. Steps use checkbox syntax. Keep the change to the single test module below.

**Goal:** Add focused characterization tests for a known Stripe PaymentIntent observed by GET without a webhook, and for webhook evidence that remains after one receipt's raw payload is purged.

**Architecture:** Exercise the existing `Store.Payments.Facade` observation path against `StripeAPIStub`, then call the explicit outcome-application facade twice. Exercise the existing verified-receipt worker with a persisted Stripe PaymentIntent, then invoke `WebhookReceipt`'s `:purge_evidence` action on that receipt alone. Do not add production code or infer behavior beyond the assertions in the tests.

**Tech stack:** Elixir, ExUnit, `Store.DataCase`, Ash resources and actions, Oban test support, `Req.Test` through `Store.TestSupport.StripeAPIStub`.

## Scope and source basis

Prerequisites JC228, JC229, JC230, JC282, and JC287 are accepted on `main`. This plan assumes implementation on the existing issue branch after the root agent confirms issue context.

Create only `test/store/payments/jc257_observation_retention_audit_test.exs`. Do not change production modules, provider rules, worker behavior, migrations, configuration, or other tests. The separate Task 1 worker covers the paid physical-order enqueue-fault proof. This file must not repeat that proof.

The source behavior to characterize is:

- `Store.Payments.Inputs.ObservePaymentIntentInput` contains only `payment_intent_id`.
- `Store.Payments.Facade.observe_payment_intent_for_system/1` reads the persisted provider identity, obtains one Stripe observation, records a `PaymentAttempt`, and returns eligibility without applying a commerce outcome.
- `Stripe.observe_payment/2` issues a GET to `/v1/payment_intents/:id`. A PaymentIntent response creates a `ProviderObservation` with `provider_occurred_at: nil` and a current `observed_at`.
- The explicit `Store.Payments.Facade.apply_observed_payment_outcome_for_system/1` accepts the returned observation result. Reapplying authoritative success is covered by existing idempotency tests and must leave exactly one order payment application.
- `ProcessWebhookReceiptWorker` accepts only a `WebhookReceipt` whose `verification_status` is `"verified"`. `Store.Payments.Interlocks` normalizes the payload, ingests a `ProviderEvent`, records a webhook `PaymentAttempt`, and associates `canonical.occurred_at` with `provider_occurred_at` and `receipt.received_at` with `observed_at`.
- `WebhookReceipt :purge_evidence` changes `raw_body`, `headers`, and `evidence_purged_at`. It does not delete or rewrite `ProviderEvent` or `PaymentAttempt`.

Use `Store.DataCase, async: false`. It owns shared sandboxes for `Store.Repo` and `Store.DirectRepo`; do not start another sandbox or use committed jobs. Use `Oban.Testing` only to call `perform_job/2` directly. `StripeAPIStub.setup_default/1` installs request verification. Custom observation stubs should assert the HTTP method and exact path, so a POST or an unexpected reference fails the test. No real Stripe HTTP call is part of this plan.

## Task 1: Add the characterization module

**File:** Create `test/store/payments/jc257_observation_retention_audit_test.exs`.

- [ ] Add the following complete test module. It contains the two requested joined proofs and all helpers used by those tests.

```elixir
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
    assert Enum.map(attempts, & &1.outcome) |> Enum.sort() == ["authoritative_success", "unresolved"]

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
    receipt = create_verified_webhook_receipt!(payment_intent, provider_payment_id, webhook_event_id)

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
    assert payment_attempt.observed_at == receipt.received_at
    refute DateTime.compare(payment_attempt.provider_occurred_at, payment_attempt.observed_at) == :eq

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
    assert purged_receipt.evidence_purged_at == purged_at
    assert purged_receipt.provider_event_id == webhook_event_id
    assert purged_receipt.payload_sha256 == receipt.payload_sha256

    persisted_provider_event = fetch_provider_event!(webhook_event_id)
    persisted_payment_attempt = fetch_webhook_payment_attempt!(payment_intent.id, webhook_event_id)

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
      :provider_occurred_at,
      :observed_at,
      :payload_sha256
    ]

    assert Map.take(persisted_payment_attempt, retained_fields) ==
             Map.take(payment_attempt, retained_fields)
    assert DateTime.compare(persisted_payment_attempt.provider_occurred_at, @provider_occurred_at) == :eq
    assert persisted_payment_attempt.observed_at == receipt.received_at
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
```

- [ ] Save the file with no production edits. The first test proves exactly two exact-reference GETs. Each callback asserts `conn.method == "GET"`; any POST or unexpected path fails. The test applies the unresolved result explicitly and verifies that it leaves payment pending. It then proves that the local PI/reference survives the second observation, that explicit success application plus replay creates one payment application, and that neither application makes another provider request.
- [ ] The first test's `owned_receipt_count/2` uses parameterized SQL to search raw receipt JSON for either this PaymentIntent UUID or its generated Stripe PI id. It scopes the count to those two owned identifiers, not to all receipts in the shared test database. Both identifiers are generated inside the test.
- [ ] The second test seeds a receipt with `verification_status: "verified"`, lets the existing worker process its actual JSON payload, confirms the distinct provider and local observation times, then calls the exact resource action on that one receipt. It checks the same provider-event and payment-attempt IDs and stored evidence after raw body and headers are scrubbed.
- [ ] Do not assert that an external Stripe signature was generated or checked in this test. This worker test starts at the already-verified receipt boundary, matching `ensure_receipt_verified/1`.
- [ ] Do not claim periodic scanning, process-crash recovery, or live-provider behavior. These tests characterize one explicit GET sequence and one worker invocation.
- [ ] Do not add an unknown-reference discard case. It is outside the two joined proofs and would exercise a separate webhook outcome.

## Task 2: Run the focused test and review the result

- [ ] Run the new module through the repository's DevCore test wrapper with the required dedicated environment:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/payments/jc257_observation_retention_audit_test.exs
```

Expected result: both tests pass. If actual code exposes a mismatch, inspect the failure and the cited implementation before changing assertions. Keep changes within this new module; do not change production behavior to satisfy a characterization test.

- [ ] Run formatter check for the new file using the same wrapper:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted test/store/payments/jc257_observation_retention_audit_test.exs
```

Expected result: the command exits successfully with no formatting changes required. If it reports formatting differences, format only the new file with the same wrapper, then rerun both commands.

## Review limits

These tests characterize current behavior. They do not certify webhook signature verification, background scanner scheduling, a process crash between database operations, provider behavior outside `Req.Test`, or live Stripe behavior. The order fixture has finalized totals but no checkout lines, so it does not prove full checkout behavior or subscription renewal behavior. The tests do not cover the Task 1 paid physical-order enqueue-fault proof. They use direct `perform_job/2` and the shared `Store.DataCase` sandboxes without committing Oban jobs or changing database configuration.

Root self-review corrected unresolved eligibility against ProviderObservation.validate_outcome/1, used chronological DateTime comparison across database precision, supervised the request counter, checked parameterized receipt ownership, and expanded retained-field equality after purge. Both tests remain explicit bounded audit calls, not automatic recovery or crash certification.
