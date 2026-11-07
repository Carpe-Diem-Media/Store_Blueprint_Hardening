# JC-248 reconciliation sweeps implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Rediscover durable grant drift and missing authority through bounded recurring PostgreSQL reads, independently of old job history.

**Architecture:** A facade operation reads an APPLIED key window and one active-grant batch, compares exact persisted targets in memory and returns bounded repair identities. Low-priority workers enqueue source repairs, continue raw cursors and periodically restart both APPLIED verification and diagnostic authority inventory. Existing nonterminal recovery remains unchanged.

**Tech stack:** Elixir, Ash 3, PostgreSQL, Oban 2.24.1, DevCore.

## Task 5: Batched verification and operational sweeps

Modify `lib/store/subscriptions/facade.ex`, `config/config.exs` and the effective execution test module. Create `lib/store/workers/verify_subscription_access_worker.ex` and `lib/store/workers/inventory_subscription_access_authority_worker.ex`. Use existing `ops` and `subscriptions` queues. No new pool, schema, dependency, global lock or business target.

- [ ] Add failing integration tests using the existing committed fixtures. Every source repair or worker call that might execute a correctness transaction runs through `Sandbox.unboxed_run`.

```elixir
test "verification batches healthy sources and returns only drift repair identities" do
  healthy = create_committed_effective_effect_fixture!("jc248_sweep_healthy")
  missing = create_committed_effective_effect_fixture!("jc248_sweep_missing")
  Sandbox.unboxed_run(Repo, fn ->
    for fixture <- [healthy, missing], do: Facade.execute_effective_access_effect_for_system(fixture.effect.id)
    Repo.query!("DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
      [Ecto.UUID.dump!(missing.subscription.id)])
    Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = ANY($1::uuid[])",
      [Enum.map([healthy, missing], &Ecto.UUID.dump!(&1.effect.id)), ~U[2020-01-01 00:00:00Z]])
  end)
  assert {:ok, query} = AppliedAccessVerificationQuery.new(%{as_of: ~U[2020-01-02 00:00:00Z], limit: 100})
  assert {{:ok, result}, stats} = RepoStats.capture(fn ->
    Facade.verify_subscription_access_window_for_system(query)
  end)
  assert stats.query_count == 2
  assert result.healthy_count == 1
  assert result.repairs == [%{subscription_id: missing.subscription.id,
    expected_access_effect_id: missing.effect.id}]
  assert result.conflicts == []
  assert result.cursor == nil
end
```

- [ ] Add a second query-count sample at 16 healthy sources, with 32 revoked history rows per source inserted directly as revoked. The two read count must remain constant. Isolate those fixtures in a fixed historical inserted_at window so unrelated private diagnostic rows cannot affect counts. Add a current fingerprint-valid funded-provenance mismatch and assert a conflict with zero repair candidates and no grant/effect mutation. Add an all-stale raw page of size 1 followed by a current mismatched APPLIED row; its cursor must advance and reach that row on the next page. Run RED and save `tmp/jc248/task5-red.log` before production code.

- [ ] Implement the facade page operation with these aliases and helpers. Reuse existing private immutable-provenance validators and input builder, so discovery does not invent another access policy. `SourceConvergence.validate_final_active_set/3` already checks exact owner, source, pair, persisted validity window and clear revocation fields. Do not compare validity to wall-clock `as_of`, normalize historical statuses or use cache contents.

