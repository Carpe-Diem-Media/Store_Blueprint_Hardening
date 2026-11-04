# JC300 Initial Paid Activation Authority

- **Status:** PROPOSED / NOT YET APPROVED
- **Baseline:** `853894f28d89ce8a6358dc088f40e4ee8721490b`
- **Implementation authority:** NONE until human approval of this document and the applicable implementation issue.

## Decision requested

Route newly created paid-order Subscriptions through the existing AccessEffect and F1 path. The source transaction must atomically persist the Subscription, its SubscriptionItem, and one exact EFFECTIVE AccessEffect. After commit, the caller passes the exact returned effect ID to F1. A committed source remains durable if F1 or post-commit projection fails.

This proposal is separate from the JC-300 ordinary-renewal writer authority. The ordinary-renewal slice explicitly left initial activation unchanged and does not authorize this cutover. Preserve the accepted F0/F1/F2 and JC247-C contracts.

This authority covers recovery after the Subscription source transaction. It does not cover recovery when a paid-order subscription-creation job is never enqueued.

## Evidence and ownership

The current paid-order facade verifies a paid Order, rejects renewal Orders, requires a user, loads subscription OrderLineItems and a succeeded PaymentIntent, then creates each Subscription and SubscriptionItem inside one `Store.Repo` transaction. After commit it calls `issue_subscription_entitlements_after_commit/1`; that path calls `EntitlementsFacade.issue_subscription_entitlement_for_system/2` and converts grant errors to a skipped count. No AccessEffect is established in this source path. Existing source replay skips the line.

The shared target helper derives an EFFECTIVE target from an active Subscription and supplied PlanRevision. It checks that `current_plan_revision_id` exists but does not compare that ID to the supplied revision's ID. The initial producer must make that exact identity comparison itself before deriving or establishing a target.

### Authority references reviewed

- `lib/store/subscriptions/facade.ex`: paid-order creation, source transaction, legacy issuance helper, typed effect establishment, and F1 execution entrypoint.
- `lib/store/subscriptions/access_effect_target_order.ex`: current-target and EFFECTIVE target derivation; the initial producer's revision equality guard remains explicit.
- `lib/store/subscriptions/access_effect_currentness_fence.ex`: Subscription-first lock, exact candidate identity, fingerprint/executability checks, and latest-effect proof.
- `lib/store/workers/ensure_subscriptions_for_paid_order_worker.ex`: existing Oban retry contract; this proposal changes no worker architecture.
- `docs/superpowers/specs/2026-10-22-jc-245-246-access-effect-convergence-authority-design.md`: accepted F1/F2 lifecycle, source fence, projection repair, recovery selectors, indexes, and scaling boundaries.
- `docs/superpowers/specs/2026-10-29-jc247-c-cancellation-policy-authority.md`: accepted cancellation target and exact F1/F2 dispatch semantics.
- `docs/superpowers/specs/2026-10-25-jc-300-ordinary-renewal-writer-cutover-design.md`: ordinary-renewal cutover explicitly leaves initial activation outside its authority.
- `docs/governance/sbh_50_access_effect_entitlements_authority_amendment.md`: ownership split, caller-owned transaction, and post-commit Entitlements projection contract.

| Owner | Authority |
|---|---|
| Orders and Payments | Verified commercial Order and payment truth, including the existing succeeded-PaymentIntent selection. |
| Subscriptions | Initial Subscription and SubscriptionItem creation, eligibility, exact purchased-revision proof, period evidence, and desired target. |
| AccessEffect | Durable immutable target, source version, fingerprint, execution obligation, and lifecycle. |
| F1 | EFFECTIVE target currentness, exact-source convergence, and APPLIED/SUPERSEDED outcome. |
| Entitlements | Actual Subscription-source grant rows and post-commit cache/PubSub projection. |
| PostgreSQL | Durable correctness, uniqueness, source serialization, transaction commit, and recovery selection. |

Redis, Cachex, GenServer memory, PubSub, Oban ordering, retries, and worker memory are not correctness authorities. Cache and PubSub remain post-commit projections only.

## Eligibility and atomic source transaction

An initial activation is eligible only under the existing paid-order preconditions:

