defmodule Store.Shipping.ConfigRevisionTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo

  alias Store.Shipping.{
    ConfigRevision,
    Facade,
    ShippingMethod,
    ShippingRateRule,
    ShippingZone
  }

  test "source inserts, updates and deletes advance one durable revision" do
    revision = revision!()
    zone = create_zone!()
    assert revision!() > revision

    revision = revision!()
    method = create_method!()
    assert revision!() > revision

    revision = revision!()
    rule = create_rule!(zone.id, method.id)
    assert revision!() > revision

    revision = revision!()
    update_zone!(zone, "CA")
    assert revision!() > revision

    revision = revision!()
    update_method!(method, "Ground Freight")
    assert revision!() > revision

    revision = revision!()
    update_rule!(rule, 1_350)
    assert revision!() > revision

    revision = revision!()
    Repo.query!("DELETE FROM shipping_rates WHERE id = $1", [Ecto.UUID.dump!(rule.id)])
    assert revision!() > revision

    revision = revision!()
    Repo.query!("DELETE FROM shipping_zones WHERE id = $1", [Ecto.UUID.dump!(zone.id)])
    assert revision!() > revision

    revision = revision!()
    Repo.query!("DELETE FROM shipping_methods WHERE id = $1", [Ecto.UUID.dump!(method.id)])
    assert revision!() > revision
  end

  test "facade writes use the same database revision trigger" do
    revision = revision!()

    assert {:ok, _zone} =
             Facade.create_shipping_zone_for_admin(
               %{},
               %{
                 code: "FACADE_REV_#{System.unique_integer([:positive])}",
                 country_code: "ZA",
                 active: true
               },
               context: %{system?: true}
             )

    assert revision!() > revision
  end

  test "truncate statements for all Shipping sources advance the revision" do
    revision = revision!()

    Repo.query!("TRUNCATE TABLE shipping_rates, shipping_zones, shipping_methods")

    assert revision!() == revision + 3
  end

  test "a rolled back source mutation rolls back its revision increment" do
    revision = revision!()

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               create_zone!()
               assert revision!() > revision
               Repo.rollback(:rolled_back)
             end)

    assert revision!() == revision
  end

  test "revision singleton cannot be reset or removed" do
    revision = revision!()

    Repo.query!("""
    DO $$
    BEGIN
      BEGIN
        DELETE FROM shipping_config_revisions WHERE singleton_id = 1;
        RAISE EXCEPTION 'expected singleton delete guard';
      EXCEPTION WHEN SQLSTATE '55000' THEN
        NULL;
      END;

      BEGIN
        UPDATE shipping_config_revisions SET revision = 1 WHERE singleton_id = 1;
        RAISE EXCEPTION 'expected monotonic revision guard';
      EXCEPTION WHEN SQLSTATE '55000' THEN
        NULL;
      END;

      BEGIN
        TRUNCATE shipping_config_revisions;
        RAISE EXCEPTION 'expected singleton truncate guard';
      EXCEPTION WHEN SQLSTATE '55000' THEN
        NULL;
      END;
    END;
    $$
    """)

    assert revision!() == revision
  end

  test "a missing singleton fails closed and rejects a source mutation" do
    code = "MISSING_REVISION_#{System.unique_integer([:positive])}"

    Repo.query!("ALTER TABLE shipping_config_revisions DISABLE TRIGGER USER")
    Repo.query!("DELETE FROM shipping_config_revisions WHERE singleton_id = 1")
    Repo.query!("ALTER TABLE shipping_config_revisions ENABLE TRIGGER USER")

    assert {:error, _error} = ConfigRevision.read()

    Repo.query!("""
    DO $$
    BEGIN
      BEGIN
        INSERT INTO shipping_zones (code, country_code, active)
        VALUES ('#{code}', 'ZA', true);
        RAISE EXCEPTION 'expected missing revision guard';
      EXCEPTION WHEN SQLSTATE '55000' THEN
        NULL;
      END;
    END;
    $$
    """)

    %{rows: [[false]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM shipping_zones WHERE code = $1)", [code])
  end

  test "revision overflow rejects the source mutation" do
    code = "OVERFLOW_REVISION_#{System.unique_integer([:positive])}"

    Repo.query!("""
    UPDATE shipping_config_revisions
       SET revision = 9223372036854775807
     WHERE singleton_id = 1
    """)

    Repo.query!("""
    DO $$
    BEGIN
      BEGIN
        INSERT INTO shipping_zones (code, country_code, active)
        VALUES ('#{code}', 'ZA', true);
        RAISE EXCEPTION 'expected revision overflow guard';
      EXCEPTION WHEN SQLSTATE '22003' THEN
        NULL;
      END;
    END;
    $$
    """)

    %{rows: [[false]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM shipping_zones WHERE code = $1)", [code])
  end

  test "concurrent committed source mutations each advance the revision" do
    parent = self()
    start_revision = revision!()
    ref = make_ref()
    run_id = System.unique_integer([:positive])
    code_a = "CONCURRENT_REV_#{run_id}_A"
    code_b = "CONCURRENT_REV_#{run_id}_B"
    app_a = "jc379_revision_a_#{run_id}"
    app_b = "jc379_revision_b_#{run_id}"

    writer_a =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT set_config('application_name', $1, true)", [app_a])
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")

            Repo.query!(
              "INSERT INTO shipping_zones (code, country_code, active) VALUES ($1, 'ZA', true)",
              [code_a]
            )

            send(parent, {:revision_writer_a_locked, ref, backend_pid})

            receive do
              {:release_revision_writer_a, ^ref} -> :ok
            after
              5_000 -> Repo.rollback(:barrier_timeout)
            end
          end)
        end)
      end)

    try do
      assert_receive {:revision_writer_a_locked, ^ref, writer_a_pid}, 5_000

      writer_b =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT set_config('application_name', $1, true)", [app_b])
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:revision_writer_b_started, ref, backend_pid})
              started_at = System.monotonic_time(:microsecond)

              Repo.query!(
                "INSERT INTO shipping_zones (code, country_code, active) VALUES ($1, 'ZA', true)",
                [code_b]
              )

              {backend_pid, System.monotonic_time(:microsecond) - started_at}
            end)
          end)
        end)

      try do
        assert_receive {:revision_writer_b_started, ^ref, writer_b_pid}, 5_000

        case wait_for_revision_writer(writer_b_pid, writer_a_pid, 1_000) do
          {:ok, observation} ->
            %{rows: [[writer_connections]]} =
              Repo.query!(
                "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ($1, $2)",
                [app_a, app_b]
              )

            send(writer_a.pid, {:release_revision_writer_a, ref})

            assert {:ok, _} = Task.await(writer_a, 10_000)
            assert {:ok, {^writer_b_pid, writer_elapsed_us}} = Task.await(writer_b, 10_000)
            assert revision!() == start_revision + 2

            pool_size = Keyword.fetch!(Repo.config(), :pool_size)

            IO.puts(
              "JC379_REVISION_CONTENTION writer_a_pid=#{writer_a_pid} " <>
                "writer_b_pid=#{writer_b_pid} state=#{observation.state} " <>
                "wait_event_type=#{observation.wait_event_type} " <>
                "wait_event=#{observation.wait_event} " <>
                "blocker_pids=#{inspect(observation.blocker_pids)} " <>
                "wait_us=#{observation.wait_us} writer_elapsed_us=#{writer_elapsed_us} " <>
                "writer_connections=#{writer_connections} pool_size=#{pool_size}"
            )

          {:error, diagnostics} ->
            send(writer_a.pid, {:release_revision_writer_a, ref})
            writer_a_result = await_writer_result(writer_a)
            writer_b_result = await_writer_result(writer_b)
            final_revision = revision!()

            flunk(
              "concurrent Shipping mutation did not wait on the revision singleton: " <>
                "#{inspect(%{writer_a_pid: writer_a_pid, writer_b_pid: writer_b_pid, diagnostics: diagnostics, writer_a_result: writer_a_result, writer_b_result: writer_b_result, final_revision: final_revision})}"
            )
        end
      after
        if Process.alive?(writer_b.pid), do: Task.shutdown(writer_b, :brutal_kill)
      end
    after
      send(writer_a.pid, {:release_revision_writer_a, ref})
      if Process.alive?(writer_a.pid), do: Task.shutdown(writer_a, :brutal_kill)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM shipping_zones WHERE code = ANY($1)", [[code_a, code_b]])
      end)
    end
  end

  defp wait_for_revision_writer(writer_pid, blocker_pid, attempts_left) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT state, wait_event_type, wait_event, pg_blocking_pids(pid), query,
               GREATEST(0, floor(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)) * 1000000)::bigint)
        FROM pg_stat_activity
        WHERE pid = $1
        """,
        [writer_pid]
      )

    case rows do
      [["active", "Lock", wait_event, blockers, query, wait_us]]
      when is_list(blockers) and is_binary(query) ->
        if blocker_pid in blockers and
             String.contains?(String.downcase(query), "insert into shipping_zones") do
          {:ok,
           %{
             state: "active",
             wait_event_type: "Lock",
             wait_event: wait_event,
             blocker_pids: blockers,
             query: query,
             wait_us: wait_us
           }}
        else
          retry_wait_for_revision_writer(writer_pid, blocker_pid, attempts_left)
        end

      _rows ->
        retry_wait_for_revision_writer(writer_pid, blocker_pid, attempts_left)
    end
  end

  defp retry_wait_for_revision_writer(writer_pid, blocker_pid, attempts_left)
       when attempts_left > 0 do
    receive do
    after
      1 -> wait_for_revision_writer(writer_pid, blocker_pid, attempts_left - 1)
    end
  end

  defp retry_wait_for_revision_writer(writer_pid, blocker_pid, _attempts_left) do
    {:error, revision_lock_diagnostics([writer_pid, blocker_pid])}
  end

  defp revision_lock_diagnostics(writer_pids) do
    %{rows: activity} =
      Repo.query!(
        """
        SELECT pid, application_name, state, wait_event_type, wait_event,
               pg_blocking_pids(pid), query
        FROM pg_stat_activity
        WHERE pid = ANY($1::integer[])
        ORDER BY pid
        """,
        [writer_pids]
      )

    %{rows: locks} =
      Repo.query!(
        """
        SELECT pid, locktype, mode, granted, relation::regclass::text,
               page, tuple, virtualxid, transactionid, classid, objid, objsubid
        FROM pg_locks
        WHERE pid = ANY($1::integer[])
        ORDER BY pid, locktype, mode
        """,
        [writer_pids]
      )

    %{activity: activity, locks: locks}
  end

  defp await_writer_result(task) do
    case Task.yield(task, 10_000) do
      nil -> {:timeout, Task.shutdown(task, :brutal_kill)}
      result -> result
    end
  end

  test "all source tables install statement triggers for DML and truncate" do
    result =
      Repo.query!("""
      SELECT table_name, trigger_name, tgtype
      FROM (
        VALUES
          ('shipping_zones', 'shipping_zones_revision_dml'),
          ('shipping_zones', 'shipping_zones_revision_truncate'),
          ('shipping_methods', 'shipping_methods_revision_dml'),
          ('shipping_methods', 'shipping_methods_revision_truncate'),
          ('shipping_rates', 'shipping_rates_revision_dml'),
          ('shipping_rates', 'shipping_rates_revision_truncate')
      ) AS expected(table_name, trigger_name)
      LEFT JOIN pg_trigger trigger_row
        ON trigger_row.tgrelid = expected.table_name::regclass
       AND trigger_row.tgname = expected.trigger_name
       AND NOT trigger_row.tgisinternal
      ORDER BY table_name, trigger_name
      """)

    assert result.rows == [
             ["shipping_methods", "shipping_methods_revision_dml", 30],
             ["shipping_methods", "shipping_methods_revision_truncate", 34],
             ["shipping_rates", "shipping_rates_revision_dml", 30],
             ["shipping_rates", "shipping_rates_revision_truncate", 34],
             ["shipping_zones", "shipping_zones_revision_dml", 30],
             ["shipping_zones", "shipping_zones_revision_truncate", 34]
           ]

    assert Enum.all?(result.rows, fn [_table, _trigger, trigger_type] ->
             is_integer(trigger_type)
           end)

    assert Enum.all?(result.rows, fn [_table, trigger, trigger_type] ->
             if String.ends_with?(trigger, "truncate"),
               do: Bitwise.band(trigger_type, 32) == 32,
               else: Bitwise.band(trigger_type, 4 + 8 + 16) == 4 + 8 + 16
           end)
  end

  defp revision! do
    %{rows: [[revision]]} =
      Repo.query!("SELECT revision FROM shipping_config_revisions WHERE singleton_id = 1")

    revision
  end

  defp create_zone! do
    ShippingZone
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "REV_ZONE_#{System.unique_integer([:positive])}",
        country_code: "ZA",
        active: true
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_method! do
    ShippingMethod
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "REV_METHOD_#{System.unique_integer([:positive])}",
        name: "Revision Method",
        active: true
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_rule!(zone_id, method_id) do
    ShippingRateRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "REV_RULE_#{System.unique_integer([:positive])}",
        currency: "USD",
        shipping_zone_id: zone_id,
        shipping_method_id: method_id,
        shipping_cost_minor: 500,
        active: true
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp update_zone!(zone, country_code) do
    zone
    |> Ash.Changeset.for_update(
      :update,
      %{country_code: country_code},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp update_method!(method, name) do
    method
    |> Ash.Changeset.for_update(:update, %{name: name}, context: %{system?: true})
    |> Ash.update!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp update_rule!(rule, amount) do
    rule
    |> Ash.Changeset.for_update(
      :update,
      %{shipping_cost_minor: amount},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end
end
