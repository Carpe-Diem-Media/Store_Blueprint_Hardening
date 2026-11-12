defmodule Store.Shipping.ConfigRevision do
  @moduledoc """
  Reads the durable Shipping configuration revision from the primary repository.

  The revision is advanced by PostgreSQL triggers in the same transaction as
  writes to Shipping zones, methods, and rate rules. Consumers must treat a
  failed or malformed read as unavailable authority.
  """

  alias Store.Repo
  alias Store.Support.Errors.Error

  @type revision :: pos_integer()

  @spec read() :: {:ok, revision()} | {:error, Error.t()}
  def read do
    case Repo.query("SELECT revision FROM shipping_config_revisions WHERE singleton_id = 1") do
      {:ok, %{rows: [[revision]]}} when is_integer(revision) and revision > 0 ->
        {:ok, revision}

      _other ->
        unavailable()
    end
  rescue
    _error -> unavailable()
  catch
    :exit, _reason -> unavailable()
  end

  defp unavailable do
    {:error, Error.new("INTERNAL_ERROR", "shipping configuration revision is unavailable")}
  end
end
