defmodule Store.Subscriptions.PaymentMethodAuthorityGate do
  @moduledoc """
  Coordinates Subscription payment-method binding and StoredPaymentMethod writes.

  Advisory locks serialize callers. Subscription and StoredPaymentMethod rows remain
  authoritative, so callers re-read them after acquiring the matching gates.
  """

  alias Store.Repo

  @namespace "store:subscription-payment-method-authority:v1"
  @mutation_query_timeout_ms 5_000
  @session_query_timeout_ms 1_000
  @dispatch_checkout_timeout_ms 60_000

  @type lock_error :: :transaction_required | :lock_unavailable
  @type session_proof :: %{
          required(:backend_pid) => pos_integer(),
          required(:binding_key) => integer(),
          required(:method_key) => integer()
        }

  @doc """
  Serializes a dispatch with cooperating binding and method writers.

  The resolver runs after the binding gate is held. The callback runs outside a
  Repo transaction and must confirm the proof immediately before adapter invocation.
  The checkout deadline bounds the database checkout. It does not prove remote
  receipt or bound the lifetime of a synchronous HTTP callback after disconnection.
  """
  @spec with_dispatch_session_gates(
          Ecto.UUID.t(),
          atom(),
          (-> {:ok, map()} | {:error, term()}),
          (map(), session_proof() -> result)
        ) :: result | {:error, term()}
        when result: var
  def with_dispatch_session_gates(user_id, provider, resolve_identity, fun) do
    dispatch_ref = make_ref()

    try do
      Repo.checkout(
        fn ->
          if Repo.in_transaction?() do
            {:error, :lock_unavailable}
          else
            binding = binding_key(user_id, provider)

            with {:ok, %{rows: [[backend_pid]]}} <-
                   Repo.query("SELECT pg_backend_pid()", [], timeout: @session_query_timeout_ms) do
              with_session_key(binding, fn ->
                with {:ok, identity} <-
                       invoke_dispatch_callback(dispatch_ref, resolve_identity, []) do
                  method =
                    method_key(identity.provider, identity.customer_ref, identity.method_ref)

                  with_session_key(method, fn ->
                    invoke_dispatch_callback(dispatch_ref, fun, [
                      identity,
                      %{
                        backend_pid: backend_pid,
                        binding_key: binding,
                        method_key: method
                      }
                    ])
                  end)
                end
              end)
            else
              _ -> {:error, :lock_unavailable}
            end
          end
        end,
        timeout: @dispatch_checkout_timeout_ms
      )
    rescue
      _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
    catch
      :throw, {^dispatch_ref, :throw, reason, stacktrace} ->
        :erlang.raise(:throw, reason, stacktrace)

      :throw, {^dispatch_ref, :exit, reason, stacktrace} ->
        :erlang.raise(:exit, reason, stacktrace)

      :throw, {^dispatch_ref, :error, reason, stacktrace} ->
        :erlang.raise(:error, reason, stacktrace)
    end
  end

  @doc """
  Confirms that the original checked-out backend still holds both session gates.

  Call this after observing the committed-claim event and immediately before
  adapter invocation. It detects an observed lost session, but cannot make
  PostgreSQL and a remote provider one atomic system.
  """
  @spec confirm_dispatch_session(session_proof()) :: :ok | {:error, :lock_unavailable}
  def confirm_dispatch_session(proof) do
    {binding_high, binding_low} = advisory_key_parts(proof.binding_key)
    {method_high, method_low} = advisory_key_parts(proof.method_key)

    query = """
    SELECT pg_backend_pid() = $1::integer
    AND EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = $1::integer
    AND granted AND objsubid = 1 AND classid::bigint = $2::bigint AND objid::bigint = $3::bigint)
    AND EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = $1::integer
    AND granted AND objsubid = 1 AND classid::bigint = $4::bigint AND objid::bigint = $5::bigint)
    """

    case Repo.query(
           query,
           [proof.backend_pid, binding_high, binding_low, method_high, method_low],
           timeout: @session_query_timeout_ms
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      _ -> {:error, :lock_unavailable}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
  end

  @doc "Returns the binding gate key using raw UUID bytes and the provider namespace."
  @spec binding_key(Ecto.UUID.t(), atom()) :: integer()
  def binding_key(user_id, provider) when is_binary(user_id) and is_atom(provider) do
    advisory_key([@namespace, "binding", Ecto.UUID.dump!(user_id), Atom.to_string(provider)])
  end

  @doc "Returns the gate key for the existing global provider method identity."
  @spec method_key(atom(), String.t(), String.t()) :: integer()
  def method_key(provider, customer_ref, payment_method_ref)
      when is_atom(provider) and is_binary(customer_ref) and is_binary(payment_method_ref) do
    advisory_key([
      @namespace,
      "method",
      Atom.to_string(provider),
      customer_ref,
      payment_method_ref
    ])
  end

  @doc "Acquires the binding gate until the current transaction ends; fails outside a transaction."
  @spec lock_binding_for_transaction(Ecto.UUID.t(), atom()) :: :ok | {:error, lock_error()}
  def lock_binding_for_transaction(user_id, provider) do
    with :ok <- require_transaction(),
         :ok <- acquire_xact(binding_key(user_id, provider)) do
      :ok
    end
  end

  @doc "Acquires the method gate inside a transaction after its owner binding gate."
  @spec lock_method_for_transaction(atom(), String.t(), String.t()) ::
          :ok | {:error, lock_error()}
  def lock_method_for_transaction(provider, customer_ref, payment_method_ref) do
    with :ok <- require_transaction(),
         :ok <- acquire_xact(method_key(provider, customer_ref, payment_method_ref)) do
      :ok
    end
  end

  @doc "Checks ownership while the caller holds the binding and global method gates."
  @spec ensure_identity_owner(Ecto.UUID.t(), atom(), String.t(), String.t()) ::
          :ok | {:error, :foreign_identity_owner | lock_error()}
  def ensure_identity_owner(user_id, provider, customer_ref, payment_method_ref) do
    query = """
    SELECT user_id::text FROM stored_payment_methods
    WHERE provider = $1 AND provider_customer_ref = $2 AND provider_payment_method_ref = $3
    LIMIT 1
    """

    with :ok <- require_transaction() do
      case Repo.query(
             query,
             [Atom.to_string(provider), customer_ref, payment_method_ref],
             timeout: @mutation_query_timeout_ms
           ) do
        {:ok, %{rows: []}} -> :ok
        {:ok, %{rows: [[^user_id]]}} -> :ok
        {:ok, %{rows: [[_foreign_user_id]]}} -> {:error, :foreign_identity_owner}
        {:error, _reason} -> {:error, :lock_unavailable}
      end
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
  end

  defp advisory_key(parts) do
    encoded = Enum.map(parts, fn part -> <<byte_size(part)::unsigned-big-32, part::binary>> end)
    <<key::signed-big-64, _rest::binary>> = :crypto.hash(:sha256, IO.iodata_to_binary(encoded))
    key
  end

  defp require_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :transaction_required}
  end

  defp acquire_xact(key) do
    case Repo.query("SELECT pg_advisory_xact_lock($1)", [key],
           timeout: @mutation_query_timeout_ms
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :lock_unavailable}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
  end

  defp with_session_key(key, fun) do
    case acquire_session_key_or_discard_owner!(key) do
      true ->
        try do
          fun.()
        after
          release_session_key_or_discard_owner!(key)
        end

      false ->
        {:error, :lock_unavailable}
    end
  end

  defp acquire_session_key_or_discard_owner!(key) do
    case Repo.query("SELECT pg_try_advisory_lock($1)", [key], timeout: @session_query_timeout_ms) do
      {:ok, %{rows: [[true]]}} -> true
      {:ok, %{rows: [[false]]}} -> false
      _ -> Process.exit(self(), :kill)
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> Process.exit(self(), :kill)
  catch
    :exit, _reason -> Process.exit(self(), :kill)
  end

  defp invoke_dispatch_callback(dispatch_ref, fun, args) do
    apply(fun, args)
  rescue
    error -> throw({dispatch_ref, :error, error, __STACKTRACE__})
  catch
    :throw, reason -> throw({dispatch_ref, :throw, reason, __STACKTRACE__})
    :exit, reason -> throw({dispatch_ref, :exit, reason, __STACKTRACE__})
  end

  defp release_session_key_or_discard_owner!(key) do
    case Repo.query("SELECT pg_advisory_unlock($1)", [key], timeout: @session_query_timeout_ms) do
      {:ok, %{rows: [[true]]}} -> :ok
      _ -> Process.exit(self(), :kill)
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> Process.exit(self(), :kill)
  catch
    :exit, _reason -> Process.exit(self(), :kill)
  end

  defp advisory_key_parts(key) do
    <<high::unsigned-big-32, low::unsigned-big-32>> = <<key::signed-big-64>>
    {high, low}
  end
end
