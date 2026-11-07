# JC-259 audit report implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Publish an evidence-bounded current scheduler and crash-recovery audit with one separately tracked retry candidate.

**Architecture:** One durable report records the observed fixture behavior, all C0 through C9 boundaries and all fourteen acceptance dimensions. It distinguishes source inspection, existing tests, new process/acknowledgement proofs and missing certification. Production code stays unchanged.

**Tech stack:** Repository Markdown, current Elixir/Ash/Oban source and observed ExUnit evidence.

## Task 3: Current audit report

Create only `docs/hardening/jc_259_worker_recovery_audit.md` using the complete Markdown below.

- [ ] Read the actual test modules, their final logs and linked source. Verify the wording against evidence and report a contradiction before changing any claim. Task 1 has spec PASS and quality APPROVED. Task 2 has spec PASS and quality APPROVED at 7a25ccf87cecbf4acdc9cfc2abc21ce811cc9a0a. Root independently observed the affected group exit zero with 181 tests, no failures and one exclusion. Do not run Mix for this documentation task.
- [ ] Add this exact report, with only factual corrections agreed with root if needed.

````markdown
# JC-259 scheduler and worker recovery audit

## Verdict and baseline

The current scheduler and recovery behavior is NOT_PROVEN_GOOD overall. [JC-370](https://linear.app/jc-dev/issue/JC-370/candidate-keep-governed-renewal-retries-executable-after-technical) records a reproduced defect: a retained completed technical job can suppress a later governed business retry and a permitted immediate retry after payment-method repair. This audit changes tests, documentation and required CI test coverage. It implements no production remediation.

The audit reviews the stack above JC-258 head `523326e69a12213ed26f64d56be9d0070cf3b7a5`. Canonical main at implementation start is `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. Live prerequisites JC-229, JC-230, JC-237, JC-238, JC-239, JC-242 and JC-252 are Done, and their relevant capabilities exist on main. September descriptions of absent collection fences, retry exhaustion, independent suspension and durable cancellation are historical. The current dependency is Oban 2.24.1, rather than the issue's old 2.20.3 pin.

The new proofs use actual worker callbacks, local PostgreSQL and synthetic Stripe responses. They do not certify live-provider behavior, every crash point or production capacity.

## Reproduced retry defect

The first [retry audit test](../../test/store/workers/jc259_renewal_retry_audit_test.exs) starts a real due occurrence without a payment method and a permitted one-hour retry offset. Its identified persisted job runs through the actual Oban executor. The first error persists PAST_DUE and a future retry deadline, with no collection. Engine acknowledgement stores the job as retryable. An early technical execution finds no reached collection, returns noop and acknowledges the same job as completed.

At the explicit future business clock, the due selector returns the same subscription and renewal key. Inserting that worker and those exact args reports `conflict?: true` against the completed row. For a separate production fan-out assertion, the test moves only that fixture's retry deadline to the past. The fan-out returns `:ok`, retains the completed row and leaves no executable process job. Dunning remains at one and no collection appears. The test does not claim an hour elapsed or that an Oban producer fetched the row; it prepares only the identified execution state before actual acknowledgement.

The repair proof creates a locally succeeded setup intent and invokes the actual success handler. The subscription receives the repaired method, remains PAST_DUE with its existing retry budget, and becomes due. Its immediate enqueue still conflicts with the same completed job. This starts after local setup success; it does not certify setup webhook verification or the complete replacement lifecycle.

A separate test seeds retained completed rows at ages of 23h59m, 24h and 25h relative to its captured reference and observes conflicts. It does not run a Pruner or certify its timing. Installed Basic engine source uses infinite-period matching without an age predicate. The configured Pruner uses a strict older-than predicate against completed jobs' scheduled time, so retained history is not a business retry clock.

Oban's documentation confirms that uniqueness applies at insertion, that the default successful states include completed, and that an insertion conflict returns a successful result containing a job with its conflict flag. Infinite uniqueness lasts while a matching retained row exists. These are queue semantics, not financial correctness guarantees. [Oban 2.24.1 unique jobs](https://oban.hexdocs.pm/unique_jobs.html), [versioned Job source](https://github.com/oban-bg/oban/blob/v2.24.1/lib/oban/job.ex).

JC-370 requires a separate reviewed scheduling correction that preserves configured offsets, immediate repair behavior and duplicate-execution protection. This audit does not select new unique states, change retry budgets or authorize another collection while an earlier one is unresolved.

## Staggered execution and process death

The first [overlap audit test](../../test/store/subscriptions/jc259_worker_overlap_audit_test.exs) pauses worker A in existing Ecto query telemetry after its actual one-row pending claim update completes. A separate observer sees the new timestamp and pending state while A remains paused outside a transaction. Worker B uses a distinct PostgreSQL connection and successfully claims using A's exact new timestamp. Both actual worker callbacks therefore pass separate claims for one pending occurrence.

B proceeds while A is paused. The database contains one RenewalAttempt, collection ordinal one and one PaymentIntent. The local transport receives one POST with the exact subscription, renewal key, Order, attempt, collection and intent metadata. Its idempotency header equals the persisted provider request reference. After A resumes, it returns the exact `PAYMENT_OUTCOME_UNRESOLVED` error with `existing_collection_replay?: true`. Stored identities and counts remain unchanged, the POST count remains one, and the subscription stays active with zero dunning.

This confirms that the attempt CAS is not an execution lease. It also disproves a duplicate-POST outcome for this controlled pending interleaving. The collection and dispatch guards remain separate protections. It does not prove every failed-status interleaving, every provider outcome or provider-side charge count.

The second test kills the actual worker process at the existing checkout-preparation event. Despite that event's historical name, the stored state already contains an Order, a processing attempt, a collection and its deterministic PaymentIntent. The collection is not_started, unresolved and not yet attached to the intent; no POST has occurred. The test observes the worker's killed DOWN result, then calls the actual worker callback again. Recovery reuses the exact Order, attempt, collection, intent and request reference, attaches the intent and makes one local POST. The response stays processing and the collection stays unresolved.

This is actual process-death recovery before dispatch, not a provider-success or paid-reconciliation certificate. These two tests invoke perform callbacks directly; they do not exercise an Oban producer or acknowledgement. Task 1 separately owns acknowledged job-state evidence.

## Crash boundaries C0 through C9

- C0, before occurrence creation: SAFE_RETRY is supported by deterministic occurrence identity and database uniqueness. The accepted [replay test](../../test/store/subscriptions/replay_concurrency_test.exs) observes one attempt under concurrent calls. It uses shared sandboxes and is not a physical-connection proof of the entire scheduler-to-provider chain.
- C1, after occurrence creation and before claim: retry can reuse the bound occurrence. [Collection tests](../../test/store/subscriptions/renewal_collection_attempts_test.exs) and charged-contract binding protect exact identity. A process kill at this precise point remains UNMEASURED.
- C2, after claim and before processing: the new physical overlap proves both fresh claims, one exact collection/intent and one local POST for the pending branch. The resumed execution requires provider reconciliation and returns unresolved. The failed branch and all possible interleavings remain UNMEASURED.
- C3, after processing and before later checkout preparation: current code already persists the Order before marking processing and has a processing-plus-order resume clause. The old permanent-stuck claim is stale. A kill before collection and intent preparation remains UNMEASURED; the new later preparation kill covers C4.
- C4, after prepared collection/intent and before dispatch: SAFE_RETRY is observed for actual process death before collection intent attachment. Recovery reuses all exact identities and submits once locally. Other physical reservation and fence cases retain their separate accepted tests.
- C5, a request may have reached the provider and its response is lost: PROVIDER_RECONCILIATION is required. Preserve the same collection, intent and request identity. A timeout is not terminal financial failure. Current policy tests require an explicit same-request replay capability; current Stripe and Paystack disable it. Successful recovery with a lost provider transaction ID remains INCONCLUSIVE where exact observation is unavailable.
- C6, a response exists only in process memory before local evidence commit: treat the durable state like C5. The new processing-response tests do not inject death after provider acceptance and before evidence persistence. Exact recovery remains INCONCLUSIVE rather than inferred from the response stub.
- C7, verified evidence committed before the attempt becomes terminal: durable evidence and exact success attribution support replay; accepted [success-versus-failure tests](../../test/store/subscriptions/sbh_20_05_success_vs_late_failure_dunning_test.exs) protect against stale dunning. This audit does not inject a kill at that commit boundary, so the full crash proof remains UNMEASURED.
- C8, succeeded attempt before Subscription reconciliation: exact paid handoff and monotonic success support SAFE_REPLAY. [Monotonicity tests](../../test/store/subscriptions/renewal_attempt_monotonicity_test.exs) and [charged-contract reconciliation](../../test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs) cover replay and immutable contract identity. The precise process-death gap remains UNMEASURED.
- C9, commercial reconciliation committed before downstream access or communications: durable AccessEffect recovery owns later delivery. [Effective recovery tests](../../test/store/subscriptions/access_effect_effective_recovery_test.exs) exercise that mechanism. Lost post-commit paid-order consequence enqueue remains JC-365 ownership. This audit does not certify every downstream delivery or create a competing outbox.

## Required issue dimensions

1. Overlapping due ticks retain one occurrence in existing tests; the new C2 physical proof retains one financial collection and local POST. A fully joined physical due-selector/fan-out race remains UNMEASURED.
2. Duplicate execution is measured at the pending claim and prepared-checkout boundaries. It is not measured at every pre/post-claim boundary.
3. Persisted not_started/not_submitted and may_have_been_reached states distinguish local pre-dispatch evidence from possible provider reach. The new kill proof exercises the pre-dispatch case.
4. Ambiguous recovery retains exact collection/intent/request identity in current policy and tests. Provider evidence, not request timeout, decides money movement.
5. Existing collection tests keep requires_action active and reuse the exact unresolved collection. The new overlap observes no second ordinal.
6. Existing tests require certified terminal financial non-success and a due permitted retry before another ordinal. Local intent failure alone cannot certify it.
7. Provider success followed by loss before local reference persistence remains INCONCLUSIVE for unsupported exact observation. No adapter capability or Product rule is invented.
8. Exact renewal replay has a recovery-required paid reconciliation handoff. JC-257 disproved the old blanket no-reenqueue claim. The distinct lost generic paid-order consequence remains [JC-365](https://linear.app/jc-dev/issue/JC-365/candidate-recover-paid-order-consequences-after-lost-post-commit); no duplicate finding is created.
9. Existing paid reconciliation tests enforce exact collection/intent identity, charged-contract application, single period advancement and succeeded monotonicity. They do not replace the remaining injected crash proofs.
10. Existing success-versus-late-failure tests prevent false dunning after exact success. The new unresolved overlap independently leaves the subscription active with zero dunning.
11. Existing [retry exhaustion](../../test/store/subscriptions/sbh_30_03_retry_exhaustion_test.exs) and [suspension boundary](../../test/store/subscriptions/sbh_30_04_failed_payment_suspension_boundary_test.exs) tests preserve dormant PAST_DUE and independent governed SUSPENDED behavior. Technical job completion is a separate queue-liveness concern in JC-370.
12. Existing [cancellation races](../../test/store/subscriptions/sbh_40_03_scheduled_cancellation_race_test.exs) and [durable terminalization](../../test/store/subscriptions/sbh_40_02_durable_period_boundary_terminalization_test.exs) revalidate current targets, rescission and boundary intent. The audit introduces no cancellation precedence law.
13. Oban insertion deduplication is tested separately from PostgreSQL occurrence, collection and dispatch correctness. The completed-job conflict is a liveness defect, not proof that queue uniqueness is financial authority.
14. The final technical-attempt test seeds only the prior counter to four, executes one actual failure and observes discard at five. Its PAST_DUE occurrence remains observable and due, and fan-out inserts a new executable exact-args job because discarded is outside the selected unique states. It does not observe five executions, prove every exhausted error recoverable or claim bounded hot-loop behavior. Business retry exhaustion has its separate accepted tests.

## Recovery limits and ownership

Current [dispatch policy](../../lib/store/subscriptions/renewal_collection_dispatch_policy.ex) chooses reconciliation for reached collections unless exact replay is expressly supported. Stripe supports observation by a known provider transaction ID but does not advertise request-reference observation or same-request replay. Paystack does not advertise merchant-initiated charging, transaction observation or same-request replay. A durable merchant request reference alone is not proof that a provider lookup exists. Unsupported exact recovery must remain unresolved and visible for operator remedy; safe non-duplication does not establish eventual financial resolution.

The remaining injected C0/C1/C3/C5/C6/C7/C8/C9 gaps and full joined overlap matrix belong in [JC-263](https://linear.app/jc-dev/issue/JC-263/sbh-95-08-comprehensive-failure-injectionconcurrency-certification) after release blockers settle. Provider-specific evidence remains with the current provider contract and JC-284. This audit is not early comprehensive certification. NewYou Product-specific grace, cancellation and pricing law is not inferred from Store fixtures.

## Database topology and verification

Production config assigns Oban to Store.DirectRepo and keeps the 24-hour Pruner. Runtime configuration requires a session/direct PostgreSQL connection for DirectRepo and permits STORE_DIRECT_DATABASE_URL to bypass transaction pooling. The audit inspects this configuration; it does not inspect a deployed connection or certify PgBouncer topology.

The retry module contains four tests and passed root's sequential focused verification. Both final focused real-connection repetitions passed two tests with no failures. The new real module is included in both existing required CI repetitions. The affected accepted test group passed 181 tests with no failures and one excluded test. Exact final repository validation, final base/head, independent reviews and remote CI are recorded in the implementation PR. Focused evidence does not imply comprehensive certification.

The real tests commit Repo fixtures, use distinct physical connections, and keep Oban writes in the separate DirectRepo sandbox. Teardown releases barriers, detaches handlers and stops tasks before exact owned-row cleanup. The copied cleanup restores the collection guard within its transaction. The expected Postgrex disconnect follows the deliberate worker kill. The sandboxed retry tests roll back both repositories and never drain or prune shared jobs.

## Performance & Scaling Review

Renewals are hot paths. Production query counts, indexes, caches, TTLs, invalidation, queue policy and telemetry are unchanged. The audit adds bounded fixture queries and two required real-connection proofs. Oban insertion conflict handling is a reproduced liveness finding; database and provider identities remain authoritative. Production N+1 behavior, scan capacity, throughput and operational recovery latency are UNMEASURED.

## Runtime Resource Safety Review

NOT_APPLICABLE to production runtime changes. The tests stop their tasks, detach telemetry, supervise the response cache and clean exact owned database rows. They do not introduce production processes or resources. Production memory, GC, mailbox accumulation, post-load convergence, multi-node behavior and capacity remain UNMEASURED.
````

- [ ] Verify all relative Markdown links resolve, inspect the diff and run `git diff --check`. Confirm no production change, secret, invented Product law, provider capability or blanket crash certificate. Commit only the report with `docs: record JC-259 scheduler and crash recovery audit`.
- [ ] Report the exact commit and observed documentation checks. Do not publish a PR, change Linear state, mutate other files or spawn agents. Root owns final validation and exact-head reviews.

## Root self-review

The report covers C0 through C9 and all fourteen live issue dimensions explicitly. JC-370 owns the one reproduced current defect. JC-365 remains separate, and exact renewal replay is described accurately. Provider loss and unmeasured process-death points remain inconclusive or unmeasured. No evidence is inferred from the CAS alone, old prerequisite text or the old Oban version. Timing, producer preparation, local setup success, retained rows and the technical counter are explicitly bounded. The only table-like mapping uses a sequential list; the deliverable is repository review documentation inside a code PR. No frontend work or standalone visualization is introduced.
