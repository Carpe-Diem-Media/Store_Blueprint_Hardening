# JC-290 strict renewal dispatch correction plan

> **For agentic workers:** Use subagent-driven-development. Root owns Mix, database, migration and Git commands. Work in the existing checkout with bounded file ownership.

**Goal:** Preserve the owner's strict revocation-before-provider-checkpoint-C guarantee by rejecting renewal POSTs that the installed providers cannot fence.

**Architecture:** Remove the facade's session-held HTTP protocol. Fresh collections stay locally prepared and unclaimed. Reached collections retain exact provider observations and checkpoint-D application. Keep short transaction locks for binding and stored-method mutations.

**Tech stack:** Existing Ash resources, PostgreSQL transaction gates, typed domain inputs, ExUnit and DevCore.

## Authority and limits

The owner explicitly selected strict rejection. Stripe has no implemented provider-side revocation fence. Idempotency, merchant-charge support, replay support, a database session and a stub response do not provide that guarantee. No environment flag or test capability may enable the removed POST path. Supporting a provider later requires an implemented and reviewed fencing contract.

The setup-generation correction is a separate append-only checkpoint on the same issue branch. PR #216 remains a draft on hold. No merge, force push, history rewrite or descendant update belongs to this task.

## Task 1: prove unsupported dispatch, then remove the unsafe protocol

**Files:**

- Create `test/store/subscriptions/jc290_strict_dispatch_test.exs`.
- Modify renewal dispatch and observation helpers in `lib/store/subscriptions/facade.ex`.
- Modify `lib/store/subscriptions/payment_method_authority_gate.ex`.
- Replace obsolete session protocol tests in the existing JC-290 cleanup and race modules, preserving transaction writer coverage.

- [ ] Add a sandbox regression using a normal due Stripe subscription and a provider stub that fails on every HTTP request. Run the public typed due facade twice for each declared database mode, including session and transaction. Assert `RENEWAL_DISPATCH_UNAVAILABLE`, no HTTP, unchanged subscription retry/dunning/period fields, one stable occurrence/order/intent/collection, `not_started`, unresolved financial outcome, and no captured contact claim.
- [ ] Cover a fenced `not_submitted` collection as another unsupported fresh route. It cannot be resumed into a POST by changing only the database mode.
- [ ] Use collection start without reservation assignment or automatic fence resumption. A fresh physical rejection must preserve inventory counters and create no exact renewal generation. Check existing prepared collections before contract, provider or method preflight can divert them into business failure. Fence an assigned `not_started` generation with its exact epoch, retain its released ID as history, and keep later ticks unavailable at the same fence. A failed cleanup remains an infrastructure error. Cover inactive/revoked methods and never release reached uncertainty.
- [ ] Root runs the focused test before production changes. The session-mode baseline must fail because it invokes the POST callback.
- [ ] Replace the submission decision with an explicit hard boundary. Keep dispatch-check telemetry for internal preparation and cancellation tests; it does not represent provider contact.

```elixir
case collection_attempt.dispatch_state do
  :may_have_been_reached ->
    reconcile_existing_renewal_collection(payment_intent, collection_attempt)

  _not_reached ->
    {:error,
     Error.new(
       "RENEWAL_DISPATCH_UNAVAILABLE",
       "provider cannot fence renewal submission against payment-method revocation",
       %{reason: :provider_revocation_fencing_unsupported}
     )}
end
```

- [ ] Preserve authentication-required settlement around reached reconciliation and preserve infrastructure error handling through both run and batch settlement. Unsupported dispatch must not become `PAYMENT_FAILED` or advance business dunning.
- [ ] Cancel deterministic unsupported-dispatch Oban jobs and include cancelled occurrences in the worker's existing uniqueness states. Preserve retries when cleanup or preflight failed. Exercise actual job acknowledgement and repeated sweep uniqueness without changing completed/discarded retry policy. Document explicit operator retry after future reviewed fencing support.
- [ ] Remove the fresh and captured POST call chains and helpers with no remaining caller. Inspect all references before removing shared helpers such as provider reference persistence, which setup start still needs. Remove the renewal charge request and direct response builders only when their complete call graphs are exclusive to the deleted protocol.
- [ ] Remove `with_dispatch_session_gates/4`, `confirm_dispatch_session/1`, proof types, session lock helpers, kill-on-cleanup logic and their timeouts. Retain `binding_key/2`, `method_key/3`, transaction lock helpers, identity ownership checks and Ash writer hooks.
- [ ] Remove the now-unused `:store, :database_pool_mode` application publication introduced only for the session guard. Preserve `STORE_DB_POOL_MODE` parsing and its existing Repo `prepare` behavior. Adjust the Config.Reader test to verify actual repository preparation and queue limits without asserting an unused application flag.
- [ ] Remove dispatch-claimed and dispatch-released telemetry that would otherwise imply a functioning POST protocol. If concurrency tests need to pause an observed outcome before checkpoint D, add a narrowly named observation-ready event after observation and before application. Metadata contains internal IDs only. Tests must synchronize on the actual observation path.
- [ ] Keep adapter payload/normalization tests and abstract lower-level collection state tests. Those tests do not authorize renewal POSTs.

## Task 2: preserve financial and lifecycle coverage with explicit reached evidence

**Files:**

- Create `test/support/reached_renewal_fixtures.ex` with an explicit synthetic legacy fixture contract.
- Modify affected renewal facade, cancellation, dunning, contract, access-effect and monotonicity tests.
- Keep `test/support/subscriptions_fixtures.ex` and the shared Stripe stub behavior unchanged.

