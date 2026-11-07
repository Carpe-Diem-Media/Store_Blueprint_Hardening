# JC-255 billing timezone implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Reject unsupported billing timezones at contract authoring, publication, and runtime scheduling without changing commercial defaults or bound renewal evidence.

**Architecture:** Configure a compiled IANA database through Elixir's Calendar API. Share one small validator between Ash authoring actions and the scheduler. Return explicit scheduler errors through the existing facade transactions before new renewal binding or provider submission.

**Tech stack:** Elixir 1.19.5, OTP 28.3, Ash 3, PostgreSQL through DevCore, Tz 0.28, ExUnit.

---

## Execution context

Work sequentially in the existing `jc-255-billing-timezone` checkout. The stack parent is `1629b6442b7ed0d00399a60f4ff14ff8e6b76f5c`, PR #214. JC-225 is accepted on canonical main. The current AGENTS workflow supersedes historical admission notes in JC-255. The user authorized the Linear queue and stacked PRs. No new worktrees, merges, schema changes, backfills, or provider changes are part of this ticket.

Read `AGENTS.md`, the design at `docs/superpowers/specs/2026-11-07-jc-255-billing-timezone-design.md`, `.devcore/project.conf`, and `.devcore/render-map.tsv`. Never print credentials. Run database commands sequentially. Prefix test commands with:

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test --
```

Each task requires a fresh implementer, then independent spec review, then independent quality review. Each implementer must observe meaningful failing regression tests before production changes. No global timezone database mutation in async tests. Any temporary database configuration changes in synchronous tests must restore the exact previous value with `try/after` or `on_exit`.

## Task 1: Configured timezone support and contract gates

Files:

- Create `lib/store/subscriptions/billing_timezone.ex` and `test/store/subscriptions/billing_timezone_test.exs`.
- Modify `mix.exs`, `mix.lock`, `config/config.exs`, and `lib/store/support/errors/error_codes.ex`.
- Modify `lib/store/subscriptions/subscription_plan.ex` and `lib/store/subscriptions/plan_revision.ex`.
- Create `test/store/subscriptions/subscription_plan_test.exs`; extend `test/store/subscriptions/plan_revision_test.exs`.

- [ ] Add pure validator regressions before implementation:

```elixir
defmodule Store.Subscriptions.BillingTimezoneTest do
  use ExUnit.Case, async: true
  alias Store.Subscriptions.BillingTimezone

  test "the configured database supports the existing commercial default" do
    assert :ok = BillingTimezone.validate("Africa/Johannesburg")
    assert :ok = BillingTimezone.validate("Etc/UTC")
  end

  test "invalid values and unsupported real zones fail explicitly" do
    for zone <- [nil, "", "Not/A_Real_Zone"] do
      assert {:error, %{code: "INVALID_BILLING_TIMEZONE"}} = BillingTimezone.validate(zone)
    end

    assert {:error, %{code: "INVALID_BILLING_TIMEZONE"}} =
             BillingTimezone.validate("Africa/Johannesburg", Calendar.UTCOnlyTimeZoneDatabase)
  end
end
```

- [ ] Add Ash action regressions using the existing system context pattern. Directly create a SubscriptionPlan with `%{key: unique_key, name: "Timezone test", amount_minor: 100}` and no timezone; assert its default remains `Africa/Johannesburg`. Test create and update with invalid, empty, and nil timezones. Test trimming a supported zone. For PlanRevision, reuse `create_draft/2`, `update_draft!/2`, `publish/1`, and `reload_revision!/1` in its existing test module. Test invalid draft creation and update without weakening immutable effective revisions.

The publication bypass regression must write the invalid historical value directly, reload it, and invoke the real publish action:

```elixir
revision = create_draft!(plan, @commercial_attrs)
Store.Repo.query!(
  "UPDATE plan_revisions SET billing_timezone = $1 WHERE id = $2",
  ["Not/A_Real_Zone", Ecto.UUID.dump!(revision.id)]
)
legacy = reload_revision!(revision.id)
assert {:error, error} = publish(legacy)
assert Exception.message(error) =~ "billing_timezone"
after_revision = reload_revision!(revision.id)
assert after_revision.status == :draft
assert after_revision.version == legacy.version
```

Also create a valid Johannesburg draft while Tz is configured, temporarily configure `Calendar.UTCOnlyTimeZoneDatabase` in a synchronous test, and prove publication rejects it. Restore configuration after the test. Assert durable state remains draft with its original zone and version.

- [ ] Run the three focused test files and retain the failing output. Expected failures include the missing helper and acceptance of invalid commercial timezone values.
- [ ] Add `{:tz, "~> 0.28"}` to dependencies, fetch the dependency through `mise exec -- mix deps.get`, and configure it once:

```elixir
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
```

Use the current official Tz documentation at `https://tz.hexdocs.pm/readme.html`. The reviewed current version is 0.28.4 with compiled IANA data. Do not add an updater, application process, cache, or custom timezone list.

