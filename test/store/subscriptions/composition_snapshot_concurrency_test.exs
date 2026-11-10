defmodule Store.Subscriptions.CompositionSnapshotConcurrencyTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "independent duplicate activations commit one snapshot and one unchanged scalar source" do
    for repetition <- 1..2 do
      fixture = Sandbox.unboxed_run(Repo, &paid_source!/0)
      on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup!(fixture) end) end)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.checkout(fn ->
                %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                send(parent, {:ready, self(), backend_pid})

                receive do
                  :activate ->
                    Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
                after
                  10_000 -> raise "activation barrier timed out"
                end
              end)
            end)
          end)
        end

      pids =
        for _ <- 1..2 do
          assert_receive {:ready, task_pid, backend_pid}, 10_000
          {task_pid, backend_pid}
        end

      assert length(Enum.uniq(Enum.map(pids, &elem(&1, 1)))) == 2
      Enum.each(pids, fn {pid, _backend_pid} -> send(pid, :activate) end)
      results = Enum.map(tasks, &Task.await(&1, 30_000))

      outcomes =
        Enum.map(results, fn result ->
          assert {:ok, outcome} = result
          {outcome.created_count, outcome.skipped_count}
        end)

      assert Enum.sort(outcomes) == [{0, 1}, {1, 0}]

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %{created_count: 0, skipped_count: 1}} =
                 Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

        %{rows: [[count, version, effect_version, snapshot_version]]} =
          Repo.query!(
            """
            SELECT count(*), min(s.aggregate_version), min(e.source_version), min(c.source_version)
            FROM subscriptions s
            JOIN composition_snapshots c ON c.id = s.current_composition_snapshot_id AND c.subscription_id = s.id
            JOIN access_effects e ON e.subscription_id = s.id
            WHERE s.source_order_id = $1
            """,
            [Ecto.UUID.dump!(fixture.order.id)]
          )

        assert {count, version, effect_version, snapshot_version} == {1, 1, 1, 1}

        IO.puts(
          "JC274 independent activation repetition=#{repetition} one source/effect/snapshot at version=1"
        )
      end)
    end
  end

  defp paid_source! do
    customer = SubscriptionsFixtures.create_customer!("jc274_connections")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc274:#{Ash.UUIDv7.generate()}"
      })

    fixture =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    Map.merge(fixture, %{customer: customer, product: product, plan: plan})
  end

  defp cleanup!(fixture) do
    order_id = Ecto.UUID.dump!(fixture.order.id)
    plan_id = Ecto.UUID.dump!(fixture.plan.id)

    assert {:ok, :cleaned} =
             Repo.transaction(fn ->
               Repo.query!(
                 "DELETE FROM entitlement_grants WHERE source_id IN (SELECT id FROM subscriptions WHERE source_order_id = $1)",
                 [order_id]
               )

               Repo.query!(
                 "DELETE FROM access_effects WHERE subscription_id IN (SELECT id FROM subscriptions WHERE source_order_id = $1)",
                 [order_id]
               )

               Repo.query!(
                 "DELETE FROM subscription_items WHERE subscription_id IN (SELECT id FROM subscriptions WHERE source_order_id = $1)",
                 [order_id]
               )

               Repo.query!("DELETE FROM subscriptions WHERE source_order_id = $1", [order_id])
               Repo.query!("DELETE FROM payment_applications WHERE order_id = $1", [order_id])
               Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
               Repo.query!("DELETE FROM order_line_items WHERE order_id = $1", [order_id])
               Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

               Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])

               Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
               Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")

               Repo.query!("DELETE FROM products WHERE id = $1", [
                 Ecto.UUID.dump!(fixture.product.id)
               ])

               Repo.query!("DELETE FROM users WHERE id = $1", [
                 Ecto.UUID.dump!(fixture.customer.id)
               ])

               :cleaned
             end)
  end
end