- [ ] Inventory every positive renewal POST test by its actual assertion. Fresh dispatch tests become rejection tests. Financial application, retry, cancellation and recovery tests use an explicitly synthetic already-reached collection and then the real observation or verified webhook path.
- [ ] Prepare a normal renewal with the real facade, require the unsupported result, locate its bound attempt/order/intent/collection, explicitly assign a physical generation through its typed domain input where required, then use typed `RenewalCollectionAttempts.AttachAndClaimInput` to seed legacy uncertainty. This fixture is evidence of a test state, not evidence that this runtime made a provider request.
- [ ] Persist one exact unique provider PaymentIntent ID through the normal resource action. A GET response or verified webhook must include that exact identity, local intent metadata, real renewal amount/currency and test environment. Keep terminal success/failure/authentication normalization in the actual payment code.
- [ ] Return the actual facade observation result. Do not convert unresolved observation into success to retain old assertion counts. Update assertions to the real lifecycle and document a synthetic seed where it matters.
- [ ] Preserve old race assertions by moving barriers to observation-ready or actual transaction boundaries. Do not fabricate an HTTP request to retain a dispatch telemetry name.
- [ ] Keep repeated success, late failure suppression, exact-ID dispatch recovery, cancellation authority, reservation release, access application and retry eligibility coverage. Assert that no fresh or replay POST occurs, including after method replacement or revocation.

## Task 3: physical contention and honest capacity evidence

**Files:**

- Modify `test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs`.
- Modify the existing JC-290 real-connection cleanup module to test transaction cleanup, or remove it only if all relevant assertions move into the transaction tests and CI file lists are updated.
- Modify `.github/workflows/ci.yml` only if the physical test module names change.

- [ ] Exercise direct Subscription binding and StoredPaymentMethod mutation actions without a helper taking the competing writer's gate for it. Hold an independent transaction's exact binding gate, prove a second backend waits using `pg_blocking_pids`, release, then inspect the committed writer result and stale CAS behavior.
- [ ] Prove transaction lock release after commit, rollback and owner death. Session-lock acknowledgement tests no longer describe an active runtime path and must not be represented as current guarantees.
- [ ] Treat the historical held-POST capacity workload as obsolete because that protocol is removed. Run two equivalent bounded transaction-contention and cleanup repetitions with independent backends. Keep any final preparation/observation query samples separate from physical contention evidence. Production capacity and provider latency remain unmeasured.
- [ ] Label measurements by the operation actually executed. Do not claim remote fencing, proxy, failover, multi-node or sustained capacity certification.
- [ ] Keep the queue headroom configuration and its runtime Config.Reader coverage. It protects shared primary work even though unfenced renewal POSTs are disabled.

## Task 4: exact correction verification and handoff

- [ ] Run focused strict, setup, affected lifecycle and physical tests through DevCore. Use a fresh private partition for broad suites and separate partitions for committed contention probes.
- [ ] Run repository `mix check`, `mix check.types`, migration alignment and required physical tests twice. Inspect failures before changing assertions. Do not skip old suites because they need new evidence setup.
- [ ] Obtain a fresh spec review, fix actionable findings, then obtain a fresh quality review. Review the whole original JC-290 incremental diff against the current parent, not only this correction's local commits.
- [ ] Update design and operations documentation to state fresh renewal unavailability and exact recovery support. Record old held-POST measurements as historical only. Include Performance & Scaling Review and Runtime Resource Safety Review with unmeasured dimensions stated.
- [ ] Append focused commits, inspect the final diff and exact head, push #216, and link it as the next tool call. Keep the draft/merge hold and require new exact-head CI and independent external verification.
- [ ] Reassess parent and descendant drift after the correction. Do not silently propagate through #217-#221 or overwrite the independent #218 amendment and #219 addendum.

## Local core checkpoint evidence

The unsupported-dispatch regression was red against the prior session-held POST path. Subsequent physical inventory regressions reproduced stock allocation and missing legacy fencing, and inactive/revoked-method cases reproduced the preflight diversion into dunning. The persisted Oban regression first observed a retryable job instead of cancellation. Test-construction errors were corrected separately before these meaningful failures were accepted.

Final focused execution passed 21 tests with zero failures and no test warnings. Both JC-290 connection modules passed six tests twice after the final helper refactor. `mix check.static`, `mix check.types` and `mix ash_postgres.generate_migrations --check` passed through DevCore. The types check retained 144 existing filtered warnings and two unnecessary skips; no ignore entry was added. Independent core spec and quality reviews passed, and the worker policy received a separate spec pass.

Two bounded diagnostic query samples observed 36 current-process primary queries for first nonphysical preparation, nine for repeated rejection and 38 for exact processing observation. The probe used a GET stub, retained unresolved financial state and does not establish capacity or whole-system query counts.

The four required connection modules ran 17 tests with two failures in older SourceFenceContention fixtures that expect fresh Stripe POSTs to manufacture dunning state. Those fixtures, other affected lifecycle suites, the complete final check and exact-head CI remain pending. This is an unpublished core checkpoint, not a completed PR or merge recommendation. PR #216 remains a draft on hold.

## Lifecycle migration checkpoints

Commit `3048e2d` preserves observation errors without business dunning. Its regressions and the first migrated suites passed 76 focused tests, static checks and types. The separate recovery-error plan records the reproduced pre-existing acceptance gap and scoped reviews.

Commit `a3a1d34` migrates the facade and monotonicity tests. Fresh dispatch assertions now require rejection. Recovery fixtures seed explicit legacy possible contact and apply exact provider observations using the actual order total and currency. Physical live-shipping and stock-consumption checks remain. The concurrent stale writer captures a processing attempt before canonical success and paid reconciliation commit, then resumes and must fail as stale. Both spec and quality reviews passed for these two files.

These checkpoints remain unpublished. Broader dunning, cancellation, contract, access and worker migrations still require validation before whole-PR review and CI.