- [ ] Add the `INVALID_BILLING_TIMEZONE` error registry entry and implement the shared helper:

```elixir
defmodule Store.Subscriptions.BillingTimezone do
  @moduledoc "Validates commercial billing zones against the configured timezone database."
  alias Store.Support.Errors.Error
  @probe ~U[2000-01-01 00:00:00Z]

  @doc "Returns an explicit contract error when the database cannot resolve the zone."
  @spec validate(term(), module()) :: :ok | {:error, Error.t()}
  def validate(timezone, database \\ Calendar.get_time_zone_database())

  def validate(timezone, database) when is_binary(timezone) and byte_size(timezone) > 0 do
    case DateTime.shift_zone(@probe, timezone, database) do
      {:ok, _datetime} -> :ok
      {:error, reason} -> invalid(timezone, reason)
    end
  end

  def validate(timezone, _database), do: invalid(timezone, :invalid_timezone)

  defp invalid(timezone, reason) do
    {:error,
     Error.new("INVALID_BILLING_TIMEZONE", "billing timezone is invalid or unsupported", %{
       billing_timezone: timezone,
       reason: reason
     })}
  end
end
```

- [ ] Add the following resource callback to both SubscriptionPlan and PlanRevision, with a module alias. Register `validate(&validate_billing_timezone/2)` after normalization in Plan create/update and revision create_draft/update_draft. Register it independently on revision publish. Do not use a fallback to old data for an explicit invalid update.

```elixir
defp validate_billing_timezone(changeset, _context) do
  case BillingTimezone.validate(Ash.Changeset.get_attribute(changeset, :billing_timezone)) do
    :ok -> :ok
    {:error, error} -> {:error, field: :billing_timezone, message: error.message}
  end
end
```

Document the supported-zone requirement in the affected attribute/action descriptions and public module contract where useful. Preserve defaults, lifecycle transitions, version locks, and all unrelated validations.

- [ ] Format affected files and run the three focused test files. Expected result is all tests passing. Inspect the complete task diff and commit `fix(subscriptions): validate commercial billing timezones`.
- [ ] Complete independent spec and quality reviews before Task 2.

## Task 2: Fail-closed scheduling and immutable renewal proofs

Files:

- Modify `lib/store/subscriptions/scheduler.ex` and the two scheduling call sites in `lib/store/subscriptions/facade.ex`.
- Modify `test/support/subscriptions_fixtures.ex` and every direct Scheduler caller in `test/store/subscriptions/{scheduler_test,scheduler_property_test,sbh_10_02_contract_binding_test,sbh_10_03_renewal_contract_snapshot_test,sbh_20_03_renewal_vs_contract_change_test,renewal_collection_attempt_test,renewal_collection_attempts_test}.exs`.
- Extend the existing paid-order facade tests with initial activation rollback evidence where the fixture can supply an invalid historical revision.

- [ ] Add focused scheduler regressions. Assert the tagged result contract on all three affected public functions. Assert missing, nil, empty, nonexistent, and real-but-unsupported zones return `INVALID_BILLING_TIMEZONE` for day, month, and year plans. Use synchronous tests for restricted global database configuration. Cover these calendar results with `assert {:ok, actual} = Scheduler.advance_period_end(start, plan)` and `assert DateTime.compare(actual, expected) == :eq`:

