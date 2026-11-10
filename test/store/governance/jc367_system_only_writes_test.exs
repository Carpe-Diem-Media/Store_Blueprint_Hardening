defmodule Store.Governance.JC367SystemOnlyWritesTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{ContractChange, Facade, RenewalAttempt, Subscription}
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures

  @system_context %{system?: true}

  @subscription_create_attributes [
    :user_id,
    :subscription_plan_id,
    :status,
    :provider,
    :provider_subscription_id,
    :billing_mode,
    :billing_status_reason,
    :cancel_at_period_end,
    :started_at,
    :current_period_start_at,
    :current_period_end_at,
    :next_renewal_at,
    :provider_customer_ref,
    :provider_billing_ref,
    :variant_id,
    :quantity,
    :renewal_amount_minor,
    :renewal_currency,
    :membership_key,
    :pending_variant_id,
    :pending_subscription_plan_id,
    :pending_renewal_amount_minor,
    :pending_renewal_currency,
    :change_effective_at,
    :dunning_attempt_count,
    :next_retry_at,
    :retry_suppressed_at,
    :stored_payment_method_id,
    :source_order_id,
    :source_order_line_item_id,
    :current_plan_revision_id
  ]

  test "Subscription activation is SYSTEM-only for valid pending rows" do
    actors = authorization_actors!("jc367_activate")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()

    for actor_context <- actors do
      fixture =
        create_subscription_fixture!(owner, variant, plan, %{status: :pending})

      before = reload_subscription!(fixture.subscription.id)
      assert before.status == :pending

      changeset = Ash.Changeset.for_update(before, :activate_now, %{})
      assert changeset.valid?

      result = update_subscription(changeset, actor_context)

      if actor_context.label == :system do
        assert {:ok, updated} = result
        assert updated.status == :active
        assert reload_subscription!(before.id).status == :active
      else
        assert {:error, %Ash.Error.Forbidden{}} = result

        assert subscription_snapshot(reload_subscription!(before.id)) ==
                 subscription_snapshot(before)
      end
    end
  end

  test "Subscription ACTIVE to PAST_DUE is SYSTEM-only for valid persisted rows" do
    actors = authorization_actors!("jc367_past_due")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()

    for actor_context <- actors do
      fixture = create_subscription_fixture!(owner, variant, plan)

      before = reload_subscription!(fixture.subscription.id)
      assert before.status == :active

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      changeset =
        Ash.Changeset.for_update(before, :mark_past_due_transition, %{
          billing_status_reason: "payment_failed",
          past_due_since_at: now,
          failed_payment_boundary_at: now,
          dunning_attempt_count: 1,
          next_retry_at: DateTime.add(now, 86_400, :second),
          retry_suppressed_at: nil
        })

      assert changeset.valid?
      result = update_subscription(changeset, actor_context)

      if actor_context.label == :system do
        assert {:ok, updated} = result
        assert updated.status == :past_due
        assert reload_subscription!(before.id).status == :past_due
      else
        assert {:error, %Ash.Error.Forbidden{}} = result

        assert subscription_snapshot(reload_subscription!(before.id)) ==
                 subscription_snapshot(before)
      end
    end
  end

  test "Subscription PAST_DUE to SUSPENDED is SYSTEM-only for valid persisted rows" do
    actors = authorization_actors!("jc367_suspended")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()

    for actor_context <- actors do
      fixture = create_subscription_fixture!(owner, variant, plan)
      active = reload_subscription!(fixture.subscription.id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, _past_due} =
               active
               |> Ash.Changeset.for_update(:mark_past_due_transition, %{
                 billing_status_reason: "payment_failed",
                 past_due_since_at: now,
                 failed_payment_boundary_at: now,
                 dunning_attempt_count: 1,
                 next_retry_at: DateTime.add(now, 86_400, :second)
               })
               |> update_subscription(Enum.find(actors, &(&1.label == :system)))

      before = reload_subscription!(active.id)
      assert before.status == :past_due

      changeset =
        Ash.Changeset.for_update(before, :mark_suspended_transition, %{
          billing_status_reason: before.billing_status_reason,
          past_due_since_at: before.past_due_since_at,
          dunning_attempt_count: before.dunning_attempt_count
        })

      assert changeset.valid?
      result = update_subscription(changeset, actor_context)

      if actor_context.label == :system do
        assert {:ok, updated} = result
        assert updated.status == :suspended
        assert is_nil(updated.next_retry_at)

        authoritative = reload_subscription!(before.id)
        assert authoritative.status == :suspended
        assert is_nil(authoritative.next_retry_at)
      else
        assert {:error, %Ash.Error.Forbidden{}} = result

        assert subscription_snapshot(reload_subscription!(before.id)) ==
                 subscription_snapshot(before)
      end
    end
  end

  test "Subscription period extension is SYSTEM-only for valid persisted rows" do
    assert_system_only_subscription_update!(
      "jc367_extend_period",
      :extend_period,
      fn _actor_context, before ->
        period_end = DateTime.add(before.current_period_end_at, 30 * 86_400, :second)

        %{
          current_period_end_at: period_end,
          next_renewal_at: period_end,
          renewal_amount_minor: before.renewal_amount_minor + 100
        }
      end,
      fn before, updated ->
        assert updated.status == :active

        assert DateTime.compare(updated.current_period_end_at, before.current_period_end_at) ==
                 :gt

        assert updated.next_renewal_at == updated.current_period_end_at
        assert updated.renewal_amount_minor == before.renewal_amount_minor + 100
      end
    )
  end

  test "Subscription expiration is SYSTEM-only for valid persisted rows" do
    assert_system_only_subscription_update!(
      "jc367_expire",
      :mark_expired_transition,
      fn _actor_context, _before -> %{canceled_reason: "term_end"} end,
      fn _before, updated ->
        assert updated.status == :expired
        assert updated.canceled_reason == "term_end"
        assert %DateTime{} = updated.ended_at
      end
    )
  end

  test "Subscription provider billing reference updates are SYSTEM-only" do
    assert_system_only_subscription_update!(
      "jc367_provider_reference",
      :set_provider_billing_reference,
      fn actor_context, _before ->
        suffix = "#{actor_context.label}_#{Ash.UUIDv7.generate()}"

        %{
          provider_customer_ref: "jc367_cus_#{suffix}",
          provider_billing_ref: "jc367_pm_#{suffix}"
        }
      end,
      fn before, updated ->
        assert updated.provider_customer_ref =~ "jc367_cus_system_"
        assert updated.provider_billing_ref =~ "jc367_pm_system_"

        assert updated.payment_method_setup_generation ==
                 before.payment_method_setup_generation + 1
      end
    )
  end

  test "Subscription contract change consumption is SYSTEM-only for a bound queued change" do
    actors = authorization_actors!("jc367_consume_contract_change")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()
    target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 2_599})
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    _revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    for actor_context <- actors do
      fixture = create_subscription_fixture!(owner, variant, plan)
      input = plan_change_input!(fixture.subscription.id, target_plan.id)

      assert {:ok, queued} =
               Facade.queue_subscription_plan_change_for_user(
                 owner,
                 fixture.subscription.id,
                 input
               )

      assert queued.current_contract_change_id
      assert queued.pending_subscription_plan_id == target_plan.id

      contract_change = reload_contract_change!(queued.current_contract_change_id)

      assert {:ok, bound_contract_change} =
               contract_change
               |> Ash.Changeset.for_update(:bind_to_renewal, %{}, context: @system_context)
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: @system_context
               )

      assert bound_contract_change.status == :bound_to_renewal

      before = reload_subscription!(queued.id)

      attrs = %{
        current_contract_change_id: nil,
        pending_variant_id: nil,
        pending_subscription_plan_id: nil,
        pending_renewal_amount_minor: nil,
        pending_renewal_currency: nil,
        change_effective_at: nil
      }

      changeset =
        Ash.Changeset.for_update(before, :consume_contract_change_for_renewal, attrs)

      assert changeset.valid?
      result = update_subscription(changeset, actor_context)

      if actor_context.label == :system do
        assert {:ok, updated} = result
        assert is_nil(updated.current_contract_change_id)
        assert is_nil(updated.pending_subscription_plan_id)
        assert is_nil(updated.pending_renewal_amount_minor)

        authoritative = reload_subscription!(before.id)
        assert is_nil(authoritative.current_contract_change_id)
        assert is_nil(authoritative.pending_subscription_plan_id)
      else
        assert {:error, %Ash.Error.Forbidden{}} = result

        assert subscription_snapshot(reload_subscription!(before.id)) ==
                 subscription_snapshot(before)
      end
    end
  end

  test "Subscription create_from_order_line rejects human actors and permits SYSTEM" do
    actors = authorization_actors!("jc367_subscription_create")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()

    base_fixture = create_subscription_fixture!(owner, variant, plan)

    for actor_context <- actors do
      %{order: order, line_item: line_item, revision: revision} =
        SubscriptionsFixtures.create_paid_order_with_subscription_line!(
          owner.id,
          variant,
          plan,
          %{create_payment_intent?: false}
        )

      attrs =
        base_fixture.subscription
        |> Map.from_struct()
        |> Map.take(@subscription_create_attributes)
        |> Map.merge(%{
          source_order_id: order.id,
          source_order_line_item_id: line_item.id,
          current_plan_revision_id: revision.id
        })

      changeset = Ash.Changeset.for_create(Subscription, :create_from_order_line, attrs)
      assert changeset.valid?

      result =
        Ash.create(changeset,
          domain: Store.Subscriptions,
          actor: actor_context.actor,
          context: actor_context.context
        )

      persisted = subscriptions_for_source_line(line_item.id)

      if actor_context.label == :system do
        assert {:ok, created} = result
        assert created.source_order_line_item_id == line_item.id
        assert [%Subscription{id: id}] = persisted
        assert id == created.id
      else
        assert {:error, %Ash.Error.Forbidden{}} = result
        assert persisted == []
      end
    end
  end

  test "RenewalAttempt create_or_reuse rejects human actors and permits SYSTEM" do
    actors = authorization_actors!("jc367_attempt_create")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()
    fixture = create_subscription_fixture!(owner, variant, plan)

    for actor_context <- actors do
      attrs = renewal_attempt_attributes(fixture.subscription, actor_context.label)
      changeset = Ash.Changeset.for_create(RenewalAttempt, :create_or_reuse, attrs)
      assert changeset.valid?

      result =
        Ash.create(changeset,
          domain: Store.Subscriptions,
          actor: actor_context.actor,
          context: actor_context.context
        )

      persisted = attempts_for_key(fixture.subscription.id, attrs.renewal_key)

      if actor_context.label == :system do
        assert {:ok, created} = result
        assert created.status == :pending
        assert [%RenewalAttempt{id: id}] = persisted
        assert id == created.id
      else
        assert {:error, %Ash.Error.Forbidden{}} = result
        assert persisted == []
      end
    end
  end

  test "RenewalAttempt PENDING to PROCESSING is SYSTEM-only for valid persisted rows" do
    actors = authorization_actors!("jc367_attempt_processing")
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()
    fixture = create_subscription_fixture!(owner, variant, plan)

    for actor_context <- actors do
      attrs = renewal_attempt_attributes(fixture.subscription, actor_context.label)
      attempt = create_system_attempt!(attrs)
      before = reload_attempt!(attempt.id)
      assert before.status == :pending

      changeset = Ash.Changeset.for_update(before, :mark_processing, %{})
      assert changeset.valid?

      result =
        Ash.update(changeset,
          domain: Store.Subscriptions,
          actor: actor_context.actor,
          context: actor_context.context
        )

      if actor_context.label == :system do
        assert {:ok, updated} = result
        assert updated.status == :processing
        assert reload_attempt!(before.id).status == :processing
      else
        assert {:error, %Ash.Error.Forbidden{}} = result

        assert renewal_attempt_snapshot(reload_attempt!(before.id)) ==
                 renewal_attempt_snapshot(before)
      end
    end
  end

  defp authorization_actors!(prefix) do
    owner = SubscriptionsFixtures.create_customer!("#{prefix}_owner")
    non_owner = SubscriptionsFixtures.create_customer!("#{prefix}_non_owner")

    role_contexts =
      Enum.map([:support, :editor, :admin, :super_admin], fn role ->
        actor = TestFixtures.register_user!(email: TestFixtures.unique_email("#{prefix}_#{role}"))
        _assignment = TestFixtures.assign_role!(actor, role)
        %{label: role, actor: actor, context: %{}}
      end)

    [
      %{label: :owner, actor: owner, context: %{}},
      %{label: :non_owner, actor: non_owner, context: %{}}
      | role_contexts
    ] ++
      [
        %{label: :system, actor: nil, context: @system_context},
        %{label: :anonymous, actor: nil, context: %{}}
      ]
  end

  defp owner!(actors), do: Enum.find(actors, &(&1.label == :owner)).actor

  defp assert_system_only_subscription_update!(prefix, action, attrs_fun, assert_success_fun) do
    actors = authorization_actors!(prefix)
    owner = owner!(actors)
    %{variant: variant, plan: plan} = subscription_catalog!()

    for actor_context <- actors do
      fixture = create_subscription_fixture!(owner, variant, plan)
      before = reload_subscription!(fixture.subscription.id)
      attrs = attrs_fun.(actor_context, before)
      changeset = Ash.Changeset.for_update(before, action, attrs)

      assert changeset.valid?
      result = update_subscription(changeset, actor_context)

      if actor_context.label == :system do
        assert {:ok, updated} = result
        assert_success_fun.(before, updated)
        assert_success_fun.(before, reload_subscription!(before.id))
      else
        assert {:error, %Ash.Error.Forbidden{}} = result

        assert subscription_snapshot(reload_subscription!(before.id)) ==
                 subscription_snapshot(before)
      end
    end
  end

  defp subscription_catalog! do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    %{variant: variant, plan: plan}
  end

  defp create_subscription_fixture!(owner, variant, plan, overrides \\ %{}),
    do: SubscriptionsFixtures.create_subscription_fixture!(owner.id, variant, plan, overrides)

  defp plan_change_input!(subscription_id, plan_id) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        subscription_id: subscription_id,
        subscription_plan_id: plan_id
      })

    input
  end

  defp renewal_attempt_attributes(subscription, prefix) do
    %{
      subscription_id: subscription.id,
      period_start_at: subscription.current_period_start_at,
      period_end_at: subscription.current_period_end_at,
      renewal_key: "jc367:#{prefix}:#{Ash.UUIDv7.generate()}",
      status: :pending
    }
  end

  defp create_system_attempt!(attrs) do
    changeset =
      Ash.Changeset.for_create(RenewalAttempt, :create_or_reuse, attrs, context: @system_context)

    assert changeset.valid?

    Ash.create!(changeset,
      domain: Store.Subscriptions,
      actor: nil,
      context: @system_context
    )
  end

  defp update_subscription(changeset, actor_context) do
    Ash.update(changeset,
      domain: Store.Subscriptions,
      actor: actor_context.actor,
      context: actor_context.context
    )
  end

  defp reload_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp subscriptions_for_source_line(source_order_line_item_id) do
    Subscription
    |> Ash.Query.filter(expr(source_order_line_item_id == ^source_order_line_item_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp reload_attempt!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp reload_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: @system_context
    )
  end

  defp attempts_for_key(subscription_id, renewal_key) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id and renewal_key == ^renewal_key))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp subscription_snapshot(subscription) do
    Map.take(subscription, [
      :status,
      :aggregate_version,
      :past_due_since_at,
      :failed_payment_boundary_at,
      :current_dunning_renewal_attempt_id,
      :billing_status_reason,
      :dunning_attempt_count,
      :next_retry_at,
      :retry_suppressed_at,
      :current_period_start_at,
      :current_period_end_at,
      :next_renewal_at,
      :renewal_amount_minor,
      :renewal_currency,
      :ended_at,
      :canceled_reason,
      :current_contract_change_id,
      :pending_variant_id,
      :pending_subscription_plan_id,
      :pending_renewal_amount_minor,
      :pending_renewal_currency,
      :change_effective_at,
      :provider_customer_ref,
      :provider_billing_ref,
      :payment_method_setup_generation
    ])
  end

  defp renewal_attempt_snapshot(attempt) do
    Map.take(attempt, [
      :status,
      :order_id,
      :payment_intent_id,
      :failure_code,
      :failure_message,
      :attempt_no
    ])
  end
end