```elixir
alias Store.Entitlements.Queries.SubscriptionSourceVerificationQuery
alias Store.Entitlements.SourceConvergence

@doc "Verifies one bounded APPLIED window and returns current source identities requiring repair."
@spec verify_subscription_access_window_for_system(AppliedAccessVerificationQuery.t()) ::
  {:ok, map()} | {:error, Error.t() | term()}
def verify_subscription_access_window_for_system(%AppliedAccessVerificationQuery{} = query) do
  with {:ok, canonical} <- AppliedAccessVerificationQuery.new(Map.from_struct(query)),
       {:ok, rows} <- list_applied_access_verification_window_for_system(canonical),
       ids <- rows |> Enum.filter(& &1.current?) |> Enum.map(& &1.source.subscription_id),
       {:ok, grants_query} <- SubscriptionSourceVerificationQuery.new(%{source_ids: ids}),
       {:ok, grants} <- EntitlementsFacade.list_active_subscription_source_grants_for_system(grants_query) do
    initial = %{raw_count: length(rows), current_count: 0, stale_count: 0,
      healthy_count: 0, repairs: [], conflicts: []}
    result = Enum.reduce(rows, initial, &verify_access_window_row(&1, &2, grants))
    {:ok, Map.merge(result, %{as_of: canonical.as_of,
      repairs: Enum.reverse(result.repairs), conflicts: Enum.reverse(result.conflicts),
      cursor: access_verification_cursor(rows, canonical.limit)})}
  end
end
def verify_subscription_access_window_for_system(_query),
  do: {:error, Error.new("VALIDATION_ERROR", "typed APPLIED verification query is required")}

defp verify_access_window_row(%{current?: false}, result, _grants),
  do: Map.update!(result, :stale_count, &(&1 + 1))
defp verify_access_window_row(row, result, grants) do
  result = Map.update!(result, :current_count, &(&1 + 1))
  case verified_snapshot_input(row) do
    {:ok, input} ->
      active_rows = Map.fetch!(grants, row.source.subscription_id)
      target_id = case active_rows do [grant] -> grant.id; _ -> nil end
      case SourceConvergence.validate_final_active_set(input, target_id, active_rows) do
        :ok -> Map.update!(result, :healthy_count, &(&1 + 1))
        {:error, _mismatch} -> Map.update!(result, :repairs, &[
          %{subscription_id: row.source.subscription_id, expected_access_effect_id: row.effect.id} | &1])
      end
    {:error, _reason} ->
      Map.update!(result, :conflicts, &[%{subscription_id: row.source.subscription_id,
        access_effect_id: row.effect.id, reason: :invalid_authority} | &1])
  end
end

defp verified_snapshot_input(%{effect: effect, source: source, revision: revision, contract_reference: reference}) do
  provenance = %{source_order_line_item_id: source.source_order_line_item_id,
    plan_revision_id: source.current_plan_revision_id,
    revision_entitlement_kind: revision.entitlement_kind && Atom.to_string(revision.entitlement_kind),
    revision_entitlement_scope_key: revision.entitlement_scope_key}
  with true <- effect.subscription_id == source.subscription_id,
       true <- is_integer(effect.source_version) and effect.source_version > 0 and
         is_integer(source.aggregate_version) and effect.source_version <= source.aggregate_version,
       true <- effect.status == :applied,
       true <- revision.id == effect.plan_revision_id,
       status when status in [:v2_match, :v1_legacy_match] <- AccessEffect.persisted_fingerprint_status(effect),
       :ok <- validate_persisted_access_effect_provenance(effect, provenance, reference) do
    applied_source_reconciliation_input(effect, source.subscription_id, source.user_id)
  else
    _ -> {:error, :invalid_authority}
  end
end
defp access_verification_cursor(rows, limit) when length(rows) == limit do
  last = List.last(rows).effect
  %{timestamp: last.inserted_at, id: last.id}
end
defp access_verification_cursor(_rows, _limit), do: nil
```

- [ ] Implement this APPLIED worker. The installed Oban Basic engine bypasses uniqueness in `insert_all`, so enqueue each bounded repair candidate with `Oban.insert`. Queue insertion failure retries the page. Existing completed/discarded jobs cannot suppress rediscovery because source jobs use finite uniqueness over incomplete states. The page cursor advances only after all candidate insertions succeed.

