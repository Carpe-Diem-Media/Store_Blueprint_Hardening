# JC-290 payment-method race design

## Contract and baseline

The owner requires a revocation committed before provider checkpoint C to prevent stale submission. No installed provider implements a fence that can establish this ordering. The owner chose rejection of unsupported fresh off-session dispatch. A database session, idempotency key, adapter capability flag or second authority read cannot supply the missing provider guarantee.

The owner also chose setup-start supersession. Starting B makes an older setup A obsolete even when B later fails. The current binding remains until a current setup succeeds or another authorized binding action changes it.

This stacked layer originally followed JC-255 at `6001f015ff3cc19d47ca123e6c0273a688c9ab91`, PR #215, above JC-360, PR #214. The parent correction and descendant propagation require separate exact-head validation. PR #216 remains a draft on hold. No merge is authorized.

## Unsupported fresh dispatch

The renewal facade returns registered infrastructure error `RENEWAL_DISPATCH_UNAVAILABLE`, with reason `provider_revocation_fencing_unsupported`, when an unreached collection reaches dispatch. No installed provider, database mode, environment switch or test capability can enable a charge POST. Existing contract, provider-configuration and missing-method checks can reject preparation earlier with their existing errors and dunning rules. Adding a provider later requires an implemented and reviewed provider-side fencing contract.

Local preparation may bind one immutable RenewalAttempt, prepare its priced Order, and create one unresolved collection and PaymentIntent. It does not capture method references, attach a provider-contact claim or reserve new physical stock. Repeated ticks retain those identities and do not advance business dunning, the billing period or financial state. The facade uses collection start without automatic reservation assignment or fence resumption.

An older `not_started` collection may already own a physical reservation. The existing typed pre-submission fence locks and rechecks its exact epoch and state, releases that exact generation, and records `not_submitted`. Later unsupported ticks retain that fence without creating another generation. A collection that may have reached the provider must never enter this cleanup path. A cleanup failure remains an infrastructure failure and cannot become a customer decline or evidence of non-submission.

The session advisory-lock holder, confirmation proof, session cleanup kills, and both fresh and replay charge POST branches are removed from renewal orchestration. `STORE_DB_POOL_MODE` still configures repository compatibility, including `prepare: :unnamed` for transaction pooling. It grants no dispatch authority.

The renewal worker cancels a deterministic unsupported-dispatch job and records the error. Cancelled jobs remain part of that worker's occurrence uniqueness so later sweeps cannot recreate the same futile work. The source's period and business dunning stay unchanged. A `cleanup_failure` or `preflight_failure` instead keeps the job retryable so transient infrastructure faults can recover. After a future provider implementation supplies reviewed fencing support, an operator must explicitly retry or requeue previously cancelled occurrences. Cancellation of a worker job is not cancellation of its Subscription or evidence of a financial outcome.

## Existing collection recovery

A durable `may_have_been_reached` claim records uncertainty. It does not prove that any bytes left the process. Recovery retains the exact collection, PaymentIntent, provider payment ID, request reference and physical reservation generation. Payment-method replacement or revocation does not erase financial evidence or authorize a replacement charge.

Stripe observation uses the stored exact provider payment ID. The normal observation and checkpoint-D application path certifies success or terminal non-success. A request reference alone cannot be observed by the current Stripe adapter, so that collection remains unresolved. No timeout, lost database connection or process death may convert this uncertainty into a decline, a fresh POST or a new financial collection.

Observation can proceed after the captured method is replaced or revoked. Verified success still pays the exact Order and produces its PaymentApplication once. Existing authentication-required settlement and paid-renewal reconciliation retain their lifecycle responsibilities. A narrow observation-ready telemetry event can pause after observation and before application for financial precedence tests. It carries internal identifiers and supplies no financial authority itself.

## Transaction writer locks

Short transaction advisory locks still serialize cooperating Subscription binding and StoredPaymentMethod writers. Their order is binding key, method identity key, then row locks. The binding key hashes raw user UUID bytes and provider; the method key hashes versioned, length-delimited provider, customer and method references. UUID ordering and hashing use binary identities. PostgreSQL rows remain authoritative.

Every declared StoredPaymentMethod create, upsert and status action acquires its transaction gates. Direct Subscription binding actions acquire the binding gate and retain aggregate-version compare-and-swap. Cross-owner identity reuse fails without mutating the existing method. Replacement leaves the old method globally active; revocation remains terminal. These locks belong to each writer's actual Repo transaction. They are not moved to DirectRepo or held during renewal HTTP.

Physical tests use separate backend PIDs and `pg_blocking_pids` to show direct resource actions wait on the expected transaction holder. Commit, rollback and owner death release transaction locks. These direct PostgreSQL tests do not certify a running PgBouncer deployment, mixed-version writers, failover or cross-node behavior.

## Test evidence and migration

Tests that require a pre-existing collection use an explicitly synthetic legacy possible-contact fixture. The fixture prepares real local records, assigns a real physical generation where required, and uses the typed claim operation to establish uncertainty. It creates no financial receipt. A separate canonical exact-ID observation supplies the amount, currency, customer, method and immutable local identifiers before any financial outcome assertion.

Existing lifecycle, cancellation, dunning and stale-write tests must retain their invariants while replacing fresh POST setup. No shared default fixture or adapter may silently authorize dispatch or fabricate success. Historical POST barriers become observation or lifecycle barriers where those are the operation under test.

Focused unsupported-dispatch tests first failed against the prior session-held POST implementation. Further regressions reproduced fresh stock allocation, skipped legacy cleanup after method withdrawal, and a retryable Oban job for deterministic rejection. The corrected focused modules passed 21 tests with zero failures and no test warnings. They cover no new reservation, one exact legacy fence without generation churn, retention of reached uncertainty, actual job cancellation and repeated-sweep uniqueness. The two JC-290 connection modules passed six tests twice. Static checks, types and migration alignment passed locally. The four required connection modules still have two old access-recovery fixtures to migrate. Final full-suite and exact-head CI evidence remains pending until the lifecycle test migration finishes.

