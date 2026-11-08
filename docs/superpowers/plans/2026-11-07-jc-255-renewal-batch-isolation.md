# JC-255 renewal batch isolation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox syntax for tracking.

**Goal:** Keep valid recurring billing reachable when historical contracts have invalid billing timezones.

**Architecture:** Isolate only `INVALID_BILLING_TIMEZONE` during due-source enumeration. Preserve the existing list API and add a one-page API with a timestamp/UUID keyset cursor. The existing tick worker enqueues valid jobs and one continuation, including when a full page contains no valid jobs.

**Tech stack:** Elixir 1.19.5, Ash 3, PostgreSQL, Oban, ExUnit, DevCore.

## Scope and decisions

Resume `jc-255-billing-timezone` append-only from `6001f015ff3cc19d47ca123e6c0273a688c9ab91`. PR #215 remains a draft. No descendant updates, merges, history rewrites, new worktrees, dependencies, migrations or contract repairs. The independent review is `/tmp/jc255-evidence-uq7ajsxf/review.md`. JC-255 is the live execution issue; JC-225 is Done.

Preserve `next_renewal_at` ascending, then native UUID ascending, with null renewal timestamps last. Past-due rows can have null timestamps. A timestamp-only cursor would omit those rows. Offset pagination would skip rows as completed renewals leave the due set. An unbounded scan would allow corrupt data to monopolize a worker. Use one page of 1 through 500 sources per invocation instead.

Every continuation carries the same selection `now`, page limit, and last scanned row. The cursor advances over rejected rows. Each scheduled root tick starts without a cursor. This is a mutable-set sweep, not a database snapshot; rows moving behind a cursor wait for a later root tick.

Only the explicit timezone error becomes a skipped source. Preserve existing unresolved-contract skipping and propagate unexpected errors. Preserve direct single-source failure and immutable bound attempts. Emit a diagnostic containing the source ID, effective revision ID, and error code. Do not log provider references, raw error dumps or payment evidence.

## Task 1: Database regressions and bounded enumeration correction

Files:

- Modify `lib/store/subscriptions/subscription.ex`, its existing `read_due_for_system` action.
- Modify `lib/store/subscriptions/facade.ex`, due enumeration and its private helpers.
- Modify `lib/store/workers/run_due_subscription_renewals_worker.ex`.
- Create `test/store/subscriptions/due_renewal_batch_isolation_test.exs`.

- [ ] Read AGENTS, the existing JC-255 design, the action, facade, tick worker, scheduled-cancellation cursor pattern, and subscription fixture.
- [ ] Add database-backed tests before production changes. Use a synchronous Store.DataCase and Oban.Testing on Store.DirectRepo. Each source gets its own plan/effective revision. Create historical invalid data only by SQL after valid fixture creation. Use this complete core reproduction:

```elixir
defmodule Store.Subscriptions.DueRenewalBatchIsolationTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo
  alias Store.Subscriptions.Facade
  alias Store.SubscriptionsFixtures, as: Fixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  for invalid_first? <- [true, false] do
    @invalid_first invalid_first?
    test "mixed validity preserves valid jobs, invalid first #{@invalid_first}" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      bad = due_source!(now, if(@invalid_first, do: -20, else: -10))
      good = due_source!(now, if(@invalid_first, do: -10, else: -20))
      corrupt_timezone!(bad.revision.id)
      StripeAPIStub.stub_unexpected!("enumeration must not submit payments")
      assert {:ok, [%{subscription_id: id}]} =
               Facade.list_due_renewal_jobs_for_system(now: now, limit: 50)
      assert id == good.subscription.id
      assert {:error, %{code: "INVALID_BILLING_TIMEZONE"}} =
               Facade.process_due_subscription_renewal_for_system(bad.subscription.id, now: now)
    end
  end

  defp due_source!(now, delta) do
    customer = Fixtures.create_customer!("jc255_batch")
    %{variant: variant} = Fixtures.create_subscription_sellable!()
    plan = Fixtures.create_subscription_plan!()
    Fixtures.attach_variant_plan!(variant.id, plan.id)
    Fixtures.create_subscription_fixture!(customer.id, variant, plan, %{
      provider_billing_ref: "pm_jc255_batch_#{System.unique_integer([:positive])}",
      next_renewal_at: DateTime.add(now, delta, :second)
    })
  end

  defp corrupt_timezone!(revision_id) do
    Store.Repo.query!(
      "UPDATE plan_revisions SET billing_timezone = $1 WHERE id = $2",
      ["Not/A_Real_Zone", Ecto.UUID.dump!(revision_id)]
    )
  end
end
```

Extend the same module with the actual tick worker in both row orders, repeated invocations, and assertions that exactly one valid ProcessSubscriptionRenewalWorker job remains. Capture invalid-source diagnostics and assert both IDs. Snapshot subscription state and counts of RenewalAttempt, RenewalCollectionAttempt, Order, PaymentIntent and access-effect rows after fixture setup; enumeration and ticks must leave them unchanged. This distinguishes queue dispatch from renewal execution.

Add an invalid prefix of at least two full pages with `limit: 1`, followed by a valid row. Assert the first page has `jobs: []` and a cursor, then execute the actual enqueued continuation jobs through Oban.Testing. Assert fixed `now`, cursor advancement, terminal page, bounded continuation count and one valid queued job across two equivalent sweeps. Do not manually calculate the worker's next cursor in the test.

Cover tied timestamps with database/native UUID ordering, transition from a non-null timestamp to null, and continuation within null timestamps. Create past-due eligible null-timestamp fixtures through existing actions, or use scoped historical SQL where fixture actions forbid the precise historical shape. Assert every source exactly once in facade pagination. Reject malformed timestamps, malformed UUIDs and timestamp-without-ID cursors without enqueuing work. Preserve existing fallback limit handling.

