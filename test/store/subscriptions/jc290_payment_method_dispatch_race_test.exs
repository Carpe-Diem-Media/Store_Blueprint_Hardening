defmodule Store.Subscriptions.JC290PaymentMethodDispatchRaceTest do
  use ExUnit.Case, async: false
  @moduletag :real_connections
  @moduletag timeout: 60_000

  import Ash.Expr
  require Ash.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.{PaymentMethodAuthorityGate, StoredPaymentMethod, Subscription}
  alias Store.Subscriptions.Facade
  alias Store.SubscriptionsFixtures
  alias Store.Support.AshNotifications
  alias Store.TestSupport.StripeAPIStub

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

  test "a dispatch blocks replacement through POST and applies success after replacement" do
    fixture = create_dispatch_fixture!("dispatch_first")
    parent = self()
    ref = make_ref()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed, :released])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      send(parent, {ref, :post, params})
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)

    dispatcher = start_dispatch(fixture)
    writer_key = {ref, :writer_task}

    try do
      assert_receive {^ref, :claimed, dispatcher_beam, dispatcher_pg, ids, false}, 10_000

      assert [[nil]] ==
               Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid=$1", [dispatcher_pg]).rows

      assert reached_identity!(fixture).collection_id == ids.collection_attempt_id

      writer =
        Task.async(fn ->
          Repo.checkout(
            fn ->
              send(parent, {ref, :writer_backend, backend_pid!()})
              mutate_method!(fixture, :replace)
              send(parent, {ref, :writer_committed})
              :ok
            end,
            timeout: 30_000
          )
        end)

      Process.put(writer_key, writer)
      assert_receive {^ref, :writer_backend, writer_pg}, 3_000
      refute writer_pg == dispatcher_pg
      assert_writer_blocked!(ref, writer_pg, dispatcher_pg)
      send(dispatcher_beam, {ref, :release, :claimed})
      assert_receive {^ref, :post, params}, 10_000
      assert params["payment_method"] == fixture.refs.old_method
      assert params["customer"] == fixture.refs.provider_customer
      assert_receive {^ref, :released, released_beam, _pg, released_ids, false}, 10_000
      assert released_ids.payment_intent_id == ids.payment_intent_id
      assert_receive {^ref, :writer_committed}, 10_000
      assert :ok = Task.await(writer, 3_000)
      assert current_subscription!(fixture).provider_billing_ref == fixture.refs.new_method
      send(released_beam, {ref, :release, :released})
      assert {:ok, :processed} = Task.await(dispatcher, 10_000)
      exact = reached_identity!(fixture)
      assert exact.payment_intent_id == ids.payment_intent_id
      assert exact.financial_outcome == "verified_success"
      assert exact.intent_method == fixture.refs.old_method
      assert exact.order_state == "paid"
      assert current_subscription!(fixture).provider_billing_ref == fixture.refs.new_method
    after
      :telemetry.detach(handler)
      send(dispatcher.pid, {ref, :release, :claimed})
      send(dispatcher.pid, {ref, :release, :released})
      Task.shutdown(dispatcher, :brutal_kill)
      if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  test "replacement after a crash before the first POST prevents stale replay" do
    fixture = create_dispatch_fixture!("crash")
    ref = make_ref()
    parent = self()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      send(parent, {ref, :unexpected_post, params})

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    dispatcher = start_dispatch(fixture)

    try do
      assert_receive {^ref, :claimed, _beam, dispatcher_pg, ids, false}, 10_000
      before = reached_identity!(fixture)
      assert before.payment_intent_id == ids.payment_intent_id
      assert :atomics.get(posts, 1) == 0
      Process.unlink(dispatcher.pid)
      Process.exit(dispatcher.pid, :kill)
      assert_receive {:DOWN, monitor, :process, pid, :killed}, 3_000
      assert monitor == dispatcher.ref and pid == dispatcher.pid

      assert_eventually(fn ->
        Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [dispatcher_pg]).rows ==
          [[0]]
      end)

      :telemetry.detach(handler)
      mutate_method!(fixture, :replace)

      result =
        Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
          now: fixture.now
        )

      assert :atomics.get(posts, 1) == 0, "recovery POSTed the withdrawn captured method"
      assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} = result
      after_recovery = reached_identity!(fixture)

      assert Map.take(after_recovery, [
               :attempt_id,
               :collection_id,
               :payment_intent_id,
               :request_ref,
               :intent_method
             ]) ==
               Map.take(before, [
                 :attempt_id,
                 :collection_id,
                 :payment_intent_id,
                 :request_ref,
                 :intent_method
               ])

      assert after_recovery.dispatch_state == "may_have_been_reached"
      assert after_recovery.financial_outcome == "unresolved"
      assert after_recovery.attempt_count == 1
      refute_receive {^ref, :unexpected_post, _}, 0
    after
      :telemetry.detach(handler)
      send(dispatcher.pid, {ref, :release, :claimed})
      Task.shutdown(dispatcher, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  test "a due worker observes the exact in-flight payment after method revocation" do
    fixture = create_dispatch_fixture!("observe_revoked")
    ref = make_ref()
    parent = self()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      body = StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      send(parent, {ref, :submitted, body})
      StripeAPIStub.json_response(conn, body)
    end)

    try do
      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: fixture.now
               )

      assert_receive {^ref, :submitted, body}, 3_000
      before = reached_identity!(fixture)
      mutate_method!(fixture, :revoke)

      StripeAPIStub.stub_observation(fn conn ->
        assert conn.method == "GET", "revoked method started another charge request"
        assert conn.request_path == "/v1/payment_intents/#{body["id"]}"
        send(parent, {ref, :observed})
        StripeAPIStub.json_response(conn, Map.put(body, "status", "succeeded"))
      end)

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                 now: fixture.now
               )

      assert_receive {^ref, :observed}, 3_000
      after_recovery = reached_identity!(fixture)
      assert after_recovery.payment_intent_id == before.payment_intent_id
      assert after_recovery.collection_id == before.collection_id
      assert after_recovery.attempt_id == before.attempt_id
      assert after_recovery.financial_outcome == "verified_success"
      assert after_recovery.order_state == "paid"
      assert after_recovery.method_status == "revoked"
    after
      cleanup_dispatch_fixture!(fixture)
    end
  end

  defp start_dispatch(fixture) do
    Task.async(fn ->
      Repo.checkout(
        fn ->
          Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
            now: fixture.now
          )
        end,
        timeout: 60_000
      )
    end)
  end

  defp attach_dispatch_barrier!(fixture, ref, phases) do
    parent = self()
    handler = {__MODULE__, ref}
    events = Enum.map(phases, &[:store, :subscriptions, event_name(&1)])

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _, metadata, _ ->
          if metadata.subscription_id == fixture.subscription.id do
            phase =
              if List.last(event) == :renewal_charge_dispatch_claimed,
                do: :claimed,
                else: :released

            send(parent, {ref, phase, self(), backend_pid!(), metadata, Repo.in_transaction?()})

            receive do
              {^ref, :release, ^phase} -> :ok
            after
              15_000 -> raise "JC290 dispatch barrier expired"
            end
          end
        end,
        nil
      )

    handler
  end

  defp event_name(:claimed), do: :renewal_charge_dispatch_claimed
  defp event_name(:released), do: :renewal_charge_dispatch_released
  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp current_subscription!(fixture) do
    Subscription
    |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reached_identity!(fixture) do
    sql = """
    SELECT a.id::text, c.id::text, p.id::text, p.provider_request_reference,
           p.provider_payment_method_ref, c.dispatch_state, c.financial_outcome,
           o.state, m.status,
           (SELECT count(*) FROM renewal_attempts WHERE subscription_id=a.subscription_id)
    FROM renewal_attempts a JOIN renewal_collection_attempts c ON c.renewal_attempt_id=a.id
    JOIN payment_intents p ON p.id=c.payment_intent_id JOIN orders o ON o.id=p.order_id
    JOIN stored_payment_methods m ON m.user_id=o.user_id AND m.provider='stripe'
      AND m.provider_customer_ref=p.provider_customer_ref
      AND m.provider_payment_method_ref=p.provider_payment_method_ref
    WHERE a.subscription_id=$1::text::uuid
    """

    [row] = Repo.query!(sql, [fixture.subscription.id]).rows

    [
      :attempt_id,
      :collection_id,
      :payment_intent_id,
      :request_ref,
      :intent_method,
      :dispatch_state,
      :financial_outcome,
      :order_state,
      :method_status,
      :attempt_count
    ]
    |> Enum.zip(row)
    |> Map.new()
  end

  defp assert_writer_blocked!(ref, writer, dispatcher) do
    assert_eventually(fn ->
      receive do
        {^ref, :writer_committed} -> flunk("replacement committed before the actual charge POST")
      after
        0 -> :ok
      end

      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [dispatcher, writer]).rows ==
        [[true]]
    end)
  end

  defp assert_eventually(fun, remaining \\ 400) do
    cond do
      fun.() ->
        :ok

      remaining == 0 ->
        flunk("database condition did not become true")

      true ->
        Process.sleep(5)
        assert_eventually(fun, remaining - 1)
    end
  end

  defp create_dispatch_fixture!(label) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    customer = SubscriptionsFixtures.create_customer!("jc290_#{label}_#{suffix}")
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
      provider_customer: "cus_jc290_#{suffix}",
      old_method: "pm_jc290_old_#{suffix}",
      new_method: "pm_jc290_new_#{suffix}"
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

  defp cleanup_dispatch_fixture!(fixture) do
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
      {:error, reason} -> raise "unable to clean JC-290 fixture: #{inspect(reason)}"
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

  defp mutate_method!(fixture, :replace) do
    {:ok, {result, notifications}} =
      Repo.transaction(fn ->
        :ok =
          PaymentMethodAuthorityGate.lock_binding_for_transaction(fixture.customer.id, :stripe)

        current_subscription =
          Subscription
          |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
          |> Ash.read_one!(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true}
          )

        {:ok, method, method_notifications} =
          StoredPaymentMethod
          |> Ash.Changeset.for_create(
            :create_or_reuse,
            %{
              user_id: fixture.customer.id,
              provider: :stripe,
              provider_customer_ref: fixture.refs.provider_customer,
              provider_payment_method_ref: fixture.refs.new_method,
              status: :active,
              fingerprint: "fp_jc290_#{fixture.refs.new_method}"
            }, context: %{system?: true})
          |> Ash.create(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true},
            return_notifications?: true
          )

        {:ok, updated_subscription, subscription_notifications} =
          current_subscription
          |> Ash.Changeset.for_update(
            :set_provider_billing_reference,
            %{
              provider_customer_ref: fixture.refs.provider_customer,
              provider_billing_ref: fixture.refs.new_method,
              stored_payment_method_id: method.id
            }, context: %{system?: true})
          |> Ash.update(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true},
            return_notifications?: true
          )

        {{method, updated_subscription}, method_notifications ++ subscription_notifications}
      end)

    :ok =
      AshNotifications.notify_post_commit(notifications,
        context: %{flow: :jc290_test_method_replacement, subscription_id: fixture.subscription.id}
      )

    {method, updated_subscription} = result
    assert method.status == :active
    assert updated_subscription.provider_billing_ref == fixture.refs.new_method

    old_method =
      StoredPaymentMethod
      |> Ash.Query.filter(
        expr(
          user_id == ^fixture.customer.id and provider == :stripe and
            provider_customer_ref == ^fixture.refs.provider_customer and
            provider_payment_method_ref == ^fixture.refs.old_method
        )
      )
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert old_method.status == :active
    :ok
  end

  defp mutate_method!(fixture, :revoke) do
    {:ok, {result, notifications}} =
      Repo.transaction(fn ->
        :ok =
          PaymentMethodAuthorityGate.lock_binding_for_transaction(fixture.customer.id, :stripe)

        current_subscription =
          Subscription
          |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
          |> Ash.read_one!(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true}
          )

        method =
          StoredPaymentMethod
          |> Ash.Query.filter(
            expr(
              user_id == ^fixture.customer.id and provider == :stripe and
                provider_customer_ref == ^fixture.refs.provider_customer and
                provider_payment_method_ref == ^fixture.refs.old_method
            )
          )
          |> Ash.read_one!(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true}
          )

        {:ok, revoked_method, method_notifications} =
          method
          |> Ash.Changeset.for_update(:mark_revoked, %{}, context: %{system?: true})
          |> Ash.update(
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true},
            return_notifications?: true
          )

        {{revoked_method, current_subscription}, method_notifications}
      end)

    :ok =
      AshNotifications.notify_post_commit(notifications,
        context: %{flow: :jc290_test_method_revocation, subscription_id: fixture.subscription.id}
      )

    {method, _current_subscription} = result
    assert method.status == :revoked
    :ok
  end
end
