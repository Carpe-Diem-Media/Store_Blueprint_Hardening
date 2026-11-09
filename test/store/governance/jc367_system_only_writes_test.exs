defmodule Store.Governance.JC367SystemOnlyWritesTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Subscription
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

  defp subscription_catalog! do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    %{variant: variant, plan: plan}
  end

  defp create_subscription_fixture!(owner, variant, plan, overrides \\ %{}),
    do: SubscriptionsFixtures.create_subscription_fixture!(owner.id, variant, plan, overrides)

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
      :retry_suppressed_at
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
