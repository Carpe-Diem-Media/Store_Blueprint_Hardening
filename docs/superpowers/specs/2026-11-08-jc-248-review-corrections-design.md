# JC-248 independent review corrections

## Authority and scope

The user requested correction of R1 through R5 in the independent review of PR #217 at `e1f23d179560cffb073b750b08d1a684a2bb87c5`. The affected code remains at published head `d3900b1670427696ec4c45bae37f7be6e1151903`, whose corrected parent is `35ce5bce10fc31f6de5426516d235968db71c0e3`. JC-245, JC-246 and JC-247 are Done. Use the existing checkout, DevCore and append-only commits. No merge, deployment, branch rewrite, operator UI or downstream commercial remediation is authorized.

The latest durable source AccessEffect remains grant authority. A repair must preserve the complete terminal APPLIED record, immutable provenance, exact source fence and independent entitlement sources. The independent review artifact remains unchanged. Its five findings supersede earlier claims that the integration had no actionable defects in those conditions.

## Verification queries

R1 and R2 retain the raw APPLIED insertion window limit before joins. A typed PostgreSQL row comparison provides the lower `(inserted_at, id)` index bound. A descending source-version lookup with LIMIT 1 resolves currentness through the existing source/version index. Natural deep-history plans must assert scan work for actual Ecto-generated SQL, including timestamp ties and one highly skewed source. Query-plan rows are not lifecycle or financial evidence. No planner hints or global settings are permitted.

## Durable repair delivery

R3 adds a purpose-specific operational `AccessRepairDelivery` resource. It has a UUIDv7 ID, unique AccessEffect identity, recipient UUIDs in binary order, positive requested generation, nonnegative delivered generation, last successful delivery time and timestamps. Its private Ash reads and writes require explicit system context. A pending index selects rows where delivered generation is less than requested generation. There is at most one row per repaired effect.

The existing grant-repair correctness transaction requests delivery after source convergence and before commit. All current and affected historical owner IDs returned by convergence remain durable. Actual grant changes always advance the generation. A pending already-converged retry reuses its generation when recipients are unchanged. A changed pending recipient set advances the generation and retains all outstanding recipients. A fresh request after completed delivery advances the generation. Request writes follow the existing Subscription, AccessEffect and grant lock order, then lock the operational row. Delivery acknowledgement locks only the operational row, so it does not introduce a reverse source-lock dependency.

After commit, delivery invalidates and broadcasts to every saved recipient. It acknowledges only the generation and recipient snapshot it actually delivered, after every recipient succeeds. Partial failure, process death or stale acknowledgement leaves pending work. Repeating the full recipient list is allowed. A concurrent later repair cannot be cleared by an earlier acknowledgement. No source or operational lock is held during Cachex or PubSub calls.

Delivery performs no grant mutation and does not replay an AccessEffect. Therefore an old delivery obligation remains deliverable after newer source authority commits. Cache invalidation asks subscribers to read current durable grants; it does not restore old access. This avoids a supersession handoff or a second business-currentness mechanism while retaining historical-owner notifications. Tests must prove this boundary.

The existing periodic AccessEffect recovery sweep gains a separately bounded repair-delivery stream with an immutable insertion high-water and composite insertion cursor. Healthy grants and the original effect delivery timestamp cannot hide pending work. Oban retries accelerate delivery but do not define completion. Repeated pending failures must not monopolize the first page. Pending operational obligations must fence destructive rollback of the new table. The new migration and snapshots must remain aligned.

## Rollback availability

R4 makes each drop in the existing verification-index migration concurrent. Its DDL transaction is already disabled. An isolated DevCore migration test must run the actual migration rollback under long readers and prove new readers and writers can continue for both affected tables. Forward rebuild and catalog validity must be checked afterward. Recovery guidance must inspect invalid or partially built indexes and describe an explicit concurrent drop/rebuild; an ordinary rerun is not an automatic repair of an invalid index.

## Observation diagnostics

R5 returns stable mismatch classes and effective-at-observation evidence separately from repair identity. The observation time is captured for the page and is distinct from the insertion high-water. It follows the existing validity law, inclusive valid-from, exclusive valid-until, active status and no revocation timestamp.

The existing grant query returns at most two active rows per source. Diagnostics must state their sample limit and completeness. A bounded sample cannot certify that no effective grant exists beyond the sample. Single-row current, expired and future cases must be distinct. Tests also cover wrong owner, kind, scope, validity, revocation metadata, missing required access and an incomplete mixed sample. Diagnostics never become caller-provided repair authority. The sweep enqueues only Subscription and expected-effect identities. Telemetry aggregates a fixed set of classes and emits bounded evidence without grant payloads or credentials.

## Verification and downstream work

Each implementation task starts with a focused failing regression, receives a fresh implementation worker, then independent specification and quality reviews. Root runs every Mix command serially through DevCore. R3 tests include cache and PubSub failures separately, partial recipients, real Oban exhaustion and acknowledgement, actual process death after commit before delivery, death after delivery before acknowledgement, concurrent generations, and newer authority during pending delivery. Existing source-fence physical proofs remain required.

After all corrections, inspect the complete #217 diff and run full checks, types, migration alignment and required real-connection repetitions. Refresh #218 through #221 append-only. Preserve #218 amendment `bccbc034`, its real positive purchase evidence and its commercial-target findings. Preserve #219 addendum `73e530a` and immutable Agent 6 review, including the distinction between missing grants and missing authority. Refresh #220's literal action/resource/facade inventory and actual system authorization evidence for any operational surface. Preserve #221's six cases and both CI repetitions. Publish updated draft heads and obtain fresh exact-head CI.

## Resource limits

The inherited convergence helper still loads and locks all grant history for one source. These corrections do not certify arbitrary per-source fanout, memory, GC, lock duration, multi-node notification delivery or production capacity. Query plans, repeated bounded tests and cleanup evidence must report what was measured. Do not replace an unmeasured dimension with a general safety claim.
