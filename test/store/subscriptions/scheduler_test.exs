defmodule Store.Subscriptions.SchedulerTest do
  use ExUnit.Case, async: false

  alias Store.Subscriptions.Scheduler

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

  test "calendar boundaries use the billing timezone and propagate invalid zones" do
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

    for timezone <- [nil, "", "Not/A_Real_Zone"] do
      plan = %{
        interval_unit: :day,
        interval_count: 1,
        billing_timezone: timezone
      }

      assert {:error, %Store.Support.Errors.Error{code: "INVALID_BILLING_TIMEZONE"}} =
               Scheduler.advance_period_end(~U[2026-01-01 00:00:00Z], plan)

      assert {:error, %Store.Support.Errors.Error{code: "INVALID_BILLING_TIMEZONE"}} =
               Scheduler.initial_period(~U[2026-01-01 00:00:00Z], plan)

      assert {:error, %Store.Support.Errors.Error{code: "INVALID_BILLING_TIMEZONE"}} =
               Scheduler.next_period(~U[2026-01-01 00:00:00Z], plan)
    end
  end

  test "grace_expires_at adds grace_period_days in whole-day increments" do
    past_due_since = DateTime.from_naive!(~N[2026-01-01 00:00:00], "Etc/UTC")
    plan = %{grace_period_days: 5}

    assert DateTime.from_naive!(~N[2026-01-06 00:00:00], "Etc/UTC") ==
             Scheduler.grace_expires_at(past_due_since, plan)
  end
end