```elixir
defmodule Store.Workers.VerifySubscriptionAccessWorker do
  @moduledoc false
  use Oban.Worker, queue: :ops, priority: 3, max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args], states: :incomplete]
  require Logger
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Queries.AppliedAccessVerificationQuery
  alias Store.Workers.ReconcileSubscriptionAccessWorker
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, query} <- parse_query(args),
         {:ok, result} <- Facade.verify_subscription_access_window_for_system(query),
         :ok <- enqueue_repairs(result.repairs),
         :ok <- enqueue_continuation(result, query.limit) do
      report(result)
      :ok
    else
      {:discard, _reason} = discard -> discard
      {:error, reason} -> {:error, reason}
    end
  end
  def perform(_job), do: {:discard, "invalid access verification job"}
  defp parse_query(args) do
    with true <- Enum.all?(Map.keys(args), &(&1 in ["as_of", "after_inserted_at", "after_id", "limit"])),
         true <- Map.has_key?(args, "as_of") or not Map.has_key?(args, "after_id"),
         {:ok, as_of} <- as_of(args),
         {:ok, after_at} <- datetime(Map.get(args, "after_inserted_at"), nil),
         {:ok, query} <- AppliedAccessVerificationQuery.new(%{as_of: as_of,
           after_inserted_at: after_at, after_id: Map.get(args, "after_id"), limit: Map.get(args, "limit", 100)}) do
      {:ok, query}
    else
      _ -> {:discard, "invalid access verification bounds"}
    end
  end
  defp as_of(args) do
    case Map.fetch(args, "as_of") do
      :error -> {:ok, DateTime.utc_now()}
      {:ok, value} -> datetime(value, nil)
    end
  end
  defp datetime(nil, default), do: {:ok, default}
  defp datetime(value, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do {:ok, time, _offset} -> {:ok, time}; _ -> :error end
  end
  defp datetime(_value, _default), do: :error
  defp enqueue_repairs(repairs) do
    Enum.reduce_while(repairs, :ok, fn candidate, :ok ->
      case candidate |> ReconcileSubscriptionAccessWorker.new() |> Oban.insert() do
        {:ok, _job} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
  defp enqueue_continuation(%{cursor: nil}, _limit), do: :ok
  defp enqueue_continuation(%{as_of: as_of, cursor: cursor}, limit) do
    args = %{as_of: DateTime.to_iso8601(as_of), limit: limit,
      after_inserted_at: DateTime.to_iso8601(cursor.timestamp), after_id: cursor.id}
    case args |> new(schedule_in: 1) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
  defp report(result) do
    :telemetry.execute([:store, :subscriptions, :access_verification, :page],
      %{raw_count: result.raw_count, current_count: result.current_count, stale_count: result.stale_count,
        healthy_count: result.healthy_count, repair_count: length(result.repairs), conflict_count: length(result.conflicts)}, %{})
    for conflict <- result.conflicts do
      Logger.error("subscription_access_authority_conflict", subscription_id: conflict.subscription_id,
        access_effect_id: conflict.access_effect_id, reason: conflict.reason)
      :telemetry.execute([:store, :subscriptions, :access_verification, :conflict], %{count: 1}, conflict)
    end
  end
end
```

- [ ] Implement this inventory worker. Missing rows remain unclassified. It records IDs and available immutable provenance only; it never enqueues a source repair, writes grants, creates effects or changes aggregate versions.

