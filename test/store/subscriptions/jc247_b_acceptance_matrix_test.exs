defmodule Store.Subscriptions.Jc247BAcceptanceMatrixTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.Order
  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, ContractChange, Facade, RenewalAttempt, Subscription}
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.RenewalCollectionAttempt
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  @barrier_timeout 10_000
  @cursor_floor "00000000-0000-7000-8000-000000000000"

  setup context do
    StripeAPIStub.setup_default(context)
    {:ok, context: context}
  end

  test "payment failure carries the exact NON_EFFECTIVE effect through postcommit dispatch", %{
    context: context
  } do
    fixture = create_due_fixture!("jc247_b_exact_id")
    issue_source_grant!(fixture)
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    task = start_failure_task(context, fixture)

    assert_receive {:jc247_b_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    subscription = fetch_subscription!(subscription_id)
    attempt = fetch_attempt!(subscription_id)
    [effect] = access_effects!(subscription_id)

    assert is_nil(Task.yield(task, 0))
    assert subscription.status == :past_due
    assert subscription.current_dunning_renewal_attempt_id == attempt.id
    assert attempt.subscription_id == subscription.id
    assert attempt.period_start_at == subscription.current_period_end_at
    assert attempt.charged_contract_snapshot["access_on_past_due"] == "remove_immediately"
    assert effect.disposition == :non_effective
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == nil
    assert effect.plan_revision_id == subscription.current_plan_revision_id
    assert effect.contract_change_id == subscription.current_contract_change_id
    assert effect.status == :required
    assert [%EntitlementGrant{status: :active}] = grants_for_source!(subscription.id)

    send(task.pid, {:jc247_b_release_postcommit, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(task, @barrier_timeout)

    assert fetch_effect!(effect.id).status == :applied

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "past_due_remove_immediately"}] =
             grants_for_source!(subscription.id)
  end

  test "same-episode payment retry retains its pointer, snapshot, boundary, and one policy effect" do
    fixture = create_due_fixture!("jc247_b_failure_replay")
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    before_subscription = fetch_subscription!(fixture.subscription.id)
    before_attempt = fetch_attempt!(fixture.subscription.id)
    [first_effect] = access_effects!(fixture.subscription.id)

    before_collection = latest_collection_for_attempt!(before_attempt.id)
    StripeAPIStub.stub_unexpected!("retry preparation must not submit a renewal charge")

    retry =
      ReachedRenewalFixtures.prepare_reached!(
        fixture.subscription.id,
        before_subscription.next_retry_at
      )

    assert retry.attempt.id == before_attempt.id
    assert retry.order.id == before_attempt.order_id
    refute retry.collection.id == before_collection.id
    refute retry.payment_intent.id == before_collection.payment_intent_id
    assert retry.collection.renewal_attempt_id == before_attempt.id
    assert retry.attempt.order_id == before_attempt.order_id
    assert retry.payment_intent.id == retry.collection.payment_intent_id

    assert retry.payment_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(retry.collection.id)

    StripeAPIStub.stub_payment_observation(
      retry.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(retry, "canceled")
    )

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: before_subscription.next_retry_at
             )

    after_subscription = fetch_subscription!(fixture.subscription.id)
    after_attempt = fetch_attempt!(fixture.subscription.id)

    assert after_subscription.current_dunning_renewal_attempt_id == before_attempt.id

    assert after_subscription.failed_payment_boundary_at ==
             before_subscription.failed_payment_boundary_at

    assert after_attempt.charged_contract_snapshot == before_attempt.charged_contract_snapshot
    assert [^first_effect] = access_effects!(fixture.subscription.id)
  end

  test "authentication-required replay retains the same B effect and episode" do
    fixture = create_due_fixture!("jc247_b_auth_replay")
    StripeAPIStub.stub_unexpected!("legacy preparation must not contact Stripe")
    reached = ReachedRenewalFixtures.prepare_reached!(fixture.subscription.id, fixture.now)

    observation =
      ReachedRenewalFixtures.observation_body(reached, "requires_action", %{
        "next_action" => %{
          "redirect_to_url" => %{"url" => "https://payments.example.test/jc247-b-auth"}
        }
      })

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      observation
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: fixture.now
             )

    before_subscription = fetch_subscription!(fixture.subscription.id)
    before_attempt = fetch_attempt!(fixture.subscription.id)
    [first_effect] = access_effects!(fixture.subscription.id)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      observation
    )

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: DateTime.add(before_subscription.failed_payment_boundary_at, -1, :second)
             )

    after_subscription = fetch_subscription!(fixture.subscription.id)
    after_attempt = fetch_attempt!(fixture.subscription.id)
    assert after_subscription.current_dunning_renewal_attempt_id == before_attempt.id

    assert after_subscription.failed_payment_boundary_at ==
             before_subscription.failed_payment_boundary_at

    assert after_attempt.charged_contract_snapshot == before_attempt.charged_contract_snapshot
    assert [^first_effect] = access_effects!(fixture.subscription.id)
  end

  test "F0.5 uses attempt X policy and current ContractChange Y provenance", %{context: context} do
    fixture = create_contract_bound_due_fixture!("jc247_b_x_to_y")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    task = start_failure_task(context, fixture)

    assert_receive {:jc247_b_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [old_effect] = access_effects!(subscription_id)
    attempt = fetch_attempt!(subscription_id)
    _subscription = fetch_subscription!(subscription_id)

    assert attempt.contract_change_id == fixture.change_x.id
    assert attempt.charged_contract_snapshot["access_on_past_due"] == "remove_immediately"
    assert old_effect.disposition == :non_effective
    assert old_effect.plan_revision_id == fixture.funded_revision_id

    SubscriptionsFixtures.create_plan_revision!(fixture.plan_y)
    assert {:ok, queued_y} = queue_plan_change(fixture.customer, subscription_id, fixture.plan_y)
    change_y = fetch_contract_change!(queued_y.current_contract_change_id)
    subscription = fetch_subscription!(subscription_id)
    assert subscription.current_contract_change_id == change_y.id
    assert subscription.current_plan_revision_id == fixture.funded_revision_id
    assert fetch_attempt!(subscription_id).contract_change_id == fixture.change_x.id

    set_updated_at!([old_effect], DateTime.add(DateTime.utc_now(), -1, :second))

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: DateTime.utc_now(),
               after_inserted_at: old_effect.inserted_at,
               after_id: @cursor_floor
             )

    assert result.repaired_count == 1
    assert result.noop_count == 0
    assert result.already_covered_count == 0
    [reconciled_old, reconciled_new] = access_effects!(subscription_id)
    assert reconciled_old.id == old_effect.id
    assert reconciled_old.status == :superseded
    assert reconciled_new.disposition == :non_effective
    assert reconciled_new.contract_change_id == change_y.id
    assert reconciled_new.plan_revision_id == fixture.funded_revision_id
    assert reconciled_new.entitlement_kind == nil
    assert reconciled_new.entitlement_scope_key == nil
    assert reconciled_new.valid_from_at == nil
    assert reconciled_new.valid_until_at == nil

    send(task.pid, {:jc247_b_release_postcommit, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(task, @barrier_timeout)
    assert fetch_subscription!(subscription_id).current_dunning_renewal_attempt_id == attempt.id
  end

  test "later suspension does not rewrite a B grant revocation reason" do
    fixture = create_due_fixture!("jc247_b_historical_reason")
    issue_source_grant!(fixture)
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    [grant] = grants_for_source!(fixture.subscription.id)
    assert grant.status == :revoked
    assert grant.revoked_reason == "past_due_remove_immediately"

    now = db_now!()

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = $2, retry_suppressed_at = $3, next_retry_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id), DateTime.add(now, -1, :second), now]
    )

    assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
             Facade.run_due_failed_payment_suspensions_for_system(now: now, limit: 100)

    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert [historical] = grants_for_source!(fixture.subscription.id)
    assert historical.id == grant.id
    assert historical.status == :revoked
    assert historical.revoked_reason == "past_due_remove_immediately"
  end

  test "later suspension revokes a recovered grant without rewriting the earlier B reason" do
    fixture = create_contract_bound_due_fixture!("jc247_b_recovered_grant_reason")
    issue_source_grant!(fixture)
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    [historical_grant] = grants_for_source!(fixture.subscription.id)
    assert historical_grant.status == :revoked
    assert historical_grant.revoked_reason == "past_due_remove_immediately"

    failed_subscription = fetch_subscription!(fixture.subscription.id)
    attempt = fetch_attempt!(fixture.subscription.id)

    order =
      Ash.get!(Order, attempt.order_id,
        domain: Store.Orders,
        authorize?: false,
        context: %{system?: true}
      )

    StripeAPIStub.stub_unexpected!("retry preparation must not submit a renewal charge")

    retry =
      ReachedRenewalFixtures.prepare_reached!(
        fixture.subscription.id,
        failed_subscription.next_retry_at
      )

    assert retry.attempt.id == attempt.id
    assert retry.order.id == order.id
    assert retry.collection.renewal_attempt_id == attempt.id
    assert retry.attempt.order_id == order.id
    assert retry.payment_intent.id == retry.collection.payment_intent_id

    assert retry.payment_intent.payment_intent_key ==
             RenewalCollectionAttempts.payment_intent_key(retry.collection.id)

    StripeAPIStub.stub_payment_observation(
      retry.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(retry, "succeeded")
    )

    assert {:ok, observed} =
             Store.Payments.Facade.observe_payment_intent_for_system(%ObservePaymentIntentInput{
               payment_intent_id: retry.payment_intent.id
             })

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

    assert outcome in [:authoritative_success, :already_applied_success]

    assert {:ok, handoff} =
             RenewalCollectionAttempts.success_handoff_for_system(retry.collection.id)

    assert handoff.renewal_attempt_id == attempt.id

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               renewal_attempt_id: handoff.renewal_attempt_id,
               collection_attempt_id: handoff.collection_attempt_id,
               payment_intent_id: handoff.payment_intent_id
             )

    recovered_grant =
      grants_for_source!(fixture.subscription.id)
      |> Enum.find(&(&1.id != historical_grant.id and &1.status == :active))

    assert %EntitlementGrant{} = recovered_grant
    assert recovered_grant.scope_key == "membership:#{fixture.label}-x"

    SubscriptionsFixtures.create_plan_revision!(fixture.plan_y)

    assert {:ok, queued_y} =
             queue_plan_change(fixture.customer, fixture.subscription.id, fixture.plan_y)

    subscription = fetch_subscription!(queued_y.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             run_reached_fixture!(subscription.id, subscription.next_renewal_at, "canceled")

    past_due = fetch_subscription!(subscription.id)
    assert past_due.status == :past_due
    assert past_due.current_dunning_renewal_attempt_id != attempt.id

    assert Enum.any?(grants_for_source!(subscription.id), fn grant ->
             grant.id == recovered_grant.id and grant.status == :active
           end)

    now = db_now!()

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = $2, retry_suppressed_at = $3, next_retry_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id), DateTime.add(now, -1, :second), now]
    )

    assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
             Facade.run_due_failed_payment_suspensions_for_system(now: now, limit: 100)

    assert fetch_subscription!(subscription.id).status == :suspended

    suspension_effect = List.last(access_effects!(subscription.id))
    assert suspension_effect.disposition == :non_effective

    assert {:ok, :applied} =
             Facade.execute_suspension_access_effect_for_system(suspension_effect.id)

    grants = grants_for_source!(subscription.id)

    assert Enum.find(grants, &(&1.id == historical_grant.id)).revoked_reason ==
             "past_due_remove_immediately"

    assert Enum.find(grants, &(&1.id == recovered_grant.id)).status == :revoked
    assert Enum.find(grants, &(&1.id == recovered_grant.id)).revoked_reason == "grace_expired"
  end

  defp start_failure_task(context, fixture) do
    _reached = prepare_reached_observation!(fixture.subscription.id, fixture.now, "canceled")

    Task.async(fn ->
      Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
      Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())

      Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
        now: fixture.now
      )
    end)
  end

  defp prepare_reached_observation!(subscription_id, now, status) do
    StripeAPIStub.stub_unexpected!("legacy preparation must not contact Stripe")
    reached = ReachedRenewalFixtures.prepare_reached!(subscription_id, now)

    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, status)
    )

    reached
  end

  defp attach_dunning_postcommit_barrier!(owner, barrier_ref, subscription_id) do
    handler_id = "jc247_b_dunning_barrier_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, %{subscription_id: sub_id}, config ->
          if sub_id == config.subscription_id do
            send(config.owner, {:jc247_b_postcommit_dunning, config.barrier_ref, sub_id})

            receive do
              {:jc247_b_release_postcommit, ref} when ref == config.barrier_ref -> :ok
            after
              @barrier_timeout -> raise "JC247-B dunning postcommit barrier timed out"
            end
          end
        end,
        %{owner: owner, barrier_ref: barrier_ref, subscription_id: subscription_id}
      )

    handler_id
  end

  defp create_due_fixture!(label) do
    now = db_now!()
    customer = SubscriptionsFixtures.create_customer!("#{label}_#{Ecto.UUID.generate()}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7,
        access_on_past_due: :remove_immediately,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{label}",
        started_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :microsecond)
      })

    %{
      subscription: subscription,
      customer: customer,
      scope: "membership:#{label}",
      now: now,
      run: fn -> run_reached_fixture!(subscription.id, now, "canceled") end
    }
  end

  defp run_reached_fixture!(subscription_id, now, status) do
    _reached = prepare_reached_observation!(subscription_id, now, status)

    Facade.process_due_subscription_renewal_for_system(subscription_id, now: now)
  end

  defp create_contract_bound_due_fixture!(label) do
    now = db_now!()
    customer = SubscriptionsFixtures.create_customer!("#{label}_#{Ecto.UUID.generate()}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}-current"
      })

    plan_x =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 4_700,
        currency: "EUR",
        access_on_past_due: :remove_immediately,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}-x"
      })

    plan_y =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 8_300,
        currency: "GBP",
        access_on_past_due: :keep_during_grace,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}-x"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan_x.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan_y.id)
    SubscriptionsFixtures.create_plan_revision!(plan_x)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :microsecond),
        quantity: 1,
        provider_billing_ref: "pm_#{label}"
      })

    Repo.query!(
      "UPDATE subscriptions SET next_renewal_at = current_period_end_at WHERE id = $1",
      [
        Ecto.UUID.dump!(subscription.id)
      ]
    )

    assert {:ok, input_x} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: subscription.id,
               subscription_plan_id: plan_x.id
             })

    assert {:ok, queued_x} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, input_x)

    change_x = fetch_contract_change!(queued_x.current_contract_change_id)
    current = fetch_subscription!(subscription.id)

    %{
      subscription: current,
      customer: customer,
      now: now,
      scope: "membership:#{label}-current",
      label: label,
      plan_y: plan_y,
      change_x: change_x,
      funded_revision_id: current.current_plan_revision_id,
      run: fn -> run_reached_fixture!(subscription.id, now, "canceled") end
    }
  end

  defp queue_plan_change(customer, subscription_id, plan) do
    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: subscription_id,
               subscription_plan_id: plan.id
             })

    Facade.queue_subscription_plan_change_for_user(customer, subscription_id, input)
  end

  defp issue_source_grant!(fixture) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               subscription = %{
                 id: fixture.subscription.id,
                 user_id: fixture.subscription.user_id,
                 current_period_end_at: fixture.subscription.current_period_end_at
               }

               plan = %{
                 entitlement_kind: :membership_access,
                 entitlement_scope_key: fixture.scope
               }

               assert {:ok, _} =
                        EntitlementsFacade.issue_subscription_source_grant_strict_for_system(
                          subscription,
                          plan
                        )

               :ok
             end)
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effects!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_effect!(id) do
    Ash.get!(AccessEffect, id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp latest_collection_for_attempt!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.last()
    |> case do
      nil -> raise "no renewal collection for attempt #{attempt_id}"
      collection -> collection
    end
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(id) do
    Ash.get!(ContractChange, id,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp set_updated_at!(effects, value) do
    Enum.each(effects, fn effect ->
      Repo.query!("UPDATE access_effects SET updated_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(effect.id),
        value
      ])
    end)
  end

  defp db_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end
end
