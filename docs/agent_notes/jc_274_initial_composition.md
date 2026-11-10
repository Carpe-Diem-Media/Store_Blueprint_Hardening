# JC-274.1 initial paid composition

This slice records the existing paid activation's commercial evidence. It does not enable multi-component execution. Base: `d52cfd022cce4b4d5d470368b800bc83220b7d80`. Branch: `jc-274-initial-composition-snapshot`.

## Transaction and ownership

PaymentApplication is already committed by payment application. Activation reads its order-indexed evidence with a two-row limit and requires the exact succeeded PaymentIntent and canonical paid-application key. It neither reapplies money nor contacts a provider.

The Subscription transaction locks the paid Order before checking source existence. This serializes duplicate delivery for that order and avoids the existing open-membership unique index racing the source-line upsert. The transaction inserts Subscription with a preallocated snapshot pointer, its item, the unchanged scalar AccessEffect, and CompositionSnapshot. The composite pointer foreign key is initially deferred and verifies both snapshot ID and Subscription ID at commit. There is no second Subscription update or aggregate increment. Snapshot source_version equals the initial AccessEffect source_version, which is 1 on this path. Later status-only transitions may advance the aggregate without replacing the snapshot.

CompositionSnapshot stores the purchased revision, line/component identity, user, variant, quantity, renewal price, applied payment identity and amount, paid interval, zero or one scalar component, and a deterministic version-1 fingerprint. UUID identities are encoded as binary. It has no update or destroy action. A database trigger rejects updates and deletion while its Subscription survives, including after pointer detachment. Existing Subscription deletion may cascade through the snapshot; this slice does not introduce a new retention policy.

Replay verifies the stored purchase and payment evidence and reuses the snapshot. Conflicting evidence fails closed. Legacy sources with no pointer remain valid and are not backfilled. This initial snapshot is historical purchase evidence, not proof of current funded access after future commercial changes. No consumer may interpret the pointer alone as entitlement authority. The scalar AccessEffect format and fingerprint remain unchanged. Existing post-commit notification and entitlement execution remain in place.

## Acceptance evidence

The focused snapshot tests cover initial creation and version equality, exact replay after a status-only aggregate change, empty entitlement composition, missing payment evidence with complete subscription-side rollback, conflicting purchased evidence, update rejection, deletion rejection after pointer detachment, and cross-Subscription linkage rejection. The independent-connection test checks distinct PostgreSQL backend PIDs, duplicate activation, one source/effect/snapshot, and unchanged version 1, in two equivalent repetitions. Existing activation, worker, and charged-contract reconciliation tests cover compatibility.

## Performance & Scaling Review

Initial paid activation is an existing hot payment-completion path. Replay is warm recovery; retained snapshot history is cold evidence. Neither path adds a storefront or protected-access read. The new evidence path adds one indexed Order row lock per activation, one order-indexed PaymentApplication read per subscription line, and one snapshot insert on creation or primary-key read on replay. No historical snapshot list or scan is needed. Existing order-line iteration and scalar grant execution are unchanged. Independent orders do not share the new lock. Contention and production throughput remain UNMEASURED.

Indexes are the snapshot primary key, unique `(subscription_id, source_version)`, unique `(id, subscription_id)` for the composite foreign key, the existing Order primary key, and existing `payment_applications_order_id_index`. The source/version index also supports source-local foreign-key cleanup. No additional cache, worker, enqueue or idempotency counter exists. Entitlements Cachex TTL remains 60 seconds; existing grant invalidation and PubSub behavior remain unchanged. Snapshot correctness depends on PostgreSQL constraints and the activation transaction, not invalidation or cross-node messages. Lost delivery can replay through the existing paid-order activation worker without repeating financial application.

The focused query telemetry test measured 38 statements for initial activation and 10 for replay in each of two repetitions. Each single-line call used exactly one snapshot query, one PaymentApplication query and one Order lock. The full initial count includes existing scalar entitlement convergence. The final focused command passed 102 tests, including independent connections and unchanged activation/worker/charged-contract tests. These are diagnostic samples, not a capacity benchmark.

## Runtime Resource Safety Review

The change creates no process, mailbox, cache, timer, connection pool, or long-lived in-memory state. Each snapshot payload contains at most one component. Existing Repo ownership closes transactions and releases the new row lock on commit or rollback. The caller retains only bounded new evidence per existing order line. Repeated independent-connection tests certify duplicate database outcomes, not memory or GC convergence. Heap, GC, mailbox accumulation, post-load resource convergence and production capacity are UNMEASURED; no runtime-capacity claim is made.

## Remaining scope

Component addition/removal, future composition, proration, renewal snapshot format changes, reversible holds and JC-276 multi-component convergence remain outside this slice. Final validation results and any outstanding repository-check failures must accompany handoff. No merge is authorized.

## Criteria for this slice

1. Immutable zero-or-one-component Ash resource, migration and resource snapshots.
2. Verification of prior payment application, with subscription-side rollback on missing evidence.
3. Initial snapshot pointer and source-version correctness, including cross-Subscription rejection.
4. Exact replay identity and rejection of conflicting purchase evidence.
5. Empty-entitlement offers and unchanged scalar AccessEffect behavior.
6. Duplicate activation on independent PostgreSQL connections.
7. Existing activation, worker and charged-contract observable outcomes.
8. Bounded new evidence queries and documented performance/resource limits.
9. Required full check, type check and whitespace check on the final candidate.

