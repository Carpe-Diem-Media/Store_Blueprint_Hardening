defmodule Store.Subscriptions.RenewalCollectionAttemptsTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ecto.Query
  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{
    InventoryAdmission.Request,
    InventoryReservation,
    Order,
    PaymentApplication
  }

  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Providers
  alias Store.Payments.Types.ProviderObservation
  alias Store.Pricing.Contract
  alias Store.Pricing.Contract.{LineAllocation, LineEvaluation}
  alias Store.Repo
  alias Store.Support.ID.UUIDv7
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  alias Store.Subscriptions.{
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Scheduler,
    Subscription
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.{
    AttachAndClaimInput,
    ClaimDispatchInput,
    FenceInput,
    PaymentIntentBindingInput,
    RecordFinancialOutcomeInput,
    ReservationGenerationInput,
    ResumeInput,
    StartInput
  }

  alias Store.SubscriptionsFixtures

  test "outcome fixture config preserves the HTTP test transport" do
    initial_config = Application.get_env(:store, :payments, [])
    expected_options = StripeAPIStub.req_options()

    assert initial_config[:stripe][:request_options] == expected_options

    enable_stripe_for_outcome_test!()

    assert Application.get_env(:store, :payments, [])[:stripe][:request_options] ==
             expected_options
  end

  test "start input accepts a UUID and an explicit current time" do
    renewal_attempt_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, input} =
             StartInput.new(%{
               renewal_attempt_id: renewal_attempt_id,
               now: now
             })

    assert input.renewal_attempt_id == renewal_attempt_id
    assert input.now == now
  end

  test "start input rejects untyped or incomplete data" do
    assert {:error, error} = StartInput.new(%{renewal_attempt_id: "bad", now: DateTime.utc_now()})
    assert error.code == "VALIDATION_ERROR"

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(%{})
    assert error.code == "VALIDATION_ERROR"
  end

  test "collection payment intent key is bound to the collection identity" do
    collection_attempt_id = Ecto.UUID.generate()

    assert RenewalCollectionAttempts.payment_intent_key(collection_attempt_id) ==
             "renewal-collection:" <> collection_attempt_id
  end

  test "payment intent binding input validates both UUIDs" do
    input_attrs = %{
      collection_attempt_id: Ecto.UUID.generate(),
      payment_intent_id: Ecto.UUID.generate()
    }

    assert {:ok, input} = PaymentIntentBindingInput.new(input_attrs)
    assert input.collection_attempt_id == input_attrs.collection_attempt_id
    assert input.payment_intent_id == input_attrs.payment_intent_id

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             PaymentIntentBindingInput.new(%{input_attrs | payment_intent_id: "bad"})
  end

  test "attach and claim rejects identity hints that differ from the locked collection owner" do
    {attempt, now} = create_bound_attempt!("jc229_attach_claim_identity_hint")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, input} =
             AttachAndClaimInput.new(%{
               collection_attempt_id: collection.id,
               renewal_attempt_id: Ecto.UUID.generate(),
               subscription_id: attempt.subscription_id,
               payment_intent_id: payment_intent.id,
               expected_epoch: 1,
               now: now
             })

    assert {:error, %{code: "NOT_FOUND"}} =
             RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input)

    assert is_nil(fetch_collection!(collection.id).payment_intent_id)
    assert fetch_collection!(collection.id).dispatch_state == :not_started
  end

  test "attach and claim marks only the first transition as a fresh dispatch" do
    {attempt, now} = create_bound_attempt!("jc229_attach_claim_fresh_dispatch")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    input = %AttachAndClaimInput{
      collection_attempt_id: collection.id,
      renewal_attempt_id: attempt.id,
      subscription_id: attempt.subscription_id,
      payment_intent_id: payment_intent.id,
      expected_epoch: collection.dispatch_epoch,
      now: now
    }

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:attach_claim_waiting, self()})

          receive do
            :attach_claim -> RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input)
          after
            5_000 -> {:error, :attach_claim_barrier_timeout}
          end
        end)
      end

    claim_pids =
      for _ <- 1..2 do
        assert_receive {:attach_claim_waiting, claim_pid}, 5_000
        claim_pid
      end

    Enum.each(claim_pids, &send(&1, :attach_claim))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    claims = Enum.map(results, fn {:ok, claim} -> claim end)
    assert Enum.sort(Enum.map(claims, & &1.dispatch_claimed?)) == [false, true]

    first_claim = Enum.find(claims, & &1.dispatch_claimed?)
    replayed_claim = Enum.find(claims, &(not &1.dispatch_claimed?))

    assert first_claim.collection_attempt.dispatch_state == :may_have_been_reached
    assert replayed_claim.collection_attempt.id == first_claim.collection_attempt.id
    assert replayed_claim.payment_intent.id == first_claim.payment_intent.id
  end

  test "collection binds an exact PaymentIntent to the bound renewal Order and deterministic key" do
    {attempt, now} = create_bound_attempt!("jc229_collection_bind_pi")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    {bound_result, bind_stats} =
      RepoStats.capture(fn ->
        RenewalCollectionAttempts.attach_payment_intent_for_system(%PaymentIntentBindingInput{
          collection_attempt_id: collection.id,
          payment_intent_id: payment_intent.id
        })
      end)

    assert bind_stats.query_count <= 10
    assert {:ok, bound} = bound_result

    assert bound.collection_attempt.payment_intent_id == payment_intent.id
    assert bound.renewal_attempt.id == attempt.id
    assert bound.order.id == order.id
    assert bound.payment_intent.order_id == order.id

    assert bound.payment_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(collection.id)

    assert {:ok, replay} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert replay.collection_attempt.id == collection.id
    assert replay.payment_intent.id == payment_intent.id
  end

  test "provider request reference is durable and immutable before dispatch" do
    {attempt, now} = create_bound_attempt!("jc229_provider_request_reference_immutable")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, expected_reference} =
             Providers.renewal_collection_request_reference(
               payment_intent.provider,
               collection.id
             )

    assert payment_intent.provider_request_reference == expected_reference

    assert {:error, error} =
             Repo.query(
               "UPDATE payment_intents SET provider_request_reference = $2 WHERE id = $1::uuid",
               [uuid_param(payment_intent.id), expected_reference <> "-changed"]
             )

    assert error.postgres.code == :check_violation

    assert error.postgres.constraint ==
             "payment_intents_provider_request_reference_immutable_check"
  end

  test "collection binding keeps the provider request reference stored on its PaymentIntent" do
    {attempt, now} = create_bound_attempt!("jc229_historical_provider_request_reference")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    payment_intent =
      create_collection_payment_intent!(collection, order, attempt,
        provider_request_reference_suffix: "-legacy-v0"
      )

    assert {:ok, bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert bound.payment_intent.provider_request_reference ==
             payment_intent.provider_request_reference
  end

  test "PaymentIntent reuse keeps its stored request reference after adapter mapping changes" do
    {attempt, now} = create_bound_attempt!("jc229_provider_reference_mapping_change")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    original =
      create_collection_payment_intent!(collection, order, attempt,
        provider_request_reference_suffix: "-legacy-v0"
      )

    replay =
      create_collection_payment_intent!(collection, order, attempt,
        provider_request_reference_suffix: "-current-v1"
      )

    assert replay.id == original.id
    assert replay.provider_request_reference == original.provider_request_reference
  end

  test "collection rejects a PaymentIntent for a different Order" do
    {attempt, now} = create_bound_attempt!("jc229_collection_wrong_order")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    other_order = create_renewal_order_for_attempt!(attempt)

    payment_intent =
      create_collection_payment_intent!(collection, other_order, attempt)

    assert {:error, error} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert error.code == "PAYMENT_EVENT_UNVERIFIED"
    assert is_binary(order.id)
    assert is_nil(fetch_collection!(collection.id).payment_intent_id)
  end

  test "collection rejects totals, currency, and key conflicts with the bound Order" do
    {attempt, now} = create_bound_attempt!("jc229_collection_wrong_totals")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    wrong_amount =
      create_collection_payment_intent!(collection, order, attempt,
        amount_received_minor: order.grand_total_minor + 1,
        key_suffix: ":amount",
        provider_request_reference_suffix: "-amount"
      )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: wrong_amount.id
               }
             )

    wrong_currency =
      create_collection_payment_intent!(collection, order, attempt,
        currency: "EUR",
        key_suffix: ":currency",
        provider_request_reference_suffix: "-currency"
      )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: wrong_currency.id
               }
             )

    wrong_key =
      create_collection_payment_intent!(collection, order, attempt,
        key_suffix: ":wrong-key",
        provider_request_reference_suffix: "-wrong-key"
      )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: wrong_key.id
               }
             )

    assert is_nil(fetch_collection!(collection.id).payment_intent_id)
  end

  test "a stale legacy RenewalAttempt PaymentIntent cannot override the collection identity" do
    {attempt, now} = create_bound_attempt!("jc229_collection_stale_legacy_pi")
    subscription = fetch_subscription!(attempt.subscription_id)
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    stale_intent = create_legacy_payment_intent!(subscription)
    exact_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _updated} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{order_id: order.id, payment_intent_id: stale_intent.id},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: exact_intent.id
               }
             )

    assert bound.renewal_attempt.payment_intent_id == stale_intent.id
    assert bound.payment_intent.id == exact_intent.id
    assert bound.collection_attempt.payment_intent_id == exact_intent.id
  end

  test "mutated current subscription and plan values do not change bound collection construction" do
    {attempt, now} = create_bound_attempt!("jc229_collection_bound_contract")
    subscription = fetch_subscription!(attempt.subscription_id)
    %{variant: changed_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "UPDATE subscriptions SET renewal_amount_minor = 9900, renewal_currency = 'EUR', quantity = 4, variant_id = $2::uuid WHERE id = $1::uuid",
               [uuid_param(subscription.id), uuid_param(changed_variant.id)]
             )

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "UPDATE subscription_plans SET amount_minor = 8800, currency = 'EUR' WHERE id = $1::uuid",
               [uuid_param(subscription.subscription_plan_id)]
             )

    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert bound.renewal_attempt.amount_minor == attempt.amount_minor
    assert bound.renewal_attempt.currency == attempt.currency
    assert bound.renewal_attempt.variant_id == attempt.variant_id
    assert bound.renewal_attempt.quantity == attempt.quantity
    assert bound.renewal_attempt.period_start_at == attempt.period_start_at
    assert bound.renewal_attempt.period_end_at == attempt.period_end_at
    assert bound.order.currency_code == attempt.currency
    assert bound.payment_intent.amount_received_minor == bound.order.grand_total_minor
    assert bound.payment_intent.currency == attempt.currency
  end

  test "concurrent dispatch claims commit may_have_been_reached once at the exact epoch" do
    {attempt, now} = create_bound_attempt!("jc229_collection_dispatch_claim")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:claim_waiting, self()})

          receive do
            :claim ->
              RenewalCollectionAttempts.claim_dispatch_for_system(
                claim_dispatch_input!(collection.id, 1, now)
              )
          after
            5_000 -> {:error, :claim_barrier_timeout}
          end
        end)
      end

    claim_pids =
      for _ <- 1..2 do
        assert_receive {:claim_waiting, claim_pid}, 5_000
        claim_pid
      end

    Enum.each(claim_pids, &send(&1, :claim))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert [claimed] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, %{code: "STALE_RECORD"}}] = Enum.filter(results, &match?({:error, _}, &1))
    {:ok, claimed} = claimed

    assert claimed.collection_attempt.dispatch_state == :may_have_been_reached
    assert claimed.collection_attempt.dispatch_epoch == 1
    assert claimed.payment_intent.id == payment_intent.id

    assert claimed.payment_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(collection.id)

    assert {:error, %{code: "STALE_RECORD"}} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    assert fetch_collection!(collection.id).dispatch_state == :may_have_been_reached
  end

  test "dispatch claim rejects a stale epoch before changing collection state" do
    {attempt, now} = create_bound_attempt!("jc229_collection_stale_dispatch_epoch")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:error, %{code: "STALE_RECORD"}} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 2, now)
             )

    assert fetch_collection!(collection.id).dispatch_state == :not_started
  end

  test "PAST_DUE without a trusted boundary cannot claim a new provider dispatch" do
    {attempt, now} = create_bound_attempt!("jc239_claim_missing_boundary")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, next_retry_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(attempt.subscription_id)]
    )

    input = %AttachAndClaimInput{
      collection_attempt_id: collection.id,
      renewal_attempt_id: attempt.id,
      subscription_id: attempt.subscription_id,
      payment_intent_id: payment_intent.id,
      expected_epoch: 1,
      now: now
    }

    assert {:error, %{code: "RENEWAL_AUTHORITY_WITHDRAWN"}} =
             RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input)

    assert fetch_collection!(collection.id).dispatch_state == :not_started
    assert fetch_payment_intent!(payment_intent.id).provider_payment_method_ref == nil
  end

  test "a claim at exact boundary equality is rejected" do
    {attempt, now} = create_bound_attempt!("jc239_claim_boundary_equality")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)
    boundary_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, failed_payment_boundary_at = $2, next_retry_at = NULL, cancel_at_period_end = true, cancel_after_renewal_attempt_id = $3 WHERE id = $1",
      [
        Ecto.UUID.dump!(attempt.subscription_id),
        boundary_at,
        Ecto.UUID.dump!(attempt.id)
      ]
    )

    input = %AttachAndClaimInput{
      collection_attempt_id: collection.id,
      renewal_attempt_id: attempt.id,
      subscription_id: attempt.subscription_id,
      payment_intent_id: payment_intent.id,
      expected_epoch: 1,
      now: boundary_at
    }

    assert {:error,
            %{
              code: "RENEWAL_AUTHORITY_WITHDRAWN",
              message: "failed-payment boundary has been reached"
            }} =
             RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input)

    assert fetch_collection!(collection.id).dispatch_state == :not_started
  end

  test "claim-time database clock rejects a transaction that crosses the boundary" do
    {attempt, now} = create_bound_attempt!("jc239_claim_cross_boundary")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)
    boundary_at = DateTime.add(now, 1, :second)

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, failed_payment_boundary_at = $2, next_retry_at = NULL, cancel_at_period_end = true, cancel_after_renewal_attempt_id = $3 WHERE id = $1",
      [
        Ecto.UUID.dump!(attempt.subscription_id),
        boundary_at,
        Ecto.UUID.dump!(attempt.id)
      ]
    )

    input = %AttachAndClaimInput{
      collection_attempt_id: collection.id,
      renewal_attempt_id: attempt.id,
      subscription_id: attempt.subscription_id,
      payment_intent_id: payment_intent.id,
      expected_epoch: 1,
      now: now
    }

    result =
      Repo.transaction(fn ->
        Process.sleep(1_100)
        RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input)
      end)

    assert {:error, :rollback} = result

    assert {:error,
            %{
              code: "RENEWAL_AUTHORITY_WITHDRAWN",
              message:
                "Subscription authority was withdrawn at the provider submission checkpoint"
            }} =
             RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input)

    assert fetch_collection!(collection.id).dispatch_state == :not_started
    assert fetch_payment_intent!(payment_intent.id).provider_payment_method_ref == nil
  end

  test "a collection already across the checkpoint remains the same occurrence after the boundary" do
    {attempt, now} = create_bound_attempt!("jc239_reached_collection_boundary")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, %{dispatch_claimed?: true, collection_attempt: claimed}} =
             RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(%AttachAndClaimInput{
               collection_attempt_id: collection.id,
               renewal_attempt_id: attempt.id,
               subscription_id: attempt.subscription_id,
               payment_intent_id: payment_intent.id,
               expected_epoch: collection.dispatch_epoch,
               now: now
             })

    assert claimed.dispatch_state == :may_have_been_reached

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, failed_payment_boundary_at = clock_timestamp() - interval '1 second', next_retry_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(attempt.subscription_id)]
    )

    recovery_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, recovered} =
             RenewalCollectionAttempts.recover_reached_for_subscription_for_system(
               attempt.subscription_id,
               recovery_now
             )

    assert recovered.collection_attempt.id == collection.id
    assert recovered.collection_attempt.dispatch_state == :may_have_been_reached
    assert recovered.payment_intent.id == payment_intent.id
    assert length(list_collections!(attempt.id)) == 1
  end

  test "dispatch replay returns the same exact PaymentIntent and epoch without another claim" do
    {attempt, now} = create_bound_attempt!("jc229_collection_dispatch_replay")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    {first_claim_result, claim_stats} =
      RepoStats.capture(fn ->
        RenewalCollectionAttempts.claim_dispatch_for_system(
          claim_dispatch_input!(collection.id, 1, now)
        )
      end)

    assert claim_stats.query_count <= 13
    assert {:ok, first_claim} = first_claim_result

    assert {:ok, replay} =
             RenewalCollectionAttempts.replay_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    assert replay.collection_attempt.id == first_claim.collection_attempt.id

    assert replay.collection_attempt.dispatch_epoch ==
             first_claim.collection_attempt.dispatch_epoch

    assert replay.collection_attempt.dispatch_state == :may_have_been_reached
    assert replay.payment_intent.id == first_claim.payment_intent.id

    assert replay.payment_intent.payment_intent_key ==
             first_claim.payment_intent.payment_intent_key

    assert replay.provider_payment_method == first_claim.provider_payment_method
  end

  test "reached dispatch replay uses its persisted provider method after cancellation" do
    {attempt, now} = create_bound_attempt!("jc229_replay_after_cancellation")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:ok, first_claim} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    assert first_claim.payment_intent.provider_customer_ref ==
             first_claim.provider_payment_method.provider_customer_ref

    assert first_claim.payment_intent.provider_payment_method_ref ==
             first_claim.provider_payment_method.provider_payment_method_ref

    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, %{status: :canceled}} =
             subscription
             |> Ash.Changeset.for_update(:cancel_now_transition, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, replay} =
             RenewalCollectionAttempts.replay_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    assert replay.collection_attempt.dispatch_state == :may_have_been_reached
    assert replay.payment_intent.id == first_claim.payment_intent.id
    assert replay.provider_payment_method == first_claim.provider_payment_method
  end

  test "physical dispatch requires the assigned exact active reservation generation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_dispatch_generation")
    order = bind_attempt_to_fixture_order!(attempt)
    set_variant_weight!(attempt.variant_id, 1)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:error, %{code: "RESERVATION_CONFLICT"}} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    assigned = assign_generation!(collection.id, now)

    assert {:ok, claimed} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    assert claimed.collection_attempt.reservation_generation_id ==
             assigned.reservation_generation_id

    assert claimed.collection_attempt.dispatch_state == :may_have_been_reached
  end

  test "requires_action remains active and exact success exposes all JC-230 identity fields" do
    {attempt, now} = create_bound_attempt!("jc229_collection_success_handoff")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:ok, _claimed} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, now)
             )

    stale_intent = create_legacy_payment_intent!(fetch_subscription!(attempt.subscription_id))

    assert {:ok, _stale_mirror} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{order_id: order.id, payment_intent_id: stale_intent.id},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    enable_stripe_for_outcome_test!()
    payment_intent = fetch_payment_intent!(payment_intent.id)
    payment_intent = submit_payment_intent!(payment_intent)

    assert {:ok, %{outcome: :requires_action, evidence: action_evidence}} =
             record_provider_outcome!(payment_intent, :requires_action)

    active = fetch_collection!(collection.id)

    assert active.financial_outcome == :requires_action
    assert active.payment_attempt_id == action_evidence.id

    assert {:ok, replay} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert replay.id == collection.id

    success_result = record_provider_outcome!(payment_intent, :succeeded)

    assert {:ok, %{outcome: :authoritative_success, evidence: success_evidence}} = success_result

    succeeded = fetch_collection!(collection.id)

    assert succeeded.financial_outcome == :verified_success
    assert succeeded.payment_attempt_id == success_evidence.id

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: success_evidence.id,
                 payment_intent_id: payment_intent.id,
                 financial_outcome: :verified_success
               }
             )

    {_replay_result, collection_stats} =
      RepoStats.capture(fn ->
        RenewalCollectionAttempts.record_financial_outcome_for_system(
          financial_outcome_input!(
            collection.id,
            payment_intent.id,
            :verified_success,
            success_evidence.id
          )
        )
      end)

    assert collection_stats.query_count <= 8

    {handoff_result, handoff_stats} =
      RepoStats.capture(fn ->
        RenewalCollectionAttempts.success_handoff_for_system(collection.id)
      end)

    assert {:ok, handoff} = handoff_result
    assert handoff_stats.query_count <= 1

    assert handoff == %{
             order_id: order.id,
             renewal_attempt_id: attempt.id,
             collection_attempt_id: collection.id,
             payment_intent_id: payment_intent.id
           }

    assert {:error, %{code: "INVALID_STATE_TRANSITION"}} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
  end

  test "local PaymentIntent failure does not set provider-verified collection failure" do
    {attempt, now} = create_bound_attempt!("jc229_collection_local_failure")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    payment_intent = submit_payment_intent!(payment_intent)
    _payment_intent = mark_payment_intent!(payment_intent, :mark_failed)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             RecordFinancialOutcomeInput.new(%{
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id,
               financial_outcome: :failed
             })

    assert fetch_collection!(collection.id).financial_outcome == :unresolved

    assert {:ok, replay} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert replay.id == collection.id
  end

  test "local PaymentIntent failure cannot certify terminal collection failure without provider evidence" do
    {attempt, now} = create_bound_attempt!("jc229_collection_fake_terminal_certification")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    payment_intent = submit_payment_intent!(payment_intent)
    _payment_intent = mark_payment_intent!(payment_intent, :mark_failed)

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             RenewalCollectionAttempts.record_financial_outcome_for_system(
               financial_outcome_input!(
                 collection.id,
                 payment_intent.id,
                 :verified_terminal_financial_non_success,
                 Ecto.UUID.generate()
               )
             )

    assert fetch_collection!(collection.id).financial_outcome == :unresolved
  end

  test "local PaymentIntent success cannot certify collection success or JC-230 handoff without provider evidence" do
    {attempt, now} = create_bound_attempt!("jc229_collection_fake_success_certification")
    order = bind_attempt_to_fixture_order!(attempt)
    {:ok, collection} = RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    payment_intent = submit_payment_intent!(payment_intent)
    _payment_intent = mark_payment_intent!(payment_intent, :mark_succeeded)

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             RenewalCollectionAttempts.record_financial_outcome_for_system(
               financial_outcome_input!(
                 collection.id,
                 payment_intent.id,
                 :verified_success,
                 Ecto.UUID.generate()
               )
             )

    assert fetch_collection!(collection.id).financial_outcome == :unresolved

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             RenewalCollectionAttempts.success_handoff_for_system(collection.id)
  end

  test "database rejects a resolved collection outcome without PaymentAttempt evidence" do
    {attempt, now} = create_bound_attempt!("jc229_collection_outcome_db_evidence")
    order = bind_attempt_to_fixture_order!(attempt)
    collection = start_collection!(attempt, now)
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE renewal_collection_attempts SET financial_outcome = 'requires_action' WHERE id = $1::uuid",
               [uuid_param(collection.id)]
             )

    assert fetch_collection!(collection.id).financial_outcome == :unresolved
    assert fetch_collection!(collection.id).payment_attempt_id == nil
  end

  test "first start creates ordinal one and active replay returns that exact collection" do
    {attempt, now} = create_bound_attempt!("jc229_collection_start_replay")
    input = start_input!(attempt.id, now)

    {first_result, first_stats} =
      RepoStats.capture(fn -> RenewalCollectionAttempts.start_for_system(input) end)

    assert first_stats.query_count <= 7
    assert {:ok, first} = first_result
    assert first.collection_ordinal == 1
    assert first.financial_outcome == :unresolved
    assert first.dispatch_state == :not_started

    {replay_result, replay_stats} =
      RepoStats.capture(fn -> RenewalCollectionAttempts.start_for_system(input) end)

    assert replay_stats.query_count <= 6
    assert {:ok, replay} = replay_result
    assert replay.id == first.id
    assert replay.renewal_attempt_id == first.renewal_attempt_id
    assert replay.collection_ordinal == first.collection_ordinal
  end

  test "concurrent starts return one active collection identity" do
    {attempt, now} = create_bound_attempt!("jc229_collection_concurrent_start")
    input = start_input!(attempt.id, now)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:start_waiting, self()})

          receive do
            :start_collection -> RenewalCollectionAttempts.start_for_system(input)
          after
            5_000 -> {:error, :start_barrier_timeout}
          end
        end)
      end

    task_pids =
      for _ <- 1..2 do
        assert_receive {:start_waiting, task_pid}, 5_000
        task_pid
      end

    Enum.each(task_pids, &send(&1, :start_collection))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert [{:ok, first}, {:ok, second}] = Enum.sort_by(results, fn {:ok, item} -> item.id end)
    assert first.id == second.id
    assert first.collection_ordinal == 1
    assert [only_collection] = list_collections!(attempt.id)
    assert only_collection.id == first.id
  end

  test "an incomplete renewal contract fails before collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_incomplete_contract")
    unbound_attempt = create_unbound_attempt!(attempt)

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(unbound_attempt.id, now))

    assert error.code == "VALIDATION_ERROR"
    assert [] == list_collections!(unbound_attempt.id)
  end

  test "a legacy PaymentIntent without collection identity fails closed" do
    {attempt, now} = create_bound_attempt!("jc229_collection_legacy_pi")
    subscription = fetch_subscription!(attempt.subscription_id)
    legacy_payment_intent = create_legacy_payment_intent!(subscription)

    assert {:ok, _processing} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{
                 order_id: subscription.source_order_id,
                 payment_intent_id: legacy_payment_intent.id
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "PAYMENT_EVENT_UNVERIFIED"
    assert [] == list_collections!(attempt.id)
    assert fetch_renewal_attempt!(attempt.id).payment_intent_id == legacy_payment_intent.id
  end

  test "a legacy succeeded RenewalAttempt without collection identity fails closed" do
    {attempt, now} = create_bound_attempt!("jc229_collection_legacy_succeeded")
    subscription = fetch_subscription!(attempt.subscription_id)
    legacy_payment_intent = create_legacy_payment_intent!(subscription)

    assert {:ok, _succeeded} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_succeeded,
               %{
                 order_id: subscription.source_order_id,
                 payment_intent_id: legacy_payment_intent.id
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "PAYMENT_EVENT_UNVERIFIED"
    assert [] == list_collections!(attempt.id)
  end

  test "legacy renewal PaymentIntent cannot enqueue reconciliation without a collection identity" do
    {attempt, _now} = create_bound_attempt!("jc229_legacy_payment_handoff")
    order = bind_attempt_to_fixture_order!(attempt)
    subscription = fetch_subscription!(attempt.subscription_id)

    {:ok, result} =
      Store.Payments.create_or_reuse_payment_intent(
        %{
          order_id: order.id,
          amount_received_minor: order.grand_total_minor,
          currency: attempt.currency,
          provider: subscription.provider,
          payment_intent_key: "jc229_legacy_collectionless:#{Ecto.UUID.generate()}"
        },
        context: %{system?: true}
      )

    payment_intent = submit_payment_intent!(result.payment_intent)

    assert {:ok, _updated_attempt} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{order_id: order.id, payment_intent_id: payment_intent.id},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Store.Payments.apply_payment_success_once(payment_intent.id)

    assert fetch_order!(order.id).state == :paid

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert [] ==
             all_enqueued(
               worker: Store.Workers.ReconcilePaidSubscriptionRenewalWorker,
               args: %{
                 "order_id" => order.id,
                 "renewal_attempt_id" => attempt.id
               }
             )
  end

  test "requires_action remains the active collection and does not allocate an ordinal" do
    {attempt, now} = create_bound_attempt!("jc229_collection_requires_action")
    input = start_input!(attempt.id, now)
    assert {:ok, collection} = RenewalCollectionAttempts.start_for_system(input)
    set_financial_outcome!(collection, attempt.subscription_id, :requires_action)

    assert {:ok, replay} = RenewalCollectionAttempts.start_for_system(input)
    assert replay.id == collection.id

    assert [only_collection] = list_collections!(attempt.id)

    assert only_collection.id == collection.id
  end

  test "verified success permanently closes collection allocation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_success_closes")
    input = start_input!(attempt.id, now)
    assert {:ok, collection} = RenewalCollectionAttempts.start_for_system(input)
    set_financial_outcome!(collection, attempt.subscription_id, :verified_success)

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(input)
    assert error.code == "INVALID_STATE_TRANSITION"
    assert error.meta.already_succeeded?
  end

  test "certified terminal non-success permits the next contiguous ordinal when retry is due" do
    {attempt, now} = create_bound_attempt!("jc229_collection_next_ordinal")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second))

    {second_result, next_stats} =
      RepoStats.capture(fn -> RenewalCollectionAttempts.start_for_system(input) end)

    assert next_stats.query_count <= 8
    assert {:ok, second} = second_result
    assert second.collection_ordinal == 2
    assert second.id != first.id
  end

  test "awaiting cancellation preserves a permitted retry for the exact bound occurrence" do
    {attempt, now} = create_bound_attempt!("jc242_awaiting_retry")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second))

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = $2 WHERE id = $1",
      [
        Ecto.UUID.dump!(attempt.subscription_id),
        DateTime.add(now, 3_600, :second)
      ]
    )

    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, scheduled} =
             subscription
             |> Ash.Changeset.for_update(
               :cancel_at_period_end_transition,
               %{cancel_after_renewal_attempt_id: attempt.id},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(scheduled.cancel_at_period_end_at)

    assert {:ok, second} = RenewalCollectionAttempts.start_for_system(input)
    assert second.renewal_attempt_id == attempt.id
    assert second.collection_ordinal == 2
    assert second.id != first.id

    charged_attempt = fetch_renewal_attempt!(attempt.id)

    payment_intent =
      create_collection_payment_intent!(
        second,
        fetch_order!(charged_attempt.order_id),
        charged_attempt
      )

    assert {:ok,
            %{
              dispatch_claimed?: true,
              renewal_attempt: claimed_attempt,
              collection_attempt: claimed_collection
            }} =
             RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(%AttachAndClaimInput{
               collection_attempt_id: second.id,
               renewal_attempt_id: attempt.id,
               subscription_id: attempt.subscription_id,
               payment_intent_id: payment_intent.id,
               expected_epoch: second.dispatch_epoch,
               now: now
             })

    assert claimed_attempt.id == attempt.id
    assert claimed_collection.id == second.id
    assert claimed_collection.dispatch_state == :may_have_been_reached
  end

  test "certified terminal non-success does not permit a collection before retry time" do
    {attempt, now} = create_bound_attempt!("jc229_collection_retry_not_due")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, 60, :second))

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(input)
    assert error.code == "INVALID_STATE_TRANSITION"

    assert [only_collection] = list_collections!(attempt.id)

    assert only_collection.id == first.id
  end

  test "dunning limit from the bound contract blocks another ordinal" do
    {attempt, now} = create_bound_attempt!("jc229_collection_retry_exhausted")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second), 4)

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(input)
    assert error.code == "INVALID_STATE_TRANSITION"
    assert [only_collection] = list_collections!(attempt.id)
    assert only_collection.id == first.id
  end

  test "funded scheduled cancellation blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_cancel_scheduled")
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _updated} =
             subscription
             |> Ash.Changeset.for_update(
               :cancel_at_period_end_transition,
               %{cancel_at_period_end_at: subscription.current_period_end_at},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "immediate cancellation blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_cancel_now")
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _canceled} =
             subscription
             |> Ash.Changeset.for_update(:cancel_now_transition, %{canceled_reason: "customer"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "expired subscription blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_expired")
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _expired} =
             subscription
             |> Ash.Changeset.for_update(:mark_expired_transition, %{canceled_reason: "term_end"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "withdrawn RenewalAttempt authority blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_withdrawn_attempt")

    assert {:ok, _withdrawn} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_authority_withdrawn,
               %{failure_message: "authority withdrawn"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "suspension blocks a new collection ordinal" do
    {attempt, now} = create_bound_attempt!("jc229_collection_suspended")
    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second))
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _suspended} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_suspended_transition,
               %{
                 billing_status_reason: "RETRY_EXHAUSTED",
                 past_due_since_at: now,
                 dunning_attempt_count: 1
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "physical reservation assignment is exact and replayable" do
    {attempt, now} = create_bound_attempt!("jc229_generation_assignment")
    collection = start_collection!(attempt, now)
    order = bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)

    assert {:ok, input} =
             ReservationGenerationInput.new(%{
               collection_attempt_id: collection.id,
               now: now
             })

    assert {:ok, assigned} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(input)

    assert is_binary(assigned.reservation_generation_id)
    reservation = Repo.get!(InventoryReservation, assigned.reservation_generation_id)
    assert reservation.order_id == order.id
    assert reservation.variant_id == attempt.variant_id
    assert reservation.quantity == attempt.quantity
    assert reservation.state == :active

    assert {:ok,
            {:renewal_generation,
             %{collection_attempt_id: collection_attempt_id, order_id: order_id}}} =
             Request.classify_reservation_key(reservation.reservation_key)

    assert collection_attempt_id == collection.id
    assert order_id == order.id

    assert {:ok, replay} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(input)

    assert replay.id == assigned.id
    assert replay.reservation_generation_id == assigned.reservation_generation_id
    assert reservation_count(order.id, attempt.variant_id) == 1
  end

  test "a succeeded parent renewal cannot acquire a dispatch reservation" do
    {attempt, now} = create_bound_attempt!("jc229_generation_parent_succeeded")
    collection = start_collection!(attempt, now)
    order = bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)

    assert {:ok, %{num_rows: 1}} =
             Repo.query("UPDATE renewal_attempts SET status = 'succeeded' WHERE id = $1::uuid", [
               uuid_param(attempt.id)
             ])

    assert {:error, error} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(
               reservation_generation_input!(collection.id, now)
             )

    assert error.code == "INVALID_STATE_TRANSITION"
    assert reservation_count(order.id, attempt.variant_id) == 0
  end

  test "concurrent physical assignment returns one exact generation" do
    {attempt, now} = create_bound_attempt!("jc229_generation_concurrent_assignment")
    collection = start_collection!(attempt, now)
    order = bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    input = reservation_generation_input!(collection.id, now)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:assignment_waiting, self()})

          receive do
            :assign ->
              RenewalCollectionAttempts.assign_reservation_generation_for_system(input)
          after
            5_000 -> {:error, :assignment_barrier_timeout}
          end
        end)
      end

    task_pids =
      for _ <- 1..2 do
        assert_receive {:assignment_waiting, task_pid}, 5_000
        task_pid
      end

    Enum.each(task_pids, &send(&1, :assign))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id
    assert first.reservation_generation_id == second.reservation_generation_id
    assert reservation_count(order.id, attempt.variant_id) == 1
  end

  test "reservation creation rolls back when collection binding fails" do
    {attempt, now} = create_bound_attempt!("jc229_generation_assignment_rollback")
    collection = start_collection!(attempt, now)
    order = bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    trigger_suffix = System.unique_integer([:positive])
    trigger_name = "jc229_reject_generation_assignment_#{trigger_suffix}"
    function_name = "jc229_reject_generation_assignment_fn_#{trigger_suffix}"

    assert {:ok, _} =
             Repo.query(
               "CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture rejects collection binding'; END; $$"
             )

    assert {:ok, _} =
             Repo.query(
               "CREATE TRIGGER #{trigger_name} BEFORE UPDATE OF reservation_generation_id ON renewal_collection_attempts FOR EACH ROW EXECUTE FUNCTION #{function_name}()"
             )

    input = reservation_generation_input!(collection.id, now)

    assert {:error, _error} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(input)

    assert {:ok, _} = Repo.query("DROP TRIGGER #{trigger_name} ON renewal_collection_attempts")
    assert {:ok, _} = Repo.query("DROP FUNCTION #{function_name}()")

    assert is_nil(fetch_collection!(collection.id).reservation_generation_id)
    assert reservation_count(order.id, attempt.variant_id) == 0
  end

  test "nonphysical renewal does not require or create a reservation generation" do
    {attempt, now} = create_bound_attempt!("jc229_virtual_generation")
    collection = start_collection!(attempt, now)
    order = bind_order!(attempt)

    assert {:ok, input} =
             ReservationGenerationInput.new(%{
               collection_attempt_id: collection.id,
               now: now
             })

    assert {:ok, assigned} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(input)

    assert is_nil(assigned.reservation_generation_id)
    assert reservation_count(order.id, attempt.variant_id) == 0
  end

  test "pre-submission fence releases only the bound generation and preserves unresolved truth" do
    {attempt, now} = create_bound_attempt!("jc229_generation_fence")
    collection = start_collection!(attempt, now)
    bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    assigned = assign_generation!(collection.id, now)
    reservation_id = assigned.reservation_generation_id

    assert {:ok, fence_input} =
             FenceInput.new(%{
               collection_attempt_id: assigned.id,
               expected_epoch: 1,
               now: now
             })

    {fence_result, fence_stats} =
      RepoStats.capture(fn ->
        RenewalCollectionAttempts.fence_before_submission_for_system(fence_input)
      end)

    assert fence_stats.query_count <= 15
    assert {:ok, fenced} = fence_result

    assert fenced.dispatch_state == :not_submitted
    assert fenced.dispatch_epoch == 1
    assert fenced.fenced_through_epoch == 1
    assert fenced.financial_outcome == :unresolved
    assert is_binary(fenced.last_fence_event_id)
    assert fenced.last_fenced_at == now
    assert Repo.get!(InventoryReservation, reservation_id).state == :cancelled

    assert {:ok, replacement} = reserve_replacement_generation!(attempt, fenced)

    assert {:error, stale_fence} =
             RenewalCollectionAttempts.fence_before_submission_for_system(fence_input)

    assert stale_fence.code == "STALE_RECORD"
    assert Repo.get!(InventoryReservation, replacement.reservation.id).state == :active
  end

  test "physical collection can be fenced before any reservation was acquired" do
    {attempt, now} = create_bound_attempt!("jc229_generation_unassigned_fence")
    collection = start_collection!(attempt, now)
    order = bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)

    assert {:ok, fenced} = fence_collection!(collection.id, now)

    assert fenced.dispatch_state == :not_submitted
    assert fenced.financial_outcome == :unresolved
    assert is_nil(fenced.reservation_generation_id)
    assert reservation_count(order.id, attempt.variant_id) == 0
  end

  test "fence and replacement generation race cannot release the replacement" do
    {attempt, now} = create_bound_attempt!("jc229_generation_fence_replace_race")
    collection = start_collection!(attempt, now)
    bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    assigned = assign_generation!(collection.id, now)
    fence_input = fence_input!(assigned.id, 1, now)
    parent = self()

    fence_task =
      Task.async(fn ->
        send(parent, {:fence_waiting, self()})

        receive do
          :race -> RenewalCollectionAttempts.fence_before_submission_for_system(fence_input)
        after
          5_000 -> {:error, :fence_barrier_timeout}
        end
      end)

    replace_task =
      Task.async(fn ->
        send(parent, {:replace_waiting, self()})

        receive do
          :race -> reserve_replacement_generation!(attempt, assigned)
        after
          5_000 -> {:error, :replacement_barrier_timeout}
        end
      end)

    assert_receive {:fence_waiting, fence_pid}, 5_000
    assert_receive {:replace_waiting, replace_pid}, 5_000
    send(fence_pid, :race)
    send(replace_pid, :race)

    assert {:ok, fenced} = Task.await(fence_task, 10_000)
    assert fenced.dispatch_state == :not_submitted

    case Task.await(replace_task, 10_000) do
      {:ok, %{reservation: replacement}} ->
        assert replacement.state == :active

        assert Repo.get!(InventoryReservation, assigned.reservation_generation_id).state ==
                 :cancelled

      {:error, %{code: "RESERVATION_CONFLICT"}} ->
        assert Repo.get!(InventoryReservation, assigned.reservation_generation_id).state ==
                 :cancelled

        assert reservation_count(fetch_renewal_attempt!(attempt.id).order_id, attempt.variant_id) ==
                 1

      other ->
        flunk("replacement race returned an unexpected result: #{inspect(other)}")
    end
  end

  test "replacement cannot begin before the assigned generation is fenced" do
    {attempt, now} = create_bound_attempt!("jc229_generation_replace_before_fence")
    collection = start_collection!(attempt, now)
    bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    assigned = assign_generation!(collection.id, now)

    assert {:error, %{code: "RESERVATION_CONFLICT"}} =
             reserve_replacement_generation!(attempt, assigned)

    assert Repo.get!(InventoryReservation, assigned.reservation_generation_id).state == :active

    assert {:ok, _fenced} = fence_collection!(assigned.id, now)

    assert {:ok, %{reservation: replacement}} =
             reserve_replacement_generation!(attempt, assigned)

    assert Repo.get!(InventoryReservation, assigned.reservation_generation_id).state == :cancelled
    assert Repo.get!(InventoryReservation, replacement.id).state == :active
  end

  test "resume reuses the collection and advances exactly one epoch with a new generation" do
    {attempt, now} = create_bound_attempt!("jc229_generation_resume")
    collection = start_collection!(attempt, now)
    bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    assigned = assign_generation!(collection.id, now)
    previous_reservation_id = assigned.reservation_generation_id
    fence_collection!(assigned.id, now)

    assert {:ok, input} =
             ResumeInput.new(%{
               collection_attempt_id: assigned.id,
               expected_epoch: 1,
               now: now
             })

    assert {:ok, resumed} = RenewalCollectionAttempts.resume_after_fence_for_system(input)

    assert resumed.id == assigned.id
    assert resumed.collection_ordinal == 1
    assert resumed.dispatch_state == :not_started
    assert resumed.dispatch_epoch == 2
    assert resumed.fenced_through_epoch == 1
    assert resumed.financial_outcome == :unresolved
    refute resumed.reservation_generation_id == previous_reservation_id
    assert Repo.get!(InventoryReservation, previous_reservation_id).state == :cancelled
    assert Repo.get!(InventoryReservation, resumed.reservation_generation_id).state == :active

    assert {:error, stale_resume} =
             RenewalCollectionAttempts.resume_after_fence_for_system(input)

    assert stale_resume.code == "STALE_RECORD"
  end

  test "concurrent resume advances one epoch once and keeps one collection" do
    {attempt, now} = create_bound_attempt!("jc229_generation_concurrent_resume")
    collection = start_collection!(attempt, now)
    bind_order!(attempt)
    set_variant_weight!(attempt.variant_id, 500)
    assigned = assign_generation!(collection.id, now)
    fence_collection!(assigned.id, now)
    input = resume_input!(assigned.id, 1, now)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:resume_waiting, self()})

          receive do
            :resume -> RenewalCollectionAttempts.resume_after_fence_for_system(input)
          after
            5_000 -> {:error, :resume_barrier_timeout}
          end
        end)
      end

    task_pids =
      for _ <- 1..2 do
        assert_receive {:resume_waiting, task_pid}, 5_000
        task_pid
      end

    Enum.each(task_pids, &send(&1, :resume))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    successful = Enum.filter(results, &match?({:ok, _}, &1))
    stale = Enum.filter(results, &match?({:error, %{code: "STALE_RECORD"}}, &1))

    assert [{:ok, resumed}] = successful
    assert length(stale) == 1
    assert resumed.dispatch_epoch == 2
    assert resumed.id == collection.id
    assert length(list_collections!(attempt.id)) == 1
  end

  test "fence and resume inputs require exact ids, epochs, and current time" do
    id = UUIDv7.generate()

    assert {:error, _} = ReservationGenerationInput.new(%{collection_attempt_id: "bad"})
    assert {:error, _} = FenceInput.new(%{collection_attempt_id: id, expected_epoch: 0})
    assert {:error, _} = ResumeInput.new(%{collection_attempt_id: id, expected_epoch: 1})
  end

  defp start_input!(renewal_attempt_id, now) do
    assert {:ok, input} =
             StartInput.new(%{
               renewal_attempt_id: renewal_attempt_id,
               now: now
             })

    input
  end

  defp start_collection!(attempt, now) do
    assert {:ok, collection} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    collection
  end

  defp bind_order!(attempt) do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    assert {:ok, _processing} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{order_id: order.id},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    order
  end

  defp set_variant_weight!(variant_id, grams) do
    assert {:ok, %{num_rows: 1}} =
             Repo.query("UPDATE variants SET weight_grams = $2 WHERE id = $1::uuid", [
               uuid_param(variant_id),
               grams
             ])
  end

  defp assign_generation!(collection_id, now) do
    input = reservation_generation_input!(collection_id, now)

    assert {:ok, collection} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(input)

    collection
  end

  defp fence_collection!(collection_id, now) do
    input = fence_input!(collection_id, 1, now)

    assert {:ok, fenced} =
             RenewalCollectionAttempts.fence_before_submission_for_system(input)

    {:ok, fenced}
  end

  defp reservation_generation_input!(collection_id, now) do
    assert {:ok, input} =
             ReservationGenerationInput.new(%{
               collection_attempt_id: collection_id,
               now: now
             })

    input
  end

  defp fence_input!(collection_id, epoch, now) do
    assert {:ok, input} =
             FenceInput.new(%{
               collection_attempt_id: collection_id,
               expected_epoch: epoch,
               now: now
             })

    input
  end

  defp claim_dispatch_input!(collection_id, epoch, now) do
    assert {:ok, input} =
             ClaimDispatchInput.new(%{
               collection_attempt_id: collection_id,
               expected_epoch: epoch,
               now: now
             })

    input
  end

  defp financial_outcome_input!(collection_id, payment_intent_id, outcome, payment_attempt_id) do
    assert {:ok, input} =
             RecordFinancialOutcomeInput.new(%{
               collection_attempt_id: collection_id,
               payment_intent_id: payment_intent_id,
               payment_attempt_id: payment_attempt_id,
               financial_outcome: outcome
             })

    input
  end

  defp enable_stripe_for_outcome_test! do
    previous_config = Application.get_env(:store, :payments, [])
    previous_stripe_config = Keyword.get(previous_config, :stripe, [])

    updated_config =
      previous_config
      |> Keyword.put(:enabled_providers, [:stripe])
      |> Keyword.put(
        :stripe,
        Keyword.put(previous_stripe_config, :secret_key, "sk_test_jc229_collection_outcomes")
      )

    Application.put_env(:store, :payments, updated_config)
    on_exit(fn -> Application.put_env(:store, :payments, previous_config) end)
  end

  defp record_provider_outcome!(payment_intent, outcome) do
    {normalized_outcome, raw_status} =
      case outcome do
        :requires_action -> {:requires_action, "requires_action"}
        :succeeded -> {:authoritative_success, "succeeded"}
        :canceled -> {:failure_observation, "canceled"}
      end

    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: payment_intent.provider_request_reference,
      provider_reference_kind: :transaction_reference,
      provider_transaction_id: "pi_jc229_#{payment_intent.id}",
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: normalized_outcome,
      raw_provider_status: raw_status,
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    Store.Payments.record_and_apply_payment_observation_for_system(payment_intent, observation)
  end

  defp submit_payment_intent!(payment_intent) do
    mark_payment_intent!(payment_intent, :submit)
  end

  defp mark_payment_intent!(payment_intent, action) do
    payment_intent
    |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp resume_input!(collection_id, epoch, now) do
    assert {:ok, input} =
             ResumeInput.new(%{
               collection_attempt_id: collection_id,
               expected_epoch: epoch,
               now: now
             })

    input
  end

  defp reserve_replacement_generation!(attempt, collection) do
    attempt = fetch_renewal_attempt!(attempt.id)
    generation_id = UUIDv7.generate()

    assert {:ok, request} =
             Request.new_renewal_generation(
               attempt.order_id,
               attempt.variant_id,
               collection.id,
               generation_id,
               attempt.quantity
             )

    Store.Orders.reserve_exact_generation(
      attempt.order_id,
      attempt.variant_id,
      request.reservation_key,
      attempt.quantity
    )
  end

  defp create_bound_attempt!(label) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    customer =
      SubscriptionsFixtures.create_customer!("#{label}_#{System.unique_integer([:positive])}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second),
        provider_billing_ref: "pm_#{label}",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    {:ok, period} = Scheduler.next_period(subscription.current_period_end_at, revision)

    attrs = %{
      subscription_id: subscription.id,
      period_start_at: subscription.current_period_end_at,
      period_end_at: period.current_period_end_at,
      renewal_key: Scheduler.renewal_key(subscription.id, period.current_period_end_at),
      plan_revision_id: revision.id,
      variant_id: variant.id,
      quantity: subscription.quantity,
      amount_minor: plan.amount_minor,
      currency: plan.currency,
      expected_subscription_version: subscription.aggregate_version,
      charged_contract_version: 1,
      charged_contract_snapshot: charged_contract_snapshot(revision, plan),
      status: :pending
    }

    attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    {attempt, now}
  end

  defp bind_attempt_to_fixture_order!(attempt) do
    order = create_renewal_order_for_attempt!(attempt)

    assert {:ok, _attempt} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{order_id: order.id, payment_intent_id: nil},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    order
  end

  defp create_renewal_order_for_attempt!(attempt) do
    subscription = fetch_subscription!(attempt.subscription_id)

    {:ok, %{order: order}} =
      Store.Orders.begin_checkout(
        %{
          user_id: subscription.user_id,
          line_items: [%{variant_id: attempt.variant_id, quantity: attempt.quantity}],
          checkout_scope: "jc229-test-#{Ecto.UUID.generate()}",
          currency: attempt.currency,
          as_of: attempt.period_start_at,
          pricing_contract_version: "jc229_test_renewal",
          tax_shipping_inputs: %{}
        },
        context: %{system?: true}
      )

    total_minor = attempt.amount_minor * attempt.quantity

    output = %Contract.Output{
      currency: attempt.currency,
      subtotal_minor: total_minor,
      discount_total_minor: 0,
      total_minor: total_minor,
      lines: [
        %LineEvaluation{
          line_id: attempt.variant_id,
          line_no: 1,
          sku_snapshot: "JC229-SUB-RENEWAL",
          product_title_snapshot: "Renewal",
          variant_title_snapshot: "Renewal",
          quantity: attempt.quantity,
          unit_price_minor: attempt.amount_minor,
          line_total_minor: total_minor,
          discount_allocated_minor: 0,
          net_line_total_minor: total_minor
        }
      ],
      line_allocations: [%LineAllocation{line_id: attempt.variant_id, discount_minor: 0}],
      applied_adjustments: []
    }

    assert {:ok, _snapshot} = Store.Orders.write_priced_snapshot(order.id, output)

    assert {:ok, finalized} =
             order
             |> Ash.Changeset.for_update(
               :finalize_checkout_totals,
               %{
                 currency_code: attempt.currency,
                 items_subtotal_minor: total_minor,
                 shipping_total_minor: 0,
                 grand_total_minor: total_minor
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Orders,
               authorize?: false,
               context: %{system?: true}
             )

    finalized
  end

  defp create_collection_payment_intent!(collection, order, attempt, opts \\ []) do
    subscription = fetch_subscription!(attempt.subscription_id)
    suffix = Keyword.get(opts, :key_suffix, "")

    {:ok, provider_request_reference} =
      Providers.renewal_collection_request_reference(
        subscription.provider,
        collection.id
      )

    provider_request_reference =
      provider_request_reference <>
        Keyword.get(opts, :provider_request_reference_suffix, "")

    attrs = %{
      order_id: order.id,
      amount_received_minor: Keyword.get(opts, :amount_received_minor, order.grand_total_minor),
      currency: Keyword.get(opts, :currency, attempt.currency),
      provider: subscription.provider,
      payment_intent_key: RenewalCollectionAttempts.payment_intent_key(collection.id) <> suffix,
      provider_request_reference: provider_request_reference
    }

    {:ok, result} =
      Store.Payments.create_or_reuse_payment_intent(attrs, context: %{system?: true})

    result.payment_intent
  end

  defp create_unbound_attempt!(attempt) do
    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: attempt.subscription_id,
        period_start_at: attempt.period_start_at,
        period_end_at: attempt.period_end_at,
        renewal_key: attempt.renewal_key <> ":unbound",
        status: :pending
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp set_financial_outcome!(collection, subscription_id, outcome) do
    attempt = fetch_renewal_attempt!(collection.renewal_attempt_id)
    assert attempt.subscription_id == subscription_id

    order = bind_attempt_to_fixture_order!(attempt)
    payment_intent = create_collection_payment_intent!(collection, order, attempt)

    assert {:ok, _bound} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               }
             )

    enable_stripe_for_outcome_test!()

    assert {:ok, _claimed} =
             RenewalCollectionAttempts.claim_dispatch_for_system(
               claim_dispatch_input!(collection.id, 1, DateTime.utc_now())
             )

    payment_intent = fetch_payment_intent!(payment_intent.id)
    payment_intent = submit_payment_intent!(payment_intent)
    payment_intent = fetch_payment_intent!(payment_intent.id)

    provider_status =
      case outcome do
        :requires_action -> :requires_action
        :verified_success -> :succeeded
        :verified_terminal_financial_non_success -> :canceled
      end

    resolved_outcome =
      case outcome do
        :requires_action -> :requires_action
        :verified_success -> :authoritative_success
        :verified_terminal_financial_non_success -> :verified_terminal_non_success
      end

    assert {:ok, %{outcome: ^resolved_outcome}} =
             record_provider_outcome!(payment_intent, provider_status)
  end

  defp create_legacy_payment_intent!(subscription) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        order_id: subscription.source_order_id,
        amount_received_minor: 0,
        currency: "USD",
        provider: :stripe,
        subscription_id: subscription.id,
        payment_intent_key: "jc229_legacy_pi:#{Ecto.UUID.generate()}"
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mark_past_due!(subscription_id, now, next_retry_at, count \\ 1) do
    subscription = fetch_subscription!(subscription_id)

    assert {:ok, _updated} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{
                 billing_status_reason: "PAYMENT_FAILED",
                 past_due_since_at: now,
                 dunning_attempt_count: count,
                 next_retry_at: next_retry_at,
                 retry_suppressed_at: nil
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(order_id) do
    Order
    |> Ash.Query.filter(expr(id == ^order_id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_renewal_attempt!(attempt_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection!(collection_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^collection_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_collections!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.for_read(:read_for_renewal_attempt, %{renewal_attempt_id: renewal_attempt_id})
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reservation_count(order_id, variant_id) do
    query =
      from reservation in InventoryReservation,
        where: reservation.order_id == ^order_id and reservation.variant_id == ^variant_id,
        select: count(reservation.id)

    Repo.one!(query)
  end

  defp uuid_param(uuid) do
    {:ok, binary} = Ecto.UUID.dump(uuid)
    binary
  end

  defp charged_contract_snapshot(revision, plan) do
    %{
      "version" => 1,
      "subscription_plan_key" => plan.key,
      "interval_unit" => Atom.to_string(revision.interval_unit),
      "interval_count" => revision.interval_count,
      "trial_days" => revision.trial_days,
      "anchor_mode" => Atom.to_string(revision.anchor_mode),
      "anchor_day_of_month" => revision.anchor_day_of_month,
      "billing_timezone" => revision.billing_timezone,
      "term_mode" => Atom.to_string(revision.term_mode),
      "term_cycles" => revision.term_cycles,
      "term_end_at" => snapshot_datetime(revision.term_end_at),
      "access_on_past_due" => Atom.to_string(revision.access_on_past_due),
      "access_on_cancel" => Atom.to_string(revision.access_on_cancel),
      "grace_period_days" => revision.grace_period_days,
      "max_retry_attempts" => revision.max_retry_attempts,
      "retry_schedule_hours" => revision.retry_schedule_hours,
      "entitlement_kind" => snapshot_enum(revision.entitlement_kind),
      "entitlement_scope_key" => revision.entitlement_scope_key
    }
  end

  defp snapshot_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp snapshot_datetime(_value), do: nil
  defp snapshot_enum(nil), do: nil
  defp snapshot_enum(value) when is_atom(value), do: Atom.to_string(value)
end
