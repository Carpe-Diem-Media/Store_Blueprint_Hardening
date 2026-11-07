defmodule Store.Subscriptions.JC290StrictDispatchTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ecto.Query, only: [from: 2]
  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.Variant
  alias Store.DirectRepo
  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Pricing.TaxRate
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.{RenewalAttempt, RenewalCollectionAttempt, Subscription}
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Subscriptions.RenewalCollectionAttempts.FenceInput
  alias Store.Subscriptions.RenewalCollectionAttempts.ReservationGenerationInput
  alias Store.Subscriptions.StoredPaymentMethod
  alias Store.SubscriptionsFixtures
  alias Store.Support.AshNotifications
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker
  alias Store.Workers.RunDueSubscriptionRenewalsWorker

  @unchanged_fields [
    :status,
    :billing_status_reason,
    :past_due_since_at,
    :failed_payment_boundary_at,
    :dunning_attempt_count,
    :next_retry_at,
    :retry_suppressed_at,
    :current_period_start_at,
    :current_period_end_at,
    :provider_customer_ref,
    :provider_billing_ref,
    :stored_payment_method_id
  ]

  setup context do
    StripeAPIStub.setup_default(context)
    previous_mode = Application.fetch_env(:store, :database_pool_mode)

    on_exit(fn ->
      case previous_mode do
        {:ok, mode} -> Application.put_env(:store, :database_pool_mode, mode)
        :error -> Application.delete_env(:store, :database_pool_mode)
      end
    end)

    :ok
  end

  for mode <- ["session", "transaction", nil] do
    @mode mode
    test "unfenced fresh dispatch stays unclaimed in #{inspect(mode)} database mode" do
      Application.put_env(:store, :database_pool_mode, @mode)
      {subscription, now} = due_subscription!()
      before = Map.take(subscription, @unchanged_fields)
      inventory_before = inventory_state!(subscription.id)
      StripeAPIStub.stub_unexpected!("unfenced renewal must not contact Stripe")

      for _ <- 1..2 do
        assert {:error,
                %{
                  code: "RENEWAL_DISPATCH_UNAVAILABLE",
                  meta: %{reason: :provider_revocation_fencing_unsupported}
                }} =
                 Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

        assert Map.take(fetch_subscription!(subscription.id), @unchanged_fields) == before
      end

      assert [attempt] = attempts(subscription.id)
      assert is_binary(attempt.order_id)
      assert attempt.payment_intent_id == nil
      assert attempt.failure_code == nil
      assert [collection] = collections(attempt.id)
      assert collection.dispatch_state == :not_started
      assert collection.financial_outcome == :unresolved
      assert collection.dispatch_epoch == 1
      assert collection.payment_intent_id == nil
      assert is_nil(collection.reservation_generation_id)
      assert inventory_state!(subscription.id) == inventory_before
      assert exact_generation_reservation_count(attempt.order_id) == 0

      key = "renewal-collection:#{collection.id}"

      assert [intent] =
               PaymentIntent
               |> Ash.Query.filter(expr(payment_intent_key == ^key))
               |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})

      assert intent.order_id == attempt.order_id
      assert intent.state == :created
      assert intent.provider_payment_id == nil
      assert intent.provider_payment_method_ref == nil
    end
  end

  test "a legacy unreached generation is released once and remains fenced" do
    {subscription, now} = due_subscription!()
    StripeAPIStub.stub_unexpected!("unsupported renewal must not contact Stripe")
    inventory_before = inventory_state!(subscription.id)

    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [attempt] = attempts(subscription.id)
    [collection] = collections(attempt.id)

    assert {:ok, assigned} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(
               %ReservationGenerationInput{collection_attempt_id: collection.id, now: now}
             )

    generation_id = assigned.reservation_generation_id
    assert is_binary(generation_id)

    assert Repo.query!("SELECT state FROM inventory_reservations WHERE id = $1::uuid", [
             Ecto.UUID.dump!(generation_id)
           ]).rows == [["active"]]

    for _ <- 1..2 do
      assert {:error,
              %{
                code: "RENEWAL_DISPATCH_UNAVAILABLE",
                meta: %{reason: :provider_revocation_fencing_unsupported}
              }} = Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)
    end

    fenced = List.first(collections(attempt.id))
    assert fenced.dispatch_state == :not_submitted
    assert fenced.dispatch_epoch == collection.dispatch_epoch
    assert fenced.reservation_generation_id == generation_id

    assert Repo.query!("SELECT state FROM inventory_reservations WHERE id = $1::uuid", [
             Ecto.UUID.dump!(generation_id)
           ]).rows == [["cancelled"]]

    assert inventory_state!(subscription.id) == inventory_before
    assert exact_generation_reservation_count(attempt.order_id) == 1
    assert exact_generation_reservation_count(attempt.order_id, :active) == 0
  end

  test "failed exact reservation cleanup stays unavailable and unresolved" do
    {subscription, now} = due_subscription!()
    StripeAPIStub.stub_unexpected!("failed cleanup must not contact Stripe")

    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [attempt] = attempts(subscription.id)
    [collection] = collections(attempt.id)

    assert {:ok, assigned} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(
               %ReservationGenerationInput{collection_attempt_id: collection.id, now: now}
             )

    change_stored_method_status!(subscription.id, :revoked)
    subscription_after_withdrawal = fetch_subscription!(subscription.id)
    generation_id = assigned.reservation_generation_id
    trigger_suffix = System.unique_integer([:positive])
    trigger_name = "jc290_reject_generation_release_#{trigger_suffix}"
    function_name = "jc290_reject_generation_release_fn_#{trigger_suffix}"

    assert %Postgrex.Result{} =
             Repo.query!(
               "CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture rejects exact generation release'; END; $$"
             )

    assert %Postgrex.Result{} =
             Repo.query!(
               "CREATE TRIGGER #{trigger_name} BEFORE UPDATE OF state ON inventory_reservations FOR EACH ROW WHEN (OLD.id = '#{generation_id}'::uuid) EXECUTE FUNCTION #{function_name}()"
             )

    on_exit(fn ->
      Repo.query("DROP TRIGGER IF EXISTS #{trigger_name} ON inventory_reservations")
      Repo.query("DROP FUNCTION IF EXISTS #{function_name}()")
    end)

    assert {:error,
            %{
              code: "RENEWAL_DISPATCH_UNAVAILABLE",
              meta: %{
                reason: :provider_revocation_fencing_unsupported,
                cleanup_failure: cleanup_failure
              }
            }} = Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert {:error,
            %{
              code: "RENEWAL_DISPATCH_UNAVAILABLE",
              meta: %{cleanup_failure: ^cleanup_failure}
            }} =
             ProcessSubscriptionRenewalWorker.perform(%Oban.Job{
               args: %{"subscription_id" => subscription.id}
             })

    assert cleanup_failure
    assert [unchanged] = collections(attempt.id)
    assert unchanged.dispatch_state == :not_started
    assert unchanged.financial_outcome == :unresolved
    assert unchanged.dispatch_epoch == assigned.dispatch_epoch
    assert unchanged.reservation_generation_id == generation_id

    assert Repo.query!("SELECT state FROM inventory_reservations WHERE id = $1::uuid", [
             Ecto.UUID.dump!(generation_id)
           ]).rows == [["active"]]

    assert Map.take(fetch_subscription!(subscription.id), @unchanged_fields) ==
             Map.take(subscription_after_withdrawal, @unchanged_fields)
  end

  test "deterministic unsupported dispatch cancels the job and keeps its occurrence unique" do
    {subscription, _now} = due_subscription!()
    source_before = Map.take(subscription, @unchanged_fields)
    StripeAPIStub.stub_unexpected!("unsupported renewal worker must not contact Stripe")

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 100})
    assert [queued] = renewal_jobs(subscription.id)

    _drain = Oban.drain_queue(queue: :subscriptions, with_scheduled: true)

    cancelled = DirectRepo.get!(Oban.Job, queued.id)
    assert cancelled.state == "cancelled"
    assert Map.take(fetch_subscription!(subscription.id), @unchanged_fields) == source_before

    [attempt] = attempts(subscription.id)
    [collection] = collections(attempt.id)
    assert attempt.id
    assert collection.id
    assert collection.dispatch_state == :not_started
    assert collection.financial_outcome == :unresolved
    assert collection.payment_intent_id == nil

    for _ <- 1..2 do
      assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, %{"limit" => 100})
      assert [still_cancelled] = renewal_jobs(subscription.id)
      assert still_cancelled.id == queued.id
      assert still_cancelled.state == "cancelled"
      assert Map.take(fetch_subscription!(subscription.id), @unchanged_fields) == source_before
    end

    [same_attempt] = attempts(subscription.id)
    [same_collection] = collections(same_attempt.id)
    assert same_attempt.id == attempt.id
    assert same_collection.id == collection.id
  end

  for method_status <- [:inactive, :revoked] do
    @method_status method_status
    test "legacy unreached reservation is fenced before #{@method_status} method preflight" do
      {subscription, now} = due_subscription!()
      StripeAPIStub.stub_unexpected!("withdrawn method renewal must not contact Stripe")
      inventory_before = inventory_state!(subscription.id)

      assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
               Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

      [attempt] = attempts(subscription.id)
      [collection] = collections(attempt.id)

      assert {:ok, assigned} =
               RenewalCollectionAttempts.assign_reservation_generation_for_system(
                 %ReservationGenerationInput{collection_attempt_id: collection.id, now: now}
               )

      change_stored_method_status!(subscription.id, @method_status)
      subscription_after_withdrawal = fetch_subscription!(subscription.id)
      generation_id = assigned.reservation_generation_id

      for _ <- 1..2 do
        assert {:error,
                %{
                  code: "RENEWAL_DISPATCH_UNAVAILABLE",
                  meta: %{reason: :provider_revocation_fencing_unsupported}
                }} = Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

        assert Map.take(fetch_subscription!(subscription.id), @unchanged_fields) ==
                 Map.take(subscription_after_withdrawal, @unchanged_fields)
      end

      [fenced] = collections(attempt.id)
      assert fenced.dispatch_state == :not_submitted
      assert fenced.financial_outcome == :unresolved
      assert fenced.dispatch_epoch == assigned.dispatch_epoch
      assert fenced.reservation_generation_id == generation_id

      assert Repo.query!("SELECT state FROM inventory_reservations WHERE id = $1::uuid", [
               Ecto.UUID.dump!(generation_id)
             ]).rows == [["cancelled"]]

      assert inventory_state!(subscription.id) == inventory_before
      assert exact_generation_reservation_count(attempt.order_id, :active) == 0
    end
  end

  test "a fenced not-submitted collection cannot be resumed into a provider POST" do
    {subscription, now} = due_subscription!()
    StripeAPIStub.stub_unexpected!("fenced renewal must not contact Stripe")

    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [attempt] = attempts(subscription.id)
    [collection] = collections(attempt.id)

    assert {:ok, fenced} =
             RenewalCollectionAttempts.fence_before_submission_for_system(%FenceInput{
               collection_attempt_id: collection.id,
               expected_epoch: collection.dispatch_epoch,
               now: now
             })

    assert fenced.dispatch_state == :not_submitted

    for _ <- 1..2 do
      assert {:error,
              %{
                code: "RENEWAL_DISPATCH_UNAVAILABLE",
                meta: %{reason: :provider_revocation_fencing_unsupported}
              }} = Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)
    end
  end

  test "an exact reached payment intent is observed and applied without a renewal POST" do
    {subscription, now} = due_subscription!()
    StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)

    body = ReachedRenewalFixtures.observation_body(reached, "succeeded")
    StripeAPIStub.stub_payment_observation(reached.payment_intent.provider_payment_id, body)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert [collection] = collections(reached.attempt.id)
    assert collection.payment_intent_id == reached.payment_intent.id
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :verified_success

    assert [["paid", 1]] ==
             Repo.query!(
               "SELECT orders.state, count(applications.order_id) FROM orders LEFT JOIN payment_applications applications ON applications.order_id = orders.id WHERE orders.id = $1::uuid GROUP BY orders.state",
               [Ecto.UUID.dump!(reached.order.id)]
             ).rows
  end

  for authority_change <- [:replace, :revoke] do
    @authority_change authority_change
    test "reached success is applied after payment method #{authority_change}" do
      {subscription, now} = due_subscription!()
      StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")
      reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
      change_method_authority!(reached, @authority_change)

      body = ReachedRenewalFixtures.observation_body(reached, "succeeded")

      StripeAPIStub.stub_payment_observation(reached.payment_intent.provider_payment_id, body)

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

      current = fetch_subscription!(subscription.id)

      if @authority_change == :replace do
        assert current.provider_billing_ref == "pm_jc290_replaced_#{subscription.id}"
      else
        assert current.provider_billing_ref ==
                 reached.provider_payment_method.provider_payment_method_ref

        assert fetch_stored_method!(reached.provider_payment_method.id).status == :revoked
      end

      assert [[provider_payment_id]] =
               Repo.query!(
                 "SELECT provider_payment_id FROM payment_intents WHERE id = $1::uuid",
                 [
                   Ecto.UUID.dump!(reached.payment_intent.id)
                 ]
               ).rows

      assert provider_payment_id == reached.payment_intent.provider_payment_id

      assert [["paid", 1]] ==
               Repo.query!(
                 "SELECT orders.state, count(applications.order_id) FROM orders LEFT JOIN payment_applications applications ON applications.order_id = orders.id WHERE orders.id = $1::uuid GROUP BY orders.state",
                 [Ecto.UUID.dump!(reached.order.id)]
               ).rows
    end
  end

  test "reached uncertainty without a provider id stays unresolved and does not contact Stripe" do
    {subscription, now} = due_subscription!()
    StripeAPIStub.stub_unexpected!("unobservable reached renewal must not contact Stripe")

    reached =
      ReachedRenewalFixtures.prepare_reached!(subscription.id, now, provider_payment_id: nil)

    assert {:error,
            %{
              code: "PAYMENT_OUTCOME_UNRESOLVED",
              meta: %{existing_collection_replay?: true}
            }} = Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    assert [collection] = collections(reached.attempt.id)
    assert collection.id == reached.collection.id
    assert collection.dispatch_epoch == reached.collection.dispatch_epoch
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.financial_outcome == :unresolved
  end

  test "reached physical uncertainty retains its exact active reservation generation" do
    {subscription, now} = due_subscription!()
    StripeAPIStub.stub_unexpected!("reached renewal may only use exact-ID GET")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    generation_id = reached.collection.reservation_generation_id
    assert is_binary(generation_id)
    inventory_before_observation = inventory_state!(subscription.id)

    body = ReachedRenewalFixtures.observation_body(reached, "processing")

    StripeAPIStub.stub_payment_observation(reached.payment_intent.provider_payment_id, body)

    assert {:error,
            %{
              code: "PAYMENT_OUTCOME_UNRESOLVED",
              meta: %{existing_collection_replay?: true}
            }} = Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [collection] = collections(reached.attempt.id)
    assert collection.dispatch_state == :may_have_been_reached
    assert collection.reservation_generation_id == generation_id
    assert collection.financial_outcome == :unresolved

    assert Repo.query!("SELECT state FROM inventory_reservations WHERE id = $1::uuid", [
             Ecto.UUID.dump!(generation_id)
           ]).rows == [["active"]]

    assert inventory_state!(subscription.id) == inventory_before_observation
  end

  defp due_subscription! do
    customer = SubscriptionsFixtures.create_customer!("jc290_strict_dispatch")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{base_variant_stock_on_hand: 7})

    variant = set_variant_weight!(base_variant, 250)
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_jc290_strict_#{customer.id}",
        provider_billing_ref: "pm_jc290_strict_#{customer.id}",
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    configure_physical_renewal_shipping!(source_order, variant)
    {fetch_subscription!(subscription.id), now}
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp attempts(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp collections(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp renewal_jobs(subscription_id) do
    worker_name = inspect(ProcessSubscriptionRenewalWorker)

    DirectRepo.all(
      from(job in Oban.Job,
        where: job.worker == ^worker_name,
        select: job
      )
    )
    |> Enum.filter(&(&1.args["subscription_id"] == subscription_id))
  end

  defp inventory_state!(subscription_id) do
    Repo.query!(
      "SELECT inventory.stock_on_hand, inventory.reserved_count FROM inventory_items inventory JOIN subscription_items item ON item.variant_id = inventory.variant_id WHERE item.subscription_id = $1::uuid",
      [Ecto.UUID.dump!(subscription_id)]
    ).rows
  end

  defp exact_generation_reservation_count(order_id, state \\ nil) do
    Repo.query!(
      "SELECT count(*) FROM inventory_reservations WHERE order_id = $1::uuid AND position(':renewal_collection:' in reservation_key) > 0 AND ($2::text IS NULL OR state::text = $2)",
      [Ecto.UUID.dump!(order_id), state && Atom.to_string(state)]
    ).rows
    |> hd()
    |> hd()
  end

  defp change_method_authority!(reached, :replace) do
    {:ok, {method, subscription, notifications}} =
      Repo.transaction(fn ->
        {:ok, method, method_notifications} =
          StoredPaymentMethod
          |> Ash.Changeset.for_create(
            :create_or_reuse,
            %{
              user_id: reached.provider_payment_method.user_id,
              provider: :stripe,
              provider_customer_ref: reached.provider_payment_method.provider_customer_ref,
              provider_payment_method_ref: "pm_jc290_replaced_#{reached.attempt.subscription_id}",
              status: :active,
              fingerprint: "fp_jc290_replaced_#{reached.attempt.subscription_id}"
            },
            context: %{system?: true}
          )
          |> Ash.create(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true},
            return_notifications?: true
          )

        subscription = fetch_subscription!(reached.attempt.subscription_id)

        {:ok, subscription, subscription_notifications} =
          subscription
          |> Ash.Changeset.for_update(
            :set_provider_billing_reference,
            %{
              provider_customer_ref: reached.provider_payment_method.provider_customer_ref,
              provider_billing_ref: method.provider_payment_method_ref,
              stored_payment_method_id: method.id
            },
            context: %{system?: true}
          )
          |> Ash.update(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true},
            return_notifications?: true
          )

        {method, subscription, method_notifications ++ subscription_notifications}
      end)

    :ok =
      AshNotifications.notify_post_commit(notifications, context: %{flow: :jc290_test_replace})

    assert method.provider_payment_method_ref == subscription.provider_billing_ref
  end

  defp change_method_authority!(reached, :revoke) do
    {:ok, {:ok, method, notifications}} =
      Repo.transaction(fn ->
        reached.provider_payment_method
        |> Ash.Changeset.for_update(:mark_revoked, %{}, context: %{system?: true})
        |> Ash.update(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true},
          return_notifications?: true
        )
      end)

    :ok = AshNotifications.notify_post_commit(notifications, context: %{flow: :jc290_test_revoke})
    assert method.status == :revoked
  end

  defp fetch_stored_method!(id) do
    StoredPaymentMethod
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp change_stored_method_status!(subscription_id, status) do
    subscription = fetch_subscription!(subscription_id)
    stored_method = fetch_stored_method!(subscription.stored_payment_method_id)
    action = if status == :revoked, do: :mark_revoked, else: :mark_inactive

    {:ok, {:ok, method, notifications}} =
      Repo.transaction(fn ->
        stored_method
        |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
        |> Ash.update(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true},
          return_notifications?: true
        )
      end)

    :ok =
      AshNotifications.notify_post_commit(notifications, context: %{flow: :jc290_test_withdraw})

    assert method.status == status
  end

  defp configure_physical_renewal_shipping!(%Order{} = order, %Variant{} = variant) do
    zone = create_shipping_zone!("US", "CA")
    method = create_shipping_method!("GROUND-#{System.unique_integer([:positive])}")
    create_tax_rate!("US", "CA")
    create_shipping_rule!(zone.id, method.id, 400)

    postal_code =
      "94105-#{System.unique_integer([:positive]) |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")}"

    {:ok, request} =
      QuoteRequest.new(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: postal_code,
        currency_code: "USD",
        shipping_weight_grams: variant.weight_grams
      })

    {:ok, options} = ShippingFacade.quote_options_for_system(request)
    option = Enum.find(options, &(&1.shipping_method_code == method.code))
    assert option

    order
    |> Ash.Changeset.for_update(
      :set_shipping_address,
      %{
        shipping_country_code: "US",
        shipping_region_code: "CA",
        shipping_postal_code: postal_code,
        shipping_address_line1: "1 Market St"
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> Ash.Changeset.for_update(
      :set_shipping_method,
      %{shipping_rate_code: method.code},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> Ash.Changeset.for_update(
      :set_shipping_quote_evidence,
      %{
        shipping_quote_hash: "jc290-baseline-#{System.unique_integer([:positive])}",
        shipping_quote_currency_code: option.currency_code,
        shipping_quote_amount_minor: 400,
        shipping_weight_grams: option.shipping_weight_grams,
        shipping_method_code: method.code,
        shipping_zone_id: option.zone_id
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_zone!(country_code, region_code) do
    ShippingZone
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "JC290-ZONE-#{System.unique_integer([:positive])}",
        country_code: country_code,
        region_code: region_code,
        active: true
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_method!(code) do
    ShippingMethod
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, name: code, active: true, sort_order: 100},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_shipping_rule!(zone_id, method_id, shipping_cost_minor) do
    ShippingRateRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "JC290-RULE-#{System.unique_integer([:positive])}",
        shipping_zone_id: zone_id,
        shipping_method_id: method_id,
        currency: "USD",
        shipping_cost_minor: shipping_cost_minor,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_tax_rate!(country_code, region_code) do
    TaxRate
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "JC290-TAX-#{System.unique_integer([:positive])}",
        country_code: country_code,
        region_code: region_code,
        product_tax_category: "STANDARD",
        rate_basis_points: 0,
        shipping_taxable: true,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  defp set_variant_weight!(%Variant{} = variant, weight_grams) do
    variant
    |> Ash.Changeset.for_update(:update, %{weight_grams: weight_grams}, context: %{system?: true})
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end
end
