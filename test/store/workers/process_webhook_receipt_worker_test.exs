defmodule Store.Workers.ProcessWebhookReceiptWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Ecto.Adapters.SQL.Sandbox

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.InventoryItem
  alias Store.Comms.EmailOutbox
  alias Store.Orders.InventoryReservation
  alias Store.Orders.{Order, PaymentApplication}

  alias Store.Payments.{
    ObservationEvidence,
    PaymentAttempt,
    PaymentIntent,
    Providers,
    WebhookReceipt
  }

  alias Store.Payments.Types.ProviderObservation
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.Subscriptions.{StoredPaymentMethod, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.{ProcessSubscriptionRenewalWorker, ProcessWebhookReceiptWorker}

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "worker performs apply-once payment success transition and order effects" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_payment_success_001",
        "created" => 1_700_000_000,
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "livemode" => false,
            "metadata" => %{},
            "status" => "succeeded"
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_payment_success_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state

    late_failure =
      create_payment_receipt!(
        "evt_worker_payment_late_failure_001",
        "payment_intent.payment_failed",
        payment_intent,
        "requires_payment_method"
      )

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => late_failure.id})

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert {:ok, payment_attempts} =
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_attempt =
      Enum.find(payment_attempts, &(&1.provider_event_id == receipt.provider_event_id))

    assert payment_attempt.provider_event_id == "evt_worker_payment_success_001"
    assert payment_attempt.provider_reference == payment_intent.id
    assert payment_attempt.observation_source == "webhook"
    assert payment_attempt.outcome == "authoritative_success"
    assert DateTime.to_unix(payment_attempt.provider_occurred_at) == 1_700_000_000
    assert %DateTime{} = payment_attempt.observed_at
    refute payment_attempt.provider_occurred_at == payment_attempt.observed_at

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert 2 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  test "the same verify observation is idempotent and later success remains durable after failure" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_observation_replay"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    failure = provider_observation(:failure_observation, "requires_payment_method")
    success = provider_observation(:authoritative_success, "succeeded")

    assert {:ok, _} = ObservationEvidence.record(payment_intent, failure)
    assert {:ok, _} = ObservationEvidence.record(payment_intent, failure)
    assert {:ok, _} = ObservationEvidence.record(payment_intent, success)

    assert {:ok, _} =
             ObservationEvidence.record(payment_intent, %{
               failure
               | observation_source: :reconciliation
             })

    assert {:ok, _} = ObservationEvidence.record(payment_intent, failure)

    assert {:ok, attempts} =
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.Query.sort(observed_at: :asc)
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert Enum.map(attempts, &{&1.observation_source, &1.outcome}) |> Enum.sort() ==
             Enum.sort([
               {"verification", "failure_observation"},
               {"verification", "authoritative_success"},
               {"reconciliation", "failure_observation"}
             ])

    assert Enum.map(attempts, & &1.provider_reference) == [
             "pi_observation_replay",
             "pi_observation_replay",
             "pi_observation_replay"
           ]

    reverse_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_observation_reverse"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    reverse_success = %{
      success
      | provider_reference: "pi_observation_reverse",
        provider_transaction_id: "pi_observation_reverse"
    }

    reverse_failure = %{
      failure
      | provider_reference: "pi_observation_reverse",
        provider_transaction_id: "pi_observation_reverse"
    }

    assert {:ok, _} = ObservationEvidence.record(reverse_intent, reverse_success)
    assert {:ok, _} = ObservationEvidence.record(reverse_intent, reverse_failure)

    assert 2 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^reverse_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "observation replay identity excludes local receipt time but preserves source and provider changes" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2_500,
        currency: "USD",
        provider_payment_id: "pi_receipt_time_identity"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    first_seen_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    replay_seen_at = DateTime.add(first_seen_at, 5, :second)

    first = %{
      provider_observation(:failure_observation, "requires_payment_method")
      | observed_at: first_seen_at
    }

    replay = %{first | observed_at: replay_seen_at}

    assert {:ok, first_evidence} = ObservationEvidence.record(payment_intent, first)
    assert {:ok, replay_evidence} = ObservationEvidence.record(payment_intent, replay)
    assert first_evidence.id == replay_evidence.id

    assert 1 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)

    other_source = %{replay | observation_source: :reconciliation}
    assert {:ok, _source_evidence} = ObservationEvidence.record(payment_intent, other_source)

    assert 2 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)

    changed_provider_state = %{
      other_source
      | observation_source: :verification,
        normalized_outcome: :authoritative_success,
        raw_provider_status: "succeeded"
    }

    assert {:ok, _changed_state_evidence} =
             ObservationEvidence.record(payment_intent, changed_provider_state)

    assert 3 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "observation stays read-only until explicit outcome application corrects failed intent" do
    order = create_order!()

    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_failed_then_paid"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)
      |> then(fn intent ->
        intent
        |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
        |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      end)
      |> then(fn intent ->
        intent
        |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
        |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      end)

    StripeAPIStub.stub_payment_observation("pi_failed_then_paid", %{
      "amount" => 2500,
      "amount_received" => 2500,
      "currency" => "usd",
      "id" => "pi_failed_then_paid",
      "livemode" => false,
      "metadata" => %{"local_intent_id" => payment_intent.id},
      "status" => "succeeded"
    })

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, observed} = Store.Payments.Facade.observe_payment_intent_for_system(input)
    assert observed.eligibility == :eligible
    assert :failed == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state

    assert {:ok, %{outcome: :authoritative_success}} =
             Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  defp provider_observation(outcome, status) do
    %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_observation_replay",
      provider_reference_kind: :payment_intent,
      provider_transaction_id: "pi_observation_replay",
      observation_source: :verification,
      normalized_outcome: outcome,
      raw_provider_status: status,
      amount_minor: 2500,
      currency: "USD",
      observed_at: DateTime.utc_now(),
      evidence_sha256: :crypto.hash(:sha256, status) |> Base.encode16(case: :lower)
    }
  end

  test "provider reconciliation stores evidence without applying commerce effects" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_reconcile_read"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    StripeAPIStub.stub_payment_observation("pi_reconcile_read", %{
      "amount" => 2500,
      "amount_received" => 2500,
      "currency" => "usd",
      "id" => "pi_reconcile_read",
      "metadata" => %{"local_intent_id" => payment_intent.id},
      "status" => "succeeded"
    })

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, result} = Store.Payments.Facade.observe_payment_intent_for_system(input)
    assert {:ok, "test"} = Providers.expected_environment(:stripe)
    assert result.eligibility == :eligible
    assert result.evidence.provider_event_id == nil
    assert result.evidence.provider_reference == "pi_reconcile_read"
    assert fetch_payment_intent!(payment_intent.id).state == :created
    assert result.observation.observation_source == :verification
  end

  test "session-only intent recovers through Checkout Session and discovered PaymentIntent" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_session_id: "cs_session_only"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/checkout/sessions/cs_session_only"

      StripeAPIStub.json_response(conn, %{
        "amount_total" => 2500,
        "currency" => "usd",
        "id" => "cs_session_only",
        "livemode" => false,
        "payment_intent" => nil,
        "payment_status" => "unpaid",
        "status" => "open"
      })
    end)

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, pending} =
             Store.Payments.Facade.observe_payment_intent_for_system(input)

    assert pending.observation.provider_reference == "cs_session_only"
    assert pending.observation.provider_transaction_id == nil
    assert pending.observation.normalized_outcome == :unresolved
    assert pending.evidence.provider_reference_kind == "checkout_session"

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v1/checkout/sessions/cs_session_only" ->
          StripeAPIStub.json_response(conn, %{
            "amount_total" => 2500,
            "currency" => "usd",
            "id" => "cs_session_only",
            "livemode" => false,
            "payment_intent" => "pi_from_session",
            "payment_status" => "paid",
            "status" => "complete"
          })

        "/v1/payment_intents/pi_from_session" ->
          StripeAPIStub.json_response(conn, %{
            "amount" => 2500,
            "amount_received" => 2500,
            "currency" => "usd",
            "id" => "pi_from_session",
            "status" => "succeeded"
          })

        other ->
          flunk("unexpected Stripe observation path: #{other}")
      end
    end)

    assert {:ok, recovered} =
             Store.Payments.Facade.observe_payment_intent_for_system(input)

    assert recovered.eligibility == :eligible
    assert recovered.observation.provider_reference == "cs_session_only"
    assert recovered.observation.provider_reference_kind == :checkout_session
    assert recovered.observation.provider_transaction_id == "pi_from_session"
    assert recovered.evidence.provider_reference_kind == "checkout_session"
    assert recovered.evidence.provider_environment == "test"

    assert {:ok, attempts} =
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert Enum.map(attempts, & &1.outcome) |> Enum.sort() ==
             ["authoritative_success", "unresolved"]
  end

  test "SetupIntent PaymentIntent purpose fails observation without a PaymentIntent GET" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        purpose: :subscription_payment_method_update,
        amount_received_minor: 0,
        currency: "USD",
        provider_payment_id: "seti_method_update"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    StripeAPIStub.stub_unexpected!("SetupIntent must not use PaymentIntent retrieval")

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:error, error} =
             Store.Payments.Facade.observe_payment_intent_for_system(input)

    assert error.code == "PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED"
  end

  test "a mismatched provider response remains durable and fails eligibility" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_reconcile_mismatch"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    StripeAPIStub.stub_payment_observation("pi_reconcile_mismatch", %{
      "amount" => 2500,
      "amount_received" => 2499,
      "currency" => "usd",
      "id" => "pi_reconcile_mismatch",
      "status" => "succeeded"
    })

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, result} = Store.Payments.Facade.observe_payment_intent_for_system(input)
    assert result.eligibility == {:error, :amount_mismatch}
    assert result.evidence.amount_minor == 2499
    assert result.evidence.outcome == "authoritative_success"
    assert fetch_payment_intent!(payment_intent.id).state == :created
  end

  test "concurrent duplicate observations produce one durable row", context do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_concurrent_observation"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    observation = %{
      provider_observation(:authoritative_success, "succeeded")
      | provider_reference: "pi_concurrent_observation",
        provider_transaction_id: "pi_concurrent_observation"
    }

    sandbox_owner = context.sandbox_owners[Store.Repo]

    assert 4 ==
             1..4
             |> Task.async_stream(
               fn _ ->
                 :ok = Sandbox.allow(Store.Repo, sandbox_owner, self())
                 ObservationEvidence.record(payment_intent, observation)
               end,
               max_concurrency: 4,
               timeout: 10_000
             )
             |> Enum.count(fn
               {:ok, {:ok, _attempt}} -> true
               _ -> false
             end)

    assert 1 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "worker falls back to metadata local_intent_id when provider payment id is not yet persisted" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_payment_success_metadata_001",
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => "pi_provider_late_001",
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "customer" => "cus_meta_001",
            "payment_method" => "pm_meta_001",
            "metadata" => %{"local_intent_id" => payment_intent.id}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_payment_success_metadata_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    updated_payment_intent = fetch_payment_intent!(payment_intent.id)
    assert updated_payment_intent.state == :succeeded
    assert updated_payment_intent.provider_payment_id == "pi_provider_late_001"
    assert updated_payment_intent.provider_customer_ref == "cus_meta_001"
    assert updated_payment_intent.provider_payment_method_ref == "pm_meta_001"
    assert fetch_order!(order.id).state == :paid
  end

  test "worker records disabled-provider failure without applying transitions" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_provider_disabled_001",
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "livemode" => false,
            "metadata" => %{}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: :stripe,
          provider_event_id: "evt_worker_provider_disabled_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DISABLED"}} =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    updated_receipt = fetch_receipt!(receipt.id)
    assert updated_receipt.processing_status == "failed"
    assert updated_receipt.error_code == "PAYMENT_PROVIDER_DISABLED"

    assert :submitted == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state
  end

  test "worker processes setup_intent success, updates stored method, and retries past-due subscriptions immediately" do
    customer = SubscriptionsFixtures.create_customer!("phase27_setup_webhook")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_setup_retry_001",
        provider_billing_ref: nil,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             Store.Subscriptions.Facade.run_due_renewals_for_system(now: now, limit: 20)

    past_due_subscription = fetch_subscription!(subscription.id)
    assert past_due_subscription.status == :past_due
    assert past_due_subscription.dunning_attempt_count == 1

    assert {:ok, setup_result} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               customer,
               past_due_subscription.id,
               %StartSubscriptionPaymentMethodUpdateInput{
                 subscription_id: past_due_subscription.id
               }
             )

    payment_intent = fetch_payment_intent!(setup_result.payment_intent_id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_setup_intent_success_001",
        "livemode" => false,
        "type" => "setup_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id,
            "currency" => "usd",
            "customer" => "cus_setup_retry_001",
            "payment_method" => "pm_setup_retry_001",
            "metadata" => %{
              "local_intent_id" => payment_intent.id,
              "subscription_id" => past_due_subscription.id,
              "currency" => "USD"
            }
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_setup_intent_success_001",
          event_type: "setup_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    updated_intent = fetch_payment_intent!(payment_intent.id)
    assert updated_intent.state == :succeeded
    assert updated_intent.provider_payment_id == payment_intent.provider_payment_id
    assert updated_intent.provider_payment_method_ref == "pm_setup_retry_001"

    updated_subscription = fetch_subscription!(past_due_subscription.id)
    assert updated_subscription.provider_billing_ref == "pm_setup_retry_001"
    assert updated_subscription.provider_customer_ref == "cus_setup_retry_001"
    assert is_binary(updated_subscription.stored_payment_method_id)
    assert updated_subscription.billing_status_reason == nil
    assert DateTime.compare(updated_subscription.next_retry_at, DateTime.utc_now()) in [:lt, :eq]

    retry_args = %{"subscription_id" => past_due_subscription.id}

    retry_jobs = fn ->
      all_enqueued(worker: ProcessSubscriptionRenewalWorker)
      |> Enum.filter(&(&1.args["subscription_id"] == past_due_subscription.id))
    end

    assert [retry_job] = retry_jobs.()
    applied_version = updated_subscription.aggregate_version
    binding = updated_subscription.provider_billing_ref

    assert 1 ==
             Store.DirectRepo.query!("DELETE FROM oban_jobs WHERE id = $1", [retry_job.id]).num_rows

    assert retry_jobs.() == []

    assert :ok =
             SubscriptionsFacade.handle_payment_method_update_succeeded_for_system(
               payment_intent.id
             )

    assert fetch_subscription!(past_due_subscription.id).aggregate_version == applied_version
    assert fetch_subscription!(past_due_subscription.id).provider_billing_ref == binding
    assert [replacement_retry_job] = retry_jobs.()
    refute replacement_retry_job.id == retry_job.id

    assert {:ok, _newer_setup} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               customer,
               past_due_subscription.id,
               %StartSubscriptionPaymentMethodUpdateInput{
                 subscription_id: past_due_subscription.id
               }
             )

    after_new_start = fetch_subscription!(past_due_subscription.id).aggregate_version

    assert 1 ==
             Store.DirectRepo.query!("DELETE FROM oban_jobs WHERE id = $1", [
               replacement_retry_job.id
             ]).num_rows

    assert retry_jobs.() == []

    assert :ok =
             SubscriptionsFacade.handle_payment_method_update_succeeded_for_system(
               payment_intent.id
             )

    assert fetch_subscription!(past_due_subscription.id).aggregate_version == after_new_start
    assert retry_jobs.() == []

    refute_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: retry_args
    )

    assert 1 ==
             StoredPaymentMethod
             |> Ash.Query.filter(
               expr(
                 user_id == ^customer.id and provider_customer_ref == ^"cus_setup_retry_001" and
                   provider_payment_method_ref == ^"pm_setup_retry_001"
               )
             )
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  test "worker consumes physical renewal inventory exactly once on recurring payment success" do
    customer = SubscriptionsFixtures.create_customer!("phase27_webhook_consume")

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
        provider_billing_ref: "pm_phase27_webhook_consume",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    configure_shipping_profile!(source_order, variant)

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    payment_intent = reached.payment_intent

    reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert reservation.state == :active

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    assert {:ok, observed} =
             Store.Payments.Facade.observe_payment_intent_for_system(
               %Store.Payments.Inputs.ObservePaymentIntentInput{
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:ok, %{outcome: :authoritative_success}} =
             Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

    assert fetch_reservation!(attempt.order_id, variant.id).state == :consumed
    assert Repo.get_by!(InventoryItem, variant_id: variant.id).stock_on_hand == 0

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_renewal_succeeded_001",
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id,
            "amount" => reached.order.grand_total_minor,
            "amount_received" => reached.order.grand_total_minor,
            "currency" => String.downcase(reached.order.currency_code),
            "livemode" => false,
            "metadata" =>
              ReachedRenewalFixtures.observation_body(reached, "succeeded")["metadata"],
            "customer" => payment_intent.provider_customer_ref,
            "payment_method" => payment_intent.provider_payment_method_ref,
            "status" => "succeeded"
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_renewal_succeeded_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok = perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
    assert fetch_order!(attempt.order_id).state == :paid

    consumed = fetch_reservation!(attempt.order_id, variant.id)
    assert consumed.id == reservation.id
    assert consumed.state == :consumed

    inventory_after_success = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory_after_success.reserved_count == 0
    assert inventory_after_success.stock_on_hand == 0

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^attempt.order_id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert :ok = perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    replayed = fetch_reservation!(attempt.order_id, variant.id)
    assert replayed.id == reservation.id
    assert replayed.state == :consumed

    inventory_after_replay = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory_after_replay.reserved_count == 0
    assert inventory_after_replay.stock_on_hand == 0

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^attempt.order_id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  test "zero-received failure webhook is rejected and retains renewal inventory until success" do
    customer = SubscriptionsFixtures.create_customer!("phase27_webhook_release")

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
        provider_billing_ref: "pm_phase27_webhook_release",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    configure_shipping_profile!(source_order, variant)

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    payment_intent = reached.payment_intent

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_renewal_failed_001",
        "livemode" => false,
        "type" => "payment_intent.payment_failed",
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id,
            "amount" => reached.order.grand_total_minor,
            "amount_received" => 0,
            "currency" => String.downcase(reached.order.currency_code),
            "livemode" => false,
            "status" => "requires_payment_method",
            "metadata" =>
              ReachedRenewalFixtures.observation_body(reached, "requires_payment_method")[
                "metadata"
              ],
            "customer" => payment_intent.provider_customer_ref,
            "payment_method" => payment_intent.provider_payment_method_ref
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_renewal_failed_001",
          event_type: "payment_intent.payment_failed",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    # The existing receipt validator compares received amount with the full Order
    # total even for a nonterminal failure. Keep the truthful zero-received event.
    assert {:error,
            %{
              code: "PAYMENT_EVENT_UNVERIFIED",
              message: "receipt amount mismatch for finalized order totals"
            }} =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert reservation.state == :active
    assert fetch_payment_intent!(payment_intent.id).state == :submitted

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1

    success_receipt =
      create_reached_payment_receipt!(reached, "evt_worker_renewal_success_001", "succeeded")

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{
               "webhook_receipt_id" => success_receipt.id
             })

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(attempt.order_id).state

    consumed_reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert consumed_reservation.id == reservation.id
    assert consumed_reservation.state == :consumed

    inventory_after_success = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory_after_success.reserved_count == 0
    assert inventory_after_success.stock_on_hand == 0

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^attempt.order_id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  test "nonterminal exact-ID recovery retains payment and renewal reservation authority" do
    customer = SubscriptionsFixtures.create_customer!("phase27_direct_retryable_failure")

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
        provider_billing_ref: "pm_phase27_direct_retryable_failure",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    configure_shipping_profile!(source_order, variant)

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    payment_intent = reached.payment_intent
    reservation = fetch_reservation!(attempt.order_id, variant.id)
    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)

    assert attempt.status == :processing
    assert payment_intent.state == :submitted
    assert reservation.state == :active
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1

    StripeAPIStub.stub_payment_observation(
      payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "requires_payment_method")
    )

    assert {:ok, observed} =
             Store.Payments.Facade.observe_payment_intent_for_system(
               %Store.Payments.Inputs.ObservePaymentIntentInput{
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:ok, %{outcome: :unresolved}} =
             Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

    assert {:ok, [payment_attempt]} =
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert payment_attempt.observation_source == "verification"
    assert payment_attempt.outcome == "unresolved"
    assert payment_attempt.raw_provider_status == "requires_payment_method"
    assert fetch_payment_intent!(payment_intent.id).state == :submitted
    assert fetch_reservation!(attempt.order_id, variant.id).state == :active
    assert Repo.get_by!(InventoryItem, variant_id: variant.id).reserved_count == 1
    assert Repo.get_by!(InventoryItem, variant_id: variant.id).stock_on_hand == 1
  end

  defp create_payment_receipt!(event_id, event_type, payment_intent, provider_status) do
    raw_body =
      Jason.encode!(%{
        "id" => event_id,
        "created" => 1_700_000_000,
        "livemode" => false,
        "type" => event_type,
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id || payment_intent.id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "livemode" => false,
            "metadata" => %{"local_intent_id" => payment_intent.id},
            "status" => provider_status
          }
        }
      })

    WebhookReceipt
    |> Ash.Changeset.for_create(
      :ingest,
      %{
        provider: "stripe",
        provider_event_id: event_id,
        event_type: event_type,
        verification_status: "verified",
        processing_status: "new",
        raw_body: raw_body,
        headers: %{"content-type" => ["application/json"]}
      }
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp create_reached_payment_receipt!(reached, event_id, provider_status) do
    body = ReachedRenewalFixtures.observation_body(reached, provider_status)

    raw_body =
      Jason.encode!(%{
        "id" => event_id,
        "created" => 1_700_000_000,
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{"object" => body}
      })

    WebhookReceipt
    |> Ash.Changeset.for_create(
      :ingest,
      %{
        provider: "stripe",
        provider_event_id: event_id,
        event_type: "payment_intent.succeeded",
        verification_status: "verified",
        processing_status: "new",
        raw_body: raw_body,
        headers: %{"content-type" => ["application/json"]}
      }
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp create_submitted_payment_intent!(order_id) do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{order_id: order_id, provider: :stripe})
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    payment_intent
    |> Ash.Changeset.for_update(:submit, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end

  defp create_order! do
    user =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_worker_receipt_user"))

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: "USD",
        grand_total_minor: 0,
        items_subtotal_minor: 0,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp fetch_receipt!(id) do
    assert {:ok, [receipt]} =
             WebhookReceipt
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    receipt
  end

  defp fetch_subscription!(id) do
    assert {:ok, [subscription]} =
             Subscription
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    subscription
  end

  defp fetch_reservation!(order_id, variant_id) do
    assert {:ok, [reservation | _]} =
             InventoryReservation
             |> Ash.Query.filter(expr(order_id == ^order_id and variant_id == ^variant_id))
             |> Ash.read(domain: Store.Orders, authorize?: false, context: %{system?: true})

    reservation
  end

  defp configure_shipping_profile!(%Order{} = order, variant) do
    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "WH-ZONE-#{System.unique_integer([:positive])}",
          country_code: "US",
          region_code: "CA",
          active: true
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: "GROUND", name: "Ground", active: true, sort_order: 100},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax_rate =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "WH-TAX-#{System.unique_integer([:positive])}",
          country_code: "US",
          region_code: "CA",
          product_tax_category: "STANDARD",
          rate_basis_points: 0,
          shipping_taxable: true,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})

    _rule =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "WH-RULE-#{System.unique_integer([:positive])}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: "USD",
          shipping_cost_minor: 400,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    {:ok, request} =
      QuoteRequest.new(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: max(variant.weight_grams || 0, 0)
      })

    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

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
    |> then(fn addressed ->
      addressed
      |> Ash.Changeset.for_update(
        :set_shipping_method,
        %{shipping_rate_code: option.shipping_method_code},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    end)
    |> Ash.Changeset.for_update(
      :set_shipping_quote_evidence,
      %{
        shipping_quote_hash: option.quote_hash,
        shipping_quote_currency_code: option.currency_code,
        shipping_quote_amount_minor: option.amount_minor,
        shipping_weight_grams: option.shipping_weight_grams,
        shipping_method_code: option.shipping_method_code,
        shipping_rule_id: option.shipping_rule_id,
        shipping_zone_id: option.zone_id
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp set_variant_weight!(variant, weight_grams) do
    variant
    |> Ash.Changeset.for_update(
      :update,
      %{weight_grams: weight_grams},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end
end
