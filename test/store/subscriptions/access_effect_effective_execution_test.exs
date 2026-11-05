defmodule Store.Subscriptions.AccessEffectEffectiveExecutionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.Cache
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade}
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
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

          started_at = System.monotonic_time(:microsecond)

          {result, stats} =
            RepoStats.capture(fn ->
              Facade.execute_effective_access_effect_for_system(fixture.effect.id)
            end)

          duration_us = System.monotonic_time(:microsecond) - started_at
          {:memory, memory_after} = Process.info(self(), :memory)

          {gc_count_after, reclaimed_words_after, _} =
            :erlang.statistics(:garbage_collection)

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
            global_gc_count_delta: gc_count_after - gc_count_before,
            global_reclaimed_words_delta: reclaimed_words_after - reclaimed_words_before
          }

          {result, stats, resource}
        end)

      assert {:ok, :applied} = result
      assert resource.source_rows_before == 128
      assert resource.source_rows_after >= 128
      assert resource.active_rows_after == 1

      IO.puts(
        "JC245_RESOURCE repetition=#{repetition} exact_source_rows=#{resource.source_rows_before} " <>
          "rows_after=#{resource.source_rows_after} active_after=#{resource.active_rows_after} " <>
          "sql_queries=#{stats.query_count} convergence_duration_us=#{resource.duration_us} " <>
          "process_memory_delta_bytes=#{resource.memory_delta_bytes} " <>
          "global_gc_count_delta=#{resource.global_gc_count_delta} " <>
          "global_reclaimed_words_delta=#{resource.global_reclaimed_words_delta}"
      )
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

    {repair_result, repair_queries} =
      capture_repo_queries(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.repair_suspension_access_effect_projection_for_system(fixture.effect.id)
        end)
      end)

    assert :ok = repair_result
    refute Enum.any?(repair_queries, &entitlement_grant_dml_query?/1)

    repaired = fetch_effect!(fixture.effect.id)
    assert repaired.status == :applied
    assert %DateTime{} = repaired.projection_delivered_at
    assert repaired.projection_user_ids == [fixture.subscription.user_id]
    assert grants_for_source!(fixture.subscription.id) == before_repair
    assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(fixture.subscription.user_id))
    assert_receive {:entitlements_invalidated, user_id, "effective_access_effect_applied", _at}
    assert user_id == fixture.subscription.user_id
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
