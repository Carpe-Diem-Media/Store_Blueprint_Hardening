defmodule Store.Orders.MembershipWriterBoundary do
  @moduledoc """
  Fixed, read-only identity probe for the isolated DEV/TEST writer process.

  The job-local OS launcher authenticates the operator using kernel identities
  and a command-specific sudo grant. Its writer UID alone can read the root-owned
  connection file. This module accepts no actor, SQL, environment credentials or
  invocation parameters. Calling it from the ordinary runtime grants no authority.

  This probe does not evaluate Pricing or accept allocation evidence. No local or
  production installation is enabled by compiling the module.
  """

  import Bitwise, only: [band: 2]

  @connection_file "/opt/store-membership-writer-ci/private/connection.json"
  @writer "model_b_allocation_writer"

  @doc """
  Checks the isolated OS/database identity and exits without financial writes.

  Requires a fresh process with Store stopped and the private CI connection file.
  Starts Postgrex dependencies only. The fixed launcher enforces a 15-second
  process deadline; the connection and query each have a two-second timeout.
  All authentication/bootstrap errors return a scrubbed denial.
  """
  @spec probe() :: :ok | {:error, :writer_boundary_denied}
  def probe do
    with false <- store_started?(),
         {:ok, credentials} <- credentials(),
         true <- writer_uid?(credentials["writer_uid"]),
         {:ok, _} <- Application.ensure_all_started(:postgrex),
         {:ok, connection} <- connect(credentials) do
      try do
        verify(connection, credentials["writer_uid"])
      after
        if Process.alive?(connection), do: GenServer.stop(connection, :normal, 1_000)
      end
    else
      _ -> {:error, :writer_boundary_denied}
    end
  rescue
    _ -> {:error, :writer_boundary_denied}
  catch
    _, _ -> {:error, :writer_boundary_denied}
  end

  defp credentials do
    with {:ok, %{type: :regular, uid: 0, mode: mode, size: size}} <-
           File.lstat(@connection_file),
         true <- band(mode, 0o777) == 0o440 and size in 1..4096,
         {:ok, encoded} <- File.read(@connection_file),
         {:ok,
          %{
            "hostname" => "127.0.0.1",
            "port" => 55433,
            "database" => "model_b_role_proof",
            "username" => @writer,
            "password" => password,
            "writer_uid" => uid
          } = credentials} <- Jason.decode(encoded),
         true <-
           map_size(credentials) == 6 and is_binary(password) and
             byte_size(password) in 32..256 and is_integer(uid) and uid > 0 do
      {:ok, credentials}
    else
      _ -> :error
    end
  end

  defp writer_uid?(uid) do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, real, effective, saved, filesystem] <-
           Regex.run(~r/^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)$/m, status) do
      Enum.all?([real, effective, saved, filesystem], &(&1 == Integer.to_string(uid)))
    else
      _ -> false
    end
  end

  defp connect(credentials) do
    Postgrex.start_link(
      hostname: credentials["hostname"],
      port: credentials["port"],
      database: credentials["database"],
      username: credentials["username"],
      password: credentials["password"],
      connect_timeout: 2_000,
      timeout: 2_000,
      backoff_type: :stop,
      show_sensitive_data_on_connection_error: false
    )
  end

  defp verify(connection, uid) do
    # Fixed SQL proves actual login identity and absence of escalation. No
    # SET ROLE, session flags, caller query or financial write is accepted.
    sql = """
    SELECT current_user::text, session_user::text, pg_backend_pid(),
      pg_has_role(current_user, 'model_b_owner', 'MEMBER') OR
        pg_has_role(current_user, 'model_b_migrator', 'MEMBER'),
      rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls
    FROM pg_catalog.pg_roles WHERE rolname = current_user
    """

    case Postgrex.query(connection, sql, [], timeout: 2_000) do
      {:ok, %{rows: [[@writer, @writer, backend_pid, false, false]]}} ->
        IO.puts(
          Jason.encode!(%{
            database_role: @writer,
            session_role: @writer,
            os_uid: uid,
            os_pid: System.pid(),
            backend_pid: backend_pid,
            privileged_membership: false,
            store_started: store_started?()
          })
        )

        :ok

      _ ->
        {:error, :writer_boundary_denied}
    end
  end

  defp store_started? do
    Enum.any?(Application.started_applications(), fn {app, _, _} ->
      app in [:store, :phoenix, :oban]
    end)
  end
end
