# JC-255 billing timezone safety design

## Goal and baseline

Prevent a commercial billing timezone from silently becoming UTC when the runtime cannot resolve it. Preserve the existing `Africa/Johannesburg` default and the immutable PlanRevision and RenewalAttempt contracts.

The user directed implementation through the existing Store Blueprint Linear queue with one stacked PR per ticket. This ticket follows JC-360. The stack base is `1629b6442b7ed0d00399a60f4ff14ff8e6b76f5c`; canonical `origin/main` is `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. JC-225, the PlanRevision prerequisite, is Done and its implementation exists on `main`. Historical serial-admission notes in JC-255 predate the current repository workflow.

At this base, Scheduler returns its input DateTime when `DateTime.shift_zone/2` fails. Plan and revision actions trim the timezone string but do not validate runtime support. PlanRevision publication has no timezone gate. The application has no configured IANA timezone database.

## Timezone database

Use `tz ~> 0.28` and configure `Tz.TimeZoneDatabase` through Elixir's standard `:time_zone_database` setting. Its current official documentation describes version 0.28.4 with IANA data 2026d and timezone periods prepared during compilation. The lockfile will record the resolved release. Do not start an automatic updater or watcher. Timezone data changes follow reviewed dependency updates.

This supplies the named timezone behavior already expressed by the existing commercial default. An intentional UTC-only product would require a different commercial decision and changed defaults. A custom timezone table would duplicate IANA rules.

Reference: [Tz installation and update documentation](https://tz.hexdocs.pm/readme.html).

## Validation and scheduling contracts

Add a small shared `Store.Subscriptions.BillingTimezone` helper. Validate a timezone using public DateTime APIs against `Calendar.get_time_zone_database/0`. Use the configured database rather than a regex, host timezone files, a second zone registry, or a cache. Missing, empty, invalid, and unsupported values fail with the registry-backed `INVALID_BILLING_TIMEZONE` code.

SubscriptionPlan create/update and PlanRevision draft create/update validate the effective changeset value after normalization. PlanRevision publish independently validates the effective value. A draft created before validation or corrupted through another path therefore cannot bypass the effectiveness gate. Read the value through `Ash.Changeset.get_attribute/2`; an explicit invalid update must not fall back to the previous valid value.

Scheduler `advance_period_end/2`, `initial_period/2`, and `next_period/2` return `{:ok, value}` or `{:error, Store.Support.Errors.Error.t()}`. They validate the requested timezone and propagate failures from both UTC conversion and local calendar construction. Update both production callers and every test/fixture caller to the explicit result contract. A separate validated timezone object or an exception-based compatibility API would add another contract without improving the failure boundary.

Valid day intervals remain a fixed multiple of 86,400 seconds. Month and year intervals calculate in the contract's local calendar and return UTC instants. Preserve the existing first result for an ambiguous local time and the first returned boundary for a gap. This task documents and tests those choices; it does not change them.

## Commercial and historical boundaries

The initial paid-order path propagates scheduling failure before creating a source, item, or AccessEffect. Renewal binding propagates it before creating a new RenewalAttempt or reaching a provider submission checkpoint. Verify rollback and the absence of payment mutation through the public facades.

An existing bound RenewalAttempt keeps its stored timezone, period, and charged-contract snapshot. Later plan, default, or runtime configuration changes do not recalculate that occurrence. Invalid legacy contract values fail closed for diagnosis and explicit repair. Do not rewrite them to UTC or the current default, infer historical meaning, or add a backfill.

The current due-renewal path calculates a live revision period twice before reusing an existing attempt. Replace that discovery step with the existing bounded current-attempt lookup. Validate complete bound evidence and use its stored renewal key. Only an unbound occurrence calculates a new period. Pass the resolved key into the execution helper so it cannot calculate another identity from current timezone configuration. Preserve locked binding and stale-version checks. Timezone contract errors must bypass payment-failure lifecycle mutation, including when a queued target revision fails inside binding.

No schema, index, lifecycle, provider contract, payment-method authority, entitlement executor, or worker architecture changes are needed. This ticket does not select a NewYou billing timezone from geography, participant preferences, or provider behavior.

## Evidence

Focused regressions cover the supported Johannesburg default; authoring and publish gates; an invalid zone; a real zone unsupported by a deliberately restricted test database; invalid historical revisions; and failure before a new renewal attempt or provider call. Calendar cases cover unchanged UTC behavior, a Johannesburg UTC/local date crossover, local leap-day yearly billing, a DST gap, a DST ambiguity, and fixed-second day billing across an offset transition. Existing-bound snapshot replay remains immutable.

Run the affected tests through DevCore, then the repository's required checks and exact-head CI. The parent stack base already passed the full suite twice, the focused JC-360 suite, both real-connection repetitions, and migration alignment. Keep local database-dependent commands sequential in the supported workspace test partition.

Contract authoring is cold work; period scheduling is a hot renewal operation. Timezone resolution remains local to the configured database. Add no database query, network operation, background updater, or cache to period calculation. Record focused runtime and resource observations with their limits in the PR. Production capacity and convergence require separate measured evidence.
