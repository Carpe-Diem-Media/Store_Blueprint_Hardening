# JC-290 checked-out session gate implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to execute this task with separate spec and quality reviews.

**Goal:** Add and prove the PostgreSQL session gate used by every later outbound renewal charge request.

**Architecture:** Use the existing Repo checkout and mutation lock keys. Acquire binding then exact method session gates, keep them while the caller commits its short claim and initiates a request, and release them before returning the response. Current rows and checkpoint-D evidence remain authority. This helper alone does not close JC-290's dispatch race.

**Tech Stack:** Installed Elixir 1.19.5, Ash 3.37.2, Ecto SQL, DBConnection, PostgreSQL, ExUnit.

## Files and scope

Modify lib/store/subscriptions/payment_method_authority_gate.ex. Create test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs. Leave facade integration and financial race fixtures for the following task. Do not change transaction gate keys, provider timeouts, dependencies, pools, schema, or services.

## Task 2: Session gates and owned-session cleanup

- [ ] Add the real-connection tests below first. Run them and observe missing-helper failure. Their SQL queries and backend IDs establish actual session ownership; task non-completion is not a lock proof.
- [ ] Add the helper code below to the existing module, using its existing Repo alias and key functions. Run both the new real-connection tests and existing helper/revocation tests. Retain their output in ignored tmp/jc290/.

```elixir
@session_query_timeout_ms 1_000
@dispatch_checkout_timeout_ms 60_000

@type session_proof :: %{
        backend_pid: pos_integer(),
        binding_key: integer(),
        method_key: integer()
      }

@doc """
Serializes a fresh dispatch with cooperating binding and method writers.

The resolver runs after the binding gate is held. The callback runs outside a
Repo transaction and must confirm the proof immediately before adapter invocation.
The checkout deadline bounds the database checkout. It does not prove remote
receipt or bound the lifetime of a synchronous HTTP callback after disconnection.
"""
@spec with_dispatch_session_gates(
        Ecto.UUID.t(),
        atom(),
        (-> {:ok, map()} | {:error, term()}),
        (map(), session_proof() -> result)
      ) :: result | {:error, term()} when result: var
 def with_dispatch_session_gates(user_id, provider, resolve_identity, fun) do
  Repo.checkout(fn ->
    if Repo.in_transaction?() do
      {:error, :lock_unavailable}
    else
      binding = binding_key(user_id, provider)

      with {:ok, %{rows: [[backend_pid]]}} <-
             Repo.query("SELECT pg_backend_pid()", [], timeout: @session_query_timeout_ms) do
        with_session_key(binding, fn ->
          with {:ok, identity} <- resolve_identity.() do
            method = method_key(identity.provider, identity.customer_ref, identity.method_ref)

            with_session_key(method, fn ->
              fun.(identity, %{backend_pid: backend_pid, binding_key: binding, method_key: method})
            end)
          end
        end)
      else
        _ -> {:error, :lock_unavailable}
      end
    end
  end, timeout: @dispatch_checkout_timeout_ms)
rescue
  _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
end

@doc """
Confirms the original checked-out backend still holds both session gates.

Call after the committed-claim observation event and immediately before the
adapter call. This detects an observed lost session; it cannot make PostgreSQL
and a remote provider one atomic system.
"""
@spec confirm_dispatch_session(session_proof()) :: :ok | {:error, :lock_unavailable}
def confirm_dispatch_session(proof) do
  {binding_high, binding_low} = advisory_key_parts(proof.binding_key)
  {method_high, method_low} = advisory_key_parts(proof.method_key)

  query = """
  SELECT pg_backend_pid() = $1::integer
    AND EXISTS (
      SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = $1::integer
        AND granted AND objsubid = 1
        AND classid::bigint = $2::bigint AND objid::bigint = $3::bigint
    )
    AND EXISTS (
      SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = $1::integer
        AND granted AND objsubid = 1
        AND classid::bigint = $4::bigint AND objid::bigint = $5::bigint
    )
  """

  case Repo.query(query, [proof.backend_pid, binding_high, binding_low, method_high, method_low],
         timeout: @session_query_timeout_ms) do
    {:ok, %{rows: [[true]]}} -> :ok
    _ -> {:error, :lock_unavailable}
  end
rescue
  _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
end

 defp with_session_key(key, fun) do
  case Repo.query("SELECT pg_try_advisory_lock($1)", [key], timeout: @session_query_timeout_ms) do
    {:ok, %{rows: [[true]]}} ->
      try do
        fun.()
      after
        release_session_key_or_discard_owner!(key)
      end

    _ -> {:error, :lock_unavailable}
  end
end

 defp release_session_key_or_discard_owner!(key) do
  case Repo.query("SELECT pg_advisory_unlock($1)", [key], timeout: @session_query_timeout_ms) do
    {:ok, %{rows: [[true]]}} -> :ok
    _ -> Process.exit(self(), :kill)
  end
rescue
  _error in [DBConnection.ConnectionError, Postgrex.Error] -> Process.exit(self(), :kill)
catch
  :exit, _reason -> Process.exit(self(), :kill)
end

 defp advisory_key_parts(key) do
  <<high::unsigned-big-32, low::unsigned-big-32>> = <<key::signed-big-64>>
  {high, low}
end
```

