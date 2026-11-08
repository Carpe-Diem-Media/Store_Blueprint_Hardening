defmodule Store.Workers.RunSubscriptionAccessEffectRecoveryWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.DirectRepo
  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade, Subscription}
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.Workers.RunSubscriptionAccessEffectRecoveryWorker

  setup do
    clear_worker_jobs!()
    on_exit(&clear_worker_jobs!/0)
    :ok
  end

  @tag :jc360_task07
  test "the worker recovers committed initial effects once and leaves terminal effects unchanged" do
    required = create_committed_effect_fixture!()
    pending = create_committed_effect_fixture!()
    failed = create_committed_effect_fixture!()
    applied = create_committed_effect_fixture!()
    superseded = create_committed_effect_fixture!()

    superseded =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %{id: pending_id, status: :pending}} =
                 Facade.mark_access_effect_pending_for_system(pending.effect)

        assert pending_id == pending.effect.id

        assert {:ok, :applied} =
                 Facade.execute_effective_access_effect_for_system(applied.effect.id)

        newer_effect = establish_newer_effect!(superseded)

        assert fetch_effect!(superseded.effect.id).status == :superseded
        assert newer_effect.status == :required

        assert {:ok, :applied} =
                 Facade.execute_effective_access_effect_for_system(newer_effect.id)

        Map.put(superseded, :newer_effect, newer_effect)
      end)

    failed_result =
      Sandbox.unboxed_run(Repo, fn ->
        with_effect_application_rejection!(failed.effect.id, fn ->
          Facade.execute_effective_access_effect_for_system(failed.effect.id)
        end)
      end)

    assert {:error, _reason} = failed_result
    assert fetch_effect!(required.effect.id).status == :required
    assert fetch_effect!(pending.effect.id).status == :pending
    assert fetch_effect!(failed.effect.id).status == :failed_retryable
    assert fetch_effect!(applied.effect.id).status == :applied
    assert fetch_effect!(superseded.effect.id).status == :superseded
    assert grants_for_source!(required.subscription.id) == []
    assert grants_for_source!(pending.subscription.id) == []
    assert grants_for_source!(failed.subscription.id) == []

    fixtures = [required, pending, failed, applied, superseded]
    source_ids_before = committed_source_ids!(fixtures)
    grant_ids_before = committed_grant_ids!(fixtures)
    assert Enum.map(grant_ids_before, &length/1) == [0, 0, 0, 1, 1]

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               perform_job(
                 RunSubscriptionAccessEffectRecoveryWorker,
                 %{"as_of" => "2099-01-01T00:00:00Z", "limit" => 100}
               )
             end)

    assert fetch_effect!(required.effect.id).status == :applied
    assert fetch_effect!(pending.effect.id).status == :applied
    assert fetch_effect!(failed.effect.id).status == :applied
    assert fetch_effect!(applied.effect.id).status == :applied
    assert fetch_effect!(superseded.effect.id).status == :superseded
    assert fetch_effect!(superseded.newer_effect.id).status == :applied
    assert committed_source_ids!(fixtures) == source_ids_before

    Enum.each(fixtures, fn fixture ->
      assert length(grants_for_source!(fixture.subscription.id)) == 1
    end)

    grant_ids_after_first_recovery = committed_grant_ids!(fixtures)
    assert length(List.flatten(grant_ids_after_first_recovery)) == 5
    effect_statuses_after_first_recovery = committed_effect_statuses!(fixtures)

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               perform_job(
                 RunSubscriptionAccessEffectRecoveryWorker,
                 %{"as_of" => "2099-01-01T00:00:00Z", "limit" => 100}
               )
             end)

    assert committed_source_ids!(fixtures) == source_ids_before
    assert committed_grant_ids!(fixtures) == grant_ids_after_first_recovery
    assert committed_effect_statuses!(fixtures) == effect_statuses_after_first_recovery
    assert [] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)
  end

  @tag :jc360_task07
  test "a half EFFECTIVE cursor discards the continuation" do
    assert {:discard, _reason} =
             perform_job(
               RunSubscriptionAccessEffectRecoveryWorker,
               %{
                 "effective_execution_after_updated_at" =>
                   DateTime.to_iso8601(DateTime.utc_now()),
                 "limit" => 1
               }
             )
  end

  test "continuation preserves the three independent cursors and sweep identity" do
    _effective = create_effect_fixture!(:effective)
    non_effective = create_effect_fixture!(:non_effective)
    projection = create_effect_fixture!(:effective)

    Repo.query!("UPDATE subscriptions SET status = 'suspended' WHERE id = $1", [
      Ecto.UUID.dump!(non_effective.subscription.id)
    ])

    Repo.query!(
      "UPDATE access_effects SET status = 'applied', projection_user_ids = ARRAY[$2]::uuid[] WHERE id = $1",
      [Ecto.UUID.dump!(projection.effect.id), Ecto.UUID.dump!(projection.subscription.user_id)]
    )

    assert :ok =
             perform_job(
               RunSubscriptionAccessEffectRecoveryWorker,
               %{
                 "as_of" => "2099-01-01T00:00:00Z",
                 "limit" => 1,
                 "sweep_id" => "jc245-three-streams"
               }
             )

    assert [job] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)
    assert job.args["sweep_id"] == "jc245-three-streams"
    assert job.args["as_of"] == "2099-01-01T00:00:00Z"
    assert job.args["skip_execution"] == false
    assert job.args["skip_effective_execution"] == false
    assert job.args["skip_projection"] == false
    assert is_binary(job.args["execution_after_updated_at"])
    assert is_binary(job.args["execution_after_id"])
    assert is_binary(job.args["effective_execution_after_updated_at"])
    assert is_binary(job.args["effective_execution_after_id"])
    assert is_binary(job.args["projection_after_inserted_at"])
    assert is_binary(job.args["projection_after_id"])
  end

  test "a sweep with all three streams exhausted does not enqueue a continuation" do
    assert [] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)

    assert :ok =
             perform_job(
               RunSubscriptionAccessEffectRecoveryWorker,
               %{
                 "as_of" => "2099-01-01T00:00:00Z",
                 "limit" => 1,
                 "skip_execution" => true,
                 "skip_effective_execution" => true,
                 "skip_projection" => true
               }
             )

    assert [] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)
  end

  defp create_effect_fixture!(disposition) do
    customer =
      SubscriptionsFixtures.create_customer!("jc245_worker_#{Ecto.UUID.generate()}")

    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc245-worker-#{Ecto.UUID.generate()}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    attrs = %{
      subscription_id: fixture.subscription.id,
      source_version: fixture.subscription.aggregate_version,
      disposition: disposition,
      entitlement_kind: if(disposition == :effective, do: fixture.revision.entitlement_kind),
      entitlement_scope_key:
        if(disposition == :effective, do: fixture.revision.entitlement_scope_key),
      valid_from_at:
        if(disposition == :effective, do: fixture.subscription.current_period_start_at),
      valid_until_at:
        if(disposition == :effective, do: fixture.subscription.current_period_end_at),
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: fixture.subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)

    fixture
    |> Map.merge(%{
      customer: customer,
      effect: effect,
      plan: plan,
      product: product,
      variant: variant
    })
    |> cleanup_on_exit()
  end

  defp create_committed_effect_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, fixture} = Repo.transaction(fn -> create_effect_fixture!(:effective) end)
      fixture
    end)
  end

  defp establish_newer_effect!(fixture) do
    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
               [Ecto.UUID.dump!(fixture.subscription.id)]
             )

    subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    attrs = %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: :effective,
      entitlement_kind: fixture.revision.entitlement_kind,
      entitlement_scope_key: fixture.revision.entitlement_scope_key,
      valid_from_at: subscription.current_period_start_at,
      valid_until_at: subscription.current_period_end_at,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp with_effect_application_rejection!(effect_id, fun) do
    constraint = "jc360_reject_recovery_#{System.unique_integer([:positive])}"

    try do
      assert {:ok, :added} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL lock_timeout = '5s'")

                 Repo.query!("""
                 ALTER TABLE access_effects
                 ADD CONSTRAINT #{constraint}
                 CHECK (status <> 'applied' OR id <> #{uuid_sql_literal!(effect_id)})
                 NOT VALID
                 """)

                 :added
               end)

      fun.()
    after
      assert {:ok, :dropped} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL lock_timeout = '5s'")
                 Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
                 :dropped
               end)
    end
  end

  defp uuid_sql_literal!(uuid) do
    {:ok, canonical_uuid} = Ecto.UUID.cast(uuid)
    "'#{canonical_uuid}'::uuid"
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

  defp committed_source_ids!(fixtures) do
    Enum.map(fixtures, fn fixture ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)

      %{
        subscriptions:
          persisted_ids!("SELECT id FROM subscriptions WHERE id = $1", [subscription_id]),
        items:
          persisted_ids!(
            "SELECT id FROM subscription_items WHERE subscription_id = $1 ORDER BY id",
            [subscription_id]
          ),
        effects:
          persisted_ids!(
            "SELECT id FROM access_effects WHERE subscription_id = $1 ORDER BY id",
            [subscription_id]
          )
      }
    end)
  end

  defp committed_grant_ids!(fixtures) do
    Enum.map(fixtures, fn fixture ->
      persisted_ids!(
        """
        SELECT id
        FROM entitlement_grants
        WHERE source_kind = 'subscription' AND source_id = $1
        ORDER BY id
        """,
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )
    end)
  end

  defp committed_effect_statuses!(fixtures) do
    Enum.map(fixtures, fn fixture ->
      Repo.query!(
        "SELECT id, status FROM access_effects WHERE subscription_id = $1 ORDER BY id",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      ).rows
      |> Enum.map(fn [id, status] -> {Ecto.UUID.load!(id), status} end)
    end)
  end

  defp persisted_ids!(sql, params) do
    Repo.query!(sql, params).rows
    |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp cleanup_on_exit(fixture) do
    on_exit(fn -> cleanup_committed_recovery_fixture!(fixture) end)

    fixture
  end

  defp cleanup_committed_recovery_fixture!(fixture) do
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

                 assert_committed_fixture_rows_removed!(cleanup_checks)

                 :cleaned
               end)
    end)
  end

  defp clear_worker_jobs! do
    DirectRepo.query!(
      "DELETE FROM oban_jobs WHERE worker = $1",
      [inspect(RunSubscriptionAccessEffectRecoveryWorker)]
    )
  end

  defp assert_committed_fixture_rows_removed!(cleanup_checks) do
    Enum.each(cleanup_checks, fn {table, query, id} ->
      assert %{rows: [[0]]} = Repo.query!(query, [id]),
             "committed fixture cleanup left rows in #{table}"
    end)
  end
end
