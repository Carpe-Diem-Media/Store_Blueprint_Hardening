defmodule Store.Subscriptions.AccessEffectEffectiveRecoveryTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.Cache
  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  @through_updated_at ~U[2026-10-20 12:00:00.000000Z]

  setup context do
    StripeAPIStub.setup_default(context)
  end

  @tag :jc360_task07
  test "EFFECTIVE recovery includes only required, pending, and retryable EFFECTIVE rows" do
    required = create_effect!(:effective)
    pending = create_effect!(:effective) |> transition_to!(:pending)
    failed = create_effect!(:effective) |> transition_to!(:failed_retryable)
    applied = create_effect!(:effective) |> transition_to!(:applied)

    superseded_fixture = create_subscription_fixture!()
    superseded = create_effect!(superseded_fixture, :effective)
    superseding = supersede_with_newer_effect!(superseded_fixture)
    non_effective = create_effect!(:non_effective)

    set_updated_at!(
      [required, pending, failed, applied, superseded, superseding, non_effective],
      ~U[2026-10-20 11:00:00.000000Z]
    )

    assert fetch_effect!(superseded.id).status == :superseded
    assert fetch_effect!(superseding.id).status == :applied

    ids =
      read_effects!(
        limit: 100,
        through_updated_at: @through_updated_at
      )
      |> Enum.map(& &1.id)
      |> MapSet.new()

    assert ids == MapSet.new([required.id, pending.id, failed.id])
    refute applied.id in ids
    refute superseded.id in ids
    refute non_effective.id in ids
  end

  @tag :jc360_task07
  test "EFFECTIVE recovery read uses its default page limit of 100" do
    query =
      AccessEffect
      |> Ash.Query.for_read(:read_recoverable_effective_for_system, %{
        through_updated_at: @through_updated_at
      })

    assert query.arguments.limit == 100
  end

  @tag :jc360_task07
  test "the through timestamp includes equality and excludes newer updates" do
    eligible = create_effect!(:effective)
    later = create_effect!(:effective)

    set_updated_at!(
      [eligible],
      ~U[2026-10-20 12:00:00.000000Z]
    )

    set_updated_at!([later], ~U[2026-10-20 12:00:00.000001Z])

    assert [selected] =
             read_effects!(
               limit: 100,
               through_updated_at: @through_updated_at
             )

    assert selected.id == eligible.id
  end

  @tag :jc360_task07
  test "the updated_at and id cursor paginates tied timestamps without gaps or duplicates" do
    effects = Enum.map(1..4, fn _ -> create_effect!(:effective) end)
    tied_at = ~U[2026-10-20 10:30:00.123456Z]
    set_updated_at!(effects, tied_at)

    all_rows = read_effects!(limit: 500, through_updated_at: @through_updated_at)

    assert length(all_rows) == 4
    assert Enum.all?(all_rows, &(&1.updated_at == tied_at))
    assert_binary_uuid_order!(all_rows)

    assert {:ok, first_page} =
             read_effects(
               limit: 2,
               through_updated_at: @through_updated_at
             )

    last = List.last(first_page)

    assert {:ok, second_page} =
             read_effects(
               limit: 2,
               through_updated_at: @through_updated_at,
               after_updated_at: last.updated_at,
               after_id: last.id
             )

    page_ids = Enum.map(first_page ++ second_page, & &1.id)
    all_ids = Enum.map(all_rows, & &1.id)

    assert page_ids == all_ids
    assert length(page_ids) == 4
    assert length(Enum.uniq(page_ids)) == 4
    assert_binary_uuid_order!(first_page ++ second_page)
  end

  @tag :jc360_task07
  test "the selector accepts limits 1 and 500 and rejects limits outside that range" do
    first = create_effect!(:effective)
    second = create_effect!(:effective)
    set_updated_at!([first, second], ~U[2026-10-20 11:00:00.000000Z])

    assert {:ok, one_row} =
             read_effects(
               limit: 1,
               through_updated_at: @through_updated_at
             )

    assert length(one_row) == 1

    assert {:ok, up_to_500_rows} =
             read_effects(
               limit: 500,
               through_updated_at: @through_updated_at
             )

    assert length(up_to_500_rows) == 2

    assert {:error, _error} =
             read_effects(limit: 0, through_updated_at: @through_updated_at)

    assert {:error, _error} =
             read_effects(limit: 501, through_updated_at: @through_updated_at)
  end

  test "the EFFECTIVE recovery index has the exact PostgreSQL structure and predicate" do
    assert {:ok, result} =
             Repo.query("""
             SELECT index_state.indisvalid,
                    index_state.indisready,
                    index_state.indnkeyatts,
                    index_state.indnatts,
                    ARRAY(
                      SELECT attribute.attname
                      FROM unnest(index_state.indkey) WITH ORDINALITY AS key(attnum, position)
                      JOIN pg_attribute AS attribute
                        ON attribute.attrelid = index_state.indrelid
                       AND attribute.attnum = key.attnum
                      WHERE key.position <= index_state.indnkeyatts
                      ORDER BY key.position
                    ) AS key_columns,
                    pg_get_expr(index_state.indpred, index_state.indrelid) AS predicate
             FROM pg_index AS index_state
             JOIN pg_class AS index_relation ON index_relation.oid = index_state.indexrelid
             JOIN pg_class AS table_relation ON table_relation.oid = index_state.indrelid
             WHERE table_relation.relname = 'access_effects'
               AND index_relation.relname = 'access_effects_effective_recovery_index'
             """)

    assert [
             [true, true, 2, 2, ["updated_at", "id"], predicate]
           ] = result.rows

    assert normalize_predicate(predicate) ==
             "disposition='effective'andstatusin'required','pending','failed_retryable'"
  end

  @tag :jc360_task11
  test "recovery, terminal sweep, and selector costs emit bounded measurements" do
    measured_executions =
      for status <- [:required, :failed_retryable], sample <- 1..4 do
        effect = create_effect!(:effective)
        effect = if status == :failed_retryable, do: transition_to!(effect, status), else: effect
        recovery_started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        {result, stats, duration_us} =
          measured_operation(fn ->
            Facade.run_subscription_access_effect_recovery_for_system(
              limit: 1,
              as_of: recovery_started_at
            )
          end)

        assert {:ok, recovery} = result
        assert recovery.effective_execution_count == 1
        assert recovery.effective_execution_cursor.id == effect.id
        assert fetch_effect!(effect.id).status == :applied
        assert length(grant_ids_for_source!(effect.subscription_id)) == 1

        print_measurement!("#{status}_recovery", sample, 1, duration_us, stats, %{
          effect_id: effect.id,
          source_rows: 1,
          eligibility_lag_us: DateTime.diff(recovery_started_at, effect.updated_at, :microsecond),
          items_per_second: 1_000_000 / max(duration_us, 1),
          lag_clock:
            "recovery start wall clock minus persisted updated_at; may be nonpositive at timestamp granularity"
        })

        duration_us
      end

    terminal_effect = create_effect!(:effective) |> transition_to!(:applied)

    terminal_sweep_durations =
      for sample <- 1..4 do
        {result, stats, duration_us} =
          measured_operation(fn ->
            Facade.run_subscription_access_effect_recovery_for_system(
              limit: 10,
              as_of: ~U[2099-01-01 00:00:00.000000Z]
            )
          end)

        assert {:ok, recovery} = result
        assert recovery.effective_execution_count == 0
        assert fetch_effect!(terminal_effect.id).status == :applied
        print_measurement!("terminal_recovery_sweep", sample, 0, duration_us, stats, %{})
        duration_us
      end

    selected = Enum.map(1..4, fn _ -> create_effect!(:effective) end)
    set_updated_at!(selected, ~U[2026-10-20 11:00:00.000000Z])

    selector_durations =
      for sample <- 1..6 do
        {rows, stats, duration_us} =
          measured_operation(fn ->
            read_effects!(limit: 2, through_updated_at: @through_updated_at)
          end)

        assert length(rows) == 2

        print_measurement!("recovery_selector_page", sample, 2, duration_us, stats, %{
          page_limit: 2,
          selected_ids: Enum.map(rows, & &1.id)
        })

        duration_us
      end

    indexes = measured_index_definitions!()

    assert indexes["subscriptions_unique_source_order_line_item_id_index"] =~
             "UNIQUE INDEX"

    assert indexes["access_effects_unique_subscription_source_version_index"] =~
             "UNIQUE INDEX"

    assert indexes["entitlement_grants_source_index"] =~
             "(source_kind, source_id)"

    assert indexes["access_effects_effective_recovery_index"] =~
             "(updated_at, id)"

    assert indexes["access_effects_effective_recovery_index"] =~
             "WHERE"

    %{rows: selector_plan_rows} =
      Repo.query!(
        "EXPLAIN SELECT id FROM access_effects WHERE disposition = 'effective' AND status IN ('required', 'pending', 'failed_retryable') AND updated_at <= $1 ORDER BY updated_at, id LIMIT 2",
        [@through_updated_at]
      )

    selector_plan = Enum.map_join(selector_plan_rows, "\n", fn [line] -> line end)

    IO.puts(
      Jason.encode!(%{
        tag: "JC360_MEASUREMENTS",
        operation: "recovery_summaries",
        workload_class: "recovery_warm",
        required_and_failed_retryable_sample_count: length(measured_executions),
        terminal_sweep_sample_count: length(terminal_sweep_durations),
        selector_page_sample_count: length(selector_durations),
        required_and_failed_retryable_latency_us: latency_summary(measured_executions),
        terminal_sweep_latency_us: latency_summary(terminal_sweep_durations),
        selector_page_latency_us: latency_summary(selector_durations),
        index_definitions: indexes,
        bounded_selector_explain_plan: selector_plan,
        planner_index_use_claim: "UNMEASURED at fixture volume",
        limits: "fixture-scoped descriptive observations; no capacity claim"
      })
    )
  end

  @tag :jc360_task07
  test "EFFECTIVE recovery returns its own count and keyset cursor" do
    effect = create_effect!(:effective)
    set_updated_at!([effect], ~U[2026-10-20 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_subscription_access_effect_recovery_for_system(
               limit: 1,
               as_of: ~U[2099-01-01 00:00:00.000000Z],
               skip_execution: true,
               skip_projection: true
             )

    assert result.effective_execution_count == 1

    assert result.effective_execution_cursor == %{
             timestamp: ~U[2026-10-20 11:00:00.000000Z],
             id: effect.id
           }

    assert result.execution_count == 0
    assert result.execution_cursor == nil
    assert result.projection_cursor == nil
    assert fetch_effect!(effect.id).status == :applied
  end

  @tag :jc360_task07
  test "EFFECTIVE recovery rejects either half of its timestamp and id cursor" do
    assert {:error, _error} =
             Facade.run_subscription_access_effect_recovery_for_system(
               effective_execution_after_updated_at: @through_updated_at,
               skip_execution: true,
               skip_projection: true
             )

    assert {:error, _error} =
             Facade.run_subscription_access_effect_recovery_for_system(
               effective_execution_after_id: Ecto.UUID.generate(),
               skip_execution: true,
               skip_projection: true
             )
  end

  @tag :jc360_task08
  test "an exhausted EFFECTIVE stream does not suppress NON_EFFECTIVE or projection work" do
    effective = create_effect!(:effective)
    non_effective = create_effect!(:non_effective)
    projection = create_effect!(:effective)
    projection_user_id = subscription_user_id!(projection.subscription_id)

    Repo.query!("UPDATE subscriptions SET status = 'suspended' WHERE id = $1", [
      Ecto.UUID.dump!(non_effective.subscription_id)
    ])

    assert {:ok, pending_projection} = Facade.mark_access_effect_pending_for_system(projection)

    assert {:ok, applied_projection} =
             Facade.mark_access_effect_applied_for_system(pending_projection)

    Repo.query!(
      "UPDATE access_effects SET projection_user_ids = ARRAY[$2]::uuid[] WHERE id = $1",
      [Ecto.UUID.dump!(projection.id), Ecto.UUID.dump!(projection_user_id)]
    )

    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(projection_user_id))
    cache_value = {:jc360_projection_recovery, projection_user_id}
    assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(projection_user_id), cache_value)

    projection_grants_before = grant_ids_for_source!(projection.subscription_id)

    set_updated_at!(
      [effective, non_effective, applied_projection],
      ~U[2026-10-20 11:00:00.000000Z]
    )

    assert {:ok, result} =
             Facade.run_subscription_access_effect_recovery_for_system(
               limit: 1,
               as_of: ~U[2099-01-01 00:00:00.000000Z],
               execution_after_updated_at: ~U[2026-10-20 10:59:59.999999Z],
               execution_after_id: "00000000-0000-0000-0000-000000000000",
               projection_after_inserted_at:
                 DateTime.add(projection.inserted_at, -1, :microsecond),
               projection_after_id: "00000000-0000-0000-0000-000000000000",
               skip_effective_execution: true
             )

    assert result.effective_execution_count == 0
    assert result.effective_execution_cursor == nil
    assert result.execution_count == 1

    assert result.execution_cursor == %{
             timestamp: ~U[2026-10-20 11:00:00.000000Z],
             id: non_effective.id
           }

    assert result.projection_count == 1
    assert result.projection_cursor == %{timestamp: projection.inserted_at, id: projection.id}
    assert fetch_effect!(effective.id).status == :required
    assert fetch_effect!(non_effective.id).status == :applied

    repaired_projection = fetch_effect!(projection.id)
    assert repaired_projection.status == :applied
    assert repaired_projection.projection_user_ids == [projection_user_id]
    assert %DateTime{} = repaired_projection.projection_delivered_at
    assert grant_ids_for_source!(projection.subscription_id) == projection_grants_before
    assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(projection_user_id))

    assert_receive {:entitlements_invalidated, user_id, "effective_access_effect_applied", _at}
    assert user_id == projection_user_id
  end

  defp create_effect!(disposition) do
    fixture = create_subscription_fixture!()
    create_effect!(fixture, disposition)
  end

  defp create_effect!(fixture, disposition) do
    subscription = fixture.subscription
    revision = fixture.revision

    attrs = %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: disposition,
      entitlement_kind: if(disposition == :effective, do: revision.entitlement_kind),
      entitlement_scope_key: if(disposition == :effective, do: revision.entitlement_scope_key),
      valid_from_at: if(disposition == :effective, do: subscription.current_period_start_at),
      valid_until_at: subscription.current_period_end_at,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: revision.id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp supersede_with_newer_effect!(fixture) do
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
               [Ecto.UUID.dump!(fixture.subscription.id)]
             )

    subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    newer = create_effect!(%{fixture | subscription: subscription}, :effective)
    transition_to!(newer, :applied)
  end

  defp create_subscription_fixture! do
    customer =
      SubscriptionsFixtures.create_customer!("task6_effective_recovery_#{Ecto.UUID.generate()}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "task6-members"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
  end

  defp transition_to!(effect, :pending) do
    assert {:ok, pending} = Facade.mark_access_effect_pending_for_system(effect)
    pending
  end

  defp transition_to!(effect, :failed_retryable) do
    effect
    |> transition_to!(:pending)
    |> transition_to!(:failed_retryable_pending)
  end

  defp transition_to!(effect, :failed_retryable_pending) do
    assert {:ok, failed} = Facade.mark_access_effect_failed_retryable_for_system(effect)
    failed
  end

  defp transition_to!(effect, :applied) do
    effect
    |> transition_to!(:pending)
    |> then(fn pending ->
      assert {:ok, applied} = Facade.mark_access_effect_applied_for_system(pending)
      applied
    end)
  end

  defp set_updated_at!(effects, updated_at) do
    Enum.each(effects, fn effect ->
      Repo.query!("UPDATE access_effects SET updated_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(effect.id),
        updated_at
      ])
    end)
  end

  defp fetch_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp subscription_user_id!(subscription_id) do
    assert {:ok, %{rows: [[user_id]]}} =
             Repo.query("SELECT user_id FROM subscriptions WHERE id = $1", [
               Ecto.UUID.dump!(subscription_id)
             ])

    Ecto.UUID.load!(user_id)
  end

  defp grant_ids_for_source!(subscription_id) do
    assert {:ok, %{rows: rows}} =
             Repo.query(
               "SELECT id FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1 ORDER BY id",
               [Ecto.UUID.dump!(subscription_id)]
             )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp read_effects!(opts) do
    assert {:ok, effects} = read_effects(opts)
    effects
  end

  defp measured_operation(fun) do
    started_at = System.monotonic_time(:microsecond)
    {result, stats} = RepoStats.capture(fun)
    {result, stats, System.monotonic_time(:microsecond) - started_at}
  end

  defp print_measurement!(operation, sample, row_count, duration_us, stats, extra) do
    IO.puts(
      Jason.encode!(
        Map.merge(stats, extra)
        |> Map.merge(%{
          tag: "JC360_MEASUREMENTS",
          operation: operation,
          sample: sample,
          sample_count: if(operation == "recovery_selector_page", do: 6, else: 4),
          row_count: row_count,
          wall_duration_us: duration_us,
          queue_time_unit: "native telemetry units",
          query_time_unit: "native telemetry units",
          decode_time_unit: "native telemetry units",
          workload_class: "recovery_warm"
        })
      )
    )
  end

  defp measured_index_definitions! do
    assert {:ok, %{rows: rows}} =
             Repo.query(
               "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = ANY($1)",
               [
                 [
                   "subscriptions_unique_source_order_line_item_id_index",
                   "access_effects_unique_subscription_source_version_index",
                   "entitlement_grants_source_index",
                   "access_effects_effective_recovery_index"
                 ]
               ]
             )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp percentile(values, fraction) do
    sorted = Enum.sort(values)
    index = max(1, ceil(length(sorted) * fraction))
    Enum.at(sorted, index - 1)
  end

  defp latency_summary(values) do
    %{
      p50_us: percentile(values, 0.50),
      p95_us: percentile(values, 0.95),
      p99_us: percentile(values, 0.99)
    }
  end

  defp read_effects(opts) do
    args =
      opts
      |> Keyword.put_new(:after_updated_at, nil)
      |> Keyword.put_new(:after_id, nil)

    AccessEffect
    |> Ash.Query.for_read(:read_recoverable_effective_for_system, args)
    |> Ash.read(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp assert_binary_uuid_order!(rows) do
    keys =
      Enum.map(rows, fn row ->
        {DateTime.to_unix(row.updated_at, :microsecond), Ecto.UUID.dump!(row.id)}
      end)

    assert keys == Enum.sort(keys)
  end

  defp normalize_predicate(predicate) do
    Regex.replace(
      ~r/status\s*=\s*ANY\s*\(\s*ARRAY\s*\[(.*?)\]\s*\)/is,
      predicate,
      fn _, values -> "status IN (#{values})" end
    )
    |> String.downcase()
    |> String.replace(
      ~r/::(?:\"?[a-z_][a-z0-9_$]*\"?\.)*\"?[a-z_][a-z0-9_$]*\"?/,
      ""
    )
    |> String.replace(~r/[()\s]/, "")
  end
end
