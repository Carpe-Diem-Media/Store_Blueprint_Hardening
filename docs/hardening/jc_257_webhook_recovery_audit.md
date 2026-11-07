# JC-257 webhook ordering and recovery audit

## Verdict and scope

The current runtime is NOT_PROVEN_GOOD overall. A deterministic fulfillment enqueue failure leaves paid truth applied once and no fulfillment job. A distinct success event does not repair that handoff. [JC-365](https://linear.app/jc-dev/issue/JC-365/candidate-recover-paid-order-consequences-after-lost-post-commit) records the separate implementation candidate. This audit changes tests and documentation only.

Independent Agent 6 reviewed head `8708e06a7cbb397d4951feeca66acd2c3f426eef` against base `484e1bee231865f954cfab036c04aa377c39bc4b`. The [preserved review record](reviews/2026-11-07-jc-257-agent-6-review.md) confirms JC-365 and records two additional pre-existing, source-confirmed gaps: P1 receipt-to-processing-job delivery in [JC-371](https://linear.app/jc-dev/issue/JC-371), and P2 evidence preservation before raw purge in [JC-372](https://linear.app/jc-dev/issue/JC-372). Both still need controlled committed-state reproductions. All three findings remain open; the existing bounded test results remain valid.

The audit starts from canonical main `12cb5ee4107ca465c9b773b258c1cbae4754b2c7` and reviews the ticket stack above JC-256 head `484e1bee231865f954cfab036c04aa377c39bc4b`. JC-228, JC-229, JC-230, JC-282 and JC-287 are Done and their relevant capabilities exist on main. The issue's September descriptions of blocked renewal binding, absent provider observation and impossible failure correction no longer describe the current implementation.

The bounded proofs below use local Stripe responses and persisted database evidence. They do not certify live provider behavior, automatic recovery scheduling or all crash boundaries.

## Current evidence

- Duplicate ingress is PROVEN_GOOD for the same Stripe event ID and payload. The existing [controller test](../../test/store_web/controllers/webhook_controller_test.exs) returns the original receipt and leaves one processing job. The first [handoff audit test](../../test/store/workers/jc257_paid_consequence_handoff_audit_test.exs) processes the same persisted success receipt twice and retains one PaymentApplication and one fulfillment job.
- Success followed by late failure is PROVEN_GOOD for the tested paid Order and exact renewal paths. [Receipt worker tests](../../test/store/workers/process_webhook_receipt_worker_test.exs) keep the Order paid and intent succeeded. [JC-235 tests](../../test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs) prevent late failure from reopening dunning after exact paid renewal application.
- Earlier failure followed by authoritative success is PROVEN_GOOD for the explicit observation/application path in the receipt worker tests. Merely observing success leaves commerce unchanged; explicit application corrects the failed intent and pays the Order once. JC-235 separately covers exact paid success after requires_action evidence, while [charged-contract tests](../../test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs) cover same-occurrence suspended recovery. These are separate proofs, not a new end-to-end claim for every event ordering.
- Missing webhook recovery is PROVEN_GOOD for one explicitly requested Stripe PaymentIntent query sequence in the new [observation audit](../../test/store/payments/jc257_observation_retention_audit_test.exs). A processing response records unresolved evidence. Explicit application leaves payment pending. A later success GET uses the same persisted provider reference and records a second observation. Success application and replay pay the same Order once. The test permits exactly two GETs and no POST, and finds no raw receipt containing its owned intent or provider reference.
- Exact renewal identity and charged-contract application have existing proofs. The charged-contract suite rejects a wrong collection or supplied intent, uses the exact collection intent over a stale attempt pointer, and applies the immutable charged contract despite later mutable projections. JC-235's failed requires_action settlement replay queries the existing collection and asserts one collection and one original provider dispatch. A fully joined missing-webhook query through paid renewal reconciliation remains INCONCLUSIVE in this audit.
- Retention after raw purge is PROVEN_GOOD for the exact receipt action in the observation audit. Processing creates normalized ProviderEvent and PaymentAttempt records. Purging that receipt clears raw body and headers while retaining its hash. The test reloads the same normalized records and checks their identities, outcome, references, amounts, environment and occurrence/observation times. The existing [purge worker test](../../test/store/workers/purge_webhook_receipt_evidence_worker_test.exs) covers bounded batch discovery separately. The new test does not run a global purge against unrelated fixtures.
- Eligibility guards have focused [provider observation tests](../../test/store/payments/provider_observation_test.exs) for provider, reference kind, transaction, amount, currency, environment and authoritative outcome. An unresolved observation never qualifies as success.

Stripe documents duplicate delivery, unordered delivery and retrieval of missing objects. Its guidance also says event creation timestamps cannot establish delivery order or duplicate identity. The Store tests therefore use durable event and collection identities rather than callback arrival time as commercial authority. [Stripe webhook guidance](https://docs.stripe.com/webhooks#event-ordering), [PaymentIntent retrieval](https://docs.stripe.com/api/payment_intents/retrieve).

## Reproduced paid-consequence defect

The handoff audit uses a published ordinary product, a nonempty physical order line and finalized USD totals of 1,000 minor units that match its submitted intent. Ordinary catalog products use `product_kind: :simple`. The fixture does not certify checkout, shipping, inventory reservations or fulfillment execution.

Its failure test installs a unique trigger that matches only `Store.Workers.EnsureFulfillmentForPaidOrderWorker` and the fixture's exact order ID. Setting that job's `max_attempts` to zero invokes the installed `positive_max_attempts` constraint. The worker logs the actual enqueue error and returns success. PaymentApplication remains singular, the intent succeeded and the Order paid, but no fulfillment job exists. After removing the fault, a different verified event ID for that intent still leaves zero fulfillment jobs.

The fault exercises a real Oban insertion error. It does not suppress an insert silently or change production code. Trigger and function cleanup run in both `after` and `on_exit`. Cleanup removes only owned order jobs and delivery jobs identified by that order's EmailOutbox rows, then checks their absence. The expected error and job operations use DirectRepo outside its test sandbox. Payment data remains inside Store.Repo's sandbox, so this is not evidence of process-exit or machine-crash durability.

Current [Interlocks](../../lib/store/payments/interlocks.ex) commits payment application before its post-commit delivery helpers. Fulfillment, digital, initial Subscription and receipt work have apply-once delivery branches. Already-applied success omits fulfillment, digital and receipt delivery. Exact renewal collection replay has a separate `recovery_required` reconciliation handoff. The historical claim that every paid consequence always skips replay is incorrect for that renewal path.

JC-365 requires a separately reviewed durable or reconstructible recovery mechanism that preserves payment application identity and existing consequence idempotency. JC-285 owns commercial-purpose routing. JC-245 and JC-360 cover later Subscription/access boundaries. This audit implements none of those changes.

## Additional source-confirmed runtime gaps

### P1: verified receipt can lose its processing-job enqueue

[WebhookController](../../lib/store_web/controllers/webhook_controller.ex#L89) persists the verified receipt before independently inserting its processing job. Its [duplicate-receipt branch](../../lib/store_web/controllers/webhook_controller.ex#L162) returns without insertion. If the first insertion fails, or the ingress process terminates after receipt commit and before insertion, redelivery of the same event can acknowledge the existing receipt while leaving it without executable processing work. Source inspection found no receipt redispatch selector. Ordinary duplicate suppression does not prove recovery from a missing first job.

[JC-371](https://linear.app/jc-dev/issue/JC-371) owns the proposed implementation. It must preserve the exact receipt, provider/event identity, verification evidence and payment application boundary while making recovery bounded and observable. A real committed insertion error, process termination and recovery from a fresh process remain unproven. This is an earlier delivery boundary than JC-365; the existing paid-consequence fault test does not exercise it.

### P2: raw evidence can be purged before normalized evidence exists

[The retention selector](../../lib/store/payments/facade.ex#L226) checks age and purge status without checking successful normalization or required evidence persistence. [Interlocks](../../lib/store/payments/interlocks.ex#L82) resolve the local PaymentIntent before recording ProviderEvent and PaymentAttempt evidence. An aged unprocessed or unknown-reference receipt may therefore lose its only usable original payload and headers. A hash cannot reconstruct those financial facts. A processed status alone is insufficient because the facade also marks discarded receipts processed.

[JC-372](https://linear.app/jc-dev/issue/JC-372) owns the proposed evidence-preservation and retention change. The current test proves that already persisted normalized evidence survives purge after successful processing. It does not prove safety before normalization or during a purge/processing race. Current receipt replay still [decodes the raw body](../../lib/store/payments/interlocks.ex#L782); `[PURGED]` returns invalid-payload discard rather than reconstructing an observation from retained evidence. The candidate must satisfy retention/PII authority, including unresolved cases at the raw-retention deadline, without assuming indefinite raw retention.

### Ownership and required production proofs

The follow-up screened all 99 Store Blueprint project issue summaries, ran targeted full-text searches and read the relevant live JC-257, JC-259, JC-260, JC-287 and JC-365 descriptions. No exact implementation owner existed for either additional gap. JC-371 and JC-372 are separate Backlog CANDIDATEs. JC-259 and JC-263 retain crash/overlap certification; JC-260 retains operator observability and recovery auditing. JC-287's accepted normalized-observation work remains valid. The candidate descriptions contain deterministic acceptance tests for their separate production changes.

Those tests must use committed owned fixtures, independent connections and barriers at the relevant persistence, job-insertion, normalization, raw-deletion and acknowledgement boundaries. They must prove exact persisted identity, duplicate redelivery, no repeated provider collection or financial application, bounded recovery/retention progress and preservation of authoritative evidence. Purge proofs must include an unknown-reference receipt marked processed without normalized evidence. Repeat equivalent bounded crash/race runs at least twice and verify cleanup. These are future acceptance requirements, not results of this audit.

Production remediation remains outside PR #219. Recording these candidates does not resolve any finding or certify automatic recovery.

## Remaining limits and ownership

Provider occurrence time and local observation time are distinct. The webhook PaymentAttempt retains normalized event occurrence time and receipt time. The tested Stripe PaymentIntent GET deliberately has no provider occurrence time; its durable observation keeps that field nil. Neither a local query time nor PaymentIntent object creation time proves when money moved.

Unknown-reference handling is characterized by source inspection, not a new automated test here. Interlocks resolves the local intent before creating normalized event/attempt evidence. A missing intent returns `discard`; the receipt facade marks that receipt processed and retains its raw evidence. This does not prove an automatic later replay policy or correct recovery for every unknown reference. That operational classification remains INCONCLUSIVE.

No new test kills a worker after evidence persistence, between paid commit and enqueue, or after provider success before local reference persistence. Those crash and overlap dimensions remain with JC-259 and comprehensive certification JC-263. The injected enqueue failure is evidence for JC-365, not a substitute for those crash tests. Same-event conflicting-payload handling and all distinct-event semantic duplicate forms are also outside the narrow duplicate proof.

The explicit query test uses an Order with finalized matching totals and no checkout lines. It proves the Payments boundary, not a complete checkout or renewal lifecycle. Existing renewal replay does query the same transaction, but this audit does not establish automatic discovery or liveness for every unresolved one-time payment. Provider-specific certification, including Paystack, remains JC-284. Unsupported provider behavior and true-expiry ordering remain INCONCLUSIVE rather than inferred from Stripe fixtures.

## Verification evidence

The two new audit modules contain four tests. Their focused runs passed. The related receipt-worker suite passed 15 tests, provider-observation validation passed four tests and the purge-worker suite passed one test. The handoff module passed three runs after its fixture correction, including its cleanup assertions. Scoped strict Credo, formatting and warnings-as-errors compilation passed for both new modules.

The handoff test commit is `ce464529d76d4709a14db1a7d956b33b4df9262c`; the observation and retention test commit is `59cf9dd8bf3dd7459319dede315298293591bf45`. Final repository checks, exact stack base/head, independent whole-ticket reviews and CI belong to the implementation PR's review evidence. These focused results do not imply comprehensive failure-injection certification.

Agent 6 independently inspected all four original changed files, the source requirements and the relevant payment implementations. The reviewer ran 14 pure eligibility/outcome tests without app startup or the database test helper; all passed. CI run [42370642832](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/42370642832) passed all six jobs for the original reviewed base/head. Its synthetic merge `1da6cc22f38392e2f58e5d67bd53d372591a70bf` had the same tree as that head, and its PostgreSQL log recorded the actual `positive_max_attempts` violation. These results certify the stated original checks only. The documentation amendment requires its own incremental review and CI, recorded on the PR.

## Performance & Scaling Review

Production query counts, indexes, caches, queue policy and telemetry are unchanged. The audit adds bounded owned fixtures and test-only queries. It preserves existing payment and collection idempotency. Production throughput, N+1 behavior under load and recovery scan capacity are UNMEASURED.

## Runtime Resource Safety Review

NOT_APPLICABLE to production runtime changes. The fault test verifies owned trigger, function and job cleanup, and its payment fixtures roll back with the sandbox. The observation test supervises its request counter and uses the normal shared sandboxes. Production memory, GC, mailboxes, post-load convergence, multi-node behavior and capacity are UNMEASURED. This audit makes no resource-safety certification.
