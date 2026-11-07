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
      raise "JC290 transaction gate tests require Repo pool_size >= 4, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    {:ok,
     identity: %{
       user_id: Ecto.UUID.generate(),
       provider: :stripe,
       customer_ref: "cus_jc290_gate",
       method_ref: "pm_#{Ecto.UUID.generate()}"
     }}
  end

  for outcome <- [:commit, :rollback] do
    test "transaction lock blocks a competing binding writer and releases on #{outcome}", %{
      identity: identity
    } do
      parent = self()
      ref = make_ref()

      holder =
        Task.async(fn ->
          Repo.checkout(fn ->
            result =
              Repo.transaction(fn ->
                assert :ok =
                         Gate.lock_binding_for_transaction(identity.user_id, identity.provider)

                assert :ok =
                         Gate.lock_method_for_transaction(
                           identity.provider,
                           identity.customer_ref,
                           identity.method_ref
                         )

                [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(parent, {ref, :holder, pid})

                receive do
                  {^ref, :release} -> :ok
                after
                  5_000 -> raise "transaction lock barrier expired"
                end

                if unquote(outcome) == :rollback, do: Repo.rollback(:expected_rollback), else: :ok
              end)

            send(parent, {ref, :holder_result, result})
            result
          end)
        end)

      writer_key = {ref, :writer_task}

      try do
        assert_receive {^ref, :holder, holder_pid}, 3_000

        writer =
          Task.async(fn ->
            Repo.checkout(fn ->
              [[writer_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {ref, :writer_pid, writer_pid})

              result =
                Repo.transaction(fn ->
                  Gate.lock_binding_for_transaction(identity.user_id, identity.provider)
                end)

              send(parent, {ref, :writer_result, result})
              result
            end)
          end)

        Process.put(writer_key, writer)

        assert_receive {^ref, :writer_pid, writer_pid}, 3_000
        refute writer_pid == holder_pid
        assert_eventually(fn -> blocked_by?(holder_pid, writer_pid) end)

        send(holder.pid, {ref, :release})
        assert_receive {^ref, :holder_result, holder_result}, 3_000
        assert_receive {^ref, :writer_result, {:ok, :ok}}, 3_000
        assert {:ok, :ok} = Task.await(Process.get(writer_key), 3_000)

        if unquote(outcome) == :commit do
          assert holder_result == {:ok, :ok}
        else
          assert holder_result == {:error, :expected_rollback}
        end

        expected_task_result =
          if unquote(outcome) == :commit, do: {:ok, :ok}, else: {:error, :expected_rollback}

        assert ^expected_task_result = Task.await(holder, 3_000)
        assert_key_available!(identity)
      after
        send(holder.pid, {ref, :release})
        Task.shutdown(holder, :brutal_kill)
        if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      end
    end
  end

  test "owner death rolls back and releases its transaction lock", %{identity: identity} do
    parent = self()
    ref = make_ref()

    holder =
      Task.async(fn ->
        Repo.checkout(fn ->
          Repo.transaction(fn ->
            assert :ok = Gate.lock_binding_for_transaction(identity.user_id, identity.provider)
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {ref, :holder, pid})
            Process.sleep(:infinity)
          end)
        end)
      end)

    try do
      assert_receive {^ref, :holder, backend_pid}, 3_000
      Process.unlink(holder.pid)
      Process.exit(holder.pid, :kill)
      assert_receive {:DOWN, task_ref, :process, task_pid, :killed}, 3_000
      assert task_ref == holder.ref and task_pid == holder.pid
      assert_eventually(fn -> not backend_present?(backend_pid) end)
      assert_key_available!(identity)
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  defp assert_key_available!(identity) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert :ok = Gate.lock_binding_for_transaction(identity.user_id, identity.provider)

               assert :ok =
                        Gate.lock_method_for_transaction(
                          identity.provider,
                          identity.customer_ref,
                          identity.method_ref
                        )

               :ok
             end)
  end

  defp blocked_by?(holder_pid, writer_pid) do
    Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
      holder_pid,
      writer_pid
    ]).rows == [[true]]
  end

  defp backend_present?(pid) do
    Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid = $1::integer", [pid]).rows ==
      [[1]]
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
