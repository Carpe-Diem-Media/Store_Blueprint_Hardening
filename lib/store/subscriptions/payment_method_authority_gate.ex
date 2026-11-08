defmodule Store.Subscriptions.PaymentMethodAuthorityGate do
  @moduledoc """
  Coordinates Subscription payment-method binding and StoredPaymentMethod writes.

  Advisory transaction locks serialize cooperating writers. Subscription and
  StoredPaymentMethod rows remain authoritative, so callers re-read them after
  acquiring the matching gates.
  """

  alias Store.Repo

  @namespace "store:subscription-payment-method-authority:v1"
  @mutation_query_timeout_ms 5_000

  @type lock_error :: :transaction_required | :lock_unavailable

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
    with :ok <- require_transaction() do
      acquire_xact(binding_key(user_id, provider))
    end
  end

  @doc "Acquires the method gate inside a transaction after its owner binding gate."
  @spec lock_method_for_transaction(atom(), String.t(), String.t()) ::
          :ok | {:error, lock_error()}
  def lock_method_for_transaction(provider, customer_ref, payment_method_ref) do
    with :ok <- require_transaction() do
      acquire_xact(method_key(provider, customer_ref, payment_method_ref))
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
end
