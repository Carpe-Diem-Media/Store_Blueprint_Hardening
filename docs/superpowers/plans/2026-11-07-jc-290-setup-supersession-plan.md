# JC-290 setup supersession implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development. The root agent owns all Mix, migration generation, database and Git commands in the shared checkout.

**Goal:** Starting a newer setup durably supersedes every older setup, and a verified setup binding is applied at most once.

**Architecture:** Commit a monotonic Subscription setup generation and its PaymentIntent together before provider I/O. Reload the source and intent under the binding transaction gate before applying success. Commit method upsert, binding update and intent application marker together. A direct binding write also advances the generation so it supersedes pending setups.

**Tech stack:** Ash 3 resource actions and optimistic locks, PostgreSQL transactions, existing advisory transaction gates, ExUnit, DevCore.

## Accepted decisions and scope

The owner chose start supersession. If A starts, then B starts and its provider call fails, A remains obsolete and the existing binding stays. The owner also chose strict provider fencing for renewal POSTs. That separate correction will remove the unsupported session-held HTTP path and migrate renewal tests. Do not add a provider bypass or claim that this setup task enables fresh renewal dispatch.

Start from local checkpoint `b336c81f7b8f21b447e0e6583b49aef525cb3e7d` on `jc-290-payment-method-races`. PR #216 remains an open draft on hold. Append commits only. No push, merge, worktree, branch rewrite or descendant update is part of this task.

## Task 1: regression tests, then durable setup authority

**Files:**

- Create `test/store/subscriptions/jc290_setup_supersession_test.exs`.
- Modify `test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs` only for a separate physical concurrent-start regression using its committed fixtures and cleanup.
- Modify `lib/store/subscriptions/subscription.ex`.
- Modify `lib/store/payments/payment_intent.ex`.
- Modify the setup start and success helpers in `lib/store/subscriptions/facade.ex`.
- Root generates a new migration and resource snapshots for Subscription and PaymentIntent under `priv/repo/migrations/` and `priv/resource_snapshots/repo/`.
- Align only affected setup fixtures in `test/store/workers/process_webhook_receipt_worker_test.exs` and `test/store/subscriptions/stored_payment_method_revocation_test.exs` with the new start contract. Do not change shared fixture behavior.
- Add `stub_setup_intent/1` to `test/support/stripe_api_stub.ex` for sanctioned setup request stubbing. Preserve existing helpers and default behavior.
- Update `docs/superpowers/specs/2026-11-07-jc-290-payment-method-race-design.md` after validation.

- [ ] Write tests against the existing public typed user start function and actual verified setup webhook handling. Use `StartSubscriptionPaymentMethodUpdateInput`, `StripeAPIStub`, persisted verified WebhookReceipt and `ProcessWebhookReceiptWorker.perform/1`. Preserve provider identity, environment, customer and exact local intent metadata. Test fields that do not yet exist with `Map.get/2` so the baseline fails on behavior rather than a struct compile error.

```elixir
assert {:ok, %{payment_intent_id: id}} =
         Facade.start_subscription_payment_method_update_for_user(
           fixture.customer,
           fixture.subscription.id,
           %StartSubscriptionPaymentMethodUpdateInput{subscription_id: fixture.subscription.id}
         )

assert Map.get(fetch_intent!(id), :subscription_setup_generation) == 1
```

- [ ] Cover applied A, then applied B, then redelivery of A's verified success. B remains bound. A and B retain their own success evidence and their original applied timestamps. Replay does not move the aggregate version or revoke A globally.
- [ ] Cover pending A, then B starts and its provider create fails, then A's verified success arrives. A is obsolete, its financial/provider success remains recorded, no candidate StoredPaymentMethod is upserted, and the original binding remains. Also cover A success after B starts but before B resolves.
- [ ] Cover redelivery after a committed binding and before queue acknowledgement by invoking the real receipt handler again. No second binding write occurs. A generation-null historical setup records success but cannot change a binding or fabricate an applied marker.
- [ ] Cover a direct binding write superseding a pending setup. Preserve the direct action's existing stale-struct CAS rejection and terminal StoredPaymentMethod revocation behavior.
- [ ] Add a physical concurrent-start regression with separate Repo backends. Use a temporary query-telemetry barrier on A's first exact binding transaction lock, show B in `pg_blocking_pids`, release A, and assert distinct monotonic generations and distinct durable intent keys. Do not hold a DB transaction during provider create. Remove only the owned handler and clean only owned fixtures/tasks.
- [ ] Root runs focused tests before resource or facade edits. Expected RED includes A overwriting B on verified replay, older A winning after B's failed create, and missing captured generations.

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_jc290_setup STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/jc290_setup_supersession_test.exs
```

- [ ] After root confirms RED, add internal fields with descriptions:

```elixir
# Subscription
attribute :payment_method_setup_generation, :integer do
  allow_nil?(false)
  default(0)
  constraints(min: 0)
  public?(false)
end

# PaymentIntent
attribute :subscription_setup_generation, :integer do
  allow_nil?(true)
  constraints(min: 1)
  public?(false)
end

