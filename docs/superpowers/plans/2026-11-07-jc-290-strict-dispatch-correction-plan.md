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
- [ ] Cancel deterministic unsupported-dispatch Oban jobs and include cancelled occurrences in the worker's existing uniqueness states. Preserve retries when cleanup or preflight failed. Exercise actual job acknowledgement and repeated sweep uniqueness without changing completed/discarded retry policy. Document retry of retained cancelled jobs after future reviewed fencing support, and the existing pruner's retention limit.
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
- [ ] Binding-only tests use actual fresh preparation followed by rejection. Concurrent first-binding tests must still start both operations from an unprepared source; seeding an attempt before the race would lose that proof. Locate the unclaimed PaymentIntent by its canonical collection key when the attempt has no mirrored intent ID.
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

The SBH-20-05 dunning migration retains ten cases. It preserves storage rollback, exact retry identity, authentication settlement and concurrent cancellation checks through exact-ID reads. Its paid-precedence race pauses a nonterminal `requires_payment_method` read, commits canonical success and paid reconciliation, then resumes the stale read and verifies unchanged paid state. It does not model a terminal canceled Stripe intent becoming successful. The legacy outbox replay test explicitly creates its historical outbox through Comms because observation recovery does not create the original dispatch email.

The module passed ten tests, and the combined first lifecycle group passed 97 tests. The recovery query case observed 100 queries under the existing 122-query limit. Strict Credo passed with no findings. The previously failing contract-binding batch-count test passed all 11 module tests in a fresh partition; committed rows from failed unboxed fixture creation had polluted the earlier exploratory partition. That suite remains unchanged. Final broad checks must use a clean partition.

The next four-module group passed 33 tests and strict Credo, with scoped spec and quality reviews approved. Contract-change and retired-revision binding tests retain actual B preparation and assert dispatch rejection. Concurrent ticks start from an unprepared source and establish one attempt, order, collection and created PaymentIntent without advancing the period or dunning. The NON_EFFECTIVE executor fixture now uses missing-method dunning to reach suspension; its execution, grant-history and resource checks remain intact. Queue profiles observed 19 or 20 queries, and each existing bounded resource repetition used 19 queries for 128 exact-source rows. These observations do not establish production capacity.

The worker comment and design now distinguish retained cancelled-job uniqueness from a durable ban. The existing 24-hour Oban pruning policy can permit a later job for the same occurrence. Strict dispatch rejection still applies to that job; no runtime policy changed for this documentation correction.

The charged-contract reconciliation and contract-change modules passed 51 tests with zero failures and no warnings. Their fixtures establish explicit legacy possible contact and apply canonical exact-ID payment evidence without reconciling the commercial contract early. Authentication cases settle `requires_action` through observation recovery before checking the captured grace boundary and replay after a live policy change. Separate spec and quality reviews found no actionable gaps, and strict Credo passed. This remains scoped evidence; cancellation, access, worker and final whole-PR checks are pending.

The snapshot and two cancellation-race modules passed 35 tests together. Fresh first-binding cases retain their real preparation and cancellation barriers. The concurrent queued-target case waits for both tasks to be ready before release, permits the existing processing-claim loser's no-op return, and counts exactly one new Order and PaymentIntent. Rejected retry preparation preserves the captured commercial policy, failure boundary, dunning count and retry time. Legacy late-outcome races pause exact-ID GET observation while cancellation commits, then apply the actual canonical outcome. The local PaymentIntent state for a terminal canceled Stripe intent is `failed`. An unclaimed fresh collection remains `not_started` after cancellation and owns no reservation generation. A later invocation against the canceled source is a no-op and preserves the original attempt and collection without a POST. Both scoped spec and quality reviews passed after the final assertions, and strict Credo found no issues. The cancellation run retains one runtime unsent-notifications warning also present in its original baseline; it has no compiler warnings.

The larger cancellation-authority module retains all 30 cases and passed with zero failures and no warnings in a fresh partition. Separate spec and quality reviews passed, and strict Credo found no issues. Its financial helpers observe the exact collection PaymentIntent through the provider adapter and retain the actual evidence identity for certification checks. Both Order-lock races commit observation evidence before creating their lock holder and retain the independent competing writers and waiter proof. Physical retry follows canonical terminal failure and real business dunning with a distinct legacy retry PaymentIntent and generation on the original occurrence and Order. Fresh B cancellation remains unclaimed with no new stock; canonical collection keys identify its created PaymentIntent because legacy mirrors are nil. The payment-first case profiles one financial application under the original 85-query limit, then checks stock consumption and replay. Broader access, boundary, worker, parent integration and final whole-PR validation remain pending.

The durable-boundary, stale-rescission and two worker modules passed all 44 tests with real-connection cases included, with zero failures and no warnings. Fresh B-only cases retain actual preparation and assert rejection. Paid boundary cases use canonical exact-ID observations before commercial reconciliation. The tick worker still creates one job across repeated ticks; its processing observation remains unresolved until a verified success webhook establishes the exact financial handoff. Subscription periods and digital access remain unchanged before commercial reconciliation. Physical webhook replay consumes the same reservation once. Scoped spec and quality reviews passed, and strict Credo found no issues.

