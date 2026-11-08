defmodule Store.Subscriptions.SchedulerTest do
  use ExUnit.Case, async: false

  alias Store.Subscriptions.{BillingTimezone, Scheduler}

  defmodule ReconfiguringDatabase do
    @moduledoc false
    @behaviour Calendar.TimeZoneDatabase

    @impl true
    def time_zone_period_from_utc_iso_days(days, timezone) do
      Application.put_env(:elixir, :time_zone_database, Calendar.UTCOnlyTimeZoneDatabase)
      Tz.TimeZoneDatabase.time_zone_period_from_utc_iso_days(days, timezone)
    end

    @impl true
    def time_zone_periods_from_wall_datetime(datetime, timezone),
      do: Tz.TimeZoneDatabase.time_zone_periods_from_wall_datetime(datetime, timezone)
  end

  defmodule ProbeOnlyDatabase do
    @moduledoc false
    @behaviour Calendar.TimeZoneDatabase
    @probe_day Calendar.ISO.date_to_iso_days(2000, 1, 1)

    @impl true
    def time_zone_period_from_utc_iso_days({@probe_day, _fraction} = days, timezone),
      do: Tz.TimeZoneDatabase.time_zone_period_from_utc_iso_days(days, timezone)

    def time_zone_period_from_utc_iso_days(_days, _timezone),
      do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(datetime, timezone),
      do: Tz.TimeZoneDatabase.time_zone_periods_from_wall_datetime(datetime, timezone)
  end

  defmodule RejectsWallTimeDatabase do
    @moduledoc false
    @behaviour Calendar.TimeZoneDatabase

    @impl true
    def time_zone_period_from_utc_iso_days(days, timezone),
      do: Tz.TimeZoneDatabase.time_zone_period_from_utc_iso_days(days, timezone)

    @impl true
    def time_zone_periods_from_wall_datetime(_datetime, _timezone),
      do: {:error, :time_zone_not_found}
  end

  test "renewal_key is deterministic and period-specific" do
    subscription_id = "0192168f-0f4b-7df3-b1e8-f8ef8e19620a"
    period_end_at = DateTime.from_unix!(1_767_200_000)

    first = Scheduler.renewal_key(subscription_id, period_end_at)
    second = Scheduler.renewal_key(subscription_id, period_end_at)
    later = Scheduler.renewal_key(subscription_id, DateTime.add(period_end_at, 1, :day))

    assert first == second
    assert first != later
  end

  test "fixed_day_of_month plans clamp to end-of-month when anchor day is missing in target month" do
    period_start_at = DateTime.from_naive!(~N[2026-01-31 08:15:00], "Etc/UTC")

    plan = %{
      interval_unit: :month,
      interval_count: 1,
      anchor_mode: :fixed_day_of_month,
      anchor_day_of_month: 31,
      billing_timezone: "Etc/UTC"
    }

    {:ok, period_end} = Scheduler.advance_period_end(period_start_at, plan)

    assert period_end.year == 2026
    assert period_end.month == 2
    assert period_end.day == 28
  end

  test "start_anniversary monthly plans keep day for regular months" do
    period_start_at = DateTime.from_naive!(~N[2026-05-10 14:30:00], "Etc/UTC")

    plan = %{
      interval_unit: :month,
      interval_count: 1,
      anchor_mode: :start_anniversary,
      billing_timezone: "Etc/UTC"
    }

    assert {:ok, period_end} = Scheduler.advance_period_end(period_start_at, plan)

    assert period_end.year == 2026
    assert period_end.month == 6
    assert period_end.day == 10
    assert period_end.hour == 14
    assert period_end.minute == 30
  end

  test "calendar boundaries use the billing timezone" do
    cases = [
      {~U[2026-01-31 10:00:00Z], :month, "Etc/UTC", ~U[2026-02-28 10:00:00Z]},
      {~U[2024-02-29 10:00:00Z], :year, "Etc/UTC", ~U[2025-02-28 10:00:00Z]},
      {~U[2026-01-30 22:30:00Z], :month, "Africa/Johannesburg", ~U[2026-02-27 22:30:00Z]},
      {~U[2024-02-28 22:30:00Z], :year, "Africa/Johannesburg", ~U[2025-02-27 22:30:00Z]},
      {~U[2023-02-26 01:30:00Z], :month, "Europe/Berlin", ~U[2023-03-26 00:59:59.999999Z]},
      {~U[2023-09-29 00:30:00Z], :month, "Europe/Berlin", ~U[2023-10-29 00:30:00Z]},
      {~U[2023-03-25 12:00:00Z], :day, "Europe/Berlin", ~U[2023-03-26 12:00:00Z]}
    ]

    Enum.each(cases, fn {start, unit, timezone, expected} ->
      assert {:ok, actual} =
               Scheduler.advance_period_end(start, %{
                 interval_unit: unit,
                 interval_count: 1,
                 anchor_mode: :start_anniversary,
                 billing_timezone: timezone
               })

      assert DateTime.compare(actual, expected) == :eq
    end)
  end

  test "missing and invalid zones fail for every cadence and period API" do
    for unit <- [:day, :month, :year] do
      base = %{interval_unit: unit, interval_count: 1}

      plans =
        [base | Enum.map([nil, "", "Not/A_Real_Zone"], &Map.put(base, :billing_timezone, &1))]

      Enum.each(plans, &assert_timezone_failure/1)

      assert_timezone_failure(
        Map.merge(base, %{:billing_timezone => nil, "billing_timezone" => "Etc/UTC"})
      )
    end
  end

  test "a real zone unsupported by the configured database fails for every cadence" do
    with_database(Calendar.UTCOnlyTimeZoneDatabase, fn ->
      for unit <- [:day, :month, :year] do
        assert_timezone_failure(%{interval_unit: unit, billing_timezone: "Africa/Johannesburg"})
      end
    end)
  end

  test "conversion failures after the validation probe return explicit errors" do
    for database <- [ProbeOnlyDatabase, RejectsWallTimeDatabase] do
      with_database(database, fn ->
        assert :ok = BillingTimezone.validate("Africa/Johannesburg")

        for unit <- [:month, :year] do
          assert_timezone_failure(%{interval_unit: unit, billing_timezone: "Africa/Johannesburg"})
        end
      end)
    end
  end

  test "day arithmetic retains the captured database if configuration changes during validation" do
    start = DateTime.shift_zone!(~U[2023-03-25 12:00:00Z], "Europe/Berlin")

    with_database(ReconfiguringDatabase, fn ->
      assert {:ok, actual} =
               Scheduler.advance_period_end(start, %{
                 interval_unit: :day,
                 billing_timezone: "Europe/Berlin"
               })

      assert DateTime.compare(actual, ~U[2023-03-26 12:00:00Z]) == :eq
    end)
  end

  test "string-keyed contracts use their explicit billing timezone" do
    assert {:ok, ~U[2026-02-27 22:30:00Z]} =
             Scheduler.advance_period_end(~U[2026-01-30 22:30:00Z], %{
               "interval_unit" => :month,
               "billing_timezone" => "Africa/Johannesburg"
             })
  end

  test "grace_expires_at adds grace_period_days in whole-day increments" do
    past_due_since = DateTime.from_naive!(~N[2026-01-01 00:00:00], "Etc/UTC")
    plan = %{grace_period_days: 5}

    assert DateTime.from_naive!(~N[2026-01-06 00:00:00], "Etc/UTC") ==
             Scheduler.grace_expires_at(past_due_since, plan)
  end

  defp assert_timezone_failure(plan) do
    for operation <- [:advance_period_end, :initial_period, :next_period] do
      assert {:error, %Store.Support.Errors.Error{code: "INVALID_BILLING_TIMEZONE"}} =
               apply(Scheduler, operation, [~U[2026-01-01 00:00:00Z], plan])
    end
  end

  defp with_database(database, fun) do
    previous = Application.fetch_env(:elixir, :time_zone_database)

    try do
      Application.put_env(:elixir, :time_zone_database, database)
      fun.()
    after
      case previous do
        {:ok, database} -> Application.put_env(:elixir, :time_zone_database, database)
        :error -> Application.delete_env(:elixir, :time_zone_database)
      end
    end
  end
end
