defmodule Store.Subscriptions.RenewalAttemptMonotonicityTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.Types.ProviderObservation
  alias Store.Subscriptions.{Facade, RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
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
    ReachedRenewalFixtures.prepare_reached!(subscription.id, now).attempt
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

    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    payment_intent = reached.payment_intent

    {:ok, barrier} = Agent.start_link(fn -> %{release?: false} end)
    parent = self()

    stale_writer =
      Task.async(fn ->
        stale_attempt = reload_attempt!(attempt.id)
        send(parent, {:sbh7002_stale_attempt_captured, self()})

        unless wait_until(fn -> Agent.get(barrier, & &1.release?) end, 2_000) do
          raise "stale failure writer barrier timed out"
        end

        mark_failed!(stale_attempt, %{
          failure_code: "PAYMENT_FAILED",
          failure_message: "late stale failure",
          attempt_no: 99
        })
      end)

    on_exit(fn ->
      if Process.alive?(barrier), do: Agent.update(barrier, &Map.put(&1, :release?, true))
      if Process.alive?(stale_writer.pid), do: Task.shutdown(stale_writer, :brutal_kill)
    end)

    assert_receive {:sbh7002_stale_attempt_captured, stale_writer_pid}, 10_000
    assert stale_writer.pid == stale_writer_pid

    assert {:ok, %{outcome: :authoritative_success}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               %ProviderObservation{
                 provider: payment_intent.provider,
                 provider_reference: payment_intent.provider_payment_id,
                 provider_reference_kind: :payment_intent,
                 provider_transaction_id: payment_intent.provider_payment_id,
                 local_payment_intent_id: payment_intent.id,
                 observation_source: :verification,
                 normalized_outcome: :authoritative_success,
                 raw_provider_status: "succeeded",
                 amount_minor: reached.order.grand_total_minor,
                 currency: reached.order.currency_code,
                 provider_environment: "test",
                 observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               }
             )

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(reached.order.id,
               renewal_attempt_id: reached.attempt.id,
               collection_attempt_id: reached.collection.id,
               payment_intent_id: reached.payment_intent.id
             )

    Agent.update(barrier, &Map.put(&1, :release?, true))
    assert stale_record_error?(Task.await(stale_writer, 10_000))

    reloaded_attempt = reload_attempt!(attempt.id)
    assert reloaded_attempt.status == :succeeded

    reloaded_subscription = reload_subscription!(subscription.id)
    assert reloaded_subscription.status == :active
    assert reloaded_subscription.dunning_attempt_count == 0
    refute reloaded_subscription.status == :past_due
  end

  defp wait_until(predicate, attempts) do
    cond do
      predicate.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(5)
        wait_until(predicate, attempts - 1)
    end
  end
end
