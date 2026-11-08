# JC-248 verification query corrections

> **For agentic workers:** Use `subagent-driven-development` for implementation, then separate specification and quality reviews. Root owns all Mix, DevCore, formatter, Git and external writes.

**Goal:** Correct R1 and R2 from the independent #217 review without changing access authority.

**Architecture:** Keep the raw APPLIED insertion window bounded before joins. Seek its composite cursor through the existing partial index. Resolve each candidate's latest source target through a descending indexed lookup with LIMIT 1. Preserve the fixed insertion high-water, stable UUID ordering and private system-authorized read action.

**Tech stack:** Elixir, Ecto SQL 3.14.0, Ash 3.37.2, AshPostgres 2.15.2 and PostgreSQL through DevCore.

## Files and implementation

- Modify `lib/store/subscriptions/queries/applied_access_verification_query.ex`.
- Add focused query-plan tests to `test/store/subscriptions/access_effect_effective_execution_test.exs`, reusing its committed source fixtures and exact cleanup.

- [ ] Add deep-history regressions before production edits. Generate query-only APPLIED rows for one real fixture source using SQL and UUIDv7-shaped IDs. Label their copied fingerprints as unsuitable for lifecycle or financial execution. Refresh statistics explicitly and inspect the actual `to_ecto/1` query through `Ecto.Adapters.SQL.to_sql/3` and `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.
- [ ] Cover a continuation near the end of 200,000 rows and timestamp ties. Assert the correct first UUID successor and page contents. Require the raw window's index condition to contain both cursor columns and reject scan work proportional to the visited prefix.
- [ ] Cover a highly skewed source and a page of historical targets. Require a descending source-version index lookup below LIMIT 1 with work bounded by candidate or distinct-source count. Assert historical rows are noncurrent and the newest row is current.
- [ ] Root runs the new tests on the unchanged query and records the expected R1/R2 failures. No planner hints, `enable_seqscan` changes or timing thresholds are allowed.
- [ ] Replace the cursor predicate with `fragment("(?, ?) > (?, ?)", effect.inserted_at, effect.id, type(^inserted_at, :utc_datetime_usec), type(^id, Ecto.UUID))` inside the raw window.
- [ ] Replace the correlated newer-row EXISTS with a lateral subquery ordered by `source_version DESC`, limited to one row for the candidate subscription. Compare the selected latest ID with the candidate ID. Keep the raw window limit before this lookup and joins.
- [ ] Root formats and runs the focused tests again, then the existing query/currentness/authorization tests. Preserve all existing cases and query-count protections.
- [ ] Obtain a fresh specification review followed by a fresh quality review. Inspect the complete diff and commit append-only after observed validation.

## Validation commands

Run the selected tests through `MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_jc248_query STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/access_effect_effective_execution_test.exs` with line selectors for the red/green cycle. Root chooses fresh private suffixes where committed fixtures require isolation. Full issue validation follows after all five review corrections.

## Limits

Natural query plans establish the tested local schema and distributions. They do not certify production capacity, arbitrary grant-history fanout, allocator convergence or multi-node behavior. R3 durable delivery, R4 rollback availability and R5 diagnostics are separate sequential correction tasks. The independent review artifact remains unchanged.
