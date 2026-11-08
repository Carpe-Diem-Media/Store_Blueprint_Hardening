# JC-257 independent Agent 6 review record

## Review provenance

The user identified the completed independent review as Agent 6. This record preserves its evidence, findings and limits for [PR #219](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/pull/219), tracked by [JC-257](https://linear.app/jc-dev/issue/JC-257).

- Exact reviewed base: `484e1bee231865f954cfab036c04aa377c39bc4b`.
- Exact reviewed head: `8708e06a7cbb397d4951feeca66acd2c3f426eef`.
- Canonical main at review: `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`.
- Final remote check: 2026-11-07 14:01 UTC. Base, head and main had not moved.
- Scope: all four original changed files, live JC-257 and JC-365 context, governing payment requirements, webhook ingestion, observations, PaymentApplication and fulfillment implementations.
- Method: an isolated checkout, source inspection, read-only CI inspection and pure tests. No code edits, commits, pushes, ticket updates, shared-database mutations, approval or merge occurred during the original review.

The original review was current for those refs. Its conclusions remain bounded evidence rather than a new-head or comprehensive crash certificate. This follow-up adds documentation and candidate ownership only.

## Findings retained from the independent review

### P1: lost paid-consequence delivery, JC-365

The payment transaction completes before fulfillment delivery. The [enqueue error branch](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/8708e06a7cbb397d4951feeca66acd2c3f426eef/lib/store/payments/interlocks.ex#L2096) logs failure and returns success. Already-applied success omits ordinary fulfillment delivery. The [new fault test](../../../test/store/workers/jc257_paid_consequence_handoff_audit_test.exs#L47) checks one PaymentApplication, a paid Order, a succeeded intent and no fulfillment job, then removes the fault and proves a distinct success event still leaves no job.

The trigger is scoped to the exact generated Order and fulfillment worker. It causes the real `positive_max_attempts` constraint error. DirectRepo operations escape their sandbox, while Store.Repo payment fixtures remain sandboxed. This proves the enqueue error and replay behavior. It does not prove that committed payment state survives process termination. [JC-365](https://linear.app/jc-dev/issue/JC-365) remains the implementation candidate.

### P1: verified receipt without processing work, JC-371

[WebhookController lines 89 and 100](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/8708e06a7cbb397d4951feeca66acd2c3f426eef/lib/store_web/controllers/webhook_controller.ex#L89) persist the receipt before inserting its processing job. [The duplicate branch](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/8708e06a7cbb397d4951feeca66acd2c3f426eef/lib/store_web/controllers/webhook_controller.ex#L162) skips insertion. A failed first insertion or termination between those steps can leave a durable verified receipt without processing work, and same-event redelivery alone cannot repair it. No receipt redispatch selector was found.

Evidence is source-confirmed. The reviewer did not perform a controlled committed-state reproduction. [JC-371](https://linear.app/jc-dev/issue/JC-371) now owns the separate proposed implementation, with insertion-error, process-death, duplicate-redelivery and bounded-recovery acceptance tests.

### P2: raw purge before usable normalized evidence, JC-372

[The retention selector](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/8708e06a7cbb397d4951feeca66acd2c3f426eef/lib/store/payments/facade.ex#L226) checks age and purge status without requiring normalized evidence. [Intent resolution precedes evidence persistence](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/8708e06a7cbb397d4951feeca66acd2c3f426eef/lib/store/payments/interlocks.ex#L82). Unprocessed and unknown-reference receipts may lose their only usable original payload. A hash cannot restore it. Replaying `[PURGED]` returns [invalid-payload discard](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/blob/8708e06a7cbb397d4951feeca66acd2c3f426eef/lib/store/payments/interlocks.ex#L782).

The existing [retention test](../../../test/store/payments/jc257_observation_retention_audit_test.exs#L136) proves preservation after successful processing. Safety before normalization, during concurrent purge/processing and after a crash remains unproven. [JC-372](https://linear.app/jc-dev/issue/JC-372) now owns the separate proposed implementation. Its acceptance tests preserve financial and verification evidence while respecting raw/PII retention deadlines, including unresolved cases.

No verified P0 finding or new production regression was identified in the original audit-only diff. Both additional defects predate PR #219. No finding is closed by this documentation amendment.

## Valid proofs and lifecycle distinctions

Receipt identity suppresses ordinary duplicate ingress. PaymentApplication uses an exact Order application key, identity checks, row locks and PostgreSQL uniqueness. Serial success replay leaves one application. This is not a new independent-connection certification of every concurrent financial effect.

The two explicit GETs use the same stored Stripe reference. Their unresolved and authoritative-success outcomes create distinct immutable PaymentAttempt evidence because outcome and provider status participate in the observation identity. Repeating explicit success application leaves one payment application without another provider request. Observation alone does not apply payment. Neither query time nor a PaymentIntent object's creation time proves when money moved.

The lifecycle distinguishes received and verified receipts, observed provider facts, applied payment, scheduled consequences and completed consequences. Receipt `processed` and worker `:ok` do not prove consequence execution. Returned processing errors mark receipts failed; discards mark them processed. A processing status is not an exclusive execution claim. Exact renewal replay has a conditional `recovery_required` handoff, so the older blanket assertion that every consequence skips replay is incorrect.

The new handoff tests inspect fulfillment job rows and never execute fulfillment. Their fixture lacks the shipping adjustment required for fulfillment execution. One queued job is not proof of one completed shipment. A rejected enqueue creates no durable failed consequence job for Oban to retry.

## Verification actually observed

- Both new test modules parsed, and `git diff --check` passed.
- The reviewer ran the four provider-observation eligibility tests and ten outcome-resolver tests directly with ExUnit, without app startup or `test_helper.exs`: 14 tests, zero failures. Reviewed pure source modules were loaded explicitly with cached dependency beams.
- [CI run 42370642832](https://github.com/JCSchoeman96/Store_Blueprint_Hardening/actions/runs/42370642832) passed all six jobs. Logs showed 3 properties and 1,637 tests with zero failures and 49 exclusions, plus two required real-connection runs of 43 tests each. The four new audit tests are not tagged out of the ordinary suite.
- CI checked synthetic merge `1da6cc22f38392e2f58e5d67bd53d372591a70bf`, whose parents were the exact reviewed base/head and whose tree `5d41bfdde6e99df44c3fee34e22ad3eca869cef9` equaled the reviewed head's tree. Its PostgreSQL log contained the `positive_max_attempts` violation.
- Installed Ash 3.37.2, Ecto SQL 3.14.0 and Oban 2.24.1 source was inspected for upsert, sandbox, constraint and test-helper semantics.
- Database suites were not rerun locally. `mix test` setup can create/migrate the shared database, and its helper clears a Redis namespace. The original review's no-mutation constraint excluded those operations.

## Proofs still missing

Committed-state proofs must separately cover receipt commit before dispatch, evidence commit before payment application, paid commit before each required consequence, durable job claim before execution, effect completion before acknowledgement, provider success before local reference persistence and recovery after raw purge. A fresh recovery process must not depend on the terminated process's memory. An actual enqueue error, sandboxed nested transaction, failed durable job, process termination and machine/VM crash are different evidence dimensions.

Automatic discovery/liveness, a fully joined missing-webhook query through paid renewal reconciliation, unknown-reference operational classification, all semantic duplicate forms, unsupported providers and capacity remain unproven. The future candidate implementations require bounded selection, authoritative persisted identity, duplicate redelivery, zero provider collection resubmission and repeated committed-state crash/race runs with exact cleanup. A status flag or retained hash cannot substitute for missing evidence.

## Ownership and downstream integration

The follow-up screened 99 Store Blueprint project issue summaries, searched the relevant full text and read complete JC-257, JC-259, JC-260, JC-287 and JC-365 descriptions. The list API truncates descriptions; summaries were not treated as full issue reviews. No exact implementation candidate existed for the two new gaps.

JC-365 retains paid-consequence recovery, JC-371 owns receipt-to-processing-job recovery and JC-372 owns preservation before raw purge. All remain Backlog CANDIDATEs pending implementation and independent verification. JC-259 and JC-263 retain broader crash/overlap certification, and JC-260 retains operator observability/recovery auditing. Candidate acceptance criteria do not grant implementation authority or freeze a production design.

At the amendment checkpoint, PR #220 at `523326e69a12213ed26f64d56be9d0070cf3b7a5` targets PR #219's branch, and PR #221 at `8ef4c70dcd5e725212dc0a2e40034d5cc715fbcf` targets PR #220's branch. This amendment does not change either descendant branch or its worktree. Advancing #219 changes #220's integration base, so its prior review/CI cannot certify the new pair. The stack owner must incorporate the amendment without losing their work and rerun the affected incremental reviews and CI for #220 and #221. This record does not claim downstream restacking or revalidation has occurred.

Original review approval status: no approval or merge. Amendment validation and CI are recorded separately on PR #219 and JC-257 for the new exact head.
