defmodule Store.Subscriptions.RenewalAttemptMonotonicityTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Types.ProviderObservation
  alias Store.Subscriptions.{Facade, RenewalAttempt, RenewalCollectionAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  defp create_pending_attempt!(subscription, overrides \\ %{}) do
    renewal_key =
      Map.get(
        overrides,
        :renewal_key,
        "sbh-70-02:#{subscription.id}:#{System.unique_integer([:positive])}"
      )

    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: subscription.id,
        period_start_at: subscription.current_period_start_at,
        period_end_at: subscription.current_period_end_at,
        renewal_key: renewal_key,
        status: :pending
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_processing_attempt!(subscription, overrides \\ %{}) do
    pending = create_pending_attempt!(subscription, overrides)

    pending
    |> Ash.Changeset.for_update(:mark_processing, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp due_processing_attempt!(subscription, now) do
    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_attempt!(attempt_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_succeeded!(attempt, order_id, payment_intent_id) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_succeeded,
      %{order_id: order_id, payment_intent_id: payment_intent_id},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_failed!(attempt, attrs) do
    attempt
    |> Ash.Changeset.for_update(:mark_failed, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_processing!(attempt, order_id, payment_intent_id) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_processing,
      %{order_id: order_id, payment_intent_id: payment_intent_id},
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp stale_record_error?({:error, %Ash.Error.Invalid{errors: errors}}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record_error?(_), do: false

  test "succeeded blocks late failed write and preserves failure evidence" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_late_failed")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_late_failed",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    attempt = due_processing_attempt!(subscription, now)
    order_id = attempt.order_id
    payment_intent_id = attempt.payment_intent_id
    succeeded = mark_succeeded!(attempt, order_id, payment_intent_id)

    stale_attempt = %{
      attempt
      | status: :processing,
        failure_code: nil,
        failure_message: nil,
        attempt_no: 1
    }

    assert stale_record_error?(
             mark_failed!(stale_attempt, %{
               failure_code: "PAYMENT_FAILED",
               failure_message: "late stale failure",
               attempt_no: 99
             })
           )

    reloaded = reload_attempt!(succeeded.id)
    assert reloaded.status == :succeeded
    assert reloaded.failure_code == nil
    assert reloaded.failure_message == nil
    assert reloaded.attempt_no == 1
    assert reloaded.order_id == order_id
    assert reloaded.payment_intent_id == payment_intent_id
  end

  test "succeeded blocks late processing write and preserves successful linkage" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_late_processing")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_late_processing",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    attempt = due_processing_attempt!(subscription, now)
    order_id = attempt.order_id
    payment_intent_id = attempt.payment_intent_id
    succeeded = mark_succeeded!(attempt, order_id, payment_intent_id)
    stale_attempt = %{attempt | status: :processing}

    assert stale_record_error?(mark_processing!(stale_attempt, order_id, payment_intent_id))

    reloaded = reload_attempt!(succeeded.id)
    assert reloaded.status == :succeeded
    assert reloaded.order_id == order_id
    assert reloaded.payment_intent_id == payment_intent_id
  end

  test "duplicate success reconciliation is replay-safe" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_dup_success")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_dup_success"
      })

    attempt = create_processing_attempt!(subscription)

    first = mark_succeeded!(attempt, nil, nil)
    second = mark_succeeded!(first, nil, nil)

    assert second.status == :succeeded
    assert second.failure_code == nil
    assert second.failure_code == nil
    assert second.failure_message == nil
  end

  test "processing to failed remains legal" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_proc_failed")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_proc_failed"
      })

    attempt = create_processing_attempt!(subscription)

    assert {:ok, failed} =
             mark_failed!(attempt, %{
               failure_code: "PAYMENT_FAILED",
               failure_message: "declined",
               attempt_no: 2
             })

    assert failed.status == :failed
    assert failed.failure_code == "PAYMENT_FAILED"
    assert failed.attempt_no == 2
  end

  test "failed to processing reclaim remains legal" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_failed_proc")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_failed_proc"
      })

    attempt =
      create_processing_attempt!(subscription)
      |> then(fn attempt ->
        {:ok, failed} =
          mark_failed!(attempt, %{
            failure_code: "PAYMENT_FAILED",
            failure_message: "declined",
            attempt_no: 2
          })

        failed
      end)

    assert {:ok, processing} =
             attempt
             |> Ash.Changeset.for_update(:mark_processing, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert processing.status == :processing
  end

  test "succeeded attempts are not reclaimable by initial CAS claim" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_claim_guard")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_claim_guard",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    attempt = due_processing_attempt!(subscription, now)
    order_id = attempt.order_id
    payment_intent_id = attempt.payment_intent_id
    succeeded = mark_succeeded!(attempt, order_id, payment_intent_id)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    reloaded = reload_attempt!(succeeded.id)
    assert reloaded.status == :succeeded
    assert reloaded.order_id == order_id
  end

  test "authoritative success wins a concurrent stale failure without past-due dunning" do
    customer = SubscriptionsFixtures.create_customer!("sbh_70_02_dunning_guard")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_sbh_70_02_dunning_guard",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    {:ok, barrier} = Agent.start_link(fn -> %{release_dispatch?: false} end)
    parent = self()
    handler_id = {__MODULE__, :dispatch_release, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_released],
        fn _event, _measurements, metadata, config ->
          await_stale_failure_dispatch(metadata, config)
        end,
        %{parent: parent, subscription_id: subscription.id, barrier: barrier}
      )

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.payment_intent_error(
        conn,
        params,
        "failed",
        "card_declined",
        "stale renewal charge failed"
      )
    end)

    renewal_task =
      Task.async(fn ->
        Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)
      end)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if Process.alive?(barrier) do
        Agent.update(barrier, &Map.put(&1, :release_dispatch?, true))
      end

      if Process.alive?(renewal_task.pid) do
        Task.shutdown(renewal_task, :brutal_kill)
      end
    end)

    assert_receive {:sbh7002_dispatch_released, ^barrier}, 10_000

    attempt =
      RenewalAttempt
      |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    renewal_order =
      Order
      |> Ash.Query.filter(expr(id == ^attempt.order_id))
      |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    payment_intent =
      PaymentIntent
      |> Ash.Query.filter(expr(id == ^attempt.payment_intent_id))
      |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:ok, %{outcome: :authoritative_success}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               %ProviderObservation{
                 provider: payment_intent.provider,
                 provider_reference: payment_intent.provider_request_reference,
                 provider_reference_kind: :transaction_reference,
                 provider_transaction_id: "pi_jc229_race_#{payment_intent.id}",
                 local_payment_intent_id: payment_intent.id,
                 observation_source: :verification,
                 normalized_outcome: :authoritative_success,
                 raw_provider_status: "succeeded",
                 amount_minor: payment_intent.amount_received_minor,
                 currency: payment_intent.currency,
                 provider_environment: "test",
                 observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               }
             )

    collection =
      RenewalCollectionAttempt
      |> Ash.Query.filter(
        expr(
          renewal_attempt_id == ^attempt.id and
            financial_outcome == :verified_success
        )
      )
      |> Ash.read_one!(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(renewal_order.id,
               renewal_attempt_id: attempt.id,
               collection_attempt_id: collection.id,
               payment_intent_id: collection.payment_intent_id
             )

    Agent.update(barrier, &Map.put(&1, :release_dispatch?, true))

    assert {:ok, :processed} = Task.await(renewal_task, 10_000)

    reloaded_attempt = reload_attempt!(attempt.id)
    assert reloaded_attempt.status == :succeeded

    reloaded_subscription = reload_subscription!(subscription.id)
    assert reloaded_subscription.status == :active
    refute reloaded_subscription.status == :past_due
  end

  defp await_stale_failure_dispatch(metadata, config) do
    if metadata.subscription_id == config.subscription_id do
      send(config.parent, {:sbh7002_dispatch_released, config.barrier})

      wait_until(fn -> Agent.get(config.barrier, & &1.release_dispatch?) end, 2_000)

      unless Agent.get(config.barrier, & &1.release_dispatch?) do
        raise "stale failure dispatch release barrier timed out"
      end
    end
  end

  defp wait_until(predicate, attempts) do
    if predicate.() or attempts <= 0 do
      :ok
    else
      Process.sleep(5)
      wait_until(predicate, attempts - 1)
    end
  end
end
