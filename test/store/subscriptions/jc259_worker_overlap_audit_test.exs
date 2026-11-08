defmodule Store.Subscriptions.JC259WorkerOverlapAuditTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @moduletag timeout: 60_000

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  setup_all do
    assert_test_database!()
    assert Repo.config()[:pool_size] >= 4
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup context do
    owner = Sandbox.start_owner!(Store.DirectRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "fresh readers claim independently while the same unclaimed collection stays unavailable" do
    fixture = fixture!("staggered")
    subscription_before = subscription_state!(fixture)
    ref = make_ref()
    parent = self()
    StripeAPIStub.stub_unexpected!("unfenced renewal must not contact Stripe")
    handler = attach_claim_barrier!(ref, parent)
    first = start_worker(fixture, ref, :first)
    second_key = {ref, :second}

    try do
      assert_receive {^ref, :ready, :first, first_pg}, 5_000
      send(first.pid, {ref, :go})

      assert_receive {^ref, :claim, :first, attempt_id, first_stamp, previous_stamp, false},
                     10_000

      assert first_stamp != previous_stamp

      assert [["pending", persisted_stamp, observer_pg]] =
               Repo.query!(
                 "SELECT status, updated_at, pg_backend_pid() FROM renewal_attempts WHERE id=$1",
                 [Ecto.UUID.dump!(attempt_id)]
               ).rows

      assert persisted_stamp == first_stamp
      refute observer_pg == first_pg

      second = start_worker(fixture, ref, :second)
      Process.put(second_key, second)
      assert_receive {^ref, :ready, :second, second_pg}, 5_000
      refute second_pg == first_pg
      send(second.pid, {ref, :go})

      assert_receive {^ref, :claim, :second, ^attempt_id, second_stamp, ^first_stamp, false},
                     10_000

      assert second_stamp != first_stamp

      assert {:cancel,
              %{
                code: "RENEWAL_DISPATCH_UNAVAILABLE",
                meta: %{reason: :provider_revocation_fencing_unsupported}
              }} = Task.await(second, 15_000)

      before_release = identity!(fixture)
      assert before_release.attempt_id == attempt_id
      assert before_release.attempt_count == 1
      assert before_release.collection_count == 1
      assert before_release.payment_intent_count == 1
      assert before_release.collection_ordinal == 1
      assert is_nil(before_release.collection_payment_intent_id)
      assert before_release.dispatch_state == "not_started"
      assert before_release.financial_outcome == "unresolved"
      assert before_release.payment_intent_state == "created"
      assert before_release.dispatch_epoch == 1
      assert is_nil(before_release.reservation_generation_id)
      assert before_release.reservation_count == 0
      assert before_release.payment_application_count == 0
      assert is_nil(before_release.provider_payment_id)
      assert is_nil(before_release.provider_payment_method_ref)

      send(first.pid, {ref, :release_claim})

      assert {:cancel,
              %{
                code: "RENEWAL_DISPATCH_UNAVAILABLE",
                meta: %{reason: :provider_revocation_fencing_unsupported}
              }} = Task.await(first, 15_000)

      after_release = identity!(fixture)
      assert after_release == before_release
      assert after_release.dispatch_state == "not_started"
      assert subscription_state!(fixture) == subscription_before

      assert [["active", 0]] ==
               Repo.query!(
                 "SELECT status, dunning_attempt_count FROM subscriptions WHERE id=$1",
                 [Ecto.UUID.dump!(fixture.subscription.id)]
               ).rows
    after
      send(first.pid, {ref, :release_claim})
      if second = Process.get(second_key), do: send(second.pid, {ref, :release_claim})
      :telemetry.detach(handler)
      Task.shutdown(first, :brutal_kill)
      if second = Process.delete(second_key), do: Task.shutdown(second, :brutal_kill)
      cleanup!(fixture)
    end
  end

  test "death after persisted checkout preparation preserves the same unavailable occurrence" do
    fixture = fixture!("prepared_crash")
    subscription_before = subscription_state!(fixture)
    ref = make_ref()
    parent = self()
    StripeAPIStub.stub_unexpected!("unfenced renewal must not contact Stripe")
    handler = {__MODULE__, ref, :prepared}

    :ok =
      :telemetry.attach(
        handler,
        [:store, :subscriptions, :renewal_attempt_before_processing],
        fn _, _, metadata, _ ->
          if metadata.subscription_id == fixture.subscription.id and
               Process.get({ref, :role}) == :crash do
            send(parent, {ref, :prepared, metadata, Repo.in_transaction?()})

            receive do
              {^ref, :release_prepared} -> :ok
            after
              15_000 -> raise "JC259 prepared barrier expired"
            end
          end
        end,
        nil
      )

    worker = start_worker(fixture, ref, :crash)

    try do
      assert_receive {^ref, :ready, :crash, _pg}, 5_000
      send(worker.pid, {ref, :go})
      assert_receive {^ref, :prepared, metadata, false}, 10_000
      prepared = identity!(fixture)
      assert prepared.attempt_id == metadata.renewal_attempt_id
      assert prepared.order_id == metadata.order_id
      assert prepared.payment_intent_id == metadata.payment_intent_id
      assert prepared.attempt_status == "processing"
      assert prepared.dispatch_state == "not_started"
      assert prepared.financial_outcome == "unresolved"
      assert prepared.collection_payment_intent_id == nil
      assert prepared.payment_intent_state == "created"
      assert prepared.dispatch_epoch == 1
      assert is_nil(prepared.reservation_generation_id)
      assert prepared.reservation_count == 0
      assert prepared.payment_application_count == 0
      assert is_nil(prepared.provider_payment_id)
      assert is_nil(prepared.provider_payment_method_ref)
      assert prepared.attempt_count == 1
      assert prepared.collection_count == 1
      assert prepared.payment_intent_count == 1
      Process.unlink(worker.pid)
      Process.exit(worker.pid, :kill)
      assert_receive {:DOWN, monitor, :process, pid, :killed}, 5_000
      assert monitor == worker.ref
      assert pid == worker.pid
      :telemetry.detach(handler)

      assert {:cancel,
              %{
                code: "RENEWAL_DISPATCH_UNAVAILABLE",
                meta: %{reason: :provider_revocation_fencing_unsupported}
              }} =
               ProcessSubscriptionRenewalWorker.perform(%Oban.Job{
                 args: %{"subscription_id" => fixture.subscription.id}
               })

      recovered = identity!(fixture)

      keys = [
        :attempt_id,
        :order_id,
        :collection_id,
        :payment_intent_id,
        :request_reference,
        :attempt_count,
        :collection_count,
        :payment_intent_count,
        :collection_ordinal
      ]

      assert Map.take(recovered, keys) == Map.take(prepared, keys)
      assert is_nil(recovered.collection_payment_intent_id)
      assert recovered.attempt_status == "processing"
      assert recovered.dispatch_state == "not_started"
      assert recovered.financial_outcome == "unresolved"
      assert recovered.payment_intent_state == "created"
      assert recovered.dispatch_epoch == 1
      assert is_nil(recovered.reservation_generation_id)
      assert recovered.reservation_count == 0
      assert recovered.payment_application_count == 0
      assert recovered == prepared
      assert subscription_state!(fixture) == subscription_before
    after
      send(worker.pid, {ref, :release_prepared})
      :telemetry.detach(handler)
      Task.shutdown(worker, :brutal_kill)
      cleanup!(fixture)
    end
  end

  defp start_worker(fixture, ref, role) do
    parent = self()

    Task.async(fn ->
      Repo.checkout(
        fn ->
          Process.put({ref, :role}, role)
          [[pg]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {ref, :ready, role, pg})

          receive do
            {^ref, :go} ->
              ProcessSubscriptionRenewalWorker.perform(%Oban.Job{
                args: %{"subscription_id" => fixture.subscription.id}
              })
          after
            15_000 -> {:error, :start_barrier_expired}
          end
        end,
        timeout: 45_000
      )
    end)
  end

  defp attach_claim_barrier!(ref, parent) do
    handler = {__MODULE__, ref, :claim}

    :ok =
      :telemetry.attach(
        handler,
        [:store, :repo, :query],
        fn _, _, metadata, _ ->
          observe_claim!(ref, parent, metadata)
        end,
        nil
      )

    handler
  end

  defp observe_claim!(ref, parent, metadata) do
    role = Process.get({ref, :role})

    query =
      "UPDATE renewal_attempts SET updated_at = $2 WHERE id = $1 AND status IN ('pending', 'failed') AND failure_code IS DISTINCT FROM 'RENEWAL_AUTHORITY_WITHDRAWN' AND updated_at = $3"

    if role in [:first, :second] and metadata.query == query and
         match?({:ok, %Postgrex.Result{num_rows: 1}}, metadata.result) do
      [id, stamp, previous] = metadata.params

      send(
        parent,
        {ref, :claim, role, Ecto.UUID.load!(id), stamp, previous, Repo.in_transaction?()}
      )

      await_claim_release(ref, role)
    end
  end

  defp await_claim_release(ref, :first) do
    receive do
      {^ref, :release_claim} -> :ok
    after
      15_000 -> raise "JC259 claim barrier expired"
    end
  end

  defp await_claim_release(_ref, _role), do: :ok

  defp identity!(fixture) do
    sql = """
    SELECT a.id::text, a.order_id::text, a.renewal_key, a.status,
           c.id::text, c.collection_ordinal, c.payment_intent_id::text,
           c.dispatch_state, c.financial_outcome,
           p.id::text, p.provider_request_reference, p.state::text,
           p.provider_payment_id, p.provider_payment_method_ref,
           c.dispatch_epoch, c.reservation_generation_id::text,
           (SELECT count(*) FROM inventory_reservations r WHERE r.order_id=a.order_id AND position(':renewal_collection:' in r.reservation_key)>0),
           (SELECT count(*) FROM payment_applications pa WHERE pa.order_id=a.order_id),
           (SELECT count(*) FROM renewal_attempts x WHERE x.subscription_id=a.subscription_id),
           (SELECT count(*) FROM renewal_collection_attempts x WHERE x.renewal_attempt_id=a.id),
           (SELECT count(*) FROM payment_intents x WHERE x.order_id=a.order_id)
    FROM renewal_attempts a
    JOIN renewal_collection_attempts c ON c.renewal_attempt_id=a.id
    JOIN payment_intents p ON p.order_id=a.order_id
      AND p.payment_intent_key='renewal-collection:' || c.id::text
    WHERE a.subscription_id=$1
    """

    [row] = Repo.query!(sql, [Ecto.UUID.dump!(fixture.subscription.id)]).rows

    keys = [
      :attempt_id,
      :order_id,
      :renewal_key,
      :attempt_status,
      :collection_id,
      :collection_ordinal,
      :collection_payment_intent_id,
      :dispatch_state,
      :financial_outcome,
      :payment_intent_id,
      :request_reference,
      :payment_intent_state,
      :provider_payment_id,
      :provider_payment_method_ref,
      :dispatch_epoch,
      :reservation_generation_id,
      :reservation_count,
      :payment_application_count,
      :attempt_count,
      :collection_count,
      :payment_intent_count
    ]

    Map.new(Enum.zip(keys, row))
  end

  defp subscription_state!(fixture) do
    [state] =
      Repo.query!(
        """
        SELECT status, billing_status_reason, past_due_since_at, failed_payment_boundary_at,
               dunning_attempt_count, next_retry_at, retry_suppressed_at,
               current_period_start_at, current_period_end_at, next_renewal_at,
               provider_customer_ref, provider_billing_ref, stored_payment_method_id,
               payment_method_setup_generation
        FROM subscriptions WHERE id=$1
        """,
        [Ecto.UUID.dump!(fixture.subscription.id)]
      ).rows

    state
  end

  defp fixture!(label) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    customer = SubscriptionsFixtures.create_customer!("jc259_#{label}_#{suffix}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 2_600,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    refs = %{
      provider_customer: "cus_jc259_#{suffix}",
      old_method: "pm_jc259_old_#{suffix}",
      new_method: "pm_jc259_new_#{suffix}"
    }

    created =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: refs.provider_customer,
        provider_billing_ref: refs.old_method,
        started_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :microsecond)
      })

    subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^created.subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    %{
      customer: customer,
      product: product,
      variant: variant,
      variant_plan: variant_plan,
      plan: plan,
      subscription: subscription,
      item: created.item,
      order: created.order,
      line_item: created.line_item,
      revision: created.revision,
      refs: refs,
      now: now
    }
  end

  defp cleanup!(fixture) do
    subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
    user_id = Ecto.UUID.dump!(fixture.customer.id)
    variant_id = Ecto.UUID.dump!(fixture.variant.id)
    plan_id = Ecto.UUID.dump!(fixture.plan.id)
    product_id = Ecto.UUID.dump!(fixture.product.id)

    case Repo.transaction(
           fn ->
             Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])

             Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!(
               "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
               [user_id]
             )

             Repo.query!(
               "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL, current_contract_change_id = NULL WHERE id = $1",
               [subscription_id]
             )

             Repo.query!(
               "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
             )

             try do
               Repo.query!(
                 "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
                 [subscription_id]
               )
             after
               Repo.query!(
                 "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
               )
             end

             Repo.query!(
               "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
               [user_id]
             )

             Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
               subscription_id
             ])

             Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

             Repo.query!(
               "DELETE FROM email_outboxes WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM fulfillment_orders WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!(
               "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
               [user_id]
             )

             Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
             Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])

             Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [
               variant_id
             ])

             Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
             Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
             Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
             Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
             Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
           end,
           timeout: 30_000
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> raise "unable to clean JC-259 fixture: #{inspect(reason)}"
    end
  end

  defp assert_test_database! do
    expected_database =
      System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test") <>
        (System.get_env("STORE_TEST_DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") || "")

    actual_database = Repo.config()[:database]

    unless Mix.env() == :test and actual_database == expected_database do
      raise "contention test database guard failed: MIX_ENV=#{inspect(Mix.env())}, " <>
              "configured_database=#{inspect(actual_database)}, expected_database=#{inspect(expected_database)}"
    end

    :ok
  end
end
