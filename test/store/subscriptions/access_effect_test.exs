defmodule Store.Subscriptions.AccessEffectTest do
  use Store.DataCase, async: false

  import Ash.Expr

  require Ash.Query

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub

  test "AccessEffect carries nullable projection repair evidence" do
    user_ids = Info.attribute(AccessEffect, :projection_user_ids)
    delivered_at = Info.attribute(AccessEffect, :projection_delivered_at)

    assert user_ids.type == {:array, Ash.Type.UUID}
    assert user_ids.allow_nil?
    refute user_ids.public?
    assert delivered_at.type == Ash.Type.UtcDatetimeUsec
    assert delivered_at.allow_nil?
    refute delivered_at.public?
  end

  test "AccessEffect stores private nullable valid_from_at evidence" do
    attribute = Info.attribute(AccessEffect, :valid_from_at)

    assert attribute
    assert attribute.type == Ash.Type.UtcDatetimeUsec
    assert attribute.allow_nil?
    refute attribute.public?

    fixture = create_subscription_fixture!()
    start_at = ~U[2026-09-01 00:00:00.123456Z]

    input =
      access_effect_input(fixture, %{
        valid_from_at: start_at,
        valid_until_at: DateTime.add(start_at, 1, :day)
      })

    assert Map.get(input, :valid_from_at) == start_at
    assert {:ok, effect} = establish(input)
    assert effect.valid_from_at == start_at
  end

  test "typed AccessEffect input leaves a missing start available for historical replay" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture, %{valid_from_at: nil})

    assert input.disposition == :effective
    assert input.entitlement_kind
    assert input.entitlement_scope_key
    assert Map.get(input, :valid_from_at) == nil
  end

  test "bounded recovery selector finds unresolved non-effective effects" do
    fixture = create_subscription_fixture!()

    effect =
      establish!(
        access_effect_input(fixture, %{
          disposition: :non_effective,
          entitlement_kind: nil,
          entitlement_scope_key: nil
        })
      )

    assert {:ok, effects} =
             AccessEffect
             |> Ash.Query.for_read(:read_recoverable_non_effective_for_system, %{
               limit: 100,
               through_updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert effect.id in Enum.map(effects, & &1.id)
  end

  test "NON_EFFECTIVE recovery selector remains backed by its existing partial index" do
    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_bitmapscan = off")

    through_updated_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    after_updated_at = DateTime.add(through_updated_at, -1, :second)
    after_id = Ecto.UUID.dump!("00000000-0000-0000-0000-000000000000")

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        EXPLAIN
        SELECT id
        FROM access_effects
        WHERE disposition = 'non_effective'
          AND status IN ('required', 'pending', 'failed_retryable')
          AND updated_at <= $1
          AND (updated_at > $2 OR (updated_at = $2 AND id > $3))
        ORDER BY updated_at ASC, id ASC
        LIMIT 100
        """,
        [through_updated_at, after_updated_at, after_id]
      )

    explain = rows |> List.flatten() |> Enum.join(" ")
    assert explain =~ "access_effects_non_effective_recovery_index"
    assert explain =~ "Limit"
  end

  test "bounded AccessEffect recovery advances by its indexed timestamp and id keyset" do
    cursor_floor = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixtures = Enum.map(1..3, fn _ -> create_subscription_fixture!() end)

    effects =
      Enum.map(fixtures, fn fixture ->
        establish!(
          access_effect_input(fixture, %{
            disposition: :non_effective,
            entitlement_kind: nil,
            entitlement_scope_key: nil
          })
        )
      end)

    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, first_page} =
             AccessEffect
             |> Ash.Query.for_read(:read_recoverable_non_effective_for_system, %{
               limit: 2,
               through_updated_at: as_of,
               after_updated_at: cursor_floor,
               after_id: "00000000-0000-0000-0000-000000000000"
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(first_page) == 2
    last = List.last(first_page)

    assert {:ok, second_page} =
             AccessEffect
             |> Ash.Query.for_read(:read_recoverable_non_effective_for_system, %{
               limit: 2,
               through_updated_at: as_of,
               after_updated_at: last.updated_at,
               after_id: last.id
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(second_page) == 1
    assert hd(second_page).id not in Enum.map(first_page, & &1.id)

    assert Enum.all?(
             effects,
             &(&1.id in Enum.map(first_page ++ second_page, fn effect -> effect.id end))
           )
  end

  test "bounded projection selector finds only tracked applied effects awaiting delivery" do
    fixture = create_subscription_fixture!()

    effect =
      establish!(
        access_effect_input(fixture, %{
          disposition: :non_effective,
          entitlement_kind: nil,
          entitlement_scope_key: nil
        })
      )

    assert {:ok, pending} = Facade.mark_access_effect_pending_for_system(effect)
    assert {:ok, _applied} = Facade.mark_access_effect_applied_for_system(pending)

    user_id = fixture.subscription.user_id

    Repo.query!(
      "UPDATE access_effects SET projection_user_ids = ARRAY[$2::uuid] WHERE id = $1",
      [Ecto.UUID.dump!(effect.id), Ecto.UUID.dump!(user_id)]
    )

    assert {:ok, effects} =
             AccessEffect
             |> Ash.Query.for_read(:read_pending_projection_repair_for_system, %{
               limit: 100,
               through_inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert effect.id in Enum.map(effects, & &1.id)
  end

  test "projection repair advances by stable inserted timestamp and id keyset" do
    fixtures = Enum.map(1..3, fn _ -> create_subscription_fixture!() end)

    effects =
      Enum.map(fixtures, fn fixture ->
        effect =
          establish!(
            access_effect_input(fixture, %{
              disposition: :non_effective,
              entitlement_kind: nil,
              entitlement_scope_key: nil
            })
          )

        {:ok, pending} = Facade.mark_access_effect_pending_for_system(effect)
        {:ok, applied} = Facade.mark_access_effect_applied_for_system(pending)
        user_id = fixture.subscription.user_id

        Repo.query!(
          "UPDATE access_effects SET projection_user_ids = ARRAY[$2::uuid] WHERE id = $1",
          [Ecto.UUID.dump!(effect.id), Ecto.UUID.dump!(user_id)]
        )

        applied
      end)

    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, first_page} =
             AccessEffect
             |> Ash.Query.for_read(:read_pending_projection_repair_for_system, %{
               limit: 2,
               through_inserted_at: as_of
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(first_page) == 2
    last = List.last(first_page)

    assert {:ok, second_page} =
             AccessEffect
             |> Ash.Query.for_read(:read_pending_projection_repair_for_system, %{
               limit: 2,
               through_inserted_at: as_of,
               after_inserted_at: last.inserted_at,
               after_id: last.id
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(second_page) == 1

    assert Enum.all?(
             effects,
             &(&1.id in Enum.map(first_page ++ second_page, fn effect -> effect.id end))
           )
  end

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "exact replay reuses one durable AccessEffect identity" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)

    assert {:ok, first} = establish(input)
    assert {:ok, replay} = establish(input)

    assert replay.id == first.id
    assert replay.status == :required
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "new effective entitlement targets require a start and create no row when it is absent" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture, %{valid_from_at: nil})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = establish(input)
    assert count_access_effects(fixture.subscription.id) == 0
  end

  test "new effective target intervals require a strict start before end" do
    fixture = create_subscription_fixture!()
    end_at = access_effect_input(fixture).valid_until_at

    for start_at <- [end_at, DateTime.add(end_at, 1, :microsecond)] do
      input = access_effect_input(fixture, %{valid_from_at: start_at})

      assert {:error, %Error{code: "VALIDATION_ERROR"}} = establish(input)
      assert count_access_effects(fixture.subscription.id) == 0
    end
  end

  test "new effective target permits a start before its end" do
    fixture = create_subscription_fixture!()
    end_at = access_effect_input(fixture).valid_until_at
    start_at = DateTime.add(end_at, -1, :day)

    assert {:ok, effect} =
             fixture
             |> access_effect_input(%{valid_from_at: start_at})
             |> establish()

    assert effect.valid_from_at == start_at
    assert effect.valid_until_at == end_at
  end

  test "new effective target permits an open-ended future start" do
    fixture = create_subscription_fixture!()
    start_at = ~U[2035-01-01 00:00:00Z]

    assert {:ok, effect} =
             fixture
             |> access_effect_input(%{valid_from_at: start_at, valid_until_at: nil})
             |> establish()

    assert DateTime.compare(effect.valid_from_at, DateTime.truncate(start_at, :microsecond)) ==
             :eq

    assert is_nil(effect.valid_until_at)
  end

  test "new effective target permits a future start before a later end" do
    fixture = create_subscription_fixture!()
    start_at = ~U[2035-01-01 00:00:00Z]
    end_at = DateTime.add(start_at, 30, :day)

    assert {:ok, effect} =
             fixture
             |> access_effect_input(%{valid_from_at: start_at, valid_until_at: end_at})
             |> establish()

    assert DateTime.compare(effect.valid_from_at, DateTime.truncate(start_at, :microsecond)) ==
             :eq

    assert DateTime.compare(effect.valid_until_at, DateTime.truncate(end_at, :microsecond)) == :eq
  end

  test "effective nil/nil targets remain legal only without a start" do
    fixture =
      create_subscription_fixture!(%{
        entitlement_kind: nil,
        entitlement_scope_key: nil
      })

    assert {:ok, effect} =
             fixture
             |> access_effect_input(%{
               entitlement_kind: nil,
               entitlement_scope_key: nil,
               valid_from_at: nil
             })
             |> establish()

    assert is_nil(effect.valid_from_at)

    invalid_fixture =
      create_subscription_fixture!(%{
        entitlement_kind: nil,
        entitlement_scope_key: nil
      })

    input =
      access_effect_input(invalid_fixture, %{
        entitlement_kind: nil,
        entitlement_scope_key: nil,
        valid_from_at: ~U[2035-01-01 00:00:00Z]
      })

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = establish(input)
    assert count_access_effects(invalid_fixture.subscription.id) == 0
  end

  test "new non-effective targets reject a supplied start" do
    fixture = create_subscription_fixture!()

    input =
      access_effect_input(fixture, %{
        disposition: :non_effective,
        entitlement_kind: nil,
        entitlement_scope_key: nil,
        valid_from_at: ~U[2035-01-01 00:00:00Z]
      })

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = establish(input)
    assert count_access_effects(fixture.subscription.id) == 0
  end

  test "legacy nil-start replay reuses its row without rewriting evidence before new-row validation" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture, %{valid_from_at: nil})
    legacy_fingerprint = AccessEffect.legacy_target_fingerprint_v1(input)
    historical = insert_legacy_access_effect!(input, legacy_fingerprint)

    before_replay = fetch_access_effect!(historical.id)
    assert is_nil(before_replay.valid_from_at)
    assert before_replay.target_fingerprint == legacy_fingerprint

    assert {:ok, replay} = establish(input)
    assert replay == before_replay
    assert replay.id == historical.id
    assert replay.target_fingerprint == legacy_fingerprint
    assert is_nil(replay.valid_from_at)
  end

  test "legacy v1 rows reject replay that asserts a non-nil start" do
    fixture = create_subscription_fixture!()
    historical_input = access_effect_input(fixture, %{valid_from_at: nil})
    legacy_fingerprint = AccessEffect.legacy_target_fingerprint_v1(historical_input)
    historical = insert_legacy_access_effect!(historical_input, legacy_fingerprint)

    incoming =
      access_effect_input(fixture, %{
        valid_from_at: DateTime.add(historical_input.valid_until_at, -1, :day)
      })

    assert {:error, %Error{code: "IDEMPOTENCY_KEY_REUSE_MISMATCH"}} = establish(incoming)
    assert fetch_access_effect!(historical.id).target_fingerprint == legacy_fingerprint
    assert is_nil(fetch_access_effect!(historical.id).valid_from_at)
  end

  test "v2 replay reuses exact starts and conflicts when only the start changes" do
    fixture = create_subscription_fixture!()
    end_at = access_effect_input(fixture).valid_until_at
    start_at = DateTime.add(end_at, -2, :day)
    input = access_effect_input(fixture, %{valid_from_at: start_at})

    assert {:ok, first} = establish(input)
    assert {:ok, replay} = establish(input)
    assert replay.id == first.id
    assert first.target_fingerprint == target_fingerprint(input)
    stored_first = fetch_access_effect!(first.id)

    conflicting = access_effect_input(fixture, %{valid_from_at: DateTime.add(start_at, -1, :day)})

    assert {:error, %Error{code: "IDEMPOTENCY_KEY_REUSE_MISMATCH"}} = establish(conflicting)
    assert fetch_access_effect!(first.id) == stored_first
  end

  test "entitlement kind and scope must be supplied as a complete pair" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    attrs = Map.from_struct(input)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             EstablishAccessEffectInput.new(%{attrs | entitlement_scope_key: nil})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             EstablishAccessEffectInput.new(%{attrs | entitlement_kind: nil})
  end

  test "typed AccessEffect input rejects a non-DateTime start" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             input
             |> Map.from_struct()
             |> Map.put(:valid_from_at, "2026-09-01T00:00:00Z")
             |> EstablishAccessEffectInput.new()
  end

  test "typed AccessEffect struct requires an explicit start key but accepts nil" do
    fixture = create_subscription_fixture!()
    attrs = access_effect_input(fixture) |> Map.from_struct()
    attrs_without_start = Map.delete(attrs, :valid_from_at)

    assert_raise ArgumentError, fn ->
      struct!(EstablishAccessEffectInput, attrs_without_start)
    end

    assert %EstablishAccessEffectInput{valid_from_at: nil} =
             struct!(
               EstablishAccessEffectInput,
               Map.put(attrs_without_start, :valid_from_at, nil)
             )
  end

  test "database constraint rejects either incomplete entitlement pair" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)

    invalid_pairs = [
      %{entitlement_kind: :membership_access, entitlement_scope_key: nil},
      %{entitlement_kind: nil, entitlement_scope_key: "members"}
    ]

    Enum.each(invalid_pairs, fn pair ->
      attrs =
        input
        |> Map.from_struct()
        |> Map.merge(pair)

      changeset =
        Ash.Changeset.for_create(AccessEffect, :establish, attrs, context: %{system?: true})

      {result, queries} =
        capture_repo_queries(fn ->
          Ash.create(changeset,
            domain: Store.Subscriptions,
            authorize?: false,
            context: %{system?: true}
          )
        end)

      assert {:error, _reason} = result

      assert Enum.any?(data_queries(queries), fn query ->
               normalized = query |> String.trim() |> String.downcase()
               String.starts_with?(normalized, "insert") and normalized =~ "access_effects"
             end)
    end)

    assert count_access_effects(fixture.subscription.id) == 0
  end

  test "a caller-owned outer rollback removes a newly established AccessEffect" do
    fixture = create_committed_subscription_fixture!()
    input = access_effect_input(fixture)

    result =
      Sandbox.unboxed_run(Store.Repo, fn ->
        Store.Repo.transaction(fn ->
          assert {:ok, effect} = establish(input)
          Store.Repo.rollback({:access_effect_rollback, effect.id})
        end)
      end)

    assert {:error, {:access_effect_rollback, _effect_id}} = result
    assert count_access_effects(fixture.subscription.id) == 0
  end

  test "concurrent exact replay creates one row and returns the same identity" do
    fixture = create_committed_subscription_fixture!()
    input = access_effect_input(fixture)
    parent = self()

    lock_holder = start_subscription_lock_holder(fixture.subscription.id, parent)
    assert_receive {:subscription_locked, blocker_pid}

    first_writer = start_writer(input, :first, parent)
    assert_receive {:access_effect_writer_started, :first}
    await_blocked_writers!(blocker_pid, 1)

    second_writer = start_writer(input, :second, parent)
    assert_receive {:access_effect_writer_started, :second}
    await_blocked_writers!(blocker_pid, 2)

    send(lock_holder.pid, :release)
    assert {:ok, :released} = Task.await(lock_holder, 10_000)

    assert {:ok, first} = Task.await(first_writer, 10_000)
    assert {:ok, second} = Task.await(second_writer, 10_000)
    assert second.id == first.id
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "same-version target conflict fails closed without changing stored evidence" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    conflicting_input = access_effect_input(fixture, %{disposition: :non_effective})

    assert {:ok, first} = establish(input)
    assert {:error, %Error{code: "IDEMPOTENCY_KEY_REUSE_MISMATCH"}} = establish(conflicting_input)

    assert {:ok, current} = current_access_effect(fixture.subscription)
    assert current.id == first.id
    assert current.disposition == :effective
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "exact historical replay reuses evidence after current Subscription provenance moves" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    assert {:ok, effect} = establish(input)

    advance_subscription_aggregate!(fixture)

    Store.Repo.query!(
      "UPDATE subscriptions SET current_plan_revision_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)]
    )

    assert {:ok, replay} = establish(input)
    assert replay.id == effect.id
  end

  test "future source versions fail closed without persisting an effect" do
    fixture = create_subscription_fixture!()
    future_version = fixture.subscription.aggregate_version + 1
    input = access_effect_input(fixture, %{source_version: future_version})

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = establish(input)
    assert count_access_effects(fixture.subscription.id) == 0
  end

  test "target entitlement evidence must match its immutable PlanRevision" do
    fixture = create_subscription_fixture!()

    for disposition <- [:effective, :non_effective] do
      input =
        access_effect_input(fixture, %{
          disposition: disposition,
          entitlement_kind: :digital_library,
          entitlement_scope_key: "vip"
        })

      assert {:error, %Error{code: "VALIDATION_ERROR"}} = establish(input)
      assert count_access_effects(fixture.subscription.id) == 0
    end

    assert {:ok, non_effective_without_entitlement} =
             establish(
               access_effect_input(fixture, %{
                 disposition: :non_effective,
                 entitlement_kind: nil,
                 entitlement_scope_key: nil
               })
             )

    assert non_effective_without_entitlement.entitlement_kind == nil
    assert non_effective_without_entitlement.entitlement_scope_key == nil
  end

  test "target fingerprint covers every canonical target field, including nil values" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    fingerprint = target_fingerprint(input)

    variations = [
      %{subscription_id: Ecto.UUID.generate()},
      %{source_version: input.source_version + 1},
      %{disposition: :non_effective, valid_from_at: input.valid_from_at},
      %{entitlement_kind: :digital_library},
      %{entitlement_scope_key: "vip_members"},
      %{valid_from_at: DateTime.add(input.valid_until_at, -1, :day)},
      %{valid_until_at: DateTime.add(input.valid_until_at, 1, :day)},
      %{valid_until_at: nil},
      %{entitlement_kind: nil, entitlement_scope_key: nil},
      %{source_order_line_item_id: Ecto.UUID.generate()},
      %{contract_change_id: Ecto.UUID.generate()},
      %{plan_revision_id: Ecto.UUID.generate()}
    ]

    assert target_fingerprint(input) == fingerprint

    Enum.each(variations, fn changed_fields ->
      changed_input = access_effect_input(fixture, changed_fields)
      refute target_fingerprint(changed_input) == fingerprint
    end)
  end

  test "legacy version 1 target fingerprint matches its fixed historical hash" do
    {:ok, valid_until_at, 0} = DateTime.from_iso8601("2026-03-04T05:06:07.123456Z")

    fields = %{
      subscription_id: "018f5c28-85ce-7a11-8f40-0e7e9f1d0001",
      source_version: 7,
      disposition: :effective,
      entitlement_kind: :membership_access,
      entitlement_scope_key: "members",
      valid_from_at: nil,
      valid_until_at: valid_until_at,
      source_order_line_item_id: "018f5c28-85ce-7a11-8f40-0e7e9f1d0002",
      contract_change_id: "018f5c28-85ce-7a11-8f40-0e7e9f1d0003",
      plan_revision_id: "018f5c28-85ce-7a11-8f40-0e7e9f1d0004"
    }

    legacy_fingerprint = "ec246cd0e293e007341889270a06d681d02cb37adc3375c27ac0b98a3bf3ab86"

    assert AccessEffect.legacy_target_fingerprint_v1(fields) == legacy_fingerprint
    refute AccessEffect.target_fingerprint(fields) == legacy_fingerprint

    assert AccessEffect.legacy_target_fingerprint_v1(
             Map.put(fields, :valid_from_at, ~U[2026-02-01 00:00:00Z])
           ) == legacy_fingerprint
  end

  test "source-version gaps are valid and unrelated aggregate writes do not stale the latest target" do
    fixture = create_subscription_fixture!()
    first_input = access_effect_input(fixture)

    assert {:ok, first} = establish(first_input)

    advance_subscription_aggregate!(fixture)
    later_subscription = advance_subscription_aggregate!(fixture)

    later_input =
      access_effect_input(fixture, %{source_version: later_subscription.aggregate_version})

    assert {:ok, later} = establish(later_input)
    assert later.source_version == later_subscription.aggregate_version
    assert later.source_version > first.source_version + 1

    latest_subscription = advance_subscription_aggregate!(fixture)

    assert {:ok, current} = current_access_effect(latest_subscription)
    assert current.id == later.id
    assert current.source_version < latest_subscription.aggregate_version
    assert fetch_access_effect!(first.id).status == :superseded
  end

  test "an older target cannot become current after a newer target exists" do
    fixture = create_subscription_fixture!()
    newer_subscription = advance_subscription_aggregate!(fixture)

    newer_input =
      access_effect_input(fixture, %{source_version: newer_subscription.aggregate_version})

    assert {:ok, newer} = establish(newer_input)

    assert {:error, %Error{code: "STALE_RECORD"}} =
             establish(access_effect_input(fixture, %{source_version: newer.source_version - 1}))

    assert {:ok, current} = current_access_effect(newer_subscription)
    assert current.id == newer.id
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "competing source versions preserve the newer target for either lock-arrival order" do
    Enum.each([:ascending, :descending], fn arrival_order ->
      fixture = create_committed_subscription_fixture!()
      latest = advance_subscription_aggregate!(fixture, committed?: true)
      high_version = latest.aggregate_version
      low_version = high_version - 1

      version_order =
        if arrival_order == :ascending,
          do: [low_version, high_version],
          else: [high_version, low_version]

      [first_version, second_version] = version_order
      first_input = access_effect_input(fixture, %{source_version: first_version})
      second_input = access_effect_input(fixture, %{source_version: second_version})
      parent = self()

      lock_holder = start_subscription_lock_holder(fixture.subscription.id, parent)
      assert_receive {:subscription_locked, blocker_pid}

      first_writer = start_writer(first_input, :first, parent)
      assert_receive {:access_effect_writer_started, :first}
      await_blocked_writers!(blocker_pid, 1)

      second_writer = start_writer(second_input, :second, parent)
      assert_receive {:access_effect_writer_started, :second}
      await_blocked_writers!(blocker_pid, 2)

      send(lock_holder.pid, :release)
      assert {:ok, :released} = Task.await(lock_holder, 10_000)

      first_result = Task.await(first_writer, 10_000)
      second_result = Task.await(second_writer, 10_000)
      assert {:ok, current} = current_access_effect(fixture.subscription)
      assert current.source_version == high_version

      if first_version < second_version do
        assert {:ok, first} = first_result
        assert {:ok, second} = second_result
        assert fetch_access_effect!(first.id).status == :superseded
        assert second.status == :required
        assert count_access_effects(fixture.subscription.id) == 2
      else
        assert {:ok, first} = first_result
        assert {:error, %Error{code: "STALE_RECORD"}} = second_result
        assert first.source_version == high_version
        assert count_access_effects(fixture.subscription.id) == 1
      end
    end)
  end

  test "REQUIRED supersession follows REQUIRED to PENDING to SUPERSEDED in one transaction" do
    assert_supersession_path(:required, 2)
  end

  test "PENDING supersession follows the direct PENDING to SUPERSEDED edge" do
    assert_supersession_path(:pending, 1)
  end

  test "FAILED_RETRYABLE supersession follows FAILED_RETRYABLE to PENDING to SUPERSEDED in one transaction" do
    assert_supersession_path(:failed_retryable, 2)
  end

  test "APPLIED and SUPERSEDED effects remain terminal and cannot reopen" do
    fixture = create_subscription_fixture!()
    applied = establish!(access_effect_input(fixture))
    pending = transition!(:mark_access_effect_pending_for_system, applied)
    applied = transition!(:mark_access_effect_applied_for_system, pending)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:mark_access_effect_pending_for_system, applied)

    newer_subscription = advance_subscription_aggregate!(fixture)

    newer =
      establish!(
        access_effect_input(fixture, %{source_version: newer_subscription.aggregate_version})
      )

    stale_pending = transition!(:mark_access_effect_pending_for_system, newer)
    latest_subscription = advance_subscription_aggregate!(fixture)

    _latest =
      establish!(
        access_effect_input(fixture, %{source_version: latest_subscription.aggregate_version})
      )

    superseded = fetch_access_effect!(stale_pending.id)

    assert superseded.status == :superseded

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:mark_access_effect_pending_for_system, superseded)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:mark_access_effect_applied_for_system, stale_pending)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:mark_access_effect_failed_retryable_for_system, stale_pending)

    refute function_exported?(Facade, :supersede_access_effect_for_system, 1)
    assert fetch_access_effect!(applied.id).status == :applied
    assert fetch_access_effect!(superseded.id).status == :superseded
  end

  test "lifecycle actions cannot mutate target evidence" do
    fixture = create_subscription_fixture!()
    required = establish!(access_effect_input(fixture))

    result =
      required
      |> Ash.Changeset.for_update(
        :mark_pending_from_required,
        %{disposition: :non_effective},
        context: %{system?: true}
      )
      |> Ash.update(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    assert {:error, _reason} = result
    persisted = fetch_access_effect!(required.id)
    assert persisted.status == :required
    assert persisted.disposition == :effective
  end

  test "stale required and failed effects retire without touching grants" do
    Enum.each([:required, :failed_retryable], fn initial_status ->
      fixture = create_subscription_fixture!()

      assert {:ok, grant} =
               EntitlementsFacade.issue_subscription_entitlement_for_system(
                 fixture.subscription,
                 fixture.plan
               )

      stale =
        establish!(
          access_effect_input(fixture, %{
            disposition: :non_effective,
            entitlement_kind: nil,
            entitlement_scope_key: nil
          })
        )

      stale =
        if initial_status == :failed_retryable do
          stale
          |> then(&transition!(:mark_access_effect_pending_for_system, &1))
          |> then(&transition!(:mark_access_effect_failed_retryable_for_system, &1))
        else
          stale
        end

      grant_updated_at = grant.updated_at
      newer_subscription = advance_subscription_aggregate!(fixture)

      newer_effect =
        establish!(
          access_effect_input(fixture, %{
            source_version: newer_subscription.aggregate_version,
            disposition: :non_effective,
            entitlement_kind: nil,
            entitlement_scope_key: nil
          })
        )

      Repo.query!(
        "UPDATE access_effects SET status = $2 WHERE id = $1",
        [Ecto.UUID.dump!(stale.id), Atom.to_string(initial_status)]
      )

      assert {:ok, :superseded} = Facade.execute_suspension_access_effect_for_system(stale.id)
      assert fetch_access_effect!(stale.id).status == :superseded
      assert fetch_access_effect!(newer_effect.id).status == :required

      assert {:ok, [unchanged_grant]} = read_grant(grant.id)
      assert unchanged_grant.status == :active
      assert unchanged_grant.updated_at == grant_updated_at
    end)
  end

  test "AccessEffect creation has bounded create, replay, and current-target query counts" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)

    {create_result, create_queries} = capture_repo_queries(fn -> establish(input) end)
    assert {:ok, effect} = create_result

    {replay_result, replay_queries} = capture_repo_queries(fn -> establish(input) end)
    assert {:ok, replayed} = replay_result
    assert replayed.id == effect.id

    {current_result, current_queries} =
      capture_repo_queries(fn -> current_access_effect(fixture.subscription) end)

    assert {:ok, current} = current_result
    assert current.id == effect.id
    assert length(data_queries(create_queries)) == 4
    assert length(data_queries(replay_queries)) == 2
    assert length(data_queries(current_queries)) == 1

    current_sql =
      Enum.find(current_queries, &String.contains?(String.downcase(&1), "access_effects"))

    assert String.contains?(String.downcase(current_sql), "order by")
    assert String.contains?(String.downcase(current_sql), "source_version")
    assert String.contains?(String.downcase(current_sql), "desc")
    assert String.contains?(String.downcase(current_sql), "limit")

    Store.Repo.query!("SET LOCAL enable_seqscan = off")

    {:ok, %{rows: plan_rows}} =
      Store.Repo.query(
        "EXPLAIN SELECT id FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC LIMIT 1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

    explain = plan_rows |> List.flatten() |> Enum.join(" ")
    assert explain =~ "access_effects_unique_subscription_source_version_index"
    assert explain =~ "Limit"
  end

  test "create and replay perform no Entitlements, worker, or provider side effect" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    StripeAPIStub.stub_unexpected!("AccessEffect must not call a payment provider")

    entitlement_count_before = count_subscription_entitlement_grants(fixture.subscription.id)
    job_count_before = count_oban_jobs()

    assert {:ok, _effect} = establish(input)
    assert {:ok, _replay} = establish(input)

    assert count_subscription_entitlement_grants(fixture.subscription.id) ==
             entitlement_count_before

    assert count_oban_jobs() == job_count_before
  end

  defp create_subscription_fixture!(plan_overrides \\ %{}) do
    customer =
      SubscriptionsFixtures.create_customer!("sbh_50_06_access_effect_#{Ecto.UUID.generate()}")

    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(
        Map.merge(
          %{
            entitlement_kind: :membership_access,
            entitlement_scope_key: "members"
          },
          plan_overrides
        )
      )

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      plan: plan,
      variant_plan: variant_plan
    })
  end

  defp create_committed_subscription_fixture! do
    fixture = Sandbox.unboxed_run(Store.Repo, fn -> create_subscription_fixture!() end)

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    fixture
  end

  defp advance_subscription_aggregate!(fixture, opts \\ []) do
    advance = fn ->
      subscription = reload_subscription!(fixture.subscription.id)
      unique = Ecto.UUID.generate() |> String.replace("-", "")

      updated =
        subscription
        |> Ash.Changeset.for_update(
          :set_provider_billing_reference,
          %{
            provider_customer_ref: "cus_sbh5006_#{unique}",
            provider_billing_ref: "pm_sbh5006_#{unique}"
          },
          context: %{system?: true}
        )
        |> Ash.update!(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )

      assert updated.aggregate_version == subscription.aggregate_version + 1
      updated
    end

    if Keyword.get(opts, :committed?, false) do
      Sandbox.unboxed_run(Store.Repo, advance)
    else
      advance.()
    end
  end

  defp reload_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
    |> List.first()
  end

  defp cleanup_committed_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)

      Store.Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

      Store.Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Store.Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
      Store.Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
      Store.Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
      Store.Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
      Store.Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
      Store.Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

      Store.Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [
        variant_id
      ])

      Store.Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Store.Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Store.Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Store.Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp access_effect_input(fixture, overrides \\ %{}) do
    subscription = fixture.subscription
    revision = fixture.revision
    disposition = Map.get(overrides, :disposition, :effective)

    default_valid_from_at =
      if disposition == :effective, do: subscription.current_period_start_at, else: nil

    attrs =
      %{
        subscription_id: subscription.id,
        source_version: subscription.aggregate_version,
        disposition: disposition,
        entitlement_kind: revision.entitlement_kind,
        entitlement_scope_key: revision.entitlement_scope_key,
        valid_from_at: default_valid_from_at,
        valid_until_at: subscription.current_period_end_at,
        source_order_line_item_id: fixture.line_item.id,
        contract_change_id: subscription.current_contract_change_id,
        plan_revision_id: revision.id
      }
      |> Map.merge(overrides)

    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise "invalid AccessEffect test input: #{inspect(reason)}"
    end
  end

  defp establish(input) do
    Facade.establish_access_effect_for_system(input)
  end

  defp establish!(input) do
    assert {:ok, effect} = establish(input)
    effect
  end

  defp current_access_effect(subscription) do
    Facade.get_current_access_effect_for_system(subscription)
  end

  defp transition(name, effect), do: apply(Facade, name, [effect])

  defp transition!(name, effect) do
    assert {:ok, transitioned} = transition(name, effect)
    transitioned
  end

  defp target_fingerprint(input) do
    AccessEffect.target_fingerprint(input)
  end

  defp insert_legacy_access_effect!(input, legacy_fingerprint) do
    effect =
      AccessEffect
      |> Ash.Changeset.for_create(:establish, Map.from_struct(input), context: %{system?: true})
      |> Ash.create!(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    Repo.query!(
      "UPDATE access_effects SET target_fingerprint = $2 WHERE id = $1",
      [Ecto.UUID.dump!(effect.id), legacy_fingerprint]
    )

    fetch_access_effect!(effect.id)
  end

  defp fetch_access_effect!(id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
    |> List.first()
  end

  defp assert_supersession_path(initial_status, expected_update_count) do
    fixture = create_subscription_fixture!()
    initial_input = access_effect_input(fixture)
    required = establish!(initial_input)

    current =
      case initial_status do
        :required ->
          required

        :pending ->
          transition!(:mark_access_effect_pending_for_system, required)

        :failed_retryable ->
          required
          |> then(&transition!(:mark_access_effect_pending_for_system, &1))
          |> then(&transition!(:mark_access_effect_failed_retryable_for_system, &1))
      end

    newer_subscription = advance_subscription_aggregate!(fixture)

    newer_input =
      access_effect_input(fixture, %{source_version: newer_subscription.aggregate_version})

    {newer_result, queries} = capture_repo_queries(fn -> establish(newer_input) end)
    assert {:ok, newer} = newer_result

    updates =
      Enum.count(queries, fn query ->
        sql = String.downcase(String.trim(query))
        String.starts_with?(sql, "update") and String.contains?(sql, "access_effects")
      end)

    assert updates == expected_update_count
    assert fetch_access_effect!(current.id).status == :superseded
    assert newer.status == :required
    assert count_access_effects(fixture.subscription.id) == 2
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, :access_effect_query_count, make_ref()}
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

  defp data_queries(queries) do
    Enum.reject(queries, fn query ->
      String.downcase(String.trim(query)) in ["begin", "commit", "rollback"]
    end)
  end

  defp count_subscription_entitlement_grants(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query(
        "SELECT count(*) FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(subscription_id)]
      )

    count
  end

  defp count_oban_jobs do
    {:ok, %{rows: [[count]]}} = Store.Repo.query("SELECT count(*) FROM oban_jobs")
    count
  end

  defp start_subscription_lock_holder(subscription_id, parent) do
    Task.async(fn ->
      Sandbox.unboxed_run(Store.Repo, fn ->
        hold_subscription_lock(subscription_id, parent)
      end)
    end)
  end

  defp hold_subscription_lock(subscription_id, parent) do
    Store.Repo.transaction(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Store.Repo.query("SELECT pg_backend_pid()")

      Store.Repo.query!(
        "SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE",
        [Ecto.UUID.dump!(subscription_id)]
      )

      send(parent, {:subscription_locked, backend_pid})
      await_subscription_lock_release()
    end)
  end

  defp await_subscription_lock_release do
    receive do
      :release -> :released
    after
      10_000 -> Store.Repo.rollback(:subscription_lock_holder_timeout)
    end
  end

  defp start_writer(input, writer, parent) do
    Task.async(fn ->
      Sandbox.unboxed_run(Store.Repo, fn ->
        send(parent, {:access_effect_writer_started, writer})
        establish(input)
      end)
    end)
  end

  defp await_blocked_writers!(blocker_pid, expected, attempts_left \\ 500)

  defp await_blocked_writers!(blocker_pid, expected, attempts_left)
       when attempts_left > 0 do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query(
        """
        SELECT count(*)
        FROM pg_stat_activity waiting
        WHERE waiting.wait_event_type = 'Lock'
          AND (
            $1 = ANY(pg_blocking_pids(waiting.pid))
            OR EXISTS (
              SELECT 1
              FROM pg_stat_activity direct_waiter
              WHERE $1 = ANY(pg_blocking_pids(direct_waiter.pid))
                AND direct_waiter.pid = ANY(pg_blocking_pids(waiting.pid))
            )
          )
        """,
        [blocker_pid]
      )

    if count >= expected do
      :ok
    else
      Process.sleep(10)
      await_blocked_writers!(blocker_pid, expected, attempts_left - 1)
    end
  end

  defp await_blocked_writers!(_blocker_pid, expected, _attempts_left) do
    flunk("expected #{expected} AccessEffect writers to wait for the Subscription row lock")
  end

  defp count_access_effects(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query("SELECT count(*) FROM access_effects WHERE subscription_id = $1", [
        Ecto.UUID.dump!(subscription_id)
      ])

    count
  end

  defp read_grant(grant_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(id == ^grant_id))
    |> Ash.read(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end
end
