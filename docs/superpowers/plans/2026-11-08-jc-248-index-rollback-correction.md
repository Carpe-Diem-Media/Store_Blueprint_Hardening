# JC-248 index rollback correction

Use `subagent-driven-development`. Root owns Mix, DevCore, formatting, Git and external writes. Implement R4 from the independent #217 review. Preserve the existing index definitions and disabled DDL transaction.

## Files

- `priv/repo/migrations/20261107072703_jc248_access_verification_indexes.exs`
- New `test/store/migrations/jc248_access_verification_indexes_test.exs`
- `test/support/isolated_migration_database.ex`, only if an optional test pool-size argument is needed. Preserve the default of two connections.
- Existing JC-248 operations documentation for interrupted concurrent index recovery.

## Test first

1. Use the existing isolated migration database helper with a separate repo and at least four connections. It must inherit DevCore's connection configuration and own only its generated database.
2. Run the actual migration's `down/0` through Ecto.Migrator, rather than copying its DDL. For each affected table, hold a reader transaction until the drop waits on that reader. Identify the migration backend and its waiting index drop through database activity and lock state.
3. While the drop waits, issue a new table read and a zero-row update with a scoped statement deadline. Both must finish before the held reader releases. The unchanged ordinary drop must fail this assertion because its queued AccessExclusiveLock blocks new access. Use task barriers, bounded polling and cleanup in `after` blocks.
4. Release the held reader, await migration completion and assert both indexes are absent. Reapply the same migration and check both indexes are present, valid and ready. Repeat independently for the other table, since rollback drops one index before the other.
5. Root observes the expected red result before production edits.

## Correction and review

Add `concurrently: true` to both rollback index declarations. Root formats and runs both tests, then migration alignment. Obtain a fresh specification review followed by a fresh quality review. Inspect the complete diff and commit append-only.

Document interruption recovery through catalog inspection and an explicit concurrent drop/rebuild of an invalid or partial feature index. Rerunning a migration alone is not a repair of an invalid index. These are operator instructions, not authorization to run production DDL.

## Evidence limits

The tests establish reader and writer availability for these exact index drops on the local DevCore PostgreSQL version. They do not certify production latency, arbitrary load or all migration rollback paths.