A truthful nonterminal Stripe failure webhook with zero received amount reproduced an existing amount-validation rejection. The migrated test records that rejection, preserves unresolved payment and inventory, and proves later success for the same PaymentIntent applies once. JC-373 tracks the separate defect in Backlog. No production payment-validation change is included here. Access-policy suites, their physical races, parent integration and complete exact-head verification remain pending. These local checkpoints do not change the draft PR's merge hold.

The basic keep-grace and immediate-removal policy modules retain all 11 cases and passed with zero failures and no warnings. Explicit HTTP rejection guards run before legacy preparation, then exact-ID GET observations produce terminal failure or authentication settlement through the real facade. Retry uses the persisted retry time, a distinct collection and PaymentIntent, and the original attempt and Order. Existing effect dispositions, provenance, one-effect replay, rollback fault injection, isolation and malformed interval checks remain. The scoped spec recheck and quality review passed, and strict Credo found no issues. Acceptance matrices, adversarial boundary coverage and physical access races remain to be migrated before final verification.

Both access-policy acceptance matrices retain all 25 cases and passed with real-connection tags included, zero failures and no warnings. The spec and quality reviews passed, and strict Credo found no issues. Failure tasks retain their post-commit dunning barriers and all F1 outcome assertions. The parent process prepares legacy records and owns the exact-ID HTTP stubs before launching those tasks. Authentication replay repeats the same provider body. Paid recovery uses a distinct retry PaymentIntent after the original terminal failure, applies canonical financial evidence, obtains its exact handoff and then reconciles before releasing the stale F1 task. The preparation leaves the existing source version, episode pointer, boundary, snapshot and effect unchanged. Historical grant revocation reasons and later suspension assertions remain. The former exact-failure-replay title now says retry failure because that case observes a distinct retry collection. Adversarial boundary and physical access race migrations, parent integration and final whole-PR checks remain pending.

The adversarial dunning module retains all 22 cases and passed with zero failures and no warnings. Its live boundary tests preserve zero grace and the original retry limit. They prepare a distinct unclaimed retry, persist a newer database boundary, and submit a typed claim with an earlier input time. The exact checkpoint error proves rejection by the SQL guard, while the collection identity, reservation generation, episode pointer and retry time remain unchanged. The pre-boundary case retains one permitted retry and repeats exact-ID processing observation without creating another collection. Positive outcomes use canonical exact-ID financial application. Preparation rejects unexpected HTTP, and obsolete POST counters were removed. Formatting and strict Credo passed. Physical access races, parent integration and whole-PR validation remain pending.

The SourceFence and charged-renewal physical modules retain all ten cases and passed together with zero failures and no warnings. The JC247-B cases establish initial access before legacy preparation, then use an exact canceled GET and the real facade's dunning transition. The parent prepares a distinct retry and applies canonical success before deliberate row barriers. It verifies unchanged source authority, required current B effect and original grants before commercial recovery starts. Both original PostgreSQL blocker sequences remain, including recovery's later wait on the held RenewalAttempt row. The charged-renewal cases retain both cancellation orders and now each assert the captured revision and one financial application. Spec review found those two missing assertions; the fix passed a fresh recheck and all ten physical tests again. Formatting and strict Credo passed.

The charged module now releases auto-owned Sandbox connections after its database identity checks and serial parent reads. A three-connection diagnostic still failed on an Ash asynchronous subscription-items load while the three race actors held their connections. Its test guard now requires four primary connections, matching the successful runs. This changes no runtime pool size, timeout or capacity claim. Temporary query diagnostics were removed. Parent integration, full-PR review, complete repository checks and exact-head CI remain pending.

Quality review found a cancellation task that could outlive an assertion failure. Both charged-renewal races now register exact-task monitoring and bounded termination in their exit cleanup. All ten physical tests passed again after this fix, strict Credo remained clean, and the fresh quality recheck approved the two-file migration. These results complete the identified lifecycle fixture migrations locally. They do not certify the pending parent integration or whole PR.

Parent integration is now local and append-only. JC-255 head `1cbd92ed94d8a0bdacbf525a6d12c625cb7f309e` contains both JC-360 follow-ups. Its tree matches the inspected CI merge `497a1222a2b0dea8c66707c48ec1dd6fdebc9b77`; local verification passed 78 focused tests, full check with three properties and 1,585 tests, types, migration alignment and 13 required connection tests twice. The parent merged into JC-290 without conflicts. The combined strict, setup, timezone and contention run passed 52 tests and three properties.

The first complete JC-290 check found one failure among 1,619 tests. The unchanged retry-exhaustion test manufactured a historical setup intent without a generation and expected it to bind. Its isolated four-test run reproduced the failure. Commit `c5261eb5f13c9492a9ac852167319b7ffb8c58d7` migrates that case to a real typed setup start and exact verified webhook success, while preserving the exhausted attempt, suppression, immutable snapshot and absence of a renewal enqueue. It passed four tests and separate spec and quality review. No production change was required for this fixture correction.

The complete rerun passed three properties and 1,619 tests with zero failures, plus strict Credo and the remaining repository check steps. Types and TEST migration alignment passed. The four required connection modules passed 19 tests twice; the other six affected connection-tagged cases also passed. Complete runtime and coverage spec reviews, then quality review, approved the integrated production change at `829f79b`; the subsequent one-file test delta received its own rechecks. The final publication still needs new CI and independent external re-verification. Downstream #217 through #221 remain to be propagated and revalidated, preserving the identifiable #218 amendment and #219 addendum. No PR merge or final approval has been granted.
