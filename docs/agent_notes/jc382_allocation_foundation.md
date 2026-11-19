# JC-382 allocation database foundation

Base is accepted main db291befdd22fdc2591bfd33cf4273e6a0510762. The 25 source paths
come from experimental 59bea4635d625f3675065c8e47f5db37e06e1a04. The experimental
branch is source evidence and was not the development base.

This is dormant allocation schema and read models. There is no acceptance facade,
financial create action, provider call, Subscription transition or entitlement
change. JC-274's parent criteria remain open. OS/operator/credential isolation
remains unverified under JC-381. No OS launcher or toolchain code is included.

## Implementation and verification plan

1. Extract the exact authorized manifest on a branch from current main.
2. Reproduce explicit non-v7 identity acceptance and rollback protection loss.
3. Add SQL UUIDv7 checks aligned with Ash snapshots and rollback refusal before
   any protection is removed. Retain all nine migration identities.
4. Preserve the create-only conflict replay path and test genuine late appends
   and conflict updates remain denied.
5. Exercise both configured Repo pools as the actual restricted runtime in the
   disposable PostgreSQL job. Use the exact frozen v1.1 column ACLs only.
6. Cover Ash reads, all retained SQL tests, upgrade/rollback and normal CI jobs.
7. Inspect the complete final diff and publish at most two exact-head CI attempts.
   Stop for independent Master Gate before any merge decision.

## Lifecycle and permissions

CONSTRUCTING has accepted_at NULL only within a transaction. It must become
ACCEPTED with complete 1–16 component evidence before COMMIT. Invalid or partial
construction rolls back. ACCEPTED is terminal. Legacy inputs with both Membership markers NULL and existing conflict keys permit
ON CONFLICT DO NOTHING to reach PostgreSQL's unique-key decision; they do not
permit appending a new row. ON CONFLICT UPDATE still faces immutable UPDATE
triggers. Source and monetary validation, per-occurrence identity and lock order
remain mandatory.

Every down boundary locks the allocation header table before checking accepted
evidence and refuses before removing any protection. The lock prevents a new
acceptance from racing the check. Empty disposable targets can roll back to main
and upgrade again. New header ID/occurrence and child ID/component-instance/
evaluation identities have SQL v7 version and RFC variant checks, including
caller-supplied values. The existing line occurrence check remains.

Only the fixed lock helpers are SECURITY DEFINER. All integrity functions remain
INVOKER, pin search_path, qualify trusted relations and revoke PUBLIC execution.
Narrow test grants live only in the disposable harness. This PR does not provision
or change production or shared DevCore identities.

The runtime compatibility process starts the existing Repo and DirectRepo with
runtime credentials and routes existing snapshot/tax/lifecycle code through each
pool. The shipping test uses Checkout's exact Ecto schema/column/conflict pattern;
it does not invoke the private Checkout function or the full Checkout flow.
Cart/Inventory/Checkout writes are outside this proof and receive no new grants.
Fixture-owner SQL tests and actual runtime login checks are reported separately.

## Performance & Scaling Review

Cold operator allocation proof; legacy line/adjustment inserts are affected hot
paths. They acquire the existing Order lock. Conflict detection adds one indexed
probe on the existing Order/line-number or Order/adjustment-sequence keys, plus the
existing partial shipping uniqueness key. New allocation and occurrence indexes
bound lookup by Order/occurrence and allocation set. No new history cache, Redis
coordination, queue, invalidation or Oban job is introduced.

Source SHARE locks, binary UUID offer/line ordering, 17-revision capability and
1s lock / 5s statement / 5s idle-transaction / 10s transaction bounds remain.
Whole-Order validation can scan multiple occurrences and repeats per affected row.
Production DDL lock duration, large-Order scaling and p99 latency are UNMEASURED.
Normal performance-smoke CI remains required without threshold changes.

## Runtime Resource Safety Review

The database proof starts bounded subprocesses and two runtime Repo pools of two
connections, records elapsed time, BEAM memory and process counts over two bounded
repetitions per pool, closes both pools in finally cleanup and checks no tagged
runtime sessions remain. No production background process, mailbox, cache or new
service is added. Disposable databases and identities belong to the existing CI
service. Local SQL tests use the repository's isolated migration database helper.

The measurements are diagnostic. Production memory/GC behavior, post-load
convergence and capacity are UNMEASURED. A passing database proof is not OS
credential isolation or production readiness.

## Additional paths beyond the 25 source paths

- .github/workflows/ci.yml explicitly includes allocation COMMIT and migration
  lifecycle tests in both real-connection repetitions.
- scripts/ci/model_b_runtime_compatibility.exs executes the actual runtime login
  checks through existing application code and both configured Repo pools.
- test/store/orders/membership_foundation_migration_test.exs tests empty rollback
  to main and subsequent upgrade in its own disposable database.
- Two generated latest Ash snapshots record the new UUIDv7 checks; the five
  original snapshots are retained.
- This note records scope, execution plan, limitations and resource reviews.

## Authorized ACL correction plan

Master Gate comment 874b4758-8ddf-400b-9f51-3e66b1d7fe18 authorizes this correction.
The supported topology uses a separate NOLOGIN object owner and two authenticated
runtime configurations with the exact frozen column ACLs. No deployment role names
are assumed. Ordinary runtime gets only SELECT on the new tables and EXECUTE on
the invoker router/validator. The supported release path stages schema and helpers,
then checks the actual roles before installing triggers. Standard release migration
entrypoints reject pending allocation triggers. The validator moves to the existing
pre-trigger helper migration, preserving all nine identities and rollback guards.

Execution plan:

1. Reproduce missing preflight, owner-role rejection and unknown-role failures.
2. Add a read-only catalog preflight, staged owner-only migration interface and
   the operator-reviewed four-grant SQL file. Keep baseline Orders ACLs unchanged.
3. Replace runtime-wide CI function grants with the same documented SQL file.
4. Test missing grants with 42501, deferred COMMIT rollback, narrow restoration,
   independent Repo/DirectRepo logins and all existing writer/lock regressions.
5. Run focused checks locally against disposable PG18 before at most two CI heads.
6. Record exact evidence and STOP for independent Master Gate. No production roles
   or shared ownership change as part of this work.
