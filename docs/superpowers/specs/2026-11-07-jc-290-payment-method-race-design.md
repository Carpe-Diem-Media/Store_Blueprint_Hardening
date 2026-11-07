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

## Implemented behavior and proof

The facade now takes the shared gates before a fresh claim, confirms the owned session immediately before charge invocation, and applies the response after gate release. Both generic POST paths use that protocol. The due missing-method fallback observes only a reached claim belonging to the same renewal occurrence. It returns lookup failures and other-occurrence ambiguity without converting them into missing-method dunning.

Every installed adapter currently disables or omits `supports_same_request_replay?`. Recovery therefore observes the exact captured request. Request-reference observation without a provider payment ID remains unsupported for Stripe and leaves the claim unresolved. The generic replay POST branch is guarded for a future certified capability, but dynamic execution of that branch is UNMEASURED under current adapters. No capability or provider contract changed.

The final real-connection race module has 18 cases. It covers both winners for replacement and revocation, exact success and terminal non-success after a later mutation, unchanged request/occurrence identities, all seven direct method insert/upsert/status variants, stale binding CAS, unrelated customer progress, due/not-due crash recovery and owned-session loss. Its committed-claim barrier sees both exact advisory keys and a nil physical `xact_start`. Twelve separate session cleanup cases cover success, callback/resolver errors, busy gates, owner death, connection loss, inherited checkout deadlines and connection reuse. The four required connection modules passed together twice, 41 tests per run, at `75f34cf6e8ad1eeda5f16429fe8b6408746a9a34`.

Verified terminal non-success may authorize a later collection under the same RenewalAttempt according to its existing retry schedule. The no-duplicate recovery proof runs before `next_retry_at`; it does not suppress an eligible business retry. Replacement preserves the old method globally and does not create a new RenewalAttempt.

## Performance & Scaling Review

Renewal dispatch is hot work backed by PostgreSQL authority. Two equivalent single-customer, one-line, stubbed processing renewals at `75f34cf6e8ad1eeda5f16429fe8b6408746a9a34` each executed 70 queries, including one diagnostic `pg_backend_pid` SELECT. Their wall times were 161.380 and 34.716 ms. Process-local Erlang call/return tracing measured the complete Repo checkout at 39.119 and 10.380 ms. The first session-lock query through the final unlock took 38.616 and 10.001 ms. These are diagnostic samples, not percentiles or production latency evidence.

Exact unresolved observation repeated on those same occurrences executed 36 queries in 24.330 and 21.983 ms, without a dispatch session checkout. Two real blocked-writer probes confirmed `pg_blocking_pids` ownership. Their two advisory transaction queries together took 1.375 and 3.866 ms, including database wait and round-trip time; complete method updates took 4.044 and 7.103 ms. The holder was released after observed blocking, without a fixed artificial wait.

Current Subscription/method lookups use primary-key identities. Cross-owner upsert validation uses the existing unique provider/customer/method index. No index or schema change is required for these query shapes. The new dispatch work performs fixed per-dispatch reads, with no new collection traversal. Large histories, multi-item query growth and production query plans remain UNMEASURED. No ETS/Redis authority cache or invalidation path was added. Existing Oban uniqueness, durable claim CAS, provider request identities and outcome certification remain responsible for duplicate work and financial idempotency. Telemetry events carry internal IDs only.

## Runtime Resource Safety Review

The existing four-connection pool had four ready connections before and after each measured operation, and three during the synchronous charge call. Its checkout queue stayed at zero in these bounded samples. The dispatcher holds one existing connection through the provider call, outside a database transaction. Acquisition uses nonblocking session locks and one-second queries; cooperating mutation queries have a five-second timeout. The checkout deadline is 60 seconds. It bounds database ownership, not the lifetime of HTTP work after a connection disconnects or remote receipt ordering.

After GC, the measured process retained 55,968 bytes after each fresh/observation pair, and its mailbox stayed at zero. Fixture confirmation emails were consumed before measurement; no dispatch messages were discarded. Both exact advisory key counts returned to zero after every operation. Probe telemetry handlers and the process-local tracer were removed. The helper adds no process, pool, timer, cache, dynamic atom or durable queue. Unknown lock acquisition/release kills only the checkout owner; tests prove the recorded session disappears and the keys can be acquired independently afterward.

These results establish the tested local cleanup behavior. Production capacity, sustained queue pressure, node RSS/allocator convergence, multiple nodes, provider/network failure windows after proof confirmation and unknown acquisition-acknowledgement faults remain UNMEASURED. The current tests do not claim atomicity between PostgreSQL and a remote provider.

## Existing validation alignment

The required full suite exposed fixture assumptions that the new guards reject. Default provider customer references now include the complete user UUID, so users created under the same UUIDv7 timestamp prefix do not share a synthetic global method identity. The committed NON_EFFECTIVE fixture runs renewal orchestration outside its outer setup transaction. Its ordinary resource actions still own their transactions.

Older logical late-failure tests shared one Sandbox connection and paused HTTP while the parent queried that same checked-out connection. Their barriers now pause after provider response and gate release, immediately before checkpoint-D application. They retain the same financial precedence assertions. The separate real-connection modules remain the physical contention and committed-claim proof.

The contract-snapshot test's unrelated update now changes billing-status metadata while retaining a consistent method binding. It still proves aggregate-version movement does not consume or replace the queued commercial target. Query budgets retain their prior workload allowances plus ten fixed dispatch statements. The terminal-failure measurement observed 121 statements at the JC-255 base and 131 with JC-290. It independently counts the six session-management statements; the remaining four statements are the two current Subscription/method reads before and after acquiring the exact method gate. These costs are explicit, rather than an unbounded allowance or a skipped performance check.

## JC-290 topology correction

The application now treats `database_pool_mode` as an operator assertion sourced from `STORE_DB_POOL_MODE`. Renewal dispatch rejects every value except `"session"` before checkout. The rejection path performs one application-config read and no database query. Tests that reject unsupported modes on direct PostgreSQL prove this guard only. They do not certify behavior through a runtime PgBouncer deployment or establish transaction-pool safety.

The earlier transaction-proxy cleanup claims are invalid. The measured and real-connection tests used direct PostgreSQL connections, so they did not exercise connection reassignment by PgBouncer in transaction mode. The pool-mode guard corrects only this immediate unsupported-mode behavior. Loss of database authority during HTTP, loss of completed provider evidence during cleanup, setup-operation replay, and queue saturation remain open. Both pending owner decisions about provider fencing and overlapping setup operations remain open. PR #216 remains on hold. This correction makes no capacity claim.
