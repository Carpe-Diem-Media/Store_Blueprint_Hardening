# JC300 initial paid activation implementation plan

Status: PROPOSED / IMPLEMENTATION NOT AUTHORIZED

Goal: Propose the bounded admission and implementation of atomic initial paid Subscription creation with an exact AccessEffect and post-commit F1 execution.

Architecture: Keep source creation in the existing Subscriptions facade transaction. Establish immutable typed evidence in that transaction, carry exact IDs out, and reuse accepted F1 execution and recovery. Only `lib/store/subscriptions/facade.ex` is a proposed production edit.

Tech stack: Elixir, Ash 3, Phoenix, PostgreSQL, Oban and the existing Entitlements Cachex/PubSub projection.

## Baseline and decision boundary

The planning baseline is `c63f1e859df8b7ba3ae0650681fe963e762fb906`. The permitted fetch succeeded on its first attempt. Local `main` fast-forwarded to that SHA and was clean before this document was created. No implementation, database operation, test or CI run forms part of this planning session.

Authority is `docs/superpowers/specs/2026-11-04-jc300-initial-paid-activation-authority.md`. Its historical baseline is provenance. Its status remains PROPOSED / NOT YET APPROVED, with implementation authority NONE. A merged document does not establish human approval of its proposal.

The requested human decision is whether to admit a separate bounded initial-activation implementation issue under this authority and plan. Approval must name the bounded scope and its acceptance criteria before any implementation starts. Do not reopen or change the canonical JC300 issue's completed contract-freeze status automatically. Do not alter Linear during this task.

This slice covers new initial paid-order sources and recovery after their source transaction commits. It does not complete full JC300 final cutover. Full source coverage still requires a current production-caller audit, separate authority for historical sources without effects, and resolution or explicit acceptance of remaining coverage debt. Payment success without durable subscription-job enqueue remains outside this slice and prevents an end-to-end payment-to-activation recovery claim.

STOP if the authority is contradicted or if implementation requires a schema, migration, index, worker architecture, payment interlock, Entitlements change, new target model, generalized executor or dependency. Request a narrower authority amendment instead of expanding this plan.

## Domain model and permissions

### Commercial evidence and exact relationships

Orders and Payments own commercial truth. Reuse `fetch_paid_order/1`, `ensure_initial_subscription_order/1`, `fetch_succeeded_payment_intent/1` and existing provider selection. Require a paid Order, a selected succeeded PaymentIntent belonging to that Order, a user, and subscription lines belonging to that Order. Reject renewal Orders bound to a RenewalAttempt. Preserve payment precedence, provider choice and payment application behavior. Neither return URLs nor query parameters authorize activation.

Subscriptions owns the source and desired target. For each new line prove:

- `subscription.source_order_id == order.id` and the line's `order_id == order.id`.
- `subscription.source_order_line_item_id == line.id`, and the SubscriptionItem references that same Subscription and line.
- The purchased revision belongs to the snapshotted plan, and `subscription.subscription_plan_id == revision.subscription_plan_id`.
- `line.subscription_plan_revision_id_snapshot == revision.id == subscription.current_plan_revision_id`. The helper's acceptance of a supplied revision does not prove this equality.
- The purchased revision has accepted purchase-history status `effective` or `retired`.
- The effect uses the newly persisted `aggregate_version`, exact source line, exact revision and `contract_change_id=nil`.
- Persisted period start/end are DateTimes with start strictly before end. A complete purchased kind/scope pair copies those exact boundaries. Accepted nil/nil copies `valid_from_at=nil` and the persisted period end while still proving both source boundaries. Reject either incomplete pair.

Keep UUIDv7 identities, integer minor-unit money and currency. Use PostgreSQL native UUID order or binary UUID order for lock ordering, never UUID string sort.

System workers call `Store.Subscriptions.Facade`; this is an explicit system operation using existing system context and resource actions. Do not broaden customer/admin permissions or introduce web resource access. Existing user/admin cancellation facades retain their ownership and role guards. PostgreSQL owns uniqueness, locks and durable commit. Oban ordering, cache contents, PubSub and process memory do not grant authority.

### Subscription and SubscriptionItem