- `Order.state == :paid` and the existing facade has selected a `PaymentIntent.state == :succeeded` for that Order.
- The Order is not a renewal Order bound to a RenewalAttempt.
- The Order has a user and a subscription OrderLineItem with the existing purchased plan and revision snapshots.
- The purchased PlanRevision belongs to the snapshotted SubscriptionPlan and has the existing accepted purchase-history status (`effective` or `retired`).
- No Subscription already owns that exact `OrderLineItem.id` as its source.

Keep payment precedence, payment selection, provider selection, and payment application behavior unchanged. Reuse the current `fetch_paid_order/1`, `ensure_initial_subscription_order/1`, `fetch_succeeded_payment_intent/1`, and provider-selection behavior. Duplicate payment events or repeated paid-order jobs must not create a second Subscription, SubscriptionItem, or initial AccessEffect for the same source OrderLineItem. The existing source-order-line uniqueness remains the database guard; a losing concurrent create rolls back and is retryable.

For each newly eligible line, one outer PostgreSQL transaction must:

1. Create the active Subscription using the exact source Order, OrderLineItem, and purchased PlanRevision.
2. Persist the SubscriptionItem for that same OrderLineItem.
3. Prove the exact identities below, validate persisted period boundaries, construct a typed `EstablishAccessEffectInput`, and establish one EFFECTIVE AccessEffect through the existing establishment path while still inside this transaction.
4. Return the exact AccessEffect ID with the transaction result. Do not look up “latest” after commit.

The outer transaction currently reduces all subscription lines. Keep the source writes and each line's effect in that same transaction. Any source, item, exact-evidence, or effect-establishment failure rolls the transaction back; no newly created Subscription may commit without its item and effect. Preserve post-commit notification delivery. A process crash or notification failure after commit but before F1 leaves the REQUIRED effect durable for recovery.

For every newly created line, independently require:

| Evidence | Required proof |
|---|---|
| Order | `subscription.source_order_id == order.id`. |
| OrderLineItem | `subscription.source_order_line_item_id == line_item.id`; the line belongs to the paid Order. |
| Plan | The purchased revision belongs to the snapshotted plan, and `subscription.subscription_plan_id == revision.subscription_plan_id`. |
| PlanRevision | `line_item.subscription_plan_revision_id_snapshot == revision.id == subscription.current_plan_revision_id`. Passing a PlanRevision into `AccessEffectTargetOrder` alone is insufficient. |
| Source version | Use the newly created Subscription's persisted `aggregate_version` for the effect's `source_version`; never invent a version after commit. |
| Period | Persisted `current_period_start_at` and `current_period_end_at` are DateTimes with `start < end`. Do not use F1 execution time. |
| Target pair | Copy the exact purchased revision pair. Both kind and scope must be present, or both nil. A half-present pair fails closed. |
| Validity | For a complete pair, `valid_from_at` equals the persisted period start and `valid_until_at` equals the persisted period end. For accepted EFFECTIVE nil/nil, preserve `valid_from_at=nil` and the persisted period end; still prove the Subscription's persisted start/end are valid. |
| Provenance | Persist exact `source_order_line_item_id`, `plan_revision_id`, and `contract_change_id=nil`. The AccessEffect resource computes and persists the current target fingerprint from the typed evidence. |

The current target helper may supply the normalized EFFECTIVE evidence only after the producer has proved revision identity. Do not re-read mutable Plan data after commit or derive a different target from status, worker time, grant rows, or payment metadata.

## AccessEffect and F1 lifecycle

New effects begin `REQUIRED`. The source transaction commits the commercial source and its execution obligation together. F1 receives the exact returned ID after commit and owns its existing correctness transaction.

New effects use the existing target-fingerprint v2 byte contract. Preserve the accepted historical v1 compatibility rule; this cutover does not change fingerprint encoding or reconstruct historical validity evidence.

