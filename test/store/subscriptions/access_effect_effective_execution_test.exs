defmodule Store.Subscriptions.AccessEffectEffectiveExecutionTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

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
  alias Store.Subscriptions.Inputs.{EstablishAccessEffectInput, QueueSubscriptionPlanChangeInput}
  alias Store.Subscriptions.Inputs.ReconcileSubscriptionAccessInput
  alias Store.Subscriptions.Queries.AppliedAccessVerificationQuery
  alias Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize
  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.Telemetry.RepoStats
  alias Store.Workers.InventorySubscriptionAccessAuthorityWorker
  alias Store.Workers.ReconcileSubscriptionAccessWorker
  alias Store.Workers.VerifySubscriptionAccessWorker

  test "source reconciliation input accepts only typed UUID identities" do
    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             ReconcileSubscriptionAccessInput.new(%{
               subscription_id: Ecto.UUID.generate(),
               grant_id: Ecto.UUID.generate()
             })

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             ReconcileSubscriptionAccessInput.new(%{subscription_id: "bad"})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             ReconcileSubscriptionAccessInput.new(%{
               subscription_id: Ecto.UUID.generate(),
               expected_access_effect_id: "bad"
             })

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             ReconcileSubscriptionAccessInput.new(%{"subscription_id" => Ecto.UUID.generate()})
  end

  test "JC248 verification returns bounded exact grant drift" do
    fixture = create_committed_effective_effect_fixture!("jc248_sweep_api")

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.effect.id),
        ~U[2020-01-01 00:00:00Z]
      ])
    end)

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{as_of: ~U[2020-01-02 00:00:00Z], limit: 100})

    assert {{:ok, result}, stats} =
             RepoStats.capture(fn ->
               Facade.verify_subscription_access_window_for_system(query)
             end)

    assert stats.query_count == 2
    assert result.current_count == 1
    assert result.healthy_count == 0

    assert result.repairs == [
             %{
               subscription_id: fixture.subscription.id,
               expected_access_effect_id: fixture.effect.id
             }
           ]
  end

  @tag :jc248_resource_evidence
  test "JC248 discovery and repair have repeated bounded resource evidence" do
    for repetition <- 1..2 do
      fixtures =
        Enum.map(1..16, fn index ->
          create_committed_effective_effect_fixture!("jc248_resource_#{repetition}_#{index}")
        end)

      timestamp = DateTime.add(~U[2094-01-01 00:00:00Z], repetition, :day)

      try do
        Sandbox.unboxed_run(Repo, fn ->
          Enum.each(fixtures, fn fixture ->
            assert {:ok, :applied} =
                     Facade.execute_effective_access_effect_for_system(fixture.effect.id)

            insert_revoked_history!(fixture, 128, timestamp)

            Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
              Ecto.UUID.dump!(fixture.effect.id),
              timestamp
            ])
          end)
        end)

        assert {:ok, page_query} =
                 AppliedAccessVerificationQuery.new(%{
                   as_of: timestamp,
                   after_inserted_at: timestamp,
                   after_id: "00000000-0000-0000-0000-000000000000",
                   limit: 16
                 })

        for page_size <- [1, 16] do
          query = %{page_query | limit: page_size}

          sample =
            jc248_measure_operation!(fn ->
              Facade.verify_subscription_access_window_for_system(query)
            end)

          assert {:ok, result} = sample.result
          assert result.healthy_count == page_size
          assert result.raw_count == page_size
          assert result.repairs == []
          assert result.conflicts == []
          assert sample.stats.query_count == 2
          jc248_print_measurement!(sample, repetition, "healthy_verification_#{page_size}")
        end

        Sandbox.unboxed_run(Repo, fn ->
          ids = Enum.map(fixtures, & &1.subscription.id)
          assert {:ok, grants_query} = SubscriptionSourceVerificationQuery.new(%{source_ids: ids})
          sorted_ids = BinaryUuidSort.sort_uuids(ids)
          <<first::unsigned-big-128>> = Ecto.UUID.dump!(hd(sorted_ids))
          predecessor = Ecto.UUID.load!(<<first - 1::unsigned-big-128>>)

          assert {:ok, inventory_query} =
                   SubscriptionAccessInventoryQuery.new(%{
                     through_id: List.last(sorted_ids),
                     after_id: predecessor,
                     limit: 16
                   })

          for {operation, query} <- [
                {"applied_window", AppliedAccessVerificationQuery.to_ecto(page_query)},
                {"active_source_batch",
                 SubscriptionSourceVerificationQuery.to_ecto(grants_query)},
                {"authority_inventory", SubscriptionAccessInventoryQuery.to_ecto(inventory_query)}
              ] do
            {sql, params} = EctoSQL.to_sql(:all, Repo, query)

            %{rows: [[plan]]} =
              Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

            IO.puts(
              "JC248_RESOURCE_QUERY_PLAN " <>
                Jason.encode!(%{
                  repetition: repetition,
                  operation: operation,
                  plan: plan,
                  sources: 16,
                  initially_revoked_rows_per_source: 128,
                  explicit_statistics_refresh: false,
                  planner_override: false,
                  limits:
                    "natural local plan; fixture volume and existing private diagnostic rows only"
                })
            )
          end
        end)

        fixture = hd(fixtures)
        effect_before = fetch_effect!(fixture.effect.id)

        history_before =
          grants_for_source!(fixture.subscription.id)
          |> Enum.reject(&(&1.status == :active))

        assert length(history_before) == 128

        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!(
            "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1 AND status = 'active'",
            [Ecto.UUID.dump!(fixture.subscription.id)]
          )
        end)

        repair_sample =
          jc248_measure_operation!(fn ->
            Facade.repair_applied_access_effect_for_system(fixture.effect.id)
          end)

        assert repair_sample.result == {:ok, :repaired}
        assert fetch_effect!(fixture.effect.id) == effect_before
        after_grants = grants_for_source!(fixture.subscription.id)
        assert length(Enum.filter(after_grants, &(&1.status == :active))) == 1

        Enum.each(history_before, fn historical ->
          assert Enum.find(after_grants, &(&1.id == historical.id)) == historical
        end)

        jc248_print_measurement!(repair_sample, repetition, "applied_missing_grant_repair")

        stale_timestamp = DateTime.add(timestamp, 1, :second)

        Sandbox.unboxed_run(Repo, fn ->
          create_newer_untransitioned_effect!(fixture)

          Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
            Ecto.UUID.dump!(fixture.effect.id),
            stale_timestamp
          ])
        end)

        assert {:ok, stale_query} =
                 AppliedAccessVerificationQuery.new(%{
                   as_of: stale_timestamp,
                   after_inserted_at: stale_timestamp,
                   after_id: "00000000-0000-0000-0000-000000000000",
                   limit: 1
                 })

        stale_sample =
          jc248_measure_operation!(fn ->
            Facade.verify_subscription_access_window_for_system(stale_query)
          end)

        assert {:ok, %{raw_count: 1, stale_count: 1, repairs: []}} = stale_sample.result
        assert stale_sample.stats.query_count == 1
        jc248_print_measurement!(stale_sample, repetition, "stale_verification_1")

        if repetition == 2 do
          Sandbox.unboxed_run(Repo, fn ->
            ids = Enum.map(fixtures, & &1.subscription.id)

            assert {:ok, grants_query} =
                     SubscriptionSourceVerificationQuery.new(%{source_ids: ids})

            index_metadata_before = jc248_entitlement_index_metadata!()

            IO.puts(
              "JC248_RESOURCE_INDEX_METADATA " <>
                Jason.encode!(%{
                  phase: "before_explicit_analyze",
                  indexes: index_metadata_before
                })
            )

            {sql, params} =
              EctoSQL.to_sql(
                :all,
                Repo,
                SubscriptionSourceVerificationQuery.to_ecto(grants_query)
              )

            %{rows: [[before_plan]]} =
              Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

            IO.puts(
              "JC248_RESOURCE_QUERY_PLAN " <>
                Jason.encode!(%{
                  repetition: repetition,
                  operation: "active_source_batch_before_explicit_analyze",
                  plan: before_plan,
                  sources: 16,
                  initially_revoked_rows_per_source: 128,
                  explicit_statistics_refresh: false,
                  planner_override: false,
                  limits: "natural local plan before the authorized test-only ANALYZE"
                })
            )

            Repo.query!("ANALYZE entitlement_grants")
            index_metadata_after = jc248_entitlement_index_metadata!()

            IO.puts(
              "JC248_RESOURCE_INDEX_METADATA " <>
                Jason.encode!(%{phase: "after_explicit_analyze", indexes: index_metadata_after})
            )

            %{rows: [[after_plan]]} =
              Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

            IO.puts(
              "JC248_RESOURCE_QUERY_PLAN " <>
                Jason.encode!(%{
                  repetition: repetition,
                  operation: "active_source_batch_after_explicit_analyze",
                  plan: after_plan,
                  sources: 16,
                  initially_revoked_rows_per_source: 128,
                  explicit_statistics_refresh: true,
                  planner_override: false,
                  limits:
                    "test-only ANALYZE of entitlement_grants; fixture volume and local plan only"
                })
            )
          end)
        end
      after
        Enum.each(fixtures, &cleanup_fixture!/1)
      end

      Sandbox.unboxed_run(Repo, fn ->
        ids = Enum.map(fixtures, &Ecto.UUID.dump!(&1.subscription.id))

        for {table, predicate} <- [
              {"subscriptions", "id"},
              {"access_effects", "subscription_id"},
              {"entitlement_grants", "source_id"}
            ] do
          assert %{rows: [[0]]} =
                   Repo.query!(
                     "SELECT count(*) FROM " <>
                       table <> " WHERE " <> predicate <> " = ANY($1::uuid[])",
                     [ids]
                   )
        end
      end)

      IO.puts(
        "JC248_RESOURCE_CLEANUP " <>
          Jason.encode!(%{
            repetition: repetition,
            owned_subscription_rows: 0,
            owned_effect_rows: 0,
            owned_grant_rows: 0,
            limits: "owned fixture identities only; unrelated database rows preserved"
          })
      )
    end
  end

  test "JC248 verification worker queues exact drift and reports page counts" do
    fixture = create_committed_effective_effect_fixture!("jc248_sweep_worker")

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.effect.id),
        ~U[2020-01-01 00:00:00Z]
      ])
    end)

    handler_id = "jc248-verification-page-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :access_verification, :page],
        fn event, measurements, metadata, pid ->
          send(pid, {:verification_page, event, measurements, metadata})
        end,
        self()
      )

    try do
      assert :ok =
               Sandbox.unboxed_run(Repo, fn ->
                 VerifySubscriptionAccessWorker.perform(%Oban.Job{
                   args: %{"as_of" => "2020-01-02T00:00:00Z", "limit" => 100}
                 })
               end)

      assert_enqueued(
        worker: ReconcileSubscriptionAccessWorker,
        args: %{
          "subscription_id" => fixture.subscription.id,
          "expected_access_effect_id" => fixture.effect.id
        }
      )

      assert_receive {:verification_page, [:store, :subscriptions, :access_verification, :page],
                      %{raw_count: 1, repair_count: 1}, _metadata}
    after
      :ok = :telemetry.detach(handler_id)
    end
  end

  test "JC248 verification rediscovers lost source jobs after completed and discarded attempt five" do
    fixture = create_committed_effective_effect_fixture!("jc248_sweep_rediscovery")

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.effect.id),
        ~U[2020-01-01 00:00:00Z]
      ])
    end)

    verification_job = %Oban.Job{args: %{"as_of" => "2020-01-02T00:00:00Z", "limit" => 100}}

    for _attempt <- 1..2 do
      assert :ok =
               Sandbox.unboxed_run(Repo, fn ->
                 VerifySubscriptionAccessWorker.perform(verification_job)
               end)
    end

    assert source_reconciliation_job_ids(fixture) |> length() == 1

    mark_source_reconciliation_jobs_terminal!(fixture, "completed")

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               VerifySubscriptionAccessWorker.perform(verification_job)
             end)

    assert source_reconciliation_job_ids(fixture) |> length() == 2

    mark_source_reconciliation_jobs_terminal!(fixture, "discarded")

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               VerifySubscriptionAccessWorker.perform(verification_job)
             end)

    assert source_reconciliation_job_ids(fixture) |> length() == 3

    before_effect = fetch_effect!(fixture.effect.id)

    before_source =
      Sandbox.unboxed_run(Repo, fn -> source_identity_snapshot!(fixture.subscription.id) end)

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               ReconcileSubscriptionAccessWorker.perform(%Oban.Job{
                 args: %{
                   "subscription_id" => fixture.subscription.id,
                   "expected_access_effect_id" => fixture.effect.id
                 }
               })
             end)

    assert fetch_effect!(fixture.effect.id) == before_effect

    after_source =
      Sandbox.unboxed_run(Repo, fn -> source_identity_snapshot!(fixture.subscription.id) end)

    assert Map.drop(after_source, [:grants]) == Map.drop(before_source, [:grants])
    assert before_source.grants == []

    assert [%EntitlementGrant{} = grant] = grants_for_source!(fixture.subscription.id)
    assert grant.id not in before_source.grants
    assert grant.user_id == fixture.subscription.user_id
    assert grant.kind == before_effect.entitlement_kind
    assert grant.scope_key == before_effect.entitlement_scope_key
    assert grant.source_kind == :subscription
    assert grant.source_id == fixture.subscription.id
    assert grant.status == :active
    assert grant.valid_from_at == before_effect.valid_from_at
    assert grant.valid_to_at == before_effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  test "JC248 verification reports fingerprint-valid provenance conflicts without repair" do
    fixture = create_committed_effective_effect_fixture!("jc248_sweep_conflict")
    other = create_committed_effective_effect_fixture!("jc248_sweep_conflict_other")

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("UPDATE subscriptions SET current_plan_revision_id = $2 WHERE id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id),
          Ecto.UUID.dump!(fixture.revision.id)
        ])
      end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      Repo.query!("UPDATE subscriptions SET current_plan_revision_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.subscription.id),
        Ecto.UUID.dump!(other.revision.id)
      ])

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.effect.id),
        ~U[2020-01-01 00:00:00Z]
      ])
    end)

    before = grants_for_source!(fixture.subscription.id)

    assert AccessEffect.persisted_fingerprint_status(fetch_effect!(fixture.effect.id)) in [
             :v2_match,
             :v1_legacy_match
           ]

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{as_of: ~U[2020-01-02 00:00:00Z], limit: 100})

    assert {:ok, result} = Facade.verify_subscription_access_window_for_system(query)

    assert result.conflicts == [
             %{
               subscription_id: fixture.subscription.id,
               access_effect_id: fixture.effect.id,
               reason: :invalid_authority
             }
           ]

    assert result.repairs == []
    assert grants_for_source!(fixture.subscription.id) == before
    assert fetch_effect!(fixture.effect.id).status == :applied

    handler_id = "jc248-verification-conflict-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :access_verification, :conflict],
        fn event, measurements, metadata, pid ->
          send(pid, {:verification_conflict, event, measurements, metadata})
        end,
        self()
      )

    try do
      assert :ok =
               Sandbox.unboxed_run(Repo, fn ->
                 VerifySubscriptionAccessWorker.perform(%Oban.Job{
                   args: %{"as_of" => "2020-01-02T00:00:00Z", "limit" => 100}
                 })
               end)

      assert_receive {:verification_conflict,
                      [:store, :subscriptions, :access_verification, :conflict], %{count: 1},
                      %{subscription_id: conflict_id, reason: :invalid_authority}}

      assert conflict_id == fixture.subscription.id
    after
      :ok = :telemetry.detach(handler_id)
    end
  end

  test "JC248 verification keeps two reads at sixteen sources with revoked history" do
    fixtures =
      Enum.map(1..16, fn index ->
        create_committed_effective_effect_fixture!("jc248_sweep_fanout_#{index}")
      end)

    inserted_at = ~U[2090-01-01 00:00:00Z]

    Sandbox.unboxed_run(Repo, fn ->
      Enum.each(fixtures, fn fixture ->
        assert {:ok, :applied} =
                 Facade.execute_effective_access_effect_for_system(fixture.effect.id)

        insert_revoked_history!(fixture, 32, inserted_at)

        Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
          Ecto.UUID.dump!(fixture.effect.id),
          inserted_at
        ])
      end)
    end)

    first_uuid = "00000000-0000-0000-0000-000000000000"

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: ~U[2090-01-02 00:00:00Z],
               after_inserted_at: inserted_at,
               after_id: first_uuid,
               limit: 16
             })

    assert {{:ok, result}, stats} =
             RepoStats.capture(fn ->
               Facade.verify_subscription_access_window_for_system(query)
             end)

    assert stats.query_count == 2
    assert result.raw_count == 16
    assert result.current_count == 16
    assert result.healthy_count == 16
    assert result.repairs == []
    assert result.conflicts == []
  end

  test "JC248 verification cursor advances through stale raw rows" do
    stale = create_committed_effective_effect_fixture!("jc248_sweep_stale")
    current = create_committed_effective_effect_fixture!("jc248_sweep_current")
    stale_at = ~U[2091-01-01 00:00:00Z]
    current_at = ~U[2092-01-01 00:00:00Z]

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} = Facade.execute_effective_access_effect_for_system(stale.effect.id)
      _newer = create_newer_untransitioned_effect!(stale)

      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(current.effect.id)

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(stale.effect.id),
        stale_at
      ])

      Repo.query!("UPDATE access_effects SET inserted_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(current.effect.id),
        current_at
      ])

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(current.subscription.id)]
      )
    end)

    assert {:ok, first} =
             AppliedAccessVerificationQuery.new(%{
               as_of: ~U[2093-01-01 00:00:00Z],
               after_inserted_at: ~U[2090-01-01 00:00:00Z],
               after_id: "00000000-0000-0000-0000-000000000000",
               limit: 1
             })

    assert {:ok, first_result} = Facade.verify_subscription_access_window_for_system(first)
    assert first_result.stale_count == 1
    assert DateTime.compare(first_result.cursor.timestamp, stale_at) == :eq
    assert first_result.cursor.id == stale.effect.id

    assert {:ok, second} =
             AppliedAccessVerificationQuery.new(%{
               as_of: first.as_of,
               after_inserted_at: first_result.cursor.timestamp,
               after_id: first_result.cursor.id,
               limit: 1
             })

    assert {:ok, second_result} = Facade.verify_subscription_access_window_for_system(second)
    assert second_result.current_count == 1

    assert second_result.repairs == [
             %{
               subscription_id: current.subscription.id,
               expected_access_effect_id: current.effect.id
             }
           ]

    first_args = %{
      "as_of" => "2093-01-01T00:00:00Z",
      "after_inserted_at" => "2090-01-01T00:00:00Z",
      "after_id" => "00000000-0000-0000-0000-000000000000",
      "limit" => 1
    }

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{args: first_args})
             end)

    continuation_args = %{
      "as_of" => DateTime.to_iso8601(first_result.as_of),
      "after_inserted_at" => DateTime.to_iso8601(first_result.cursor.timestamp),
      "after_id" => stale.effect.id,
      "limit" => 1
    }

    assert_enqueued(worker: VerifySubscriptionAccessWorker, args: continuation_args)

    assert %{num_rows: 1} =
             Store.DirectRepo.query!(
               "DELETE FROM oban_jobs WHERE worker = $1 AND args = $2::jsonb",
               [
                 "Store.Workers.VerifySubscriptionAccessWorker",
                 continuation_args
               ]
             )

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{args: first_args})
             end)

    assert_enqueued(worker: VerifySubscriptionAccessWorker, args: continuation_args)

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{args: continuation_args})
             end)

    assert_enqueued(
      worker: ReconcileSubscriptionAccessWorker,
      args: %{
        "subscription_id" => current.subscription.id,
        "expected_access_effect_id" => current.effect.id
      }
    )
  end

  test "JC248 inventory reports missing authority without enqueueing source work" do
    healthy = create_committed_effective_effect_fixture!("jc248_inventory_healthy")
    fixture = create_committed_effective_effect_fixture!("jc248_inventory_missing")

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

      Repo.query!("DELETE FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(fixture.effect.id)])
    end)

    source_before =
      Sandbox.unboxed_run(Repo, fn -> source_identity_snapshot!(fixture.subscription.id) end)

    <<healthy_uuid_integer::unsigned-big-128>> = Ecto.UUID.dump!(healthy.subscription.id)
    predecessor_id = Ecto.UUID.load!(<<healthy_uuid_integer - 1::unsigned-big-128>>)

    handler_id = "jc248-inventory-missing-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:store, :subscriptions, :access_authority_inventory, :missing],
          [:store, :subscriptions, :access_authority_inventory, :page]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:inventory_telemetry, event, measurements, metadata})
        end,
        self()
      )

    continuation_args = %{
      "through_id" => fixture.subscription.id,
      "after_id" => healthy.subscription.id,
      "limit" => 1
    }

    try do
      assert :ok =
               Sandbox.unboxed_run(Repo, fn ->
                 InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
                   args: %{
                     "through_id" => fixture.subscription.id,
                     "after_id" => predecessor_id,
                     "limit" => 1
                   }
                 })
               end)

      assert_enqueued(worker: InventorySubscriptionAccessAuthorityWorker, args: continuation_args)

      assert_receive {:inventory_telemetry,
                      [:store, :subscriptions, :access_authority_inventory, :page],
                      %{raw_count: 1, missing_count: 0}, _metadata}

      assert :ok =
               Sandbox.unboxed_run(Repo, fn ->
                 InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
                   args: continuation_args
                 })
               end)

      assert_receive {:inventory_telemetry,
                      [:store, :subscriptions, :access_authority_inventory, :page],
                      %{raw_count: 1, missing_count: 1}, _metadata}

      assert_receive {:inventory_telemetry,
                      [:store, :subscriptions, :access_authority_inventory, :missing],
                      %{count: 1},
                      %{subscription_id: subscription_id, classification: :unclassified}}

      assert subscription_id == fixture.subscription.id

      assert Sandbox.unboxed_run(Repo, fn ->
               source_identity_snapshot!(fixture.subscription.id)
             end) == source_before

      assert grants_for_source!(fixture.subscription.id) == []
      assert Sandbox.unboxed_run(Repo, fn -> Repo.get(AccessEffect, fixture.effect.id) end) == nil

      refute_enqueued(worker: ReconcileSubscriptionAccessWorker)
    after
      :ok = :telemetry.detach(handler_id)
    end
  end

  test "JC248 verification rejects invalid arguments and worker cursor parsing" do
    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{as_of: ~U[2020-01-02 00:00:00Z], limit: 1})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Facade.verify_subscription_access_window_for_system(%{query | limit: 0})

    assert {:discard, _} =
             VerifySubscriptionAccessWorker.perform(%Oban.Job{args: %{"as_of" => nil}})

    assert {:discard, _} =
             VerifySubscriptionAccessWorker.perform(%Oban.Job{
               args: %{
                 "as_of" => DateTime.to_iso8601(query.as_of),
                 "after_id" => Ecto.UUID.generate()
               }
             })

    assert {{:discard, _}, half_cursor_stats} =
             RepoStats.capture(fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{
                 args: %{
                   "as_of" => DateTime.to_iso8601(query.as_of),
                   "after_id" => Ecto.UUID.generate(),
                   "after_inserted_at" => nil
                 }
               })
             end)

    assert half_cursor_stats.query_count == 0

    assert {{:discard, _}, null_cursor_stats} =
             RepoStats.capture(fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{
                 args: %{
                   "as_of" => DateTime.to_iso8601(query.as_of),
                   "after_id" => nil,
                   "after_inserted_at" => nil
                 }
               })
             end)

    assert null_cursor_stats.query_count == 0

    assert {{:discard, _}, cursor_stats} =
             RepoStats.capture(fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{
                 args: %{
                   "after_inserted_at" => DateTime.to_iso8601(query.as_of),
                   "after_id" => Ecto.UUID.generate()
                 }
               })
             end)

    assert cursor_stats.query_count == 0

    assert {:discard, _} =
             InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
               args: %{"through_id" => nil}
             })

    assert {{:discard, _}, inventory_stats} =
             RepoStats.capture(fn ->
               InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
                 args: %{"after_id" => Ecto.UUID.generate()}
               })
             end)

    assert inventory_stats.query_count == 0

    assert {{:discard, _}, null_inventory_cursor_stats} =
             RepoStats.capture(fn ->
               InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
                 args: %{"through_id" => Ecto.UUID.generate(), "after_id" => nil}
               })
             end)

    assert null_inventory_cursor_stats.query_count == 0

    assert {{:discard, _}, limit_stats} =
             RepoStats.capture(fn ->
               InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
                 args: %{"limit" => 0}
               })
             end)

    assert limit_stats.query_count == 0

    assert {:discard, _} =
             InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
               args: %{"through_id" => Ecto.UUID.generate(), "unknown" => true}
             })
  end

  @tag :jc248_continuation_validation
  test "verification continuation without its page limit is discarded before SQL" do
    assert {{:discard, _}, stats} =
             RepoStats.capture(fn ->
               VerifySubscriptionAccessWorker.perform(%Oban.Job{
                 args: %{
                   "as_of" => "1990-01-01T00:00:00Z",
                   "after_inserted_at" => "1990-01-01T00:00:00Z",
                   "after_id" => "00000000-0000-0000-0000-000000000001"
                 }
               })
             end)

    assert stats.query_count == 0
  end

  @tag :jc248_continuation_validation
  test "inventory continuation without its page limit is discarded before SQL" do
    assert {{:discard, _}, stats} =
             RepoStats.capture(fn ->
               InventorySubscriptionAccessAuthorityWorker.perform(%Oban.Job{
                 args: %{
                   "through_id" => "00000000-0000-0000-0000-000000000002",
                   "after_id" => "00000000-0000-0000-0000-000000000001"
                 }
               })
             end)

    assert stats.query_count == 0
  end

  test "source reconciliation repairs current effective authority and worker reports outcomes" do
    fixture = create_committed_effective_effect_fixture!("jc248_reconcile_effective")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    assert fetch_effect!(fixture.effect.id).status == :applied
    assert [grant] = grants_for_source!(fixture.subscription.id)
    effect_snapshot = fetch_effect!(fixture.effect.id)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [
          Ecto.UUID.dump!(fixture.subscription.id)
        ]
      )
    end)

    handler_id = "jc248-reconcile-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :source_reconciliation, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:source_reconciliation, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               ReconcileSubscriptionAccessWorker.perform(%Oban.Job{
                 args: %{"subscription_id" => fixture.subscription.id}
               })
             end)

    assert fetch_effect!(fixture.effect.id) == effect_snapshot
    assert [repaired] = grants_for_source!(fixture.subscription.id)
    assert repaired.status == :active
    assert repaired.kind == grant.kind
    assert repaired.scope_key == grant.scope_key
    assert repaired.valid_from_at == grant.valid_from_at
    assert repaired.valid_to_at == grant.valid_to_at

    assert_receive {:source_reconciliation,
                    [:store, :subscriptions, :source_reconciliation, :stop],
                    %{duration: duration},
                    %{
                      subscription_id: subscription_id,
                      access_effect_id: nil,
                      outcome: :repaired
                    }}

    assert is_integer(duration)
    assert subscription_id == fixture.subscription.id

    assert {:discard, _} =
             ReconcileSubscriptionAccessWorker.perform(%Oban.Job{
               args: %{"subscription_id" => "bad", "extra" => true}
             })
  end

  test "funded entitlement remains executable after a future plan is queued and the Plan is edited" do
    fixture = create_committed_effective_effect_fixture!("jc248_queued_future_contract")

    future_plan =
      Sandbox.unboxed_run(Repo, fn ->
        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            entitlement_kind: :membership_access,
            entitlement_scope_key: "future:#{Ecto.UUID.generate()}"
          })

        SubscriptionsFixtures.create_plan_revision!(plan)
        SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, plan.id)
        plan
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          UPDATE subscriptions
          SET current_contract_change_id = NULL,
              pending_subscription_plan_id = NULL,
              pending_variant_id = NULL,
              pending_renewal_amount_minor = NULL,
              pending_renewal_currency = NULL,
              change_effective_at = NULL
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(fixture.subscription.id)]
        )

        Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id)
        ])

        Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id)
        ])

        Repo.query!("DELETE FROM variant_subscription_plans WHERE subscription_plan_id = $1", [
          Ecto.UUID.dump!(future_plan.id)
        ])

        Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
          Ecto.UUID.dump!(future_plan.id)
        ])

        Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [
          Ecto.UUID.dump!(future_plan.id)
        ])
      end)
    end)

    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: fixture.subscription.id,
               subscription_plan_id: future_plan.id
             })

    assert {:ok, queued} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.queue_subscription_plan_change_for_user(
                 fixture.customer,
                 fixture.subscription.id,
                 input
               )
             end)

    assert queued.current_contract_change_id
    assert queued.aggregate_version > fixture.effect.source_version
    assert queued.current_plan_revision_id == fixture.effect.plan_revision_id

    original_plan =
      Sandbox.unboxed_run(Repo, fn ->
        fixture.plan
        |> Ash.Changeset.for_update(
          :update,
          %{entitlement_scope_key: "mutable-plan:#{Ecto.UUID.generate()}"},
          context: %{system?: true}
        )
        |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      end)

    assert original_plan.entitlement_scope_key != fixture.effect.entitlement_scope_key

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    applied_effect = fetch_effect!(fixture.effect.id)
    assert applied_effect.status == :applied
    assert applied_effect.plan_revision_id == fixture.effect.plan_revision_id
    assert applied_effect.entitlement_scope_key == fixture.effect.entitlement_scope_key

    assert_effective_grant!(fixture)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [
          Ecto.UUID.dump!(fixture.subscription.id)
        ]
      )
    end)

    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    assert fetch_effect!(fixture.effect.id) == applied_effect
    assert_effective_grant!(fixture)

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: DateTime.add(DateTime.utc_now(), 1, :second)
             })

    assert {:ok, verifications} = Facade.list_applied_access_verification_window_for_system(query)
    assert verification = Enum.find(verifications, &(&1.effect.id == fixture.effect.id))

    assert verification.contract_reference == %{
             id: nil,
             subscription_id: nil,
             ordering_version: nil
           }
  end

  test "a captured ContractChange survives supersession and requires its original source owner" do
    fixture = create_committed_effective_effect_fixture!("jc248_historical_contract_reference")

    future_plans =
      Sandbox.unboxed_run(Repo, fn ->
        Enum.map(1..2, fn index ->
          plan =
            SubscriptionsFixtures.create_subscription_plan!(%{
              entitlement_kind: :membership_access,
              entitlement_scope_key: "historical:#{index}:#{Ecto.UUID.generate()}"
            })

          SubscriptionsFixtures.create_plan_revision!(plan)
          SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, plan.id)
          plan
        end)
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          UPDATE subscriptions
          SET current_contract_change_id = NULL,
              pending_subscription_plan_id = NULL,
              pending_variant_id = NULL,
              pending_renewal_amount_minor = NULL,
              pending_renewal_currency = NULL,
              change_effective_at = NULL
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(fixture.subscription.id)]
        )

        Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id)
        ])

        Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id)
        ])

        Enum.each(future_plans, fn plan ->
          Repo.query!("DELETE FROM variant_subscription_plans WHERE subscription_plan_id = $1", [
            Ecto.UUID.dump!(plan.id)
          ])

          Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
            Ecto.UUID.dump!(plan.id)
          ])

          Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [Ecto.UUID.dump!(plan.id)])
        end)
      end)
    end)

    [first_plan, second_plan] = future_plans

    assert {:ok, first_input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: fixture.subscription.id,
               subscription_plan_id: first_plan.id
             })

    assert {:ok, first_queued} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.queue_subscription_plan_change_for_user(
                 fixture.customer,
                 fixture.subscription.id,
                 first_input
               )
             end)

    assert {:ok, effect_input} =
             EstablishAccessEffectInput.new(%{
               subscription_id: fixture.subscription.id,
               source_version: first_queued.aggregate_version,
               disposition: fixture.effect.disposition,
               entitlement_kind: fixture.effect.entitlement_kind,
               entitlement_scope_key: fixture.effect.entitlement_scope_key,
               valid_from_at: fixture.effect.valid_from_at,
               valid_until_at: fixture.effect.valid_until_at,
               source_order_line_item_id: fixture.effect.source_order_line_item_id,
               contract_change_id: first_queued.current_contract_change_id,
               plan_revision_id: fixture.effect.plan_revision_id
             })

    assert {:ok, historical_effect} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.establish_access_effect_for_system(effect_input)
             end)

    assert {:ok, second_input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: fixture.subscription.id,
               subscription_plan_id: second_plan.id
             })

    assert {:ok, superseding_queue} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.queue_subscription_plan_change_for_user(
                 fixture.customer,
                 fixture.subscription.id,
                 second_input
               )
             end)

    assert superseding_queue.current_contract_change_id != historical_effect.contract_change_id

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    applied_effect = fetch_effect!(historical_effect.id)
    assert applied_effect.status == :applied
    assert_effective_grant!(%{fixture | effect: historical_effect})

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [
          Ecto.UUID.dump!(fixture.subscription.id)
        ]
      )
    end)

    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    assert fetch_effect!(historical_effect.id) == applied_effect
    assert_effective_grant!(%{fixture | effect: historical_effect})

    assert {:ok, query} =
             AppliedAccessVerificationQuery.new(%{
               as_of: DateTime.add(DateTime.utc_now(), 1, :second)
             })

    assert {:ok, verifications} = Facade.list_applied_access_verification_window_for_system(query)
    assert verification = Enum.find(verifications, &(&1.effect.id == historical_effect.id))

    assert verification.contract_reference == %{
             id: historical_effect.contract_change_id,
             subscription_id: fixture.subscription.id,
             ordering_version: historical_effect.source_version
           }

    foreign = create_committed_effective_effect_fixture!("jc248_foreign_contract_owner")
    grants_before = grants_for_source!(fixture.subscription.id)
    reference_id = Ecto.UUID.dump!(historical_effect.contract_change_id)

    try do
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("UPDATE contract_changes SET subscription_id = $2 WHERE id = $1", [
          reference_id,
          Ecto.UUID.dump!(foreign.subscription.id)
        ])
      end)

      assert {:error, %Error{code: "VALIDATION_ERROR"}} =
               Sandbox.unboxed_run(Repo, fn ->
                 Facade.repair_applied_access_effect_for_system(historical_effect.id)
               end)

      assert fetch_effect!(historical_effect.id) == applied_effect
      assert grants_for_source!(fixture.subscription.id) == grants_before
      assert grants_for_source!(foreign.subscription.id) == []
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("UPDATE contract_changes SET subscription_id = $2 WHERE id = $1", [
          reference_id,
          Ecto.UUID.dump!(fixture.subscription.id)
        ])
      end)
    end
  end

  test "source reconciliation rejects a too-new captured ContractChange without writes" do
    fixture = create_committed_effective_effect_fixture!("jc248_bad_contract_reference")
    before_effect = fetch_effect!(fixture.effect.id)
    before_grants = grants_for_source!(fixture.subscription.id)

    future_plan =
      Sandbox.unboxed_run(Repo, fn ->
        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            entitlement_kind: :membership_access,
            entitlement_scope_key: "too-new:#{Ecto.UUID.generate()}"
          })

        SubscriptionsFixtures.create_plan_revision!(plan)
        SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, plan.id)
        plan
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("UPDATE access_effects SET contract_change_id = $2 WHERE id = $1", [
          Ecto.UUID.dump!(fixture.effect.id),
          before_effect.contract_change_id && Ecto.UUID.dump!(before_effect.contract_change_id)
        ])

        recompute_v2_fingerprint!(fixture.effect.id)

        Repo.query!(
          """
          UPDATE subscriptions
          SET current_contract_change_id = NULL,
              pending_subscription_plan_id = NULL,
              pending_variant_id = NULL,
              pending_renewal_amount_minor = NULL,
              pending_renewal_currency = NULL,
              change_effective_at = NULL
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(fixture.subscription.id)]
        )

        Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id)
        ])

        Repo.query!("DELETE FROM variant_subscription_plans WHERE subscription_plan_id = $1", [
          Ecto.UUID.dump!(future_plan.id)
        ])

        Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [
          Ecto.UUID.dump!(future_plan.id)
        ])

        Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [
          Ecto.UUID.dump!(future_plan.id)
        ])
      end)
    end)

    assert {:ok, future_input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: fixture.subscription.id,
               subscription_plan_id: future_plan.id
             })

    assert {:ok, future_change} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.queue_subscription_plan_change_for_user(
                 fixture.customer,
                 fixture.subscription.id,
                 future_input
               )
             end)

    too_new_effect = %{
      before_effect
      | contract_change_id: future_change.current_contract_change_id
    }

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE access_effects SET contract_change_id = $2, target_fingerprint = $3 WHERE id = $1",
        [
          Ecto.UUID.dump!(too_new_effect.id),
          Ecto.UUID.dump!(too_new_effect.contract_change_id),
          AccessEffect.target_fingerprint(too_new_effect)
        ]
      )
    end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    assert fetch_effect!(fixture.effect.id) == %{
             too_new_effect
             | target_fingerprint: AccessEffect.target_fingerprint(too_new_effect)
           }

    assert grants_for_source!(fixture.subscription.id) == before_grants
  end

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

    assert {:ok, stats} =
             RepoStats.capture(fn ->
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
               :ok
             end)

    assert stats.query_count == 0
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

  test "authority inventory validates fixed UUID bounds" do
    [first, last] = BinaryUuidSort.sort_uuids([Ecto.UUID.generate(), Ecto.UUID.generate()])

    assert {:ok, _} =
             SubscriptionAccessInventoryQuery.new(%{through_id: last, after_id: first, limit: 1})

    for attrs <- [
          %{through_id: "bad"},
          %{through_id: first, after_id: last},
          %{through_id: last, limit: 501},
          %{through_id: last, status: :active}
        ] do
      assert {:error, %Error{code: "VALIDATION_ERROR"}} =
               SubscriptionAccessInventoryQuery.new(attrs)
    end
  end

  test "authority inventory action rejects ordinary callers before SQL" do
    input =
      Ash.ActionInput.for_action(
        Store.Subscriptions.Subscription,
        :read_access_inventory_window_for_system,
        %{through_id: Ecto.UUID.generate(), limit: 1},
        domain: Store.Subscriptions
      )

    assert {:ok, stats} =
             RepoStats.capture(fn ->
               assert {:error, reason} = Ash.run_action(input, authorize?: true)
               assert %Error{code: "FORBIDDEN"} = Normalize.normalize(reason)
               :ok
             end)

    assert stats.query_count == 0
  end

  test "authority inventory captures the database's native highest UUID" do
    _fixture = create_committed_effective_effect_fixture!("jc248_inventory_frontier")

    %{rows: [[expected]]} =
      Repo.query!("SELECT id::text FROM subscriptions ORDER BY id DESC LIMIT 1")

    assert {:ok, ^expected} = Facade.subscription_access_inventory_upper_bound_for_system()
  end

  test "authority inventory consumes healthy raw rows and exposes missing authority without writes" do
    fixtures =
      for index <- 1..3,
          do: create_committed_effective_effect_fixture!("jc248_inventory_#{index}")

    ordered = Enum.sort_by(fixtures, &Ecto.UUID.dump!(&1.subscription.id))
    [healthy, missing, later] = ordered

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DELETE FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(missing.effect.id)])
    end)

    before = source_identity_snapshot!(missing.subscription.id)
    <<numeric_id::unsigned-big-integer-size(128)>> = Ecto.UUID.dump!(healthy.subscription.id)
    predecessor = Ecto.UUID.load!(<<numeric_id - 1::unsigned-big-integer-size(128)>>)

    assert {:ok, first} =
             SubscriptionAccessInventoryQuery.new(%{
               through_id: missing.subscription.id,
               after_id: predecessor,
               limit: 1
             })

    {inventory_sql, inventory_params} =
      EctoSQL.to_sql(:all, Repo, SubscriptionAccessInventoryQuery.to_ecto(first))

    [_outer_select, window_and_rest] = String.split(inventory_sql, "FROM (", parts: 2)
    [raw_window_sql | _outer_order] = String.split(window_and_rest, ") AS s0", parts: 2)

    assert raw_window_sql =~ "LIMIT"
    refute raw_window_sql =~ "exists("
    assert inventory_sql =~ "exists("

    %{rows: [[inventory_plan]]} =
      Repo.query!(
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> inventory_sql,
        inventory_params
      )

    IO.puts(
      "JC248_AUTHORITY_INVENTORY_QUERY_PLAN " <>
        Jason.encode!(%{
          operation: "subscription_access_inventory_window",
          raw_window_limit: 1,
          sql: inventory_sql,
          plan: inventory_plan,
          limits: "three committed fixture rows; small-volume planner observation only"
        })
    )

    {{:ok, [%{id: healthy_id, has_access_effect?: true}] = page}, stats} =
      RepoStats.capture(fn ->
        Facade.list_subscription_access_inventory_window_for_system(first)
      end)

    assert healthy_id == healthy.subscription.id
    assert stats.query_count == 1

    assert {:ok, after_healthy} =
             SubscriptionAccessInventoryQuery.new(%{
               through_id: missing.subscription.id,
               after_id: healthy.subscription.id,
               limit: 1
             })

    assert {:ok, [%{id: missing_id, has_access_effect?: false}]} =
             Facade.list_subscription_access_inventory_window_for_system(after_healthy)

    assert missing_id == missing.subscription.id

    assert {:ok, done} =
             SubscriptionAccessInventoryQuery.new(%{
               through_id: missing.subscription.id,
               after_id: missing.subscription.id,
               limit: 1
             })

    assert {:ok, []} = Facade.list_subscription_access_inventory_window_for_system(done)
    assert source_identity_snapshot!(missing.subscription.id) == before
    assert grants_for_source!(missing.subscription.id) == []
    assert {:ok, nil} = Facade.get_current_access_effect_for_system(missing.subscription)
    refute later.subscription.id in Enum.map(page, & &1.id)
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

  test "source reconciliation returns stale expected authority without executing it" do
    fixture = create_committed_effective_effect_fixture!("jc248_reconcile_stale")
    before_effect = fetch_effect!(fixture.effect.id)
    before_grants = grants_for_source!(fixture.subscription.id)

    assert {:ok, :stale} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id,
                 expected_access_effect_id: Ecto.UUID.generate()
               })
             end)

    assert fetch_effect!(fixture.effect.id) == before_effect
    assert grants_for_source!(fixture.subscription.id) == before_grants
  end

  test "source reconciliation rejects caller transactions and missing durable authority" do
    fixture = create_committed_effective_effect_fixture!("jc248_reconcile_missing")
    effect_before_transaction = fetch_effect!(fixture.effect.id)
    grants_before_transaction = grants_for_source!(fixture.subscription.id)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Facade.reconcile_subscription_access_for_system(
                   %ReconcileSubscriptionAccessInput{
                     subscription_id: fixture.subscription.id
                   }
                 )
               end)
               |> elem(1)
             end)

    assert fetch_effect!(fixture.effect.id) == effect_before_transaction
    assert grants_for_source!(fixture.subscription.id) == grants_before_transaction

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DELETE FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(fixture.effect.id)])
    end)

    assert {:error,
            %Error{
              code: "VALIDATION_ERROR",
              meta: %{reason: :missing_access_effect, classification: :unclassified}
            }} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    assert grants_for_source!(fixture.subscription.id) == []

    assert {:ok, nil} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.get_current_access_effect_for_system(fixture.subscription)
             end)
  end

  test "source reconciliation rejects provenance drift before changing authority or grants" do
    fixture = create_committed_effective_effect_fixture!("jc248_reconcile_provenance")
    foreign = create_committed_effective_effect_fixture!("jc248_reconcile_foreign")
    before_effect = fetch_effect!(fixture.effect.id)
    before_grants = grants_for_source!(fixture.subscription.id)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("UPDATE subscriptions SET current_plan_revision_id = $2 WHERE id = $1", [
          Ecto.UUID.dump!(fixture.subscription.id),
          Ecto.UUID.dump!(fixture.revision.id)
        ])
      end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("UPDATE subscriptions SET current_plan_revision_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(fixture.subscription.id),
        Ecto.UUID.dump!(foreign.revision.id)
      ])
    end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_subscription_access_for_system(%ReconcileSubscriptionAccessInput{
                 subscription_id: fixture.subscription.id
               })
             end)

    assert fetch_effect!(fixture.effect.id) == before_effect
    assert grants_for_source!(fixture.subscription.id) == before_grants
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

  test "APPLIED repair restores the whole source and preserves other users and history" do
    fixture = create_committed_effective_effect_fixture!("jc248_exact_pair")
    independent = create_committed_effective_effect_fixture!("jc248_exact_independent")

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(independent.effect.id)

      [original] = grants_for_source!(fixture.subscription.id)

      Repo.query!(
        "UPDATE entitlement_grants SET user_id = $2, kind = 'discount_tier', scope_key = $3 WHERE id = $1",
        [
          Ecto.UUID.dump!(original.id),
          Ecto.UUID.dump!(independent.subscription.user_id),
          "#{fixture.effect.id}:wrong-target"
        ]
      )

      create_grant!(fixture, "#{fixture.effect.id}:obsolete-active", fixture.effect.valid_from_at)
      insert_revoked_history!(fixture, 1, DateTime.utc_now())
    end)

    effect_before = fetch_effect!(fixture.effect.id)
    source_before = grants_for_source!(fixture.subscription.id)
    inactive_before = Enum.reject(source_before, &(&1.status == :active))
    obsolete_ids = source_before |> Enum.filter(&(&1.status == :active)) |> Enum.map(& &1.id)
    independent_before = grants_for_source!(independent.subscription.id)
    assert length(obsolete_ids) == 2
    assert length(inactive_before) == 1

    user_ids = [fixture.subscription.user_id, independent.subscription.user_id]

    Enum.each(user_ids, fn user_id ->
      :ok = Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(user_id))
      assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(user_id), :jc248_stale_owner)
    end)

    try do
      assert {:ok, :repaired} =
               Sandbox.unboxed_run(Repo, fn ->
                 Facade.repair_applied_access_effect_for_system(fixture.effect.id)
               end)

      source_after = grants_for_source!(fixture.subscription.id)
      assert [target] = Enum.filter(source_after, &(&1.status == :active))
      assert target.user_id == fixture.subscription.user_id
      assert target.kind == fixture.effect.entitlement_kind
      assert target.scope_key == fixture.effect.entitlement_scope_key
      assert target.valid_from_at == fixture.effect.valid_from_at
      assert target.valid_to_at == fixture.effect.valid_until_at
      assert target.revoked_at == nil
      assert target.revoked_reason == nil

      Enum.each(obsolete_ids, fn id ->
        assert %{status: :revoked, revoked_reason: "subscription_source_reconciliation"} =
                 Enum.find(source_after, &(&1.id == id))
      end)

      Enum.each(inactive_before, fn historical ->
        assert Enum.find(source_after, &(&1.id == historical.id)) == historical
      end)

      assert fetch_effect!(fixture.effect.id) == effect_before
      assert grants_for_source!(independent.subscription.id) == independent_before

      Enum.each(user_ids, fn user_id ->
        assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(user_id))

        assert_receive {:entitlements_invalidated, ^user_id, "subscription_source_reconciliation",
                        _at}
      end)
    after
      Enum.each(user_ids, fn user_id ->
        Phoenix.PubSub.unsubscribe(Store.PubSub, Cache.topic(user_id))
        Cachex.del(Cache, Cache.cache_key(user_id))
      end)
    end
  end

  test "APPLIED empty effective target removes stale rows only for its own source" do
    fixture = create_committed_effective_effect_fixture!("jc248_exact_empty", target: :empty)
    independent = create_committed_effective_effect_fixture!("jc248_empty_independent")

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(fixture.effect.id)

      assert {:ok, :applied} =
               Facade.execute_effective_access_effect_for_system(independent.effect.id)

      for suffix <- ["a", "b"] do
        create_grant!(
          fixture,
          "#{fixture.effect.id}:stale:#{suffix}",
          fixture.subscription.current_period_start_at
        )
      end
    end)

    effect_before = fetch_effect!(fixture.effect.id)
    independent_before = grants_for_source!(independent.subscription.id)

    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect.id)
             end)

    assert grants = grants_for_source!(fixture.subscription.id)
    assert length(grants) == 2
    assert Enum.all?(grants, &(&1.status == :revoked))
    assert grants_for_source!(independent.subscription.id) == independent_before
    assert fetch_effect!(fixture.effect.id) == effect_before

    assert {:ok, :already_converged} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect.id)
             end)

    assert grants_for_source!(fixture.subscription.id) == grants
    assert fetch_effect!(fixture.effect.id) == effect_before
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

  defp source_reconciliation_job_ids(fixture) do
    Store.DirectRepo.query!(
      """
      SELECT id FROM oban_jobs
      WHERE worker = $1 AND args->>'subscription_id' = $2
        AND args->>'expected_access_effect_id' = $3
      ORDER BY inserted_at, id
      """,
      [
        "Store.Workers.ReconcileSubscriptionAccessWorker",
        fixture.subscription.id,
        fixture.effect.id
      ]
    ).rows
  end

  defp mark_source_reconciliation_jobs_terminal!(fixture, state) do
    Store.DirectRepo.query!(
      """
      UPDATE oban_jobs
      SET state = $4, attempt = 5
      WHERE worker = $1 AND args->>'subscription_id' = $2
        AND args->>'expected_access_effect_id' = $3 AND state = 'available'
      """,
      [
        "Store.Workers.ReconcileSubscriptionAccessWorker",
        fixture.subscription.id,
        fixture.effect.id,
        state
      ]
    )
  end

  defp insert_revoked_history!(fixture, count, inserted_at) do
    ids = Enum.map(1..count, fn _ -> Ash.UUIDv7.generate() |> Ecto.UUID.dump!() end)

    scope_keys =
      Enum.map(1..count, fn index ->
        "#{fixture.effect.entitlement_scope_key}:revoked-history:#{index}"
      end)

    Repo.query!(
      """
      INSERT INTO entitlement_grants (
        id, user_id, kind, scope_key, source_kind, source_id, status,
        valid_from_at, valid_to_at, revoked_at, revoked_reason, inserted_at, updated_at
      )
      SELECT historical.id, $2, 'membership_access', historical.scope_key,
             'subscription', $3, 'revoked', $4, $5, $6, 'historical_test', $7, $7
      FROM unnest($1::uuid[], $8::text[]) AS historical(id, scope_key)
      """,
      [
        ids,
        Ecto.UUID.dump!(fixture.subscription.user_id),
        Ecto.UUID.dump!(fixture.subscription.id),
        fixture.effect.valid_from_at,
        fixture.effect.valid_until_at,
        inserted_at,
        inserted_at,
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

  defp jc248_measure_operation!(operation) do
    {pool_before, pool_baseline_wait_us, pool_baseline_polls} = jc248_wait_for_idle_pool()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          :erlang.garbage_collect()
          {:memory, memory_before} = Process.info(self(), :memory)
          {:message_queue_len, mailbox_before} = Process.info(self(), :message_queue_len)
          handlers_before = length(:telemetry.list_handlers([:store, :repo, :query]))
          repo_stats_keys_before = Process.get_keys() |> Enum.filter(&jc248_repo_stats_key?/1)
          {gc_before, words_before, _} = :erlang.statistics(:garbage_collection)
          started = System.monotonic_time(:microsecond)
          {result, stats} = RepoStats.capture(operation)
          wall_us = System.monotonic_time(:microsecond) - started
          {:memory, memory_after} = Process.info(self(), :memory)
          :erlang.garbage_collect()
          {:memory, memory_after_gc} = Process.info(self(), :memory)
          {:message_queue_len, mailbox_after} = Process.info(self(), :message_queue_len)
          handlers_after = length(:telemetry.list_handlers([:store, :repo, :query]))
          {gc_after, words_after, _} = :erlang.statistics(:garbage_collection)

          repo_stats_keys_after = Process.get_keys() |> Enum.filter(&jc248_repo_stats_key?/1)

          assert repo_stats_keys_before == []
          assert repo_stats_keys_after == []
          assert handlers_after == handlers_before
          assert mailbox_before == 0
          assert mailbox_after == 0
          refute Repo.in_transaction?()

          %{
            result: result,
            stats: stats,
            wall_us: wall_us,
            memory_before_gc_bytes: memory_before,
            memory_after_bytes: memory_after,
            memory_after_gc_bytes: memory_after_gc,
            mailbox_before: mailbox_before,
            mailbox_after: mailbox_after,
            handlers_before: handlers_before,
            handlers_after: handlers_after,
            global_gc_count_delta: gc_after - gc_before,
            global_reclaimed_words_delta: words_after - words_before,
            transaction_after: false,
            repo_stats_dictionary_keys_before: length(repo_stats_keys_before),
            repo_stats_dictionary_keys_remaining: length(repo_stats_keys_after)
          }
        end)
      end)

    try do
      sample = Task.await(task, 30_000)
      pool_wait_started = System.monotonic_time(:microsecond)
      {pool_after, pool_return_polls} = jc248_wait_for_pool_metrics(pool_before)
      pool_return_wait_us = System.monotonic_time(:microsecond) - pool_wait_started
      assert pool_after == pool_before

      Map.merge(sample, %{
        pool_before: pool_before,
        pool_after: pool_after,
        pool_baseline_wait_us: pool_baseline_wait_us,
        pool_baseline_polls: pool_baseline_polls,
        pool_return_wait_us: pool_return_wait_us,
        pool_return_polls: pool_return_polls
      })
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp jc248_pool_metrics do
    meta = Ecto.Adapter.lookup_meta(Repo)

    DBConnection.get_connection_metrics(meta.pid, pool: Keyword.fetch!(meta.opts, :pool))
    |> Enum.map(fn metric ->
      %{
        source: jc248_pool_source(metric),
        ready_conn_count: metric.ready_conn_count,
        checkout_queue_length: metric.checkout_queue_length
      }
    end)
    |> Enum.sort_by(&{&1.source, &1.ready_conn_count, &1.checkout_queue_length})
  end

  defp jc248_pool_source(%{source: {:proxy, _pid}}), do: "proxy"
  defp jc248_pool_source(%{source: _source}), do: "pool"

  defp jc248_repo_stats_key?(key) do
    is_tuple(key) and tuple_size(key) > 0 and elem(key, 0) == RepoStats
  end

  defp jc248_entitlement_index_metadata! do
    %{rows: rows, columns: columns} =
      Repo.query!("""
      SELECT index_class.relname AS index_name,
             index_meta.indisvalid,
             index_meta.indisready,
             pg_get_expr(index_meta.indpred, index_meta.indrelid) AS predicate,
             index_class.reltuples::bigint AS index_reltuples,
             index_class.relpages AS index_relpages,
             table_class.reltuples::bigint AS table_reltuples,
             table_class.relpages AS table_relpages
      FROM pg_index AS index_meta
      JOIN pg_class AS index_class ON index_class.oid = index_meta.indexrelid
      JOIN pg_class AS table_class ON table_class.oid = index_meta.indrelid
      WHERE table_class.relname = 'entitlement_grants'
        AND index_class.relname IN (
          'entitlement_grants_source_index',
          'entitlement_grants_active_subscription_source_index'
        )
      ORDER BY index_class.relname
      """)

    Enum.map(rows, fn row ->
      columns |> Enum.zip(row) |> Map.new()
    end)
  end

  defp jc248_wait_for_idle_pool(
         deadline \\ System.monotonic_time(:millisecond) + 3_000,
         polls \\ 0,
         started \\ System.monotonic_time(:microsecond)
       ) do
    metrics = jc248_pool_metrics()
    expected_size = Keyword.fetch!(Repo.config(), :pool_size)

    if Enum.sum_by(metrics, & &1.ready_conn_count) == expected_size and
         Enum.all?(metrics, &(&1.checkout_queue_length == 0)) do
      {metrics, System.monotonic_time(:microsecond) - started, polls}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "Repo pool did not reach an idle #{expected_size}-connection baseline: #{inspect(metrics)}"
        )
      else
        Process.sleep(10)
        jc248_wait_for_idle_pool(deadline, polls + 1, started)
      end
    end
  end

  defp jc248_wait_for_pool_metrics(
         expected,
         deadline \\ System.monotonic_time(:millisecond) + 3_000,
         polls \\ 0
       ) do
    current = jc248_pool_metrics()

    cond do
      current == expected ->
        {current, polls}

      System.monotonic_time(:millisecond) >= deadline ->
        {current, polls}

      true ->
        Process.sleep(10)
        jc248_wait_for_pool_metrics(expected, deadline, polls + 1)
    end
  end

  defp jc248_print_measurement!(sample, repetition, operation) do
    sample
    |> Map.delete(:result)
    |> Map.merge(%{
      tag: "JC248_RESOURCE_MEASUREMENT",
      repetition: repetition,
      operation: operation,
      sources: 16,
      initially_revoked_rows_per_source: 128,
      telemetry_time_unit: "native units",
      limits:
        "two equivalent bounded local repetitions; global GC is process-external; no capacity or stable-memory claim"
    })
    |> Jason.encode!()
    |> IO.puts()
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
