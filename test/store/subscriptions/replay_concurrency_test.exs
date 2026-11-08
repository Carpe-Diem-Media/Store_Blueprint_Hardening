defmodule Store.Subscriptions.ReplayConcurrencyTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.{Facade, RenewalAttempt, RenewalCollectionAttempt, Subscription}
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "concurrent renewal ticks create one renewal attempt and do not advance before reconciliation" do
    customer = SubscriptionsFixtures.create_customer!("phase26_sub_concurrency")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_phase26_race",
        next_renewal_at: DateTime.add(now, -5, :second)
      })

    current_period_end = subscription.current_period_end_at
    current_next_renewal_at = subscription.next_renewal_at
    order_count_before = customer_order_count(customer.id)
    StripeAPIStub.stub_unexpected!("concurrent preparation must not submit a renewal charge")

    start = make_ref()

    tasks =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          receive do
            {:start_renewal_tick, ^start} -> :ok
          after
            5_000 -> raise "concurrent renewal tick start timed out"
          end

          Facade.run_due_renewals_for_system(now: now, limit: 50)
        end)
      end)

    on_exit(fn ->
      Enum.each(tasks, fn task ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)
    end)

    Enum.each(tasks, &send(&1.pid, {:start_renewal_tick, start}))

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(results, fn
             {:ok, %{due_count: 1, success_count: success_count, failed_count: failed_count}}
             when success_count in 0..1 and failed_count in 0..1 and
                    success_count + failed_count == 1 ->
               true

             _ ->
               false
           end)

    assert Enum.any?(results, &match?({:ok, %{failed_count: 1}}, &1))

    renewed = fetch_subscription!(subscription.id)
    assert renewed.current_period_end_at == current_period_end
    assert renewed.next_renewal_at == current_next_renewal_at
    assert renewed.status == :active
    assert renewed.dunning_attempt_count == 0
    assert customer_order_count(customer.id) == order_count_before + 1

    attempts = list_attempts!(subscription.id)
    assert length(attempts) == 1
    assert hd(attempts).status == :processing
    assert is_binary(hd(attempts).order_id)

    [collection] = list_collections!(hd(attempts).id)
    assert collection.dispatch_state == :not_started
    assert collection.financial_outcome == :unresolved
    assert collection.payment_intent_id == nil

    payment_intent_key = RenewalCollectionAttempts.payment_intent_key(collection.id)

    assert [payment_intent] =
             PaymentIntent
             |> Ash.Query.filter(expr(payment_intent_key == ^payment_intent_key))
             |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert payment_intent.order_id == hd(attempts).order_id
    assert payment_intent.state == :created
    assert payment_intent.provider_payment_id == nil

    assert 1 ==
             PaymentIntent
             |> Ash.Query.filter(expr(order_id == ^payment_intent.order_id))
             |> Ash.count!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp customer_order_count(customer_id) do
    Order
    |> Ash.Query.filter(expr(user_id == ^customer_id))
    |> Ash.count!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp list_attempts!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_collections!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
