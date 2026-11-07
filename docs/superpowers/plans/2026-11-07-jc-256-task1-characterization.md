# JC-256 Task 1 characterization tests implementation plan

> **For agentic workers:** Execute this plan in the current authorized JC-256 implementation branch. Keep this task to the audit tests below. Do not change production code or infer term, trial, or provider-managed contract semantics.

**Goal:** Record whether currently modeled commercial plan configurations can become effective and whether the pure Scheduler calculation changes when only term and trial fields change.

**Architecture:** Add one focused `Store.DataCase` test file. Use the existing plan and revision fixtures to characterize publication. Use the pure `Store.Subscriptions.Scheduler` functions to characterize period calculations against a fixed UTC reference. The outcomes describe current behavior; they do not define desired commercial behavior.

**Tech Stack:** Elixir, ExUnit, Phoenix app, Ash 3, Ecto SQL sandbox, DevCore test runtime.

---

## Scope and evidence

The live Linear issue JC-256 is a structured audit and is now In Progress. It says the audit outcome must be `PROVEN_GOOD` or a new `CANDIDATE`, and explicitly says findings do not authorize implementation. JC-219 and JC-220 are marked Done in the issue. The authorized stack base is `e1f23d179560cffb073b750b08d1a684a2bb87c5`, JC-248 draft PR #217. Canonical main remains `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`, where the concrete JC-219 and JC-220 prerequisites are accepted. JC-256 is now In Progress for this structured audit. Historical readiness labels are not execution gates under AGENTS.md.

This Task 1 tests only two observable facts:

1. Which configurations the current PlanRevision create-and-publish path accepts, and whether the published revision retains the configured immutable commercial fields.
2. Whether `Scheduler.initial_period/2` and `Scheduler.next_period/2` produce the same boundaries when term and trial fields vary and cadence, timezone, and reference instants stay fixed.

These tests do not prove payment collection, trial access, term completion, provider-start eligibility, subscription activation, or provider-managed behavior. Do not add those claims to test names or assertions. Do not add an inline production fix. Existing `plan_revision_test.exs` already covers immutable commercial fields and publish guards; the new test should focus on the configuration matrix rather than duplicate those broad tests.

## File map

- Create `test/store/subscriptions/jc256_contract_configuration_audit_test.exs`. It owns the bounded publication matrix and pure Scheduler characterization.
- Do not modify production code, existing tests, project documentation, or tracker state.

## Task 1: Add the characterization test file

**Files:**
- Create: `test/store/subscriptions/jc256_contract_configuration_audit_test.exs`

- [ ] **Step 1: Create the complete test module**

Add this exact module:

```elixir
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
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: ~U[2026-05-31 23:59:59Z]},
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: @reference_at},
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: ~U[2026-06-01 00:00:01Z]}
    ]

    for configuration <- configurations, trial_days <- [0, 14] do
      plan =
        SubscriptionsFixtures.create_subscription_plan!(
          Map.merge(configuration, %{trial_days: trial_days})
        )

      revision =
        SubscriptionsFixtures.create_plan_revision!(plan, %{trial_days: trial_days})

      assert revision.status == :effective
      assert revision.subscription_plan_id == plan.id
      assert revision.term_mode == configuration.term_mode
      assert revision.term_cycles == configuration.term_cycles
      case configuration.term_end_at do
        nil -> assert revision.term_end_at == nil
        expected -> assert DateTime.compare(revision.term_end_at, expected) == :eq
      end
      assert revision.trial_days == trial_days

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
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: ~U[2026-05-31 23:59:59Z]},
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: @reference_at},
      %{term_mode: :fixed_end_at, term_cycles: nil, term_end_at: ~U[2026-06-01 00:00:01Z]}
    ]

    assert {:ok, initial_baseline} = Scheduler.initial_period(@reference_at, baseline)
    assert DateTime.compare(initial_baseline.current_period_start_at, @reference_at) == :eq
    assert DateTime.compare(initial_baseline.current_period_end_at, ~U[2026-07-01 00:00:00Z]) == :eq
    assert DateTime.compare(initial_baseline.next_renewal_at, ~U[2026-07-01 00:00:00Z]) == :eq

    assert {:ok, next_baseline} =
             Scheduler.next_period(initial_baseline.current_period_end_at, baseline)

    assert DateTime.compare(next_baseline.current_period_start_at, ~U[2026-07-01 00:00:00Z]) == :eq
    assert DateTime.compare(next_baseline.current_period_end_at, ~U[2026-08-01 00:00:00Z]) == :eq
    assert DateTime.compare(next_baseline.next_renewal_at, ~U[2026-08-01 00:00:00Z]) == :eq

    for configuration <- configurations, trial_days <- [0, 14] do
      plan =
        baseline
        |> Map.merge(configuration)
        |> Map.put(:trial_days, trial_days)

      assert {:ok, initial_period} = Scheduler.initial_period(@reference_at, plan)
      assert initial_period == initial_baseline

      assert {:ok, next_period} =
               Scheduler.next_period(initial_period.current_period_end_at, plan)

      assert next_period == next_baseline
    end
  end
end
```

