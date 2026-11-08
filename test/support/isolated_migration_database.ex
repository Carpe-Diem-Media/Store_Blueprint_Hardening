defmodule Store.TestSupport.IsolatedMigrationDatabase do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  defmodule AdminRepo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :store,
      adapter: Ecto.Adapters.Postgres
  end

  @spec start!(String.t(), module(), keyword()) :: %{
          repo: module(),
          repo_pid: pid(),
          database: String.t(),
          admin_pid: pid()
        }
  def start!(tag, repo_module, opts \\ [])
      when is_binary(tag) and is_atom(repo_module) and is_list(opts) do
    pool_size = Keyword.get(opts, :pool_size, 2)
    database = isolated_database_name(tag)
    base_config = Store.Repo.config()

    admin_config =
      base_config
      |> Keyword.drop([:pool, :pool_size])
      |> Keyword.merge(database: postgres_admin_database(base_config), pool_size: 2)

    {:ok, admin_pid} = AdminRepo.start_link(Keyword.merge(admin_config, name: AdminRepo))
    Process.unlink(admin_pid)

    _ = SQL.query!(AdminRepo, "DROP DATABASE IF EXISTS \"#{database}\"", [])
    _ = SQL.query!(AdminRepo, "CREATE DATABASE \"#{database}\"", [])

    repo_config =
      base_config
      |> Keyword.drop([:pool])
      |> Keyword.merge(
        name: repo_module,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: pool_size
      )

    {:ok, repo_pid} = repo_module.start_link(repo_config)
    Process.unlink(repo_pid)

    migrations_path = Application.app_dir(:store, "priv/repo/migrations")

    {:ok, migrated_versions, _started_apps} =
      Migrator.with_repo(repo_module, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    if migrated_versions == [] do
      raise "expected isolated migration database #{database} to apply migrations, got none"
    end

    case SQL.query!(repo_module, "SELECT to_regclass('public.renewal_attempts')", []) do
      %{rows: [[nil]]} ->
        raise "isolated migration database #{database} is missing renewal_attempts after migrate"

      _ ->
        :ok
    end

    %{repo: repo_module, repo_pid: repo_pid, database: database, admin_pid: admin_pid}
  end

  def stop!(%{repo: _repo, repo_pid: repo_pid, database: database, admin_pid: admin_pid}) do
    _ = Supervisor.stop(repo_pid, :normal)
    _ = SQL.query!(AdminRepo, "DROP DATABASE IF EXISTS \"#{database}\"", [])
    _ = Supervisor.stop(admin_pid, :normal)
    :ok
  end

  @spec isolated_database_name(String.t()) :: String.t()
  def isolated_database_name(tag) do
    suffix =
      tag
      |> String.replace(~r/[^a-z0-9_]+/i, "_")
      |> String.slice(0, 32)

    "store_blueprint_migration_#{suffix}_#{System.unique_integer([:positive])}"
  end

  defp postgres_admin_database(config) do
    System.get_env("STORE_TEST_POSTGRES_ADMIN_DATABASE") ||
      config[:database] ||
      "postgres"
  end
end
