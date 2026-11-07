# JC-256 term, trial and provider audit

JC-256 is an audit. Production code, commercial rules and deployed provider flags are unchanged. The audit is not PROVEN_GOOD overall. Its three confirmed gaps have separate candidates, and their fixes require their own implementation decisions and PRs.

The candidate rows below record `PROVEN_GAP` evidence. `CANDIDATE` is their follow-up status, not a safety verdict. Missing commercial and provider decisions remain `INCONCLUSIVE`.

The branch originally stacked on JC-248 head `e1f23d179560cffb073b750b08d1a684a2bb87c5` and now incorporates corrected parent `d3900b1670427696ec4c45bae37f7be6e1151903` append-only. Amendment `bccbc034a45a6f9d1cdbed2fdd908e22a838821d` remains identifiable. JC-219 and JC-220 are accepted on canonical main `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. Historical readiness labels do not change the current repository workflow.

## Executable verdicts

| Feature | Verdict | Evidence and owner |
| --- | --- | --- |
| `until_canceled`, ordinary paid schedule | `PROVEN_GOOD` for the audited cadence and activation behavior | The configuration has no finite cutoff. Scheduler and paid activation use the ordinary period boundaries. Existing cancellation and dunning tests cover their separate mechanisms; comprehensive certification remains JC-263. |
| `fixed_cycles` | `CANDIDATE` | Limits 1 and 3 allow 2 and 4 paid period extensions in explicitly synthetic legacy possible-contact scenarios. Fresh occurrences stop with `RENEWAL_DISPATCH_UNAVAILABLE` before provider contact. JC-362 owns enforcement and true expiry. |
| `fixed_end_at` | `CANDIDATE` | With no prior renewal occurrence, fresh processing before, at and after the June 1 start boundary creates an unclaimed collection but stops before provider contact. The charged period snapshot ends June 2; no extension is reconciled in these cases. JC-362 owns the missing cutoff guard and terminal source. |
| `trial_days > 0` | `CANDIDATE` | Positive trial values can become effective and sellable, but no executable trial lifecycle was found. JC-363 owns support or explicit gating. |
| Provider-managed billing | `CANDIDATE` | The isolated flag can select a mode without a provider subscription ID. Fresh collection stops before provider contact; the test only resolves an explicitly synthetic legacy possible-contact collection. JC-364 owns the gate and orchestration decision. |

The repository defaults provider-managed selection to false. With that flag false, Stripe can still select merchant-managed fallback. Yoco's unsupported capabilities reject activation even with the isolated flag true. These negative checks do not certify provider-managed behavior for any provider. Deployed provider configuration and real provider accounts were not inspected.

## Deterministic evidence

The [configuration module](../../test/store/subscriptions/jc256_contract_configuration_audit_test.exs) passed 2 tests. Each test covers six term configurations with trial days 0 and 14. Publication retains the configured immutable fields. Pure initial and next-period calculations stay unchanged when only term and trial fields vary. The fixed reference is June 1, 2026 in UTC.

The [sale and activation module](../../test/store/subscriptions/jc256_sale_activation_audit_test.exs) contains 5 tests. Real cart and checkout finalization accept a 14-day trial with a past fixed end, freeze the exact revision and retain a 1,999-minor-unit line price. Eight paid activation combinations bind that revision, create an ACTIVE Subscription and apply its initial AccessEffect. Separate cases cover Stripe mode selection, unsupported-provider rejection and financially consistent purchase-to-activation replay. Test flags restore their exact previous application environment values.

The Stripe activation fixtures build the sale through the public cart, checkout and payment APIs. A local Stripe double supplies success evidence for the exact stored provider reference, amount, currency and PaymentIntent identity. The real payment evidence/application path marks the finalized Order paid and creates its PaymentApplication. Before activation, the tests require matching nonzero Order, line and PaymentIntent amounts, matching currencies and the exact PaymentApplication. The regression test also requires activation replay to retain one Subscription, initial AccessEffect and PaymentApplication.

Provider setup and observation use local HTTP doubles. This proves Store's financial consistency and activation response to simulated success; it does not prove live provider collection, external settlement, real initial collection timing or a complete provider integration. Activation itself makes no additional provider call. The activation cases use an empty entitlement pair, so they do not prove trial access.

The shared `create_paid_order_with_subscription_line!/4` helper remains unchanged because other suites consume it. It finalizes and marks an Order paid with zero totals, then inserts a nonzero line and separately succeeded PaymentIntent without a PaymentApplication. That manufactured initial purchase history remains in the explicitly synthetic Yoco rejection control and the renewal source fixtures. Those cases do not establish a financially valid initial purchase-to-renewal sequence. Each new renewal separately prepares a pending nonzero Order and unclaimed PaymentIntent. The legacy recovery fixture adds possible-contact state, then the normal observation and payment-application path applies exact-ID simulated success for that renewal. Yoco has no implemented checkout/observation path with which to make the same positive purchase proof.

The [renewal module](../../test/store/subscriptions/jc256_renewal_term_audit_test.exs) retains all three renewal cases. Each fresh occurrence runs under an unexpected-HTTP guard and must return `RENEWAL_DISPATCH_UNAVAILABLE` with reason `provider_revocation_fencing_unsupported`. The test checks its one new attempt, pending nonzero Order, unclaimed collection, created PaymentIntent, absent provider identity, no reservation, no PaymentApplication and unchanged business dunning state. The PaymentIntent is resolved through `RenewalCollectionAttempts.payment_intent_key/1` because the collection has no claimed PaymentIntent ID yet.

To preserve term-gap evidence, each case then labels a separate scenario `synthetic_legacy_possible_contact`. The existing helper rechecks that fresh dispatch is rejected and seeds historical possible-contact state with an exact provider identity, without supplying an outcome. An exact-ID GET returns canonical simulated success, and the actual facade observation path records financial evidence and creates one local PaymentApplication. The tests use the real nonzero Order amount and currency and check exact attempt, collection, PaymentIntent and Order relationships. This simulated observation does not establish a live charge or provider settlement.

Fixed-end fixtures use daily cadence and cutoffs one second before, equal to and one second after the June 1 renewal start boundary. Each charged snapshot ends June 2. They retain that snapshot and do not reconcile a period extension. Fixed-cycle limits 1 and 3 retain 2 and 4 counted paid extensions. Each extension is a new occurrence after the preceding synthetic legacy occurrence has been paid through the observation path and explicitly reconciled; assertions require a verified-success collection, succeeded PaymentIntent, exact success handoff, one PaymentApplication and persisted period growth. The tests do not count attempts as cycles or decide whether the initial paid period consumes a cycle. The provider-managed case proves only fresh rejection and the labeled legacy recovery path. It does not prove fresh merchant dispatch or provider-managed orchestration.

Fixture construction commits atomically, then registers cleanup before assertions or provider calls. Runtime calls and reads use unboxed Repo connections. Cleanup deletes exact fixture owners, clears the exact user cache key and restores the collection guard within its cleanup transaction. No live provider calls, extra collector processes, database resets or global cache resets are used. The final PR records repository-wide checks and CI for its exact head.

## Parent integration validation

The unmodified audit first ran against the corrected parent with ten tests and three expected fresh-dispatch failures. The migrated audit passed all ten tests. Full `mix check` then passed three properties and 1,666 tests with zero failures and 27 excluded connection cases. Types and TEST migration alignment passed without ignore changes. The four required connection modules passed 21 tests twice; the other six affected connection cases passed separately. The type check retained 144 filtered findings and two unnecessary skips. Existing documentation and migration-test warnings remain.

Independent local spec and quality reviews approved the audit delta. A later equivalent empty-list assertion received separate rechecks after strict Credo identified it; the corrected full check passed with no Credo issues. All nine relative report links resolve, and six added-line credential-pattern checks found no matches. Fresh publication CI and independent external re-verification remain pending. These local results do not approve merge or certify the open production candidates.

## Immutable contract ownership

[PlanRevision](../../lib/store/subscriptions/plan_revision.ex) owns `term_mode`, `term_cycles`, `term_end_at` and `trial_days` in its immutable commercial field set. New-sale OrderLineItems freeze its ID. Paid activation binds that revision. At renewal checkpoint B, the [facade](../../lib/store/subscriptions/facade.ex) serializes the fields into the immutable charged-contract snapshot.

Modeling and serialization do not execute the fields. [Scheduler](../../lib/store/subscriptions/scheduler.ex) uses cadence, anchor and timezone inputs without a trial or term cutoff. Renewal processing has no term-completion guard. The Subscription resource declares true `mark_expired_transition`, but the source search found no production caller. Retry-budget exhaustion leaves the Subscription `PAST_DUE`, suppresses retries and clears `next_retry_at`. Reaching the separately stored `failed_payment_boundary_at` produces recoverable `SUSPENDED`. Fixed-term completion requires a separate terminal `EXPIRED` outcome; neither retry exhaustion nor the failed-payment boundary supplies that missing term producer.

## Lifecycle interactions and unresolved decisions

Fixed terms currently have no enforced final-charge boundary, completed-cycle position, true terminal-expiry producer or corresponding term-end access consequence. The fixed-end proof starts without an in-flight B occurrence and therefore avoids inventing its ordering against a later cutoff. JC-362 must resolve historical term progress, initial-cycle treatment, contract changes, last access, final-cycle failure and dunning, then compose with JC-234's paid-versus-expiry race. Cancellation remains its existing separate instruction; its success does not prove term completion.

Trial start/end, payment-method requirements, initial collection timing, access during trial, cancellation, conversion success/failure, dunning, term consumption and queued changes are `INCONCLUSIVE` without a trial contract. The confirmed defect is admitting commercially meaningful positive trial data without executing or explicitly rejecting it. JC-363 must choose support or gating and define treatment of historical purchased revisions. This audit creates no default free trial or Product policy.

Provider-managed creation/idempotency, provider ID binding, schedule and price ownership, event reconciliation, missing or reordered events, cancellation/rescission, failure states, terms, trials and changes are `INCONCLUSIVE`. The current implementation uses local Scheduler, bound renewal and merchant collection authority. A provider-managed label does not transfer that authority. JC-364 must prevent conflicting collection ownership and define any real supported mode. JC-284 retains the external Paystack validation gate; this audit selects no Paystack mechanism.

Ordinary cancellation, same-renewal recovery, dunning and purchased access policy have dedicated accepted tests, including [cancellation authority](../../test/store/subscriptions/cancellation_renewal_authority_test.exs), [dunning boundaries](../../test/store/subscriptions/sbh_30_05_dunning_adversarial_boundary_test.exs) and [charged-contract reconciliation](../../test/store/subscriptions/sbh_10_05_charged_contract_reconciliation_test.exs). Their coverage does not establish the missing fixed-term or trial-specific interactions. Exhaustive cross-mechanism failure certification remains JC-263.

## Candidate records

- [JC-362](https://linear.app/jc-dev/issue/JC-362/candidate-enforce-immutable-fixed-terms-before-renewal-and-true-expiry) records immutable fixed-term enforcement and true expiry. JC-234 remains the separate expiry-race owner. Promotion-cycle consumption in JC-270 is a separate mechanism.
- [JC-363](https://linear.app/jc-dev/issue/JC-363/candidate-gate-unsupported-positive-trial-contracts-or-define-trial) records positive-trial gating or a defined trial lifecycle.
- [JC-364](https://linear.app/jc-dev/issue/JC-364/candidate-gate-provider-managed-mode-on-implemented-orchestration) records provider-managed gating and orchestration, with JC-284 as the Paystack gate.

The project queue was searched before these candidates were created. They remain Backlog candidates. No production fixes are included in this audit, and none of the findings silently changes another issue's scope.

## Performance & Scaling Review

This PR adds tests and documentation. Production query counts, indexes, caching, queues, uniqueness and telemetry are unchanged. The bounded renewal tests exercise existing hot paths and use exact owned cleanup. They do not measure throughput or capacity.

## Runtime Resource Safety Review

`NOT_APPLICABLE` to production behavior because this PR changes no runtime code. Test cleanup covers committed fixture ownership, the collection trigger and user cache keys. Memory, GC, mailbox, multi-node behavior, post-load convergence and production capacity are `UNMEASURED`; these tests make no resource-safety certification.