`lib/store/subscriptions/subscription.ex` owns commercial status, funded revision, source identity, period and aggregate version. The general default is `pending`; this paid-order path creates `active` through the existing `:create_from_order_line` action. It does not add a new activation state or payment transition.

Reuse existing transitions without changing their guards: `activate_now` accepts pending/past_due to active; active can become past_due, past_due can become suspended; `extend_period` returns past_due/suspended to active or extends active. Existing cancellation and expiry actions reach canceled and expired. Canceled and expired are terminal in the current state machine. The private cancel-now action permits pending, but public cancellation admission remains the accepted JC247-C active/past_due/suspended contract. Scheduling cancellation changes intent without immediate terminalization; boundary cancellation moves active to canceled under its existing checks. Initial activation does not reinterpret those rules.

`lib/store/subscriptions/subscription_item.ex` persists the purchased item snapshots, quantity and exact source line. It has no independent execution state machine or terminal execution state. Its creation belongs to the same outer transaction as its Subscription and effect. Existing unique source-line identities prevent duplicate Subscriptions and items. A concurrent losing source create must roll back and remain retryable rather than leave partial rows.

Commercial activation does not mean entitlement execution has completed. F1 failure does not reverse an active source or a paid Order. Cancellation establishes newer evidence under the same Subscription lock; it does not rewrite the initial effect's immutable target.

### AccessEffect and accepted F1/F2 contracts

`lib/store/subscriptions/access_effect.ex` owns immutable disposition, source version, provenance, target interval and fingerprint. Build `Store.Subscriptions.Inputs.EstablishAccessEffectInput` through `new/1`; reuse `establish_access_effect_for_system/1`. The existing transaction wrapper joins the outer transaction. Establishment locks the Subscription before inspecting effect history and respects unique `(subscription_id, source_version)` identity. New effects start REQUIRED and use the existing v2 fingerprint. Preserve historical v1 compatibility without reconstructing missing evidence.

For initial activation use EFFECTIVE, including valid nil/nil. F1 owns `execute_effective_access_effect_for_system/1` and refuses execution inside another transaction. Its currentness fence locks Subscription, then candidate AccessEffect, proves identity and `source_version <= aggregate_version`, verifies fingerprint and executable target, and proves latest effect ID. Do not replace that inequality with equality. Validate executability before stale supersession.

Reuse these transitions and outcomes:

- Current REQUIRED or FAILED_RETRYABLE moves through PENDING to APPLIED; existing PENDING can become APPLIED. Grant convergence and APPLIED commit atomically.
- Stale executable REQUIRED or FAILED_RETRYABLE moves through PENDING to SUPERSEDED; PENDING can become SUPERSEDED. No stale grant mutation occurs.
- A qualifying convergence failure rolls back grant changes and lifecycle changes. A separate transaction repeats currentness proof before recording REQUIRED through PENDING to FAILED_RETRYABLE, or PENDING to FAILED_RETRYABLE. An already FAILED_RETRYABLE row remains unchanged.
- Invalid identity, future source version, corrupt fingerprint, wrong disposition/executor, incomplete pair, invalid interval or transition fails closed. Do not mutate grants or lifecycle, guess evidence or treat repeated proof failure as repair authority.
- APPLIED and SUPERSEDED are terminal execution outcomes. Replay returns the accepted terminal no-op. APPLIED may still require projection delivery.
- Projection failure after successful commit returns `:applied_projection_pending`. Keep APPLIED and use existing projection repair; do not mark FAILED_RETRYABLE or reconverge grants just for projection.

F2 remains the accepted NON_EFFECTIVE executor for newer cancellation targets. It converges an empty exact-source active grant set under the accepted fence and lifecycle. Initial activation dispatches only F1; cancellation chooses its exact F1/F2 path from its persisted disposition. No executor or cancellation semantic change is proposed.

### EntitlementGrant and projection

`lib/store/entitlements/entitlement_grant.ex` owns actual grant rows. Its unique identity is `(user_id, kind, scope_key, source_kind, source_id)`. Subscription grants use `source_kind=:subscription` and `source_id=subscription.id`. A complete EFFECTIVE target converges to exactly one active exact-source grant with the persisted kind, scope and interval, and cleared revocation fields. Conflicting active rows for the same source are revoked by existing convergence. EFFECTIVE nil/nil and NON_EFFECTIVE converge to an empty active exact-source set, but retain different commercial meaning. Other sources and users remain untouched.

