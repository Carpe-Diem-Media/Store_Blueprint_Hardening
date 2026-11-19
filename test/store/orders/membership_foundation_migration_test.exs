defmodule Store.MembershipAllocationUpgradeTestRepo do
  use Ecto.Repo, otp_app: :store, adapter: Ecto.Adapters.Postgres
end

defmodule Store.Orders.MembershipFoundationMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Store.Operations.AllocationRuntimeContract
  alias Store.TestSupport.IsolatedMigrationDatabase
  @moduletag :real_connections

  test "fresh empty foundation rolls back to accepted main and upgrades again" do
    db =
      IsolatedMigrationDatabase.start!(
        "jc382_empty_upgrade",
        Store.MembershipAllocationUpgradeTestRepo
      )

    try do
      path = Application.app_dir(:store, "priv/repo/migrations")

      assert length(Ecto.Migrator.run(db.repo, path, :down, to: 20_261_116_193_823, log: false)) ==
               9

      assert %{rows: [[nil]]} =
               SQL.query!(
                 db.repo,
                 "SELECT to_regclass('public.order_line_component_allocation_sets')",
                 []
               )

      assert length(Ecto.Migrator.run(db.repo, path, :up, all: true, log: false)) == 9

      assert length(Ecto.Migrator.run(db.repo, path, :down, to: 20_261_116_195_399, log: false)) ==
               5

      assert %{rows: [[true]]} =
               SQL.query!(
                 db.repo,
                 "SELECT to_regprocedure('public.membership_allocation_validate_order(uuid)') IS NOT NULL",
                 []
               )

      assert_raise RuntimeError, ~r/allocation triggers pending/, fn ->
        AllocationRuntimeContract.guard_standard_migrations!(db.repo)
      end

      assert length(Ecto.Migrator.run(db.repo, path, :up, all: true, log: false)) == 5
      assert_protection_attestation(db.repo)
    after
      IsolatedMigrationDatabase.stop!(db)
    end
  end

  defp assert_protection_attestation(repo) do
    assert :ok = AllocationRuntimeContract.guard_standard_migrations!(repo)

    %{rows: triggers} =
      SQL.query!(
        repo,
        """
        SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid)
        FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_proc p ON p.oid=t.tgfoid
        WHERE p.pronamespace='public'::regnamespace
          AND p.proname LIKE 'membership_allocation_%' AND NOT t.tgisinternal
        ORDER BY c.relname, t.tgname
        """,
        []
      )

    assert length(triggers) == 20

    for [table, name, definition] <- triggers,
        fault <- [:disabled, :replica_only, :missing, :wrong_binding] do
      assert_fault_refused(repo, table, name, definition, fault)
    end
  end

  defp assert_fault_refused(repo, table, name, definition, fault) do
    assert {:error, :fault_rolled_back} =
             repo.transaction(fn ->
               apply_fault(repo, table, name, definition, fault)

               error =
                 assert_raise RuntimeError, ~r/allocation protection postflight failed/, fn ->
                   AllocationRuntimeContract.guard_standard_migrations!(repo)
                 end

               assert Exception.message(error) =~ name
               repo.rollback(:fault_rolled_back)
             end)

    assert :ok = AllocationRuntimeContract.guard_standard_migrations!(repo)
  end

  defp apply_fault(repo, table, name, _definition, :disabled) do
    SQL.query!(repo, ~s(ALTER TABLE public."#{table}" DISABLE TRIGGER "#{name}"), [])
  end

  defp apply_fault(repo, table, name, _definition, :replica_only) do
    SQL.query!(repo, ~s(ALTER TABLE public."#{table}" ENABLE REPLICA TRIGGER "#{name}"), [])
  end

  defp apply_fault(repo, table, name, _definition, :missing) do
    SQL.query!(repo, ~s(DROP TRIGGER "#{name}" ON public."#{table}"), [])
  end

  defp apply_fault(repo, table, name, definition, :wrong_binding) do
    SQL.query!(repo, ~s(DROP TRIGGER "#{name}" ON public."#{table}"), [])

    replacement =
      if String.contains?(definition, "membership_allocation_no_truncate()"),
        do: "membership_allocation_lock_order()",
        else: "membership_allocation_no_truncate()"

    changed = Regex.replace(~r/membership_allocation_[a-z_]+\(\)/, definition, replacement)
    SQL.query!(repo, changed, [])
  end
end
