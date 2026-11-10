defmodule Store.Subscriptions.CompositionSnapshotTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.PaymentApplication
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.{AccessEffect, CompositionSnapshot, Facade, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "initial paid activation records one immutable composition without advancing the source twice" do
    fixture = paid_source!()

    assert {:ok, %{created_count: 1}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    subscription = source!(fixture.line_item.id)
    assert is_binary(Map.get(subscription, :current_composition_snapshot_id))
    snapshot = snapshot!(subscription)
    assert snapshot.source_version == subscription.aggregate_version
    assert snapshot.source_order_line_item_id == fixture.line_item.id
    assert snapshot.payment_application_id == fixture.payment_application.id
    assert snapshot.payment_intent_id == fixture.payment_intent.id
    assert snapshot.period_start_at == subscription.current_period_start_at
    assert snapshot.period_end_at == subscription.current_period_end_at
    assert [%{"component_key" => key, "kind" => "membership_access"}] = snapshot.components
    assert key == fixture.line_item.id
    assert snapshot.fingerprint == CompositionSnapshot.fingerprint(Map.from_struct(snapshot))
    assert subscription.aggregate_version == 1

    [effect] = Ash.read!(AccessEffect, authorize?: false, context: %{system?: true})
    assert effect.source_version == subscription.aggregate_version
    assert effect.status == :applied
  end

  test "replay retains the exact immutable snapshot after a status-only aggregate advance" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    subscription = source!(fixture.line_item.id)
    before = snapshot!(subscription)

    assert {:ok, _} =
             Facade.cancel_subscription_for_user(
               %{id: subscription.user_id},
               subscription.id,
               :period_end
             )

    assert source!(fixture.line_item.id).aggregate_version > before.source_version

    assert {:ok, %{created_count: 0, skipped_count: 1}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert snapshot!(source!(fixture.line_item.id)) == before
    assert Repo.aggregate(CompositionSnapshot, :count) == 1
  end

  test "a zero-entitlement offer records an empty component set without changing the scalar effect" do
    fixture = paid_source!(%{entitlement_kind: nil, entitlement_scope_key: nil})

    assert {:ok, %{entitlement_issued_count: 0}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    subscription = source!(fixture.line_item.id)
    assert snapshot!(subscription).components == []
    [effect] = Ash.read!(AccessEffect, authorize?: false, context: %{system?: true})
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
  end

  test "missing committed payment application rolls back all subscription-side establishment" do
    fixture = paid_source!()

    Repo.query!("DELETE FROM payment_applications WHERE id = $1", [
      Ecto.UUID.dump!(fixture.payment_application.id)
    ])

    assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert source!(fixture.line_item.id) == nil
    assert Repo.aggregate(CompositionSnapshot, :count) == 0
    assert Repo.aggregate(AccessEffect, :count) == 0

    assert Ash.get!(PaymentIntent, fixture.payment_intent.id,
             authorize?: false,
             context: %{system?: true}
           ).state == :succeeded
  end

  test "conflicting purchased evidence fails replay without replacing the snapshot" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    subscription = source!(fixture.line_item.id)
    original = snapshot!(subscription)

    Repo.query!("UPDATE order_line_items SET quantity = quantity + 1 WHERE id = $1", [
      Ecto.UUID.dump!(fixture.line_item.id)
    ])

    assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert snapshot!(source!(fixture.line_item.id)) == original
  end

  test "database protection rejects evidence updates while preserving the current snapshot" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    snapshot = snapshot!(source!(fixture.line_item.id))

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE composition_snapshots SET quantity = quantity + 1 WHERE id = $1",
               [Ecto.UUID.dump!(snapshot.id)],
               mode: :savepoint
             )

    assert snapshot!(source!(fixture.line_item.id)) == snapshot
  end

  test "database protection retains evidence after the pointer is cleared" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    subscription = source!(fixture.line_item.id)
    snapshot = snapshot!(subscription)

    Repo.query!("UPDATE subscriptions SET current_composition_snapshot_id = NULL WHERE id = $1", [
      Ecto.UUID.dump!(subscription.id)
    ])

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "DELETE FROM composition_snapshots WHERE id = $1",
               [Ecto.UUID.dump!(snapshot.id)],
               mode: :savepoint
             )
  end

  test "the deferred linkage cannot reference another Subscription's composition" do
    first = paid_source!()
    second = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(first.order.id)
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(second.order.id)
    a = source!(first.line_item.id)
    b = source!(second.line_item.id)
    Repo.query!("SET CONSTRAINTS subscriptions_current_composition_snapshot_id_fkey IMMEDIATE")

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE subscriptions SET current_composition_snapshot_id = $1 WHERE id = $2",
               [Ecto.UUID.dump!(b.current_composition_snapshot_id), Ecto.UUID.dump!(a.id)],
               mode: :savepoint
             )
  end

  test "the initial producer and replay add bounded exact-key evidence queries" do
    for repetition <- 1..2 do
      fixture = paid_source!()

      for phase <- [:initial, :replay] do
        owner = self()
        handler = {__MODULE__, make_ref()}

        :ok =
          :telemetry.attach(
            handler,
            [:store, :repo, :query],
            fn _, _, metadata, _ ->
              if self() == owner, do: send(owner, {:composition_query, metadata.query})
            end,
            nil
          )

        try do
          assert {:ok, _} =
                   Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
        after
          :telemetry.detach(handler)
        end

        queries = collect_queries([])
        assert Enum.count(queries, &String.contains?(&1, "\"composition_snapshots\"")) == 1
        assert Enum.count(queries, &String.contains?(&1, "\"payment_applications\"")) == 1

        assert Enum.count(
                 queries,
                 &(String.contains?(&1, "\"orders\"") and String.contains?(&1, "FOR UPDATE"))
               ) == 1

        IO.puts(
          "JC274 query sample repetition=#{repetition} phase=#{phase} total=#{length(queries)} composition=1 payment_application=1 order_lock=1"
        )
      end
    end
  end

  defp collect_queries(acc) do
    receive do
      {:composition_query, query} -> collect_queries([query | acc])
    after
      0 -> acc
    end
  end

  defp snapshot!(subscription) do
    Ash.get!(CompositionSnapshot, subscription.current_composition_snapshot_id,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp paid_source!(overrides \\ %{}) do
    customer = SubscriptionsFixtures.create_customer!("composition_snapshot")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(
        Map.merge(
          %{
            entitlement_kind: :membership_access,
            entitlement_scope_key: "composition:#{Ash.UUIDv7.generate()}"
          },
          overrides
        )
      )

    fixture =
      SubscriptionsFixtures.create_paid_order_with_subscription_line!(customer.id, variant, plan)

    [intent] =
      PaymentIntent
      |> Ash.Query.filter(expr(order_id == ^fixture.order.id))
      |> Ash.read!(authorize?: false, context: %{system?: true})

    application =
      PaymentApplication
      |> Ash.Changeset.for_create(
        :apply_once,
        %{
          order_id: fixture.order.id,
          payment_intent_id: intent.id,
          application_key: "paid_apply:order:#{fixture.order.id}"
        },
        context: %{system?: true}
      )
      |> Ash.create!(authorize?: false, context: %{system?: true})

    Map.merge(fixture, %{payment_intent: intent, payment_application: application})
  end

  defp source!(line_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_line_item_id == ^line_id))
    |> Ash.read_one!(authorize?: false, context: %{system?: true})
  end
end
