defmodule Store.Release do
  @moduledoc """
  Release-safe operator entrypoints for production checks, migrations, and restore audits.
  """

  alias Ecto.Migrator
  alias Store.Operations.Health

  @doc """
  Probes the isolated DEV/TEST writer identity without starting Store or writing evidence.

  Called only by the fixed operator OS launcher. Credentials have no runtime,
  owner or migrator fallback; ordinary-runtime calls fail closed.
  """
  @spec membership_writer_boundary_probe() :: :ok | {:error, :writer_boundary_denied}
  def membership_writer_boundary_probe do
    Store.Orders.MembershipWriterBoundary.probe()
  end

  @spec migrate() :: map()
  def migrate do
    run_migration_command("migrate", [migration_target(Store.Repo)])
  end

  @spec migrate_direct_repo() :: map()
  def migrate_direct_repo do
    run_migration_command("migrate_direct_repo", [migration_target(Store.DirectRepo)])
  end

  @spec migrate_all() :: map()
  def migrate_all do
    targets =
      [migration_target(Store.Repo), migration_target(Store.DirectRepo)]
      |> Enum.uniq()

    run_migration_command("migrate_all", targets)
  end

  @spec preflight() :: map()
  def preflight do
    ensure_started!()

    report =
      %{
        command: "preflight",
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        readiness: Health.ready_status(),
        runtime: Health.runtime_contract_status()
      }
      |> finalize_report()

    IO.puts(Jason.encode!(report, pretty: true))
    maybe_raise!(report)
    report
  end

  @spec restore_audit() :: map()
  def restore_audit do
    ensure_started!()

    report =
      %{
        command: "restore_audit",
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        readiness: Health.ready_status(),
        restore_audit: Health.restore_audit_status()
      }
      |> finalize_report()

    IO.puts(Jason.encode!(report, pretty: true))
    maybe_raise!(report)
    report
  end

  defp ensure_started! do
    {:ok, _} = Application.ensure_all_started(:store)
  end

  defp ensure_loaded! do
    Application.load(:store)
  end

  defp run_migration_command(command, repos) do
    ensure_loaded!()

    migrated =
      repos
      |> Enum.map(&run_repo_migrations/1)

    report =
      %{
        command: command,
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        migrated: migrated
      }
      |> finalize_report()

    IO.puts(Jason.encode!(report, pretty: true))
    maybe_raise!(report)
    report
  end

  defp run_repo_migrations(repo) do
    {:ok, _, migrated_versions} =
      Migrator.with_repo(repo, fn migration_repo ->
        Migrator.run(migration_repo, :up, all: true)
      end)

    %{
      status: "ok",
      repo: inspect(repo),
      migrated_versions: migrated_versions
    }
  rescue
    error ->
      %{
        status: "error",
        repo: inspect(repo),
        reason: Exception.message(error)
      }
  end

  defp migration_target(repo) do
    Application.get_env(:store, repo, [])
    |> Keyword.get(:migration_repo, repo)
  end

  defp finalize_report(report) do
    status =
      if Enum.all?(report, fn
           {:generated_at, _value} ->
             true

           {:command, _value} ->
             true

           {:status, _value} ->
             true

           {:migrated, values} when is_list(values) ->
             Enum.all?(values, &(Map.get(&1, :status) == "ok"))

           {_key, %{status: "ok"}} ->
             true

           _other ->
             false
         end) do
        "ok"
      else
        "error"
      end

    Map.put(report, :status, status)
  end

  defp maybe_raise!(%{status: "ok"}), do: :ok

  defp maybe_raise!(report) do
    raise "release command failed: #{report.command}"
  end
end
