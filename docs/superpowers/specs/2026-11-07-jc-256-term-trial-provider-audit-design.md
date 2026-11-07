# JC-256 term, trial and provider audit

JC-256 requests a structured audit. It does not authorize production fixes, new trial rules, provider-managed enablement or live provider calls. Linear is the execution tracker. JC-219 and JC-220 are Done and their concrete prerequisites are accepted on canonical main `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`.

The human requested stacked review. This branch starts at JC-248 head `87348afd9f565a31fb5fb0d279c611e8275c3a7b` and its PR will target `jc-248-entitlement-reconciliation`. Each ticket remains a separate draft PR for human review and merge.

## Audit boundaries

Classify each feature as `PROVEN_GOOD`, `EXPLICITLY_UNSUPPORTED / feature-disabled`, `CANDIDATE`, or `INCONCLUSIVE`. Cite deterministic tests and current code. An accepted schema value alone proves no executable behavior.

Preserve immutable PlanRevision ownership of commercial fields. Inspect creation and activation, paid-cycle evidence, last charge and access, term completion, renewal suppression, cancellation, dunning, contract changes, and local versus provider authority. Identify missing Product or provider decisions explicitly. Do not infer completed cycles from worker or attempt counts.

The existing issue already records three candidate findings. Refresh their evidence and search the queue before creating separate findings. Route genuine defects to their existing owner where one exists. Candidate findings do not authorize their implementation.

## Work sequence

1. Add a bounded publication and pure Scheduler characterization matrix. Vary `until_canceled`, fixed cycles 1 and 3, fixed-end instants before, equal to and after a fixed reference, and trial days 0 and 14. Assert persistence and period calculations only.
2. Inspect and add focused sale, paid activation and due-renewal proofs where existing test helpers support them. Test provider-mode selection with isolated, restored test flags and existing local provider doubles. Plan the exact fixture ownership and cleanup before committed writes. Keep ambiguous cycle-count or in-flight fixed-end precedence inconclusive.
3. Write a durable audit matrix with executable verdicts, evidence limits, lifecycle interactions and candidate owners. Record unresolved delivery work in Linear. Leave production behavior unchanged.

Task 1 has a complete implementation plan. Later task plans will use the observed results and actual APIs rather than speculative code. Each implementation task gets a fresh worker, a specification review, then a quality review.

## Validation

Use the existing DevCore test environment and isolated `_t3_132f19be_hardening` database suffix. Run one Mix process at a time with the established four-scheduler and four-connection limits. Characterization tests can pass immediately; do not manufacture a failing test or alter production code to force an audit result.

Run focused tests, formatting, warnings-as-errors compilation and strict Credo for each task. Before publication, inspect the entire ticket diff, run the repository's required checks, review the exact final head and inspect its CI when available. No capacity, resource convergence or end-to-end provider claims follow from these bounded tests.

## Design self-review

The audit separates observation from commercial law and production fixes. The first task uses ordinary rollback fixtures. Committed renewal tests require their own explicit cleanup plan because payment-method authority uses a separate physical connection. No new infrastructure, provider adapter, production test seam, migration or UI change is needed.
