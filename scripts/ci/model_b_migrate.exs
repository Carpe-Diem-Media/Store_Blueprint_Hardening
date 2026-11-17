# Invoked only by the job-owned role-security harness, with migrator credentials.
target = System.fetch_env!("PGDATABASE")

fixture? =
  target == "model_b_fixture_tests" and System.get_env("PGUSER") == "model_b_fixture_harness"

if System.get_env("GITHUB_ACTIONS") != "true" or
     System.get_env("MODEL_B_CI_DISPOSABLE") != "true" or
     (target != "model_b_role_proof" and not fixture?) do
  raise "isolated CI migration target required"
end

{:ok, _} = Application.ensure_all_started(:ecto_sql)

Application.put_env(:store, Store.Repo,
  username: System.fetch_env!("PGUSER"),
  password: System.fetch_env!("PGPASSWORD"),
  hostname: "127.0.0.1",
  port: 55433,
  database: target,
  parameters: if(fixture?, do: [], else: [role: "model_b_owner"]),
  pool: DBConnection.ConnectionPool,
  pool_size: 1,
  show_sensitive_data_on_connection_error: false
)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Store.Repo, fn repo ->
    Ecto.Migrator.run(repo, Application.app_dir(:store, "priv/repo/migrations"), :up, all: true)
  end)

IO.puts("PASS Store migrations on job-owned target #{target}")
