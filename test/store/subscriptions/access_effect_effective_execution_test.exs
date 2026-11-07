defmodule Store.Subscriptions.AccessEffectEffectiveExecutionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.Cache
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Queries.SubscriptionSourceVerificationQuery
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade}
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Queries.AppliedAccessVerificationQuery
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize
  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.Telemetry.RepoStats

  @tag :jc360_task08
  test "EFFECTIVE execution converges one exact-source grant interval" do
    fixture = create_committed_effective_effect_fixture!("jc245_effective_pair")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    effect = fetch_effect!(fixture.effect.id)
    assert effect.status == :applied
    assert %DateTime{} = effect.projection_delivered_at
    assert AccessEffect.persisted_fingerprint_status(effect) == :v2_match

    assert [grant] = grants_for_source!(fixture.subscription.id)
    assert grant.status == :active
    assert grant.kind == fixture.effect.entitlement_kind
    assert grant.scope_key == fixture.effect.entitlement_scope_key
    assert grant.valid_from_at == fixture.effect.valid_from_at
    assert grant.valid_to_at == fixture.effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  test "verification query constructors reject unbounded or malformed cursors" do
    as_of = ~U[2020-01-01 00:00:00Z]

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 0})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             AppliedAccessVerificationQuery.new(%{as_of: as_of, limit: 501})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             AppliedAccessVerificationQuery.new(%{as_of: as_of, after_inserted_at: as_of})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             AppliedAccessVerificationQuery.new(%{as_of: as_of, after_id: Ecto.UUID.generate()})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             AppliedAccessVerificationQuery.new(%{
               as_of: as_of,
               after_inserted_at: as_of,
               after_id: "not-a-uuid"
             })

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             SubscriptionSourceVerificationQuery.new(%{source_ids: ["not-a-uuid"]})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             SubscriptionSourceVerificationQuery.new(%{
               source_ids: List.duplicate(Ecto.UUID.generate(), 501)
             })
  end

  test "verification resource actions require system context" do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:error, reason} =
             AccessEffect
             |> Ash.ActionInput.for_action(
               :read_applied_verification_window_for_system,
               %{as_of: timestamp, limit: 1},
               domain: Store.Subscriptions
             )
             |> Ash.run_action(authorize?: true)

    assert %Error{code: "FORBIDDEN"} = Normalize.normalize(reason)

    assert {:error, reason} =
             EntitlementGrant
             |> Ash.ActionInput.for_action(
               :read_active_subscription_sources_for_system,
               %{source_ids: []},
               domain: Store.Entitlements
             )
             |> Ash.run_action(authorize?: true)

    assert %Error{code: "FORBIDDEN"} = Normalize.normalize(reason)
  end

  test "bounded verification reads retain stale window rows and return both dispositions" do
    stale = create_committed_effective_effect_fixture!("jc248_window_stale")

    current =
      create_committed_effective_effect_fixture!("jc248_window_current",
        target: :empty,
        disposition: :non_effective
      )

    Sandbox.unboxed_run(Repo, fn ->
      for fixture <- [stale, current] do
        assert {:ok, _} = Facade.mark_access_effect_pending_for_system(fixture.effect)
        assert {:ok, _} = Facade.mark_access_effect_applied_for_system(fixture.effect)
      end

      create_newer_untransitioned_effect!(stale)

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(stale.effect.id),
        ~U[2020-01-01 00:00:00Z]
      ])

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(current.effect.id),
        ~U[2020-01-01 00:00:01Z]
      ])
    end)

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{as_of: ~U[2020-01-01 00:00:02Z], limit: 1})

    assert {:ok, [first]} = Facade.list_applied_access_verification_window_for_system(query)
    assert first.effect.id == stale.effect.id
    refute first.current?

    assert {:ok, next_query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: query.as_of,
               limit: 1,
               after_inserted_at: first.effect.inserted_at,
               after_id: first.effect.id
             })

    assert {:ok, [second]} = Facade.list_applied_access_verification_window_for_system(next_query)
    assert second.effect.id == current.effect.id
    assert second.current?
    assert second.effect.disposition == :non_effective
    assert second.source.user_id == current.subscription.user_id
    assert %DateTime{} = second.effect.inserted_at
  end

  test "source grant verification reads are batched and retain empty source keys" do
    first = create_committed_effective_effect_fixture!("jc248_source_grants")
    empty = create_committed_effective_effect_fixture!("jc248_source_empty")

    Sandbox.unboxed_run(Repo, fn -> insert_historical_grants!(first, 128) end)

    assert {:ok, query} =
             SubscriptionSourceVerificationQuery.new(%{
               source_ids: [first.subscription.id, empty.subscription.id]
             })

    {result, stats} =
      RepoStats.capture(fn ->
        EntitlementsFacade.list_active_subscription_source_grants_for_system(query)
      end)

    assert {:ok, grants_by_source} = result

    assert Map.keys(grants_by_source) |> MapSet.new() ==
             MapSet.new([first.subscription.id, empty.subscription.id])

    assert length(grants_by_source[first.subscription.id]) == 2
    assert grants_by_source[empty.subscription.id] == []
    assert stats.query_count == 1

    assert Enum.all?(grants_by_source[first.subscription.id], fn grant ->
             grant.source_id == first.subscription.id and grant.source_kind == :subscription and
               grant.status == :active and is_struct(grant.valid_from_at, DateTime)
           end)

    assert {:ok, empty_query} = SubscriptionSourceVerificationQuery.new(%{source_ids: []})

    {empty_result, empty_stats} =
      RepoStats.capture(fn ->
        EntitlementsFacade.list_active_subscription_source_grants_for_system(empty_query)
      end)

    assert {:ok, %{}} = empty_result
    assert empty_stats.query_count == 0
  end

  test "APPLIED verification cursor uses UUID order for ties and excludes rows above the high-water mark" do
    left = create_committed_effective_effect_fixture!("jc248_tie_left")
    right = create_committed_effective_effect_fixture!("jc248_tie_right")
    future = create_committed_effective_effect_fixture!("jc248_tie_future")
    tied_at = ~U[2021-01-01 00:00:00Z]

    Sandbox.unboxed_run(Repo, fn ->
      for fixture <- [left, right, future] do
        assert {:ok, _} = Facade.mark_access_effect_pending_for_system(fixture.effect)
        assert {:ok, _} = Facade.mark_access_effect_applied_for_system(fixture.effect)
      end

      for fixture <- [left, right] do
        Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
          Ecto.UUID.dump!(fixture.effect.id),
          tied_at
        ])
      end

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(future.effect.id),
        DateTime.add(tied_at, 2, :second)
      ])
    end)

    [first_id, second_id] = BinaryUuidSort.sort_uuids([left.effect.id, right.effect.id])

    assert {:ok, first_query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: DateTime.add(tied_at, 1, :second),
               limit: 1
             })

    assert {:ok, [first]} = Facade.list_applied_access_verification_window_for_system(first_query)
    assert first.effect.id == first_id

    assert {:ok, next_query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: first_query.as_of,
               limit: 1,
               after_inserted_at: tied_at,
               after_id: first_id
             })

    assert {:ok, [second]} = Facade.list_applied_access_verification_window_for_system(next_query)
    assert second.effect.id == second_id

    assert {:ok, full_query} =
             AppliedAccessVerificationQuery.new(%{as_of: first_query.as_of, limit: 500})

    assert {:ok, bounded_rows} =
             Facade.list_applied_access_verification_window_for_system(full_query)

    assert Enum.map(bounded_rows, & &1.effect.id) == [first_id, second_id]
    refute future.effect.id in Enum.map(bounded_rows, & &1.effect.id)
  end

  test "verification query plans expose bounded source access with historical rows" do
    fixture = create_committed_effective_effect_fixture!("jc248_query_plan")

    Sandbox.unboxed_run(Repo, fn ->
      insert_historical_grants!(fixture, 128)

      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      assert {:ok, applied_query} =
               AppliedAccessVerificationQuery.new(%{as_of: DateTime.utc_now(), limit: 2})

      assert {:ok, source_query} =
               SubscriptionSourceVerificationQuery.new(%{source_ids: [fixture.subscription.id]})

      for {operation, query} <- [
            {"applied_window", AppliedAccessVerificationQuery.to_ecto(applied_query)},
            {"active_source_grants", SubscriptionSourceVerificationQuery.to_ecto(source_query)}
          ] do
        {sql, params} = EctoSQL.to_sql(:all, Repo, query)
        %{rows: [[plan]]} = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

        IO.puts(
          "JC248_VERIFICATION_QUERY_PLAN " <>
            Jason.encode!(%{
              operation: operation,
              historical_source_rows: 128,
              sql: sql,
              plan: plan,
              limits: "small fixture, no production capacity claim"
            })
        )
      end

      {result, stats} =
        RepoStats.capture(fn ->
          EntitlementsFacade.list_active_subscription_source_grants_for_system(source_query)
        end)

      assert {:ok, grants_by_source} = result
      assert [grant] = grants_by_source[fixture.subscription.id]
      assert grant.status == :active
      assert stats.query_count == 1
    end)
  end

  test "APPLIED source repair restores missing grants and retries projection without changing the effect" do
    fixture = create_committed_effective_effect_fixture!("jc248_missing")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    effect_snapshot = fetch_effect!(fixture.effect.id)
    user_id = fixture.subscription.user_id
    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(user_id))

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )
    end)

    assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(user_id), :jc248_stale)

    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect.id)
             end)

    assert_effective_grant!(fixture)
    assert fetch_effect!(fixture.effect.id) == effect_snapshot
    assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(user_id))

    assert_receive {:entitlements_invalidated, ^user_id, "subscription_source_reconciliation",
                    _at}

    repaired_grants = grants_for_source!(fixture.subscription.id)
    assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(user_id), :jc248_stale_replay)

    assert {:ok, :already_converged} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect.id)
             end)

    assert grants_for_source!(fixture.subscription.id) == repaired_grants
    assert fetch_effect!(fixture.effect.id) == effect_snapshot
    assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(user_id))

    assert_receive {:entitlements_invalidated, ^user_id, "subscription_source_reconciliation",
                    _at}
  end

  test "APPLIED source repair restores the exact target validity interval" do
    fixture = create_committed_effective_effect_fixture!("jc248_validity")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    effect_snapshot = fetch_effect!(fixture.effect.id)
    original_valid_to_at = fixture.effect.valid_until_at

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE entitlement_grants SET valid_to_at = valid_to_at + interval '1 day' WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )
    end)

    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect.id)
             end)

    assert_effective_grant!(fixture)

    assert [%EntitlementGrant{valid_to_at: ^original_valid_to_at}] =
             grants_for_source!(fixture.subscription.id)

    assert fetch_effect!(fixture.effect.id) == effect_snapshot
  end

  @tag :jc360_task07
  @tag :jc360_task08
  test "a committed REQUIRED initial source effect recovers by exact ID without duplicate rows" do
    fixture = create_committed_effective_effect_fixture!("jc360_initial_required_recovery")

    assert fetch_effect!(fixture.effect.id).status == :required

    before =
      Sandbox.unboxed_run(Repo, fn -> source_identity_snapshot!(fixture.subscription.id) end)

    assert before.subscriptions == [fixture.subscription.id]
    assert before.items == [fixture.item.id]
    assert before.effects == [fixture.effect.id]
    assert before.grants == []

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    applied = fetch_effect!(fixture.effect.id)
    assert applied.status == :applied
    assert_effective_grant!(%{fixture | effect: applied})

    grants_after_apply =
      Sandbox.unboxed_run(Repo, fn -> grants_for_source!(fixture.subscription.id) end)

    assert length(grants_after_apply) == 1

    after_apply =
      Sandbox.unboxed_run(Repo, fn -> source_identity_snapshot!(fixture.subscription.id) end)

    assert Map.take(after_apply, [:subscriptions, :items, :effects]) ==
             Map.take(before, [:subscriptions, :items, :effects])

    assert after_apply.grants == Enum.map(grants_after_apply, & &1.id)

    assert {:ok, :noop} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert fetch_effect!(fixture.effect.id).status == :applied

    assert Sandbox.unboxed_run(Repo, fn ->
             grants_for_source!(fixture.subscription.id)
           end) == grants_after_apply

    assert Sandbox.unboxed_run(Repo, fn ->
             source_identity_snapshot!(fixture.subscription.id)
           end) == after_apply
  end

  test "EFFECTIVE nil/nil execution converges to an empty exact-source set" do
    fixture = create_committed_effective_effect_fixture!("jc245_effective_empty", target: :empty)

    Sandbox.unboxed_run(Repo, fn ->
      create_grant!(fixture, "old-scope", DateTime.add(fixture.effect.valid_until_at, -2, :day))
    end)

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert fetch_effect!(fixture.effect.id).status == :applied
    assert [] == Enum.filter(grants_for_source!(fixture.subscription.id), &(&1.status == :active))
  end

  @tag :jc360_task08
  test "the EFFECTIVE executor rejects NON_EFFECTIVE disposition before lifecycle mutation" do
    fixture =
      create_committed_effective_effect_fixture!("jc245_wrong_disposition",
        disposition: :non_effective
      )

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert fetch_effect!(fixture.effect.id).status == :required
    assert grants_for_source!(fixture.subscription.id) == []
  end

  @tag :jc360_task08
  test "F1 rejects a corrupt fingerprint without changing lifecycle or grants" do
    fixture = create_committed_effective_effect_fixture!("jc360_bad_fingerprint")

    corrupt_fingerprint =
      Base.encode16(:crypto.hash(:sha256, "corrupt fingerprint"), case: :lower)

    refute corrupt_fingerprint == fixture.effect.target_fingerprint

    {result, invalid_effect, effect_after_execution, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "UPDATE access_effects SET target_fingerprint = $2 WHERE id = $1",
          [Ecto.UUID.dump!(fixture.effect.id), corrupt_fingerprint]
        )

        invalid_effect = fetch_effect!(fixture.effect.id)
        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

        {result, invalid_effect, fetch_effect!(fixture.effect.id),
         grants_for_source!(fixture.subscription.id)}
      end)

    assert {:error, %Error{code: "INTERNAL_ERROR"}} = result
    assert AccessEffect.persisted_fingerprint_status(invalid_effect) == :mismatch
    assert invalid_effect.status == :required
    assert effect_after_execution == invalid_effect
    assert grants == []
  end

  @tag :jc360_task08
  test "F1 rejects a future source version without changing lifecycle or grants" do
    fixture = create_committed_effective_effect_fixture!("jc360_future_version")

    {result, invalid_effect, effect_after_execution, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "UPDATE access_effects SET source_version = $2 WHERE id = $1",
          [
            Ecto.UUID.dump!(fixture.effect.id),
            fixture.subscription.aggregate_version + 1
          ]
        )

        recompute_v2_fingerprint!(fixture.effect.id)
        invalid_effect = fetch_effect!(fixture.effect.id)
        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

        {result, invalid_effect, fetch_effect!(fixture.effect.id),
         grants_for_source!(fixture.subscription.id)}
      end)

    assert {:error, %Error{code: "INTERNAL_ERROR"}} = result
    assert invalid_effect.status == :required
    assert effect_after_execution == invalid_effect
    assert grants == []
  end

  @tag :jc360_task08
  test "F1 rejects source-line and plan-revision provenance mismatches" do
    fixture = create_committed_effective_effect_fixture!("jc360_wrong_provenance")
    foreign_fixture = create_committed_effective_effect_fixture!("jc360_foreign_provenance")

    mismatched_provenance = [
      {foreign_fixture.revision.id, fixture.effect.source_order_line_item_id},
      {fixture.effect.plan_revision_id, foreign_fixture.line_item.id}
    ]

    try do
      Enum.each(mismatched_provenance, fn {plan_revision_id, line_item_id} ->
        {result, invalid_effect, effect_after_execution, grants} =
          Sandbox.unboxed_run(Repo, fn ->
            Repo.query!(
              """
              UPDATE access_effects
              SET plan_revision_id = $2,
                  source_order_line_item_id = $3,
                  target_fingerprint = $4
              WHERE id = $1
              """,
              [
                Ecto.UUID.dump!(fixture.effect.id),
                Ecto.UUID.dump!(plan_revision_id),
                Ecto.UUID.dump!(line_item_id),
                fixture.effect.target_fingerprint
              ]
            )

            invalid_effect = fetch_effect!(fixture.effect.id)
            result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

            {result, invalid_effect, fetch_effect!(fixture.effect.id),
             grants_for_source!(fixture.subscription.id)}
          end)

        assert {:error, %Error{code: "INTERNAL_ERROR"}} = result
        assert AccessEffect.persisted_fingerprint_status(invalid_effect) == :mismatch
        assert invalid_effect.status == :required
        assert effect_after_execution == invalid_effect
        assert grants == []
      end)
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          UPDATE access_effects
          SET plan_revision_id = $2,
              source_order_line_item_id = $3,
              target_fingerprint = $4
          WHERE id = $1
          """,
          [
            Ecto.UUID.dump!(fixture.effect.id),
            Ecto.UUID.dump!(fixture.effect.plan_revision_id),
            Ecto.UUID.dump!(fixture.effect.source_order_line_item_id),
            fixture.effect.target_fingerprint
          ]
        )
      end)
    end
  end

  @tag :jc360_task08
  test "F1 rejects an invalid interval with a valid fingerprint without writes" do
    fixture = create_committed_effective_effect_fixture!("jc360_invalid_interval")

    {result, invalid_effect, effect_after_execution, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "UPDATE access_effects SET valid_until_at = valid_from_at WHERE id = $1",
          [Ecto.UUID.dump!(fixture.effect.id)]
        )

        recompute_v2_fingerprint!(fixture.effect.id)
        malformed = fetch_effect!(fixture.effect.id)
        assert AccessEffect.persisted_fingerprint_status(malformed) == :v2_match

        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

        {result, malformed, fetch_effect!(fixture.effect.id),
         grants_for_source!(fixture.subscription.id)}
      end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert invalid_effect.status == :required
    assert effect_after_execution == invalid_effect
    assert grants == []
  end

  @tag :jc360_task08
  test "F1 accepts a compatible v1 fingerprint for an EFFECTIVE empty target" do
    fixture = create_committed_effective_effect_fixture!("jc360_v1_empty", target: :empty)
    legacy_fingerprint = AccessEffect.legacy_target_fingerprint_v1(fixture.effect)

    refute legacy_fingerprint == fixture.effect.target_fingerprint

    {result, effect, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "UPDATE access_effects SET target_fingerprint = $2 WHERE id = $1",
          [Ecto.UUID.dump!(fixture.effect.id), legacy_fingerprint]
        )

        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        {result, fetch_effect!(fixture.effect.id), grants_for_source!(fixture.subscription.id)}
      end)

    assert {:ok, :applied} = result
    assert effect.status == :applied
    assert effect.target_fingerprint == legacy_fingerprint
    assert AccessEffect.persisted_fingerprint_status(effect) == :v1_legacy_match
    assert grants == []
  end

  @tag :jc360_task08
  test "a valid stale REQUIRED target is superseded without issuing a grant" do
    fixture = create_committed_effective_effect_fixture!("jc360_valid_stale")

    newer =
      Sandbox.unboxed_run(Repo, fn -> create_newer_untransitioned_effect!(fixture) end)

    assert fetch_effect!(fixture.effect.id).status == :required
    assert fetch_effect!(newer.id).status == :required

    assert {:ok, :superseded} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert fetch_effect!(fixture.effect.id).status == :superseded
    assert fetch_effect!(newer.id).status == :required
    assert grants_for_source!(fixture.subscription.id) == []
  end

  @tag :jc360_task08
  test "an invalid stale target fails before lifecycle or grant mutation" do
    fixture = create_committed_effective_effect_fixture!("jc360_invalid_stale")

    newer =
      Sandbox.unboxed_run(Repo, fn -> create_newer_untransitioned_effect!(fixture) end)

    {result, invalid_candidate, candidate_after_execution, latest_before_execution,
     latest_after_execution, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "UPDATE access_effects SET valid_until_at = valid_from_at WHERE id = $1",
          [Ecto.UUID.dump!(fixture.effect.id)]
        )

        recompute_v2_fingerprint!(fixture.effect.id)
        malformed = fetch_effect!(fixture.effect.id)
        assert AccessEffect.persisted_fingerprint_status(malformed) == :v2_match
        latest_before_execution = fetch_effect!(newer.id)

        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

        {result, malformed, fetch_effect!(fixture.effect.id), latest_before_execution,
         fetch_effect!(newer.id), grants_for_source!(fixture.subscription.id)}
      end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert invalid_candidate.status == :required
    assert candidate_after_execution == invalid_candidate
    assert latest_before_execution.status == :required
    assert latest_after_execution == latest_before_execution
    assert grants == []
  end

  test "the public EFFECTIVE executor rejects a caller-owned transaction before writes on commit" do
    fixture = create_committed_effective_effect_fixture!("jc245_nested_commit")

    assert {:ok, :ok} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
             end)

    before_effect = fetch_effect!(fixture.effect.id)
    before_grants = grants_for_source!(fixture.subscription.id)
    assert before_effect.status == :required
    assert length(before_grants) == 1

    assert {:ok, {result, ^before_effect, ^before_grants}} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()
                 result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)

                 {result, fetch_effect!(fixture.effect.id),
                  grants_for_source!(fixture.subscription.id)}
               end)
             end)

    assert {:error, %{code: "VALIDATION_ERROR"}} = result
    assert fetch_effect!(fixture.effect.id) == before_effect
    assert grants_for_source!(fixture.subscription.id) == before_grants
  end

  test "the public EFFECTIVE executor rejects a caller-owned transaction before writes on rollback" do
    fixture = create_committed_effective_effect_fixture!("jc245_nested_rollback")

    assert {:ok, :ok} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
             end)

    before_effect = fetch_effect!(fixture.effect.id)
    before_grants = grants_for_source!(fixture.subscription.id)
    assert before_effect.status == :required
    assert length(before_grants) == 1

    assert {:error, {:forced_rollback, result, ^before_effect, ^before_grants}} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()
                 result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
                 effect = fetch_effect!(fixture.effect.id)
                 grants = grants_for_source!(fixture.subscription.id)
                 Repo.rollback({:forced_rollback, result, effect, grants})
               end)
             end)

    assert {:error, %{code: "VALIDATION_ERROR"}} = result
    assert fetch_effect!(fixture.effect.id) == before_effect
    assert grants_for_source!(fixture.subscription.id) == before_grants
  end

  test "a PENDING EFFECTIVE effect converges and becomes APPLIED" do
    fixture = create_committed_effective_effect_fixture!("jc245_effective_pending")

    assert {:ok, pending} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.mark_access_effect_pending_for_system(fixture.effect)
             end)

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(pending.id)
             end)

    assert fetch_effect!(pending.id).status == :applied
    assert_effective_grant!(fixture)
  end

  @tag :jc360_task11
  test "runtime resource review measures convergence with 128 exact-source historical rows" do
    for repetition <- 1..2 do
      fixture = create_committed_effective_effect_fixture!("jc245_resource_#{repetition}")

      Sandbox.unboxed_run(Repo, fn ->
        insert_historical_grants!(fixture, 128)
      end)

      {result, stats, resource} =
        Sandbox.unboxed_run(Repo, fn ->
          source_id = Ecto.UUID.dump!(fixture.subscription.id)

          %{rows: [[source_rows_before]]} =
            Repo.query!(
              "SELECT count(*) FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
              [source_id]
            )

          {:memory, memory_before} = Process.info(self(), :memory)

          {gc_count_before, reclaimed_words_before, _} =
            :erlang.statistics(:garbage_collection)

          {:message_queue_len, mailbox_before} = Process.info(self(), :message_queue_len)
          handlers_before = length(:telemetry.list_handlers([:store, :repo, :query]))

          started_at = System.monotonic_time(:microsecond)

          {result, stats} =
            RepoStats.capture(fn ->
              Facade.execute_effective_access_effect_for_system(fixture.effect.id)
            end)

          duration_us = System.monotonic_time(:microsecond) - started_at
          {:memory, memory_after} = Process.info(self(), :memory)
          {:message_queue_len, mailbox_after} = Process.info(self(), :message_queue_len)
          handlers_after = length(:telemetry.list_handlers([:store, :repo, :query]))

          %{rows: [[source_rows_after, active_rows_after]]} =
            Repo.query!(
              """
              SELECT count(*), count(*) FILTER (WHERE status = 'active')
              FROM entitlement_grants
              WHERE source_kind = 'subscription' AND source_id = $1
              """,
              [source_id]
            )

          resource = %{
            source_rows_before: source_rows_before,
            source_rows_after: source_rows_after,
            active_rows_after: active_rows_after,
            duration_us: duration_us,
            memory_delta_bytes: memory_after - memory_before,
            mailbox_before: mailbox_before,
            mailbox_after: mailbox_after,
            telemetry_handlers_before: handlers_before,
            telemetry_handlers_after: handlers_after
          }

          %{num_rows: deleted_rows} =
            Repo.query!(
              "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
              [source_id]
            )

          %{rows: [[source_rows_after_cleanup]]} =
            Repo.query!(
              "SELECT count(*) FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
              [source_id]
            )

          {:memory, memory_after_cleanup} = Process.info(self(), :memory)
          {:message_queue_len, mailbox_after_cleanup} = Process.info(self(), :message_queue_len)

          {gc_count_after_cleanup, reclaimed_words_after_cleanup, _} =
            :erlang.statistics(:garbage_collection)

          resource =
            Map.merge(resource, %{
              cleanup_deleted_rows: deleted_rows,
              source_rows_after_cleanup: source_rows_after_cleanup,
              memory_after_cleanup_bytes: memory_after_cleanup,
              mailbox_after_cleanup: mailbox_after_cleanup,
              global_gc_count_delta: gc_count_after_cleanup - gc_count_before,
              global_reclaimed_words_delta: reclaimed_words_after_cleanup - reclaimed_words_before
            })

          {result, stats, resource}
        end)

      assert {:ok, :applied} = result
      assert resource.source_rows_before == 128
      assert resource.source_rows_after >= 128
      assert resource.active_rows_after == 1
      assert resource.cleanup_deleted_rows == resource.source_rows_after
      assert resource.source_rows_after_cleanup == 0
      assert resource.telemetry_handlers_after == resource.telemetry_handlers_before

      IO.puts(
        Jason.encode!(%{
          tag: "JC360_MEASUREMENTS",
          operation: "effective_execution_historical_source_fanout",
          repetition: repetition,
          repetition_count: 2,
          subscription_id: fixture.subscription.id,
          access_effect_id: fixture.effect.id,
          historical_rows: 128,
          source_rows_before: resource.source_rows_before,
          source_rows_after: resource.source_rows_after,
          active_rows_after: resource.active_rows_after,
          source_rows_after_explicit_cleanup: resource.source_rows_after_cleanup,
          cleanup_deleted_rows: resource.cleanup_deleted_rows,
          wall_duration_us: resource.duration_us,
          query_count: stats.query_count,
          queue_time: stats.queue_time,
          query_time: stats.query_time,
          decode_time: stats.decode_time,
          telemetry_time_unit: "native units",
          process_memory_delta_bytes: resource.memory_delta_bytes,
          process_memory_after_cleanup_bytes: resource.memory_after_cleanup_bytes,
          mailbox_before: resource.mailbox_before,
          mailbox_after: resource.mailbox_after,
          mailbox_after_cleanup: resource.mailbox_after_cleanup,
          global_gc_count_delta: resource.global_gc_count_delta,
          global_reclaimed_words_delta: resource.global_reclaimed_words_delta,
          telemetry_handlers_before: resource.telemetry_handlers_before,
          telemetry_handlers_after: resource.telemetry_handlers_after,
          workload_class: "recovery_warm",
          historical_source_history_class: "historical_audit_cold",
          limits: "two equivalent bounded repetitions; no convergence or capacity claim"
        })
      )
    end
  end

  @tag :jc360_task11
  test "EFFECTIVE execution reports bounded PostgreSQL lock-wait observations" do
    for repetition <- 1..2 do
      fixture = create_committed_effective_effect_fixture!("jc360_lock_wait_#{repetition}")
      run_ref = make_ref()
      parent = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT id FROM access_effects WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(fixture.effect.id)
              ])

              send(parent, {run_ref, :lock_held, backend_pid!()})

              receive do
                {^run_ref, :release_lock} -> :released
              after
                10_000 -> Repo.rollback(:lock_release_timeout)
              end
            end)
          end)
        end)

      executor =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            executor_pid = backend_pid!()
            send(parent, {run_ref, :executor_ready, executor_pid})

            receive do
              {^run_ref, :execute} -> :ok
            after
              5_000 -> raise "executor start timed out"
            end

            started_at = System.monotonic_time(:nanosecond)
            send(parent, {run_ref, :executor_started, started_at})

            {result, stats} =
              RepoStats.capture(fn ->
                Facade.execute_effective_access_effect_for_system(fixture.effect.id)
              end)

            completed_at = System.monotonic_time(:nanosecond)
            {result, stats, started_at, completed_at}
          end)
        end)

      try do
        assert_receive {^run_ref, :lock_held, holder_pid}, 5_000
        assert_receive {^run_ref, :executor_ready, executor_pid}, 5_000
        refute executor_pid == holder_pid
        send(executor.pid, {run_ref, :execute})
        assert_receive {^run_ref, :executor_started, executor_started_at}, 5_000

        observed_at = await_lock_wait!(executor_pid, holder_pid, 5_000)
        release_sent_at = System.monotonic_time(:nanosecond)
        send(holder.pid, {run_ref, :release_lock})

        assert {:ok, :released} = Task.await(holder, 5_000)

        assert {{:ok, :applied}, stats, ^executor_started_at, completed_at} =
                 Task.await(executor, 5_000)

        assert observed_at > executor_started_at
        assert release_sent_at > observed_at
        assert completed_at > release_sent_at
        assert fetch_effect!(fixture.effect.id).status == :applied

        IO.puts(
          Jason.encode!(%{
            tag: "JC360_MEASUREMENTS",
            operation: "effective_execution_lock_wait",
            repetition: repetition,
            repetition_count: 2,
            effect_id: fixture.effect.id,
            holder_backend_pid: holder_pid,
            executor_backend_pid: executor_pid,
            observed_blocker_backend_pids: [holder_pid],
            wait_event_type: "Lock",
            wait_observation_to_release_request_ns: release_sent_at - observed_at,
            blocked_operation_wall_us: div(completed_at - executor_started_at, 1_000),
            query_count: stats.query_count,
            queue_time: stats.queue_time,
            query_time: stats.query_time,
            decode_time: stats.decode_time,
            telemetry_time_unit: "native units",
            workload_class: "paid_activation_hot",
            limits:
              "controlled single-row lock; observation-to-release is a minimum observed blocked interval; whole operation includes execution; no capacity claim"
          })
        )
      after
        send(holder.pid, {run_ref, :release_lock})
        send(executor.pid, {run_ref, :execute})
        Task.shutdown(holder, :brutal_kill)
        Task.shutdown(executor, :brutal_kill)
      end
    end
  end

  test "legacy ordinary issue followed by F1 converges the exact persisted target" do
    fixture = create_committed_effective_effect_fixture!("jc245_legacy_then_f1")

    assert {:ok, :ok} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
             end)

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert_effective_grant!(fixture)
  end

  test "legacy ordinary issue after F1 preserves the exact persisted start and target" do
    fixture = create_committed_effective_effect_fixture!("jc245_f1_then_legacy")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)
             end)

    assert {:ok, :ok} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
             end)

    assert_effective_grant!(fixture)
  end

  test "a convergence write failure rolls back grants and records retryable truth" do
    fixture = create_committed_effective_effect_fixture!("jc245_effective_retry")
    constraint = "jc245_fail_active_#{System.unique_integer([:positive])}"

    {result, effect_status, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("""
        ALTER TABLE entitlement_grants
        ADD CONSTRAINT #{constraint}
        CHECK (source_id <> '#{fixture.subscription.id}'::uuid OR status <> 'active')
        NOT VALID
        """)

        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        effect = fetch_effect!(fixture.effect.id)
        source_grants = grants_for_source!(fixture.subscription.id)
        Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT #{constraint}")
        {result, effect.status, source_grants}
      end)

    assert {:error, _reason} = result
    assert effect_status == :failed_retryable
    assert grants == []

    retryable_effect = fetch_effect!(fixture.effect.id)
    cursor_start = DateTime.add(retryable_effect.updated_at, -1, :microsecond)
    as_of = DateTime.add(retryable_effect.updated_at, 1, :microsecond)

    assert {:ok, recovery} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.run_subscription_access_effect_recovery_for_system(
                 limit: 100,
                 as_of: as_of,
                 effective_execution_after_updated_at: cursor_start,
                 effective_execution_after_id: "00000000-0000-0000-0000-000000000000",
                 skip_execution: true,
                 skip_projection: true
               )
             end)

    assert recovery.effective_execution_count >= 1
    assert recovery.effective_execution_cursor == nil
    assert fetch_effect!(fixture.effect.id).status == :applied
    assert_effective_grant!(fixture)
  end

  test "an APPLIED write failure rolls back grant convergence before recovery retry" do
    fixture = create_committed_effective_effect_fixture!("jc245_applied_rollback")
    constraint = "jc245_block_applied_#{System.unique_integer([:positive])}"

    {result, effect_status, grants} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("""
        ALTER TABLE access_effects
        ADD CONSTRAINT #{constraint}
        CHECK (status <> 'applied')
        NOT VALID
        """)

        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        effect = fetch_effect!(fixture.effect.id)
        source_grants = grants_for_source!(fixture.subscription.id)
        Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT #{constraint}")
        {result, effect.status, source_grants}
      end)

    assert {:error, _reason} = result
    assert effect_status == :failed_retryable
    assert grants == []

    retryable_effect = fetch_effect!(fixture.effect.id)
    cursor_start = DateTime.add(retryable_effect.updated_at, -1, :microsecond)
    as_of = DateTime.add(retryable_effect.updated_at, 1, :microsecond)

    assert {:ok, recovery} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.run_subscription_access_effect_recovery_for_system(
                 limit: 100,
                 as_of: as_of,
                 effective_execution_after_updated_at: cursor_start,
                 effective_execution_after_id: "00000000-0000-0000-0000-000000000000",
                 skip_execution: true,
                 skip_projection: true
               )
             end)

    assert recovery.effective_execution_count >= 1
    assert fetch_effect!(fixture.effect.id).status == :applied
    assert_effective_grant!(fixture)
  end

  @tag :jc360_task08
  test "post-commit projection failure returns a successful repairable outcome" do
    fixture = create_committed_effective_effect_fixture!("jc245_effective_projection")
    constraint = "jc245_projection_pending_#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(
      Store.PubSub,
      Cache.topic(fixture.subscription.user_id)
    )

    result =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("""
        ALTER TABLE access_effects
        ADD CONSTRAINT #{constraint}
        CHECK (projection_delivered_at IS NULL)
        NOT VALID
        """)

        result = Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT #{constraint}")
        result
      end)

    assert {:ok, :applied_projection_pending} = result
    assert_receive {:entitlements_invalidated, user_id, "effective_access_effect_applied", _at}
    assert user_id == fixture.subscription.user_id

    applied = fetch_effect!(fixture.effect.id)
    assert applied.status == :applied
    assert applied.projection_delivered_at == nil
    assert applied.projection_user_ids == [fixture.subscription.user_id]
    before_repair = grants_for_source!(fixture.subscription.id)
    assert_effective_grant!(fixture)

    cache_value = {:projection_repair_sentinel, fixture.subscription.user_id}

    assert {:ok, true} =
             Cachex.put(Cache, Cache.cache_key(fixture.subscription.user_id), cache_value)

    repair_projection_with_sql_evidence!(fixture.effect.id, :delivery_update)

    repaired = fetch_effect!(fixture.effect.id)
    assert repaired.status == :applied
    assert %DateTime{} = repaired.projection_delivered_at
    assert repaired.projection_user_ids == [fixture.subscription.user_id]
    assert grants_for_source!(fixture.subscription.id) == before_repair
    assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(fixture.subscription.user_id))
    assert_receive {:entitlements_invalidated, user_id, "effective_access_effect_applied", _at}
    assert user_id == fixture.subscription.user_id

    repeated_cache_value = {:projection_repair_replay, fixture.subscription.user_id}

    assert {:ok, true} =
             Cachex.put(
               Cache,
               Cache.cache_key(fixture.subscription.user_id),
               repeated_cache_value
             )

    repair_projection_with_sql_evidence!(fixture.effect.id, :already_delivered)

    repeated_repair = fetch_effect!(fixture.effect.id)
    assert repeated_repair.status == :applied
    assert %DateTime{} = repeated_repair.projection_delivered_at
    assert repeated_repair.projection_user_ids == [fixture.subscription.user_id]
    assert grants_for_source!(fixture.subscription.id) == before_repair
    assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(fixture.subscription.user_id))

    assert_receive {:entitlements_invalidated, repeated_user_id,
                    "effective_access_effect_applied", _at}

    assert repeated_user_id == fixture.subscription.user_id
  end

  defp create_committed_effective_effect_fixture!(prefix, opts \\ []) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, fixture} =
          Repo.transaction(fn -> create_effective_effect_fixture!(prefix, opts) end)

        fixture
      end)

    on_exit(fn -> cleanup_fixture!(fixture) end)
    fixture
  end

  defp create_effective_effect_fixture!(prefix, opts) do
    customer = SubscriptionsFixtures.create_customer!("#{prefix}_#{Ecto.UUID.generate()}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    empty_target? = Keyword.get(opts, :target) == :empty
    disposition = Keyword.get(opts, :disposition, :effective)

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: if(empty_target?, do: nil, else: :membership_access),
        entitlement_scope_key:
          if(empty_target?, do: nil, else: "#{prefix}:#{Ecto.UUID.generate()}")
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
    subscription = fixture.subscription

    attrs =
      %{
        subscription_id: subscription.id,
        source_version: subscription.aggregate_version,
        disposition: disposition,
        source_order_line_item_id: fixture.line_item.id,
        contract_change_id: subscription.current_contract_change_id,
        plan_revision_id: fixture.revision.id
      }
      |> Map.merge(
        effective_effect_target_attrs(disposition, empty_target?, fixture.revision, subscription)
      )

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)

    Map.merge(fixture, %{
      customer: customer,
      effect: effect,
      plan: plan,
      product: product,
      variant: variant,
      variant_plan: variant_plan
    })
  end

  defp effective_effect_target_attrs(:non_effective, _empty_target?, _revision, _subscription) do
    %{
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil
    }
  end

  defp effective_effect_target_attrs(:effective, true, _revision, subscription) do
    %{
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: subscription.current_period_end_at
    }
  end

  defp effective_effect_target_attrs(:effective, false, revision, subscription) do
    %{
      entitlement_kind: revision.entitlement_kind,
      entitlement_scope_key: revision.entitlement_scope_key,
      valid_from_at: subscription.current_period_start_at,
      valid_until_at: subscription.current_period_end_at
    }
  end

  defp create_newer_untransitioned_effect!(fixture) do
    source_version = fixture.subscription.aggregate_version + 1

    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE subscriptions SET aggregate_version = $2 WHERE id = $1",
               [Ecto.UUID.dump!(fixture.subscription.id), source_version]
             )

    attrs = %{
      subscription_id: fixture.subscription.id,
      source_version: source_version,
      disposition: :effective,
      entitlement_kind: fixture.revision.entitlement_kind,
      entitlement_scope_key: "#{fixture.effect.entitlement_scope_key}:newer",
      valid_from_at: fixture.subscription.current_period_start_at,
      valid_until_at: fixture.subscription.current_period_end_at,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: fixture.subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)

    AccessEffect
    |> Ash.Changeset.for_create(:establish, Map.from_struct(input), context: %{system?: true})
    |> Ash.create!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp recompute_v2_fingerprint!(effect_id) do
    effect = fetch_effect!(effect_id)

    Repo.query!(
      "UPDATE access_effects SET target_fingerprint = $2 WHERE id = $1",
      [Ecto.UUID.dump!(effect_id), AccessEffect.target_fingerprint(effect)]
    )
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, :jc360_task08_queries, make_ref()}
    message_ref = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, {pid, ref} ->
          send(pid, {ref, metadata.query})
        end,
        {self(), message_ref}
      )

    try do
      result = fun.()
      {result, receive_repo_queries(message_ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp receive_repo_queries(ref, queries) do
    receive do
      {^ref, query} -> receive_repo_queries(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp entitlement_grant_dml_query?(query) do
    Regex.match?(
      ~r/^\s*(insert\s+into|update|delete\s+from)\s+"?entitlement_grants"?/i,
      query
    )
  end

  defp access_effect_projection_delivery_update?(query) do
    Regex.match?(~r/^\s*update\s+"?access_effects"?/i, query) and
      String.contains?(String.downcase(query), "projection_delivered_at")
  end

  defp access_effect_projection_lock_query?(query) do
    normalized = String.downcase(query)

    Regex.match?(~r/^\s*select\b/s, normalized) and
      String.contains?(normalized, "from \"access_effects\"") and
      String.contains?(normalized, "for update")
  end

  defp repair_projection_with_sql_evidence!(effect_id, expected_query) do
    {result, queries} =
      capture_repo_queries(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.repair_suspension_access_effect_projection_for_system(effect_id)
        end)
      end)

    assert :ok = result

    case expected_query do
      :delivery_update ->
        assert Enum.any?(queries, &access_effect_projection_delivery_update?/1),
               "projection delivery update was not captured: #{inspect(queries)}"

      :already_delivered ->
        assert Enum.any?(queries, &access_effect_projection_lock_query?/1),
               "projection repair lock query was not captured: #{inspect(queries)}"
    end

    refute Enum.any?(queries, &entitlement_grant_dml_query?/1)
  end

  defp create_grant!(fixture, scope_key, valid_from_at) do
    EntitlementGrant
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: fixture.subscription.user_id,
        kind: :membership_access,
        scope_key: scope_key,
        source_kind: :subscription,
        source_id: fixture.subscription.id,
        status: :active,
        valid_from_at: valid_from_at,
        valid_to_at: fixture.effect.valid_until_at
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp insert_historical_grants!(fixture, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ids = Enum.map(1..count, fn _ -> Ash.UUIDv7.generate() |> Ecto.UUID.dump!() end)

    scope_keys =
      Enum.map(1..count, fn index ->
        "#{fixture.effect.entitlement_scope_key}:history:#{index}"
      end)

    Repo.query!(
      """
      INSERT INTO entitlement_grants (
        id, user_id, kind, scope_key, source_kind, source_id, status,
        valid_from_at, valid_to_at, inserted_at, updated_at
      )
      SELECT historical.id, $2, 'membership_access', historical.scope_key,
             'subscription', $3, 'active', $4, $5, $6, $6
      FROM unnest($1::uuid[], $7::text[]) AS historical(id, scope_key)
      """,
      [
        ids,
        Ecto.UUID.dump!(fixture.subscription.user_id),
        Ecto.UUID.dump!(fixture.subscription.id),
        fixture.effect.valid_from_at,
        fixture.effect.valid_until_at,
        now,
        scope_keys
      ]
    )
  end

  defp issue_legacy_grant!(fixture) do
    subscription = %{
      id: fixture.subscription.id,
      user_id: fixture.subscription.user_id,
      current_period_end_at: fixture.subscription.current_period_end_at
    }

    target = %{
      entitlement_kind: fixture.effect.entitlement_kind,
      entitlement_scope_key: fixture.effect.entitlement_scope_key
    }

    case EntitlementsFacade.issue_subscription_source_grant_strict_for_system(
           subscription,
           target
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fetch_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp source_identity_snapshot!(subscription_id) do
    dumped_id = Ecto.UUID.dump!(subscription_id)

    %{
      subscriptions: persisted_ids!("SELECT id FROM subscriptions WHERE id = $1", [dumped_id]),
      items:
        persisted_ids!(
          "SELECT id FROM subscription_items WHERE subscription_id = $1 ORDER BY id",
          [dumped_id]
        ),
      effects:
        persisted_ids!(
          "SELECT id FROM access_effects WHERE subscription_id = $1 ORDER BY id",
          [dumped_id]
        ),
      grants:
        persisted_ids!(
          """
          SELECT id
          FROM entitlement_grants
          WHERE source_kind = 'subscription' AND source_id = $1
          ORDER BY id
          """,
          [dumped_id]
        )
    }
  end

  defp persisted_ids!(sql, params) do
    Repo.query!(sql, params).rows
    |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp await_lock_wait!(executor_pid, holder_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_lock_wait!(executor_pid, holder_pid, deadline, nil)
  end

  defp await_lock_wait!(executor_pid, holder_pid, deadline, last_observation) do
    %{rows: rows} =
      Repo.query!(
        "SELECT wait_event_type, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
        [executor_pid],
        timeout: 1_000
      )

    case rows do
      [["Lock", blockers]] ->
        if holder_pid in blockers do
          System.monotonic_time(:nanosecond)
        else
          retry_lock_wait!(executor_pid, holder_pid, deadline, rows)
        end

      _ ->
        retry_lock_wait!(executor_pid, holder_pid, deadline, last_observation || rows)
    end
  end

  defp retry_lock_wait!(executor_pid, holder_pid, deadline, last_observation) do
    if System.monotonic_time(:millisecond) < deadline do
      await_lock_wait!(executor_pid, holder_pid, deadline, last_observation)
    else
      flunk(
        "executor did not show the expected PostgreSQL lock wait: #{inspect(last_observation)}"
      )
    end
  end

  defp assert_effective_grant!(fixture) do
    assert [%EntitlementGrant{} = grant] = grants_for_source!(fixture.subscription.id)
    assert grant.status == :active
    assert grant.kind == fixture.effect.entitlement_kind
    assert grant.scope_key == fixture.effect.entitlement_scope_key
    assert grant.valid_from_at == fixture.effect.valid_from_at
    assert grant.valid_to_at == fixture.effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  defp cleanup_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)
      user_id = Ecto.UUID.dump!(fixture.subscription.user_id)

      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")

                 Repo.query!(
                   "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
                   [subscription_id]
                 )

                 Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!(
                   "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
                   [subscription_id]
                 )

                 Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
                   subscription_id
                 ])

                 Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
                 Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
                 Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
                 Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

                 Repo.query!(
                   "DELETE FROM variant_subscription_plans WHERE variant_id = $1",
                   [variant_id]
                 )

                 Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
                   plan_id
                 ])

                 Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
                 Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
                 Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

                 cleanup_checks = [
                   {"subscriptions", "SELECT count(*) FROM subscriptions WHERE id = $1",
                    subscription_id},
                   {"subscription_items",
                    "SELECT count(*) FROM subscription_items WHERE subscription_id = $1",
                    subscription_id},
                   {"access_effects",
                    "SELECT count(*) FROM access_effects WHERE subscription_id = $1",
                    subscription_id},
                   {"entitlement_grants",
                    "SELECT count(*) FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
                    subscription_id},
                   {"order_line_items", "SELECT count(*) FROM order_line_items WHERE id = $1",
                    line_item_id},
                   {"orders", "SELECT count(*) FROM orders WHERE id = $1", order_id}
                 ]

                 assert_fixture_rows_removed!(cleanup_checks)

                 :cleaned
               end)
    end)
  end

  defp assert_fixture_rows_removed!(cleanup_checks) do
    Enum.each(cleanup_checks, fn {table, query, id} ->
      assert %{rows: [[0]]} = Repo.query!(query, [id]),
             "committed fixture cleanup left rows in #{table}"
    end)
  end
end
