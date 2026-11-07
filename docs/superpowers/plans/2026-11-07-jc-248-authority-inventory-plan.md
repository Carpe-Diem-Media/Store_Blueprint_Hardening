# JC-248 authority inventory implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Read bounded Subscription windows and report whether a durable AccessEffect exists without creating authority or modifying access.

**Architecture:** Capture a fixed upper Subscription UUID through Ash. Read a raw primary-key window before checking effect existence through a private system-only Ash generic action. Return every raw row so healthy rows cannot prevent cursor progress.

**Tech stack:** Elixir, Ash 3, Ecto, PostgreSQL, DevCore.

## Task 4: Diagnostic inventory reads

Create `lib/store/subscriptions/queries/subscription_access_inventory_query.ex` and `lib/store/subscriptions/actions/read_subscription_access_inventory_window.ex`. Modify the Subscription resource, facade and existing effective execution test module. No migration is required: Subscription's primary key bounds the window and the existing AccessEffect subscription/source-version index supports each existence probe. Do not add a sweep worker or classify absent effects as a proven transition defect.

- [ ] Add the inventory query alias and these tests before production code. Existing committed fixture cleanup remains unchanged.

```elixir
alias Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery

test "authority inventory validates fixed UUID bounds" do
  [first, last] = Store.Support.ID.BinaryUuidSort.sort_uuids([Ecto.UUID.generate(), Ecto.UUID.generate()])
  assert {:ok, _} = SubscriptionAccessInventoryQuery.new(%{through_id: last, after_id: first, limit: 1})
  for attrs <- [%{through_id: "bad"}, %{through_id: first, after_id: last},
                %{through_id: last, limit: 501}, %{through_id: last, status: :active}] do
    assert {:error, %Error{code: "VALIDATION_ERROR"}} = SubscriptionAccessInventoryQuery.new(attrs)
  end
end

test "authority inventory consumes healthy raw rows and exposes missing authority without writes" do
  fixtures = for index <- 1..3, do: create_committed_effective_effect_fixture!("jc248_inventory_#{index}")
  ordered = Enum.sort_by(fixtures, &Ecto.UUID.dump!(&1.subscription.id))
  [healthy, missing, later] = ordered
  Sandbox.unboxed_run(Repo, fn ->
    Repo.query!("DELETE FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(missing.effect.id)])
  end)
  before = source_identity_snapshot!(missing.subscription.id)
  <<numeric_id::unsigned-big-integer-size(128)>> = Ecto.UUID.dump!(healthy.subscription.id)
  predecessor = Ecto.UUID.load!(<<(numeric_id - 1)::unsigned-big-integer-size(128)>>)
  assert {:ok, first} = SubscriptionAccessInventoryQuery.new(%{
    through_id: missing.subscription.id, after_id: predecessor, limit: 1})
  assert {{:ok, [%{id: healthy_id, has_access_effect?: true}] = page}, stats} =
    RepoStats.capture(fn -> Facade.list_subscription_access_inventory_window_for_system(first) end)
  assert healthy_id == healthy.subscription.id
  assert stats.query_count == 1
  assert {:ok, after_healthy} = SubscriptionAccessInventoryQuery.new(%{
    through_id: missing.subscription.id, after_id: healthy.subscription.id, limit: 1})
  assert {:ok, [%{id: missing_id, has_access_effect?: false}]} =
    Facade.list_subscription_access_inventory_window_for_system(after_healthy)
  assert missing_id == missing.subscription.id
  assert {:ok, done} = SubscriptionAccessInventoryQuery.new(%{
    through_id: missing.subscription.id, after_id: missing.subscription.id, limit: 1})
  assert {:ok, []} = Facade.list_subscription_access_inventory_window_for_system(done)
  assert source_identity_snapshot!(missing.subscription.id) == before
  assert grants_for_source!(missing.subscription.id) == []
  assert {:ok, nil} = Facade.get_current_access_effect_for_system(missing.subscription)
  refute later.subscription.id in Enum.map(page, & &1.id)
end
```

- [ ] Add raw-action authorization coverage with `RepoStats.capture`, asserting no-system context is FORBIDDEN and issues zero SQL. Capture RED at `tmp/jc248/task4-red.log` before production changes.

```elixir
test "authority inventory action rejects ordinary callers before SQL" do
  input = Ash.ActionInput.for_action(Subscription, :read_access_inventory_window_for_system,
    %{through_id: Ecto.UUID.generate(), limit: 1}, domain: Store.Subscriptions)
  assert {:ok, stats} = RepoStats.capture(fn ->
    assert {:error, reason} = Ash.run_action(input, authorize?: true)
    assert %Error{code: "FORBIDDEN"} = Normalize.normalize(reason)
    :ok
  end)
  assert stats.query_count == 0
end

test "authority inventory captures the database's native highest UUID" do
  _fixture = create_committed_effective_effect_fixture!("jc248_inventory_frontier")
  %{rows: [[expected]]} = Repo.query!("SELECT id::text FROM subscriptions ORDER BY id DESC LIMIT 1")
  assert {:ok, ^expected} = Facade.subscription_access_inventory_upper_bound_for_system()
end
```

- [ ] Implement this typed query. UUID comparison uses dumped binary values in validation and PostgreSQL UUID comparison in SQL.

