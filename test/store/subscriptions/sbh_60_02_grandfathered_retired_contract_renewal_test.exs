defmodule Store.Subscriptions.Sbh6002GrandfatheredRetiredContractRenewalTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Repo
  alias Store.Subscriptions.{ContractChange, Facade, PlanRevision, RenewalAttempt}
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub

  @plan_revision_fields [
    :interval_unit,
    :interval_count,
    :currency,
    :amount_minor,
    :trial_days,
    :anchor_mode,
    :anchor_day_of_month,
    :billing_timezone,
    :term_mode,
    :term_cycles,
    :term_end_at,
    :access_on_past_due,
    :access_on_cancel,
    :grace_period_days,
    :max_retry_attempts,
    :retry_schedule_hours,
    :entitlement_kind,
    :entitlement_scope_key
  ]

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a DRAFT current revision fails closed before checkpoint B" do
    fixture = due_fixture!("draft_current")
    draft_revision = create_matching_draft_revision!(fixture.plan, fixture.revision)

    Repo.query!(
      "UPDATE subscriptions SET current_plan_revision_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(draft_revision.id), Ecto.UUID.dump!(fixture.subscription.id)]
    )

    assert {:error,
            %Error{
              code: "VALIDATION_ERROR",
              message: "purchased plan revision was never effective"
            }} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    assert [] == list_attempts!(fixture.subscription.id)
  end

  test "a DRAFT queued ContractChange target fails closed before checkpoint B" do
    fixture = due_fixture!("draft_queued_target")

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 3_700,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, queued_subscription} =
             queue_plan_change(fixture.customer, fixture.subscription.id, target_plan)

    queued_change = fetch_contract_change!(queued_subscription.current_contract_change_id)
    draft_revision = create_matching_draft_revision!(target_plan, target_revision)

    Repo.query!(
      "UPDATE contract_changes SET target_plan_revision_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(draft_revision.id), Ecto.UUID.dump!(queued_change.id)]
    )

    assert {:error,
            %Error{
              code: "VALIDATION_ERROR",
              message: "purchased plan revision was never effective"
            }} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    assert [] == list_attempts!(fixture.subscription.id)

    persisted_change = fetch_contract_change!(queued_change.id)
    assert persisted_change.status == :queued
    assert persisted_change.target_plan_revision_id == draft_revision.id
  end

  test "a queued target retired before checkpoint B remains the exact renewal authority" do
    fixture = due_fixture!("retired_queued_target")

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 2,
        amount_minor: 3_700,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(fixture.variant.id, target_plan.id)
    target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)

    assert {:ok, queued_subscription} =
             queue_plan_change(fixture.customer, fixture.subscription.id, target_plan)

    queued_change = fetch_contract_change!(queued_subscription.current_contract_change_id)
    assert queued_change.target_plan_revision_id == target_revision.id

    assert {:ok, retired_revision} =
             target_revision
             |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    replacement_revision =
      SubscriptionsFixtures.create_plan_revision!(target_plan, %{amount_minor: 4_900})

    assert retired_revision.status == :retired
    assert replacement_revision.status == :effective

    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: fixture.now
             )

    [attempt] = list_attempts!(fixture.subscription.id)
    persisted_change = fetch_contract_change!(queued_change.id)

    assert persisted_change.status == :bound_to_renewal
    assert persisted_change.target_plan_revision_id == target_revision.id
    assert attempt.plan_revision_id == target_revision.id
    assert attempt.contract_change_id == queued_change.id
    assert attempt.amount_minor == queued_change.target_amount_minor
    refute attempt.plan_revision_id == replacement_revision.id
  end

  defp due_fixture!(suffix) do
    customer = SubscriptionsFixtures.create_customer!("sbh_60_02_#{suffix}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_300,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second),
        provider_billing_ref: "pm_sbh_60_02_#{suffix}"
      })

    %{
      customer: customer,
      variant: variant,
      plan: plan,
      revision: revision,
      subscription: subscription,
      now: now
    }
  end

  defp create_matching_draft_revision!(plan, source_revision) do
    attrs =
      source_revision
      |> Map.take(@plan_revision_fields)
      |> Map.put(:subscription_plan_id, plan.id)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp queue_plan_change(customer, subscription_id, target_plan) do
    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription_id,
        "subscription_plan_id" => target_plan.id
      })

    Facade.queue_subscription_plan_change_for_user(customer, subscription_id, input)
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_attempts!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
