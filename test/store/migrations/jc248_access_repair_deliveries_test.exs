defmodule Store.Jc248AccessRepairDeliveriesTestRepo do
  use Ecto.Repo,
    otp_app: :store,
    adapter: Ecto.Adapters.Postgres
end

defmodule Store.Migrations.Jc248AccessRepairDeliveriesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Store.Subscriptions.{AccessRepairDelivery, Facade}
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.IsolatedMigrationDatabase

  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20261108015229_jc248_access_repair_deliveries.exs",
      __DIR__
    )
  )

  @version 20_261_108_015_229
  @migration Store.Repo.Migrations.Jc248AccessRepairDeliveries

  setup_all do
    context =
      IsolatedMigrationDatabase.start!(
        "jc248_delivery_rollback",
        Store.Jc248AccessRepairDeliveriesTestRepo,
        pool_size: 4
      )

    on_exit(fn -> IsolatedMigrationDatabase.stop!(context) end)
    {:ok, context}
  end

  test "rollback preserves every pending delivery obligation", %{repo: repo, repo_pid: pid} do
    delivery = create_delivery_fixture!(pid)
    before = delivery_rows(repo)

    try do
      assert_raise Postgrex.Error, ~r/pending access repair deliveries/, fn ->
        Migrator.down(repo, @version, @migration, log: false)
      end

      assert @version in Migrator.migrated_versions(repo)
      assert delivery_rows(repo) == before

      # This fixture tests the rollback predicate, not actual notification delivery.
      SQL.query!(
        repo,
        """
        UPDATE access_repair_deliveries
           SET delivered_generation = generation, delivered_at = now()
         WHERE id = $1
        """,
        [Ecto.UUID.dump!(delivery.id)]
      )

      assert :ok = Migrator.down(repo, @version, @migration, log: false)

      assert %{rows: [[nil]]} =
               SQL.query!(repo, "SELECT to_regclass('public.access_repair_deliveries')", [])
    after
      Migrator.up(repo, @version, @migration, log: false)
    end
  end

  test "rollback observes a pending generation committed by a concurrent writer", %{
    repo: repo,
    repo_pid: pid
  } do
    delivery = create_delivery_fixture!(pid)
    id = Ecto.UUID.dump!(delivery.id)

    SQL.query!(
      repo,
      """
      UPDATE access_repair_deliveries
         SET delivered_generation = generation, delivered_at = now()
       WHERE id = $1
      """,
      [id]
    )

    parent = self()
    barrier = make_ref()

    writer =
      Task.async(fn ->
        repo.transaction(fn ->
          SQL.query!(repo, "UPDATE access_repair_deliveries SET generation = 2 WHERE id = $1", [
            id
          ])

          %{rows: [[backend_pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
          send(parent, {barrier, :writer_ready, backend_pid})

          receive do
            {^barrier, :commit} -> :ok
          after
            5_000 -> raise "rollback test did not release its writer"
          end
        end)
      end)

    try do
      assert_receive {^barrier, :writer_ready, writer_backend}, 5_000

      rollback =
        Task.async(fn ->
          try do
            Migrator.down(repo, @version, @migration, log: false)
          rescue
            error in Postgrex.Error -> {:refused, error}
          end
        end)

      try do
        assert await_blocked_rollback(
                 repo,
                 writer_backend,
                 System.monotonic_time(:millisecond) + 5_000
               )

        send(writer.pid, {barrier, :commit})
        assert {:ok, :ok} = Task.await(writer, 5_000)
        assert {:refused, error} = Task.await(rollback, 5_000)
        assert Exception.message(error) =~ "pending access repair deliveries"

        assert %{rows: [[2, 1]]} =
                 SQL.query!(
                   repo,
                   "SELECT generation, delivered_generation FROM access_repair_deliveries WHERE id = $1",
                   [id]
                 )

        assert @version in Migrator.migrated_versions(repo)
      after
        Task.shutdown(rollback, :brutal_kill)
      end
    after
      send(writer.pid, {barrier, :commit})
      Task.shutdown(writer, :brutal_kill)

      SQL.query!(
        repo,
        "UPDATE access_repair_deliveries SET delivered_generation = generation, delivered_at = now()",
        []
      )
    end
  end

  defp await_blocked_rollback(repo, writer_backend, deadline) do
    %{rows: [[blocked?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_stat_activity
          WHERE datname = current_database()
            AND $1::integer = ANY(pg_blocking_pids(pid))
            AND query LIKE 'LOCK TABLE access_repair_deliveries%'
            AND wait_event_type = 'Lock'
        )
        """,
        [writer_backend]
      )

    cond do
      blocked? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          10 -> await_blocked_rollback(repo, writer_backend, deadline)
        end
    end
  end

  defp create_delivery_fixture!(repo_pid) do
    previous_repo = Store.Repo.put_dynamic_repo(repo_pid)

    try do
      # Keep all foreign keys and use the established source/effect constructors.
      # This migration fixture does not certify commercial payment evidence.
      customer = SubscriptionsFixtures.create_customer!("jc248_delivery_rollback")

      %{variant: variant} =
        SubscriptionsFixtures.create_subscription_sellable!(%{published?: false})

      plan =
        SubscriptionsFixtures.create_subscription_plan!(%{
          entitlement_kind: :membership_access,
          entitlement_scope_key: "jc248_rollback:#{Ecto.UUID.generate()}"
        })

      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
      fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
      subscription = fixture.subscription

      {:ok, input} =
        EstablishAccessEffectInput.new(%{
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
        })

      {:ok, effect} = Facade.establish_access_effect_for_system(input)
      {:ok, :applied} = Facade.execute_effective_access_effect_for_system(effect.id)

      AccessRepairDelivery
      |> Ash.Changeset.for_create(
        :create_for_system,
        %{
          access_effect_id: effect.id,
          recipient_user_ids: [customer.id],
          generation: 1,
          delivered_generation: 0
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: true, context: %{system?: true})
    after
      Store.Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp delivery_rows(repo) do
    SQL.query!(repo, "SELECT * FROM access_repair_deliveries ORDER BY id", []).rows
  end
end
