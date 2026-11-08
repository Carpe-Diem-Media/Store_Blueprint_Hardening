defmodule Store.Subscriptions.BillingTimezone do
  @moduledoc """
  Validates commercial billing timezones against the configured calendar database.

  Plan authoring and revision publication use this check so persisted contracts
  cannot depend on a timezone that the runtime cannot resolve.
  """

  alias Store.Support.Errors.Error

  @probe ~U[2000-01-01 00:00:00Z]

  @doc """
  Checks that `timezone` resolves through `database` at a fixed UTC instant.

  The default database is the one configured for the running Elixir application.
  Invalid or unsupported values return a registry-backed error.
  """
  @spec validate(term(), module()) :: :ok | {:error, Error.t()}
  def validate(timezone, database \\ Calendar.get_time_zone_database())

  def validate(timezone, database) when is_binary(timezone) and byte_size(timezone) > 0 do
    case DateTime.shift_zone(@probe, timezone, database) do
      {:ok, _datetime} -> :ok
      {:error, reason} -> invalid_timezone(timezone, reason)
    end
  end

  def validate(timezone, _database), do: invalid_timezone(timezone, :invalid_timezone)

  defp invalid_timezone(timezone, reason) do
    {:error,
     Error.new(
       "INVALID_BILLING_TIMEZONE",
       "billing timezone is invalid or unsupported",
       %{billing_timezone: timezone, reason: reason}
     )}
  end
end
