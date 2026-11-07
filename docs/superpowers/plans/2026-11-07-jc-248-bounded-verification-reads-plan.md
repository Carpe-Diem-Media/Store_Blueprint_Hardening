# JC-248 bounded verification reads implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Read a bounded APPLIED key window with currentness evidence and at most two active grants per requested source in two database round trips.

**Architecture:** Typed domain queries validate all bounds before Ecto reads. The APPLIED query retains stale rows so the caller can advance through the complete bounded window. The Entitlements query uses a typed UUID array and a lateral LIMIT 2 query, preserving empty sources in its result map. The later sweep task compares these read results and enqueues isolated repairs.

**Tech stack:** Existing Ash resources, Ecto 3.14, PostgreSQL, DevCore. No dependency, service, pool, queue or lifecycle changes.

## Task 2: Bounded query contracts and indexes

Create `lib/store/subscriptions/queries/applied_access_verification_query.ex` and `lib/store/entitlements/queries/subscription_source_verification_query.ex`. Modify both domain facades, both resource index declarations, and the existing effective execution test module. Generate only the required index migrations and corresponding resource snapshots.

- [ ] Add regression tests using the existing committed fixtures and helpers. Add aliases for the two new query modules. Use these test bodies before implementing the modules.

```elixir
test "JC248 verification rejects invalid bounds and incomplete cursors before database work" do
  as_of = ~U[2020-01-01 00:00:00Z]
  for attrs <- [
        %{as_of: as_of, limit: 0},
        %{as_of: as_of, limit: 501},
        %{as_of: as_of, after_inserted_at: as_of},
        %{as_of: as_of, after_id: Ash.UUIDv7.generate()},
        %{as_of: as_of, after_inserted_at: as_of, after_id: "bad"}
      ] do
    assert {:error, %{code: "VALIDATION_ERROR"}} = AppliedAccessVerificationQuery.new(attrs)
  end
  assert {:error, %{code: "VALIDATION_ERROR"}} =
    SubscriptionSourceVerificationQuery.new(%{source_ids: ["bad"]})
  assert {:error, %{code: "VALIDATION_ERROR"}} =
    SubscriptionSourceVerificationQuery.new(%{source_ids: List.duplicate(Ash.UUIDv7.generate(), 501)})
end

test "JC248 verification advances a bounded stale window before the current target" do
  stale = create_committed_effective_effect_fixture!("jc248_window_stale")
  current = create_committed_effective_effect_fixture!("jc248_window_current", target: :empty,
    disposition: :non_effective)
  first_time = ~U[2020-01-01 00:00:00Z]
  second_time = DateTime.add(first_time, 1, :second)
  as_of = DateTime.add(first_time, 2, :second)
  Sandbox.unboxed_run(Repo, fn ->
    for fixture <- [stale, current] do
      assert {:ok, pending} = Facade.mark_access_effect_pending_for_system(fixture.effect)
      assert {:ok, _applied} = Facade.mark_access_effect_applied_for_system(pending)
    end
    create_newer_untransitioned_effect!(stale)
    Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(stale.effect.id), first_time])
    Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(current.effect.id), second_time])
  end)
  assert {:ok, query} = AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 1})
  assert {:ok, [row]} = Facade.list_applied_access_verification_window_for_system(query)
  assert row.effect.id == stale.effect.id
  refute row.current?
  assert {:ok, next} = AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 1,
    after_inserted_at: row.effect.inserted_at, after_id: row.effect.id})
  assert {:ok, [next_row]} = Facade.list_applied_access_verification_window_for_system(next)
  assert next_row.effect.id == current.effect.id
  assert next_row.current?
  assert next_row.effect.disposition == :non_effective
  assert next_row.source.user_id == current.subscription.user_id
  assert %DateTime{} = next_row.effect.inserted_at
end

test "JC248 batch grant reads bound each source and preserve empty sources" do
  fixture = create_committed_effective_effect_fixture!("jc248_batch_many")
  empty = create_committed_effective_effect_fixture!("jc248_batch_empty")
  Sandbox.unboxed_run(Repo, fn ->
    insert_historical_grants!(fixture, 128)
  end)
  assert {:ok, query} = SubscriptionSourceVerificationQuery.new(%{
    source_ids: [fixture.subscription.id, empty.subscription.id]})
  assert {{:ok, sources}, stats} = RepoStats.capture(fn ->
    EntitlementsFacade.list_active_subscription_source_grants_for_system(query)
  end)
  assert stats.query_count == 1
  assert map_size(sources) == 2
  assert length(sources[fixture.subscription.id]) == 2
  assert sources[empty.subscription.id] == []
  assert Enum.all?(sources[fixture.subscription.id], fn row ->
    row.source_id == fixture.subscription.id and row.source_kind == :subscription and
      row.status == :active and match?(%DateTime{}, row.valid_from_at)
  end)
  assert {:ok, empty_query} = SubscriptionSourceVerificationQuery.new(%{source_ids: []})
  assert {{:ok, %{}}, empty_stats} = RepoStats.capture(fn ->
    EntitlementsFacade.list_active_subscription_source_grants_for_system(empty_query)
  end)
  assert empty_stats.query_count == 0
end
```