| Case | Guard and transition | Durable side effect and outcome |
|---|---|---|
| Current executable effect | F1 locks the exact Subscription first, then the candidate effect; verifies source identity, `source_version <= aggregate_version`, persisted fingerprint, executable target, EFFECTIVE disposition, and that the candidate ID is latest. `REQUIRED -> PENDING -> APPLIED`, `FAILED_RETRYABLE -> PENDING -> APPLIED`, or `PENDING -> APPLIED`. | Converge the complete exact Subscription-source target and APPLIED state in one transaction. Commit before cache invalidation, PubSub, or notifier delivery. |
| Stale executable effect | Same source/effect locks and integrity checks; latest effect ID differs. `REQUIRED -> PENDING -> SUPERSEDED`, `FAILED_RETRYABLE -> PENDING -> SUPERSEDED`, or `PENDING -> SUPERSEDED`. | No grant mutation. Return `:superseded`. |
| Qualifying convergence failure | Roll back the F1 transaction, including the grant mutation and PENDING/APPLIED changes. In a separate transaction, repeat the accepted currentness proof. If still current, record `REQUIRED -> PENDING -> FAILED_RETRYABLE` or `PENDING -> FAILED_RETRYABLE`; an already FAILED_RETRYABLE row remains unchanged. | Return the error. The committed Order and Subscription remain unchanged. The exact effect remains eligible for the existing effective recovery selector. |
| Proof or integrity failure | Source identity, currentness, fingerprint, target executability, or disposition guard fails. Do not mutate grants or advance the AccessEffect lifecycle. | Fail closed and report the error. These non-retryable authority/integrity failures remain unresolved and require operator investigation using existing persisted evidence and diagnostics. Automatic recovery must not reconstruct a target from mutable Plan data, grant history, or guessed values. Re-running the same proof does not authorize repair. |
| Post-commit projection failure | Grant convergence and APPLIED commit have already succeeded. | Return `:applied_projection_pending`; keep the effect APPLIED and eligible for existing projection repair. Do not move it to FAILED_RETRYABLE or repeat grant convergence solely to repair projection. |
| Terminal replay | Candidate is APPLIED or SUPERSEDED. | Return the existing terminal no-op outcome. APPLIED and SUPERSEDED do not execute again. |

F1's latest-ID check is the ordering guard; retain the accepted `source_version <= aggregate_version` rule and do not add source-version equality. Validate target executability before stale supersession. A wrong executor, invalid transition, incomplete pair, invalid interval, or corrupt fingerprint must not touch grants or advance lifecycle state. The EFFECTIVE nil/nil target is valid and converges to an empty exact-source grant set while remaining distinct from NON_EFFECTIVE.

The F1 lock order remains Subscription, candidate AccessEffect, latest-effect proof, exact-source grant rows in native PostgreSQL UUID order, convergence, APPLIED, commit. Effect establishment continues to use the Subscription source lock before effect history. No executor runs inside the paid-order source transaction, and no post-commit caller query substitutes for F1's currentness proof.

## Replay, recovery, and failure boundaries

| Event | Required behavior |
|---|---|
| Worker crash before source commit | PostgreSQL rolls back Subscription, SubscriptionItem, and AccessEffect together. A job retry starts from the still-paid Order and current payment evidence. |
| Worker crash after source commit but before F1 | The source and REQUIRED effect remain committed. The existing bounded EFFECTIVE recovery path executes that exact persisted target. |
| F1 convergence error | Return the error from the facade so the existing paid-order Oban worker sees `{:error, reason}` and may retry. Do not turn a post-commit error into a source rollback or `:skipped`. Oban is prompt retry only; durable AccessEffect recovery is the correctness path. |
| F1 projection error | Preserve the successful F1 result as projection-pending. Existing projection repair repeats cache invalidation and PubSub without changing grant truth or APPLIED. |
| Duplicate paid-order job/payment replay | Existing source-line identity prevents duplicate source rows. Existing lines are skipped for creation and no new target is derived. An effect already established for a new activation remains under its own recovery lifecycle. |
| Multiple subscription lines | Source rows and all initial effects commit or roll back together. Post-commit F1 dispatch is one exact ID per new Subscription, in existing line order. Stop dispatch at the first F1 error and return it; unattempted effects remain in their durable executable state (normally REQUIRED) and recoverable. A retry or recovery must not recreate source rows or effects. |
| Cancellation commits before activation F1 | The cancellation transaction establishes its newer exact target under the same Subscription lock. F1 sees the initial effect ID as stale, supersedes it through PENDING, and performs no old-target grant mutation. The accepted JC247-C producer/executor resolves the newer EFFECTIVE or NON_EFFECTIVE target. |
| Activation F1 acquires the Subscription lock first | F1 may commit the initial target APPLIED while holding the source lock. Cancellation waits, then commits a newer target and dispatches the existing JC247-C F1/F2 path. The final projection follows that newer effect. |
| Replay of a source with an existing AccessEffect | Do not establish a second effect, select a new target, or use an arbitrary latest effect. Its existing REQUIRED/PENDING/FAILED_RETRYABLE obligation belongs to the existing recovery lifecycle; its APPLIED/SUPERSEDED outcome remains terminal. |
| Historical Subscription without an AccessEffect | Skip source creation and do not derive an EFFECTIVE target on replay. Do not restore grants from mutable Plan data, current Subscription status, or grant history. Historical repair requires separate verified authority. |