```elixir
[
  {~U[2026-01-31 10:00:00Z], :month, "Etc/UTC", ~U[2026-02-28 10:00:00Z]},
  {~U[2024-02-29 10:00:00Z], :year, "Etc/UTC", ~U[2025-02-28 10:00:00Z]},
  {~U[2026-01-30 22:30:00Z], :month, "Africa/Johannesburg", ~U[2026-02-27 22:30:00Z]},
  {~U[2024-02-28 22:30:00Z], :year, "Africa/Johannesburg", ~U[2025-02-27 22:30:00Z]},
  {~U[2023-02-26 01:30:00Z], :month, "Europe/Berlin", ~U[2023-03-26 00:59:59.999999Z]},
  {~U[2023-09-29 00:30:00Z], :month, "Europe/Berlin", ~U[2023-10-29 00:30:00Z]},
  {~U[2023-03-25 12:00:00Z], :day, "Europe/Berlin", ~U[2023-03-26 12:00:00Z]}
]
```

Confirm the DST gap and ambiguity expectations through DateTime.new/4 using the installed Tz database. Preserve the existing first ambiguous result and first gap boundary; do not choose a new policy. Preserve fixed-day clamping and all existing property coverage.

- [ ] Add a runtime legacy-row regression to `sbh_10_03_renewal_contract_snapshot_test.exs` with its real public facade and existing fixture helpers:

```elixir
%{subscription: subscription, revision: revision, now: now} =
  create_due_live_fixture!("jc255_invalid_revision")
before_subscription = fetch_subscription!(subscription.id)
orders_before = Store.Repo.aggregate(Order, :count, :id)
intents_before = Store.Repo.aggregate(PaymentIntent, :count, :id)
attempts_before = Store.Repo.aggregate(RenewalAttempt, :count, :id)
Store.Repo.query!(
  "UPDATE plan_revisions SET billing_timezone = $1 WHERE id = $2",
  ["Not/A_Real_Zone", Ecto.UUID.dump!(revision.id)]
)
StripeAPIStub.stub_unexpected!("invalid timezone must fail before provider submission")
assert {:error, %{code: "INVALID_BILLING_TIMEZONE"}} =
         Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)
assert Store.Repo.aggregate(Order, :count, :id) == orders_before
assert Store.Repo.aggregate(PaymentIntent, :count, :id) == intents_before
assert Store.Repo.aggregate(RenewalAttempt, :count, :id) == attempts_before
assert fetch_subscription!(subscription.id) == before_subscription
```

Repeat the failure boundary with a real Johannesburg contract and a temporarily UTC-only configured database. For initial paid activation, use a valid purchased revision, corrupt its timezone before the facade runs, then assert the explicit error and no new subscription, item, or access-effect rows. Keep the parent JC-360 atomicity proofs intact.

- [ ] Extend the existing bound retry test, `a bound retry uses the occurrence's captured grace policy`, to capture the first attempt's `charged_contract_snapshot["billing_timezone"]`, period boundaries, plan_revision_id, and attempt id. After binding, change the mutable plan's timezone through its public action and publish a later revision with a different supported zone. Retry the same occurrence with the configured database temporarily restricted to UTC-only. Assert the same attempt, stored period, revision, and snapshot timezone remain unchanged and that the provider retry still follows the existing captured contract. Do not re-resolve a bound occurrence from mutable plans or current configuration.

- [ ] Run the scheduler and facade regression files before production edits and retain the meaningful failing output.
- [ ] Introduce Scheduler aliases for BillingTimezone and Error. Define its period type as a map of the three existing DateTime fields and its public return types as `{:ok, period()} | {:error, Error.t()}`. Implement initial and next periods using an explicit successful advance:

```elixir
def initial_period(%DateTime{} = started_at, plan) when is_map(plan) do
  with {:ok, period_end_at} <- advance_period_end(started_at, plan) do
    {:ok, %{current_period_start_at: started_at, current_period_end_at: period_end_at,
            next_renewal_at: period_end_at}}
  end
end

def next_period(%DateTime{} = current_period_end_at, plan) when is_map(plan) do
  initial_period(current_period_end_at, plan)
end
```

- [ ] Resolve the effective timezone without silently replacing nil or missing values. Preserve atom/string map support and fetch the configured database once per advance:

