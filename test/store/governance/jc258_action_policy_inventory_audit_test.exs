defmodule Store.Governance.JC258ActionPolicyInventoryAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.AccessRepairDelivery
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.PlanRevision
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.RenewalCollectionAttempt
  alias Store.Subscriptions.StoredPaymentMethod
  alias Store.Subscriptions.Subscription
  alias Store.Subscriptions.SubscriptionItem
  alias Store.Subscriptions.SubscriptionPlan
  alias Store.Subscriptions.VariantSubscriptionPlan
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Normalize
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("policy inventory audit must not call Stripe")
    :ok
  end

  @user_facade_names [
    :list_subscriptions_for_user,
    :get_subscription_for_user,
    :get_subscription_detail_for_user,
    :cancel_subscription_for_user,
    :queue_subscription_plan_change_for_user,
    :queue_subscription_variant_change_for_user,
    :start_subscription_payment_method_update_for_user
  ]
  @admin_facade_names [
    :list_subscriptions_for_admin,
    :get_subscription_for_admin,
    :get_subscription_detail_for_admin,
    :cancel_subscription_for_admin,
    :queue_subscription_plan_change_for_admin,
    :queue_subscription_variant_change_for_admin,
    :start_subscription_payment_method_update_for_admin
  ]
  @system_facade_names [
    :list_subscription_access_inventory_window_for_system,
    :subscription_access_inventory_upper_bound_for_system,
    :establish_access_effect_for_system,
    :get_current_access_effect_for_system,
    :list_applied_access_verification_window_for_system,
    :verify_subscription_access_window_for_system,
    :validate_complete_bound_renewal_attempt_for_system,
    :mark_access_effect_pending_for_system,
    :mark_access_effect_applied_for_system,
    :mark_access_effect_failed_retryable_for_system,
    :retry_access_effect_for_system,
    :execute_effective_access_effect_for_system,
    :reconcile_subscription_access_for_system,
    :execute_suspension_access_effect_for_system,
    :repair_applied_access_effect_for_system,
    :repair_suspension_access_effect_projection_for_system,
    :run_subscription_access_effect_recovery_for_system,
    :run_access_effect_target_order_reconciliation_for_system,
    :list_variant_subscription_plan_options_for_system,
    :resolve_variant_subscription_plan_for_system,
    :ensure_membership_purchase_allowed_for_system,
    :order_has_subscription_lines_for_system,
    :order_is_subscription_only_for_system,
    :create_subscriptions_from_paid_order_for_system,
    :handle_payment_method_update_succeeded_for_system,
    :run_due_renewals_for_system,
    :run_due_failed_payment_suspensions_for_system,
    :run_due_scheduled_cancellations_for_system,
    :replay_scheduled_cancellation_notifications_for_system,
    :list_past_due_missing_failed_payment_boundary_for_system,
    :list_due_renewal_jobs_for_system,
    :list_due_renewal_job_page_for_system,
    :process_due_subscription_renewal_for_system,
    :reconcile_paid_subscription_renewal_for_system
  ]

  @resource_modules [
    AccessEffect,
    AccessRepairDelivery,
    ContractChange,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    StoredPaymentMethod,
    Subscription,
    SubscriptionItem,
    SubscriptionPlan,
    VariantSubscriptionPlan
  ]

  @expected_invalid_input_errors %{
    {AccessEffect, :establish} =>
      MapSet.new([Ash.Error.Changes.Required, Ash.Error.Changes.InvalidAttribute]),
    {ContractChange, :apply} => MapSet.new([Ash.Error.Changes.InvalidAttribute]),
    {ContractChange, :queue} => MapSet.new([Ash.Error.Changes.Required]),
    {PlanRevision, :create_draft} => MapSet.new([Ash.Error.Changes.Required]),
    {PlanRevision, :retire} => MapSet.new([Ash.Error.Changes.InvalidAttribute]),
    {RenewalAttempt, :create_or_reuse} => MapSet.new([Ash.Error.Changes.Required]),
    {RenewalCollectionAttempt, :create} => MapSet.new([Ash.Error.Changes.Required]),
    {StoredPaymentMethod, :create_or_reuse} => MapSet.new([Ash.Error.Changes.Required]),
    {Subscription, :create_from_order_line} =>
      MapSet.new([Ash.Error.Changes.Required, Ash.Error.Changes.InvalidAttribute]),
    {Subscription, :mark_suspended_transition} =>
      MapSet.new([Ash.Error.Changes.InvalidAttribute]),
    {SubscriptionItem, :create_from_order_line} => MapSet.new([Ash.Error.Changes.Required]),
    {SubscriptionPlan, :create} => MapSet.new([Ash.Error.Changes.Required]),
    {VariantSubscriptionPlan, :attach} => MapSet.new([Ash.Error.Changes.Required])
  }

  @staff_roles [:support, :admin, :super_admin]

  @action_policy %{
    {AccessEffect, :establish} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_applied} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_failed_retryable} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_pending_from_required} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_projection_delivered} => {:system_only, :needs_product_decision},
    {AccessEffect, :read} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_applied_verification_window_for_system} =>
      {:system_only_action, :needs_product_decision},
    {AccessEffect, :read_current_for_subscription} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_for_subscription_source_version} =>
      {:system_only, :needs_product_decision},
    {AccessEffect, :read_pending_projection_repair_for_system} =>
      {:system_only, :needs_product_decision},
    {AccessEffect, :read_recoverable_effective_for_system} =>
      {:system_only, :needs_product_decision},
    {AccessEffect, :read_recoverable_non_effective_for_system} =>
      {:system_only, :needs_product_decision},
    {AccessEffect, :read_target_order_candidates_for_system} =>
      {:system_only, :needs_product_decision},
    {AccessEffect, :retry_to_pending} => {:system_only, :needs_product_decision},
    {AccessEffect, :supersede} => {:system_only, :needs_product_decision},
    {AccessRepairDelivery, :acknowledge_for_system} => {:system_only, :needs_product_decision},
    {AccessRepairDelivery, :create_for_system} => {:system_only, :needs_product_decision},
    {AccessRepairDelivery, :read} => {:system_only, :needs_product_decision},
    {AccessRepairDelivery, :read_for_access_effect} => {:system_only, :needs_product_decision},
    {AccessRepairDelivery, :read_pending_for_system} =>
      {:system_only_action, :needs_product_decision},
    {AccessRepairDelivery, :request_for_system} => {:system_only, :needs_product_decision},
    {ContractChange, :apply} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :bind_to_renewal} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :cancel} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :queue} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :read} => {:staff_read, :needs_product_decision},
    {ContractChange, :read_for_subscription} => {:staff_read, :needs_product_decision},
    {ContractChange, :supersede} => {:admin_or_system_write, :needs_product_decision},
    {PlanRevision, :create_draft} => {:admin_write, :needs_product_decision},
    {PlanRevision, :get_effective_for_plan} => {:staff_read, :needs_product_decision},
    {PlanRevision, :publish} => {:admin_write, :needs_product_decision},
    {PlanRevision, :read} => {:staff_read, :needs_product_decision},
    {PlanRevision, :retire} => {:admin_write, :needs_product_decision},
    {PlanRevision, :update_draft} => {:admin_write, :needs_product_decision},
    {RenewalAttempt, :create_or_reuse} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_authority_withdrawn} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_failed} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_processing} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_succeeded} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :read} => {:staff_read, :matrix},
    {RenewalAttempt, :read_for_admin} => {:staff_read, :matrix},
    {RenewalAttempt, :read_for_subscription} => {:staff_read, :matrix},
    {RenewalCollectionAttempt, :assign_reservation_generation} =>
      {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :attach_and_claim_dispatch} =>
      {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :attach_payment_intent} =>
      {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :claim_dispatch} =>
      {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :create} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :fence_before_submission} =>
      {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :read} => {:staff_read, :needs_product_decision},
    {RenewalCollectionAttempt, :read_for_renewal_attempt} =>
      {:staff_read, :needs_product_decision},
    {RenewalCollectionAttempt, :record_financial_outcome} =>
      {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :resume_after_fence} =>
      {:admin_or_system_write, :needs_product_decision},
    {StoredPaymentMethod, :create_or_reuse} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :get_for_system} => {:owner_or_staff_read, :needs_product_decision},
    {StoredPaymentMethod, :mark_active} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :mark_inactive} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :mark_revoked} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :read} => {:owner_or_staff_read, :needs_product_decision},
    {Subscription, :activate_now} => {:admin_or_system_write, :system_row_gap},
    {Subscription, :advance_payment_method_setup_generation} =>
      {:system_only, :needs_product_decision},
    {Subscription, :cancel_at_period_end_transition} => {:self_or_admin_write, :matrix},
    {Subscription, :cancel_now_transition} => {:self_or_admin_write, :matrix},
    {Subscription, :consume_contract_change_for_renewal} =>
      {:admin_or_system_write, :needs_product_decision},
    {Subscription, :create_from_order_line} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :extend_period} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :get_for_admin} => {:staff_read, :matrix},
    {Subscription, :get_for_user} => {:self_read, :matrix},
    {Subscription, :mark_expired_transition} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :mark_past_due_transition} => {:admin_or_system_write, :system_row_gap},
    {Subscription, :mark_suspended_transition} =>
      {:admin_or_system_write, :needs_product_decision},
    {Subscription, :queue_change} => {:self_or_admin_write, :needs_product_decision},
    {Subscription, :read} => {:staff_read, :matrix},
    {Subscription, :read_access_inventory_window_for_system} =>
      {:system_only, :needs_product_decision},
    {Subscription, :read_due_failed_payment_boundary_for_system} => {:staff_read, :matrix},
    {Subscription, :read_due_for_system} => {:staff_read, :matrix},
    {Subscription, :read_due_scheduled_cancellations_for_system} => {:staff_read, :matrix},
    {Subscription, :read_for_admin} => {:staff_read, :matrix},
    {Subscription, :read_for_user} => {:self_read, :matrix},
    {Subscription, :read_past_due_missing_boundary_for_system} => {:staff_read, :matrix},
    {Subscription, :rescind_cancel_at_period_end_transition} =>
      {:self_or_admin_write, :needs_product_decision},
    {Subscription, :scheduled_boundary_cancellation_transition} =>
      {:self_or_admin_write, :needs_product_decision},
    {Subscription, :set_provider_billing_reference} =>
      {:admin_or_system_write, :needs_product_decision},
    {SubscriptionItem, :create_from_order_line} => {:admin_write, :needs_product_decision},
    {SubscriptionItem, :read} => {:staff_read, :needs_product_decision},
    {SubscriptionItem, :read_for_subscription} => {:staff_read, :needs_product_decision},
    {SubscriptionPlan, :activate} => {:admin_write, :matrix},
    {SubscriptionPlan, :archive} => {:admin_write, :matrix},
    {SubscriptionPlan, :create} => {:admin_write, :matrix},
    {SubscriptionPlan, :get_by_key_for_system} => {:staff_read, :needs_product_decision},
    {SubscriptionPlan, :get_for_admin} => {:staff_read, :matrix},
    {SubscriptionPlan, :read} => {:staff_read, :matrix},
    {SubscriptionPlan, :read_for_admin} => {:staff_read, :matrix},
    {SubscriptionPlan, :read_for_public} => {:public_read, :matrix_discrepancy},
    {SubscriptionPlan, :update} => {:admin_write, :matrix},
    {VariantSubscriptionPlan, :attach} => {:admin_write, :needs_product_decision},
    {VariantSubscriptionPlan, :read} => {:staff_read, :needs_product_decision},
    {VariantSubscriptionPlan, :read_active_for_variant} => {:staff_read, :needs_product_decision},
    {VariantSubscriptionPlan, :read_for_admin} => {:staff_read, :needs_product_decision},
    {VariantSubscriptionPlan, :set_active} => {:admin_write, :needs_product_decision}
  }

  test "inventory covers every compiled action" do
    compiled =
      Subscriptions
      |> Ash.Domain.Info.resources()
      |> Enum.flat_map(fn resource ->
        Enum.map(Ash.Resource.Info.actions(resource), &{resource, &1.name})
      end)
      |> Enum.sort()

    assert compiled == @action_policy |> Map.keys() |> Enum.sort()
    assert length(compiled) == 99
    resources = @action_policy |> Map.keys() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert resources == MapSet.new(@resource_modules)
  end

  test "facade names have explicit consumer categories" do
    functions = SubscriptionsFacade.__info__(:functions)
    names = functions |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    expected = MapSet.new(@user_facade_names ++ @admin_facade_names ++ @system_facade_names)

    assert length(@user_facade_names) == 7
    assert length(@admin_facade_names) == 7
    assert length(@system_facade_names) == 34
    assert MapSet.size(expected) == 48
    assert names == expected

    expected_arities = %{
      list_subscriptions_for_user: [2],
      get_subscription_for_user: [2],
      get_subscription_detail_for_user: [2],
      cancel_subscription_for_user: [2, 3],
      queue_subscription_plan_change_for_user: [3],
      queue_subscription_variant_change_for_user: [3],
      start_subscription_payment_method_update_for_user: [3],
      list_subscriptions_for_admin: [2],
      get_subscription_for_admin: [2],
      get_subscription_detail_for_admin: [2],
      cancel_subscription_for_admin: [2, 3],
      queue_subscription_plan_change_for_admin: [3],
      queue_subscription_variant_change_for_admin: [3],
      start_subscription_payment_method_update_for_admin: [3],
      list_subscription_access_inventory_window_for_system: [1],
      subscription_access_inventory_upper_bound_for_system: [0],
      establish_access_effect_for_system: [1],
      get_current_access_effect_for_system: [1],
      list_applied_access_verification_window_for_system: [1],
      verify_subscription_access_window_for_system: [1],
      validate_complete_bound_renewal_attempt_for_system: [1],
      mark_access_effect_pending_for_system: [1],
      mark_access_effect_applied_for_system: [1],
      mark_access_effect_failed_retryable_for_system: [1],
      retry_access_effect_for_system: [1],
      execute_effective_access_effect_for_system: [1],
      reconcile_subscription_access_for_system: [1],
      execute_suspension_access_effect_for_system: [1],
      repair_applied_access_effect_for_system: [1],
      repair_suspension_access_effect_projection_for_system: [1],
      run_subscription_access_effect_recovery_for_system: [0, 1],
      run_access_effect_target_order_reconciliation_for_system: [0, 1],
      list_variant_subscription_plan_options_for_system: [1, 2],
      resolve_variant_subscription_plan_for_system: [1, 2],
      ensure_membership_purchase_allowed_for_system: [2],
      order_has_subscription_lines_for_system: [1],
      order_is_subscription_only_for_system: [1],
      create_subscriptions_from_paid_order_for_system: [1],
      handle_payment_method_update_succeeded_for_system: [1],
      run_due_renewals_for_system: [0, 1],
      run_due_failed_payment_suspensions_for_system: [0, 1],
      run_due_scheduled_cancellations_for_system: [0, 1],
      replay_scheduled_cancellation_notifications_for_system: [0, 1],
      list_past_due_missing_failed_payment_boundary_for_system: [0, 1],
      list_due_renewal_jobs_for_system: [0, 1],
      list_due_renewal_job_page_for_system: [0, 1],
      process_due_subscription_renewal_for_system: [1, 2],
      reconcile_paid_subscription_renewal_for_system: [1, 2]
    }

    expected_functions =
      for {name, arities} <- expected_arities, arity <- arities, do: {name, arity}

    assert length(expected_functions) == 63
    assert Enum.sort(functions) == Enum.sort(expected_functions)
  end

  test "public plan query filters archived plans for all actor contexts" do
    active_plan = SubscriptionsFixtures.create_subscription_plan!(%{status: :active})
    archived_plan = SubscriptionsFixtures.create_subscription_plan!(%{status: :archived})
    ids = [active_plan.id, archived_plan.id]

    owner = SubscriptionsFixtures.create_customer!("jc258_public_owner")
    non_owner = SubscriptionsFixtures.create_customer!("jc258_public_non_owner")

    for {_name, actor, context} <- actor_contexts!(%{owner: owner, non_owner: non_owner}) do
      query =
        SubscriptionPlan
        |> Ash.Query.for_read(:read_for_public, %{}, actor: actor, context: context)
        |> Ash.Query.filter(expr(id in ^ids))

      assert query.valid?
      assert {:ok, rows} = Ash.read(query, domain: Subscriptions, actor: actor, context: context)
      assert Enum.map(rows, & &1.id) == [active_plan.id]
    end
  end

  test "preflights every action for all eight actor contexts" do
    fixtures = fixtures!()
    contexts = actor_contexts!(fixtures)

    for {{resource, action}, {group, authority}} <- @action_policy,
        {context_name, actor, context} <- contexts do
      args = arguments!(resource, action, fixtures)
      validity = input_validity(resource, action, args, actor, context, fixtures)
      assert_input_validity!(validity, resource, action, context_name)
      subject = preflight_subject(resource, action, args, fixtures)
      current_policy_preflight = Ash.can(subject, actor, validate?: false, context: context)
      assert_current_preflight!(current_policy_preflight, group, authority, action, context_name)
    end
  end

  test "repair delivery actions reject non-system actors before SQL and accept system execution" do
    fixtures = fixtures!()
    delivery = fixtures.access_repair_delivery
    contexts = Enum.reject(actor_contexts!(fixtures), fn {name, _, _} -> name == :system end)

    for {_name, actor, context} <- contexts do
      {result, stats} =
        RepoStats.capture(fn ->
          denied_delivery_actions(fixtures, delivery, actor, context)
        end)

      assert result == :ok
      assert stats.query_count == 0
    end

    assert {:ok, rows} =
             AccessRepairDelivery
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(expr(id == ^delivery.id))
             |> Ash.read(domain: Subscriptions, authorize?: true, context: %{system?: true})

    assert Enum.map(rows, & &1.id) == [delivery.id]

    assert {:ok, [^delivery]} =
             AccessRepairDelivery
             |> Ash.Query.for_read(:read_for_access_effect, %{
               access_effect_id: fixtures.access_effect.id
             })
             |> Ash.read(domain: Subscriptions, authorize?: true, context: %{system?: true})

    pending_input =
      Ash.ActionInput.for_action(AccessRepairDelivery, :read_pending_for_system, %{
        as_of: DateTime.add(DateTime.utc_now(), 1, :second),
        limit: 10
      })

    assert {:ok, pending} =
             Ash.run_action(pending_input,
               domain: Subscriptions,
               authorize?: true,
               context: %{system?: true}
             )

    assert Enum.any?(pending, &(&1.id == delivery.id))

    assert {:ok, requested} =
             delivery
             |> Ash.Changeset.for_update(:request_for_system, %{
               recipient_user_ids: delivery.recipient_user_ids,
               generation: 2
             })
             |> Ash.update(domain: Subscriptions, authorize?: true, context: %{system?: true})

    assert requested.generation == 2

    assert {:ok, acknowledged} =
             requested
             |> Ash.Changeset.for_update(:acknowledge_for_system, %{
               generation: 2,
               recipient_user_ids: requested.recipient_user_ids,
               delivered_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })
             |> Ash.update(domain: Subscriptions, authorize?: true, context: %{system?: true})

    assert acknowledged.delivered_generation == 2
  end

  test "user reads preflight and execute against the persisted Subscription row" do
    fixture = fixtures!()
    contexts = actor_contexts!(fixture)

    for action <- [:read_for_user, :get_for_user],
        {name, actor, context} <- contexts do
      args = if action == :get_for_user, do: %{id: fixture.subscription.id}, else: %{}

      query =
        Subscription
        |> Ash.Query.for_read(action, args, actor: actor, context: context)
        |> Ash.Query.filter(expr(id == ^fixture.subscription.id))

      if name in [:anonymous, :system] do
        assert query.valid? == false
        assert Enum.any?(query.errors, &match?(%Ash.Error.Query.ReadActionRequiresActor{}, &1))
      else
        assert query.valid?

        policy =
          Ash.can({fixture.subscription, action, args}, actor, validate?: false, context: context)

        assert policy == {:ok, name == :owner_customer}

        case Ash.read(query, domain: Subscriptions, actor: actor, context: context) do
          {:ok, [subscription]} when name == :owner_customer ->
            assert subscription.id == fixture.subscription.id

          {:ok, []} when name != :owner_customer ->
            :ok

          other ->
            flunk(
              "#{inspect(action)} #{name} expected owner row or empty filtered result, got #{inspect(other)}"
            )
        end
      end
    end
  end

  test "default and get_for_system reads use the persisted method id" do
    fixture = fixtures!()
    method = stored_method!(fixture)
    contexts = actor_contexts!(fixture)

    for action <- [:read, :get_for_system],
        {name, actor, context} <- contexts do
      args = if action == :get_for_system, do: %{id: method.id}, else: %{}

      query =
        Ash.Query.for_read(StoredPaymentMethod, action, args, actor: actor, context: context)

      query = Ash.Query.filter(query, expr(id == ^method.id))
      assert query.valid?
      result = Ash.read(query, domain: Subscriptions, actor: actor, context: context)
      assert_direct_method_result!(result, action, name, method)
    end
  end

  defp fixtures! do
    owner = SubscriptionsFixtures.create_customer!("jc258_matrix_owner")
    non_owner = SubscriptionsFixtures.create_customer!("jc258_matrix_non_owner")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc258_matrix:#{Ash.UUIDv7.generate()}"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    subscription_fixture =
      SubscriptionsFixtures.create_subscription_fixture!(owner.id, variant, plan, %{
        provider_customer_ref: "cus_jc258_matrix_#{System.unique_integer([:positive])}",
        provider_billing_ref: "pm_jc258_matrix_#{System.unique_integer([:positive])}",
        create_payment_intent?: true
      })

    subscription = subscription_fixture.subscription
    attempt = create_pending_attempt!(subscription)
    payment_intent = payment_intent_for_order!(subscription_fixture.order.id)
    stored_method = stored_method!(%{subscription: subscription})
    access_effect = access_effect!(subscription, subscription_fixture)
    access_repair_delivery = access_repair_delivery!(access_effect, owner.id)

    %{
      owner: owner,
      non_owner: non_owner,
      variant: variant,
      plan: plan,
      subscription: subscription,
      item: subscription_fixture.item,
      order: subscription_fixture.order,
      line_item: subscription_fixture.line_item,
      revision: subscription_fixture.revision,
      renewal_attempt: attempt,
      payment_intent: payment_intent,
      stored_method: stored_method,
      access_effect: access_effect,
      access_repair_delivery: access_repair_delivery
    }
  end

  defp actor_contexts!(fixtures) do
    roles = Map.new(@staff_roles ++ [:editor], fn role -> {role, role_actor!(role)} end)

    [
      {:owner_customer, fixtures.owner, %{}},
      {:non_owner_customer, fixtures.non_owner, %{}},
      {:support, roles.support, %{}},
      {:editor, roles.editor, %{}},
      {:admin, roles.admin, %{}},
      {:super_admin, roles.super_admin, %{}},
      {:anonymous, nil, %{}},
      {:system, nil, %{system?: true}}
    ]
  end

  defp role_actor!(role) do
    actor = TestFixtures.register_user!(email: TestFixtures.unique_email("jc258_#{role}"))
    _assignment = TestFixtures.assign_role!(actor, role)
    actor
  end

  defp stored_method!(%{subscription: subscription}) do
    query =
      Ash.Query.filter(StoredPaymentMethod, expr(id == ^subscription.stored_payment_method_id))

    Ash.read_one!(query, domain: Subscriptions, authorize?: false)
  end

  defp arguments!(resource, action, fixtures) do
    info = Ash.Resource.Info.action(resource, action)

    arguments =
      Map.new(info.arguments, fn argument ->
        {argument.name, argument_value(argument.name, resource, fixtures)}
      end)

    case {resource, action} do
      {AccessRepairDelivery, :create_for_system} ->
        Map.merge(arguments, %{
          access_effect_id: fixtures.access_effect.id,
          recipient_user_ids: [fixtures.owner.id],
          generation: 1,
          delivered_generation: 0
        })

      {AccessRepairDelivery, :request_for_system} ->
        Map.merge(arguments, %{recipient_user_ids: [fixtures.owner.id], generation: 2})

      _ ->
        arguments
    end
  end

  defp argument_value(:id, StoredPaymentMethod, %{subscription: s}),
    do: s.stored_payment_method_id

  defp argument_value(:id, Subscription, %{subscription: s}), do: s.id
  defp argument_value(:id, AccessRepairDelivery, %{access_repair_delivery: d}), do: d.id
  defp argument_value(:access_effect_id, AccessRepairDelivery, %{access_effect: e}), do: e.id
  defp argument_value(:recipient_user_ids, AccessRepairDelivery, %{owner: owner}), do: [owner.id]
  defp argument_value(:generation, AccessRepairDelivery, _fixtures), do: 1
  defp argument_value(:delivered_at, AccessRepairDelivery, _fixtures), do: now()
  defp argument_value(:id, SubscriptionPlan, %{plan: p}), do: p.id
  defp argument_value(:subscription_id, _resource, %{subscription: s}), do: s.id
  defp argument_value(:subscription_plan_id, _resource, %{plan: p}), do: p.id
  defp argument_value(:variant_id, _resource, %{variant: v}), do: v.id
  defp argument_value(:renewal_attempt_id, _resource, %{renewal_attempt: r}), do: r.id
  defp argument_value(:payment_intent_id, _resource, %{payment_intent: p}), do: p.id
  defp argument_value(:through_id, _resource, %{subscription: s}), do: s.id
  defp argument_value(:dunning_renewal_attempt_id, _resource, _fixtures), do: nil
  defp argument_value(:recovery_renewal_attempt_id, _resource, _fixtures), do: nil
  defp argument_value(:after_id, _resource, _fixtures), do: nil
  defp argument_value(:after_inserted_at, _resource, _fixtures), do: nil
  defp argument_value(:after_updated_at, _resource, _fixtures), do: nil
  defp argument_value(:after_boundary_at, _resource, _fixtures), do: nil
  defp argument_value(:after_renewal_at, _resource, _fixtures), do: nil
  defp argument_value(:as_of, _resource, _fixtures), do: now()
  defp argument_value(:now, _resource, _fixtures), do: now()
  defp argument_value(:through_inserted_at, _resource, _fixtures), do: now()
  defp argument_value(:through_updated_at, _resource, _fixtures), do: now()
  defp argument_value(:limit, _resource, _fixtures), do: 10
  defp argument_value(:source_version, _resource, _fixtures), do: 1
  defp argument_value(:expected_epoch, _resource, _fixtures), do: 1
  defp argument_value(:key, _resource, %{plan: p}), do: p.key

  defp argument_value(name, _resource, _fixtures),
    do: raise("unmapped required argument #{inspect(name)}")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp create_pending_attempt!(subscription) do
    attrs = %{
      subscription_id: subscription.id,
      period_start_at: subscription.current_period_start_at,
      period_end_at: subscription.current_period_end_at,
      renewal_key: "jc258_matrix_#{Ash.UUIDv7.generate()}"
    }

    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create!(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp payment_intent_for_order!(order_id) do
    query = Ash.Query.filter(PaymentIntent, expr(order_id == ^order_id))
    Ash.read_one!(query, domain: Store.Payments, authorize?: false)
  end

  defp preflight_subject(resource, action, args, fixtures) do
    case specific_preflight_record(resource, action, fixtures) do
      {:subject, record} ->
        {record, action, args}

      :default ->
        generic_preflight_subject(resource, action, args)
    end
  end

  defp specific_preflight_record(Subscription, action, %{subscription: subscription})
       when action in [:read_for_user, :get_for_user],
       do: {:subject, subscription}

  defp specific_preflight_record(Subscription, action, %{subscription: subscription}),
    do: update_preflight_record(Subscription, action, subscription)

  defp specific_preflight_record(StoredPaymentMethod, :read, %{stored_method: method}),
    do: {:subject, method}

  defp specific_preflight_record(StoredPaymentMethod, :get_for_system, _fixtures),
    do: {:subject, StoredPaymentMethod}

  defp specific_preflight_record(StoredPaymentMethod, action, %{stored_method: method}),
    do: update_preflight_record(StoredPaymentMethod, action, method)

  defp specific_preflight_record(AccessRepairDelivery, action, %{access_repair_delivery: delivery}),
       do: update_preflight_record(AccessRepairDelivery, action, delivery)

  defp specific_preflight_record(_resource, _action, _fixtures), do: :default

  defp update_preflight_record(resource, action, record) do
    if Ash.Resource.Info.action(resource, action).type == :update,
      do: {:subject, record},
      else: :default
  end

  defp generic_preflight_subject(resource, action, args) do
    case Ash.Resource.Info.action(resource, action).type do
      type when type in [:update, :destroy] -> {struct(resource), action, args}
      _type -> {resource, action, args}
    end
  end

  defp input_validity(resource, action, args, actor, context, fixtures) do
    action_info = Ash.Resource.Info.action(resource, action)

    subject =
      case action_info.type do
        :read ->
          Ash.Query.for_read(resource, action, args, actor: actor, context: context)

        :create ->
          Ash.Changeset.for_create(resource, action, args, actor: actor, context: context)

        :update ->
          Ash.Changeset.for_update(update_record(resource, fixtures), action, args,
            actor: actor,
            context: context
          )

        :action ->
          Ash.ActionInput.for_action(resource, action, args, actor: actor, context: context)

        :destroy ->
          Ash.Changeset.for_destroy(struct(resource), action, args,
            actor: actor,
            context: context
          )
      end

    %{valid?: subject.valid?, error_classes: error_classes(Map.get(subject, :errors, []))}
  end

  defp update_record(Subscription, fixtures), do: fixtures.subscription
  defp update_record(StoredPaymentMethod, fixtures), do: fixtures.stored_method
  defp update_record(AccessRepairDelivery, fixtures), do: fixtures.access_repair_delivery
  defp update_record(resource, _fixtures), do: struct(resource)

  defp access_effect!(subscription, fixture) do
    attrs = %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: :effective,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id,
      entitlement_kind: fixture.revision.entitlement_kind,
      entitlement_scope_key: fixture.revision.entitlement_scope_key,
      valid_from_at: subscription.current_period_start_at,
      valid_until_at: subscription.current_period_end_at
    }

    {:ok, input} = EstablishAccessEffectInput.new(attrs)

    SubscriptionsFacade.establish_access_effect_for_system(input)
    |> case do
      {:ok, effect} -> effect
      other -> flunk("expected a valid access effect, got #{inspect(other)}")
    end
  end

  defp access_repair_delivery!(effect, user_id) do
    AccessRepairDelivery
    |> Ash.Changeset.for_create(
      :create_for_system,
      %{
        access_effect_id: effect.id,
        recipient_user_ids: [user_id],
        generation: 1,
        delivered_generation: 0
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Subscriptions, authorize?: true, context: %{system?: true})
  end

  defp denied_delivery_actions(fixtures, delivery, actor, context) do
    effect = fixtures.access_effect
    user_ids = delivery.recipient_user_ids

    requests = [
      {:read, nil},
      {:read_for_access_effect, %{access_effect_id: effect.id}},
      {:create_for_system,
       %{
         access_effect_id: effect.id,
         recipient_user_ids: user_ids,
         generation: 2,
         delivered_generation: 0
       }},
      {:request_for_system, %{recipient_user_ids: user_ids, generation: 2}},
      {:acknowledge_for_system,
       %{generation: 1, recipient_user_ids: user_ids, delivered_at: now()}},
      {:read_pending_for_system, %{as_of: now(), limit: 10}}
    ]

    for {action, args} <- requests do
      result =
        case action do
          :read ->
            Ash.Query.for_read(AccessRepairDelivery, action)
            |> Ash.read(domain: Subscriptions, authorize?: true, actor: actor, context: context)

          :read_for_access_effect ->
            Ash.Query.for_read(AccessRepairDelivery, action, args)
            |> Ash.read(domain: Subscriptions, authorize?: true, actor: actor, context: context)

          :create_for_system ->
            AccessRepairDelivery
            |> Ash.Changeset.for_create(action, args, actor: actor, context: context)
            |> Ash.create(domain: Subscriptions, authorize?: true, actor: actor, context: context)

          action when action in [:request_for_system, :acknowledge_for_system] ->
            delivery
            |> Ash.Changeset.for_update(action, args, actor: actor, context: context)
            |> Ash.update(domain: Subscriptions, authorize?: true, actor: actor, context: context)

          :read_pending_for_system ->
            Ash.ActionInput.for_action(AccessRepairDelivery, action, args,
              actor: actor,
              context: context
            )
            |> Ash.run_action(
              domain: Subscriptions,
              authorize?: true,
              actor: actor,
              context: context
            )
        end

      assert {:error, reason} = result
      assert %Store.Support.Errors.Error{code: "FORBIDDEN"} = Normalize.normalize(reason)
    end

    :ok
  end

  defp error_classes(errors) do
    errors
    |> Enum.map(fn
      %{__struct__: module} -> module
      _ -> :non_struct_error
    end)
    |> MapSet.new()
  end

  defp assert_input_validity!(
         %{valid?: false, error_classes: errors},
         resource,
         action,
         context_name
       ) do
    key = {resource, action}

    if action in [:read_for_user, :get_for_user] and context_name in [:anonymous, :system] do
      assert errors == MapSet.new([Ash.Error.Query.ReadActionRequiresActor]),
             "#{inspect(key)} #{context_name} actor contract had #{inspect(errors)}"
    else
      assert Map.fetch!(@expected_invalid_input_errors, key) == errors,
             "#{inspect(key)} #{context_name} invalid input classes changed to #{inspect(errors)}"
    end
  end

  defp assert_input_validity!(%{valid?: true}, resource, action, _context_name) do
    refute Map.has_key?(@expected_invalid_input_errors, {resource, action}),
           "#{inspect({resource, action})} became valid; review and update the explicit validity contract"
  end

  defp assert_current_preflight!(result, group, authority, action, context_name) do
    expected = expected_result(group, context_name)

    if group == :self_read and context_name in [:anonymous, :system] do
      assert match?({:error, %Ash.Error.Invalid{}}, result),
             "#{inspect(action)} #{context_name} #{authority} CURRENT_POLICY_PREFLIGHT expected actor-required error, got #{inspect(result)}"

      assert nested_error?(elem(result, 1), Ash.Error.Query.ReadActionRequiresActor),
             "#{inspect(action)} #{context_name} #{authority} CURRENT_POLICY_PREFLIGHT lacked nested ReadActionRequiresActor, got #{inspect(result)}"
    else
      assert result == expected,
             "#{inspect(action)} #{context_name} #{authority} CURRENT_POLICY_PREFLIGHT expected #{inspect(expected)}, got #{inspect(result)}"
    end
  end

  defp nested_error?(%{__struct__: module}, module), do: true

  defp nested_error?(%{errors: errors}, expected),
    do: Enum.any?(errors, &nested_error?(&1, expected))

  defp nested_error?(_error, _expected), do: false

  defp expected_result(:public_read, _), do: {:ok, true}

  defp expected_result(:staff_read, name),
    do: {:ok, name in [:support, :admin, :super_admin, :system]}

  defp expected_result(:admin_write, name), do: {:ok, name in [:admin, :super_admin, :system]}

  defp expected_result(:admin_or_system_write, name),
    do: {:ok, name in [:admin, :super_admin, :system]}

  defp expected_result(:self_or_admin_write, name),
    do: {:ok, name in [:owner_customer, :admin, :super_admin, :system]}

  defp expected_result(:system_only, name), do: {:ok, name == :system}
  defp expected_result(:system_only_action, name), do: {:ok, name == :system}
  defp expected_result(:self_read, :owner_customer), do: {:ok, true}
  defp expected_result(:self_read, _), do: {:ok, false}

  defp expected_result(:owner_or_staff_read, name)
       when name in [:owner_customer, :non_owner_customer, :editor], do: {:ok, :maybe}

  defp expected_result(:owner_or_staff_read, name),
    do: {:ok, name in [:support, :admin, :super_admin, :system]}

  defp assert_direct_method_result!(
         {:error, %Ash.Error.Forbidden{}},
         _action,
         :anonymous,
         _method
       ),
       do: :ok

  defp assert_direct_method_result!({:ok, rows}, _action, name, method)
       when is_list(rows) and name != :anonymous do
    expected_count =
      if name in [:owner_customer, :support, :admin, :super_admin, :system], do: 1, else: 0

    assert length(rows) == expected_count
    if expected_count == 1, do: assert(hd(rows).id == method.id)
  end

  defp assert_direct_method_result!(other, action, name, _method),
    do: flunk("#{inspect(action)} #{name} unexpected direct read result: #{inspect(other)}")
end
