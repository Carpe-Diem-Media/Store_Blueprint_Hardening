defmodule Store.Subscriptions.JC256ContractConfigurationAuditTest do
  use Store.DataCase, async: false

  alias Store.Subscriptions.{PlanRevision, Scheduler}
  alias Store.SubscriptionsFixtures

  @reference_at ~U[2026-06-01 00:00:00Z]

  test "records which term and trial configurations publish as effective revisions" do
    configurations = [
      %{term_mode: :until_canceled, term_cycles: nil, term_end_at: nil},
      %{term_mode: :fixed_cycles, term_cycles: 1, term_end_at: nil},
      %{term_mode: :fixed_cycles, term_cycles: 3, term_end_at: nil},
      %{
        term_mode: :fixed_end_at,
        term_cycles: nil,
        term_end_at: ~U[2026-05-31 23:59:59Z]
      },
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: @reference_at},
      %{
        term_mode: :fixed_end_at,
        term_cycles: nil,
        term_end_at: ~U[2026-06-01 00:00:01Z]
      }
    ]

    for configuration <- configurations, trial_days <- [0, 14] do
      plan =
        SubscriptionsFixtures.create_subscription_plan!(
          Map.merge(configuration, %{trial_days: trial_days})
        )

      revision = SubscriptionsFixtures.create_plan_revision!(plan, %{trial_days: trial_days})

      assert revision.status == :effective
      assert revision.subscription_plan_id == plan.id
      assert revision.term_mode == configuration.term_mode
      assert revision.term_cycles == configuration.term_cycles
      assert revision.trial_days == trial_days

      case configuration.term_end_at do
        nil -> assert revision.term_end_at == nil
        expected -> assert DateTime.compare(revision.term_end_at, expected) == :eq
      end

      assert {:ok, %PlanRevision{id: effective_id, status: :effective}} =
               PlanRevision.get_effective_for_plan(plan.id,
                 authorize?: false,
                 context: %{system?: true}
               )

      assert effective_id == revision.id
    end
  end

  test "term and trial fields do not change pure Scheduler period boundaries" do
    baseline = %{
      interval_unit: :month,
      interval_count: 1,
      anchor_mode: :start_anniversary,
      billing_timezone: "Etc/UTC",
      term_mode: :until_canceled,
      term_cycles: nil,
      term_end_at: nil,
      trial_days: 0
    }

    configurations = [
      %{term_mode: :until_canceled, term_cycles: nil, term_end_at: nil},
      %{term_mode: :fixed_cycles, term_cycles: 1, term_end_at: nil},
      %{term_mode: :fixed_cycles, term_cycles: 3, term_end_at: nil},
      %{
        term_mode: :fixed_end_at,
        term_cycles: nil,
        term_end_at: ~U[2026-05-31 23:59:59Z]
      },
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: @reference_at},
      %{
        term_mode: :fixed_end_at,
        term_cycles: nil,
        term_end_at: ~U[2026-06-01 00:00:01Z]
      }
    ]

    assert {:ok, initial_baseline} = Scheduler.initial_period(@reference_at, baseline)
    assert DateTime.compare(initial_baseline.current_period_start_at, @reference_at) == :eq

    assert DateTime.compare(initial_baseline.current_period_end_at, ~U[2026-07-01 00:00:00Z]) ==
             :eq

    assert DateTime.compare(initial_baseline.next_renewal_at, ~U[2026-07-01 00:00:00Z]) == :eq

    assert {:ok, next_baseline} =
             Scheduler.next_period(initial_baseline.current_period_end_at, baseline)

    assert DateTime.compare(next_baseline.current_period_start_at, ~U[2026-07-01 00:00:00Z]) ==
             :eq

    assert DateTime.compare(next_baseline.current_period_end_at, ~U[2026-08-01 00:00:00Z]) == :eq
    assert DateTime.compare(next_baseline.next_renewal_at, ~U[2026-08-01 00:00:00Z]) == :eq

    for configuration <- configurations, trial_days <- [0, 14] do
      plan = baseline |> Map.merge(configuration) |> Map.put(:trial_days, trial_days)

      assert {:ok, initial_period} = Scheduler.initial_period(@reference_at, plan)
      assert initial_period == initial_baseline

      assert {:ok, next_period} =
               Scheduler.next_period(initial_period.current_period_end_at, plan)

      assert next_period == next_baseline
    end
  end
end
