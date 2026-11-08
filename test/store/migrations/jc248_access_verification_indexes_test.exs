defmodule Store.Jc248AccessVerificationIndexesTestRepo do
  use Ecto.Repo,
    otp_app: :store,
    adapter: Ecto.Adapters.Postgres
end

defmodule Store.Migrations.Jc248AccessVerificationIndexesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  alias Store.TestSupport.IsolatedMigrationDatabase

  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20261108015000_jc248_access_verification_indexes.exs",
      __DIR__
    )
  )

  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20261107174747_add_subscription_setup_generations.exs",
      __DIR__
    )
  )

  @version 20_261_108_015_000
  @migration Store.Repo.Migrations.Jc248AccessVerificationIndexes
  @parent_version 20_261_107_174_747
  @parent_migration Store.Repo.Migrations.AddSubscriptionSetupGenerations
  setup_all do
    context =
      IsolatedMigrationDatabase.start!(
        "jc248_index_rollback",
        Store.Jc248AccessVerificationIndexesTestRepo,
        pool_size: 6
      )

    on_exit(fn -> IsolatedMigrationDatabase.stop!(context) end)

    {:ok, context}
  end

  setup %{repo: repo} do
    assert :ok = migrate_up(repo)
    :ok
  end

  test "the actual rollback keeps entitlement-grant reads and writes available", %{repo: repo} do
    rollback_index_while_readers_continue(
      repo,
      "entitlement_grants",
      "entitlement_grants_active_subscription_source_index"
    )
  end

  test "the actual rollback keeps access-effect reads and writes available", %{repo: repo} do
    rollback_index_while_readers_continue(
      repo,
      "access_effects",
      "access_effects_applied_verification_index"
    )
  end

  test "a staged index upgrade rolls back before the already-applied parent migration", %{
    repo: repo
  } do
    # Restrict this stage to the parent and index migrations. Later migrations in
    # this PR have their own rollback steps and do not change this ordering law.
    source = [{@parent_version, @parent_migration}, {@version, @migration}]

    try do
      assert :ok = Migrator.down(repo, @version, @migration, log: false)
      assert @parent_version in Migrator.migrated_versions(repo)
      refute @version in Migrator.migrated_versions(repo)

      assert [@version] = Migrator.run(repo, source, :up, all: true, log: false)
      assert [@version] = Migrator.run(repo, source, :down, step: 1, log: false)
      assert @parent_version in Migrator.migrated_versions(repo)
      refute @version in Migrator.migrated_versions(repo)
    after
      Migrator.up(repo, @parent_version, @parent_migration, log: false)
      migrate_up(repo)
    end
  end

  defp rollback_index_while_readers_continue(repo, table, index) do
    assert_index_state(repo, index, true)

    with_reader(repo, table, fn reader_pid, release_reader ->
      with_worker(
        fn -> Migrator.down(repo, @version, @migration, log: false) end,
        fn
          migration ->
            wait_state = await_drop_wait(repo, reader_pid, index, table)
            assert is_integer(wait_state.backend_pid)
            assert wait_state.lock_type == "virtualxid"
            assert wait_state.lock_mode == "ShareLock"
            assert String.starts_with?(wait_state.lock_relation, "virtualxid:")
            assert wait_state.table == table

            with_worker(fn -> probe_read(repo, table) end, fn read_probe ->
              assert {:ok, %{rows: []}} = await_worker(read_probe),
                     "rollback wait state: #{inspect(wait_state)}, table: #{table}"

              with_worker(fn -> probe_zero_row_update(repo, table) end, fn write_probe ->
                assert {:ok, %{num_rows: 0}} = await_worker(write_probe),
                       "rollback wait state: #{inspect(wait_state)}, table: #{table}"
              end)
            end)

            IO.puts(
              "JC248_CONCURRENT_INDEX_ROLLBACK " <>
                Jason.encode!(
                  Map.merge(wait_state, %{
                    index: index,
                    reader_backend_pid: reader_pid,
                    read_completed_before_release: true,
                    write_completed_before_release: true
                  })
                )
            )

            release_reader.()
            assert :ok = await_worker(migration)
        end,
        release_reader
      )
    end)

    assert_index_state(repo, "access_effects_applied_verification_index", false)
    assert_index_state(repo, "entitlement_grants_active_subscription_source_index", false)

    assert :ok = migrate_up(repo)
    assert_index_state(repo, "access_effects_applied_verification_index", true)
    assert_index_state(repo, "entitlement_grants_active_subscription_source_index", true)
  end

  defp with_reader(repo, table, callback) do
    parent = self()

    reader =
      spawn_worker(fn ->
        repo.transaction(fn ->
          _ = SQL.query!(repo, "SELECT id FROM #{table} LIMIT 0", [])
          %{rows: [[backend_pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
          send(parent, {:reader_started, backend_pid})

          receive do
            :release_reader -> :released
          after
            15_000 -> repo.rollback(:reader_release_timeout)
          end
        end)
      end)

    try do
      reader_pid =
        receive do
          {:reader_started, backend_pid} -> backend_pid
        after
          5_000 -> flunk("reader transaction did not start")
        end

      callback.(reader_pid, fn -> send(reader.pid, :release_reader) end)
    after
      send(reader.pid, :release_reader)
      stop_worker(reader)
    end
  end

  defp with_worker(fun, callback, cleanup \\ fn -> :ok end) do
    worker = spawn_worker(fun)

    try do
      callback.(worker)
    after
      cleanup.()
      stop_worker(worker)
    end
  end

  defp spawn_worker(fun) do
    parent = self()
    result_tag = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = fun.()
        send(parent, {result_tag, result})
      end)

    %{pid: pid, monitor_ref: monitor_ref, result_tag: result_tag}
  end

  defp await_worker(%{pid: pid, monitor_ref: monitor_ref, result_tag: result_tag}) do
    receive do
      {^result_tag, result} -> result
      {:DOWN, ^monitor_ref, :process, ^pid, reason} -> flunk("worker exited: #{inspect(reason)}")
    after
      5_000 -> flunk("worker did not finish before the deadline")
    end
  end

  defp stop_worker(%{pid: pid, monitor_ref: monitor_ref}) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp await_drop_wait(repo, reader_pid, index, table, attempts_left \\ 500)

  defp await_drop_wait(repo, reader_pid, index, table, attempts_left)
       when attempts_left > 0 do
    result =
      SQL.query!(
        repo,
        """
        SELECT waiting.pid,
               waiting.query,
               waiting_lock.locktype,
               waiting_lock.mode,
               CASE
                 WHEN waiting_lock.relation IS NULL THEN
                   waiting_lock.locktype || ':' || COALESCE(
                     waiting_lock.virtualxid,
                     waiting_lock.transactionid::text,
                     ''
                   )
                 ELSE waiting_lock.relation::regclass::text
               END
        FROM pg_stat_activity AS waiting
        JOIN pg_locks AS waiting_lock
          ON waiting_lock.pid = waiting.pid
         AND NOT waiting_lock.granted
        WHERE waiting.wait_event_type = 'Lock'
          AND $1 = ANY(pg_blocking_pids(waiting.pid))
          AND waiting.query ILIKE '%' || $2 || '%'
          AND EXISTS (
            SELECT 1 FROM pg_locks AS reader_lock
            WHERE reader_lock.pid = $1 AND reader_lock.granted
              AND reader_lock.mode = 'AccessShareLock'
              AND reader_lock.relation = to_regclass($3)
          )
        LIMIT 1
        """,
        [reader_pid, index, table]
      )

    case result.rows do
      [[backend_pid, query, lock_type, lock_mode, lock_relation]] ->
        assert is_integer(backend_pid)
        assert query =~ index
        assert query =~ "CONCURRENTLY"

        %{
          backend_pid: backend_pid,
          lock_type: lock_type,
          lock_mode: lock_mode,
          lock_relation: lock_relation,
          table: table
        }

      _ ->
        Process.sleep(20)
        await_drop_wait(repo, reader_pid, index, table, attempts_left - 1)
    end
  end

  defp await_drop_wait(_repo, _reader_pid, index, _table, _attempts_left) do
    flunk("migration did not wait on DROP INDEX #{index}")
  end

  defp probe_read(repo, table) do
    probe_query(repo, "SELECT id FROM #{table} LIMIT 0")
  end

  defp probe_zero_row_update(repo, table) do
    probe_query(repo, "UPDATE #{table} SET id = id WHERE false")
  end

  defp probe_query(repo, query) do
    repo.transaction(fn ->
      query_or_rollback!(repo, "SET LOCAL statement_timeout = '750ms'")
      query_or_rollback!(repo, query)
    end)
  end

  defp query_or_rollback!(repo, query) do
    case SQL.query(repo, query, []) do
      {:ok, result} -> result
      {:error, reason} -> repo.rollback({:statement_query_failed, reason})
    end
  end

  defp assert_index_state(repo, index, expected?) do
    %{rows: [[index_oid]]} = SQL.query!(repo, "SELECT to_regclass($1)", [index])

    if expected? do
      refute is_nil(index_oid)

      %{rows: [[true, true]]} =
        SQL.query!(
          repo,
          """
          SELECT indisvalid, indisready
          FROM pg_index
          WHERE indexrelid = to_regclass($1)
          """,
          [index]
        )
    else
      assert is_nil(index_oid)
    end
  end

  defp migrate_up(repo) do
    case Migrator.up(repo, @version, @migration, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end
end
