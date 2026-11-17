defmodule Store.MembershipAllocationUpgradeTestRepo do
  use Ecto.Repo, otp_app: :store, adapter: Ecto.Adapters.Postgres
end

defmodule Store.Orders.MembershipFoundationMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
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
    after
      IsolatedMigrationDatabase.stop!(db)
    end
  end
end