```elixir
defmodule Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery do
  @moduledoc "Fixed UUID bounds for diagnostic Subscription authority inventory."
  import Ecto.Query
  alias Store.Subscriptions.{AccessEffect, Subscription}
  alias Store.Support.Errors.Error
  @enforce_keys [:through_id]
  defstruct [:through_id, :after_id, limit: 100]
  @type t :: %__MODULE__{through_id: Ecto.UUID.t(), after_id: Ecto.UUID.t() | nil, limit: pos_integer()}
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{through_id: through_id} = attrs) do
    with true <- Enum.all?(Map.keys(attrs), &(&1 in [:through_id, :after_id, :limit])),
         {:ok, upper} <- Ecto.UUID.cast(through_id),
         {:ok, after_id} <- optional_uuid(Map.get(attrs, :after_id)),
         limit <- Map.get(attrs, :limit, 100),
         true <- is_integer(limit) and limit in 1..500,
         true <- is_nil(after_id) or Ecto.UUID.dump!(after_id) <= Ecto.UUID.dump!(upper) do
      {:ok, %__MODULE__{through_id: upper, after_id: after_id, limit: limit}}
    else
      _ -> invalid()
    end
  end
  def new(_attrs), do: invalid()
  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(id), do: Ecto.UUID.cast(id)
  defp invalid, do: {:error, Error.new("VALIDATION_ERROR", "invalid subscription authority inventory bounds")}
  @doc false
  @spec to_ecto(t()) :: Ecto.Query.t()
  def to_ecto(%__MODULE__{} = query) do
    window = from source in Subscription,
      where: source.id <= ^query.through_id, order_by: [asc: source.id], limit: ^query.limit
    window = if query.after_id, do: where(window, [source], source.id > ^query.after_id), else: window
    effects = from effect in AccessEffect,
      where: effect.subscription_id == parent_as(:source).id, select: 1
    from source in subquery(window), as: :source, order_by: [asc: source.id],
      select: %{id: source.id, user_id: source.user_id, aggregate_version: source.aggregate_version,
        source_order_line_item_id: source.source_order_line_item_id,
        current_contract_change_id: source.current_contract_change_id,
        current_plan_revision_id: source.current_plan_revision_id,
        has_access_effect?: exists(subquery(effects))}
  end
end
```

- [ ] Add this private generic action and its specific system-context runtime policy to `Subscription`. Generic actions do not use the existing read-action policy.

```elixir
action :read_access_inventory_window_for_system, {:array, :map} do
  public?(false)
  transaction?(false)
  argument :through_id, :uuid, allow_nil?: false
  argument :after_id, :uuid, allow_nil?: true
  argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 500]
  run(Store.Subscriptions.Actions.ReadSubscriptionAccessInventoryWindow)
end

policy action(:read_access_inventory_window_for_system) do
  access_type(:runtime)
  authorize_if(context_equals(:system?, true))
end
```

- [ ] Implement the action callback and facade reads.

```elixir
defmodule Store.Subscriptions.Actions.ReadSubscriptionAccessInventoryWindow do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Store.Repo
  alias Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery
  @impl true
  def run(input, _opts, _context) do
    with {:ok, query} <- SubscriptionAccessInventoryQuery.new(input.arguments) do
      {:ok, Repo.all(SubscriptionAccessInventoryQuery.to_ecto(query))}
    end
  end
end

# Add the query alias to the facade.
@doc "Reads a fixed Subscription key window and reports AccessEffect existence without mutation."
@spec list_subscription_access_inventory_window_for_system(SubscriptionAccessInventoryQuery.t()) ::
  {:ok, [map()]} | {:error, Error.t() | term()}
def list_subscription_access_inventory_window_for_system(%SubscriptionAccessInventoryQuery{} = query) do
  with {:ok, canonical} <- SubscriptionAccessInventoryQuery.new(Map.from_struct(query)) do
    input = Ash.ActionInput.for_action(Subscription, :read_access_inventory_window_for_system,
      Map.from_struct(canonical), domain: Subscriptions, context: %{system?: true})
    case Ash.run_action(input, domain: Subscriptions, authorize?: true) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end
end
def list_subscription_access_inventory_window_for_system(_query),
  do: {:error, Error.new("VALIDATION_ERROR", "typed authority inventory query is required")}

@doc "Captures the current highest Subscription UUID as an operational inventory bound."
@spec subscription_access_inventory_upper_bound_for_system() ::
  {:ok, Ecto.UUID.t() | nil} | {:error, Error.t() | term()}
def subscription_access_inventory_upper_bound_for_system do
  query = Subscription |> Ash.Query.sort(id: :desc) |> Ash.Query.limit(1) |> Ash.Query.select([:id])
  case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
    {:ok, nil} -> {:ok, nil}
    {:ok, %Subscription{id: id}} -> {:ok, id}
    {:error, reason} -> {:error, Normalize.normalize(reason)}
  end
end
```

- [ ] Run GREEN, then capture inventory SQL and `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` through the typed query's `to_ecto/1`. Assert a healthy window has one SQL query regardless of its absent-effect count, every raw row consumes the limit, and the upper bound excludes later fixture UUIDs. Add exact frontier read assertion against a DB-native highest-ID query as test-only evidence. Do not use `max(uuid)`, OFFSET, absence filtering before the raw limit, forced planner settings or production full-table scans.
- [ ] Run format, scoped strict Credo, compile warnings-as-errors and both execution modules. No migration/snapshot drift is expected. Review complete diff and commit only task files. Independent spec then quality review follow.

Every Mix command uses the existing isolated DevCore test environment sequentially:

`MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix`

Focused command arguments are `test test/store/subscriptions/access_effect_effective_execution_test.exs test/store/subscriptions/access_effect_non_effective_execution_test.exs`. Capture task logs under `tmp/jc248`. Do not expose credentials or delete unrelated fixtures.