The two cancellation lock orders must be proved with independent PostgreSQL connections and the existing lock-barrier style, without sleeps. JC300 does not reinterpret cancellation policy or payment-versus-cancellation precedence.

### Worker error contract and committed truth

A post-commit F1 correctness error is returned from `create_subscriptions_from_paid_order_for_system/1`; the existing worker then returns `{:error, reason}` and Oban may retry. The source transaction has already committed and remains authoritative. Because exact source replay can skip the existing line, worker retries are not the recovery guarantee: the REQUIRED or FAILED_RETRYABLE effect and the existing bounded recovery selector are. Projection-pending is a successful synchronization outcome and does not request a source retry.

This design does not promise recovery when payment succeeds but the subscription-creation job is never durably enqueued. That is a separate payment-fanout recovery question.

## Compatibility

Keep the public result map and field types unchanged: `order_id`, `subscription_line_count`, `created_count`, `skipped_count`, and `entitlement_issued_count`. Keep creation and replay count semantics tied to source-line creation.

`entitlement_issued_count` counts a successful F1 APPLIED outcome (`:applied` or `:applied_projection_pending`) for a newly processed EFFECTIVE target with a complete kind/scope pair. It remains zero for EFFECTIVE nil/nil because F1 creates no grant, and for `:superseded` or terminal `:noop`. It is not a count of inserted database rows. Existing-source replay may report zero while a committed effect is still awaiting recovery.

## Performance & Scaling Review

| Dimension | Contract and evidence status |
|---|---|
| Hot path | One paid-order source transaction creates each Subscription, SubscriptionItem, and AccessEffect; post-commit invokes existing F1 once per new Subscription. Multi-line orders therefore fan out to multiple F1 calls. No caller-side latest-effect query is added. |
| Exact-source and recovery indexes | Retain the existing unique Subscription source-OrderLineItem index and unique AccessEffect `(subscription_id, source_version)` index, `entitlement_grants_source_index` on `(source_kind, source_id)`, and `access_effects_effective_recovery_index` for EFFECTIVE REQUIRED/PENDING/FAILED_RETRYABLE rows. The effective selector remains keyset-paged by `(updated_at, id)` with a 1..500 page bound. Add no index or migration. |
| Query bounds and N+1 | Existing paid-order line lookup is order-scoped and sorted by line number. Expect one AccessEffect establishment per new Subscription and one bounded F1 proof/convergence transaction per dispatched effect. Existing F1 locks the complete exact-source grant set; query round trips are structurally bounded, but rows and lock duration depend on source history. No fixed maximum number of grant rows per source is established. Absolute SQL count and latency are UNMEASURED. |
| Locking and pools | PostgreSQL Subscription row locks serialize source target establishment, cancellation, and F1 for one Subscription. The paid-order source transaction is not extended into F1. More subscription lines lengthen the source transaction; simultaneous work may increase pool waits and per-source lock time. Pool wait, lock duration, and contention are UNMEASURED. |
| Recovery amplification | One durable effect exists per new Subscription source version. F1 failures may cause both Oban retries and the existing recovery sweep to retry the same effect; currentness and idempotency make repeated execution safe. Existing recovery remains keyset-paged and bounded to 1..500 effects per page. Recovery lag and retry amplification are UNMEASURED. |
| Cache and PubSub | Keep the existing Cachex raw-grant projection and 60-second TTL. Invalidate after PostgreSQL commit, then publish PubSub. APPLIED projection failures use existing projection repair. No new cache, TTL, Redis representation, or cache-based correctness check. |
| 100k concurrency and runtime resources | No global lock or new long-lived process is introduced, but capacity is not certified. SQL count, p50/p95/p99 latency, source-line fanout, pool waits, lock waits, grant-row cardinality, process memory/GC, recovery throughput, and 100k-concurrency behavior are UNMEASURED pending implementation evidence. Make no capacity, convergence, or no-accumulation claim without the required bounded repeated measurements. |

