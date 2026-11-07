defmodule Store.Subscriptions.JC290PaymentMethodDispatchRaceTest do
  use ExUnit.Case, async: false
  @moduletag :real_connections
  @moduletag timeout: 60_000

  import Ash.Expr
  require Ash.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Payments.WebhookReceipt
  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Facade.StaleWrite
  alias Store.Subscriptions.{PaymentMethodAuthorityGate, StoredPaymentMethod, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.Support.AshNotifications
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessWebhookReceiptWorker

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

      assert_dispatch_locks!(
        dispatcher_pg,
        PaymentMethodAuthorityGate.binding_key(fixture.customer.id, :stripe),
        PaymentMethodAuthorityGate.method_key(
          :stripe,
          fixture.refs.provider_customer,
          fixture.refs.old_method
        )
      )

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

  @tag :jc290_topology_correction
  test "unsupported pool modes leave due renewal unclaimed and make no provider request" do
    fixture = create_dispatch_fixture!("unsupported_pool_mode")
    previous_mode = Application.fetch_env(:store, :database_pool_mode)
    initial_subscription = current_subscription!(fixture)
    parent = self()
    ref = make_ref()
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      send(parent, {ref, :provider_post, params})
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)

    try do
      for mode <- ["transaction", "unsupported", nil] do
        Application.put_env(:store, :database_pool_mode, mode)

        for _ <- 1..2 do
          assert {:error,
                  %Store.Support.Errors.Error{
                    code: "RENEWAL_DISPATCH_UNAVAILABLE",
                    meta: %{reason: :unsupported_database_pool_mode}
                  }} =
                   Facade.process_due_subscription_renewal_for_system(
                     fixture.subscription.id,
                     now: fixture.now
                   )
        end

        assert :atomics.get(posts, 1) == 0
        refute_receive {^ref, :provider_post, _params}, 0

        assert current_subscription!(fixture)
               |> Map.take([
                 :status,
                 :billing_status_reason,
                 :past_due_since_at,
                 :failed_payment_boundary_at,
                 :dunning_attempt_count,
                 :next_retry_at,
                 :retry_suppressed_at,
                 :provider_customer_ref,
                 :provider_billing_ref,
                 :stored_payment_method_id
               ]) ==
                 Map.take(initial_subscription, [
                   :status,
                   :billing_status_reason,
                   :past_due_since_at,
                   :failed_payment_boundary_at,
                   :dunning_attempt_count,
                   :next_retry_at,
                   :retry_suppressed_at,
                   :provider_customer_ref,
                   :provider_billing_ref,
                   :stored_payment_method_id
                 ])

        rows =
          Repo.query!(
            """
            SELECT c.dispatch_state, c.financial_outcome
            FROM renewal_attempts a
            JOIN renewal_collection_attempts c ON c.renewal_attempt_id = a.id
            WHERE a.subscription_id = $1::text::uuid
            """,
            [fixture.subscription.id]
          ).rows

        assert rows != []

        assert Enum.all?(rows, fn [dispatch_state, financial_outcome] ->
                 dispatch_state == "not_started" and financial_outcome == "unresolved"
               end)
      end
    after
      case previous_mode do
        {:ok, value} -> Application.put_env(:store, :database_pool_mode, value)
        :error -> Application.delete_env(:store, :database_pool_mode)
      end

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

  test "not-due recovery keeps an unobservable same-method request unresolved" do
    fixture = create_dispatch_fixture!("not_due_replay")
    ref = make_ref()
    parent = self()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      send(parent, {ref, :post, params})

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "succeeded"})
      )
    end)

    dispatcher = start_dispatch(fixture)

    try do
      assert_receive {^ref, :claimed, _beam, _pg, _ids, false}, 10_000
      before = reached_identity!(fixture)
      Process.unlink(dispatcher.pid)
      Process.exit(dispatcher.pid, :kill)
      assert_receive {:DOWN, monitor, :process, pid, :killed}, 3_000
      assert monitor == dispatcher.ref and pid == dispatcher.pid
      :telemetry.detach(handler)

      recovery_now = DateTime.add(fixture.subscription.next_renewal_at, -1, :microsecond)

      assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
               Facade.process_due_subscription_renewal_for_system(
                 fixture.subscription.id,
                 now: recovery_now
               )

      assert :atomics.get(posts, 1) == 0
      refute_receive {^ref, :post, _params}, 0

      after_recovery = reached_identity!(fixture)
      assert after_recovery.attempt_id == before.attempt_id
      assert after_recovery.collection_id == before.collection_id
      assert after_recovery.payment_intent_id == before.payment_intent_id
      assert after_recovery.financial_outcome == "unresolved"
    after
      :telemetry.detach(handler)
      send(dispatcher.pid, {ref, :release, :claimed})
      Task.shutdown(dispatcher, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  for mutation <- [:replace, :revoke], status <- ["succeeded", "canceled"] do
    @tag :jc290_matrix
    test "dispatch first with #{mutation} preserves exact #{status} evidence" do
      run_dispatch_evidence_case!(unquote(mutation), unquote(status))
    end
  end

  for mutation <- [:replace, :revoke] do
    @tag :jc290_matrix
    test "#{mutation} wins before the dispatch claim" do
      fixture = create_dispatch_fixture!("writer_first")
      ref = make_ref()
      parent = self()
      handler = {__MODULE__, ref}
      posts = :atomics.new(1, [])

      :ok =
        :telemetry.attach(
          handler,
          [:store, :subscriptions, :renewal_charge_dispatch_check],
          fn _, _, ids, _ ->
            if ids.subscription_id == fixture.subscription.id do
              send(parent, {ref, :before_claim, self(), ids})

              receive do
                {^ref, :resume} -> :ok
              after
                10_000 -> raise "pre-claim barrier expired"
              end
            end
          end,
          nil
        )

      StripeAPIStub.stub_payment_intent(fn conn, params ->
        :atomics.add(posts, 1, 1)
        send(parent, {ref, :post_params, params})
        StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
      end)

      task = start_dispatch(fixture)

      try do
        assert_receive {^ref, :before_claim, beam, ids}, 10_000
        mutate_method!(fixture, unquote(mutation))
        send(beam, {ref, :resume})
        result = Task.await(task, 10_000)

        if unquote(mutation) == :replace do
          assert {:ok, :processed} = result
          assert_receive {^ref, :post_params, params}, 3_000
          assert params["payment_method"] == fixture.refs.new_method
          exact = reached_identity!(fixture)
          assert exact.attempt_id == ids.renewal_attempt_id
          assert exact.payment_intent_id == ids.payment_intent_id
          assert exact.attempt_count == 1
          assert :atomics.get(posts, 1) == 1
        else
          assert {:error, %{code: "STALE_RECORD"}} = result
          assert :atomics.get(posts, 1) == 0

          assert [["not_started", "unresolved", nil]] ==
                   Repo.query!(
                     "SELECT c.dispatch_state,c.financial_outcome,c.payment_intent_id FROM renewal_collection_attempts c JOIN renewal_attempts a ON a.id=c.renewal_attempt_id WHERE a.subscription_id=$1::text::uuid",
                     [fixture.subscription.id]
                   ).rows

          assert current_subscription!(fixture).dunning_attempt_count ==
                   fixture.subscription.dunning_attempt_count
        end
      after
        :telemetry.detach(handler)
        send(task.pid, {ref, :resume})
        Task.shutdown(task, :brutal_kill)
        cleanup_dispatch_fixture!(fixture)
      end
    end
  end

  @tag :jc290_matrix
  test "every direct StoredPaymentMethod mutation waits on the dispatch binding gate" do
    for action <- [
          :create,
          :upsert_active,
          :upsert_inactive,
          :upsert_revoked,
          :mark_active,
          :mark_inactive,
          :mark_revoked
        ] do
      fixture = create_dispatch_fixture!("action_#{action}")
      parent = self()
      ref = make_ref()

      identity = %{
        provider: :stripe,
        customer_ref: fixture.refs.provider_customer,
        method_ref: fixture.refs.old_method
      }

      holder =
        Task.async(fn ->
          PaymentMethodAuthorityGate.with_dispatch_session_gates(
            fixture.customer.id,
            :stripe,
            fn -> {:ok, identity} end,
            fn _, proof ->
              send(parent, {ref, :held, proof.backend_pid})

              receive do
                {^ref, :release} -> :ok
              after
                10_000 -> raise "action gate barrier expired"
              end
            end
          )
        end)

      writer_key = {ref, :writer}

      try do
        assert_receive {^ref, :held, holder_pg}, 3_000

        writer =
          Task.async(fn ->
            Repo.checkout(fn ->
              send(parent, {ref, :writer_pg, backend_pid!()})
              result = direct_method_write(fixture, action)
              send(parent, {ref, :mutation_finished})
              result
            end)
          end)

        Process.put(writer_key, writer)
        assert_receive {^ref, :writer_pg, writer_pg}, 3_000
        refute writer_pg == holder_pg

        assert_eventually(fn ->
          receive do
            {^ref, :mutation_finished} -> flunk("#{action} bypassed its resource gate")
          after
            0 -> :ok
          end

          Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
            holder_pg,
            writer_pg
          ]).rows == [[true]]
        end)

        send(holder.pid, {ref, :release})
        assert :ok = Task.await(holder, 3_000)
        assert {:ok, _method} = Task.await(writer, 3_000)
      after
        send(holder.pid, {ref, :release})
        Task.shutdown(holder, :brutal_kill)
        if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
        cleanup_dispatch_fixture!(fixture)
      end
    end
  end

  @tag :jc290_matrix
  test "a stale direct binding writer cannot overwrite the replacement" do
    fixture = create_dispatch_fixture!("stale_binding")

    try do
      stale = current_subscription!(fixture)
      mutate_method!(fixture, :replace)
      winner = current_subscription!(fixture)
      assert winner.aggregate_version == stale.aggregate_version + 1

      result =
        stale
        |> Ash.Changeset.for_update(
          :set_provider_billing_reference,
          %{
            provider_customer_ref: stale.provider_customer_ref,
            provider_billing_ref: stale.provider_billing_ref,
            stored_payment_method_id: stale.stored_payment_method_id
          },
          context: %{system?: true}
        )
        |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

      assert {:error, error} = result
      assert StaleWrite.stale_record_error?(error)

      assert current_subscription!(fixture).stored_payment_method_id ==
               winner.stored_payment_method_id

      assert current_subscription!(fixture).aggregate_version == winner.aggregate_version
    after
      cleanup_dispatch_fixture!(fixture)
    end
  end

  @tag :jc290_matrix
  test "an unrelated customer can renew while another dispatch is paused" do
    first = create_dispatch_fixture!("unrelated_first")
    other = create_dispatch_fixture!("unrelated_other")
    ref = make_ref()
    handler = attach_dispatch_barrier!(first, ref, [:claimed])
    task = start_dispatch(first)

    try do
      assert_receive {^ref, :claimed, beam, _pg, _ids, false}, 10_000

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(other.subscription.id,
                 now: other.now
               )

      assert reached_identity!(other).financial_outcome == "verified_success"
      send(beam, {ref, :release, :claimed})
      assert {:ok, :processed} = Task.await(task, 10_000)
    after
      :telemetry.detach(handler)
      send(task.pid, {ref, :release, :claimed})
      Task.shutdown(task, :brutal_kill)
      cleanup_dispatch_fixture!(first)
      cleanup_dispatch_fixture!(other)
    end
  end

  @tag :jc290_capacity_correction
  test "bounded held renewals leave capacity for webhook and binding writes twice" do
    pool_size = Repo.config()[:pool_size]
    assert pool_size >= 4
    holder_count = min(4, pool_size - 2)

    for repetition <- 1..2 do
      run_capacity_liveness_repetition!(repetition, holder_count)
    end
  end

  for mutation <- [:replace, :revoke], route <- [:due, :not_due] do
    @tag :jc290_matrix
    test "crashed dispatch with #{mutation} observes only on the #{route} route" do
      fixture = create_dispatch_fixture!("crash_matrix")
      ref = make_ref()
      handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
      posts = :atomics.new(1, [])

      StripeAPIStub.stub_payment_intent(fn conn, params ->
        :atomics.add(posts, 1, 1)

        StripeAPIStub.json_response(
          conn,
          StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
        )
      end)

      task = start_dispatch(fixture)

      try do
        assert_receive {^ref, :claimed, _beam, pg, _ids, false}, 10_000
        exact = reached_identity!(fixture)
        Process.unlink(task.pid)
        Process.exit(task.pid, :kill)
        assert_receive {:DOWN, monitor, :process, pid, :killed}, 3_000
        assert monitor == task.ref and pid == task.pid

        assert_eventually(fn ->
          Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [pg]).rows == [[0]]
        end)

        :telemetry.detach(handler)
        mutate_method!(fixture, unquote(mutation))
        # Select the not-due recovery branch with the facade's explicit clock input.
        now =
          if unquote(route) == :due,
            do: fixture.now,
            else: DateTime.add(fixture.subscription.next_renewal_at, -1, :microsecond)

        assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
                 Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                   now: now
                 )

        assert :atomics.get(posts, 1) == 0
        after_recovery = reached_identity!(fixture)

        assert Map.take(after_recovery, [
                 :attempt_id,
                 :collection_id,
                 :payment_intent_id,
                 :request_ref,
                 :intent_method
               ]) ==
                 Map.take(exact, [
                   :attempt_id,
                   :collection_id,
                   :payment_intent_id,
                   :request_ref,
                   :intent_method
                 ])

        assert after_recovery.attempt_count == 1
        assert after_recovery.financial_outcome == "unresolved"
      after
        :telemetry.detach(handler)
        send(task.pid, {ref, :release, :claimed})
        Task.shutdown(task, :brutal_kill)
        cleanup_dispatch_fixture!(fixture)
      end
    end
  end

  defp direct_method_write(fixture, action) do
    opts = [domain: Store.Subscriptions, authorize?: false, context: %{system?: true}]

    if action in [:create, :upsert_active, :upsert_inactive, :upsert_revoked] do
      status =
        case action do
          :upsert_inactive -> :inactive
          :upsert_revoked -> :revoked
          _ -> :active
        end

      ref = if action == :create, do: fixture.refs.new_method, else: fixture.refs.old_method

      StoredPaymentMethod
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          user_id: fixture.customer.id,
          provider: :stripe,
          provider_customer_ref: fixture.refs.provider_customer,
          provider_payment_method_ref: ref,
          status: status
        },
        context: %{system?: true}
      )
      |> Ash.create(opts)
    else
      method =
        StoredPaymentMethod
        |> Ash.Query.filter(expr(id == ^fixture.subscription.stored_payment_method_id))
        |> Ash.read_one!(opts)

      method
      |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
      |> Ash.update(opts)
    end
  end

  defp run_dispatch_evidence_case!(mutation, status) do
    fixture = create_dispatch_fixture!("evidence_matrix")
    parent = self()
    ref = make_ref()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed, :released])
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      send(parent, {ref, :post_entered, params})

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => status})
      )
    end)

    task = start_dispatch(fixture)
    writer_key = {ref, :writer}

    try do
      assert_receive {^ref, :claimed, beam, pg, ids, false}, 10_000

      writer =
        Task.async(fn ->
          Repo.checkout(fn ->
            send(parent, {ref, :writer_backend, backend_pid!()})
            mutate_method!(fixture, mutation)
            send(parent, {ref, :writer_committed})
            :ok
          end)
        end)

      Process.put(writer_key, writer)
      assert_receive {^ref, :writer_backend, writer_pg}, 3_000
      assert_writer_blocked!(ref, writer_pg, pg)
      send(beam, {ref, :release, :claimed})
      assert_receive {^ref, :post_entered, params}, 10_000
      assert params["payment_method"] == fixture.refs.old_method
      assert_receive {^ref, :released, released_beam, _pg, released_ids, false}, 10_000
      assert released_ids.payment_intent_id == ids.payment_intent_id
      assert_receive {^ref, :writer_committed}, 3_000
      assert :ok = Task.await(writer, 3_000)
      send(released_beam, {ref, :release, :released})
      result = Task.await(task, 10_000)

      if status == "succeeded" do
        assert {:ok, :processed} = result
      else
        assert {:error, %{code: "PAYMENT_FAILED"}} = result
      end

      exact = reached_identity!(fixture)

      expected =
        if status == "succeeded",
          do: "verified_success",
          else: "verified_terminal_financial_non_success"

      assert exact.financial_outcome == expected
      assert exact.payment_intent_id == ids.payment_intent_id
      assert exact.collection_id == ids.collection_attempt_id
      assert exact.attempt_count == 1
      assert exact.intent_method == fixture.refs.old_method
      assert :atomics.get(posts, 1) == 1
      current = current_subscription!(fixture)

      if mutation == :replace do
        assert current.provider_billing_ref == fixture.refs.new_method
        assert exact.method_status == "active"
      else
        assert current.provider_billing_ref == fixture.refs.old_method
        assert exact.method_status == "revoked"
      end

      # A call before the scheduled retry time cannot authorize a new collection.
      :telemetry.detach(handler)
      current_before_recovery = current_subscription!(fixture)

      recovery_now =
        case current_before_recovery.next_retry_at do
          %DateTime{} = next_retry_at -> DateTime.add(next_retry_at, -1, :microsecond)
          nil -> fixture.now
        end

      _ =
        Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
          now: recovery_now
        )

      assert :atomics.get(posts, 1) == 1
      after_recovery = reached_identity!(fixture)
      assert after_recovery.attempt_id == exact.attempt_id
      assert after_recovery.collection_id == exact.collection_id
      assert after_recovery.payment_intent_id == exact.payment_intent_id
      assert after_recovery.financial_outcome == expected
      assert after_recovery.attempt_count == 1
    after
      :telemetry.detach(handler)
      send(task.pid, {ref, :release, :claimed})
      send(task.pid, {ref, :release, :released})
      Task.shutdown(task, :brutal_kill)
      if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  @tag :jc290_matrix
  test "losing the owned session after claim prevents provider invocation" do
    fixture = create_dispatch_fixture!("connection_lost")
    ref = make_ref()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)

    task = start_dispatch(fixture)

    try do
      assert_receive {^ref, :claimed, beam, pg, ids, false}, 10_000
      Process.unlink(task.pid)
      assert [[true]] == Repo.query!("SELECT pg_terminate_backend($1::integer)", [pg]).rows
      send(beam, {ref, :release, :claimed})
      result = Task.yield(task, 5_000)
      refute is_nil(result), "dispatch did not stop after losing its database session"
      assert :atomics.get(posts, 1) == 0
      exact = reached_identity!(fixture)
      assert exact.payment_intent_id == ids.payment_intent_id
      assert exact.dispatch_state == "may_have_been_reached"
      assert exact.financial_outcome == "unresolved"

      assert_eventually(fn ->
        Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [pg]).rows == [[0]]
      end)
    after
      :telemetry.detach(handler)
      send(task.pid, {ref, :release, :claimed})
      Task.shutdown(task, :brutal_kill)
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
          await_dispatch_event(fixture, ref, parent, event, metadata)
        end,
        nil
      )

    handler
  end

  defp await_dispatch_event(fixture, ref, parent, event, metadata) do
    if metadata.subscription_id == fixture.subscription.id do
      phase =
        if List.last(event) == :renewal_charge_dispatch_claimed, do: :claimed, else: :released

      send(parent, {ref, phase, self(), backend_pid!(), metadata, Repo.in_transaction?()})

      receive do
        {^ref, :release, ^phase} -> :ok
      after
        15_000 -> raise "JC290 dispatch barrier expired"
      end
    end
  end

  defp event_name(:claimed), do: :renewal_charge_dispatch_claimed
  defp event_name(:released), do: :renewal_charge_dispatch_released
  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp assert_dispatch_locks!(backend_pid, binding_key, method_key) do
    <<binding_high::unsigned-big-32, binding_low::unsigned-big-32>> =
      <<binding_key::signed-big-64>>

    <<method_high::unsigned-big-32, method_low::unsigned-big-32>> =
      <<method_key::signed-big-64>>

    sql = """
    SELECT count(*) FROM pg_locks
    WHERE locktype = 'advisory' AND pid = $1::integer AND granted
      AND objsubid = 1
      AND ((classid::bigint = $2::bigint AND objid::bigint = $3::bigint)
        OR (classid::bigint = $4::bigint AND objid::bigint = $5::bigint))
    """

    assert [[2]] ==
             Repo.query!(sql, [backend_pid, binding_high, binding_low, method_high, method_low]).rows
  end

  defp current_subscription!(fixture) do
    Subscription
    |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp run_capacity_liveness_repetition!(repetition, holder_count) do
    ref = make_ref()
    Process.put({ref, :fixtures}, [])
    Process.put({ref, :tasks}, [])
    Process.put({ref, :post_handles}, [])
    Process.put({ref, :receipt}, nil)

    try do
      source = track_capacity_fixture!(ref, "capacity_source_#{repetition}")
      writer_fixture = track_capacity_fixture!(ref, "capacity_writer_#{repetition}")

      holders =
        for index <- 1..holder_count do
          track_capacity_fixture!(ref, "capacity_holder_#{repetition}_#{index}")
        end

      parent = self()

      StripeAPIStub.stub_payment_intent(fn conn, params ->
        customer_ref = params["customer"]

        case Enum.find(holders, &(&1.refs.provider_customer == customer_ref)) do
          nil ->
            StripeAPIStub.json_response(
              conn,
              StripeAPIStub.payment_intent_response(params, %{
                "status" => "processing",
                "amount_received" => 0
              })
            )

          fixture ->
            local_id = params["metadata[local_intent_id]"]
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {ref, :held_post, self(), customer_ref, backend_pid, local_id, params})

            receive do
              {^ref, :release_post, ^local_id} ->
                body = StripeAPIStub.payment_intent_response(params, %{"status" => "succeeded"})
                send(parent, {ref, :provider_response, customer_ref, body["id"]})
                StripeAPIStub.json_response(conn, body)
            after
              20_000 -> raise "JC290 capacity POST barrier expired for #{fixture.subscription.id}"
            end
        end
      end)

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(source.subscription.id,
                 now: source.now
               )

      source_identity = reached_identity!(source)

      [[provider_payment_id, amount_minor, currency]] =
        Repo.query!(
          "SELECT p.provider_payment_id, o.grand_total_minor, o.currency_code FROM payment_intents p JOIN orders o ON o.id=p.order_id WHERE p.id=$1::text::uuid",
          [source_identity.payment_intent_id]
        ).rows

      assert is_binary(provider_payment_id) and provider_payment_id != ""
      assert source_identity.financial_outcome == "unresolved"
      event_id = "evt_jc290_capacity_#{repetition}_#{Ecto.UUID.generate()}"

      receipt =
        WebhookReceipt
        |> Ash.Changeset.for_create(:ingest, %{
          provider: "stripe",
          provider_event_id: event_id,
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body:
            Jason.encode!(%{
              "id" => event_id,
              "created" => DateTime.to_unix(source.now),
              "livemode" => false,
              "type" => "payment_intent.succeeded",
              "data" => %{
                "object" => %{
                  "id" => provider_payment_id,
                  "amount_received" => amount_minor,
                  "currency" => String.downcase(currency),
                  "livemode" => false,
                  "metadata" => %{"local_intent_id" => source_identity.payment_intent_id},
                  "status" => "succeeded"
                }
              }
            }),
          headers: %{"content-type" => ["application/json"]}
        })
        |> Ash.create!(domain: Store.Payments, authorize?: false)

      Process.put({ref, :receipt}, receipt)

      active_method =
        StoredPaymentMethod
        |> Ash.Changeset.for_create(
          :create_or_reuse,
          %{
            user_id: writer_fixture.customer.id,
            provider: :stripe,
            provider_customer_ref: writer_fixture.refs.provider_customer,
            provider_payment_method_ref: writer_fixture.refs.new_method,
            status: :active,
            fingerprint: "fp_jc290_#{writer_fixture.refs.new_method}"
          },
          context: %{system?: true}
        )
        |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

      renewal_tasks =
        Enum.map(holders, fn fixture ->
          task =
            Task.async(fn ->
              Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
                now: fixture.now
              )
            end)

          track_capacity_task!(ref, task)
          {fixture, task}
        end)

      held_posts =
        Enum.reduce(1..holder_count, %{}, fn _, acc ->
          assert_receive {^ref, :held_post, callback_pid, customer_ref, backend_pid, local_id,
                          params},
                         10_000

          Process.put({ref, :post_handles}, [
            {callback_pid, backend_pid, customer_ref, local_id}
            | Process.get({ref, :post_handles})
          ])

          assert Map.has_key?(acc, customer_ref) == false
          fixture = Enum.find(holders, &(&1.refs.provider_customer == customer_ref))
          assert fixture
          assert params["payment_method"] == fixture.refs.old_method
          assert params["customer"] == fixture.refs.provider_customer

          [[renewal_total, renewal_currency]] =
            Repo.query!(
              "SELECT o.grand_total_minor, o.currency_code FROM payment_intents p JOIN orders o ON o.id=p.order_id WHERE p.id=$1::text::uuid",
              [local_id]
            ).rows

          assert params["amount"] == Integer.to_string(renewal_total)
          assert params["currency"] == String.downcase(renewal_currency)

          assert [[nil]] ==
                   Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid=$1", [
                     backend_pid
                   ]).rows

          assert_dispatch_locks!(
            backend_pid,
            PaymentMethodAuthorityGate.binding_key(fixture.customer.id, :stripe),
            PaymentMethodAuthorityGate.method_key(
              :stripe,
              fixture.refs.provider_customer,
              fixture.refs.old_method
            )
          )

          Map.put(acc, customer_ref, %{
            fixture: fixture,
            backend_pid: backend_pid,
            local_id: local_id
          })
        end)

      assert MapSet.new(Map.keys(held_posts)) ==
               MapSet.new(Enum.map(holders, & &1.refs.provider_customer))

      assert length(Enum.uniq(Enum.map(Map.values(held_posts), & &1.backend_pid))) == holder_count

      primary_metrics = primary_pool_metrics!()
      assert primary_metrics.ready_conn_count >= 2
      assert primary_metrics.checkout_queue_length == 0

      worker =
        start_capacity_operation!(ref, fn ->
          ProcessWebhookReceiptWorker.perform(%Oban.Job{
            args: %{"webhook_receipt_id" => receipt.id}
          })
        end)

      writer =
        start_capacity_operation!(ref, fn ->
          Repo.checkout(fn ->
            current = current_subscription!(writer_fixture)

            {:ok, updated, notifications} =
              current
              |> Ash.Changeset.for_update(
                :set_provider_billing_reference,
                %{
                  provider_customer_ref: writer_fixture.refs.provider_customer,
                  provider_billing_ref: writer_fixture.refs.new_method,
                  stored_payment_method_id: active_method.id
                },
                context: %{system?: true}
              )
              |> Ash.update(
                domain: Store.Subscriptions,
                authorize?: false,
                context: %{system?: true},
                return_notifications?: true
              )

            :ok =
              AshNotifications.notify_post_commit(notifications,
                context: %{flow: :jc290_capacity_writer, subscription_id: updated.id}
              )

            updated
          end)
        end)

      assert {:ok, webhook_measurements} = Task.await(worker, 10_000)
      {writer_result, binding_measurements} = Task.await(writer, 10_000)
      assert writer_result.provider_billing_ref == writer_fixture.refs.new_method
      assert reached_identity!(source).financial_outcome == "verified_success"
      assert Enum.all?(renewal_tasks, fn {_fixture, task} -> Process.alive?(task.pid) end)

      IO.puts(
        Jason.encode!(%{
          tag: "JC290_BOUNDED_CAPACITY_LIVENESS",
          repetition: repetition,
          held_direct_facade_renewals: holder_count,
          primary_pool_ready_connections_while_held: primary_metrics.ready_conn_count,
          primary_pool_checkout_queue_while_held: primary_metrics.checkout_queue_length,
          webhook: webhook_measurements,
          binding_write: binding_measurements,
          scope: "one node, stubbed provider requests, no Oban producer or network timeout"
        })
      )

      release_capacity_posts!(ref)

      provider_ids =
        Enum.reduce(1..holder_count, %{}, fn _, acc ->
          assert_receive {^ref, :provider_response, customer_ref, provider_payment_id}, 10_000
          Map.put(acc, customer_ref, provider_payment_id)
        end)

      Enum.each(renewal_tasks, fn {fixture, task} ->
        assert {:ok, :processed} = Task.await(task, 15_000),
               "renewal #{fixture.subscription.id} did not finish"
      end)

      Enum.each(holders, fn fixture ->
        post = Map.fetch!(held_posts, fixture.refs.provider_customer)
        exact = reached_identity!(fixture)
        assert exact.payment_intent_id == post.local_id

        [[provider_payment_id]] =
          Repo.query!("SELECT provider_payment_id FROM payment_intents WHERE id=$1::text::uuid", [
            post.local_id
          ]).rows

        assert provider_payment_id == Map.fetch!(provider_ids, fixture.refs.provider_customer)
        assert exact.financial_outcome == "verified_success"
        assert exact.intent_method == fixture.refs.old_method
      end)

      Enum.each(holders, &assert_dispatch_locks_absent!/1)

      assert primary_pool_metrics!() == %{
               ready_conn_count: Repo.config()[:pool_size],
               checkout_queue_length: 0
             }
    after
      release_capacity_posts!(ref)
      Enum.each(Process.get({ref, :tasks}, []), &Task.shutdown(&1, 3_000))

      if receipt = Process.get({ref, :receipt}),
        do: Repo.query!("DELETE FROM webhook_receipts WHERE id=$1::text::uuid", [receipt.id])

      Enum.each(Process.get({ref, :fixtures}, []), &cleanup_dispatch_fixture!/1)
      Process.delete({ref, :fixtures})
      Process.delete({ref, :tasks})
      Process.delete({ref, :post_handles})
      Process.delete({ref, :receipt})
    end
  end

  defp track_capacity_fixture!(ref, label) do
    fixture = create_dispatch_fixture!(label)
    Process.put({ref, :fixtures}, [fixture | Process.get({ref, :fixtures})])
    fixture
  end

  defp track_capacity_task!(ref, task) do
    Process.put({ref, :tasks}, [task | Process.get({ref, :tasks})])
    task
  end

  defp start_capacity_operation!(ref, fun) do
    task =
      Task.async(fn ->
        started = System.monotonic_time()
        {result, stats} = RepoStats.capture(fun)

        measurements = %{
          elapsed_us:
            System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond),
          query_count: stats.query_count,
          checkout_queue_time_us:
            System.convert_time_unit(stats.queue_time, :native, :microsecond)
        }

        {result, measurements}
      end)

    track_capacity_task!(ref, task)
  end

  defp release_capacity_posts!(ref) do
    pending = collect_pending_capacity_handles!(ref)

    Enum.each(pending ++ Process.get({ref, :post_handles}, []), fn {callback_pid, _backend_pid,
                                                                    _customer_ref, local_id} ->
      send(callback_pid, {ref, :release_post, local_id})
    end)
  end

  defp collect_pending_capacity_handles!(ref) do
    receive do
      {^ref, :held_post, callback_pid, customer_ref, backend_pid, local_id, _params} ->
        [
          {callback_pid, backend_pid, customer_ref, local_id}
          | collect_pending_capacity_handles!(ref)
        ]
    after
      0 -> []
    end
  end

  defp primary_pool_metrics! do
    meta = Ecto.Adapter.lookup_meta(Repo)

    metrics =
      DBConnection.get_connection_metrics(meta.pid, pool: Keyword.fetch!(meta.opts, :pool))

    %{
      ready_conn_count: Enum.sum(Enum.map(metrics, & &1.ready_conn_count)),
      checkout_queue_length: Enum.sum(Enum.map(metrics, & &1.checkout_queue_length))
    }
  end

  defp assert_dispatch_locks_absent!(fixture) do
    keys = [
      PaymentMethodAuthorityGate.binding_key(fixture.customer.id, :stripe),
      PaymentMethodAuthorityGate.method_key(
        :stripe,
        fixture.refs.provider_customer,
        fixture.refs.old_method
      )
    ]

    Enum.each(keys, fn key ->
      <<high::unsigned-big-32, low::unsigned-big-32>> = <<key::signed-big-64>>

      assert [[0]] ==
               Repo.query!(
                 "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted AND objsubid=1 AND classid::bigint=$1 AND objid::bigint=$2",
                 [high, low]
               ).rows
    end)
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
            },
            context: %{system?: true}
          )
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
            },
            context: %{system?: true}
          )
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
