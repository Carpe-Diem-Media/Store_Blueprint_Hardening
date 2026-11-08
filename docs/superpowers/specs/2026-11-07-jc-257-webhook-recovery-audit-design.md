# JC-257 webhook and recovery audit

JC-257 requests evidence for duplicate and reordered webhooks, durable provider observation, missing events, unknown references and worker replay. It forbids remediation inside the audit. Current Linear prerequisites JC-228, JC-229 and JC-230 are Done and accepted on main. JC-282 and JC-287 are also Done; their current implementations supersede the issue's September descriptions of missing success correction and provider observation.

At design time, the branch started from JC-256 head `484e1bee231865f954cfab036c04aa377c39bc4b`, and its draft PR targeted `jc-256-term-trial-provider-audit` as the sixth ticket layer. Canonical main at audit start was `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. Human review and merge remained required. These are historical design facts. The original independent review pair was `8708e06a7cbb397d4951feeca66acd2c3f426eef` / `484e1bee231865f954cfab036c04aa377c39bc4b`, with addendum head `73e530a84cd2e666c73346b5a6dc6b7516747eda`. The current corrected parent head is `7f231b42a773150749edda7e4b981b3344f901ec`; fresh CI and independent external re-verification remain pending.

## Evidence and scope

Inspect and reuse existing receipt, observation and charged-renewal proofs before adding tests. Distinguish provider occurrence time, observation time and receipt time. Verify the same provider occurrence during missing-webhook recovery; do not issue a replacement collection. Treat unknown provider contracts and true-expiry ordering as inconclusive where their owners still have missing prerequisites.

The remaining paid-consequence finding needs a deterministic failure proof. PaymentApplication commits paid truth before best-effort fulfillment, digital, Subscription and receipt enqueue. Current replay may repair some Subscription work while still skipping other consequences. The audit must report actual current coverage rather than repeat the older claim that every consequence skips replay.

Use an exact order-and-worker scoped test database trigger only if it can force a real enqueue error without corrupting the test transaction. First probe the installed Oban/Ecto behavior in a rollback-only test transaction. A suppressed INSERT that returns a job with no ID is insufficient to prove the error branch. A registered priority constraint violation may produce the needed changeset error; the probe must establish that before a test plan depends on it.

No production test seam, provider adapter, live API call, Redis authority or broad fault injection is allowed. Use the existing DevCore test database and four-connection limits. Diagnostic trigger names and predicates must be unique, ownership bounded and cleanup verified. One Mix process owns the environment at a time.

The rollback probe observed that priority 10 is valid in the current database: Oban V12 replaced the old upper-bound constraint. A second probe set only the matching job's `max_attempts` to zero and obtained an Ecto changeset error for `positive_max_attempts`. Rollback left zero probe functions, triggers and jobs. The test plan will use this observed mechanism. It must state whether Store payment data remains under a test sandbox and avoid claiming process-exit durability from that setup.

## Work sequence

1. Establish the smallest safe Oban enqueue-failure mechanism from installed source and a bounded rollback probe. Write the complete test plan only after observing the actual result.
2. Add focused tests for the paid-commit/consequence gap and any missing current ordering or observation evidence. Use the existing local provider doubles and public domain functions. Every fixture or committed job gets explicit cleanup.
3. Write the durable current-state audit matrix. Reuse JC-282, JC-287, JC-284, JC-234 and JC-259 ownership where applicable. Search before creating a separate concrete paid-consequence candidate. Do not implement the candidate.
4. Run focused and repository-required checks, then review the complete exact-head diff before publishing the draft PR.

Each implementation task gets a fresh worker, specification review and quality review. The final report will classify observed behavior as PROVEN_GOOD, CANDIDATE or INCONCLUSIVE and state its evidence limits. It will not certify an unsupported provider or replace frozen precedence with callback arrival order.
