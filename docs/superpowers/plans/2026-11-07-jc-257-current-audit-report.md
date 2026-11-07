# JC-257 current recovery audit report implementation plan

> **For agentic workers:** Use subagent-driven-development or executing-plans. Steps use checkbox syntax.

**Goal:** Retain the current JC-257 audit findings, their evidence limits and the separate JC-365 candidate.

**Architecture:** Add a Markdown report. Archive completed execution plans in ignored scratch storage and remove them from the final PR diff. Leave tests and production files unchanged.

**Tech Stack:** Markdown and repository-relative evidence links.

## Task 1: Retain the reviewed report

- [ ] Create `docs/hardening/jc_257_webhook_recovery_audit.md` with the complete content below.

```markdown
# JC-257 webhook ordering and recovery audit

## Verdict and scope

The current runtime is NOT_PROVEN_GOOD overall. A deterministic fulfillment enqueue failure leaves paid truth applied once and no fulfillment job. A distinct success event does not repair that handoff. [JC-365](https://linear.app/jc-dev/issue/JC-365/candidate-recover-paid-order-consequences-after-lost-post-commit) records the separate implementation candidate. This audit changes tests and documentation only.

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

## Remaining limits and ownership

Provider occurrence time and local observation time are distinct. The webhook PaymentAttempt retains normalized event occurrence time and receipt time. The tested Stripe PaymentIntent GET deliberately has no provider occurrence time; its durable observation keeps that field nil. Neither a local query time nor PaymentIntent object creation time proves when money moved.

Unknown-reference handling is characterized by source inspection, not a new automated test here. Interlocks resolves the local intent before creating normalized event/attempt evidence. A missing intent returns `discard`; the receipt facade marks that receipt processed and retains its raw evidence. This does not prove an automatic later replay policy or correct recovery for every unknown reference. That operational classification remains INCONCLUSIVE.

No new test kills a worker after evidence persistence, between paid commit and enqueue, or after provider success before local reference persistence. Those crash and overlap dimensions remain with JC-259 and comprehensive certification JC-263. The injected enqueue failure is evidence for JC-365, not a substitute for those crash tests. Same-event conflicting-payload handling and all distinct-event semantic duplicate forms are also outside the narrow duplicate proof.

The explicit query test uses an Order with finalized matching totals and no checkout lines. It proves the Payments boundary, not a complete checkout or renewal lifecycle. Existing renewal replay does query the same transaction, but this audit does not establish automatic discovery or liveness for every unresolved one-time payment. Provider-specific certification, including Paystack, remains JC-284. Unsupported provider behavior and true-expiry ordering remain INCONCLUSIVE rather than inferred from Stripe fixtures.

## Verification evidence

The two new audit modules contain four tests. Their focused runs passed. The related receipt-worker suite passed 15 tests, provider-observation validation passed four tests and the purge-worker suite passed one test. The handoff module passed three runs after its fixture correction, including its cleanup assertions. Scoped strict Credo, formatting and warnings-as-errors compilation passed for both new modules.

The handoff test commit is `ce464529d76d4709a14db1a7d956b33b4df9262c`; the observation and retention test commit is `59cf9dd8bf3dd7459319dede315298293591bf45`. Final repository checks, exact stack base/head, independent whole-ticket reviews and CI belong to the implementation PR's review evidence. These focused results do not imply comprehensive failure-injection certification.

## Performance & Scaling Review

Production query counts, indexes, caches, queue policy and telemetry are unchanged. The audit adds bounded owned fixtures and test-only queries. It preserves existing payment and collection idempotency. Production throughput, N+1 behavior under load and recovery scan capacity are UNMEASURED.

## Runtime Resource Safety Review

NOT_APPLICABLE to production runtime changes. The fault test verifies owned trigger, function and job cleanup, and its payment fixtures roll back with the sandbox. The observation test supervises its request counter and uses the normal shared sandboxes. Production memory, GC, mailboxes, post-load convergence, multi-node behavior and capacity are UNMEASURED. This audit makes no resource-safety certification.
```

- [ ] Copy the two completed test plans to `tmp/jc257/implementation-plans/`, then delete `docs/superpowers/plans/2026-11-07-jc-257-paid-consequence-audit.md` and `docs/superpowers/plans/2026-11-07-jc-257-observation-retention-audit.md`. They remain in commit history. Archive this report plan there as well after implementation; root will remove this tracked plan before final review.
- [ ] Resolve each relative report link against `docs/hardening`. Run `git diff --check`. Confirm tests and production files are unchanged by this task. No Mix or database commands are needed for this report task; root owns final repository validation.
- [ ] Commit only the report and the two completed test-plan deletions.

## Root self-review

The report covers current duplicate delivery, success precedence, explicit missing-webhook queries, exact renewal identity, retained normalized evidence and the reproduced handoff defect. It distinguishes the exact renewal replay repair from initial/fulfillment branches. Unknown-reference behavior is source-only and remains inconclusive. The report does not claim a real process crash, automatic scanner, full checkout/renewal proof, live provider behavior, or resource convergence. JC-365 is separate from JC-285/245/360. Links and assertions were compared with actual test code and the focused logs before authoring.