Persisted states active, revoked and expired differ from temporal read classifications FUTURE, EFFECTIVE, ENDED, REVOKED and INACTIVE. Intervals are start-inclusive and end-exclusive. Existing convergence can reactivate an identity through its dedicated upsert, so revoked/expired historical grant rows are not AccessEffect-style terminal execution records. Do not change generic `:issue`, its defaults or its conflict fields. Entitlements accepts existing typed immutable convergence evidence, never a mutable Plan lookup or worker-time target.

F1 locks exact-source grant rows in native PostgreSQL UUID order, converges, marks APPLIED and commits. Only then invalidate existing Cachex raw-grant projection, publish PubSub and deliver notifications. Preserve the 60-second TTL and existing projection-delivery evidence. Cache expiration is no substitute for post-commit invalidation or durable recovery.

## Implementation map and constraints

Confirmed facade locations at the baseline:

- `lib/store/subscriptions/facade.ex:98` establishes typed effects; line 164 executes exact-ID F1.
- Line 362 runs existing AccessEffect recovery; line 2219 exposes paid-order source creation.
- Lines 2259, 2282, 2301 and 2329 contain result construction, outer transaction and line reduction.
- Line 3645 creates a source from a line; lines 3860 and 3943 create Subscription and item.
- Line 4004 contains legacy initial post-commit issuance; line 10013 joins an existing effect transaction.

Use function names to relocate these after edits. Reuse `AccessEffectTargetOrder.derive_current_target/2` only after producer identity and period proofs. Keep the existing functions and typed inputs. A small local guard or accumulator adjustment in the facade is permitted; a new abstraction or generalized executor is not.

The only proposed production edit is `lib/store/subscriptions/facade.ex`. Existing resource, input, target helper, currentness fence, worker, Entitlements and migration files are references, not implementation targets. Test edits are restricted to the exact files below. Preserve all other callers of compatibility helpers; removing the initial activation call does not authorize deleting unrelated APIs.

## Phases and granular TOON micro-prompts

Lifecycle assertions must match the observable boundary. A committed effect before F1 is REQUIRED. A successful synchronous public facade call that applies the target leaves APPLIED, not REQUIRED. A valid stale execution leaves SUPERSEDED. A qualifying execution failure leaves FAILED_RETRYABLE only after the accepted separate failure-recording transaction succeeds and currentness still holds. A projection failure leaves APPLIED with projection pending. Proof/integrity errors do not authorize a FAILED_RETRYABLE assertion.

At the public-call boundary, inspect persisted source/item/effect/grant evidence after the facade returns and assert its actual F1 outcome. Test establishment alone through the existing typed establishment API and a test-owned committed transaction; label this a component test, not proof that the public initial path paused before F1. Atomic rollback tests inspect absence of all new rows after an error. Tasks 09 and 10 use a committed fixture and control explicit F1 calls at the executor boundary. They do not provide a public-path pre-F1 pause. Public facade integration must separately prove atomic creation, exact-ID handoff and legacy-writer removal. Do not add production-only test hooks, expose private functions for tests, or use notification failure to simulate that boundary. Test fixture failures are not lifecycle evidence.

These prompts are proposed future work, not commands authorized by this document. Execute only after explicit human admission, in this exact order: `01 → 02 → 04 → 03 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12`. Complete and observe the relevant RED tests in Tasks 01, 02 and 04 before either production edit. Tasks 03 and 05 together form the single GREEN cutover; Task 03 alone cannot pass tests requiring successful synchronous F1. Run those tests for GREEN only after Task 05 completes the cutover. Every task inherits the global STOP conditions above. Checkboxes record future completion only. Each test-writing task must observe a meaningful failure before the corresponding production change; fixture/setup errors do not count as RED.

### Phase 1: All initial-cutover RED tests, Tasks 01, 02 and 04

- [ ] Task 01