## Scope exclusions and completion boundary

This proposal does not authorize:

- Historical no-effect Subscription repair or arbitrary historical grant restoration.
- Recovery for a successful payment whose subscription-creation job was never durably enqueued.
- F0/F1/F2 or JC247-C semantic redesign, payment precedence changes, Entitlements implementation changes, schema changes, migrations, indexes, new workers, or generic outbox architecture.
- A final source-coverage claim without a current audit proving that no active production legacy direct grant writer remains. Compatibility APIs may remain only if no production caller bypasses F1/F2.

Historical no-effect sources keep full-population source coverage open until a separate authority verifies their target or explicitly bounds and accepts that debt. The payment enqueue-loss gap is separate from the post-source JC300 cutover; it blocks an end-to-end payment-to-activation recovery claim, not the bounded F1 source-transaction cutover. Any unknown active direct writer blocks a claim of complete JC300 source coverage.

If implementation proves a migration, payment interlock change, worker redesign, Entitlements change, or new target model is necessary, stop and request a narrower authority amendment. Do not absorb it into this cutover.

## Minimal implementation slice and tests

After approval, the smallest proposed production change is limited to:

- `lib/store/subscriptions/facade.ex`: construct and establish the typed EFFECTIVE AccessEffect inside the existing paid-order source transaction; return exact effect IDs; replace the initial activation legacy writer with post-commit exact-ID F1 dispatch; propagate F1 correctness errors without undoing committed source truth; preserve public result fields and payment behavior; add the explicit purchased-revision equality and period-boundary guard.

No change is proposed to the paid-order worker, AccessEffect currentness fence, target-order helper, Entitlements, schemas, indexes, or migrations. Existing recovery and F1/F2 APIs are reused.

Focused test files:

- `test/store/subscriptions/facade_test.exs`: atomic source/effect identity, exact PlanRevision guard, period bounds, nil/nil target and count, public result shape, duplicate source replay, and no legacy writer invocation.
- `test/store/workers/subscriptions_ensure_for_paid_order_worker_test.exs`: duplicate worker runs create one Subscription, item, and effect; post-commit errors are returned for Oban retry without undoing paid/source truth.
- `test/store/subscriptions/access_effect_effective_execution_test.exs`: F1 correctness failure and projection-pending behavior for an activation effect.
- `test/store/subscriptions/access_effect_effective_recovery_test.exs`: REQUIRED/FAILED_RETRYABLE activation recovery and no duplicate grant/source mutation.
- `test/store/workers/run_subscription_access_effect_recovery_worker_test.exs`: recover a committed initial-activation REQUIRED effect through the existing `RunSubscriptionAccessEffectRecoveryWorker`; verify recovery and repeated execution do not create duplicate Subscription, SubscriptionItem, AccessEffect, or grant rows.
- `test/store/subscriptions/access_effect_target_order_contention_test.exs`: activation versus cancellation in both PostgreSQL lock orders, asserting exact latest-effect behavior.
- `test/store/subscriptions/cancellation_renewal_authority_test.exs`: preserve the accepted cancellation and payment/cancellation behavior while exercising an initial-activation effect where the existing fixture permits.

Acceptance requires deterministic proofs for atomic Subscription/SubscriptionItem/AccessEffect establishment; exact purchased PlanRevision and valid period boundaries; nil/nil EFFECTIVE handling; repeated paid-order worker execution; F1 failure and recovery; recovery of a committed activation REQUIRED effect through the existing `RunSubscriptionAccessEffectRecoveryWorker`, with no duplicate Subscription, SubscriptionItem, AccessEffect, or grant rows after recovery and replay; APPLIED projection repair; multi-line partial post-commit failure and retry; both cancellation lock orders; no initial-activation legacy writer invocation; and unchanged payment behavior and public result contract. Tests must use PostgreSQL fixtures and transaction/lock barriers where races are involved.

Human approval of this proposed authority is required before implementation begins.
