defmodule Store.Subscriptions.SchedulerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Store.Subscriptions.Scheduler

  property "next_period always advances time for supported interval units" do
    check all(
            unix <- integer(1_735_000_000..1_900_000_000),
            interval_unit <- member_of([:day, :month, :year]),
            interval_count <- integer(1..12),
            anchor_mode <- member_of([:start_anniversary, :fixed_day_of_month]),
            anchor_day <- integer(1..31)
          ) do
      period_start_at = DateTime.from_unix!(unix)

      plan = %{
        interval_unit: interval_unit,
        interval_count: interval_count,
        anchor_mode: anchor_mode,
        anchor_day_of_month: anchor_day,
        billing_timezone: "Etc/UTC"
      }

      {:ok, period_end_at} = Scheduler.advance_period_end(period_start_at, plan)

      assert DateTime.compare(period_end_at, period_start_at) == :gt

      {:ok, next_period} = Scheduler.next_period(period_end_at, plan)

      assert DateTime.compare(
               next_period.current_period_end_at,
               next_period.current_period_start_at
             ) == :gt

      assert next_period.next_renewal_at == next_period.current_period_end_at
    end
  end

  property "fixed day-of-month anchor never exceeds calendar month length" do
    check all(
            unix <- integer(1_735_000_000..1_900_000_000),
            anchor_day <- integer(1..31),
            interval_count <- integer(1..24)
          ) do
      period_start_at = DateTime.from_unix!(unix)

      plan = %{
        interval_unit: :month,
        interval_count: interval_count,
        anchor_mode: :fixed_day_of_month,
        anchor_day_of_month: anchor_day,
        billing_timezone: "Etc/UTC"
      }

      {:ok, period_end_at} = Scheduler.advance_period_end(period_start_at, plan)
      days_in_month = Date.days_in_month(Date.new!(period_end_at.year, period_end_at.month, 1))

      assert period_end_at.day <= days_in_month
      assert period_end_at.day >= 1
    end
  end

  property "renewal_key is stable for identical inputs" do
    check all(unix <- integer(1_735_000_000..1_900_000_000)) do
      subscription_id = "0192168f-0f4b-7df3-b1e8-f8ef8e19620a"
      period_end_at = DateTime.from_unix!(unix)

      assert Scheduler.renewal_key(subscription_id, period_end_at) ==
               Scheduler.renewal_key(subscription_id, period_end_at)
    end
  end
end