| Task | Objective | Output | Note |
|---|---|---|---|
| 01_source_atomicity_red | Add failing source/effect atomicity and purchased-identity tests before production edits. | test/store/subscriptions/facade_test.exs asserts one active Subscription, one matching SubscriptionItem and one exact EFFECTIVE AccessEffect per new line; after successful synchronous F1 assert APPLIED, while a separately committed establishment component test asserts REQUIRED before explicit F1; exact order/line/plan/revision/version/provenance/interval equality; failure of any item or effect rolls back all newly created lines. | Use existing PostgreSQL fixtures and supported failure injection. Include a valid but different revision of the same plan, foreign-plan revision, missing revision, never-effective revision, invalid persisted period and incomplete target pair. Retired purchased revisions remain accepted. Inspect existing unique source-line and effect source-version guards; do not add indexes. STOP if proving the producer guard needs a production test hook, new input type or schema change. |

- [ ] Task 02

| Task | Objective | Output | Note |
|---|---|---|---|
| 02_public_and_empty_target_red | Define unchanged public results and exact empty-target behavior. | test/store/subscriptions/facade_test.exs adds failing tests for all five public map keys and their types, complete pair, nil/nil, each half-present pair, duplicate source replay and absence of initial legacy issuance. | Nil/nil is EFFECTIVE with nil valid_from_at and persisted period end, with zero issued count. Count applied and applied_projection_pending complete pairs once; count superseded/noop and empty targets zero. Preserve source-line created/skipped semantics. Require no mutable Plan read after commit and no placeholder grant. STOP if compatibility requires a public field or type change. |

- [ ] Task 04

| Task | Objective | Output | Note |
|---|---|---|---|
| 04_dispatch_failure_red | Prove exact-ID ordered post-commit dispatch and committed-truth errors. | test/store/subscriptions/facade_test.exs and test/store/workers/subscriptions_ensure_for_paid_order_worker_test.exs add failing tests for returned-ID dispatch outside the source transaction, duplicate jobs, first-error propagation and a multi-line failure after earlier success. | Assert post-return committed truth and exact dispatched IDs with existing supported test facilities. Do not require or claim a pause inside the public path. Prove atomic creation, exact-ID handoff and legacy-writer removal separately from the committed-fixture race tests. If approved acceptance instead requires an end-to-end dispatcher pause, STOP=INITIAL_ACTIVATION_RACE_SEAM_UNPROVEN and request an authority decision; do not claim an unobserved REQUIRED boundary. Stop dispatch at the first error; later IDs remain REQUIRED and recoverable. Verify paid Order and selected payment remain unchanged. Existing worker returns error for Oban retry. No caller latest-effect lookup is allowed. STOP if this needs a worker rewrite or payment interlock. |

### Phase 2: Single GREEN production cutover, Tasks 03 and 05

Tasks 03 and 05 are one indivisible production cutover. Their ordering describes local implementation steps only. No intermediate PR merge, release, deployment or acceptance may leave both the new initial AccessEffect producer and the old initial direct grant writer active. Review and deliver both changes together, with the direct writer removed from the initial path and exact-ID F1 dispatch in place. Task 03 alone is not an acceptable production result and must not claim GREEN for tests requiring successful synchronous F1. Those tests become GREEN only after Task 05 completes exact-ID dispatch and removes the initial direct writer.

- [ ] Task 03

| Task | Objective | Output | Note |
|---|---|---|---|
| 03_atomic_initial_effect | Implement the atomic source/effect portion of the smallest facade cutover. GREEN for successful synchronous F1 requires Task 05 as well. | lib/store/subscriptions/facade.ex updates create_subscription_from_line/4 and existing line reduction to prove persisted identities and periods, derive the purchased target, construct EstablishAccessEffectInput.new/1 and call establish_access_effect_for_system/1 inside run_subscription_creation_transaction/3. The internal result carries each exact returned effect ID and complete-pair count evidence. | All lines share the existing outer Repo transaction. Any source/item/evidence/effect failure invokes existing rollback handling. Use persisted aggregate_version, never execution time. Establishment locks Subscription before effect history and uses the existing unique subscription/source_version identity. No F1 or projection occurs here. Preserve return_notifications?: true and collected post-commit notifications. Tasks 03 and 05 must ship as one indivisible cutover; no intermediate merge, release, deployment or acceptance with both initial writers active. STOP if atomicity requires changing resource actions, the helper, Entitlements or the transaction architecture, or delivery separates the cutover. |

- [ ] Task 05

