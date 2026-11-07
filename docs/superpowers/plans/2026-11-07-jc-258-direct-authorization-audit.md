# JC-258 direct authorization proof implementation plan

> **For agentic workers:** Use the approved sequential issue workflow. Steps use checkbox syntax for tracking.

**Goal:** Add one fixture-backed governance test that records direct Ash authorization and facade ownership behavior for the JC-258 Subscription and RenewalAttempt audit.

**Architecture:** Add only `test/store/governance/jc258_direct_authorization_audit_test.exs`. Use existing actor and subscription fixture constructors, invoke the two matrix SYSTEM-only actions directly through Ash, and call the existing cancellation and queued-contract-change facade functions with typed inputs. Assert valid changesets and persisted state so authorization results cannot be confused with lifecycle validation or no-op target equality.

**Tech Stack:** Elixir, ExUnit, Ash 3, PostgreSQL Sandbox, Store.DataCase.

---

## Scope and evidence limits

Do not edit production code, policy rows, shared auth, or fixtures. This module proves only the named actions and facade paths below. A legacy RenewalAttempt with all charged-contract fields nil is permitted solely for an authorization fixture: the SQL check allows the complete legacy nil tuple, but this does not prove renewal dispatch behavior. The source matrix names `activate`, `mark_past_due`, `reconcile_renewal`, and RenewalAttempt create/update categories. The direct demonstrations below target only the two concrete currently exposed actions, `mark_past_due_transition` and `mark_processing`. Do not extrapolate to other lifecycle actions.

Current source evidence: `Subscription.mark_past_due_transition` allows an active-to-past_due transition and its resource policy permits system context or admin/super_admin roles. `RenewalAttempt.mark_processing` changes pending to processing, and its create/update policy likewise permits system context or admin/super_admin. Therefore direct calls currently succeed for admin, super_admin, and system context, while owner, non-owner, support, editor, and anonymous contexts are denied. These two results are candidate matrix drift; this audit test records behavior and must not change the rows.

For facade cancellation, non-owner lookup returns no row and the facade maps that to `SUBSCRIPTION_NOT_FOUND`; support can read through the admin getter but does not pass the cancellation policy. The support facade denial uses the confirmed `FORBIDDEN` mapping. Do not replace these action-specific contracts with a blanket error assertion.

The policy matrix does not define a role for subscription plan or variant changes, beyond the existing resource `queue_change` policy. Record owner/admin controls and support denial as current behavior. Leave any missing role law as a decision gap; do not infer new Product permission policy. The customer detail builder reads the most recent five RenewalAttempt rows with `authorize?: false` and system context after its owner-scoped Subscription lookup. Test the direct customer `:read_for_subscription` query with an exact owned attempt filter and the same row in the owner detail result. Root verification already observed `Ash.Error.Forbidden` for the direct query and inclusion of that attempt in owner detail. Record this as a candidate boundary finding that needs authority review. Do not claim the matrix explicitly governs nested detail fields, and do not change policy or facade behavior in JC-258.

## File ownership

- Create `test/store/governance/jc258_direct_authorization_audit_test.exs`. This is the only file in scope.

## Proposed complete module

The source confirms that `Normalize.normalize/1` maps `Ash.Error.Forbidden` to `FORBIDDEN`, and the facade maps an absent owner-scoped subscription to `SUBSCRIPTION_NOT_FOUND`. The code below scopes state checks to the fixture subscription and its contract changes. Each successful mutation uses its own fixture.

```elixir
defmodule Store.Governance.JC258DirectAuthorizationAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionVariantChangeInput
  alias Store.Subscriptions.RenewalAttempt
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
    for {label, actor, context, expected, owner_id, owner} <- authorization_actors!("jc258_past_due") do
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
    for {label, actor, context, expected, owner_id, owner} <- authorization_actors!("jc258_processing") do
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

    assert_queued_plan_change!(owner_result, target_plan.plan.id, target_plan.revision.id, owner_fixture)

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

    assert_queued_plan_change!(admin_result, admin_target.plan.id, admin_target.revision.id, admin_fixture)

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

    assert_queued_variant_change!(owner_result, owner_target.id)

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

    assert_queued_variant_change!(admin_result, admin_target.id)

    non_owner = SubscriptionsFixtures.create_customer!("jc258_variant_non_owner")
    non_owner_fixture = subscription_fixture!("jc258_variant_non_owner_target")
    non_owner_target = attach_target_variant!(non_owner_fixture)
    non_owner_input = variant_change_input!(non_owner_fixture.subscription.id, non_owner_target.id)
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

  defp subscription_fixture!(prefix, customer \\ nil) do
    customer = customer || SubscriptionsFixtures.create_customer!("#{prefix}_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_#{prefix}",
        provider_billing_ref: "pm_#{prefix}"
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

  defp assert_queued_plan_change!(result, target_plan_id, target_revision_id, fixture) do
    assert result.pending_subscription_plan_id == target_plan_id
    refute result.pending_subscription_plan_id == fixture.subscription.subscription_plan_id
    change = fetch_contract_change!(result.current_contract_change_id)
    assert change.subscription_id == fixture.subscription.id
    assert change.status == :queued
    assert change.instruction_kind == :plan_change
    assert change.target_plan_revision_id == target_revision_id
  end

  defp assert_queued_variant_change!(result, target_variant_id) do
    assert result.pending_variant_id == target_variant_id
    change = fetch_contract_change!(result.current_contract_change_id)
    assert change.subscription_id == result.id
    assert change.status == :queued
    assert change.instruction_kind == :variant_change
    assert change.target_variant_id == target_variant_id
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
end
```

## Implementation sequence

- [ ] Create only `test/store/governance/jc258_direct_authorization_audit_test.exs` from the complete module above. Preserve the stated actor IDs, fixture ownership, exact action names, return contracts, and scoped persisted-state assertions.
- [ ] Inspect the new file and confirm it contains no production changes, new fixture seams, provider calls, or permission edits.
- [ ] Run each command below separately through DevCore. Each block prints the command exit code and returns that same code. Wait for each process to exit before starting the next Mix command because this repository allows one Mix owner.
- [ ] Confirm `mix format --check-formatted` and `mix compile --warnings-as-errors` exit with code 0 before reviewing the test result and strict Credo result.

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted test/store/governance/jc258_direct_authorization_audit_test.exs
jc258_direct_check_status=$?
printf 'exit_code=%s\n' "$jc258_direct_check_status"
exit "$jc258_direct_check_status"
```

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
jc258_direct_check_status=$?
printf 'exit_code=%s\n' "$jc258_direct_check_status"
exit "$jc258_direct_check_status"
```

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/governance/jc258_direct_authorization_audit_test.exs
jc258_direct_check_status=$?
printf 'exit_code=%s\n' "$jc258_direct_check_status"
exit "$jc258_direct_check_status"
```

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/governance/jc258_direct_authorization_audit_test.exs
jc258_direct_check_status=$?
printf 'exit_code=%s\n' "$jc258_direct_check_status"
exit "$jc258_direct_check_status"
```

The plan author did not run Mix, database commands, Git commands, or tracker operations. Root review and commitment of this plan precede implementation by a separate worker.
