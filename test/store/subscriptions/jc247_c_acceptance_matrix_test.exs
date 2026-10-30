defmodule Store.Subscriptions.Jc247CAcceptanceMatrixTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade, RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.Comms.EmailOutbox

  test "remove-immediately cancels active with exact F2 convergence",
    do: assert_remove_immediately!(:active)

  test "remove-immediately cancels past_due with dunning history and exact F2 convergence",
    do: assert_remove_immediately!(:past_due)

  test "remove-immediately cancels suspended with dunning history and exact F2 convergence",
    do: assert_remove_immediately!(:suspended)

  test "keep-until-period-end pair target converges through the funded end for active",
    do: assert_keep_pair!(:active)

  test "keep-until-period-end pair target converges through the funded end for past_due",
    do: assert_keep_pair!(:past_due)

  test "keep-until-period-end pair target converges through the funded end for suspended",
    do: assert_keep_pair!(:suspended)

  test "keep-until-period-end preserves the accepted nil/nil target" do
    fixture =
      create_cancel_fixture!("keep_empty", :active, :keep_until_period_end,
        entitlement_kind: nil,
        entitlement_scope_key: nil
      )

    assert {:ok, canceled} = cancel(fixture, :user)
    assert [effect] = access_effects!(canceled.id)
    assert effect.status == :applied
    assert effect.disposition == :effective
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == fixture.source.current_period_end_at
    assert effect.plan_revision_id == fixture.revision.id
    assert [] == Enum.filter(grants_for_source!(canceled.id), &(&1.status == :active))
    assert access_ended_count(canceled.id) == 0
  end

  test "keep policy outside the funded interval uses exact F2 convergence" do
    fixture =
      create_cancel_fixture!("keep_outside", :active, :keep_until_period_end,
        interval_unit: :day,
        interval_count: 1,
        started_at: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      )

    _grant = issue_source_grant!(fixture)
    assert DateTime.compare(fixture.source.current_period_end_at, DateTime.utc_now()) == :lt

    assert {:ok, canceled} = cancel(fixture, :user)
    assert [effect] = access_effects!(canceled.id)
    assert effect.status == :applied
    assert effect.disposition == :non_effective
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == nil
    assert effect.plan_revision_id == fixture.revision.id

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "canceled_now"}] =
             grants_for_source!(canceled.id)
  end

  test "pending is rejected without changing the source or establishing a policy effect" do
    fixture = create_cancel_fixture!("pending", :active, :remove_immediately)

    Repo.query!("UPDATE subscriptions SET status = 'pending' WHERE id = $1", [
      Ecto.UUID.dump!(fixture.source.id)
    ])

    assert {:error, _reason} = cancel(fixture, :user)
    assert fetch_subscription!(fixture.source.id).status == :pending
    assert access_effects!(fixture.source.id) == []
    assert grants_for_source!(fixture.source.id) == []
  end

  test "cancel-now replay leaves the source version and policy effect unchanged" do
    fixture = create_cancel_fixture!("replay", :active, :remove_immediately)
    assert {:ok, canceled} = cancel(fixture, :user)
    effects = access_effects!(canceled.id)

    assert {:ok, replayed} = cancel(fixture, :user)
    assert replayed.status == :canceled
    assert replayed.aggregate_version == canceled.aggregate_version
    assert access_effects!(canceled.id) == effects
  end

  test "funded non-membership suppresses email after mutable Plan changes to membership" do
    fixture =
      create_cancel_fixture!("immutable_email", :active, :remove_immediately,
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:funded"
      )

    update_plan!(fixture.plan, %{
      entitlement_kind: :membership_access,
      entitlement_scope_key: "membership:mutable"
    })

    assert fixture.revision.entitlement_kind == :digital_library
    assert {:ok, canceled} = cancel(fixture, :user)
    assert [effect] = access_effects!(canceled.id)
    assert effect.disposition == :non_effective
    assert effect.plan_revision_id == fixture.revision.id
    assert access_ended_count(canceled.id) == 0
  end

  test "F2 noop never queues a new access-ended message",
    do: assert_f2_email_suppressed!(:noop)

  test "F2 superseded never queues a new access-ended message",
    do: assert_f2_email_suppressed!(:superseded)

  test "F2 error never queues a new access-ended message",
    do: assert_f2_email_suppressed!(:error)

  test "F2 applied_projection_pending still permits the membership email" do
    fixture = create_cancel_fixture!("email_projection_pending", :active, :remove_immediately)
    _grant = issue_source_grant!(fixture)
    constraint = add_projection_pending_constraint!()

    on_exit(fn ->
      Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
    end)

    assert {:ok, canceled} = cancel(fixture, :user)
    assert [effect] = access_effects!(canceled.id)
    assert effect.status == :applied
    assert is_nil(effect.projection_delivered_at)
    assert access_ended_count(canceled.id) == 1
  end

  test "historical effects cannot replace the exact cancel-now effect used by F2" do
    fixture = create_cancel_fixture!("historical_effect", :active, :remove_immediately)
    _grant = issue_source_grant!(fixture)
    historical = establish_historical_effect!(fixture)
    assert {:ok, canceled} = cancel(fixture, :user)

    assert [old, current] = access_effects!(canceled.id)
    assert old.id == historical.id
    assert old.status == :superseded
    assert old.source_version < current.source_version
    assert current.status == :applied
    assert current.disposition == :non_effective

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "canceled_now"}] =
             grants_for_source!(canceled.id)
  end

  defp assert_remove_immediately!(source_state) do
    fixture =
      create_cancel_fixture!("remove_#{source_state}", source_state, :remove_immediately)

    grant = issue_source_grant!(fixture)
    attempt = seed_dunning_attempt!(fixture)

    assert {:ok, canceled} = cancel(fixture, :user)
    assert canceled.status == :canceled
    assert canceled.canceled_reason == "user_request"
    assert %DateTime{} = canceled.canceled_at
    assert canceled.current_plan_revision_id == fixture.revision.id
    assert canceled.current_period_start_at == fixture.source.current_period_start_at
    assert canceled.current_period_end_at == fixture.source.current_period_end_at
    assert is_nil(canceled.current_dunning_renewal_attempt_id)

    assert [effect] = access_effects!(canceled.id)
    assert effect.status == :applied
    assert effect.disposition == :non_effective
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == nil
    assert effect.plan_revision_id == fixture.revision.id
    assert effect.source_order_line_item_id == fixture.source.source_order_line_item_id
    assert effect.contract_change_id == fixture.source.current_contract_change_id
    assert effect.source_version == canceled.aggregate_version

    assert %EntitlementGrant{status: :revoked, revoked_reason: "canceled_now"} =
             fetch_grant!(grant.id)

    if attempt, do: assert(fetch_attempt!(attempt.id).id == attempt.id)
    assert access_ended_count(canceled.id) == 1
  end

  defp assert_keep_pair!(source_state) do
    fixture =
      create_cancel_fixture!("keep_pair_#{source_state}", source_state, :keep_until_period_end)

    bounds = {fixture.source.current_period_start_at, fixture.source.current_period_end_at}
    attempt = seed_dunning_attempt!(fixture)

    assert {:ok, canceled} = cancel(fixture, :admin)
    assert canceled.status == :canceled
    assert canceled.canceled_reason == "user_request"
    assert %DateTime{} = canceled.canceled_at
    assert canceled.current_plan_revision_id == fixture.revision.id
    assert {canceled.current_period_start_at, canceled.current_period_end_at} == bounds
    assert is_nil(canceled.current_dunning_renewal_attempt_id)

    assert [effect] = access_effects!(canceled.id)
    assert effect.status == :applied
    assert effect.disposition == :effective
    assert effect.entitlement_kind == fixture.revision.entitlement_kind
    assert effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert effect.valid_from_at == elem(bounds, 0)
    assert effect.valid_until_at == elem(bounds, 1)
    assert effect.plan_revision_id == fixture.revision.id

    assert [%EntitlementGrant{status: :active, kind: :membership_access} = grant] =
             grants_for_source!(canceled.id)

    assert grant.scope_key == fixture.revision.entitlement_scope_key
    assert grant.valid_from_at == elem(bounds, 0)
    assert grant.valid_to_at == elem(bounds, 1)
    assert access_ended_count(canceled.id) == 0
    if attempt, do: assert(fetch_attempt!(attempt.id).id == attempt.id)
  end

  defp assert_f2_email_suppressed!(outcome) do
    fixture = create_cancel_fixture!("email_#{outcome}", :active, :remove_immediately)
    _grant = issue_source_grant!(fixture)
    install_f2_outcome!(fixture, outcome)

    assert fixture.revision.entitlement_kind == :membership_access
    assert {:ok, canceled} = cancel(fixture, :user)
    assert canceled.status == :canceled
    assert access_ended_count(canceled.id) == 0

    case outcome do
      :noop ->
        assert [%AccessEffect{status: :applied}] = access_effects!(canceled.id)

      :superseded ->
        assert [
                 %AccessEffect{status: :superseded, source_version: old_version},
                 %AccessEffect{status: :required, source_version: new_version}
               ] = access_effects!(canceled.id)

        assert new_version > old_version

      :error ->
        assert [%AccessEffect{status: :failed_retryable}] = access_effects!(canceled.id)
        assert [%EntitlementGrant{status: :active}] = grants_for_source!(canceled.id)
    end
  end

  defp create_cancel_fixture!(label, source_state, policy, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    unique = "jc247_c_#{label}_#{Ecto.UUID.generate()}"
    customer = SubscriptionsFixtures.create_customer!(unique)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: Keyword.get(opts, :interval_unit, :month),
        interval_count: Keyword.get(opts, :interval_count, 1),
        access_on_cancel: policy,
        entitlement_kind: Keyword.get(opts, :entitlement_kind, :membership_access),
        entitlement_scope_key: Keyword.get(opts, :entitlement_scope_key, "membership:#{unique}")
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: Keyword.get(opts, :started_at, DateTime.add(now, -10 * 86_400, :second)),
        provider_billing_ref: "pm_#{unique}"
      })

    source = set_source_state!(fixture.subscription, source_state, now)
    TestFixtures.assign_role!(customer, :admin)
    actor = customer

    %{
      actor: actor,
      customer: customer,
      line_item: fixture.line_item,
      plan: plan,
      revision: fixture.revision,
      source: source,
      subscription_id: source.id,
      variant: variant
    }
  end

  defp set_source_state!(subscription, :active, _now), do: subscription

  defp set_source_state!(subscription, source_state, now)
       when source_state in [:past_due, :suspended] do
    past_due =
      subscription
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{
          billing_status_reason: "payment_failed",
          past_due_since_at: now,
          failed_payment_boundary_at: now
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    if source_state == :suspended do
      past_due
      |> Ash.Changeset.for_update(:mark_suspended_transition, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    else
      past_due
    end
  end

  defp seed_dunning_attempt!(%{source: %Subscription{status: status}} = fixture)
       when status in [:past_due, :suspended] do
    attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: fixture.source.id,
          period_start_at: fixture.source.current_period_end_at,
          period_end_at: DateTime.add(fixture.source.current_period_end_at, 86_400, :second),
          plan_revision_id: fixture.revision.id,
          variant_id: fixture.variant.id,
          quantity: fixture.source.quantity,
          amount_minor: fixture.source.renewal_amount_minor,
          currency: fixture.source.renewal_currency,
          expected_subscription_version: fixture.source.aggregate_version,
          charged_contract_version: 1,
          charged_contract_snapshot: charged_contract_snapshot(fixture),
          renewal_key: "jc247-c-#{fixture.source.id}",
          status: :failed,
          failure_code: "PAYMENT_FAILED"
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    Repo.query!(
      "UPDATE subscriptions SET current_dunning_renewal_attempt_id = $2 WHERE id = $1",
      [
        Ecto.UUID.dump!(fixture.source.id),
        Ecto.UUID.dump!(attempt.id)
      ]
    )

    attempt
  end

  defp seed_dunning_attempt!(_fixture), do: nil

  defp charged_contract_snapshot(fixture) do
    revision = fixture.revision

    %{
      "version" => 1,
      "subscription_plan_key" => fixture.plan.key,
      "interval_unit" => Atom.to_string(revision.interval_unit),
      "interval_count" => revision.interval_count,
      "trial_days" => revision.trial_days,
      "anchor_mode" => Atom.to_string(revision.anchor_mode),
      "anchor_day_of_month" => revision.anchor_day_of_month,
      "billing_timezone" => revision.billing_timezone,
      "term_mode" => Atom.to_string(revision.term_mode),
      "term_cycles" => revision.term_cycles,
      "term_end_at" => nil,
      "access_on_past_due" => Atom.to_string(revision.access_on_past_due),
      "access_on_cancel" => Atom.to_string(revision.access_on_cancel),
      "grace_period_days" => revision.grace_period_days,
      "max_retry_attempts" => revision.max_retry_attempts,
      "retry_schedule_hours" => revision.retry_schedule_hours,
      "entitlement_kind" => Atom.to_string(revision.entitlement_kind),
      "entitlement_scope_key" => revision.entitlement_scope_key
    }
  end

  defp cancel(fixture, :user),
    do: Facade.cancel_subscription_for_user(fixture.customer, fixture.subscription_id, :now)

  defp cancel(fixture, :admin),
    do: Facade.cancel_subscription_for_admin(fixture.actor, fixture.subscription_id, :now)

  defp issue_source_grant!(fixture) do
    EntitlementGrant
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: fixture.source.user_id,
        kind: fixture.revision.entitlement_kind,
        scope_key: fixture.revision.entitlement_scope_key,
        source_kind: :subscription,
        source_id: fixture.source.id,
        status: :active,
        valid_from_at: fixture.source.current_period_start_at,
        valid_to_at: fixture.source.current_period_end_at
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp update_plan!(plan, attrs) do
    plan
    |> Ash.Changeset.for_update(:update, attrs, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effects!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_grant!(grant_id),
    do: Ash.get!(EntitlementGrant, grant_id, domain: Store.Entitlements, authorize?: false)

  defp fetch_attempt!(attempt_id),
    do: Ash.get!(RenewalAttempt, attempt_id, domain: Store.Subscriptions, authorize?: false)

  defp fetch_subscription!(subscription_id),
    do: Ash.get!(Subscription, subscription_id, domain: Store.Subscriptions, authorize?: false)

  defp access_ended_count(subscription_id) do
    EmailOutbox
    |> Ash.Query.filter(
      expr(subscription_id == ^subscription_id and template_kind == :access_ended)
    )
    |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  defp add_projection_pending_constraint! do
    constraint = "jc247_c_projection_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE access_effects
    ADD CONSTRAINT #{constraint}
    CHECK (projection_delivered_at IS NULL)
    NOT VALID
    """)

    constraint
  end

  defp establish_historical_effect!(fixture) do
    attrs = %{
      subscription_id: fixture.source.id,
      source_version: max(fixture.source.aggregate_version, 1),
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: fixture.source.source_order_line_item_id,
      contract_change_id: fixture.source.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    {:ok, input} = Store.Subscriptions.Inputs.EstablishAccessEffectInput.new(attrs)
    {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp install_f2_outcome!(fixture, :error) do
    constraint = "jc247_c_f2_error_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE entitlement_grants
    ADD CONSTRAINT #{constraint}
    CHECK (source_id <> '#{fixture.source.id}'::uuid OR status <> 'revoked')
    NOT VALID
    """)

    on_exit(fn ->
      Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT IF EXISTS #{constraint}")
    end)
  end

  defp install_f2_outcome!(fixture, :noop) do
    function = "jc247_c_mark_applied_#{System.unique_integer([:positive])}"
    trigger = "#{function}_trigger"

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      UPDATE access_effects SET status = 'applied' WHERE id = NEW.id;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    AFTER INSERT ON access_effects
    FOR EACH ROW WHEN (NEW.subscription_id = '#{fixture.source.id}'::uuid)
    EXECUTE FUNCTION #{function}()
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON access_effects")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end)
  end

  defp install_f2_outcome!(fixture, :superseded) do
    function = "jc247_c_add_newer_effect_#{System.unique_integer([:positive])}"
    trigger = "#{function}_trigger"

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      UPDATE subscriptions
      SET aggregate_version = NEW.source_version + 1
      WHERE id = NEW.subscription_id;

      INSERT INTO access_effects (
        id, subscription_id, source_version, status, disposition,
        entitlement_kind, entitlement_scope_key, valid_from_at, valid_until_at,
        source_order_line_item_id, contract_change_id, plan_revision_id,
        target_fingerprint, inserted_at, updated_at
      ) VALUES (
        current_setting('store.jc247_c_newer_effect_id')::uuid,
        NEW.subscription_id, NEW.source_version + 1, 'required', NEW.disposition,
        NEW.entitlement_kind, NEW.entitlement_scope_key, NEW.valid_from_at, NEW.valid_until_at,
        NEW.source_order_line_item_id, NEW.contract_change_id, NEW.plan_revision_id,
        NEW.target_fingerprint, now(), now()
      );
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    AFTER INSERT ON access_effects
    FOR EACH ROW WHEN (
      NEW.subscription_id = '#{fixture.source.id}'::uuid
      AND NEW.id <> current_setting('store.jc247_c_newer_effect_id')::uuid
    )
    EXECUTE FUNCTION #{function}()
    """)

    Repo.query!("SELECT set_config('store.jc247_c_newer_effect_id', $1, false)", [
      Ash.UUIDv7.generate()
    ])

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON access_effects")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
      Repo.query!("SELECT set_config('store.jc247_c_newer_effect_id', '', false)")
    end)
  end
end
