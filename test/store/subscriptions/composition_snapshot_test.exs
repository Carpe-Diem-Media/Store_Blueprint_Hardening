defmodule Store.Subscriptions.CompositionSnapshotTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info
  alias Store.Orders.PaymentApplication
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.{AccessEffect, CompositionSnapshot, Facade, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "version 1 fingerprints preserve the accepted deterministic descriptor" do
    id = "018f0000-0000-7000-8000-000000000001"

    fields = %{
      subscription_id: id,
      source_version: 1,
      user_id: id,
      order_id: id,
      source_order_line_item_id: id,
      plan_revision_id: id,
      payment_intent_id: id,
      payment_application_id: id,
      variant_id: id,
      quantity: 1,
      renewal_amount_minor: 1234,
      payment_amount_minor: 1234,
      currency: "ZAR",
      period_start_at: ~U[2026-01-01 00:00:00.123456Z],
      period_end_at: ~U[2026-02-01 00:00:00.123456Z],
      components: []
    }

    assert CompositionSnapshot.fingerprint(fields) ==
             "90d63b184088e1f8cb7339f83120b72ed196a805a0db36128c2d70f499e3f37e"

    component = %{
      "component_key" => id,
      "kind" => "membership_access",
      "scope_key" => "membership:basic",
      "valid_from_at" => "2026-01-01T00:00:00.123456Z",
      "valid_until_at" => "2026-02-01T00:00:00.123456Z"
    }

    single = %{fields | components: [component]}

    assert CompositionSnapshot.fingerprint(single) ==
             "57f0ecd5af708235af43f6425148fa7661c6f38cc440cf284c0b3799ab8e77c8"

    v2_fingerprint =
      CompositionSnapshot.fingerprint(
        v2_fields([v2_component("018f0000-0000-7000-8000-000000000002", "membership:basic")])
      )

    assert is_binary(v2_fingerprint)
    refute v2_fingerprint == CompositionSnapshot.fingerprint(single)
  end

  test "version 2 accepts distinct same-scope components and canonicalizes by binary UUID" do
    low_key = "018f0000-0000-7000-8000-000000000002"
    high_key = "018F0000-0000-7000-8000-000000000003"
    first = v2_component(high_key, "membership:basic")
    second = v2_component(low_key, "membership:basic")
    fields = v2_fields([first, second])
    before = evidence_state()

    assert CompositionSnapshot.valid_v2_components?(fields)

    assert {:ok, [canonical_second, canonical_first]} =
             CompositionSnapshot.canonical_v2_components(fields)

    assert canonical_second["component_key"] == low_key
    assert canonical_first["component_key"] == String.downcase(high_key)

    fingerprint = CompositionSnapshot.fingerprint(fields)
    assert is_binary(fingerprint)

    assert ^fingerprint = CompositionSnapshot.fingerprint(%{fields | components: [second, first]})

    fingerprint_with_next_source =
      CompositionSnapshot.fingerprint(%{fields | source_version: fields.source_version + 1})

    refute fingerprint_with_next_source == fingerprint

    fingerprint_with_another_membership =
      CompositionSnapshot.fingerprint(%{
        fields
        | subscription_id: "018f0000-0000-7000-8000-000000000108"
      })

    refute fingerprint_with_another_membership == fingerprint
    assert evidence_state() == before
  end

  test "version 2 rejects duplicate, malformed and over-bound component payloads" do
    component = v2_component("018f0000-0000-7000-8000-000000000002", "membership:basic")
    fields = v2_fields([component])

    refute CompositionSnapshot.valid_v2_components?(%{
             fields
             | components: [component, component]
           })

    for malformed <- [
          Map.put(component, "component_key", "not-a-uuid"),
          Map.put(component, "component_key", "550e8400-e29b-41d4-a716-446655440000"),
          Map.put(component, "valid_until_at", "2026-01-01T00:00:00Z"),
          Map.put(component, "valid_from_at", "not-a-timestamp"),
          Map.put(component, "scope_key", String.duplicate("x", 256)),
          Map.put(component, "unexpected", "value"),
          Map.delete(component, "kind")
        ] do
      refute CompositionSnapshot.valid_v2_components?(%{fields | components: [malformed]})

      assert {:error, :invalid_v2_payload} =
               CompositionSnapshot.fingerprint(%{fields | components: [malformed]})
    end

    refute CompositionSnapshot.valid_v2_components?(%{
             fields
             | components: List.duplicate(component, 17)
           })

    refute CompositionSnapshot.valid_components?(%{fields | format_version: 3})
    refute CompositionSnapshot.valid_components?(%{fields | format_version: "2"})
    refute CompositionSnapshot.valid_components?(Map.put(fields, :unbound_content, "value"))
    refute CompositionSnapshot.valid_components?(%{fields | source_version: "2"})

    assert {:error, :invalid_v2_payload} =
             CompositionSnapshot.fingerprint(Map.put(fields, :unbound_content, "value"))

    assert {:error, :unsupported_format_version} =
             CompositionSnapshot.fingerprint(%{fields | format_version: 3})

    assert {:error, :unsupported_format_version} =
             CompositionSnapshot.fingerprint(%{fields | format_version: "2"})
  end

  test "version 2 preserves the empty-component encoding supported by version 1" do
    fields = v2_fields([])

    assert CompositionSnapshot.valid_v2_components?(fields)
    assert is_binary(CompositionSnapshot.fingerprint(fields))
  end

  test "version 1 rejects malformed component identities and payloads" do
    id = "018f0000-0000-7000-8000-000000000001"

    component = %{
      "component_key" => id,
      "kind" => "membership_access",
      "scope_key" => "membership:basic",
      "valid_from_at" => "2026-01-01T00:00:00Z",
      "valid_until_at" => "2026-02-01T00:00:00Z"
    }

    fields = %{source_order_line_item_id: id, components: [component]}
    assert CompositionSnapshot.valid_v1_components?(fields)
    assert CompositionSnapshot.valid_v1_components?(%{fields | components: []})

    for malformed <- [
          Map.delete(component, "component_key"),
          Map.put(component, "component_key", 42),
          Map.put(component, "component_key", "018f0000-0000-7000-8000-000000000002"),
          Map.delete(component, "kind"),
          Map.put(component, "kind", "invalid"),
          Map.put(component, "scope_key", " "),
          Map.put(component, "valid_from_at", "invalid"),
          Map.put(component, "valid_until_at", "2025-01-01T00:00:00Z"),
          Map.put(component, "unexpected", "value")
        ] do
      refute CompositionSnapshot.valid_v1_components?(%{fields | components: [malformed]})
    end

    refute CompositionSnapshot.valid_v1_components?(%{
             fields
             | components: [component, component]
           })
  end

  test "initial paid activation records one immutable composition without advancing the source twice" do
    fixture = paid_source!()

    assert {:ok, %{created_count: 1}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    subscription = source!(fixture.line_item.id)
    assert is_binary(Map.get(subscription, :current_composition_snapshot_id))
    snapshot = snapshot!(subscription)
    assert Map.get(snapshot, :format_version) == 1
    refute :format_version in Info.action(CompositionSnapshot, :establish).accept
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

  test "original sale replay preserves an advanced composition and an independent source" do
    fixture = paid_source!()
    independent = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(independent.order.id)
    subscription = source!(fixture.line_item.id)
    original = snapshot!(subscription)
    successor = successor!(original)
    point_to!(subscription, successor.id)
    before = evidence_state()

    assert {:ok, %{created_count: 0, skipped_count: 1, entitlement_issued_count: 0}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert evidence_state() == before
    assert source!(fixture.line_item.id).current_composition_snapshot_id == successor.id
  end

  test "v1 is verified even with a nil current pointer" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    point_to!(source!(fixture.line_item.id), nil)
    before = evidence_state()

    assert {:ok, %{created_count: 0, skipped_count: 1, entitlement_issued_count: 0}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert evidence_state() == before

    Repo.query!("UPDATE order_line_items SET quantity = quantity + 1 WHERE id = $1", [
      Ecto.UUID.dump!(fixture.line_item.id)
    ])

    assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert evidence_state() == before
  end

  for pointer <- [:successor, nil] do
    test "missing v1 fails closed with other snapshots and pointer #{inspect(pointer)}" do
      fixture = paid_source!()
      assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      subscription = source!(fixture.line_item.id)
      original = snapshot!(subscription)
      successor = successor!(original)
      point_to!(subscription, if(unquote(pointer) == :successor, do: successor.id))
      remove_snapshot_for_test!(original)
      before = evidence_state()

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

      assert evidence_state() == before
    end
  end

  test "evidence-free nil-pointer compatibility skips without synthesizing consequences" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    subscription = source!(fixture.line_item.id)
    original = snapshot!(subscription)
    point_to!(subscription, nil)
    remove_snapshot_for_test!(original)
    independent = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(independent.order.id)
    # Compatibility is deliberate even without provable historical provenance or payment evidence.
    Repo.query!("DELETE FROM payment_applications WHERE id = $1", [
      Ecto.UUID.dump!(fixture.payment_application.id)
    ])

    before = evidence_state()

    assert {:ok, %{created_count: 0, skipped_count: 1, entitlement_issued_count: 0}} =
             Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

    assert evidence_state() == before
  end

  for conflict <- [:purchase, :payment] do
    test "original #{conflict} evidence conflict fails after the pointer advances" do
      fixture = paid_source!()
      assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      subscription = source!(fixture.line_item.id)
      successor = successor!(snapshot!(subscription))
      point_to!(subscription, successor.id)

      case unquote(conflict) do
        :purchase ->
          Repo.query!("UPDATE order_line_items SET quantity = quantity + 1 WHERE id = $1", [
            Ecto.UUID.dump!(fixture.line_item.id)
          ])

        :payment ->
          Repo.query!(
            "UPDATE payment_applications SET application_key = 'conflicting' WHERE id = $1",
            [
              Ecto.UUID.dump!(fixture.payment_application.id)
            ]
          )
      end

      before = evidence_state()

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

      assert evidence_state() == before
    end
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

  test "invalid components cannot be created through the Ash action" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    snapshot = snapshot!(source!(fixture.line_item.id))
    [component] = snapshot.components

    attrs =
      snapshot
      |> Map.from_struct()
      |> Map.take(Info.action(CompositionSnapshot, :establish).accept)

    malformed = [
      [Map.delete(component, "component_key")],
      [Map.put(component, "component_key", "invalid")],
      [Map.put(component, "component_key", Ash.UUIDv7.generate())],
      [Map.delete(component, "kind")],
      [Map.put(component, "kind", "invalid")],
      [Map.put(component, "scope_key", " ")],
      [Map.put(component, "valid_from_at", "invalid")],
      [Map.put(component, "valid_until_at", "invalid")],
      [Map.put(component, "valid_until_at", "2000-01-01T00:00:00Z")],
      [component, component]
    ]

    for components <- malformed do
      candidate =
        Map.merge(attrs, %{id: Ash.UUIDv7.generate(), source_version: 2, components: components})

      assert {:error, _} =
               CompositionSnapshot
               |> Ash.Changeset.for_create(:establish, candidate, context: %{system?: true})
               |> Ash.create(authorize?: false, context: %{system?: true})

      assert Repo.aggregate(CompositionSnapshot, :count) == 1
    end
  end

  test "database rejects unsupported and null format versions" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    snapshot = snapshot!(source!(fixture.line_item.id))

    for version <- [0, 3, nil] do
      assert {:error, %Postgrex.Error{}} =
               Repo.query(
                 """
                 INSERT INTO composition_snapshots
                   (id, subscription_id, source_version, user_id, order_id, source_order_line_item_id,
                    plan_revision_id, payment_intent_id, payment_application_id, variant_id, quantity,
                    renewal_amount_minor, payment_amount_minor, currency, period_start_at, period_end_at,
                    components, fingerprint, format_version)
                 SELECT $1, subscription_id, source_version + 1, user_id, order_id, source_order_line_item_id,
                    plan_revision_id, payment_intent_id, payment_application_id, variant_id, quantity,
                    renewal_amount_minor, payment_amount_minor, currency, period_start_at, period_end_at,
                    components, fingerprint, $2 FROM composition_snapshots WHERE id = $3
                 """,
                 [Ecto.UUID.dump!(Ash.UUIDv7.generate()), version, Ecto.UUID.dump!(snapshot.id)],
                 mode: :savepoint
               )
    end

    assert Repo.aggregate(CompositionSnapshot, :count) == 1
  end

  test "database cardinality limits match each supported format" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    snapshot = snapshot!(source!(fixture.line_item.id))

    for {version, count} <- [{1, 2}, {2, 17}] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 """
                 INSERT INTO composition_snapshots
                   (id, subscription_id, source_version, user_id, order_id, source_order_line_item_id,
                    plan_revision_id, payment_intent_id, payment_application_id, variant_id, quantity,
                    renewal_amount_minor, payment_amount_minor, currency, period_start_at, period_end_at,
                    components, fingerprint, format_version)
                 SELECT $1, subscription_id, source_version + 1, user_id, order_id,
                    source_order_line_item_id, plan_revision_id, payment_intent_id,
                    payment_application_id, variant_id, quantity, renewal_amount_minor,
                    payment_amount_minor, currency, period_start_at, period_end_at,
                    array_fill(components[1], ARRAY[$2::integer]), fingerprint, $3
                 FROM composition_snapshots WHERE id = $4
                 """,
                 [
                   Ecto.UUID.dump!(Ash.UUIDv7.generate()),
                   count,
                   version,
                   Ecto.UUID.dump!(snapshot.id)
                 ],
                 mode: :savepoint
               )
    end

    assert Repo.aggregate(CompositionSnapshot, :count) == 1
  end

  test "replay rejects self-consistent malformed persisted components" do
    fixture = paid_source!()
    assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
    snapshot = snapshot!(source!(fixture.line_item.id))
    [component] = snapshot.components

    for malformed <- [
          Map.put(component, "component_key", Ash.UUIDv7.generate()),
          Map.put(component, "valid_from_at", "invalid")
        ] do
      components = [malformed]

      fingerprint =
        CompositionSnapshot.fingerprint(%{Map.from_struct(snapshot) | components: components})

      Repo.query!(
        "ALTER TABLE composition_snapshots DISABLE TRIGGER composition_snapshots_immutable"
      )

      try do
        Repo.query!(
          "UPDATE composition_snapshots SET components = $1, fingerprint = $2 WHERE id = $3",
          [components, fingerprint, Ecto.UUID.dump!(snapshot.id)]
        )
      after
        Repo.query!(
          "ALTER TABLE composition_snapshots ENABLE TRIGGER composition_snapshots_immutable"
        )
      end

      before = evidence_state()

      assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
               Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)

      assert evidence_state() == before
    end
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

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE composition_snapshots SET format_version = 2 WHERE id = $1",
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

        if phase == :replay do
          [lookup] = Enum.filter(queries, &String.contains?(&1, "\"composition_snapshots\""))
          assert lookup =~ ~s("subscription_id"::uuid =)
          assert lookup =~ ~s("source_version" =)
        end

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

  test "compatibility lookup is bounded and limited to its own source" do
    for repetition <- 1..2 do
      fixture = paid_source!()
      assert {:ok, _} = Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      subscription = source!(fixture.line_item.id)
      original = snapshot!(subscription)
      point_to!(subscription, nil)
      remove_snapshot_for_test!(original)
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
        assert {:ok, %{created_count: 0, skipped_count: 1}} =
                 Facade.create_subscriptions_from_paid_order_for_system(fixture.order.id)
      after
        :telemetry.detach(handler)
      end

      queries = collect_queries([])
      lookups = Enum.filter(queries, &String.contains?(&1, "\"composition_snapshots\""))
      assert length(lookups) == 2
      assert Enum.all?(lookups, &String.contains?(&1, ~s("subscription_id"::uuid =)))
      assert Enum.any?(lookups, &String.contains?(&1, "LIMIT"))
      refute Enum.any?(queries, &String.contains?(&1, "\"payment_applications\""))

      IO.puts(
        "JC274 compatibility repetition=#{repetition} total=#{length(queries)} composition=2 payment_application=0"
      )
    end
  end

  defp v2_component(key, scope) do
    %{
      "component_key" => key,
      "kind" => "membership_access",
      "scope_key" => scope,
      "valid_from_at" => "2026-01-01T00:00:00Z",
      "valid_until_at" => "2026-02-01T00:00:00Z"
    }
  end

  defp v2_fields(components) do
    %{
      format_version: 2,
      subscription_id: "018f0000-0000-7000-8000-000000000100",
      source_version: 2,
      components: components
    }
  end

  # This successor is lookup-only test data, not an implemented composition transition.
  defp successor!(original) do
    attrs =
      original
      |> Map.from_struct()
      |> Map.take(Info.action(CompositionSnapshot, :establish).accept)

    attrs =
      Map.merge(attrs, %{
        id: Ash.UUIDv7.generate(),
        source_version: 2,
        quantity: original.quantity + 1,
        renewal_amount_minor: original.renewal_amount_minor + 100
      })

    {:ok, successor} =
      Repo.transaction(fn ->
        CompositionSnapshot
        |> Ash.Changeset.for_create(:establish, attrs, context: %{system?: true})
        |> Ash.create!(authorize?: false, context: %{system?: true})
      end)

    successor
  end

  defp point_to!(subscription, snapshot_id) do
    Repo.query!("UPDATE subscriptions SET current_composition_snapshot_id = $1 WHERE id = $2", [
      snapshot_id && Ecto.UUID.dump!(snapshot_id),
      Ecto.UUID.dump!(subscription.id)
    ])

    Repo.query!("SET CONSTRAINTS subscriptions_current_composition_snapshot_id_fkey IMMEDIATE")
    Repo.query!("SET CONSTRAINTS subscriptions_current_composition_snapshot_id_fkey DEFERRED")
  end

  defp remove_snapshot_for_test!(snapshot) do
    # Only the sandbox transaction bypasses immutability to simulate absent/corrupted evidence.
    Repo.query!("SET CONSTRAINTS subscriptions_current_composition_snapshot_id_fkey IMMEDIATE")

    Repo.query!(
      "ALTER TABLE composition_snapshots DISABLE TRIGGER composition_snapshots_immutable"
    )

    try do
      Repo.query!("DELETE FROM composition_snapshots WHERE id = $1", [
        Ecto.UUID.dump!(snapshot.id)
      ])
    after
      Repo.query!(
        "ALTER TABLE composition_snapshots ENABLE TRIGGER composition_snapshots_immutable"
      )

      Repo.query!("SET CONSTRAINTS subscriptions_current_composition_snapshot_id_fkey DEFERRED")
    end
  end

  defp evidence_state do
    for table <-
          ~w(subscriptions composition_snapshots access_effects entitlement_grants payment_applications payment_intents) do
      {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows}
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