| Task | Objective | Output | Note |
|---|---|---|---|
| 05_exact_dispatch | Replace initial legacy issuance with the accepted F1 call and preserve public results. | lib/store/subscriptions/facade.ex adjusts build_subscription_creation_result/3 and the initial post-commit reduction to invoke execute_effective_access_effect_for_system/1 once per newly created source, using its exact returned ID in original line order. Return the first correctness error unchanged through existing normalization and worker contract; retain all public keys and count types. | Notify after source commit as before. Do not turn errors into skipped counts or pretend the committed source rolled back. Projection-pending is successful APPLIED synchronization. Preserve Cachex invalidation then PubSub only after the F1 commit and the existing 60-second TTL. No new cache or latest query. Deliver with Task 03 as one indivisible production cutover and verify the initial direct writer is inactive before acceptance. STOP if any public result, worker behavior or non-initial writer must change, or an intermediate dual-writer release is proposed. |

### Phase 3: Replay, durable recovery and projection repair, Tasks 06 through 08

- [ ] Task 06

| Task | Objective | Output | Note |
|---|---|---|---|
| 06_replay_and_historical_exclusion | Prove replay cannot invent new evidence or duplicate durable rows. | test/store/subscriptions/facade_test.exs and test/store/workers/subscriptions_ensure_for_paid_order_worker_test.exs cover duplicate jobs/events, existing sources with each effect lifecycle state and historical sources without effects. Source replay skips creation without establishing or dispatching an arbitrary current effect. | Compare exact source/item/effect/grant IDs and counts across repetitions. Existing unique source-line identities guard concurrent creation; the losing transaction rolls back. Historical no-effect sources remain excluded even if Plan or grant history has changed. STOP if recovery demands backfill or historical target reconstruction. |

- [ ] Task 07

| Task | Objective | Output | Note |
|---|---|---|---|
| 07_correctness_recovery | Prove REQUIRED and FAILED_RETRYABLE activation obligations recover through existing APIs and worker. | test/store/subscriptions/access_effect_effective_execution_test.exs, test/store/subscriptions/access_effect_effective_recovery_test.exs and test/store/workers/run_subscription_access_effect_recovery_worker_test.exs cover a test-owned committed source/effect fixture without dispatch as a component recovery test, qualifying convergence rollback, retryable failure recording and successful recovery through Store.Workers.RunSubscriptionAccessEffectRecoveryWorker.perform/1. Repeated recovery creates no duplicate Subscription, item, effect or grant. | Reuse run_subscription_access_effect_recovery_for_system/1. Effective selection uses access_effects_effective_recovery_index and updated_at/id keyset cursors with a 1..500 page limit, default 100. Verify boundaries, continuation and terminal exclusion. Both Oban retries and sweeps may attempt an effect, so measure duplicate attempt DB amplification later. Oban retry alone is not the recovery guarantee. The committed fixture does not prove a controlled crash between public initial source commit and F1; no such public-path crash proof is claimed. If the approved authority requires that additional end-to-end pause, STOP=INITIAL_ACTIVATION_RACE_SEAM_UNPROVEN and request an authority decision. STOP if a new sweep, worker or unbounded scan appears necessary. |

- [ ] Task 08

| Task | Objective | Output | Note |
|---|---|---|---|
| 08_projection_and_invalid_evidence | Prove projection repair preserves committed grant truth and invalid evidence fails closed. | test/store/subscriptions/access_effect_effective_execution_test.exs and test/store/subscriptions/access_effect_effective_recovery_test.exs cover applied_projection_pending, existing projection repair, terminal replay, corrupt fingerprint, invalid interval, wrong source/version/disposition/executor, incomplete pairs and stale invalid targets. | Assert invalid evidence changes neither grants nor lifecycle and needs investigation rather than guessed repair. APPLIED projection repair retries Cachex invalidation and PubSub without grant DML or FAILED_RETRYABLE. Preserve fingerprint v2 and accepted v1 compatibility. Test valid stale targets supersede only after executable-target proof. STOP if F1/F2, fingerprint encoding or Entitlements semantics need modification. |

### Phase 4: Independent-connection cancellation races, Tasks 09 and 10