## Performance & Scaling Review

Renewal preparation and exact collection observation are hot paths. The writer gates use existing primary-key and provider/customer/method indexes. This correction adds no cache, pool or service. No ETS or Redis invalidation or stampede protection is required. Existing Oban uniqueness, immutable collection request keys and checkpoint-D certification still govern replay and financial idempotency.

Production subscriptions concurrency remains `min(4, POOL_SIZE - 2)` per node, with `POOL_SIZE >= 3`. A positive `STORE_SUBSCRIPTIONS_QUEUE_LIMIT` override cannot exceed `POOL_SIZE - 2`. Other queue limits remain unchanged. This bound reserves potential primary-pool headroom; it does not certify production capacity.

Two equivalent bounded local samples of one nonphysical line each observed 36 current-process primary queries for first preparation, nine for repeated unsupported preparation, and 38 for exact-ID processing observation. First-preparation wall times were 106.218 and 17.210 ms; repeated preparation took 5.484 and 3.774 ms; observation took 51.754 and 16.497 ms. The provider GET used a stub and the result remained unresolved. `RepoStats.capture/1` counts only the calling process, so these are diagnostic query samples rather than whole-system or capacity measurements. The probe passed one test with two repetitions. Physical shipping, larger histories, N+1 behavior under larger workloads, asynchronous child queries, production query plans and latency distributions remain UNMEASURED. Telemetry contains internal identifiers and no provider secrets.

## Runtime Resource Safety Review

Renewal orchestration no longer owns a database session or session advisory locks across provider HTTP. Short writer transactions retain their existing bounded lock query timeout. Unsupported preparation must hold no new inventory generation, and repeated ticks must not resume fenced stock. Reached uncertainty retains its exact reservation for the established financial recovery rules.

No new process, timer, dynamic atom, cache or pool is introduced. The physical tests check owned task and transaction-lock cleanup. Memory, GC, mailbox growth, allocator convergence, sustained queue pressure, node RSS, failover and cross-node behavior remain UNMEASURED for the final correction. Two equivalent bounded repetitions are required for any claimed local cleanup convergence. No local test establishes remote receipt ordering.

## Historical evidence

Earlier commits implemented session-held renewal HTTP and measured that protocol. Those results are historical and do not certify the corrected runtime. At `75f34cf6e8ad1eeda5f16429fe8b6408746a9a34`, two single-customer renewals each executed 70 queries; the four required real-connection modules passed 41 tests per run. The independent review showed that these tests did not establish transaction-proxy safety or prevent HTTP after authority loss.

The subsequent capacity checkpoint ran two local repetitions with two renewals held in POST stubs and a four-connection pool. An unrelated verified webhook and binding action completed before response release. That workload did not run an Oban producer or real network timeouts. Its HTTP and session-lock tests are removed because the corrected runtime rejects that dispatch. It provides no current provider-latency, fencing or capacity guarantee.

The temporary topology guard allowed only declared session mode. Strict rejection supersedes it. Session mode does not establish provider-side fencing, and the application publication used only by that guard is removed.

## Setup start supersession

Every Subscription now carries an internal, nonnegative `payment_method_setup_generation`, initialized to zero. Starting a setup takes the binding transaction gate, reloads the Subscription, advances its generation and creates the matching PaymentIntent in one transaction. The key `pm-update:v2:<subscription_id>:<generation>` identifies that operation. The transaction commits and sends Ash notifications before the facade calls Stripe. A provider create failure leaves the newer generation in place, so an earlier setup remains obsolete. Setup start rejects calls made inside an existing Repo transaction because a nested transaction cannot establish the required provider-call boundary.

PaymentIntent stores its captured generation and an internal `setup_binding_applied_at` marker. Verified success reloads both records after taking the binding gate. Historical intents without a generation and intents whose generation no longer matches the source record retain their provider success evidence but do not upsert a candidate StoredPaymentMethod, change the binding, or enqueue a retry from that candidate. A current setup updates the method, binding, and marker in one transaction. The binding action advances the Subscription generation; after application it equals the setup generation plus one. Marker failure rolls back both local binding writes while preserving success evidence committed before the callback.

Replaying an applied setup does not write the binding again. It can recover an immediate retry enqueue only while the marker is set, the source generation is exactly one greater than the captured generation, and the source still binds the same provider customer and method references. Starting another setup or writing the binding directly invalidates that recovery condition. The direct binding action retains its aggregate-version compare-and-swap and also advances setup generation. Global StoredPaymentMethod revocation behavior is unchanged.

Callback validation checks the immutable subscription ID, provider and setup purpose before classifying generation. A direct customer and method replacement makes older verified operations successful binding no-ops. Current-customer equality is required only when applying a current, unapplied setup. An authentic obsolete event therefore does not retry merely because the subscription now uses a different provider customer.

The schema addition is additive: existing Subscriptions begin at generation zero, and historical PaymentIntents keep null generation and marker values. There is no historical backfill. The affected setup, revocation and webhook modules passed 50 tests with zero failures. Two equivalent physical concurrent-start runs passed using separate primary PostgreSQL backends. B waited on A's binding gate, both intents and their ordered generations were visible from an independent connection before provider responses, and neither provider caller had an open transaction. The tests cover replay, failed newer provider creation, a newer pending setup, direct binding supersession, historical no-op behavior, marker rollback, retry enqueue recovery and verified webhook handling. Broader final validation remains pending. These tests do not establish production capacity, mixed-version node behavior, failover or production migration duration.
