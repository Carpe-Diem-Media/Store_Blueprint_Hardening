defmodule Store.Subscriptions.AccessEffectNonEffectiveExecutionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.{Cache, EntitlementGrant}
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade, Subscription}
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "current non-effective effect revokes past-due source grants with purchased-policy reason" do
    fixture = create_committed_suspended_effect_fixture!("jc247_b_past_due")

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("UPDATE subscriptions SET status = 'past_due' WHERE id = $1", [
        Ecto.UUID.dump!(fixture.subscription_id)
      ])
    end)

    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.user_id))

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "past_due_remove_immediately"}] =
             grants_for_source!(fixture.subscription_id)

    assert_receive {:entitlements_invalidated, _, "non_effective_access_effect_applied", _}
  end

  test "APPLIED source repair revokes an exact-source grant that became active again" do
    fixture = create_committed_suspended_effect_fixture!("jc248_reactivation")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    effect_snapshot = fetch_effect!(fixture.effect_id)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE entitlement_grants SET status = 'active', revoked_at = NULL, revoked_reason = NULL WHERE id = $1",
        [Ecto.UUID.dump!(fixture.grant_id)]
      )
    end)

    assert {:ok, :repaired} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect_id)
             end)

    assert %EntitlementGrant{
             status: :revoked,
             revoked_reason: "subscription_source_reconciliation"
           } = fetch_grant!(fixture.grant_id)

    assert fetch_effect!(fixture.effect_id) == effect_snapshot

    repaired_grants = grants_for_source!(fixture.subscription_id)

    assert {:ok, :already_converged} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.repair_applied_access_effect_for_system(fixture.effect_id)
             end)

    assert grants_for_source!(fixture.subscription_id) == repaired_grants
    assert fetch_effect!(fixture.effect_id) == effect_snapshot
  end

  test "the public NON_EFFECTIVE executor rejects a caller-owned transaction before writes on commit" do
    fixture = create_committed_suspended_effect_fixture!("jc246_nested_commit")
    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.user_id))

    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)
    assert before_effect.status == :required
    assert before_effect.projection_user_ids == nil
    assert before_effect.projection_delivered_at == nil
    assert length(before_grants) == 1

    assert {:ok, {result, ^before_effect, ^before_grants}} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()
                 result = Facade.execute_suspension_access_effect_for_system(fixture.effect_id)

                 {result, fetch_effect!(fixture.effect_id),
                  grants_for_source!(fixture.subscription_id)}
               end)
             end)

    assert {:error,
            %{
              code: "VALIDATION_ERROR",
              message: "NON_EFFECTIVE AccessEffect execution must own its correctness transaction"
            }} = result

    assert fetch_effect!(fixture.effect_id) == before_effect
    assert grants_for_source!(fixture.subscription_id) == before_grants
    refute_receive {:entitlements_invalidated, _, _, _}, 0
  end

  test "the public NON_EFFECTIVE executor rejects a caller-owned transaction before writes on rollback" do
    fixture = create_committed_suspended_effect_fixture!("jc246_nested_rollback")
    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.user_id))

    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)
    assert before_effect.status == :required
    assert before_effect.projection_user_ids == nil
    assert before_effect.projection_delivered_at == nil
    assert length(before_grants) == 1

    assert {:error, {:forced_rollback, result, ^before_effect, ^before_grants}} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()
                 result = Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
                 effect = fetch_effect!(fixture.effect_id)
                 grants = grants_for_source!(fixture.subscription_id)
                 Repo.rollback({:forced_rollback, result, effect, grants})
               end)
             end)

    assert {:error,
            %{
              code: "VALIDATION_ERROR",
              message: "NON_EFFECTIVE AccessEffect execution must own its correctness transaction"
            }} = result

    assert fetch_effect!(fixture.effect_id) == before_effect
    assert grants_for_source!(fixture.subscription_id) == before_grants
    refute_receive {:entitlements_invalidated, _, _, _}, 0
  end

  test "a latest NON_EFFECTIVE effect remains executable when its source version trails the aggregate" do
    fixture = create_committed_suspended_effect_fixture!("jc246_lower_source_version")

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
        [Ecto.UUID.dump!(fixture.subscription_id)]
      )
    end)

    effect = fetch_effect!(fixture.effect_id)
    subscription = fetch_subscription!(fixture.subscription_id)
    assert effect.source_version < subscription.aggregate_version
    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.user_id))

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert_receive {:entitlements_invalidated, user_id, "non_effective_access_effect_applied",
                    _at}

    assert user_id == fixture.user_id

    assert fetch_effect!(fixture.effect_id).status == :applied

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "grace_expired"}] =
             grants_for_source!(fixture.subscription_id)
  end

  test "an effect above the aggregate version fails before lifecycle or grant mutation" do
    fixture = create_committed_suspended_effect_fixture!("jc246_source_version_ahead")
    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE subscriptions SET aggregate_version = $2 WHERE id = $1",
        [Ecto.UUID.dump!(fixture.subscription_id), before_effect.source_version - 1]
      )
    end)

    assert {:error, _reason} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert fetch_effect!(fixture.effect_id) == before_effect
    assert grants_for_source!(fixture.subscription_id) == before_grants
  end

  test "a fingerprint mismatch fails before lifecycle or grant mutation" do
    fixture = create_committed_suspended_effect_fixture!("jc246_fingerprint_mismatch")
    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE access_effects SET target_fingerprint = repeat('0', 64) WHERE id = $1",
        [Ecto.UUID.dump!(fixture.effect_id)]
      )
    end)

    assert {:error, _reason} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert fetch_effect!(fixture.effect_id).status == before_effect.status
    assert grants_for_source!(fixture.subscription_id) == before_grants
  end

  test "execution revokes every active exact-source row and preserves history and other sources" do
    fixture = create_committed_suspended_effect_fixture!("jc246_exact_source_set")
    other_subscription = create_other_subscription_fixture!(fixture)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    future =
      create_grant!(fixture, "#{fixture.effect_id}:future", :active,
        valid_from_at: DateTime.add(now, 3_600, :second),
        valid_to_at: DateTime.add(now, 7_200, :second)
      )

    ended =
      create_grant!(fixture, "#{fixture.effect_id}:ended", :active,
        valid_from_at: DateTime.add(now, -7_200, :second),
        valid_to_at: DateTime.add(now, -3_600, :second)
      )

    revoked =
      create_grant!(fixture, "#{fixture.effect_id}:historical-revoked", :revoked,
        valid_from_at: DateTime.add(now, -7_200, :second),
        valid_to_at: DateTime.add(now, -3_600, :second),
        revoked_at: DateTime.add(now, -1_800, :second),
        revoked_reason: "legacy_revocation"
      )

    expired =
      create_grant!(fixture, "#{fixture.effect_id}:historical-expired", :expired,
        valid_from_at: DateTime.add(now, -7_200, :second),
        valid_to_at: DateTime.add(now, -3_600, :second)
      )

    other_source =
      create_grant!(fixture, "#{fixture.effect_id}:other-source", :active,
        source_id: other_subscription.id,
        valid_from_at: DateTime.add(now, -60, :second),
        valid_to_at: DateTime.add(now, 86_400, :second)
      )

    before_source_grants = grants_for_source!(fixture.subscription_id)
    before_other_source = fetch_grant!(other_source.id)
    assert DateTime.compare(future.valid_from_at, now) == :gt
    assert DateTime.compare(ended.valid_to_at, now) != :gt

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    after_source_grants = grants_for_source!(fixture.subscription_id)

    active_ids_before =
      before_source_grants
      |> Enum.filter(&(&1.status == :active))
      |> Enum.map(& &1.id)

    active_after = Enum.filter(after_source_grants, &(&1.id in active_ids_before))

    assert length(active_after) == length(active_ids_before)

    assert Enum.all?(active_after, fn grant ->
             grant.status == :revoked and grant.revoked_reason == "grace_expired"
           end)

    assert entitlement_grant_attributes(fetch_grant!(revoked.id)) ==
             entitlement_grant_attributes(revoked)

    assert entitlement_grant_attributes(fetch_grant!(expired.id)) ==
             entitlement_grant_attributes(expired)

    assert fetch_grant!(other_source.id) == before_other_source
  end

  test "PENDING and FAILED_RETRYABLE NON_EFFECTIVE effects execute successfully" do
    for status <- [:pending, :failed_retryable] do
      fixture = create_committed_suspended_effect_fixture!("jc246_#{status}_success")
      set_effect_status!(fixture.effect_id, status)

      assert {:ok, :applied} =
               Sandbox.unboxed_run(Repo, fn ->
                 Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
               end)

      assert fetch_effect!(fixture.effect_id).status == :applied

      assert [%EntitlementGrant{status: :revoked, revoked_reason: "grace_expired"}] =
               grants_for_source!(fixture.subscription_id)
    end
  end

  test "stale NON_EFFECTIVE effects supersede from every executable status" do
    for status <- [:required, :pending, :failed_retryable] do
      fixture = create_committed_suspended_effect_fixture!("jc246_stale_#{status}")
      newer_effect = establish_newer_non_effective_effect!(fixture)
      set_effect_status!(fixture.effect_id, status)
      before_grants = grants_for_source!(fixture.subscription_id)

      assert {:ok, :superseded} =
               Sandbox.unboxed_run(Repo, fn ->
                 Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
               end)

      assert fetch_effect!(fixture.effect_id).status == :superseded
      assert fetch_effect!(newer_effect.id).status == :required
      assert grants_for_source!(fixture.subscription_id) == before_grants
    end
  end

  test "APPLIED and SUPERSEDED NON_EFFECTIVE effects replay as no-op" do
    applied_fixture = create_committed_suspended_effect_fixture!("jc246_applied_terminal")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(applied_fixture.effect_id)
             end)

    applied_grants = grants_for_source!(applied_fixture.subscription_id)

    assert {:ok, :noop} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(applied_fixture.effect_id)
             end)

    assert grants_for_source!(applied_fixture.subscription_id) == applied_grants

    superseded_fixture = create_committed_suspended_effect_fixture!("jc246_superseded_terminal")
    establish_newer_non_effective_effect!(superseded_fixture)

    assert fetch_effect!(superseded_fixture.effect_id).status == :superseded

    assert {:ok, :noop} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(superseded_fixture.effect_id)
             end)
  end

  test "the NON_EFFECTIVE executor rejects a complete EFFECTIVE target without mutation" do
    fixture = create_committed_effective_effect_fixture!("jc246_reject_effective_pair", :pair)
    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)

    assert {:error, _reason} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert fetch_effect!(fixture.effect_id) == before_effect
    assert grants_for_source!(fixture.subscription_id) == before_grants
  end

  test "the NON_EFFECTIVE executor rejects EFFECTIVE nil/nil without mutation" do
    fixture = create_committed_effective_effect_fixture!("jc246_reject_effective_empty", :empty)
    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)

    assert {:error, _reason} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert fetch_effect!(fixture.effect_id) == before_effect
    assert grants_for_source!(fixture.subscription_id) == before_grants
  end

  test "immediate cancellation evidence maps grant revocation to canceled_now" do
    fixture = create_committed_suspended_effect_fixture!("jc246_immediate_cancel_reason")
    set_cancellation_evidence!(fixture.subscription_id, "user_request")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "canceled_now"}] =
             grants_for_source!(fixture.subscription_id)
  end

  test "scheduled cancellation evidence maps grant revocation to canceled_period_end" do
    fixture = create_committed_suspended_effect_fixture!("jc246_period_end_cancel_reason")
    set_cancellation_evidence!(fixture.subscription_id, "canceled_period_end")

    assert {:ok, :applied} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "canceled_period_end"}] =
             grants_for_source!(fixture.subscription_id)
  end

  test "runtime resource review measures bounded exact-source NON_EFFECTIVE convergence" do
    for repetition <- 1..2 do
      fixture = create_committed_suspended_effect_fixture!("jc246_resource_#{repetition}")

      Sandbox.unboxed_run(Repo, fn ->
        insert_active_source_rows!(fixture, 127)
      end)

      {result, stats, resource} =
        Sandbox.unboxed_run(Repo, fn ->
          source_id = Ecto.UUID.dump!(fixture.subscription_id)

          %{rows: [[source_rows_before]]} =
            Repo.query!(
              "SELECT count(*) FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
              [source_id]
            )

          {:memory, memory_before} = Process.info(self(), :memory)
          {:message_queue_len, mailbox_before} = Process.info(self(), :message_queue_len)
          {gc_count_before, reclaimed_words_before, _} = :erlang.statistics(:garbage_collection)
          started_at = System.monotonic_time(:microsecond)

          {result, stats} =
            RepoStats.capture(fn ->
              Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
            end)

          duration_us = System.monotonic_time(:microsecond) - started_at
          {:memory, memory_after} = Process.info(self(), :memory)
          {:message_queue_len, mailbox_after} = Process.info(self(), :message_queue_len)
          {gc_count_after, reclaimed_words_after, _} = :erlang.statistics(:garbage_collection)

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
            mailbox_delta: mailbox_after - mailbox_before,
            global_gc_count_delta: gc_count_after - gc_count_before,
            global_reclaimed_words_delta: reclaimed_words_after - reclaimed_words_before
          }

          {result, stats, resource}
        end)

      assert {:ok, :applied} = result
      assert resource.source_rows_before == 128
      assert resource.source_rows_after == 128
      assert resource.active_rows_after == 0

      IO.puts(
        "JC246_RESOURCE repetition=#{repetition} exact_source_rows=#{resource.source_rows_before} " <>
          "rows_after=#{resource.source_rows_after} active_after=#{resource.active_rows_after} " <>
          "sql_queries=#{stats.query_count} convergence_duration_us=#{resource.duration_us} " <>
          "process_memory_delta_bytes=#{resource.memory_delta_bytes} " <>
          "mailbox_delta=#{resource.mailbox_delta} " <>
          "global_gc_count_delta=#{resource.global_gc_count_delta} " <>
          "global_reclaimed_words_delta=#{resource.global_reclaimed_words_delta}"
      )
    end
  end

  test "stale EFFECTIVE candidates fail disposition admission before supersession" do
    fixture = create_committed_effective_effect_fixture!("jc246_stale_effective_pair", :pair)
    newer_effect = establish_newer_non_effective_effect!(fixture)
    set_effect_status!(fixture.effect_id, :required)
    before_effect = fetch_effect!(fixture.effect_id)
    before_grants = grants_for_source!(fixture.subscription_id)

    assert {:error, _reason} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert fetch_effect!(fixture.effect_id) == before_effect
    assert fetch_effect!(newer_effect.id).status == :required
    assert grants_for_source!(fixture.subscription_id) == before_grants
  end

  test "an incomplete EFFECTIVE pair fails before lifecycle or grant mutation" do
    fixture = create_committed_effective_effect_fixture!("jc246_incomplete_effective_pair", :pair)
    effect = fetch_effect!(fixture.effect_id)
    malformed = %{effect | valid_from_at: nil}
    fingerprint = AccessEffect.target_fingerprint(malformed)
    before_grants = grants_for_source!(fixture.subscription_id)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE access_effects SET valid_from_at = NULL, target_fingerprint = $2 WHERE id = $1",
        [Ecto.UUID.dump!(fixture.effect_id), fingerprint]
      )
    end)

    assert {:error, _reason} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
             end)

    assert fetch_effect!(fixture.effect_id).status == :required
    assert grants_for_source!(fixture.subscription_id) == before_grants
  end

  defp create_committed_suspended_effect_fixture!(prefix) do
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        create_suspended_effect_fixture!(prefix)
      end)

    on_exit(fn -> cleanup_fixture!(fixture) end)
    fixture
  end

  defp create_suspended_effect_fixture!(prefix) do
    setup_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("#{prefix}_#{Ecto.UUID.generate()}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 0,
        grace_period_days: 0,
        access_on_past_due: :keep_during_grace,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, order: order, line_item: line_item} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{prefix}",
        next_renewal_at: DateTime.add(setup_now, -1, :second)
      })

    failure_now = DateTime.add(subscription.current_period_start_at, 1, :second)

    grant =
      EntitlementGrant
      |> Ash.Changeset.for_create(
        :issue,
        %{
          user_id: customer.id,
          kind: :membership_access,
          scope_key: plan.entitlement_scope_key,
          source_kind: :subscription,
          source_id: subscription.id,
          status: :active,
          valid_from_at: DateTime.add(setup_now, -60, :second),
          valid_to_at: DateTime.add(setup_now, 86_400, :second)
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: failure_now)

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    effect = suspension_access_effect!(subscription.id)

    %{
      effect_id: effect.id,
      grant_id: grant.id,
      line_item_id: line_item.id,
      order_id: order.id,
      plan_id: plan.id,
      product_id: product.id,
      subscription_id: subscription.id,
      user_id: customer.id,
      plan: plan,
      variant: variant,
      variant_id: variant.id,
      variant_plan_id: variant_plan.id
    }
  end

  defp create_committed_effective_effect_fixture!(prefix, target) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, fixture} =
          Repo.transaction(fn -> create_effective_effect_fixture!(prefix, target) end)

        fixture
      end)

    on_exit(fn -> cleanup_fixture!(fixture) end)
    fixture
  end

  defp create_effective_effect_fixture!(prefix, target) do
    customer = SubscriptionsFixtures.create_customer!("#{prefix}_#{Ecto.UUID.generate()}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
    subscription = fixture.subscription

    target_attrs =
      case target do
        :pair ->
          %{
            entitlement_kind: fixture.revision.entitlement_kind,
            entitlement_scope_key: fixture.revision.entitlement_scope_key,
            valid_from_at: subscription.current_period_start_at,
            valid_until_at: subscription.current_period_end_at
          }

        :empty ->
          %{
            entitlement_kind: fixture.revision.entitlement_kind,
            entitlement_scope_key: fixture.revision.entitlement_scope_key,
            valid_from_at: subscription.current_period_start_at,
            valid_until_at: subscription.current_period_end_at
          }
      end

    attrs =
      Map.merge(
        %{
          subscription_id: subscription.id,
          source_version: subscription.aggregate_version,
          disposition: :effective,
          source_order_line_item_id: fixture.line_item.id,
          contract_change_id: subscription.current_contract_change_id,
          plan_revision_id: fixture.revision.id
        },
        target_attrs
      )

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)

    effect =
      if target == :empty do
        empty_target = %{
          effect
          | entitlement_kind: nil,
            entitlement_scope_key: nil,
            valid_from_at: nil,
            valid_until_at: nil
        }

        fingerprint = AccessEffect.target_fingerprint(empty_target)

        Repo.query!(
          "UPDATE access_effects SET entitlement_kind = NULL, entitlement_scope_key = NULL, valid_from_at = NULL, valid_until_at = NULL, target_fingerprint = $2 WHERE id = $1",
          [Ecto.UUID.dump!(effect.id), fingerprint]
        )

        fetch_effect!(effect.id)
      else
        effect
      end

    Map.merge(fixture, %{
      customer: customer,
      effect_id: effect.id,
      line_item_id: fixture.line_item.id,
      order_id: fixture.order.id,
      plan_id: plan.id,
      plan: plan,
      product: product,
      product_id: product.id,
      subscription_id: subscription.id,
      user_id: customer.id,
      variant: variant,
      variant_id: variant.id,
      variant_plan: variant_plan
    })
  end

  defp establish_newer_non_effective_effect!(fixture) do
    candidate = fetch_effect!(fixture.effect_id)
    subscription = fetch_subscription!(fixture.subscription_id)
    source_version = subscription.aggregate_version + 1

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE subscriptions SET aggregate_version = $2 WHERE id = $1",
        [Ecto.UUID.dump!(fixture.subscription_id), source_version]
      )
    end)

    assert {:ok, input} =
             EstablishAccessEffectInput.new(%{
               subscription_id: fixture.subscription_id,
               source_version: source_version,
               disposition: :non_effective,
               entitlement_kind: nil,
               entitlement_scope_key: nil,
               valid_from_at: nil,
               valid_until_at: nil,
               source_order_line_item_id: candidate.source_order_line_item_id,
               contract_change_id: candidate.contract_change_id,
               plan_revision_id: candidate.plan_revision_id
             })

    assert {:ok, effect} =
             Sandbox.unboxed_run(Repo, fn -> Facade.establish_access_effect_for_system(input) end)

    effect
  end

  defp set_effect_status!(effect_id, status) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE access_effects SET status = $2 WHERE id = $1",
        [Ecto.UUID.dump!(effect_id), Atom.to_string(status)]
      )
    end)
  end

  defp set_cancellation_evidence!(subscription_id, canceled_reason) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "UPDATE subscriptions SET status = 'canceled', canceled_reason = $2, current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(subscription_id), canceled_reason]
      )
    end)
  end

  defp create_other_subscription_fixture!(fixture) do
    other =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, other} =
          Repo.transaction(fn ->
            %{product: product, variant: variant} =
              SubscriptionsFixtures.create_subscription_sellable!()

            plan =
              SubscriptionsFixtures.create_subscription_plan!(%{
                entitlement_kind: :membership_access,
                entitlement_scope_key: "membership:jc246_other_#{Ecto.UUID.generate()}"
              })

            variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

            SubscriptionsFixtures.create_subscription_fixture!(
              fixture.user_id,
              variant,
              plan
            )
            |> Map.merge(%{
              plan: plan,
              product: product,
              variant: variant,
              variant_plan: variant_plan
            })
          end)

        other
      end)

    on_exit(fn -> cleanup_other_subscription_fixture!(other) end)
    other.subscription
  end

  defp cleanup_other_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)

      Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])

      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
      Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
      Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp cleanup_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription_id)
      variant_id = Ecto.UUID.dump!(fixture.variant_id)
      product_id = Ecto.UUID.dump!(fixture.product_id)
      plan_id = Ecto.UUID.dump!(fixture.plan_id)
      user_id = Ecto.UUID.dump!(fixture.user_id)

      Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM entitlement_grants WHERE user_id = $1", [user_id])

      Repo.query!(
        "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
        )

        Repo.query!(
          """
          DELETE FROM renewal_collection_attempts
          WHERE renewal_attempt_id IN (
            SELECT id
            FROM renewal_attempts
            WHERE subscription_id = $1
          )
          """,
          [subscription_id]
        )

        Repo.query!(
          "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
        )
      end)

      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Repo.query!(
        "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

      Repo.query!(
        "DELETE FROM email_outboxes WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM fulfillment_orders WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp suspension_access_effect!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(
      expr(subscription_id == ^subscription_id and disposition == :non_effective)
    )
    |> Ash.Query.sort(source_version: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_grant!(grant_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(id == ^grant_id))
    |> Ash.read_one!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp entitlement_grant_attributes(grant) do
    Map.take(grant, EntitlementGrant |> ResourceInfo.attribute_names() |> MapSet.to_list())
  end

  defp create_grant!(fixture, scope_key, status, opts) do
    attrs = %{
      user_id: fixture.user_id,
      kind: :membership_access,
      scope_key: scope_key,
      source_kind: :subscription,
      source_id: Keyword.get(opts, :source_id, fixture.subscription_id),
      status: status,
      valid_from_at: Keyword.fetch!(opts, :valid_from_at),
      valid_to_at: Keyword.get(opts, :valid_to_at),
      revoked_at: Keyword.get(opts, :revoked_at),
      revoked_reason: Keyword.get(opts, :revoked_reason)
    }

    Sandbox.unboxed_run(Repo, fn ->
      EntitlementGrant
      |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
      |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    end)
  end

  defp insert_active_source_rows!(fixture, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    ids = Enum.map(1..count, fn _ -> Ash.UUIDv7.generate() |> Ecto.UUID.dump!() end)
    scope_keys = Enum.map(1..count, &"membership:jc246:resource:#{&1}")

    Repo.query!(
      """
      INSERT INTO entitlement_grants (
        id, user_id, kind, scope_key, source_kind, source_id, status,
        valid_from_at, valid_to_at, inserted_at, updated_at
      )
      SELECT row.id, $2, 'membership_access', row.scope_key,
             'subscription', $3, 'active', $4, $5, $6, $6
      FROM unnest($1::uuid[], $7::text[]) AS row(id, scope_key)
      """,
      [
        ids,
        Ecto.UUID.dump!(fixture.user_id),
        Ecto.UUID.dump!(fixture.subscription_id),
        DateTime.add(now, -60, :second),
        DateTime.add(now, 86_400, :second),
        now,
        scope_keys
      ]
    )
  end
end