The race designs below use a test-created, transactionally committed initial-source/effect fixture. They prove AccessEffect/F1 versus cancellation ordering. They do not pause or race the entire paid-order creation call. Separate public facade integration tests in Tasks 01, 02 and 04 must prove atomic source/effect creation, exact-ID post-commit handoff and removal of the initial legacy writer. Do not call the combined coverage a single end-to-end race proof unless that is actually demonstrated. No public dispatcher pause is claimed or required by these boundary designs.

The existing lock order is verified in `lib/store/subscriptions/access_effect_currentness_fence.ex`. `prove_in_transaction/1` reads the candidate's Subscription ID without locking the candidate, calls `lock_subscription/1` with FOR UPDATE, then calls `lock_candidate/1` with FOR UPDATE on the exact effect ID. Integrity and latest-effect proofs follow. A test-owned candidate-row lock therefore lets F1 acquire the source lock and then wait at the candidate, without production instrumentation.

Reuse the test-process message and real-connection patterns in `test/store/subscriptions/source_fence_contention_test.exs`, especially `start_waiting_task/3`, `backend_pid!/0`, `assert_blocked_by_barrier!/5` and `await_barrier_observation!/1`. Adapt the existing row-lock barrier to the exact candidate row in test code only. `test/store/subscriptions/access_effect_target_order_contention_test.exs` supplies the existing committed-fixture, cancellation and cleanup patterns. Do not wrap F1 in a test-owned outer transaction; F1 must own its correctness transaction. Pin each task's backend with the existing Repo checkout facilities without opening an outer transaction around F1 or public cancellation. Record `pg_backend_pid()` from that pinned connection before starting its API call.

For both orders, commit an active Subscription, matching SubscriptionItem and one REQUIRED EFFECTIVE AccessEffect together, using existing resource actions and `EstablishAccessEffectInput.new/1` with `establish_access_effect_for_system/1`. Prove exact paid Order, line, purchased plan/revision, persisted aggregate version, valid period and target provenance before starting the race. Read back the exact committed effect ID and REQUIRED status. Use a complete pair and controlled accepted cancel-now policy that produces a distinguishable newer target. No mutable Plan evidence or arbitrary latest-ID lookup selects the initial candidate.

Use unique run references, explicit ready/start/release messages, bounded receive/query deadlines and distinct backend PID assertions. For F1-first, connection C observes `pg_blocking_pids` while holding the candidate lock, so the three participating connections suffice. The existing bounded blocker-observation loop may wait for actual PostgreSQL blocker evidence. The evidence is the returned blocker PID relationship for the known row-lock operations, never elapsed time, a poll count, task non-completion or a scheduling assumption. No sleeps or notification failures control either race. Paid-renewal telemetry is unrelated and is not used. Release barriers and clean up only owned fixture rows in test cleanup, including on failure.

STOP=INITIAL_ACTIVATION_RACE_SEAM_UNPROVEN if the fence lock order differs at execution time, the exact candidate-row barrier cannot be used, pinned independent connections cannot be demonstrated, or the approved acceptance authority requires an end-to-end dispatcher pause that these boundary tests cannot prove. Request an authority decision in that case. These are designs supported by source inspection, not runtime proofs; no database operations or tests were run during planning.

- [ ] Task 09

| Task | Objective | Output | Note |
|---|---|---|---|
| 09_cancellation_commits_first | Prove cancellation commits its newer target before initial F1 dispatch, using a committed initial-source/effect fixture. | test/store/subscriptions/access_effect_target_order_contention_test.exs creates and verifies the committed fixture described above. Start an F1 test task on its own pinned connection A; it sends its backend PID and waits for an explicit run-scoped release message before calling execute_effective_access_effect_for_system/1 with the exact initial effect ID. On independent connection B call the existing public cancel-now API with the authorized fixture actor. Require its successful return after its source transaction commits; read back the newer exact target and source version. Only then send the F1 release message. Require the initial effect to become SUPERSEDED through PENDING and return :superseded, with no old-target grant mutation. | Reuse cancellation and committed-fixture patterns from test/store/subscriptions/access_effect_target_order_contention_test.exs and waiting-task/backend identity patterns from test/store/subscriptions/source_fence_contention_test.exs. Snapshot exact-source grant identities and values after cancellation and before release; compare after stale F1, and retain existing grant-mutation evidence to exclude old-target writes. Require distinct A/B backend PIDs and explicit cancellation-completed and F1-release messages, not sleeps or task timing. Verify final grants/projection follow cancellation's newer F1/F2 target. Preserve Subscription-before-candidate lock order and native UUID grant order. This is a boundary test; public facade integration stays separately required. STOP=INITIAL_ACTIVATION_RACE_SEAM_UNPROVEN for any shared race STOP condition above; also STOP if cancellation policy or payment precedence must change. |

