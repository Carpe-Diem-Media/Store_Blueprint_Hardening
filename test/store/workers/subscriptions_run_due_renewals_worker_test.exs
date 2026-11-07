defmodule Store.Workers.SubscriptionsRunDueRenewalsWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Digital.{DigitalAsset, DownloadGrant, ProductDigitalLink}
  alias Store.Digital.Workers.IssueGrantsForPaidOrderWorker
  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent

  alias Store.Subscriptions.{
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Scheduler,
    Subscription
  }

  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker
  alias Store.Workers.ProcessWebhookReceiptWorker
  alias Store.Workers.ReconcilePaidSubscriptionRenewalWorker
  alias Store.Workers.RunDueSubscriptionRenewalsWorker

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "paid renewal exposes exact collection identity without applying the renewal" do
    customer = SubscriptionsFixtures.create_customer!("phase26_worker_due")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    digital_asset = create_digital_asset!()
    create_variant_digital_link!(variant.id, digital_asset.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_worker",
        next_renewal_at: DateTime.add(now, -30, :second)
      })

    previous_period_end = subscription.current_period_end_at

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 50})
    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 50})

    assert_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => subscription.id}
    )

    jobs = all_enqueued(worker: ProcessSubscriptionRenewalWorker)

    assert length(jobs) == 1

    scheduled_job = List.first(jobs)

    assert is_binary(scheduled_job.args["renewal_key"])
    assert DateTime.compare(scheduled_job.scheduled_at, scheduled_job.inserted_at) in [:eq, :gt]

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, DateTime.utc_now())

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "processing")
    )

    assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
             perform_job(ProcessSubscriptionRenewalWorker, scheduled_job.args)

    attempt = reached.attempt
    assert attempt.status == :processing
    assert is_binary(attempt.order_id)
    assert is_binary(attempt.payment_intent_id)

    renewal_order = fetch_order!(attempt.order_id)
    assert renewal_order.state == :pending_payment

    renewal_payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    assert renewal_payment_intent.state == :submitted
    assert is_binary(renewal_payment_intent.provider_payment_id)

    refute_enqueued(
      worker: IssueGrantsForPaidOrderWorker,
      args: %{"order_id" => renewal_order.id}
    )

    assert [] ==
             DownloadGrant
             |> Ash.Query.filter(expr(order_id == ^renewal_order.id))
             |> Ash.read!(domain: Store.Digital, authorize?: false, context: %{system?: true})

    receipt = create_success_webhook_receipt!(reached)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    collection =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt.id))
      |> Ash.read_one!(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    assert fetch_payment_intent!(renewal_payment_intent.id).state == :succeeded
    assert collection.financial_outcome == :verified_success
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert handoff == %{
             order_id: renewal_order.id,
             renewal_attempt_id: attempt.id,
             collection_attempt_id: collection.id,
             payment_intent_id: renewal_payment_intent.id
           }

    refute_enqueued(worker: ReconcilePaidSubscriptionRenewalWorker)

    unchanged = fetch_subscription!(subscription.id)
    assert unchanged.current_period_end_at == previous_period_end
    assert unchanged.status == :active
    assert fetch_latest_attempt!(subscription.id).status == :processing
  end

  test "tick worker enqueues deterministic jitter within the expected window for multiple subscriptions" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    subscriptions =
      for suffix <- ~w(alpha beta gamma) do
        customer = SubscriptionsFixtures.create_customer!("phase27_worker_jitter_#{suffix}")

        %{subscription: subscription} =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            provider_billing_ref: "pm_phase27_worker_jitter_#{suffix}",
            next_renewal_at: DateTime.add(now, -30, :second)
          })

        subscription
      end

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 50})

    first_jobs =
      all_enqueued(worker: ProcessSubscriptionRenewalWorker)
      |> Enum.sort_by(& &1.args["subscription_id"])

    assert length(first_jobs) == 3

    first_schedule_deltas =
      first_jobs
      |> Enum.map(fn job ->
        subscription_id = job.args["subscription_id"]
        delta = DateTime.diff(job.scheduled_at, job.inserted_at, :second)
        expected_delta = Scheduler.renewal_jitter_seconds(subscription_id)

        assert job.queue == "subscriptions"
        assert is_binary(job.args["renewal_key"])
        assert delta >= 0
        assert delta <= 3_600
        assert abs(delta - expected_delta) <= 1

        {subscription_id, delta}
      end)
      |> Map.new()

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 50})

    second_jobs =
      all_enqueued(worker: ProcessSubscriptionRenewalWorker)
      |> Enum.sort_by(& &1.args["subscription_id"])

    assert length(second_jobs) == 3

    second_schedule_deltas =
      second_jobs
      |> Enum.map(fn job ->
        {job.args["subscription_id"], DateTime.diff(job.scheduled_at, job.inserted_at, :second)}
      end)
      |> Map.new()

    assert MapSet.new(Map.keys(first_schedule_deltas)) ==
             MapSet.new(Enum.map(subscriptions, & &1.id))

    assert second_schedule_deltas == first_schedule_deltas
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_order!(id) do
    Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp create_success_webhook_receipt!(reached) do
    alias Store.Payments.WebhookReceipt

    raw_body =
      Jason.encode!(%{
        "id" => "evt_renewal_#{reached.payment_intent.id}",
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => ReachedRenewalFixtures.observation_body(reached, "succeeded")
        }
      })

    WebhookReceipt
    |> Ash.Changeset.for_create(
      :ingest,
      %{
        provider: "stripe",
        provider_event_id: "evt_renewal_#{reached.payment_intent.id}",
        event_type: "payment_intent.succeeded",
        verification_status: "verified",
        processing_status: "new",
        raw_body: raw_body,
        headers: %{"content-type" => ["application/json"]}
      }
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp create_digital_asset! do
    DigitalAsset
    |> Ash.Changeset.for_create(:create, %{
      key: "jc229-worker-asset-#{System.unique_integer([:positive])}",
      title: "JC-229 worker asset",
      content_type: "application/pdf",
      byte_size: 1024,
      storage_provider: "s3",
      storage_bucket: "downloads-bucket",
      storage_object_key: "assets/jc229-worker.pdf",
      status: :active
    })
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp create_variant_digital_link!(variant_id, asset_id) do
    ProductDigitalLink
    |> Ash.Changeset.for_create(
      :create,
      %{variant_id: variant_id, digital_asset_id: asset_id, position: 0},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end
end
