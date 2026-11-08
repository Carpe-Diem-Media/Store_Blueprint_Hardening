defmodule Store.Subscriptions.JC290PaymentMethodDispatchRaceTest do
  use ExUnit.Case, async: false
  @moduletag :real_connections
  @moduletag timeout: 60_000

  import Ash.Expr
  require Ash.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.Subscriptions.{PaymentMethodAuthorityGate, StoredPaymentMethod, Subscription}
  alias Store.SubscriptionsFixtures
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

  test "concurrent setup starts serialize and persist separate generations" do
    fixture = create_dispatch_fixture!("setup_start_race")
    ref = make_ref()
    parent = self()
    barrier_key = PaymentMethodAuthorityGate.binding_key(fixture.customer.id, :stripe)
    handler = attach_setup_start_barrier!(ref, parent, barrier_key)
    setup_tasks_key = {ref, :setup_tasks}
    provider_callbacks_key = {ref, :provider_callbacks}

    StripeAPIStub.stub_setup_intent(fn conn, params ->
      local_id = params["metadata[local_intent_id]"]
      backend_pid = Process.get({__MODULE__, ref, :setup_backend_pid})
      send(parent, {ref, :setup_provider_post, self(), backend_pid, local_id})

      receive do
        {^ref, :release_provider, ^local_id} -> :ok
        {^ref, :release_all_provider_posts} -> :ok
      after
        20_000 -> raise "JC290 setup provider barrier expired"
      end

      StripeAPIStub.json_response(conn, StripeAPIStub.setup_intent_response(params))
    end)

    first = start_setup_task(fixture, ref, :first)
    Process.put(setup_tasks_key, [first])

    try do
      assert_receive {^ref, :setup_lock_claimed, first_pg}, 10_000
      second = start_setup_task(fixture, ref, :second, self())
      Process.put(setup_tasks_key, [second | Process.get(setup_tasks_key)])
      assert_receive {^ref, :setup_backend, :second, second_pg}, 10_000
      refute first_pg == second_pg

      assert_eventually(fn ->
        Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
          first_pg,
          second_pg
        ]).rows == [[true]]
      end)

      send(first.pid, {ref, :release_setup_lock})

      assert_receive {^ref, :setup_provider_post, first_provider, ^first_pg, first_local_id},
                     10_000

      Process.put(provider_callbacks_key, [first_provider])

      assert [[nil]] ==
               Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid = $1", [
                 first_pg
               ]).rows

      assert_receive {^ref, :setup_provider_post, second_provider, ^second_pg, second_local_id},
                     10_000

      Process.put(provider_callbacks_key, [second_provider | Process.get(provider_callbacks_key)])

      assert [[nil]] ==
               Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid = $1", [
                 second_pg
               ]).rows

      committed_first = fetch_setup_intent!(first_local_id)
      committed_second = fetch_setup_intent!(second_local_id)

      assert committed_second.subscription_setup_generation ==
               committed_first.subscription_setup_generation + 1

      assert current_subscription!(fixture).payment_method_setup_generation ==
               committed_second.subscription_setup_generation

      send(first_provider, {ref, :release_provider, first_local_id})
      send(second_provider, {ref, :release_provider, second_local_id})
      assert {:ok, first_result} = Task.await(first, 20_000)
      assert {:ok, second_result} = Task.await(second, 20_000)

      first_intent = fetch_setup_intent!(first_result.payment_intent_id)
      second_intent = fetch_setup_intent!(second_result.payment_intent_id)
      first_generation = Map.get(first_intent, :subscription_setup_generation)
      second_generation = Map.get(second_intent, :subscription_setup_generation)

      assert first_intent.id != second_intent.id
      assert first_intent.payment_intent_key != second_intent.payment_intent_key
      assert is_integer(first_generation) and first_generation > 0
      assert second_generation == first_generation + 1

      assert first_intent.payment_intent_key ==
               "pm-update:v2:#{fixture.subscription.id}:#{first_generation}"

      assert second_intent.payment_intent_key ==
               "pm-update:v2:#{fixture.subscription.id}:#{second_generation}"
    after
      :telemetry.detach(handler)
      release_pending_setup_provider_posts(ref)

      for task <- Process.delete(setup_tasks_key) || [] do
        send(task.pid, {ref, :release_setup_lock})
        send(task.pid, {ref, :release_all_provider_posts})
        Task.shutdown(task, :brutal_kill)
      end

      for callback <- Process.delete(provider_callbacks_key) || [] do
        send(callback, {ref, :release_all_provider_posts})
      end

      cleanup_dispatch_fixture!(fixture)
    end
  end

  test "StoredPaymentMethod mutation waits on its resource-owned binding gate" do
    fixture = create_dispatch_fixture!("method_gate")
    parent = self()
    ref = make_ref()
    holder = hold_binding_gate(fixture, parent, ref)
    writer_key = {ref, :writer}

    try do
      assert_receive {^ref, :holder, holder_pid}, 3_000

      writer =
        Task.async(fn ->
          Repo.checkout(fn ->
            writer_pid = backend_pid!()
            send(parent, {ref, :writer, writer_pid})
            direct_method_write(fixture, :upsert_inactive)
          end)
        end)

      Process.put(writer_key, writer)

      assert_receive {^ref, :writer, writer_pid}, 3_000
      refute writer_pid == holder_pid
      assert_eventually(fn -> blocked_by?(holder_pid, writer_pid) end)
      send(holder.pid, {ref, :release})
      assert {:ok, method} = Task.await(writer, 5_000)
      assert method.status == :inactive
      assert_key_available(fixture)
    after
      send(holder.pid, {ref, :release})
      Task.shutdown(holder, 5_000)
      if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  test "Subscription binding mutation waits on its resource-owned gate" do
    fixture = create_dispatch_fixture!("subscription_gate")
    parent = self()
    ref = make_ref()
    holder = hold_binding_gate(fixture, parent, ref)
    writer_key = {ref, :writer}

    try do
      assert_receive {^ref, :holder, holder_pid}, 3_000

      writer =
        Task.async(fn ->
          Repo.checkout(fn ->
            writer_pid = backend_pid!()
            send(parent, {ref, :writer, writer_pid})
            subscription = current_subscription!(fixture)

            subscription
            |> Ash.Changeset.for_update(
              :set_provider_billing_reference,
              %{
                provider_customer_ref: fixture.refs.provider_customer,
                provider_billing_ref: fixture.refs.old_method,
                stored_payment_method_id: fixture.subscription.stored_payment_method_id
              },
              context: %{system?: true}
            )
            |> Ash.update(
              domain: Store.Subscriptions,
              authorize?: false,
              context: %{system?: true}
            )
          end)
        end)

      Process.put(writer_key, writer)

      assert_receive {^ref, :writer, writer_pid}, 3_000
      refute writer_pid == holder_pid
      assert_eventually(fn -> blocked_by?(holder_pid, writer_pid) end)
      send(holder.pid, {ref, :release})
      assert {:ok, subscription} = Task.await(writer, 5_000)
      assert subscription.provider_billing_ref == fixture.refs.old_method
      assert_key_available(fixture)
    after
      send(holder.pid, {ref, :release})
      Task.shutdown(holder, 5_000)
      if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  defp hold_binding_gate(fixture, parent, ref) do
    Task.async(fn ->
      Repo.checkout(fn ->
        hold_binding_transaction(fixture, parent, ref)
      end)
    end)
  end

  defp hold_binding_transaction(fixture, parent, ref) do
    Repo.transaction(fn ->
      assert :ok =
               PaymentMethodAuthorityGate.lock_binding_for_transaction(
                 fixture.customer.id,
                 :stripe
               )

      [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(parent, {ref, :holder, pid})

      receive do
        {^ref, :release} -> :ok
      after
        5_000 -> raise "binding gate barrier expired"
      end
    end)
  end

  defp direct_method_write(fixture, :upsert_inactive) do
    StoredPaymentMethod
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        user_id: fixture.customer.id,
        provider: :stripe,
        provider_customer_ref: fixture.refs.provider_customer,
        provider_payment_method_ref: fixture.refs.old_method,
        status: :inactive
      },
      context: %{system?: true}
    )
    |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp blocked_by?(holder_pid, writer_pid) do
    Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
      holder_pid,
      writer_pid
    ]).rows == [[true]]
  end

  defp assert_key_available(fixture) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert :ok =
                        PaymentMethodAuthorityGate.lock_binding_for_transaction(
                          fixture.customer.id,
                          :stripe
                        )

               :ok
             end)
  end

  defp attach_setup_start_barrier!(ref, parent, lock_key) do
    handler = {__MODULE__, ref, :setup_start}
    process_key = {__MODULE__, ref, :setup_lock_seen}
    owner_key = {__MODULE__, ref, :setup_lock_barrier_owner}

    :ok =
      :telemetry.attach(
        handler,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata.query || ""

          if String.contains?(query, "pg_advisory_xact_lock") and
               Enum.any?(metadata.params || [], &(&1 == lock_key)) and
               Process.get(owner_key) == true and
               Process.get(process_key) != true do
            Process.put(process_key, true)
            send(parent, {ref, :setup_lock_claimed, backend_pid!()})

            receive do
              {^ref, :release_setup_lock} -> :ok
            after
              15_000 -> raise "JC290 setup-start barrier expired"
            end
          end
        end,
        nil
      )

    handler
  end

  defp start_setup_task(fixture, ref, label, parent \\ self()) do
    Task.async(fn ->
      Repo.checkout(
        fn -> run_setup_start(fixture, ref, label, parent) end,
        timeout: 30_000
      )
    end)
  end

  defp run_setup_start(fixture, ref, label, parent) do
    backend_pid = backend_pid!()
    Process.put({__MODULE__, ref, :setup_lock_barrier_owner}, label == :first)
    Process.put({__MODULE__, ref, :setup_backend_pid}, backend_pid)
    if label == :second, do: send(parent, {ref, :setup_backend, label, backend_pid})

    input = %StartSubscriptionPaymentMethodUpdateInput{subscription_id: fixture.subscription.id}

    Facade.start_subscription_payment_method_update_for_user(
      fixture.customer,
      fixture.subscription.id,
      input
    )
  end

  defp release_pending_setup_provider_posts(ref) do
    receive do
      {^ref, :setup_provider_post, callback, _backend_pid, _local_id} ->
        send(callback, {ref, :release_all_provider_posts})
        release_pending_setup_provider_posts(ref)
    after
      0 ->
        :ok
    end
  end

  defp fetch_setup_intent!(id) do
    Store.Payments.PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

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

  defp current_subscription!(fixture) do
    Subscription
    |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
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

             Repo.query!(
               "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE subscription_id = $1)",
               [subscription_id]
             )

             Repo.query!("DELETE FROM payment_intents WHERE subscription_id = $1", [
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
end
