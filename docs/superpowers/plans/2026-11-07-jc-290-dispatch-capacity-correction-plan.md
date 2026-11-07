# JC-290 dispatch capacity correction implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task by task. The root agent owns all Mix and database commands in the shared checkout.

**Goal:** Bound the subscriptions queue below primary database capacity and demonstrate that unrelated binding and webhook work can progress while that bounded number of renewal dispatches waits for provider responses.

**Architecture:** Set the ordinary queue default to four. Production computes its limit from the configured primary pool size and reserves at least two connections for other work. Keep the existing Oban queue and repositories. Test the real runtime configuration and actual renewal facade with bounded provider barriers.

**Tech stack:** Elixir Config.Reader, Oban Basic queue limits, Ecto/Postgrex, Ash 3, ExUnit and DevCore.

## Scope and constraints

The owner subsequently chose strict provider-side fencing and setup-start supersession. Those follow-up corrections are outside this independent capacity checkpoint. The liveness measurements below describe the local protocol before strict unsupported-provider rejection and must be reassessed with that correction.

Implement only after the topology correction has passed its spec and quality reviews. Do not alter provider authority, HTTP lifetimes, setup ordering, migrations, pool sizes, or performance thresholds. PR #216 remains on hold. The selected strict dispatch and setup-ordering corrections are separate follow-ups. A lower queue limit reserves potential connection capacity. It does not reserve connections against all other consumers or certify production throughput.

Production currently defaults to a primary pool of ten and ten subscriptions jobs. Each blocked dispatch can own one primary checkout. Use a fixed minimum headroom of two. The automatic subscriptions limit is `min(4, primary_pool_size - 2)`. An explicitly configured `STORE_SUBSCRIPTIONS_QUEUE_LIMIT` must be a positive integer no greater than `primary_pool_size - 2`. Reject a primary pool smaller than three. This is a per-node bound matching that node's primary pool, not a cluster-wide database capacity claim.

## Task 1: configure and verify primary-pool headroom

**Files:**

- Modify `config/config.exs` for the ordinary subscriptions queue default.
- Modify `config/runtime.exs` for the production bound and validation.
- Create `test/store/subscriptions/jc290_dispatch_runtime_config_test.exs` to evaluate the actual Config files without applying returned configuration or opening a connection.
- Modify `test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs` for the bounded-wait progress regression, reusing its committed fixture and cleanup helpers.
- Modify `docs/superpowers/specs/2026-11-07-jc-290-payment-method-race-design.md` to record behavior and measured limits.
- Modify `docs/stabilization/source-of-truth.md` and `docs/phases/phase_28_production_readiness_release_checklist.md` to document the topology restriction, `POOL_SIZE` minimum, automatic queue bound and optional `STORE_SUBSCRIPTIONS_QUEUE_LIMIT`.

- [ ] Add synchronous Config.Reader tests. Temporarily set only the required production configuration to inert test literals. Override `DATABASE_URL` with an inert local URL for evaluation only, set digital storage to fake, disable enabled payment providers and inventory admission, and use the existing Swoosh comms path. Preserve the exact presence and values of every environment key changed. Do not inspect or print any actual secret. Read `config/config.exs` with `env: :prod, target: :host`, read `config/runtime.exs` with the same options, and merge using `Config.Reader.merge/2`. Do not call `Application.put_all_env/1`.

```elixir
base = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
runtime = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
config = Config.Reader.merge(base, runtime)
queues = config[:store][Oban][:queues]
assert queues[:subscriptions] == 4
assert queues[:webhooks] == 10
assert config[:store][Store.Repo][:pool_size] == 10
assert config[:store][:database_pool_mode] == "session"
```

- [ ] Test automatic limits of two for `POOL_SIZE=4` and one for `POOL_SIZE=3`. Test explicit six with `POOL_SIZE=10`, rejection of nine with that pool, rejection of pool two, and rejection of zero, negative, malformed, and empty queue-limit strings. Test that transaction mode is published for the guard and still sets `prepare: :unnamed`, without losing the other queue configurations.

```elixir
System.put_env("POOL_SIZE", "4")
System.delete_env("STORE_SUBSCRIPTIONS_QUEUE_LIMIT")
config = runtime_config!()
assert config[:store][Oban][:queues][:subscriptions] == 2

System.put_env("STORE_SUBSCRIPTIONS_QUEUE_LIMIT", "3")
assert_raise RuntimeError, ~r/reserve at least two primary database connections/, fn ->
  runtime_config!()
end
```