- [ ] Task 10

| Task | Objective | Output | Note |
|---|---|---|---|
| 10_activation_locks_first | Prove F1 holds the Subscription lock before cancellation and commits the initial target before cancellation's newer effect. | test/store/subscriptions/access_effect_target_order_contention_test.exs uses three pinned independent PostgreSQL connections A, B and C and the committed fixture. C opens a test-owned transaction and executes SELECT id FROM access_effects WHERE id = $1 FOR UPDATE for the exact candidate ID, with the existing UUID parameter conversion. C sends its locked-row ID and backend PID and waits for release. Start exact-ID public F1 on A outside any outer transaction. Through C require C's PID in pg_blocking_pids(A), at the known candidate lock. Only then start public cancel-now on B. Through C require A's PID in pg_blocking_pids(B), at the exact Subscription lock, and reconfirm A waits for C. Send C an explicit release message and await its transaction completion. Require F1 :applied and persisted initial APPLIED, followed by cancellation's newer committed effect and its accepted F1/F2 outcome. Verify final exact-source grants and projection follow cancellation. test/store/subscriptions/cancellation_renewal_authority_test.exs retains accepted payment/cancellation behavior where existing fixtures permit. | lib/store/subscriptions/access_effect_currentness_fence.ex proves A acquires Subscription FOR UPDATE before candidate FOR UPDATE. C must lock only the exact candidate row, not the Subscription or grants. Reuse message/backend/blocker observation patterns from test/store/subscriptions/source_fence_contention_test.exs and cancellation/cleanup patterns from test/store/subscriptions/access_effect_target_order_contention_test.exs. Require A, B and C PIDs all distinct and sufficient existing pool capacity. A and B keep their checkout but let the public APIs own transactions. Use C for blocker queries while its barrier transaction is open. Capture both blocker PID sets before release; no sleeps or unfinished-task assertions are evidence. Source-lock serialization proves initial APPLIED commit precedes cancellation's source commit; message arrival order after release is not commit-order evidence. Assert initial effect remains APPLIED and cancellation has a distinct newer exact effect. Preserve latest-ID currentness and source_version <= aggregate_version, native UUID grant locks, post-commit Cachex invalidation/PubSub and 60-second TTL. Repeat both race orders in the existing real_connections gate. STOP=INITIAL_ACTIVATION_RACE_SEAM_UNPROVEN for any shared race STOP condition above; also STOP if a new lock order, executor, transaction framework, payment interlock or cancellation interpretation is needed. |

### Phase 5: Measured performance, CI and final acceptance, Tasks 11 and 12

- [ ] Task 11

| Task | Objective | Output | Note |
|---|---|---|---|
| 11_measure_bounded_cost | Record the actual cost of the new source/effect and dispatch path without a capacity claim. | Record evidence in the future bounded implementation PR, using lib/store/subscriptions/facade.ex, test/store/subscriptions/facade_test.exs and test/store/subscriptions/access_effect_effective_recovery_test.exs as the measured paths. Include Performance & Scaling Review and Runtime Resource Safety Review with workload, sample counts, SQL counts and latency distributions. | Classify paid-order activation as hot, recovery as warm and historical audit as cold. Confirm exact source-line and effect subscription/source_version unique index use, entitlement_grants_source_index for source_kind/source_id and access_effects_effective_recovery_index for bounded updated_at/id pages. Measure line fanout, source-history grant rows, pool waits, lock waits, query counts/N+1, retry/sweep DB amplification, recovery lag and throughput. Preserve 60-second Cachex TTL and post-commit invalidate-then-PubSub order. No fixed grant-row bound exists. Measure process memory, GC, mailbox growth, resource cleanup and post-load behavior over at least two equivalent bounded repetitions. SQL cost, p50/p95/p99, contention and 100k-concurrency capacity remain UNMEASURED until evidence exists; do not extrapolate a small run. STOP if acceptable behavior needs schema/index/dependency/infrastructure changes. |