- [ ] Run the complete effective execution test module to RED before implementation, preserving `tmp/jc248/task2-red.log`. Failures must identify missing query/read behavior, not a fixture defect. The raw SQL fixture timestamp updates above use the same DateTime parameter convention as existing tests; diagnose any codec mismatch before drawing a product conclusion.

- [ ] Implement the APPLIED query module below. The inner LIMIT precedes the latest-source check. Both dispositions are included. Ecto resource selection must preserve typed AccessEffect/Subscription/PlanRevision fields. If the installed Ecto planner rejects a nested selection, preserve the same bounded shape with an explicit typed field map and reconstruct only the known AccessEffect fields, then add an integration assertion for that representation.

```elixir
defmodule Store.Subscriptions.Queries.AppliedAccessVerificationQuery do
  @moduledoc "Typed bounds for one immutable APPLIED effect scan window."
  import Ecto.Query, only: [from: 2, subquery: 1]
  alias Store.Subscriptions.{AccessEffect, PlanRevision, Subscription}
  alias Store.Support.Errors.Error
  @enforce_keys [:as_of]
  defstruct [:as_of, :after_inserted_at, :after_id, limit: 100]
  @type t :: %__MODULE__{as_of: DateTime.t(), after_inserted_at: DateTime.t() | nil,
    after_id: Ecto.UUID.t() | nil, limit: pos_integer()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{as_of: %DateTime{} = as_of} = params) do
    limit = Map.get(params, :limit, 100)
    with true <- Enum.all?(Map.keys(params), &(&1 in [:as_of, :after_inserted_at, :after_id, :limit])),
         true <- is_integer(limit) and limit in 1..500,
         {:ok, timestamp, id} <- cursor(params),
         true <- is_nil(timestamp) or DateTime.compare(timestamp, as_of) != :gt do
      {:ok, %__MODULE__{as_of: utc(as_of), after_inserted_at: timestamp, after_id: id, limit: limit}}
    else
      _ -> invalid()
    end
  end
  def new(_params), do: invalid()
  defp cursor(params) do
    case {Map.get(params, :after_inserted_at), Map.get(params, :after_id)} do
      {nil, nil} -> {:ok, nil, nil}
      {%DateTime{} = timestamp, id} when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, exact_id} -> {:ok, utc(timestamp), exact_id}
          :error -> invalid()
        end
      _ -> invalid()
    end
  end
  defp utc(datetime), do: DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  defp invalid, do: {:error, Error.new("VALIDATION_ERROR", "invalid APPLIED verification query")}

  @doc false
  @spec to_ecto(t()) :: Ecto.Query.t()
  def to_ecto(query) do
    window = from effect in AccessEffect,
      where: fragment("? = 'applied'", effect.status) and effect.inserted_at <= ^query.as_of,
      order_by: [asc: effect.inserted_at, asc: effect.id], limit: ^query.limit
    window = after_cursor(window, query)
    newer = from other in AccessEffect,
      where: other.subscription_id == parent_as(:effect).subscription_id and
        other.source_version > parent_as(:effect).source_version,
      select: 1
    from effect in subquery(window), as: :effect,
      join: source in Subscription, on: source.id == effect.subscription_id,
      left_join: revision in PlanRevision, on: revision.id == source.current_plan_revision_id,
      order_by: [asc: effect.inserted_at, asc: effect.id],
      select: %{effect: effect, current?: not exists(subquery(newer)),
        source: %{subscription_id: source.id, user_id: source.user_id,
          aggregate_version: source.aggregate_version,
          source_order_line_item_id: source.source_order_line_item_id,
          current_contract_change_id: source.current_contract_change_id,
          current_plan_revision_id: source.current_plan_revision_id},
        revision: %{id: revision.id, entitlement_kind: revision.entitlement_kind,
          entitlement_scope_key: revision.entitlement_scope_key}}
  end
  defp after_cursor(window, %{after_inserted_at: nil}), do: window
  defp after_cursor(window, query) do
    from effect in window,
      where: effect.inserted_at > ^query.after_inserted_at or
        (effect.inserted_at == ^query.after_inserted_at and effect.id > ^query.after_id)
  end
end
```

