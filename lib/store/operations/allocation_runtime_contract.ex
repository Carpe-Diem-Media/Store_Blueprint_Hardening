defmodule Store.Operations.AllocationRuntimeContract do
  @moduledoc """
  Fail-closed deployment contract for the dormant allocation foundation.

  The operator supplies a migration login that can explicitly assume a distinct
  NOLOGIN object owner. Both configured runtime logins are authenticated and must
  have the frozen legacy column ACLs, allocation SELECT, and only the two nested
  invoker EXECUTEs. This module checks permissions; it never grants them.

  Migration staging stops before allocation triggers. A failed check leaves only
  staged schema, and rerunning after an explicitly approved ACL correction is safe.
  Existing deployments require an authorized role inventory before using this path.
  """
  alias Ecto.Adapters.SQL

  @stage 20_261_116_195_330
  @foundation_versions [
    20_261_116_193_824,
    20_261_116_195_248,
    20_261_116_195_306,
    20_261_116_195_330,
    20_261_116_195_400,
    20_261_116_195_500,
    20_261_116_195_600,
    20_261_116_204_642,
    20_261_117_120_000
  ]

  defmodule MigrationRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :store, adapter: Ecto.Adapters.Postgres
  end

  @doc "Checks effective ACLs for the two authenticated runtime principal names. No writes."
  @spec check!(Ecto.Repo.t(), [String.t()]) :: :ok
  def check!(repo, roles) do
    path = Application.app_dir(:store, "priv/repo/contracts")

    columns =
      path |> Path.join("allocation_legacy_columns.json") |> File.read!() |> Jason.decode!()

    sql = path |> Path.join("allocation_runtime_preflight.sql") |> File.read!()
    %{rows: rows} = SQL.query!(repo, sql, [roles, columns], log: false)
    failures = for [name, passed] <- rows, passed != true, do: name

    if failures != [] do
      raise "allocation runtime preflight failed: #{Enum.join(failures, ",")}"
    end

    :ok
  end

  @doc "Rejects pending migrations or missing, altered or disabled allocation protections."
  @spec guard_standard_migrations!(Ecto.Repo.t()) :: :ok
  def guard_standard_migrations!(repo) do
    %{rows: [[table]]} = SQL.query!(repo, "SELECT to_regclass('public.schema_migrations')", [])

    installed? =
      table != nil and
        SQL.query!(repo, "SELECT count(*)=9 FROM schema_migrations WHERE version=ANY($1)", [
          @foundation_versions
        ]).rows == [[true]]

    unless installed?,
      do: raise("allocation triggers pending; use Store.Release.migrate_allocation_foundation/0")

    check_protections!(repo)
  end

  @doc "Checks the fixed protection trigger manifest after installation. No writes."
  @spec check_protections!(Ecto.Repo.t()) :: :ok
  def check_protections!(repo) do
    sql =
      :store
      |> Application.app_dir("priv/repo/contracts/allocation_protection_postflight.sql")
      |> File.read!()

    %{rows: failures} = SQL.query!(repo, sql, [], log: false)

    if failures != [] do
      raise "allocation protection postflight failed: #{Enum.join(List.flatten(failures), ",")}"
    end

    :ok
  end

  @doc "Stages and checks the supported role model before applying trigger migrations."
  @spec migrate!([keyword()], keyword(), String.t()) :: map()
  def migrate!(runtime_configs, migration_config, owner) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    identities = Enum.map(runtime_configs, &runtime_identity!/1)
    roles = Enum.map(identities, &hd/1)

    config =
      Keyword.merge(connection_opts!(migration_config),
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        parameters: [role: owner, application_name: "jc382_allocation_migration"],
        show_sensitive_data_on_connection_error: false
      )

    {:ok, pid} = MigrationRepo.start_link(config)

    try do
      %{rows: [[^owner, database, address, port, false]]} =
        SQL.query!(
          MigrationRepo,
          "SELECT current_user::text,current_database()::text,inet_server_addr()::text,inet_server_port(),rolcanlogin FROM pg_roles WHERE rolname=current_user",
          [],
          log: false
        )

      unless Enum.all?(identities, fn [role, db, addr, p] ->
               role != owner and addr != nil and p != nil and
                 [db, addr, p] == [database, address, port]
             end),
             do: raise("allocation runtime preflight failed: identity_or_database_mismatch")

      path = Application.app_dir(:store, "priv/repo/migrations")
      _staged_versions = Ecto.Migrator.run(MigrationRepo, path, :up, to: @stage, log: false)
      check!(MigrationRepo, roles)
      versions = Ecto.Migrator.run(MigrationRepo, path, :up, all: true, log: false)
      check!(MigrationRepo, roles)
      check_protections!(MigrationRepo)
      %{status: "ok", runtime_roles: roles, migrated_versions: versions}
    after
      Supervisor.stop(pid)
    end
  end

  defp runtime_identity!(config) do
    opts =
      Keyword.put(connection_opts!(config), :parameters,
        application_name: "jc382_allocation_identity"
      )

    {:ok, conn} = Postgrex.start_link(opts)

    try do
      %{rows: [[role, session, db, address, port]]} =
        Postgrex.query!(
          conn,
          "SELECT current_user::text,session_user::text,current_database()::text,inet_server_addr()::text,inet_server_port()",
          []
        )

      unless role == session,
        do: raise("allocation runtime preflight failed: runtime_role_switch")

      [role, db, address, port]
    after
      GenServer.stop(conn)
    end
  end

  defp connection_opts!(config) do
    config =
      case Keyword.get(config, :url) do
        nil -> config
        url -> Keyword.merge(config, Ecto.Repo.Supervisor.parse_url(url))
      end

    config
    |> Keyword.take([
      :username,
      :password,
      :hostname,
      :port,
      :database,
      :ssl,
      :socket_options,
      :prepare
    ])
    |> Keyword.put(:show_sensitive_data_on_connection_error, false)
  rescue
    Ecto.InvalidURLError ->
      reraise %RuntimeError{
                message: "allocation runtime preflight failed: invalid_connection_config"
              },
              __STACKTRACE__
  end
end