## Validation commands

```sh
devcore-project run test -- mix test test/store/subscriptions/composition_snapshot_test.exs test/store/subscriptions/composition_snapshot_concurrency_test.exs test/store/subscriptions/facade_test.exs test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs test/store/workers/subscriptions_ensure_for_paid_order_worker_test.exs test/store/support/http/req_client_test.exs --include real_connections
devcore-project run test -- mix check
devcore-project run test -- mix check.types
git diff --check
```

The final focused run passed 102 tests. The clean full check passed three properties and 1,723 tests, with 34 real-connection tests excluded by repository defaults; the focused command above explicitly included the required independent-connection cases. Credo found no issues. Sobelow and documentation generation completed successfully. Existing hidden-type documentation warnings remain outside this change.

The earlier broad attempt overlapped another test VM and encountered connection pressure plus an HTTP timing assertion failure. It also identified two introduced Credo findings, both corrected before the clean full run. No checks were weakened.

A bounded independent static review identified missing deletion protection, corrected with the source-aware delete trigger and focused regression. Subsequent row-lock and replay-helper changes have author-side review and tests; the final uncommitted diff has no independent merge certification or CI candidate. At the implementation handoff, no PR, commit, push, merge or Linear state change had been performed.

## Completion assessment

Task type: IMPLEMENTATION. Task: JC-274.1. Assessment role: author self-assessment. Criteria above: 9/9 PASS, with no failed, unverified or unfinished criterion within this slice. Final `mix check.types` exited successfully with all 144 reported warnings matched by the existing ignore configuration and no new warning. Final `git diff --check` passed.

Implementation Score: 9/10, comprising requirements 4/4, observed verification 2.5/3, correctness and architecture 1.5/2, handoff 1/1. Deductions reflect absent CI for a committed candidate and absent independent review of the final diff. Confidence Score: 90%, a subjective estimate based on focused regressions, real connections, repeated query samples and complete local checks. Production lock contention and capacity remain unmeasured.

Verification Status: VERIFIED for local JC-274.1 implementation criteria only. Merge readiness: NOT_VERIFIED_FOR_MERGE. The next action is independent review of this bounded diff before any integration; JC-274.2 and JC-276 remain separate work. At the implementation handoff, the branch retained uncommitted changes and had no PR or CI status. Opening a PR does not grant merge authorization.

## PR review corrections

The Order-lock-first contention proof gates the first caller after acquiring its Order lock, observes PostgreSQL blocking the second caller specifically on the Order `FOR UPDATE` query, then requires first-create and second-replay success for both lines. A second gate captures the committed source identities before replay can read or modify them. It checks distinct backend PIDs, exact source/item/effect/grant/snapshot identities, unchanged snapshot evidence and aggregate version 1, and an independent source before and after replay. Both required real-connection repetitions now include the snapshot contention suite explicitly.

`payment_amount_minor` records the whole Order payment occurrence. Several line snapshots can reference the same PaymentApplication and PaymentIntent. This is not component funding allocation; summing these amounts across line snapshots would double-count the payment.

Before JC-274.2 adds a format or component semantics, it must define an explicit persisted format version and compatibility validation for the existing version-1 descriptor and fingerprint. This PR does not reinterpret existing records or enable multiple components.

## Correction verification

The previous PR head `6199a7a70fb30a91b330ac89e215e27cd205f8ac` failed required CI because its existing contention proof expected both activations to read an absent source. Its local verification did not cover that required real-connection file. That candidate is blocked for merge.

The corrected required real-connection file list, including `composition_snapshot_concurrency_test.exs`, passed twice locally: 26 tests and zero failures in each repetition. The complete local check passed three properties and 1,723 tests with zero failures. The final full-check command was `devcore-project run test -- env ERL_FLAGS='+S 8:8' mix check`. An earlier default-scheduler attempt failed the unchanged HTTP two-second elapsed-time assertion; that attempt was stopped and the complete check rerun with eight schedulers. No assertion, timeout or required check was weakened.

Correction criteria are: deterministic Order serialization with immutable identities and independent-source cleanup; snapshot-suite registration in both required CI repetitions; payment-occurrence and future format-compatibility clarification; passing local checks; and a pushed candidate with passing exact-head CI. CI and independent review must reassess the new head. Local success does not certify merge readiness.

The correction also passed `devcore-project run test -- env ERL_FLAGS='+S 8:8' mix check.types`, `devcore-project run test -- env MIX_ENV=test ERL_FLAGS='+S 8:8' mix ash_postgres.generate_migrations --check`, and `git diff --check`.

Correction assessment: BUG_FIX, author self-assessment. Four of five criteria have local evidence; pushed exact-head CI remains unverified until the new run completes. Verification Status: PARTIALLY_VERIFIED. Implementation Score: 7/10, comprising requirements 3.5/4, verification 1.5/3, correctness/risk 1.5/2 and handoff 0.5/1. Confidence Score: 90%, based on deterministic lock observations and repeated full-gate tests; runner behavior remains unverified. The gap to 8/10 is passing exact-head required CI and independent review, with no points awarded for pending checks. Merge readiness remains NOT_VERIFIED_FOR_MERGE. No production execution behavior, provider operation or Linear state was changed by this correction.
