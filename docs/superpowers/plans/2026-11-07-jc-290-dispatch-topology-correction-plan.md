# JC-290 dispatch topology correction implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task by task. The root agent owns all Mix and database commands in the shared checkout.

**Goal:** Reject fresh renewal submission through a declared transaction-pooled primary repository before taking session locks or claiming provider contact.

**Architecture:** Keep dispatch and writer locks on their existing repositories. Publish the validated production pool mode as application configuration and permit the session-lock helper only when it is explicitly `"session"`. Return a registered infrastructure error without recording a payment failure or advancing dunning.

**Tech stack:** Elixir, Ecto/Postgrex, Ash 3, Oban, PostgreSQL, ExUnit, DevCore.

## Scope and authority

The correction starts at `d1d60edfaa7f9ff24dec340cbee9e3f8fac234eb` on `jc-290-payment-method-races`, PR #216. The PR remains a draft with a merge hold. Append commits only. Do not merge, rewrite history, create a worktree, update descendants, or change provider capabilities.

The topology defect is independent of two pending owner decisions. The frozen checkpoint-C authority requirement and the ordering of overlapping payment-method setup operations remain unresolved. This correction does not close the HTTP/session-loss defect, the setup replay gap, or the concurrency risk. The existing single-dispatch measurements do not certify saturation safety.

PgBouncer transaction pooling cannot preserve session advisory-lock ownership. A checked-out Ecto connection does not establish a pinned PostgreSQL backend. The guard is an explicit rejection of that deployment mode, not an implementation of session-pinned routing. Configuration is a deployment assertion. A mislabeled transaction proxy cannot be detected by this guard.

Do not move transaction advisory locks to `DirectRepo`. They must belong to the actual writer transaction. Do not move only the dispatch holder to a different repository, since its claim actions may then block on its own gates through another physical session.

## Task 1: reject unsupported dispatch topology

**Files:**

- Modify `config/config.exs` to declare the local direct-PostgreSQL default `database_pool_mode: "session"`.
- Modify `config/runtime.exs` to publish the already validated `STORE_DB_POOL_MODE` as `:store, :database_pool_mode`.
- Modify `lib/store/subscriptions/payment_method_authority_gate.ex` to reject every value except `"session"` before `Repo.checkout/2`.
- Modify `lib/store/support/errors/error_codes.ex` and `docs/governance/error_codes.md` to register `RENEWAL_DISPATCH_UNAVAILABLE`.
- Modify `lib/store/subscriptions/facade.ex` to preserve that infrastructure error through both fresh and captured dispatch and through renewal result classification. Do not turn it into decline, retry-count increment, grace establishment, or past-due transition.
- Modify `test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs` for the helper rejection contract.
- Modify `test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs` for a facade-level repeated-call regression using its existing committed fixtures and cleanup.
- Modify `docs/superpowers/specs/2026-11-07-jc-290-payment-method-race-design.md` to record the guard and remaining limitations.

- [ ] Add a tagged helper regression for `"transaction"`, an unknown string, and nil. Save and restore the exact previous application environment, including whether the key existed. Attach a temporary Repo query handler only around the gate call. Assert no resolver, callback, or query event occurs. Use unique references for every message and remove the handler in an `after` block.

```elixir
Application.put_env(:store, :database_pool_mode, "transaction")

assert {:error,
        %Store.Support.Errors.Error{
          code: "RENEWAL_DISPATCH_UNAVAILABLE",
          meta: %{reason: :unsupported_database_pool_mode}
        }} =
         Gate.with_dispatch_session_gates(
           identity.user_id,
           identity.provider,
           fn -> send(parent, {ref, :resolved}); {:ok, identity} end,
           fn _, _ -> send(parent, {ref, :submitted}); :sent end
         )

refute_received {^ref, :resolved}
refute_received {^ref, :submitted}
refute_received {^ref, :query}
```

- [ ] Add a tagged facade regression with an existing due, chargeable Stripe fixture. Configure `"transaction"` only after fixture creation. Stub charge POST to count calls. Call `process_due_subscription_renewal_for_system/2` twice with the same fixed `now`. Both calls must return the registered infrastructure error. Assert zero POSTs, no collection with dispatch state other than `not_started`, no terminal financial outcome, and unchanged Subscription status, retry count, retry schedule, and binding. Inspect the actual schema names and existing fixture fields before writing the SQL assertions. Restore application configuration before fixture cleanup.

```elixir
for _ <- 1..2 do
  assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
           Facade.process_due_subscription_renewal_for_system(
             fixture.subscription.id,
             now: fixture.now
           )
end

assert :atomics.get(posts, 1) == 0
assert current_subscription!(fixture).status == fixture.subscription.status
```

- [ ] Root runs the new tagged regressions before production changes.

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_jc290_followups STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test --only jc290_topology_correction test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs
```

Expected RED: the old helper runs the callback and returns `:sent`; the facade sends a POST instead of rejecting the configured topology. The worker must stop after adding tests until root reports this observed failure.

- [ ] Register `RENEWAL_DISPATCH_UNAVAILABLE` in code and documentation. Add the configuration default and production assignment after validation of `db_pool_mode`.

```elixir
config :store, :database_pool_mode, "session"
```

```elixir
config :store, :database_pool_mode, db_pool_mode
```

- [ ] Wrap the old gate body with a configuration guard. Keep the existing gate body in a private helper, preserving its exception propagation, lock ordering, timeouts and cleanup. Use the existing error envelope and do not include connection strings or credentials in metadata.

```elixir
def with_dispatch_session_gates(user_id, provider, resolve_identity, fun) do
  case Application.get_env(:store, :database_pool_mode) do
    "session" ->
      do_with_dispatch_session_gates(user_id, provider, resolve_identity, fun)

    _ ->
      {:error,
       Error.new(
         "RENEWAL_DISPATCH_UNAVAILABLE",
         "renewal dispatch requires a session-pinned database connection",
         %{reason: :unsupported_database_pool_mode}
       )}
  end
end
```

- [ ] Preserve this typed error in `run_single_due_renewal/4`, `run_claimed_due_renewal/4`, and `classify_claimed_renewal_charge_result/2` before their generic financial-failure paths. The dispatch wrapper cases already propagate typed errors through their final clause. Confirm both fresh and captured branches retain the error. Keep the changes narrow, without restructuring the facade.

```elixir
{:error, %Error{code: "RENEWAL_DISPATCH_UNAVAILABLE"} = error} ->
  {:error, error}
```

- [ ] Root repeats the tagged tests and then all existing cleanup and dispatch-race tests with `--only real_connections`. Expected GREEN: every test passes. Direct session mode must retain all existing contention and cleanup behavior.
- [ ] Root runs focused formatting, static checks, full required suites and independent reviews before publishing a correction. Record exact counts and distinguish direct PostgreSQL guard tests from an actual PgBouncer backend-reuse test. No project-owned PgBouncer endpoint is currently available, so proxy fault injection remains unmeasured.
- [ ] Append a design correction note that retracts transaction-proxy cleanup claims and retains the merge hold for the remaining findings. Include performance and runtime resource reviews. This guard performs one application-configuration lookup and performs no query on rejection. Do not claim capacity or post-confirmation response safety.
- [ ] Review the complete diff and exact head, then append a focused commit after validation. Do not publish a claim that all JC-290 defects are fixed.

## Self-review

This plan covers only immediate topology containment and nonfinancial error handling. It adds no dependency, migration, extra pool, cache, HTTP behavior, or change to writer transaction locks. The concurrency correction will have a separate bounded plan. The two financial semantics remain with the owner and do not inherit a decision from this plan.