- [ ] Root runs the new module before production edits and records its expected mixed-batch failure. Root owns all Mix invocations, using a private DevCore test partition. No production edits before the root reports RED.
- [ ] Add nullable optional `after_renewal_at` and `after_id` action arguments. Extend its existing filter with this keyset predicate, keeping all due/retry/cancellation conditions:

```elixir
is_nil(^arg(:after_id)) or
  (not is_nil(^arg(:after_renewal_at)) and
     (next_renewal_at > ^arg(:after_renewal_at) or
        (next_renewal_at == ^arg(:after_renewal_at) and id > ^arg(:after_id)) or
        is_nil(next_renewal_at))) or
  (is_nil(^arg(:after_renewal_at)) and is_nil(next_renewal_at) and id > ^arg(:after_id))
```

Use explicit `sort: [next_renewal_at: :asc_nils_last, id: :asc]`. Keep the existing code interface arguments compatible. Verify the sort option in installed Ash source.

- [ ] Add documented and typed `list_due_renewal_job_page_for_system/1`. Validate cursor before the Ash query. `(nil,nil)` starts a scan; `(DateTime,valid UUID)` advances non-null rows; `(nil,valid UUID)` advances null rows; reject every other combination. Validate `now` as DateTime and keep Ash's 1..500 limit validation. Read at most one limited page, build jobs and return:

```elixir
{:ok, %{
  jobs: Enum.reverse(jobs),
  cursor: due_renewal_cursor(subscriptions, limit),
  now: now
}}

defp due_renewal_cursor(subscriptions, limit) when length(subscriptions) == limit do
  last = List.last(subscriptions)
  %{timestamp: last.next_renewal_at, id: last.id}
end
defp due_renewal_cursor(_subscriptions, _limit), do: nil
```

Keep `list_due_renewal_jobs_for_system/1` as a wrapper returning `{:ok, result.jobs}` or the same error. Its limit still means selected rows, not guaranteed valid jobs. Document the page API for callers needing progress through a full invalid page.

- [ ] Add an explicit reducer clause before the generic error halt:

```elixir
{:error, %Error{code: "INVALID_BILLING_TIMEZONE"}} ->
  Logger.warning("subscription renewal skipped: invalid billing timezone",
    subscription_id: subscription.id,
    plan_revision_id: subscription.current_plan_revision_id,
    error_code: "INVALID_BILLING_TIMEZONE"
  )
  {:cont, {:ok, jobs}}
```

Require Logger in the facade. Include the IDs in an observable way in tests even when the default formatter omits metadata. Do not broaden skipping to all validation or all domain errors.

- [ ] Update the existing tick worker to parse optional UTC ISO `now`, nullable `after_renewal_at`, and UUID `after_id`. Reuse the scheduled-cancellation parser pattern locally. Require an ID if a timestamp exists. Root args have neither cursor field. A null-phase cursor has an ID and a null timestamp. Keep current limit parser behavior. Malformed cursor input returns discard. Add a fallback perform clause for malformed jobs.

The perform sequence is:

```elixir
with {:ok, opts} <- parse_opts(args),
     {:ok, page} <- SubscriptionsFacade.list_due_renewal_job_page_for_system(opts),
     :ok <- enqueue_due_jobs(page.jobs),
     :ok <- enqueue_next_page(page, Keyword.fetch!(opts, :limit)) do
  :ok
end
```

`enqueue_next_page(%{cursor: nil}, _limit)` returns `:ok`. For a full page, serialize `page.now`, cursor ID and nullable timestamp into one job of this same worker with the same limit. Use Oban.insert's result. Insert page jobs before continuation; on insert errors return the error so the current page retries. Preserve ProcessSubscriptionRenewalWorker's existing uniqueness. Change tick worker uniqueness to include args, as the scheduled-cancellation worker does, so distinct continuation cursors do not collide with the current tick and equivalent pages remain deduplicated.

- [ ] Root formats the four files and runs the regression module, existing due-worker module, renewal contract snapshot tests and scheduled cancellation race tests. Verify the full added diff, then commit `fix(subscriptions): isolate invalid timezone renewal sources`.
- [ ] Fresh spec review must pass before a fresh quality review. Root fixes small review findings directly and requests a fresh verification of changed code. No reviewer may mutate files or run Mix concurrently with root.

## Validation and publication

Root uses this prefix for every test/database-dependent command:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_jc255_followups STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test --
```

- [ ] Run DevCore doctor, create/migrate the private test database sequentially. Never print credentials or touch another agent's partition.
- [ ] Run `mix check`, strict `mix test --max-failures 1`, `mix check.types`, and `mix ash_postgres.generate_migrations --check`.
- [ ] Run required real-connection files twice: `mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs`.
- [ ] Measure two equivalent bounded page sweeps with query counts, row/page counts, process memory/mailbox and process cleanup. Report unmeasured dimensions rather than inferring capacity or convergence from functional success. Inspect query indexes and N+1 risk. No cache or new index is part of this correction.
- [ ] Inspect the complete incremental correction and original ticket diff, secrets, exact base/head, and clean worktree. Append commit only, push #215, link it immediately, update PR/JC-255 evidence and return the issue to In Review. Include Performance & Scaling Review and Runtime Resource Safety Review.
- [ ] Read CI for the exact new head. If still pending, watch and hand back without merge or final approval. Parent #214 and descendants stay unchanged; their future propagation needs separate coordination and revalidation.