- [ ] **Step 3: Run the new test through DevCore**

Run this exact command from the repository root after the implementation branch is ready:

```bash
set -o pipefail
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/jc256_contract_configuration_audit_test.exs 2>&1 | tee tmp/jc256/task1-test.log
```

Expected: exit status `0`, both test cases pass, and `tmp/jc256/task1-test.log` records the observed run. If a test fails because a checked API differs from this draft, inspect the local API and revise the plan's exact test code before dispatching implementation. Do not repair production code as part of this audit Task 1.

- [ ] **Step 4: Review the test diff**

Run:

```bash
git diff --check
git diff -- test/store/subscriptions/jc256_contract_configuration_audit_test.exs
```

Expected: the diff contains only the new characterization test file and has no whitespace errors. Confirm the tests make no assertion about charges, trial access, expiration, renewal eligibility, or provider orchestration.

## Explicit stop conditions

- A candidate finding remains a candidate. Stop before production changes.
- A passing publication assertion means only that the current action accepts and stores those attributes.
- A passing Scheduler assertion means only that these pure calculations ignore those fields for these inputs.
- Do not add a sale/checkout proof in this Task. If a later audit task requires it, use the existing cart facade and Checkout start/finalize pattern in `checkout_subscription_only_test.exs`. Restore feature flags to their exact previous application environment state, deleting a previously missing key. Verify the immutable `OrderLineItem.subscription_plan_revision_id_snapshot` and current totals. Do not invent a `trial_days_snapshot` column.
- Do not activate subscriptions, run renewal collection, use committed fixtures, or expand this plan into Task 2.

## Additional required task checks

Run each command sequentially after adding the new file. All use the same DevCore prefix as the test command above:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format test/store/subscriptions/jc256_contract_configuration_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo test/store/subscriptions/jc256_contract_configuration_audit_test.exs --strict
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
```

Self-review, commit only the new test file, and report its head for fresh specification and quality review. These characterization tests may pass immediately. Do not manufacture a RED result or change production behavior to satisfy an observation.

## Plan self-review

- The 12 publication cases cover `until_canceled`, fixed cycle counts 1 and 3, fixed-end instants before, equal to, and after the fixed reference, each with `trial_days` 0 and 14.
- The same 12 field combinations are passed to the pure Scheduler comparison. Cadence, timezone, and reference timestamps are held constant.
- The assertions describe present behavior and do not imply that any accepted configuration has correct commercial semantics.
- The only code file in scope is the new focused test file. No source changes or Tracker updates belong in this task.

Root corrected datetime assertions to compare instants, because persisted utc_datetime_usec values can carry a different precision tuple from a literal. Root also added scoped formatting, strict Credo and warnings-as-errors compilation.