- [ ] Add a tagged real-connection regression before changing queue production configuration. Assert the default compiled configuration evaluated without test overrides has subscriptions limit four. For a four-connection primary test pool, use the production configuration evaluation with `POOL_SIZE=4` to establish the tested bound of two. Keep runtime configuration evaluation in the dedicated synchronous module, while the real-connection test derives its bounded workload with `min(4, Repo.config()[:pool_size] - 2)` and documents that relationship. Do not assert that arbitrary direct facade calls enforce an Oban limit.
- [ ] Root runs the runtime configuration tests at RED. Expected failure: default remains ten and production does not reduce or validate it. The worker must stop until root confirms this observed failure.
- [ ] Change `config/config.exs` subscriptions from ten to four. Parse the primary pool size once in production runtime and reuse it for repository options and capacity validation.

```elixir
primary_pool_size = parse_positive_integer!.("POOL_SIZE", "10")

if primary_pool_size < 3 do
  raise "POOL_SIZE must reserve at least two primary database connections outside the subscriptions queue"
end

subscriptions_queue_limit =
  parse_positive_integer!.(
    "STORE_SUBSCRIPTIONS_QUEUE_LIMIT",
    Integer.to_string(min(4, primary_pool_size - 2))
  )

if subscriptions_queue_limit > primary_pool_size - 2 do
  raise "STORE_SUBSCRIPTIONS_QUEUE_LIMIT must reserve at least two primary database connections outside the subscriptions queue"
end

config :store, Oban, queues: [subscriptions: subscriptions_queue_limit]
```

- [ ] Root reruns runtime configuration tests at GREEN. Verify Config.Reader's deep merge retains all other queues and that no running application configuration or database endpoint changed.
- [ ] Use the existing race module's fixtures for four unrelated customers. Before saturation, dispatch one source with a processing response and persist its exact provider identity. Create a verified `payment_intent.succeeded` receipt using that exact identity and amount/currency, not query parameters. A fourth customer's binding will be the unrelated writer. For each of two equivalent repetitions, hold two actual renewal facade dispatches inside Stripe POST stubs. Signal each owned backend PID and wait on exact-reference release messages, with bounded timeouts and no sleeps.

```elixir
StripeAPIStub.stub_payment_intent(fn conn, params ->
  send(parent, {ref, :provider_wait, self(), params})
  receive do
    {^ref, :release} -> :ok
  after
    10_000 -> raise "bounded provider wait expired"
  end
  StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
end)
```

- [ ] While both waits are held, inspect existing DBConnection pool metrics without consuming a primary connection. Assert at least two ready primary connections. Concurrently invoke the real verified-receipt worker and a direct binding resource action for the unrelated source. Both must finish before releasing either held provider response. Capture elapsed time, query queue time, successful worker outcome and committed binding. Use a bounded Task.await as a liveness assertion, not as a production latency SLA. Confirm that no waiting renewal uses the unrelated method.
- [ ] Release the exact two waiting processes and assert both renewals preserve their own PaymentIntent, collection and financial evidence. Clean up all tasks, handlers, test receipts and fixtures in `after` blocks. Restore any changed application configuration and sandbox mode. Confirm pool ready count returns to its pre-load level and both exact advisory keys are absent. Do not drain unrelated messages or terminate unrelated sessions.
- [ ] Root runs the bounded progress test twice using the isolated DevCore test suffix. Record durations, query counts/queue times, pool ready counts, post-GC memory and mailbox counts where observed. Report unmeasured dimensions explicitly. The barrier stubs model provider waits and do not certify external network timeouts, cross-node load, production sizing or absolute checkpoint-C ordering.
- [ ] Run focused tests and required full repository checks. Obtain separate spec and quality reviews. Append a focused commit, update PR #216 with exact evidence and keep the remaining defect hold visible. No descendant update or merge is part of this task.
- [ ] Update the two deployment references. State that transaction mode still configures unnamed prepared statements, but fresh renewal POSTs are rejected in that mode. Document that a declared session mode must correspond to a direct or session-pooled PostgreSQL endpoint. State the minimum pool of three, fixed minimum headroom of two, automatic limit `min(4, POOL_SIZE - 2)`, and the validated optional queue-limit override. Do not advertise the lower limit as a capacity certification.

## Self-review

No extra pool, cache, semaphore service or dependency is required. The configured Oban limit bounds queue-started work per node. Ordinary facade calls remain available to tests and are not advertised as a second admission system. The liveness probe establishes only progress under the tested bounded direct-PostgreSQL workload. It does not resolve HTTP authority loss or setup replay.
