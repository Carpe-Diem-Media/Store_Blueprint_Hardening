# JC-290 payment-method race design

## Goal and baseline

Prevent a payment-method replacement or revocation that wins before a new provider request from allowing a stale method to start that request. Preserve the same RenewalAttempt, exact in-flight payment evidence, terminal revocation, and versioned Subscription binding.

The user authorized the existing Linear queue, subagents, and one stacked PR per ticket. This layer follows JC-255 at `6001f015ff3cc19d47ca123e6c0273a688c9ab91`, PR #215, which follows JC-360, PR #214. Canonical main remains `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. JC-228, JC-229, JC-231, and JC-253 are Done and their concrete implementations exist on main. Current AGENTS supersedes historical admission and branch-pin process notes.

## Observed defect and authority

RenewalCollectionAttempts validates the active method under row locks and commits a `may_have_been_reached` dispatch claim. The facade subsequently calls the provider with the captured method references after those locks have ended. A method writer can commit in that interval.

The accepted cross-domain amendment defines the claim as uncertainty evidence before provider I/O. It explicitly leaves method races to JC-290. A claim is not proof of provider contact. Tests must observe actual request initiation through the adapter stub and cover the interval after claim commit. A second read immediately before the call still leaves a check-to-send race.

Keep HTTP after the claim transaction commits. Do not use Redis, ETS, a GenServer, a global provider lock, or an open row-lock transaction around HTTP. Preserve existing provider replay capability and finality contracts. Checkpoint D remains the authority for financial outcomes.

## Shared database gate

Use one small Subscriptions helper with PostgreSQL advisory locks and the existing Repo checkout. Add no service, dependency, table, or schema migration.

The lock order is binding key, method identity key, then ordinary row locks. A binding key contains the raw user UUID bytes and provider. A method identity key contains provider, provider customer reference, and provider payment-method reference, matching the existing global identity. Hash versioned, length-delimited bytes to a PostgreSQL advisory-lock key. UUID hashing uses binary UUIDs. These keys coordinate execution; PostgreSQL rows remain authority.

A charge dispatcher checks out one Repo connection, acquires session locks in that order, resolves the current Subscription binding and method identity, and revalidates them. A replay must also match that identity to the PaymentIntent's captured references. The existing short claim transaction runs on that same checked-out connection and commits before provider I/O. Keep the session gates through initiation of the first provider request. Release them before financial response application and subsequent settlement transactions where practical.

Resource mutations take compatible transaction-level advisory locks before any conflicting row mutation. Every StoredPaymentMethod create/upsert and mark-active/inactive/revoked action participates. Subscription `set_provider_billing_reference` participates, including direct resource callers. The payment-method success facade takes the binding gate before upserting the method, so the later binding update is reentrant rather than reversing the order.

StoredPaymentMethod updates use their persisted immutable owner and identity. A create/upsert must not acquire a gate solely from an unverified input owner and then mutate an identity owned by another user. Under the method identity gate, reject a cross-owner collision without changing the existing row. Preserve all same-owner nonterminal transitions and revoked-row upsert protections. This is required to keep ownership and lock order consistent.

The helper must fail closed outside the required checkout/transaction context. Bound acquisition and connection timeouts prevent indefinite waits. Session locks require explicit cleanup on success, ordinary exceptions, and timeout. If cleanup cannot prove release, discard that exact database session before returning it to the pool. Do not disconnect unrelated sessions. Worker death must release its checked-out database session and locks; prove that behavior with separate real connections.

## Winner and recovery behavior

If replacement wins the gate first, dispatch reads the new current binding, validates it, and uses it for the same RenewalAttempt. Replacing a method does not revoke the old identity globally. If revocation wins first, a fresh provider request must not start with that identity.

If dispatch wins first, writers cannot commit conflicting mutations before request initiation. A later replacement or revocation cannot erase the exact request, PaymentIntent, collection, or financial outcome. Keep the durable claim when contact is possible. Local errors, connection loss, or process death must not manufacture non-submission, terminal provider failure, a new renewal occurrence, or permission for another financial mutation.

Acquire gates before a fresh claim so a method change cannot leave a newly claimed but locally unsent request solely because it changed during an unlocked interval. Existing reached-request reconciliation retains its exact PaymentIntent, collection, and provider evidence. Every outbound charge request, including an exact-reference replay, must hold the authority gates and match the current active method to the captured request identity. A committed uncertainty claim can precede the first actual request. If replacement or revocation wins during a crashed dispatcher's gap, observe the old request without sending another POST. Unsupported observation leaves the outcome unresolved. Never substitute a replacement method, reset the claim, or manufacture terminal non-success. This applies the accepted amendment's current-method rule before every dispatch and preserves checkpoint-D truth.

Use a test telemetry seam after claim commit and before adapter invocation. It carries source, attempt, collection, and PaymentIntent IDs, with no provider secrets. The seam is observation only and does not grant dispatch authority. A connection failure observed before invocation fails closed. Once invocation starts, retain uncertainty and reconcile through existing financial evidence. Do not claim atomic remote receipt or provider finality from a local lock.

## Proof and limits

Use separate PostgreSQL backend sessions and explicit barriers for both winners. Show actual `pg_blocking_pids` dependencies and matching advisory locks, not sleeps or task non-completion. Cover replacement and revocation before initiation, dispatch-first blocked writers, stale binding CAS loss, every method mutation action including upserts, cross-owner reuse, the same RenewalAttempt across replacement, and no implicit global revoke.

After request initiation, prove verified success and terminal non-success use exact checkpoint-D evidence despite later method changes. Preserve other subscriptions and unrelated provider methods. Verify no duplicate request or renewal occurrence from replay, exhausted retry, or a crashed dispatcher.

Run bounded cleanup tests for success, callback exception, lock timeout, connection loss, worker death, and connection reuse. Prove the claim is committed on another connection while the provider seam is paused, and that no database transaction remains open during HTTP. Measure query counts, lock waits, checkout duration, pool occupancy, memory/mailbox state, and cleanup over at least two equivalent bounded repetitions. Treat capacity, remote receipt ordering, and unmeasured fault behavior as unproven.

The gate adds a checked-out connection across network initiation and may retain it until a synchronous request returns. This is a hot-path cost. Keep its scope narrow, use existing provider timeouts, and report the observed limits. Do not compensate with a new pool or an unmeasured pool-size change.

References: [PostgreSQL 18 advisory-lock semantics](https://www.postgresql.org/docs/18/explicit-locking.html), [Ash 3.37.2 changeset hooks](https://ash-project.github.io/ash/Ash.Changeset.html), and the accepted repository cross-domain amendment.

## Recovery-path review

A separate read-only review confirmed two additional paths in this ticket. Both the due path and not-due reached-collection recovery can submit an exact-reference replay. Gating only `not_started` collections leaves the first-request race open after a worker dies between claim commit and request initiation. Also, the due path checks current chargeability before loading a reached collection, so a revoked current method can prevent read-only financial reconciliation. Keep the fresh missing-method behavior, but permit exact reached-request observation without requiring an active method. Every POST still requires current matching method authority. The accepted amendment defines both uncertainty-before-bytes and the before-every-dispatch method rule; this correction does not invent provider finality.