- [ ] Implement the Entitlements query module below. The explicit type is `Ecto.UUID`, not `:uuid`. The installed Ecto.Type base list does not include `:uuid`; its documentation maps the Ecto.UUID module to the adapter UUID type. Ecto 3.14's own query documentation contains the UNNEST plus correlated parent_as lateral pattern.

```elixir
defmodule Store.Entitlements.Queries.SubscriptionSourceVerificationQuery do
  @moduledoc "Typed source identities for bounded active-grant verification reads."
  import Ecto.Query, only: [from: 2, subquery: 1]
  alias Store.Entitlements.EntitlementGrant
  alias Store.Support.Errors.Error
  @enforce_keys [:source_ids]
  defstruct [:source_ids]
  @type t :: %__MODULE__{source_ids: [Ecto.UUID.t()]}
  @fields [:id, :user_id, :kind, :scope_key, :source_kind, :source_id, :status,
    :valid_from_at, :valid_to_at, :revoked_at, :revoked_reason]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{source_ids: ids} = params) when is_list(ids) and length(ids) <= 500 do
    with true <- Map.keys(params) == [:source_ids],
         {:ok, canonical} <- cast_ids(ids) do
      {:ok, %__MODULE__{source_ids: Enum.uniq(canonical)}}
    else
      _ -> invalid()
    end
  end
  def new(_params), do: invalid()
  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, exact_id} -> {:cont, {:ok, [exact_id | acc]}}
        :error -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, Enum.reverse(canonical)}
      error -> error
    end
  end
  defp invalid, do: {:error, Error.new("VALIDATION_ERROR", "invalid subscription source verification query")}

  @doc false
  @spec to_ecto(t()) :: Ecto.Query.t()
  def to_ecto(query) do
    ids = query.source_ids
    fields = @fields
    grants = from grant in EntitlementGrant,
      where: fragment("? = 'subscription' AND ? = 'active'", grant.source_kind, grant.status),
      where: grant.source_id == type(parent_as(:requested).id, Ecto.UUID),
      order_by: [asc: grant.id], limit: 2, select: map(grant, ^fields)
    from requested in fragment("SELECT unnest(?::uuid[]) AS id", type(^ids, {:array, Ecto.UUID})),
      as: :requested, inner_lateral_join: grant in subquery(grants), on: true, select: grant
  end
end
```

- [ ] Add public, documented/typespecified facade reads using the corresponding aliases. Revalidate structs before executing Ecto. Neither read locks rows or makes repair decisions. Database exceptions retain the repository's normal Ecto behavior.

```elixir
# Subscriptions facade
@spec list_applied_access_verification_window_for_system(AppliedAccessVerificationQuery.t()) ::
  {:ok, [map()]} | {:error, Error.t()}
def list_applied_access_verification_window_for_system(%AppliedAccessVerificationQuery{} = query) do
  with {:ok, canonical} <- AppliedAccessVerificationQuery.new(Map.from_struct(query)) do
    {:ok, Repo.all(AppliedAccessVerificationQuery.to_ecto(canonical))}
  end
end
def list_applied_access_verification_window_for_system(_query),
  do: {:error, Error.new("VALIDATION_ERROR", "typed APPLIED verification query is required")}

# Entitlements facade
@spec list_active_subscription_source_grants_for_system(SubscriptionSourceVerificationQuery.t()) ::
  {:ok, %{Ecto.UUID.t() => [map()]}} | {:error, Error.t()}
def list_active_subscription_source_grants_for_system(%SubscriptionSourceVerificationQuery{} = query) do
  with {:ok, canonical} <- SubscriptionSourceVerificationQuery.new(Map.from_struct(query)) do
    groups = Map.new(canonical.source_ids, &{&1, []})
    rows = if canonical.source_ids == [], do: [],
      else: Repo.all(SubscriptionSourceVerificationQuery.to_ecto(canonical))
    {:ok, Enum.reduce(rows, groups, fn row, acc ->
      Map.update!(acc, row.source_id, &[row | &1])
    end)}
  end
end
def list_active_subscription_source_grants_for_system(_query),
  do: {:error, Error.new("VALIDATION_ERROR", "typed subscription source verification query is required")}
```

- [ ] Run the focused module to GREEN. Add the following cursor and diagnostic tests, then re-run the complete module. The diagnostic test runs before and after adding the indexes, with distinct log files. Do not mistake a fixture-sized sequential plan for production capacity evidence.