```elixir
defmodule Store.Workers.InventorySubscriptionAccessAuthorityWorker do
  @moduledoc false
  use Oban.Worker, queue: :ops, priority: 3, max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args], states: :incomplete]
  require Logger
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery
  alias Store.Support.Errors.Error
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, query} <- parse_query(args),
         {:ok, rows} <- read_window(query),
         :ok <- enqueue_continuation(rows, query) do
      missing = Enum.reject(rows, & &1.has_access_effect?)
      :telemetry.execute([:store, :subscriptions, :access_authority_inventory, :page],
        %{raw_count: length(rows), missing_count: length(missing)}, %{})
      for row <- missing do
        metadata = %{subscription_id: row.id, classification: :unclassified,
          source_order_line_item_id: row.source_order_line_item_id,
          contract_change_id: row.current_contract_change_id, plan_revision_id: row.current_plan_revision_id}
        Logger.warning("subscription_access_authority_missing", Map.to_list(metadata))
        :telemetry.execute([:store, :subscriptions, :access_authority_inventory, :missing], %{count: 1}, metadata)
      end
      :ok
    else
      {:discard, _reason} = discard -> discard
      {:error, reason} -> {:error, reason}
    end
  end
  def perform(_job), do: {:discard, "invalid access authority inventory job"}
  defp parse_query(args) do
    with true <- Enum.all?(Map.keys(args), &(&1 in ["through_id", "after_id", "limit"])),
         true <- Map.has_key?(args, "through_id") or not Map.has_key?(args, "after_id"),
         limit <- Map.get(args, "limit", 100),
         true <- is_integer(limit) and limit in 1..500,
         {:ok, upper} <- upper_bound(args) do
      if is_nil(upper) do
        {:ok, nil}
      else
        case SubscriptionAccessInventoryQuery.new(%{
               through_id: upper, after_id: Map.get(args, "after_id"), limit: limit}) do
          {:ok, query} -> {:ok, query}
          {:error, _reason} -> {:discard, "invalid access authority inventory bounds"}
        end
      end
    else
      false -> {:discard, "invalid access authority inventory bounds"}
      {:error, %Error{code: "VALIDATION_ERROR"}} -> {:discard, "invalid access authority inventory bounds"}
      {:error, reason} -> {:error, reason}
    end
  end
  defp upper_bound(%{"through_id" => id}) when is_binary(id), do: {:ok, id}
  defp upper_bound(%{"through_id" => _id}),
    do: {:error, Error.new("VALIDATION_ERROR", "invalid inventory upper bound")}
  defp upper_bound(_args), do: Facade.subscription_access_inventory_upper_bound_for_system()
  defp read_window(nil), do: {:ok, []}
  defp read_window(query), do: Facade.list_subscription_access_inventory_window_for_system(query)
  defp enqueue_continuation(_rows, nil), do: :ok
  defp enqueue_continuation(rows, query) when length(rows) == query.limit do
    args = %{through_id: query.through_id, after_id: List.last(rows).id, limit: query.limit}
    case args |> new(schedule_in: 1) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
  defp enqueue_continuation(_rows, _query), do: :ok
end
```

- [ ] Add daily crons `{"0 0 * * *", Store.Workers.VerifySubscriptionAccessWorker}` and `{"30 0 * * *", Store.Workers.InventorySubscriptionAccessAuthorityWorker}`. The cron's existing UTC clock schedules these at 02:00 and 02:30 South Africa time. Both use priority 3 in the existing ops queue. Continuations delay one second and retain fixed bounds. This bounds each unit of work; it does not assert a production sweep duration or guarantee completion before peak hours.

- [ ] Add worker integration tests with Oban manual testing and actual persisted jobs: lost initial source enqueue is rediscovered from PostgreSQL mismatch; repeated verification creates at most one incomplete source job inside the 55-second window; completed/discarded source jobs do not suppress a new repair; deleting an operational continuation then restarting the initial window repeats safe work and reaches the mismatch; all-stale raw pages still enqueue a continuation with the same `as_of`; inventory healthy pages continue and missing rows only emit unclassified telemetry. Invalid/half cursor arguments cannot silently reset progress. Capture worker RED before implementing each new behavior, then GREEN.
- [ ] Add telemetry assertions for page counts and conflict/missing outcomes. Remove handlers in `after`. Do not expose raw source/provider payloads or customer details. All event metadata remains IDs and fixed outcome classes.
- [ ] Run format, scoped strict Credo, compile warnings-as-errors, focused execution modules and migration alignment. Self-review and commit task-owned files. Separate spec and quality review follow, then a final task supplies real concurrency, two-repeat resource measurements and full repository gates.

Use only sequential Mix commands under:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix`

Root self-review must verify query/input names against the accepted earlier tasks before dispatch. Exact page bounds and database truth govern execution. No queue state is business completion and no missing-authority backfill is authorized.
