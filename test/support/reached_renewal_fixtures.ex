defmodule Store.TestSupport.ReachedRenewalFixtures do
  @moduledoc """
  Seeds a synthetic legacy collection that may have reached a provider.

  The helper creates no provider receipt. Tests must observe the stored exact
  provider identity through the normal payment observation path before asserting
  any financial outcome.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.RenewalCollectionAttempt
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Subscriptions.RenewalCollectionAttempts.AttachAndClaimInput
  alias Store.Subscriptions.RenewalCollectionAttempts.ReservationGenerationInput
  alias Store.Subscriptions.{StoredPaymentMethod, Subscription}

  def prepare_reached!(subscription_id, now, opts \\ []) do
    provider_payment_id = Keyword.get(opts, :provider_payment_id, unique_provider_id())

    assert_fresh_dispatch_unavailable!(
      Facade.process_due_subscription_renewal_for_system(
        subscription_id,
        now: now
      )
    )

    attempt = read_latest_attempt!(subscription_id)
    collection = read_unreached_collection!(attempt.id)

    {:ok, collection} =
      RenewalCollectionAttempts.assign_reservation_generation_for_system(
        %ReservationGenerationInput{
          collection_attempt_id: collection.id,
          now: now
        }
      )

    payment_intent =
      read_payment_intent!(RenewalCollectionAttempts.payment_intent_key(collection.id))

    order = read_order!(attempt.order_id)

    {:ok, claim} =
      RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(%AttachAndClaimInput{
        collection_attempt_id: collection.id,
        renewal_attempt_id: attempt.id,
        subscription_id: subscription_id,
        payment_intent_id: payment_intent.id,
        expected_epoch: collection.dispatch_epoch,
        now: now
      })

    {:ok, payment_intent} =
      claim.payment_intent
      |> Ash.Changeset.for_update(
        :set_provider_reference,
        %{
          provider: payment_intent.provider,
          purpose: payment_intent.purpose,
          subscription_id: payment_intent.subscription_id,
          provider_payment_id: provider_payment_id,
          provider_customer_ref: claim.provider_payment_method.provider_customer_ref,
          provider_payment_method_ref: claim.provider_payment_method.provider_payment_method_ref
        },
        context: %{system?: true}
      )
      |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})

    subscription = read_subscription!(subscription_id)

    %{
      source: :synthetic_legacy_possible_contact,
      attempt: claim.renewal_attempt || attempt,
      order: claim.order || order,
      collection: claim.collection_attempt,
      payment_intent: payment_intent,
      provider_payment_method: read_stored_method!(subscription.stored_payment_method_id),
      now: now
    }
  end

  def observation_body(
        %{order: order, attempt: attempt, payment_intent: payment_intent},
        status,
        overrides \\ %{}
      ) do
    amount = order.grand_total_minor

    amount_received =
      if status == "succeeded", do: amount, else: Map.get(overrides, "amount_received", 0)

    Map.merge(
      %{
        "amount" => amount,
        "amount_received" => amount_received,
        "currency" => String.downcase(order.currency_code),
        "customer" => payment_intent.provider_customer_ref,
        "id" => payment_intent.provider_payment_id,
        "livemode" => false,
        "metadata" => %{
          "local_intent_id" => payment_intent.id,
          "order_id" => order.id,
          "renewal_attempt_id" => attempt.id,
          "renewal_key" => attempt.renewal_key,
          "subscription_id" => attempt.subscription_id
        },
        "payment_method" => payment_intent.provider_payment_method_ref,
        "status" => status
      },
      overrides
    )
  end

  defp assert_fresh_dispatch_unavailable!({:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}}),
    do: :ok

  defp assert_fresh_dispatch_unavailable!(other),
    do: raise("expected unsupported fresh dispatch, got: #{inspect(other)}")

  defp read_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> case do
      [%RenewalAttempt{} = attempt] -> attempt
      other -> raise "expected one latest renewal attempt, got: #{inspect(other)}"
    end
  end

  defp read_unreached_collection!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(
      expr(
        renewal_attempt_id == ^attempt_id and dispatch_state == :not_started and
          financial_outcome == :unresolved
      )
    )
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> case do
      [%RenewalCollectionAttempt{} = collection] -> collection
      other -> raise "expected one unsubmitted unresolved collection, got: #{inspect(other)}"
    end
  end

  defp read_payment_intent!(key) do
    PaymentIntent
    |> Ash.Query.filter(expr(payment_intent_key == ^key))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp read_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp read_stored_method!(id) do
    StoredPaymentMethod
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp read_order!(id) do
    Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp unique_provider_id do
    "pi_legacy_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