```elixir
test "JC248 verification uses binary UUID ties and a fixed high-water" do
  left = create_committed_effective_effect_fixture!("jc248_tie_left")
  right = create_committed_effective_effect_fixture!("jc248_tie_right")
  future = create_committed_effective_effect_fixture!("jc248_tie_future")
  timestamp = ~U[2021-01-01 00:00:00Z]
  as_of = DateTime.add(timestamp, 1, :second)
  Sandbox.unboxed_run(Repo, fn ->
    for fixture <- [left, right, future] do
      assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
      inserted_at = if fixture.effect.id == future.effect.id,
        do: DateTime.add(timestamp, 2, :second), else: timestamp
      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1",
        [Ecto.UUID.dump!(fixture.effect.id), inserted_at])
    end
  end)
  [first_id, second_id] = Store.Support.ID.BinaryUuidSort.sort_uuids([left.effect.id, right.effect.id])
  assert {:ok, query} = AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 1})
  assert {:ok, [%{effect: %{id: ^first_id}} = first]} =
    Facade.list_applied_access_verification_window_for_system(query)
  assert {:ok, next} = AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 1,
    after_inserted_at: first.effect.inserted_at, after_id: first_id})
  assert {:ok, [%{effect: %{id: ^second_id}}]} =
    Facade.list_applied_access_verification_window_for_system(next)
  assert {:ok, all} = AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 500})
  assert {:ok, rows} = Facade.list_applied_access_verification_window_for_system(all)
  assert Enum.map(rows, & &1.effect.id) == [first_id, second_id]
end

test "JC248 records verification plans with bounded historical source fanout" do
  fixture = create_committed_effective_effect_fixture!("jc248_query_plans")
  Sandbox.unboxed_run(Repo, fn ->
    insert_historical_grants!(fixture, 128)
    assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
  end)
  assert {:ok, effects} = AppliedAccessVerificationQuery.new(%{as_of: DateTime.utc_now(), limit: 2})
  assert {:ok, grants} = SubscriptionSourceVerificationQuery.new(%{source_ids: [fixture.subscription.id]})
  queries = [
    {:applied_window, AppliedAccessVerificationQuery.to_ecto(effects)},
    {:active_source_grants, SubscriptionSourceVerificationQuery.to_ecto(grants)}
  ]
  for {operation, query} <- queries do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
    plan = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params).rows
    IO.puts(Jason.encode!(%{tag: "JC248_VERIFICATION_QUERY_PLAN", operation: operation,
      historical_source_rows: 128, sql: sql, plan: plan,
      limits: "bounded fixture evidence; no production planner or capacity claim"}))
  end
  assert {{:ok, rows}, stats} = RepoStats.capture(fn ->
    EntitlementsFacade.list_active_subscription_source_grants_for_system(grants)
  end)
  assert length(rows[fixture.subscription.id]) == 1
  assert stats.query_count == 1
end
```
- [ ] Add these two custom indexes in the existing resource DSL. Both are operational read indexes; they do not change business authority. The existing source-version unique index handles each bounded latest-version check. The new active partial index avoids scanning/sorting the full revoked source history for LIMIT 2.

```elixir
# AccessEffect postgres/custom_indexes
index([:inserted_at, :id], where: "status = 'applied'",
  name: "access_effects_applied_verification_index", concurrently: true)

# EntitlementGrant postgres/custom_indexes
index([:source_id, :id], where: "source_kind = 'subscription' AND status = 'active'",
  name: "entitlement_grants_active_subscription_source_index", concurrently: true)
```

- [ ] Generate the aligned migration/snapshots with `mix ash_postgres.generate_migrations --name jc248_access_verification_indexes`. The installed generator emits `@disable_ddl_transaction true` and `@disable_migration_lock true` for concurrent indexes. Inspect the complete generated diff; stop for unexpected unrelated schema drift. Re-run the focused module, `mix ash_postgres.generate_migrations --check`, format checks and strict Credo. Capture the indexed plans and verify native UUID ordering, bounded inner APPLIED LIMIT and lateral LIMIT 2. Record small-volume planner choices honestly.
- [ ] Self-review all changed files and commit this task. Do not enqueue repairs, add a cron, implement missing-authority inventory or complete JC-248 yet. Separate specification and quality reviews follow.

All Mix commands run sequentially through this exact environment, replacing only the final command:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/access_effect_effective_execution_test.exs`

The query API only reads. Stale/current flags and source snapshots are diagnostic until a later source-fenced repair revalidates authority. This task makes no runtime capacity or production index-build duration claim.