Use this complete test module. It uses no business-row fixtures, so it needs no
fixture deletion or trigger changes. All advisory keys have a fresh random owner.
The SQL assertions use distinct physical connections in auto Sandbox mode.

```elixir
defmodule Store.Subscriptions.Jc290PaymentMethodDispatchCleanupTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.PaymentMethodAuthorityGate, as: Gate

  @moduletag :real_connections
  @moduletag timeout: 15_000

  setup_all do
    unless Repo.config()[:pool_size] >= 4, do: raise("JC290 needs Repo pool_size >= 4")
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    identity = %{user_id: Ecto.UUID.generate(), provider: :stripe,
                 customer_ref: "cus_jc290_gate", method_ref: "pm_#{Ecto.UUID.generate()}"}
    {:ok, identity: identity}
  end

  test "same backend commits its short transaction while the gates remain held", %{identity: identity} do
    for _ <- 1..2 do
      parent = self()
      ref = make_ref()
      task = Task.async(fn ->
        Gate.with_dispatch_session_gates(identity.user_id, identity.provider, fn -> {:ok, identity} end,
          fn _resolved, proof ->
            assert {:ok, :ok} = Repo.transaction(fn ->
              assert [[proof.backend_pid]] == Repo.query!("SELECT pg_backend_pid()").rows
              :ok
            end)
            assert :ok = Gate.confirm_dispatch_session(proof)
            send(parent, {ref, :held, proof, Repo.in_transaction?()})
            receive do {^ref, :release} -> :ok after 3_000 -> raise "gate barrier timeout" end
          end)
      end)

      try do
        assert_receive {^ref, :held, proof, false}, 3_000
        assert {:error, :lock_unavailable} = Gate.confirm_dispatch_session(proof)
        assert [[nil]] == Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid = $1", [proof.backend_pid]).rows
        writer = Task.async(fn ->
          Repo.checkout(fn ->
            [[writer_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {ref, :writer, writer_pid})
            Repo.transaction(fn -> Gate.lock_binding_for_transaction(identity.user_id, identity.provider) end)
          end)
        end)

        try do
          assert_receive {^ref, :writer, writer_pid}, 3_000
          refute writer_pid == proof.backend_pid
          assert_eventually(fn ->
            Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [proof.backend_pid, writer_pid]).rows == [[true]]
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

  test "an existing caller transaction fails closed", %{identity: identity} do
    assert {:ok, {:error, :lock_unavailable}} = Repo.transaction(fn ->
      Gate.with_dispatch_session_gates(identity.user_id, identity.provider,
        fn -> flunk("transaction invoked resolver") end, fn _, _ -> flunk("transaction invoked callback") end)
    end)
    assert_keys_available!(identity)
  end

  test "callback exception releases both keys", %{identity: identity} do
    parent = self()
    ref = make_ref()
    assert_raise RuntimeError, "jc290 callback", fn ->
      Gate.with_dispatch_session_gates(identity.user_id, identity.provider, fn -> {:ok, identity} end,
        fn _identity, proof ->
          send(parent, {ref, :backend, proof.backend_pid})
          raise "jc290 callback"
        end)
    end
    assert_receive {^ref, :backend, backend_pid}
    assert_keys_available!(identity, backend_pid)
  end

  test "resolver error releases the binding", %{identity: identity} do
    assert {:error, :authority_changed} = Gate.with_dispatch_session_gates(
      identity.user_id, identity.provider, fn -> {:error, :authority_changed} end,
      fn _, _ -> flunk("resolver error invoked callback") end)
    assert_keys_available!(identity)
  end

  test "resolver exception releases the binding", %{identity: identity} do
    assert_raise RuntimeError, "jc290 resolver", fn ->
      Gate.with_dispatch_session_gates(identity.user_id, identity.provider,
        fn -> raise "jc290 resolver" end, fn _, _ -> flunk("resolver exception invoked callback") end)
    end
    assert_keys_available!(identity)
  end

  for kind <- [:binding, :method] do
    test "#{kind} busy fails closed and releases only acquired keys", %{identity: identity} do
      kind = unquote(kind)
      key = if kind == :binding,
        do: Gate.binding_key(identity.user_id, identity.provider),
        else: Gate.method_key(identity.provider, identity.customer_ref, identity.method_ref)
      parent = self()
      ref = make_ref()
      holder = Task.async(fn ->
        Repo.checkout(fn ->
          Repo.query!("SELECT pg_advisory_lock($1)", [key])
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {ref, :holder, backend_pid})
          try do
            receive do {^ref, :release} -> :ok after 3_000 -> raise "holder timeout" end
            assert [[1]] == Repo.query!("SELECT 1").rows
          after
            assert [[true]] == Repo.query!("SELECT pg_advisory_unlock($1)", [key]).rows
          end
        end)
      end)

      try do
        assert_receive {^ref, :holder, holder_pid}, 3_000
        assert {:error, :lock_unavailable} =
          Gate.with_dispatch_session_gates(identity.user_id, identity.provider,
            fn -> {:ok, identity} end, fn _, _ -> flunk("busy gate invoked callback") end)
        assert [[true]] == Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1 AND locktype = 'advisory' AND granted)", [holder_pid]).rows
        if kind == :method do
          Repo.checkout(fn ->
            binding = Gate.binding_key(identity.user_id, identity.provider)
            assert [[true]] == Repo.query!("SELECT pg_try_advisory_lock($1)", [binding]).rows
            assert [[true]] == Repo.query!("SELECT pg_advisory_unlock($1)", [binding]).rows
          end)
        end
      after
        send(holder.pid, {ref, :release})
        Task.await(holder, 3_000)
      end
      assert_keys_available!(identity)
    end
  end

  for mode <- [:owner_death, :unlock_false, :connection_loss, :checkout_deadline] do
    test "#{mode} discards only its checkout and frees both keys", %{identity: identity} do
      mode = unquote(mode)
      parent = self()
      ref = make_ref()
      task = Task.async(fn ->
        outer = fn ->
          Gate.with_dispatch_session_gates(identity.user_id, identity.provider, fn -> {:ok, identity} end,
            fn _identity, proof ->
              send(parent, {ref, :held, proof.backend_pid})
              receive do {^ref, :release} -> :ok after 3_000 -> raise "cleanup barrier timeout" end
              case mode do
                :owner_death -> :ok
                :unlock_false ->
                  assert [[true]] == Repo.query!("SELECT pg_advisory_unlock($1)", [proof.method_key]).rows
                :connection_loss ->
                  Repo.query("SELECT pg_terminate_backend(pg_backend_pid())")
                :checkout_deadline ->
                  with :ok <- Gate.confirm_dispatch_session(proof) do
                    send(parent, {ref, :unexpected_invocation})
                  end
              end
            end)
        end
        if mode == :checkout_deadline, do: Repo.checkout(outer, timeout: 500), else: outer.()
      end)
      Process.unlink(task.pid)

      try do
        assert_receive {^ref, :held, backend_pid}, 3_000
        if mode == :owner_death, do: Process.exit(task.pid, :kill)
        if mode in [:unlock_false, :connection_loss], do: send(task.pid, {ref, :release})
        if mode == :checkout_deadline do
          assert_eventually(fn -> Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid = $1", [backend_pid]).rows == [[0]] end)
          send(task.pid, {ref, :release})
        end
        assert_receive {:DOWN, monitor_ref, :process, task_pid, :killed}, 3_000
        assert monitor_ref == task.ref
        assert task_pid == task.pid
        assert_eventually(fn -> Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid = $1", [backend_pid]).rows == [[0]] end)
        refute_receive {^ref, :unexpected_invocation}, 0
        assert_keys_available!(identity, backend_pid)
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp assert_keys_available!(identity, excluded_backend \\ nil) do
    keys = [Gate.binding_key(identity.user_id, identity.provider),
            Gate.method_key(identity.provider, identity.customer_ref, identity.method_ref)]
    Enum.each(keys, fn key ->
      <<high::unsigned-big-32, low::unsigned-big-32>> = <<key::signed-big-64>>
      assert [[0]] == Repo.query!("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND objsubid = 1 AND classid::bigint = $1::bigint AND objid::bigint = $2::bigint", [high, low]).rows
    end)
    Repo.checkout(fn ->
      [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      if backend_pid == excluded_backend do
        task = Task.async(fn ->
          Repo.checkout(fn ->
            [[probe_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            refute probe_pid == excluded_backend
            probe_keys!(identity)
          end)
        end)
        Task.await(task, 3_000)
      else
        probe_keys!(identity)
      end
    end)
  end

  defp probe_keys!(identity) do
    binding = Gate.binding_key(identity.user_id, identity.provider)
    method = Gate.method_key(identity.provider, identity.customer_ref, identity.method_ref)
    assert [[true]] == Repo.query!("SELECT pg_try_advisory_lock($1)", [binding]).rows
    try do
      assert [[true]] == Repo.query!("SELECT pg_try_advisory_lock($1)", [method]).rows
      assert [[1]] == Repo.query!("SELECT 1").rows
    after
      Repo.query!("SELECT pg_advisory_unlock($1)", [method])
      assert [[true]] == Repo.query!("SELECT pg_advisory_unlock($1)", [binding]).rows
    end
  end

  defp assert_eventually(predicate), do: poll(predicate, System.monotonic_time(:millisecond) + 2_000)
  defp poll(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "PostgreSQL condition did not become true"
      receive do after 10 -> :ok end
      poll(predicate, deadline)
    end
  end
end
```

- [ ] Run the new module twice, sequentially, through DevCore. No facade integration is part of this task. Keep the method-busy
  holder alive while proving the helper released its binding key. Preserve the
  prior mutation helper/revocation results with their focused command.

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test --only real_connections test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/payment_method_authority_gate_test.exs test/store/subscriptions/stored_payment_method_revocation_test.exs
```

- [ ] Format the two touched files, run format checking and git diff --check,
  inspect the complete task diff, and commit only those two files.

```bash
git add lib/store/subscriptions/payment_method_authority_gate.ex test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs
git commit -m "fix(subscriptions): guard checked-out payment method sessions"
```

## Root self-review

The key functions match Task 1. The resolver returns provider, customer_ref and
method_ref. The callback receives that identity plus the exact backend/key proof.
Both unlock paths are nested, and an untrappable owner kill prevents reuse after
unknown cleanup. Existing caller checkout deadlines may expire first; the test
uses a 500 ms outer checkout to exercise that same production API without a minute
of idle test time. The helper never claims a request occurred or sets payment
state. Real physical transaction visibility and both race winners remain part of
the following facade task, including exact-reference replay after a crash.