- [ ] Task 12

| Task | Objective | Output | Note |
|---|---|---|---|
| 12_final_acceptance | Verify the admitted implementation against every authority gate on its exact final head. | Future review evidence records exact base/head, complete diff and changed-file audit, all focused test results, required repository CI statuses, unresolved evidence and human merge decision. Read .github/workflows/ci.yml and docs/governance/performance_scaling.md at execution time. No file or tracker change is authorized by this prompt today. | Run focused PostgreSQL tests through DevCore only after reading .devcore/project.conf and .devcore/render-map.tsv and checking local setup. Never request secrets. Require mix check, strict tests, migration alignment/no generated drift and the real_connections contention gate twice as configured in CI. Include existing performance and type gates where applicable and inspect CI for the exact reviewed head. A later code edit invalidates prior certification. STOP for any failing required check, unresolved acceptance criterion, unauthorized file change or required scope expansion. Human approval and human merge remain separate decisions. |

## Future validation commands and acceptance gates

The following are execution requirements after admission. None were run to draft this plan.

Run the seven focused test files named in Tasks 01, 04 and 07 through 10 with `devcore-project run test -- mix test <exact-file-paths>`. Observe RED before implementation, then GREEN after the minimal change. Run independent-connection cases through `devcore-project run test -- mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs` twice, matching CI. Run required static and strict checks through the existing DevCore test environment, including `mix check`, `mix test --max-failures 1` and `mix ash_postgres.generate_migrations --check`. Do not generate a migration to make this slice pass. Current `.github/workflows/ci.yml` is the command authority for additional applicable jobs.

Admission acceptance requires observed evidence for all of these outcomes:

- All new lines atomically commit Subscription, item and exact effect initially REQUIRED, or all new writes roll back on any line's failure. Successful synchronous F1 leaves APPLIED; valid stale execution leaves SUPERSEDED; qualifying recorded execution failure leaves FAILED_RETRYABLE; failed projection leaves APPLIED with projection pending.
- Purchased revision identity, source/order/plan provenance, period and exact target pair are proved. Nil/nil succeeds as empty EFFECTIVE; both incomplete pairs fail.
- No initial activation legacy writer runs; no mutable target is derived after commit; exact returned IDs dispatch in existing line order.
- Public result shape and count semantics remain unchanged, including projection-pending, nil/nil, superseded and no-op cases.
- Duplicate paid-order jobs and payment replay do not duplicate source, item, effect or grant. Historical no-effect sources receive no guessed repair.
- A first post-commit multi-line failure returns an error while all sources stay committed and unattempted effects remain recoverable. Replay does not recreate them.
- REQUIRED and FAILED_RETRYABLE recover through the existing recovery facade and actual recovery worker. Terminal effects do not execute again.
- Projection repair completes invalidation/publication without redoing grant convergence. Integrity failures preserve grants and lifecycle for investigation.
- Both PostgreSQL boundary race orders must pass with the committed initial fixture, explicit messages, independent connections and the specified candidate-row/blocker evidence. Public facade integration must separately prove atomic creation, exact-ID handoff and legacy-writer removal. Do not claim a single end-to-end dispatcher race from these separate proofs. Accepted payment and cancellation behavior remains unchanged.
- Measured performance and runtime-resource evidence records its limits; exact-head diff, tests and CI satisfy the bounded issue. No full JC300 coverage or 100k-concurrency certification is inferred.

## Approval and planning verification record

Outstanding human approval covers the proposed authority and the separate bounded implementation-admission issue. This document grants no implementation permission and changes no issue state. The canonical JC300 completed contract freeze remains untouched. Future issue selection, branch creation, implementation, commits, PR and merge require the later authorized workflow.

For this documentation-only task, runtime measurement is NOT_APPLICABLE because no runtime behavior changes. All proposed runtime performance measurements remain UNMEASURED. Planning verification consists only of inspecting this document, checking Git status for exactly this new Markdown file, and `git diff --check` plus a whitespace check of the untracked document. No database commands, tests or CI runs are authorized in this session.