```elixir
billing_timezone =
  case Map.fetch(plan, :billing_timezone) do
    {:ok, timezone} -> timezone
    :error -> Map.get(plan, "billing_timezone")
  end
database = Calendar.get_time_zone_database()

with :ok <- BillingTimezone.validate(billing_timezone, database) do
  case interval_unit do
    :day -> {:ok, DateTime.add(period_start_at, day_seconds, :second)}
    :month -> shift_calendar_months(period_start_at, interval_count, anchor_mode,
                  anchor_day_of_month, billing_timezone, database)
    :year -> shift_calendar_months(period_start_at, interval_count * 12, anchor_mode,
                  anchor_day_of_month, billing_timezone, database)
    _ -> {:ok, DateTime.add(period_start_at, day_seconds, :second)}
  end
end
```

Keep existing interval defaults and unrelated scheduler functions. Replace the suppressing shift helper with the explicit conversion below and pass the same database to every operation:

```elixir
defp shift_zone(datetime, timezone, database) do
  case DateTime.shift_zone(datetime, timezone, database) do
    {:ok, shifted} -> {:ok, shifted}
    {:error, reason} -> timezone_error(timezone, reason)
  end
end

defp local_datetime(date, time, timezone, database) do
  case DateTime.new(date, time, timezone, database) do
    {:ok, datetime} -> {:ok, datetime}
    {:ambiguous, first, _second} -> {:ok, first}
    {:gap, before_gap, _after_gap} -> {:ok, before_gap}
    {:error, reason} -> timezone_error(timezone, reason)
  end
end

defp timezone_error(timezone, reason) do
  {:error, Error.new("INVALID_BILLING_TIMEZONE", "billing timezone is invalid or unsupported",
                    %{billing_timezone: timezone, reason: reason})}
end
```

In `shift_calendar_months/6`, first match `{:ok, local} <- shift_zone(...)`; preserve local date/time, anchor selection, and `shift_date_months/3`. Then match `{:ok, shifted_local} <- local_datetime(...)` and return `shift_zone(shifted_local, "Etc/UTC", database)`. Document errors, gap/ambiguity choices, and the fixed-second day contract.

- [ ] Change the paid-order facade's `period <- Scheduler.initial_period(...)` clause to `{:ok, period} <- Scheduler.initial_period(...)`. Change `renewal_period/3` to return `Scheduler.next_period(...)` directly rather than nesting it inside another ok tuple. Preserve the branch that reads existing bound period evidence.
- [ ] Change each direct fixture/test call from `period = Scheduler.next_period(...)` or `Scheduler.initial_period(...)` to `{:ok, period} = ...`, using `assert` in tests. Unwrap chained field accesses into a named period first. Change direct advance assertions to match `{:ok, expected}`. Use `rg -n 'Scheduler\.(initial_period|next_period|advance_period_end)' lib test` to verify every caller, including all seven listed test modules. Do not weaken the existing calendar properties or lifecycle assertions.
- [ ] Format, run focused tests, self-review the complete diff, and commit `fix(subscriptions): fail closed on billing timezone errors`.
- [ ] Complete independent spec review, then quality review of the whole ticket.

## Final verification and publication

- [ ] Run `mix check`, `mix test --max-failures 1`, the real-connection gate, and `mix ash_postgres.generate_migrations --check` with the DevCore prefix above. Real-connection gate command is `mix test --include real_connections test/store/subscriptions/access_effect_source_fence_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs`; confirm exact filenames against the current CI workflow before running. Do not run database commands concurrently.
- [ ] Inspect `git diff 1629b6442b7ed0d00399a60f4ff14ff8e6b76f5c...HEAD`, `git diff --check`, and exact head. Confirm no secrets, defaults changes, migrations, extra dependencies, or unrelated production files.
- [ ] Record two equivalent bounded scheduling measurements, including query count, process memory/mailbox, and limits. Do not claim convergence or capacity from functional tests. Add Performance & Scaling Review and Runtime Resource Safety Review to the PR. Database indexes, Oban uniqueness, caching, and logging retain their existing ownership; scheduling adds local timezone lookups only.
- [ ] Push the issue branch and create a draft PR targeting `jc360-initial-paid-activation`, with JC-255 acceptance evidence and explicit stack order. Link the PR to this thread as the next tool call. Move JC-255 to In Review when ready for human review. Never mark it Done or merge it.
- [ ] Read exact-head GitHub CI and distinguish observed passes from pending checks. Keep the one-ticket PR diff separate from its parent.
