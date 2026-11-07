# JC-248 entitlement reconciliation design

## Authority and scope

The existing Store Blueprint Linear queue guides this work. JC-245, JC-246 and JC-247 are Done and implemented on canonical main `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. The user requested one stacked draft PR per ticket, so this branch follows JC-290 at `d1d60edfaa7f9ff24dec340cbee9e3f8fac234eb`, PR #216. Use one checkout and sequential implementation tasks with independent specification and quality reviews.

The latest durable AccessEffect is the desired access authority for its exact Subscription source. PostgreSQL grants are the actual state. Neither cache contents, job history, mutable plans nor Subscription status determine a repair target. Store has a scalar zero-or-one target; this work does not introduce NewYou target-set policy.

## Separate recovery and drift repair

Current nonterminal obligations continue through the accepted effective and non-effective executors. Their source fence handles stale work and permitted supersession. Keep that lifecycle separate from APPLIED drift repair.

Add a narrow system operation to repair an exact APPLIED effect. It owns its transaction, proves currentness through AccessEffectCurrentnessFence, and skips stale historical effects. A current non-APPLIED effect is rejected by this operation. The later source-level operation selects the current effect and routes nonterminal work to its existing executor.

For a current APPLIED target, validate its source order-line, contract-change and plan-revision IDs against the locked Subscription's current funded provenance. Reuse the existing immutable PlanRevision target-pair validation. Do not require source-version equality with the aggregate; unrelated aggregate writes are legitimate. An unpaid future contract is not a funded provenance pointer. A mismatch fails closed before grant writes.

Converge through the existing Entitlements source-convergence implementation. Add a narrow variant that first compares the locked source's active grants with the exact target. If already correct, return `already_converged` without writing grants. Otherwise use the existing target upsert, active non-target revoke and final-set validation, returning `repaired`. Both outcomes carry all source-user IDs needed for projection invalidation. This preserves independently valid sources and non-active historical evidence.

The APPLIED effect retains its entire persisted record. Do not reopen its lifecycle, change its fingerprint or source version, or manufacture another target. Use `subscription_source_reconciliation` as operational reason only for newly revoked drift. This reason does not reconstruct historical business policy.

After commit, use the shared notification wrapper and Entitlements invalidation/PubSub path. Propagate projection failures so a targeted worker retry can repeat invalidation even when grants are already converged. Cache is never mismatch authority. The existing cache has a 60-second TTL. This design does not claim durable PubSub delivery after operational retries exhaust.

## Bounded discovery

Verification walks immutable `(inserted_at, id)` keysets over current APPLIED effects, using a fixed sweep high-water and a limit no greater than 500. A query-level latest-source predicate avoids loading every effect history. Batch-read actual active grants for each page, then compare source-local target equality. Healthy candidates must not cause per-source database round trips. Only mismatches enter isolated, fence-checked repair transactions.

Add the smallest required APPLIED verification index and keep its Ash snapshot/migration aligned. Use the existing source identity indexes for exact lookups. If the bounded batch read needs another index to avoid source-history work, include only that index and demonstrate the query shape with EXPLAIN. Do not introduce OFFSET, a global reconciliation lock, another pool, service or dependency.

An Oban sweep worker continues bounded pages and periodically restarts a complete sweep. Cursors record operational progress only. Losing a cursor can repeat work but cannot erase a target or make grants authoritative. Preserve finite execution failure as unresolved work, never manufactured APPLIED state. Reuse the existing nonterminal recovery lane and prove old/exhausted obligations remain discoverable.

Missing-effect inventory is diagnostic. The schema has no rollout or backfill marker, so absence alone cannot distinguish legacy rows, ordinary pre-access states and a violated transition invariant. Report that absence and available immutable provenance without granting, revoking, synthesizing effects or changing aggregate versions. A source-specific repair with no target fails closed. No one-time backfill is authorized by this design.

## Proof and review

Focused tests cover missing and wrong active grants after APPLIED, stale reactivation after a non-effective target, exact scope replacement, empty targets, other sources, valid revocation history, immutable provenance mismatch, unrelated aggregate versions, unpaid future contracts, stale work and projection ordering. Include nonterminal re-drive, repeated/lost enqueue, exhausted retries, worker continuation, cursor restart and old-target reachability.

Measure healthy discovery query counts across page sizes, mismatch repair costs, new selector plans and historical source fanout. Real-connection tests must prove stale scans and delayed workers cannot defeat newer authority. Reuse the required connection test workflow and run each required repetition twice. Run the repository's full checks, strict suite, migration alignment and exact-head reviews before publication.

## Performance & Scaling Review

Reconciliation is warm operational work, with cold historical sweep candidates. Database targets and grants remain authoritative. Discovery is bounded and batched; repair is isolated per source under existing row locks. Index and query-count evidence will be recorded after implementation. Cache invalidation follows commit; the existing cache TTL remains 60 seconds. Oban jobs accelerate recoverable work but do not define completion. Telemetry must use IDs and bounded outcome classes, without source payloads or credentials.

## Runtime Resource Safety Review

Implementation evidence is not yet measured. Bound page size, worker continuation, active-grant result size, connection ownership and transaction lifetime. Measure memory, mailbox, cleanup and pool behavior over at least two equivalent bounded repetitions before making convergence claims. Production capacity, multi-node behavior and allocator/RSS trends remain UNMEASURED unless separately demonstrated.
