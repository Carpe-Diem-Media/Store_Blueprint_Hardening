defmodule Store.Governance.JC258DirectAuthorizationAuditTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionVariantChangeInput
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Scheduler
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  @system_context %{system?: true}

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("JC-258 direct authorization audit must not call Stripe")
    :ok
  end

  test "direct Subscription past-due transition exposes the current admin policy mismatch" do
    for {label, actor, context, expected, owner_id, owner} <-
          authorization_actors!("jc258_past_due") do
      fixture = subscription_fixture!("jc258_past_due_#{label}", owner)
      assert fixture.subscription.user_id == owner_id
      assert_owner_context!(label, actor, fixture.subscription.user_id)
      before = fetch_subscription!(fixture.subscription.id)
      assert before.status == :active

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      changeset =
        before
        |> Ash.Changeset.for_update(:mark_past_due_transition, %{
          billing_status_reason: "payment_failed",
          past_due_since_at: now,
          failed_payment_boundary_at: now,
          dunning_attempt_count: 1,
          next_retry_at: DateTime.add(now, 86_400, :second),
          retry_suppressed_at: nil
        })

      assert changeset.valid?
      result = Ash.update(changeset, domain: Store.Subscriptions, actor: actor, context: context)

      case expected do
        :allowed ->
          assert {:ok, updated} = result
          assert updated.id == before.id
          assert updated.status == :past_due
          assert fetch_subscription!(before.id).status == :past_due

        :forbidden ->
          assert {:error, %Ash.Error.Forbidden{}} = result
          after_state = fetch_subscription!(before.id)
          assert after_state.id == before.id
          assert after_state.status == :active
          assert after_state.aggregate_version == before.aggregate_version
      end
    end
  end

  test "direct RenewalAttempt processing exposes the current admin policy mismatch" do
    for {label, actor, context, expected, owner_id, owner} <-
          authorization_actors!("jc258_processing") do
      fixture = subscription_fixture!("jc258_processing_#{label}", owner)
      assert fixture.subscription.user_id == owner_id
      assert_owner_context!(label, actor, fixture.subscription.user_id)
      attempt = legacy_authorization_attempt!(fixture.subscription)
      before = fetch_attempt!(attempt.id)
      assert before.status == :pending

      changeset = before |> Ash.Changeset.for_update(:mark_processing, %{})
      assert changeset.valid?
      result = Ash.update(changeset, domain: Store.Subscriptions, actor: actor, context: context)

      case expected do
        :allowed ->
          assert {:ok, updated} = result
          assert updated.id == before.id
          assert updated.status == :processing
          assert fetch_attempt!(before.id).status == :processing

        :forbidden ->
          assert {:error, %Ash.Error.Forbidden{}} = result
          after_state = fetch_attempt!(before.id)
          assert after_state.id == before.id
          assert after_state.status == :pending
      end
    end
  end

  test "owner detail composes a Subscription read with a system RenewalAttempt read" do
    fixture = subscription_fixture!("jc258_nested_attempt_read")
    attempt = legacy_authorization_attempt!(fixture.subscription)

    direct_query =
      RenewalAttempt
      |> Ash.Query.for_read(:read_for_subscription, %{
        subscription_id: fixture.subscription.id
      })
      |> Ash.Query.filter(expr(id == ^attempt.id))

    assert direct_query.valid?

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.read(direct_query, domain: Store.Subscriptions, actor: fixture.customer)

    assert {:ok, detail} =
             Facade.get_subscription_detail_for_user(fixture.customer, fixture.subscription.id)

    assert detail.subscription.id == fixture.subscription.id
    assert [returned_attempt] = Enum.filter(detail.renewal_attempts, &(&1.id == attempt.id))
    assert returned_attempt.subscription_id == fixture.subscription.id
    assert returned_attempt.renewal_key == attempt.renewal_key
    assert returned_attempt.status == :pending
    assert returned_attempt.attempt_no == 1
    assert returned_attempt.period_start_at == attempt.period_start_at
    assert returned_attempt.period_end_at == attempt.period_end_at

    support = actor_with_role!(:support, "jc258_nested_attempt_support")

    assert {:ok, support_detail} =
             Facade.get_subscription_detail_for_admin(support, fixture.subscription.id)

    assert [support_attempt] =
             Enum.filter(support_detail.renewal_attempts, &(&1.id == attempt.id))

    assert support_attempt.renewal_key == attempt.renewal_key
    assert support_attempt.status == :pending
    assert support_attempt.attempt_no == 1
    assert support_attempt.period_start_at == attempt.period_start_at
    assert support_attempt.period_end_at == attempt.period_end_at
  end

  test "owner and admin cancellation controls succeed while non-owner and support remain denied" do
    owner_fixture = subscription_fixture!("jc258_cancel_owner")

    assert {:ok, owner_canceled} =
             Facade.cancel_subscription_for_user(
               owner_fixture.customer,
               owner_fixture.subscription.id,
               :period_end
             )

    assert owner_canceled.cancel_at_period_end
    assert fetch_subscription!(owner_fixture.subscription.id).cancel_at_period_end

    admin = actor_with_role!(:admin, "jc258_cancel_admin")
    admin_fixture = subscription_fixture!("jc258_cancel_admin")

    assert {:ok, admin_canceled} =
             Facade.cancel_subscription_for_admin(
               admin,
               admin_fixture.subscription.id,
               :period_end
             )

    assert admin_canceled.cancel_at_period_end
    assert fetch_subscription!(admin_fixture.subscription.id).cancel_at_period_end

    non_owner = SubscriptionsFixtures.create_customer!("jc258_cancel_non_owner")
    non_owner_fixture = subscription_fixture!("jc258_cancel_non_owner_target")
    refute non_owner.id == non_owner_fixture.subscription.user_id
    support = actor_with_role!(:support, "jc258_cancel_support")
    support_fixture = subscription_fixture!("jc258_cancel_support_target")

    assert {:error, error} =
             Facade.cancel_subscription_for_user(
               non_owner,
               non_owner_fixture.subscription.id,
               :period_end
             )

    assert error.code == "SUBSCRIPTION_NOT_FOUND"
    refute fetch_subscription!(non_owner_fixture.subscription.id).cancel_at_period_end

    assert {:error, support_error} =
             Facade.cancel_subscription_for_admin(
               support,
               support_fixture.subscription.id,
               :period_end
             )

    assert support_error.code == "FORBIDDEN"
    refute fetch_subscription!(support_fixture.subscription.id).cancel_at_period_end
  end

  test "owner can rescind through its facade and support rescission is denied directly" do
    owner_fixture = subscription_fixture!("jc258_rescind_owner")

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(
               owner_fixture.customer,
               owner_fixture.subscription.id,
               :period_end
             )

    assert scheduled.cancel_at_period_end

    assert {:ok, rescinded} =
             Facade.cancel_subscription_for_user(
               owner_fixture.customer,
               owner_fixture.subscription.id,
               :rescind_period_end
             )

    refute rescinded.cancel_at_period_end
    refute fetch_subscription!(owner_fixture.subscription.id).cancel_at_period_end

    non_owner = SubscriptionsFixtures.create_customer!("jc258_rescind_non_owner")

    assert {:error, error} =
             Facade.cancel_subscription_for_user(
               non_owner,
               owner_fixture.subscription.id,
               :rescind_period_end
             )

    assert error.code == "SUBSCRIPTION_NOT_FOUND"
    refute fetch_subscription!(owner_fixture.subscription.id).cancel_at_period_end

    support_fixture = subscription_fixture!("jc258_rescind_support_target")

    assert {:ok, _scheduled} =
             Facade.cancel_subscription_for_user(
               support_fixture.customer,
               support_fixture.subscription.id,
               :period_end
             )

    support = actor_with_role!(:support, "jc258_rescind_support")
    before = fetch_subscription!(support_fixture.subscription.id)
    assert before.cancel_at_period_end

    changeset =
      before
      |> Ash.Changeset.for_update(:rescind_cancel_at_period_end_transition, %{})

    assert changeset.valid?

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(changeset, domain: Store.Subscriptions, actor: support)

    after_state = fetch_subscription!(support_fixture.subscription.id)
    assert after_state.cancel_at_period_end == before.cancel_at_period_end
    assert after_state.cancel_at_period_end_at == before.cancel_at_period_end_at
    assert after_state.aggregate_version == before.aggregate_version
  end

  test "owner and admin can queue valid distinct plan targets while non-owner and support cannot" do
    owner_fixture = subscription_fixture!("jc258_plan_owner")
    target_plan = attach_revision_to_plan!(owner_fixture)
    owner_input = plan_change_input!(owner_fixture.subscription.id, target_plan.plan.id)
    refute owner_fixture.subscription.subscription_plan_id == target_plan.plan.id

    assert {:ok, owner_result} =
             Facade.queue_subscription_plan_change_for_user(
               owner_fixture.customer,
               owner_fixture.subscription.id,
               owner_input
             )

    assert_queued_plan_change!(
      owner_result,
      target_plan.plan.id,
      target_plan.revision.id,
      owner_fixture
    )

    admin = actor_with_role!(:admin, "jc258_plan_admin")
    admin_fixture = subscription_fixture!("jc258_plan_admin")
    admin_target = attach_revision_to_plan!(admin_fixture)
    admin_input = plan_change_input!(admin_fixture.subscription.id, admin_target.plan.id)

    assert {:ok, admin_result} =
             Facade.queue_subscription_plan_change_for_admin(
               admin,
               admin_fixture.subscription.id,
               admin_input
             )

    assert_queued_plan_change!(
      admin_result,
      admin_target.plan.id,
      admin_target.revision.id,
      admin_fixture
    )

    non_owner = SubscriptionsFixtures.create_customer!("jc258_plan_non_owner")
    non_owner_fixture = subscription_fixture!("jc258_plan_non_owner_target")
    non_owner_target = attach_revision_to_plan!(non_owner_fixture)

    non_owner_input =
      plan_change_input!(non_owner_fixture.subscription.id, non_owner_target.plan.id)

    before_non_owner = fetch_subscription!(non_owner_fixture.subscription.id)
    before_non_owner_changes = contract_change_ids(non_owner_fixture.subscription.id)

    assert {:ok, nil} =
             Facade.queue_subscription_plan_change_for_user(
               non_owner,
               non_owner_fixture.subscription.id,
               non_owner_input
             )

    assert_unchanged_subscription!(before_non_owner)
    assert contract_change_ids(non_owner_fixture.subscription.id) == before_non_owner_changes

    support = actor_with_role!(:support, "jc258_plan_support")
    support_fixture = subscription_fixture!("jc258_plan_support_target")
    support_target = attach_revision_to_plan!(support_fixture)
    support_input = plan_change_input!(support_fixture.subscription.id, support_target.plan.id)
    before_support = fetch_subscription!(support_fixture.subscription.id)
    before_support_changes = contract_change_ids(support_fixture.subscription.id)

    assert {:error, %{code: "FORBIDDEN"}} =
             Facade.queue_subscription_plan_change_for_admin(
               support,
               support_fixture.subscription.id,
               support_input
             )

    assert_unchanged_subscription!(before_support)
    assert contract_change_ids(support_fixture.subscription.id) == before_support_changes
  end

  test "owner and admin can queue valid distinct variants while non-owner and support cannot" do
    owner_fixture = subscription_fixture!("jc258_variant_owner")
    owner_target = attach_target_variant!(owner_fixture)
    owner_input = variant_change_input!(owner_fixture.subscription.id, owner_target.id)
    refute owner_fixture.subscription.variant_id == owner_target.id

    assert {:ok, owner_result} =
             Facade.queue_subscription_variant_change_for_user(
               owner_fixture.customer,
               owner_fixture.subscription.id,
               owner_input
             )

    assert_queued_variant_change!(owner_result, owner_target.id, owner_fixture.subscription.id)

    admin = actor_with_role!(:admin, "jc258_variant_admin")
    admin_fixture = subscription_fixture!("jc258_variant_admin")
    admin_target = attach_target_variant!(admin_fixture)
    admin_input = variant_change_input!(admin_fixture.subscription.id, admin_target.id)

    assert {:ok, admin_result} =
             Facade.queue_subscription_variant_change_for_admin(
               admin,
               admin_fixture.subscription.id,
               admin_input
             )

    assert_queued_variant_change!(admin_result, admin_target.id, admin_fixture.subscription.id)

    non_owner = SubscriptionsFixtures.create_customer!("jc258_variant_non_owner")
    non_owner_fixture = subscription_fixture!("jc258_variant_non_owner_target")
    non_owner_target = attach_target_variant!(non_owner_fixture)

    non_owner_input =
      variant_change_input!(non_owner_fixture.subscription.id, non_owner_target.id)

    before_non_owner = fetch_subscription!(non_owner_fixture.subscription.id)
    before_non_owner_changes = contract_change_ids(non_owner_fixture.subscription.id)

    assert {:ok, nil} =
             Facade.queue_subscription_variant_change_for_user(
               non_owner,
               non_owner_fixture.subscription.id,
               non_owner_input
             )

    assert_unchanged_subscription!(before_non_owner)
    assert contract_change_ids(non_owner_fixture.subscription.id) == before_non_owner_changes

    support = actor_with_role!(:support, "jc258_variant_support")
    support_fixture = subscription_fixture!("jc258_variant_support_target")
    support_target = attach_target_variant!(support_fixture)
    support_input = variant_change_input!(support_fixture.subscription.id, support_target.id)
    before_support = fetch_subscription!(support_fixture.subscription.id)
    before_support_changes = contract_change_ids(support_fixture.subscription.id)

    assert {:error, %{code: "FORBIDDEN"}} =
             Facade.queue_subscription_variant_change_for_admin(
               support,
               support_fixture.subscription.id,
               support_input
             )

    assert_unchanged_subscription!(before_support)
    assert contract_change_ids(support_fixture.subscription.id) == before_support_changes
  end

  test "support replay of an identical queued target follows current facade behavior" do
    for state <- [:active, :past_due], kind <- [:plan, :variant] do
      prefix = "jc258_support_replay_#{state}_#{kind}"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      fixture =
        subscription_fixture!(prefix, nil, %{
          started_at: if(state == :past_due, do: DateTime.add(now, -62, :day), else: now)
        })

      target = replay_target!(fixture, kind)
      input = replay_input!(fixture, kind, target)
      admin = actor_with_role!(:admin, "#{prefix}_admin")

      assert {:ok, seeded} =
               queue_replay_target(kind, admin, fixture.subscription.id, input)

      seeded_change_id = seeded.current_contract_change_id
      assert is_binary(seeded_change_id)
      seeded_change = fetch_contract_change!(seeded_change_id)
      assert subscription_renewal_jobs(fixture.subscription.id) == []

      if state == :past_due do
        mark_replay_fixture_past_due!(fixture.subscription.id, now)
        past_due = fetch_subscription!(fixture.subscription.id)
        assert past_due.status == :past_due
        assert DateTime.compare(past_due.current_period_end_at, now) in [:lt, :eq]
        assert DateTime.compare(past_due.next_retry_at, now) == :lt
        assert DateTime.compare(past_due.failed_payment_boundary_at, now) == :gt
        assert is_nil(past_due.retry_suppressed_at)
      end

      before = fetch_subscription!(fixture.subscription.id)
      assert subscription_renewal_jobs(fixture.subscription.id) == []
      assert before.current_plan_revision_id == fixture.revision.id

      assert {:ok, renewal_period} =
               Scheduler.next_period(before.current_period_end_at, fixture.revision)

      expected_key = Scheduler.renewal_key(before.id, renewal_period.current_period_end_at)
      assert fetch_contract_change!(seeded_change_id).effective_at == seeded_change.effective_at
      before_change_ids = contract_change_ids(fixture.subscription.id)
      support = actor_with_role!(:support, "#{prefix}_support")

      assert {:ok, replayed} = queue_replay_target(kind, support, fixture.subscription.id, input)
      assert replayed.current_contract_change_id == seeded_change_id

      after_first_replay = fetch_subscription!(fixture.subscription.id)
      assert replayed_projection(after_first_replay, kind) == replayed_projection(before, kind)
      assert after_first_replay.aggregate_version == before.aggregate_version
      assert fetch_contract_change!(seeded_change_id).effective_at == seeded_change.effective_at
      assert contract_change_ids(fixture.subscription.id) == before_change_ids
      assert_replay_jobs!(state, fixture.subscription.id, expected_key)

      assert {:ok, replayed_again} =
               queue_replay_target(kind, support, fixture.subscription.id, input)

      assert replayed_again.current_contract_change_id == seeded_change_id

      assert replayed_projection(fetch_subscription!(fixture.subscription.id), kind) ==
               replayed_projection(before, kind)

      assert fetch_subscription!(fixture.subscription.id).aggregate_version ==
               before.aggregate_version

      assert fetch_contract_change!(seeded_change_id).effective_at == seeded_change.effective_at
      assert contract_change_ids(fixture.subscription.id) == before_change_ids
      assert_replay_jobs!(state, fixture.subscription.id, expected_key)
    end

    assert_support_distinct_target_denied!()
  end

  defp authorization_actors!(prefix) do
    owner = SubscriptionsFixtures.create_customer!("#{prefix}_owner")
    non_owner = SubscriptionsFixtures.create_customer!("#{prefix}_non_owner")
    support = actor_with_role!(:support, "#{prefix}_support")
    editor = actor_with_role!(:editor, "#{prefix}_editor")
    admin = actor_with_role!(:admin, "#{prefix}_admin")
    super_admin = actor_with_role!(:super_admin, "#{prefix}_super_admin")

    [
      {:owner, owner, %{}, :forbidden, owner.id, owner},
      {:non_owner, non_owner, %{}, :forbidden, owner.id, owner},
      {:support, support, %{}, :forbidden, owner.id, owner},
      {:editor, editor, %{}, :forbidden, owner.id, owner},
      {:admin, admin, %{}, :allowed, owner.id, owner},
      {:super_admin, super_admin, %{}, :allowed, owner.id, owner},
      {:system, nil, @system_context, :allowed, owner.id, owner},
      {:anonymous, nil, %{}, :forbidden, owner.id, owner}
    ]
  end

  defp assert_owner_context!(:owner, actor, subscription_user_id),
    do: assert(subscription_user_id == actor.id)

  defp assert_owner_context!(:non_owner, actor, subscription_user_id) do
    refute subscription_user_id == actor.id
  end

  defp assert_owner_context!(_label, _actor, _subscription_user_id), do: :ok

  defp subscription_fixture!(prefix, customer \\ nil, overrides \\ %{}) do
    customer = customer || SubscriptionsFixtures.create_customer!("#{prefix}_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_#{prefix}",
        provider_billing_ref: "pm_#{prefix}",
        started_at:
          Map.get(overrides, :started_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
      })

    Map.merge(fixture, %{customer: customer, plan: plan, variant: variant})
  end

  defp attach_revision_to_plan!(fixture) do
    plan = SubscriptionsFixtures.create_subscription_plan!()

    _attachment =
      SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, plan.id)

    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    %{plan: plan, revision: revision}
  end

  defp attach_target_variant!(fixture) do
    %{variant: target_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    _attachment =
      SubscriptionsFixtures.attach_variant_plan!(target_variant.id, fixture.plan.id)

    target_variant
  end

  defp replay_target!(fixture, :plan), do: attach_revision_to_plan!(fixture)
  defp replay_target!(fixture, :variant), do: attach_target_variant!(fixture)

  defp replay_input!(fixture, :plan, target),
    do: plan_change_input!(fixture.subscription.id, target.plan.id)

  defp replay_input!(fixture, :variant, target),
    do: variant_change_input!(fixture.subscription.id, target.id)

  defp queue_replay_target(:plan, actor, subscription_id, input),
    do: Facade.queue_subscription_plan_change_for_admin(actor, subscription_id, input)

  defp queue_replay_target(:variant, actor, subscription_id, input),
    do: Facade.queue_subscription_variant_change_for_admin(actor, subscription_id, input)

  defp replayed_projection(subscription, :plan),
    do:
      {subscription.status, subscription.pending_subscription_plan_id,
       subscription.current_contract_change_id}

  defp replayed_projection(subscription, :variant),
    do:
      {subscription.status, subscription.pending_variant_id,
       subscription.current_contract_change_id}

  defp mark_replay_fixture_past_due!(subscription_id, now) do
    changeset =
      fetch_subscription!(subscription_id)
      |> Ash.Changeset.for_update(:mark_past_due_transition, %{
        billing_status_reason: "payment_failed",
        past_due_since_at: DateTime.add(now, -86_400, :second),
        failed_payment_boundary_at: DateTime.add(now, 86_400, :second),
        dunning_attempt_count: 1,
        next_retry_at: DateTime.add(now, -1, :second),
        retry_suppressed_at: nil
      })

    assert changeset.valid?

    assert {:ok, _updated} =
             Ash.update(changeset,
               domain: Store.Subscriptions,
               actor: nil,
               context: @system_context
             )
  end

  defp assert_support_distinct_target_denied! do
    fixture = subscription_fixture!("jc258_support_replay_distinct")
    first_target = attach_revision_to_plan!(fixture)
    second_target = attach_revision_to_plan!(fixture)
    admin = actor_with_role!(:admin, "jc258_support_replay_distinct_admin")
    support = actor_with_role!(:support, "jc258_support_replay_distinct_support")

    assert {:ok, _queued} =
             Facade.queue_subscription_plan_change_for_admin(
               admin,
               fixture.subscription.id,
               plan_change_input!(fixture.subscription.id, first_target.plan.id)
             )

    before = fetch_subscription!(fixture.subscription.id)
    before_changes = contract_change_ids(fixture.subscription.id)

    assert {:error, %{code: "FORBIDDEN"}} =
             Facade.queue_subscription_plan_change_for_admin(
               support,
               fixture.subscription.id,
               plan_change_input!(fixture.subscription.id, second_target.plan.id)
             )

    assert_unchanged_subscription!(before)
    assert contract_change_ids(fixture.subscription.id) == before_changes
    assert subscription_renewal_jobs(fixture.subscription.id) == []
  end

  defp assert_queued_plan_change!(result, target_plan_id, target_revision_id, fixture) do
    assert result.id == fixture.subscription.id
    assert result.pending_subscription_plan_id == target_plan_id
    refute result.pending_subscription_plan_id == fixture.subscription.subscription_plan_id
    change = fetch_contract_change!(result.current_contract_change_id)
    assert change.subscription_id == fixture.subscription.id
    assert change.status == :queued
    assert change.instruction_kind == :plan_change
    assert change.target_plan_revision_id == target_revision_id

    persisted = fetch_subscription!(fixture.subscription.id)
    assert persisted.pending_subscription_plan_id == target_plan_id
    assert persisted.current_contract_change_id == change.id
  end

  defp assert_queued_variant_change!(result, target_variant_id, subscription_id) do
    assert result.id == subscription_id
    assert result.pending_variant_id == target_variant_id
    change = fetch_contract_change!(result.current_contract_change_id)
    assert change.subscription_id == subscription_id
    assert change.status == :queued
    assert change.instruction_kind == :variant_change
    assert change.target_variant_id == target_variant_id

    persisted = fetch_subscription!(subscription_id)
    assert persisted.pending_variant_id == target_variant_id
    assert persisted.current_contract_change_id == change.id
  end

  defp assert_unchanged_subscription!(before) do
    after_state = fetch_subscription!(before.id)
    assert after_state.current_contract_change_id == before.current_contract_change_id
    assert after_state.pending_subscription_plan_id == before.pending_subscription_plan_id
    assert after_state.pending_variant_id == before.pending_variant_id
    assert after_state.aggregate_version == before.aggregate_version
    assert after_state.cancel_at_period_end == before.cancel_at_period_end
    assert after_state.cancel_at_period_end_at == before.cancel_at_period_end_at
  end

  defp legacy_authorization_attempt!(subscription) do
    attrs = %{
      subscription_id: subscription.id,
      period_start_at: subscription.current_period_start_at,
      period_end_at: subscription.current_period_end_at,
      renewal_key: "jc258-auth-#{Ash.UUIDv7.generate()}",
      status: :pending,
      attempt_no: 1
    }

    changeset =
      RenewalAttempt
      |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: @system_context)

    assert changeset.valid?
    assert is_nil(changeset.attributes[:plan_revision_id])
    assert is_nil(changeset.attributes[:variant_id])
    assert is_nil(changeset.attributes[:quantity])
    assert is_nil(changeset.attributes[:amount_minor])
    assert is_nil(changeset.attributes[:currency])
    assert is_nil(changeset.attributes[:contract_change_id])
    assert is_nil(changeset.attributes[:expected_subscription_version])
    assert is_nil(changeset.attributes[:charged_contract_version])
    assert is_nil(changeset.attributes[:charged_contract_snapshot])

    attempt =
      Ash.create!(changeset,
        domain: Store.Subscriptions,
        authorize?: false,
        context: @system_context
      )

    assert is_nil(attempt.plan_revision_id)
    assert is_nil(attempt.variant_id)
    assert is_nil(attempt.quantity)
    assert is_nil(attempt.amount_minor)
    assert is_nil(attempt.currency)
    assert is_nil(attempt.contract_change_id)
    assert is_nil(attempt.expected_subscription_version)
    assert is_nil(attempt.charged_contract_version)
    assert is_nil(attempt.charged_contract_snapshot)
    attempt
  end

  defp plan_change_input!(subscription_id, target_plan_id) do
    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               "subscription_id" => subscription_id,
               "subscription_plan_id" => target_plan_id
             })

    input
  end

  defp variant_change_input!(subscription_id, target_variant_id) do
    assert {:ok, input} =
             QueueSubscriptionVariantChangeInput.new(%{
               "subscription_id" => subscription_id,
               "variant_id" => target_variant_id
             })

    input
  end

  defp actor_with_role!(role, prefix) do
    actor = TestFixtures.register_user!(email: TestFixtures.unique_email(prefix))
    _assignment = TestFixtures.assign_role!(actor, role)
    actor
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> List.first()
  end

  defp fetch_attempt!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> List.first()
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> List.first()
  end

  defp contract_change_ids(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp subscription_renewal_jobs(subscription_id) do
    all_enqueued(worker: Store.Workers.ProcessSubscriptionRenewalWorker)
    |> Enum.filter(&(&1.args["subscription_id"] == subscription_id))
  end

  defp assert_replay_jobs!(:active, subscription_id, _expected_key),
    do: assert(subscription_renewal_jobs(subscription_id) == [])

  defp assert_replay_jobs!(:past_due, subscription_id, expected_key) do
    jobs = subscription_renewal_jobs(subscription_id)
    assert length(jobs) == 1

    assert [
             %Oban.Job{
               args: %{"subscription_id" => ^subscription_id, "renewal_key" => ^expected_key}
             }
           ] = jobs
  end
end
