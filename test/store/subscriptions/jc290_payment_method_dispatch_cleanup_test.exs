defmodule Store.Subscriptions.JC290PaymentMethodDispatchCleanupTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @moduletag timeout: 15_000

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.PaymentMethodAuthorityGate, as: Gate

  setup_all do
    pool_size = Repo.config()[:pool_size]

    unless is_integer(pool_size) and pool_size >= 4 do
      raise "JC290 session proof requires Repo pool_size >= 4, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    identity = %{
      user_id: Ecto.UUID.generate(),
      provider: :stripe,
      customer_ref: "cus_jc290_gate",
      method_ref: "pm_#{Ecto.UUID.generate()}"
    }

    {:ok, identity: identity}
  end

  test "holds both session gates outside a transaction and blocks binding writers", %{
    identity: identity
  } do
    for _ <- 1..2 do
      parent = self()
      ref = make_ref()

      task =
        Task.async(fn ->
          Gate.with_dispatch_session_gates(
            identity.user_id,
            identity.provider,
            fn -> {:ok, identity} end,
            fn _resolved, proof ->
              assert {:ok, :ok} =
                       Repo.transaction(fn ->
                         assert [[proof.backend_pid]] ==
                                  Repo.query!("SELECT pg_backend_pid()").rows

                         :ok
                       end)

              assert :ok = Gate.confirm_dispatch_session(proof)
              send(parent, {ref, :held, proof, Repo.in_transaction?()})

              receive do
                {^ref, :release} -> :ok
              after
                3_000 -> raise "gate barrier timeout"
              end
            end
          )
        end)

      try do
        assert_receive {^ref, :held, proof, false}, 3_000
        assert {:error, :lock_unavailable} = Gate.confirm_dispatch_session(proof)

        assert [[nil]] ==
                 Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid = $1", [
                   proof.backend_pid
                 ]).rows

        writer =
          Task.async(fn ->
            Repo.checkout(fn ->
              [[writer_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {ref, :writer, writer_pid})

              Repo.transaction(fn ->
                Gate.lock_binding_for_transaction(identity.user_id, identity.provider)
              end)
            end)
          end)

        try do
          assert_receive {^ref, :writer, writer_pid}, 3_000
          refute writer_pid == proof.backend_pid

          assert_eventually(fn ->
            Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
              proof.backend_pid,
              writer_pid
            ]).rows == [[true]]
          end)

          send(task.pid, {ref, :release})
          assert :ok = Task.await(task, 3_000)
          assert {:ok, :ok} = Task.await(writer, 3_000)
        after
          send(task.pid, {ref, :release})
          Task.shutdown(writer, :brutal_kill)
        end

        assert_keys_available!(identity, proof.backend_pid)
      after
        send(task.pid, {ref, :release})
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "rejects an existing transaction before running the resolver", %{identity: identity} do
    assert {:ok, {:error, :lock_unavailable}} =
             Repo.transaction(fn ->
               Gate.with_dispatch_session_gates(
                 identity.user_id,
                 identity.provider,
                 fn -> flunk("transaction invoked resolver") end,
                 fn _, _ -> flunk("transaction invoked callback") end
               )
             end)

    assert_keys_available!(identity)
  end

  @tag :jc290_topology_correction
  test "rejects unsupported pool modes before resolver, callback, or repository query", %{
    identity: identity
  } do
    parent = self()

    for mode <- ["transaction", "unsupported", nil] do
      previous = Application.fetch_env(:store, :database_pool_mode)
      Application.put_env(:store, :database_pool_mode, mode)
      ref = make_ref()
      handler = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler,
          [:store, :repo, :query],
          fn _, _, _, _ ->
            if self() == parent, do: send(parent, {ref, :repo_query})
          end,
          nil
        )

      try do
        assert {:error,
                %Store.Support.Errors.Error{
                  code: "RENEWAL_DISPATCH_UNAVAILABLE",
                  meta: %{reason: :unsupported_database_pool_mode}
                }} =
                 Gate.with_dispatch_session_gates(
                   identity.user_id,
                   identity.provider,
                   fn ->
                     send(parent, {ref, :resolver_invoked})
                     {:ok, identity}
                   end,
                   fn _, _ ->
                     send(parent, {ref, :callback_invoked})
                     :sent
                   end
                 )

        refute_receive {^ref, :resolver_invoked}, 0
        refute_receive {^ref, :callback_invoked}, 0
        refute_receive {^ref, :repo_query}, 0
      after
        :telemetry.detach(handler)

        case previous do
          {:ok, value} -> Application.put_env(:store, :database_pool_mode, value)
          :error -> Application.delete_env(:store, :database_pool_mode)
        end
      end
    end

    assert_keys_available!(identity)
  end

  test "cleans both session gates after a callback exception", %{identity: identity} do
    parent = self()

    assert_raise RuntimeError, "jc290 callback", fn ->
      Gate.with_dispatch_session_gates(
        identity.user_id,
        identity.provider,
        fn -> {:ok, identity} end,
        fn _, proof ->
          send(parent, {:callback_backend, proof.backend_pid})
          raise "jc290 callback"
        end
      )
    end

    assert_receive {:callback_backend, backend_pid}
    assert_keys_available!(identity, backend_pid)
  end

  test "passes resolver errors through after releasing the binding gate", %{identity: identity} do
    assert {:error, :authority_changed} =
             Gate.with_dispatch_session_gates(
               identity.user_id,
               identity.provider,
               fn -> {:error, :authority_changed} end,
               fn _, _ -> flunk("resolver error invoked callback") end
             )

    assert_keys_available!(identity)
  end

  test "releases the binding gate after a resolver exception", %{identity: identity} do
    assert_raise RuntimeError, "jc290 resolver", fn ->
      Gate.with_dispatch_session_gates(
        identity.user_id,
        identity.provider,
        fn -> raise "jc290 resolver" end,
        fn _, _ -> flunk("resolver exception invoked callback") end
      )
    end

    assert_keys_available!(identity)
  end

  test "discards the owner when method acquisition follows connection loss", %{
    identity: identity
  } do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Gate.with_dispatch_session_gates(
          identity.user_id,
          identity.provider,
          fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {ref, :resolver_backend, backend_pid})

            receive do
              {^ref, :resume} -> {:ok, identity}
            after
              3_000 -> raise "resolver barrier timeout"
            end
          end,
          fn _, _ -> send(parent, {ref, :unexpected_callback}) end
        )
      end)

    try do
      assert_receive {^ref, :resolver_backend, backend_pid}, 3_000
      Process.unlink(task.pid)

      assert {:ok, %{rows: [[true]]}} =
               Repo.query("SELECT pg_terminate_backend($1::integer)", [backend_pid])

      send(task.pid, {ref, :resume})
      assert_receive {:DOWN, task_ref, :process, task_pid, :killed}, 3_000
      assert task_ref == task.ref
      assert task_pid == task.pid
      assert_eventually(fn -> not backend_present?(backend_pid) end)
      refute_receive {^ref, :unexpected_callback}, 0
      assert_keys_available!(identity, backend_pid)
    after
      send(task.pid, {ref, :resume})
      Task.shutdown(task, :brutal_kill)
    end
  end

  for busy_gate <- [:binding, :method] do
    test "does not disconnect another owner's #{busy_gate} lock", %{identity: identity} do
      parent = self()
      ref = make_ref()

      busy_key =
        if unquote(busy_gate) == :binding, do: binding_key(identity), else: method_key(identity)

      holder = Task.async(fn -> hold_raw_lock(parent, ref, busy_key) end)
      assert_receive {^ref, :holder, holder_pid}, 3_000

      try do
        assert {:error, :lock_unavailable} =
                 Gate.with_dispatch_session_gates(
                   identity.user_id,
                   identity.provider,
                   fn -> {:ok, identity} end,
                   fn _, _ -> flunk("busy lock invoked callback") end
                 )

        assert advisory_lock_owned?(busy_key, holder_pid)

        if unquote(busy_gate) == :method do
          assert :ok == probe_binding_key(identity)
        end
      after
        send(holder.pid, {ref, :release})
        assert :ok = Task.await(holder, 3_000)
      end

      assert_keys_available!(identity)
    end
  end

  for mode <- [:owner_death, :unlock_false, :connection_loss, :checkout_deadline] do
    test "discards only the checked-out owner after #{mode}", %{identity: identity} do
      run_discard_scenario(identity, unquote(mode))
    end
  end

  defp run_discard_scenario(identity, mode) do
    parent = self()
    ref = make_ref()

    call = fn ->
      Gate.with_dispatch_session_gates(
        identity.user_id,
        identity.provider,
        fn -> {:ok, identity} end,
        fn _, proof ->
          send(parent, {ref, :held, proof.backend_pid})

          receive do
            {^ref, :release} -> :ok
          after
            3_000 -> raise "gate barrier timeout"
          end

          apply_discard_mode(mode, identity, proof, parent, ref)
        end
      )
    end

    task =
      Task.async(fn ->
        if mode == :checkout_deadline do
          Repo.checkout(call, timeout: 500)
        else
          call.()
        end
      end)

    try do
      assert_receive {^ref, :held, backend_pid}, 3_000
      Process.unlink(task.pid)

      if mode == :owner_death do
        Process.exit(task.pid, :kill)
      else
        if mode == :checkout_deadline do
          assert_eventually(fn -> not backend_present?(backend_pid) end)
        end

        send(task.pid, {ref, :release})
      end

      assert_receive {:DOWN, task_ref, :process, task_pid, :killed}, 3_000
      assert task_ref == task.ref
      assert task_pid == task.pid
      assert_eventually(fn -> not backend_present?(backend_pid) end)
      refute_receive {^ref, :unexpected_invocation}, 0
      assert_keys_available!(identity, backend_pid)
    after
      send(task.pid, {ref, :release})
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp hold_raw_lock(parent, ref, key) do
    Repo.checkout(fn ->
      [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      assert {:ok, %{rows: [[:void]]}} = Repo.query("SELECT pg_advisory_lock($1)", [key])
      send(parent, {ref, :holder, pid})

      try do
        receive do
          {^ref, :release} -> :ok
        after
          3_000 -> raise "holder barrier timeout"
        end
      after
        assert {:ok, %{rows: [[true]]}} = Repo.query("SELECT pg_advisory_unlock($1)", [key])
      end

      Repo.query!("SELECT 1")
      :ok
    end)
  end

  defp apply_discard_mode(mode, identity, proof, parent, ref) do
    case mode do
      :owner_death ->
        :ok

      :unlock_false ->
        assert {:ok, %{rows: [[true]]}} =
                 Repo.query("SELECT pg_advisory_unlock($1)", [method_key(identity)])

        :ok

      :connection_loss ->
        _ = Repo.query("SELECT pg_terminate_backend(pg_backend_pid())")
        :ok

      :checkout_deadline ->
        with :ok <- Gate.confirm_dispatch_session(proof) do
          send(parent, {ref, :unexpected_invocation})
        end
    end
  end

  defp assert_keys_available!(identity, excluded_pid \\ nil) do
    keys = [binding_key(identity), method_key(identity)]

    for key <- keys do
      assert key_lock_count(key) == 0
    end

    Repo.checkout(fn ->
      [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows

      if pid == excluded_pid do
        assert :ok = probe_keys_on_another_backend!(keys, excluded_pid)
      else
        probe_keys!(keys)
      end
    end)
  end

  defp probe_keys_on_another_backend!(keys, excluded_pid) do
    Task.async(fn ->
      Repo.checkout(fn ->
        [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
        assert pid != excluded_pid
        probe_keys!(keys)
      end)
    end)
    |> Task.await(3_000)
  end

  defp probe_keys!([binding, method]) do
    assert {:ok, %{rows: [[true]]}} = Repo.query("SELECT pg_try_advisory_lock($1)", [binding])

    try do
      assert {:ok, %{rows: [[true]]}} = Repo.query("SELECT pg_try_advisory_lock($1)", [method])
      assert [[1]] = Repo.query!("SELECT 1").rows
    after
      _ = Repo.query("SELECT pg_advisory_unlock($1)", [method])
      assert {:ok, %{rows: [[true]]}} = Repo.query("SELECT pg_advisory_unlock($1)", [binding])
    end

    :ok
  end

  defp probe_binding_key(identity) do
    key = binding_key(identity)
    assert {:ok, %{rows: [[true]]}} = Repo.query("SELECT pg_try_advisory_lock($1)", [key])
    assert {:ok, %{rows: [[true]]}} = Repo.query("SELECT pg_advisory_unlock($1)", [key])
    :ok
  end

  defp key_lock_count(key) do
    {high, low} = key_parts(key)

    Repo.query!(
      "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND objsubid = 1 AND classid::bigint = $1::bigint AND objid::bigint = $2::bigint",
      [high, low]
    ).rows
    |> hd()
    |> hd()
  end

  defp advisory_lock_owned?(key, pid) do
    {high, low} = key_parts(key)

    Repo.query!(
      "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = $1::integer AND objsubid = 1 AND classid::bigint = $2::bigint AND objid::bigint = $3::bigint)",
      [pid, high, low]
    ).rows == [[true]]
  end

  defp backend_present?(pid) do
    Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1::integer)", [pid]).rows ==
      [[true]]
  end

  defp binding_key(identity), do: Gate.binding_key(identity.user_id, identity.provider)

  defp method_key(identity),
    do: Gate.method_key(identity.provider, identity.customer_ref, identity.method_ref)

  defp key_parts(key) do
    <<high::unsigned-big-32, low::unsigned-big-32>> = <<key::signed-big-64>>
    {high, low}
  end

  defp assert_eventually(predicate) do
    poll(predicate, System.monotonic_time(:millisecond) + 2_000)
  end

  defp poll(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "PostgreSQL condition did not become true"

      receive do
      after
        10 -> :ok
      end

      poll(predicate, deadline)
    end
  end
end