attribute :setup_binding_applied_at, :utc_datetime_usec do
  allow_nil?(true)
  public?(false)
end
```

- [ ] Add a system-only Subscription `advance_payment_method_setup_generation` action. It acquires the existing binding transaction gate, changes generation to `changeset.data.payment_method_setup_generation + 1`, and uses `OptimisticAggregateLock`. Add the same generation increment to `set_provider_billing_reference` before its aggregate lock, so any intentional direct binding write invalidates older setup operations.
- [ ] Add a system-only PaymentIntent create action for setup intents that accepts the captured positive generation and forces purpose `subscription_payment_method_update`. Do not add the generation to ordinary provider-reference update accepts. Add a system-only application-marker update action with empty accepts, a null-marker/succeeded/setup-purpose filter, UTC timestamp, and optimistic lock on `version`. The marker cannot be cleared or rewritten through that action.
- [ ] Replace process-local setup key allocation with `pm-update:v2:<subscription_id>:<generation>`. The new namespace avoids collisions with historical keys. The generation defines order; the key identifies the operation.
- [ ] Start the setup with one primary transaction. Acquire the binding gate, reload the Subscription, revalidate provider support, advance generation, and create the intent with that generation. Collect notifications inside the transaction and deliver after commit. Only then call provider create, persist references and submit the intent. Provider failure leaves the committed newer generation in place.
- [ ] Reject setup start inside an existing explicit Repo transaction with `VALIDATION_ERROR` before writes or HTTP. A nested transaction cannot commit generation authority before provider create. Add a regression that invokes start inside `Repo.transaction/1`, checks zero provider calls, and verifies unchanged generation and no new setup intent.

```elixir
Repo.transaction(fn ->
  :ok = PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, provider)
  {:ok, current} = fetch_subscription_for_renewal(subscription_id)
  # Advance through the system resource action, then create the setup intent.
  # Normalize and roll back every error; collect action notifications.
end)
```

- [ ] In the success transaction, take the binding gate and reload both source and intent. Require the matching source/provider/purpose and succeeded intent state. A generation-null or mismatched intent is an obsolete binding no-op. An already-applied intent is a replay no-op. Neither may upsert a candidate method or overwrite current authority.
- [ ] Check immutable source identity before generation classification. Check current-customer equality only before applying a current, unapplied setup. A coherent direct customer and method replacement must make an older verified callback a successful binding no-op, rather than an invalid event retry.
- [ ] For a current unapplied intent, retain active-method validation and commit the method upsert, `set_provider_billing_reference`, and marker action together. A marker failure must roll back the method and binding. Because the binding action advances generation, the successfully applied generation is `intent.subscription_setup_generation + 1` on the source.
- [ ] Only a still-current applied operation may recover immediate retry enqueue after redelivery. Require source generation equal to captured generation plus one and the exact current binding to match the applied intent. An obsolete setup never enqueues based on its candidate. Keep the existing job uniqueness and retry eligibility behavior; do not silently change the separately tracked technical retry limitation.
- [ ] Root generates and inspects the migration. Existing subscriptions receive zero; historical intents retain null generation and marker. No fabricated history or timestamp backfill. Root migrates only the isolated test partition through DevCore before GREEN.
- [ ] Add a focused atomic rollback test after schema generation. A test-owned constraint on the exact intent can reject marker persistence after the method/binding writes. Assert rollback leaves source binding, candidate method and marker unchanged while preserving independently committed provider success evidence. Remove the test constraint in `after`.
- [ ] Root runs focused tests, existing affected setup/revocation/worker suites, physical concurrent starts twice, migration alignment and required checks. Align legacy positive setup fixtures to use the public start flow; keep a dedicated historical-null no-op test. Do not weaken financial assertions or change shared helpers.
- [ ] Obtain spec then quality reviews. Record exact checkpoint evidence and append a focused commit. Strict renewal rejection and lifecycle test migration remain the next task, and PR #216 stays on hold.

## Evidence limits

Physical concurrent starts must use separate primary connections. Sandbox tests prove logical transactions only. Historical null-generation operations are deliberately not ordered. Mixed-version nodes, failover and production-size migration timing require separate evidence and must not be claimed from these tests.

## Local checkpoint evidence

Root observed four behavioral failures before implementation, then 50 passing tests across the setup, revocation and webhook worker modules after the fixes. The required four real-connection modules passed 45 tests twice. The concurrent-start probe independently observes gate blocking, committed source and intent generations, and no open transaction during provider callbacks. Its request stubs now use the sanctioned Stripe wrapper.

Spec review and fresh rechecks passed. Quality review found that a current-customer check rejected obsolete success after direct replacement; root reproduced and corrected it, and fresh quality review approved the result. Credo and the repository static gate passed after correcting new nesting, alias and Req-wrapper violations. The migration and snapshots contain only the intended additive fields. Type checking passed with the existing 160 skipped warnings and two unnecessary skips; no ignore entry changed.

The new strict-dispatch regression remains intentionally red against the existing session-held POST implementation and belongs to the next task. The full final suite and fresh CI for the complete PR correction remain pending. This checkpoint does not release the PR #216 hold or authorize a merge.
