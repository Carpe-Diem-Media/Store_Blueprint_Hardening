# Allocation foundation runtime ACL contract

This is a supported new-install contract, tested on disposable PostgreSQL 18.
It does not assert that an existing deployment has these roles. JC-382 authorizes
DEV/TEST proof only. An active deployment needs an authorized inventory of actual
principals, ownership, memberships and default ACLs before any role change. Stop
if that inventory is unknown. Do not infer authority from a role's name.

## Supported topology

- One NOSUPERUSER, NOCREATEROLE, NOCREATEDB, NOREPLICATION, NOBYPASSRLS, NOLOGIN
  object owner owns the existing baseline tables and all new allocation objects.
- A distinct, similarly restricted LOGIN migration operator has NOINHERIT and an
  explicit owner membership. Only that operator assumes the owner role. It is not
  a running application principal.
- `Store.Repo` uses `DATABASE_URL`. `Store.DirectRepo` uses
  `STORE_DIRECT_DATABASE_URL`, falling back to `DATABASE_URL`. The two runtime
  logins may differ. Each must authenticate as its session principal, be distinct
  from the owner, have no memberships and no privileged role attributes.
- Both configurations must reach the same database and backend address/port.
  Replica routing and forced-role switching are outside this supported contract.
- Runtime has schema USAGE without CREATE, dependency SELECT on Orders, lines,
  adjustments, offer revisions/components and existing Pricing source tables.
  The exact baseline column INSERT/UPDATE lists are in
  `priv/repo/contracts/allocation_legacy_columns.json`. No table-level DML,
  DELETE/TRUNCATE/TRIGGER/REFERENCES or Membership-marker INSERT is added.
- Runtime has SELECT on both allocation tables and no column/table DML, trigger
  control, REFERENCES or grant options.
- Runtime has EXECUTE only on the two nested invoker functions:
  `membership_allocation_lock_orders(uuid[],uuid)` and
  `membership_allocation_validate_order(uuid)`. It cannot execute either private
  SECURITY DEFINER source/manifest helper or the other trigger-entry functions.
- No PUBLIC allocation-table privileges, PUBLIC function EXECUTE, or owner default
  ACL grants to other principals are permitted. No owner/writer SET ROLE access is
  permitted from runtime. The preflight never grants or repairs privileges.

## Staging and fail-closed preflight

The ordinary `Store.Release.migrate`, `migrate_direct_repo` and `migrate_all`
entrypoints reject a pending allocation trigger migration. Use the dedicated
entrypoint with operator-only environment injection:

```sh
bin/store eval 'Store.Release.migrate_allocation_foundation()'
```

In addition to the ordinary configured runtime environment, the operator process
needs `STORE_MIGRATION_DATABASE_URL` and `STORE_MIGRATION_OWNER`. The first is a
secret direct-PostgreSQL URL for the migration LOGIN, the second is the actual NOLOGIN owner name.
Do not put the migration URL in the long-running application environment, shell
history, logs or source. Use the platform's existing approved secret injection.
No production credentials are needed for the disposable proof.

The entrypoint authenticates both configured runtime connections independently,
then starts a short-lived migration repo with the separate operator connection
and explicit owner assumption. It verifies database identity, stages through
`20261116195330`, and checks effective catalog privileges before running
`20261116195400` or any later migration. The validator is created at the staging
boundary, allowing its exact EXECUTE ACL to be inspected before trigger creation.
All nine migration identities remain. Every rollback refusal guard remains.

On the first attempt the staged tables and helpers can exist without their new
runtime grants. The preflight must fail in that state, leaving the trigger
migration unapplied. It does not modify existing baseline grants or automatically
create roles. The already-approved baseline schema and role permissions must be
established through the site's own authorized provisioning process.

For a new installation with a verified supported topology, an explicitly approved
owner operation can apply the precise new delta from
`scripts/deployment/allocation_runtime_grants.sql`. Supply `repo_role` and
`direct_repo_role` as nonsecret psql variables containing the authenticated
principal names. Use the approved owner connection with `psql -X`; do not pass
passwords or secret URLs as command arguments. This file grants SELECT on the two
new tables and EXECUTE on the two invoker helpers, nothing else. Schema USAGE and
baseline permissions are prerequisites, not silently repaired by this file.

Rerun the dedicated entrypoint after approval and provisioning. Any inadequate,
unknown or excessive effective ACL fails closed before the trigger migrations.
The preflight checks again after migration. Success returns only role names,
status and migration versions. All temporary connections close on success or
failure. An already accepted foundation can be checked again through the same
entrypoint without replaying migrations.

Keep runtime traffic and privileged DDL/ACL changes quiescent throughout this
operator procedure. The catalog check is not a lock against an independent
administrator changing grants immediately afterwards. The first failed staging
attempt can leave schema and helper definitions, but no new allocation triggers.
Do not admit application traffic until the whole procedure succeeds.

## Disposable verification

The existing database-security job uses its owned PostgreSQL 18 service and
separate `model_b_runtime` / `model_b_direct_runtime` logins. These names are CI
fixtures, never production defaults. The job uses the deployment SQL grant file
and the same Elixir preflight/migration function. It does not supplement runtime
with wildcard function grants.

It tests missing SELECT/EXECUTE grants, pre-trigger refusal, 42501 failures during
legacy writes and at deferred COMMIT, complete rollback, narrow restoration,
allocation reads, denied allocation DML/private helpers/SET ROLE/trigger control,
SnapshotWriter create/replay, the existing shipping insert/conflict pattern,
tax/finalization and lifecycle/replay through both runtime pools. The ordinary
shipping private function and full Cart/Inventory/Checkout flow remain outside
this proof. Original writer COMMIT/locks/timeouts, 74 role assertions and all 34
foundation regressions remain required.

## Performance and resource limits

The harness records two equivalent rollback-only transactions with one Order and
20 unmarked lines before allocation migrations and after trigger installation.
It forces deferred checks before rollback. This measures a bounded diagnostic
under the same owner and disposable database, not runtime-role capacity or p99.
Each line gains indexed conflict/allocation probes, an Order lock, a nested
invoker router call and deferred Order validation. New SELECT/EXECUTE grants do
not add a financial write path.

The operator uses two short runtime identity connections and one temporary repo
of two connections, then closes them. The compatibility harness records two
repetitions per runtime pool and verifies no tagged sessions remain. Production
DDL lock duration, large-Order scaling, memory/GC/mailbox behavior, post-load
convergence, capacity and p99 remain UNMEASURED. No JC-381 or OS isolation claim.
