# The disposable harness invokes the same preflight/migration path as the release.
unless System.get_env("MODEL_B_CI_DISPOSABLE") == "true" and
         System.get_env("PGDATABASE") == "model_b_role_proof" do
  raise "disposable contract target required"
end

config = fn user, password ->
  url = %URI{
    scheme: "ecto",
    host: "127.0.0.1",
    port: String.to_integer(System.fetch_env!("PGPORT")),
    path: "/model_b_role_proof",
    userinfo: URI.encode_www_form(user) <> ":" <> URI.encode_www_form(password)
  }

  [url: URI.to_string(url)]
end

configs =
  for {user, password} <- [
        {System.fetch_env!("MODEL_B_RUNTIME_USER"),
         System.fetch_env!("MODEL_B_RUNTIME_PASSWORD")},
        {System.fetch_env!("MODEL_B_DIRECT_RUNTIME_USER"),
         System.fetch_env!("MODEL_B_DIRECT_RUNTIME_PASSWORD")}
      ],
      do: config.(user, password)

owner = config.(System.fetch_env!("PGUSER"), System.fetch_env!("PGPASSWORD"))

try do
  Store.Operations.AllocationRuntimeContract.migrate!(configs, owner, "model_b_owner")
  IO.puts("PASS supported_allocation_runtime_preflight_and_migration")
rescue
  error in RuntimeError ->
    IO.puts(Exception.message(error))
    System.halt(1)

  _ ->
    IO.puts("FAIL supported_allocation_runtime_preflight")
    System.halt(1)
end
