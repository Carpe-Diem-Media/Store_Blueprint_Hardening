defmodule Store.Subscriptions.PlanRevision do
  @moduledoc """
  Durable commercial-contract revision for a mutable subscription plan offer.
  """

  import Ash.Expr

  alias Store.Subscriptions.BillingTimezone

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  @commercial_fields [
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

  attributes do
    uuid_v7_primary_key(:id)

    attribute :status, Store.Subscriptions.Types.PlanRevisionStatus do
      allow_nil?(false)
      default(:draft)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
    end

    attribute :interval_unit, Store.Subscriptions.Types.IntervalUnit do
      allow_nil?(false)
      default(:month)
      public?(true)
    end

    attribute :interval_count, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      default("USD")
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :amount_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :trial_days, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :anchor_mode, Store.Subscriptions.Types.AnchorMode do
      allow_nil?(false)
      default(:start_anniversary)
      public?(true)
    end

    attribute :anchor_day_of_month, :integer do
      allow_nil?(true)
      constraints(min: 1, max: 31)
      public?(true)
    end

    attribute :billing_timezone, :string do
      allow_nil?(false)
      default("Africa/Johannesburg")
      public?(true)
    end

    attribute :term_mode, Store.Subscriptions.Types.TermMode do
      allow_nil?(false)
      default(:until_canceled)
      public?(true)
    end

    attribute :term_cycles, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(true)
    end

    attribute :term_end_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :access_on_past_due, Store.Subscriptions.Types.AccessOnPastDue do
      allow_nil?(false)
      default(:keep_during_grace)
      public?(true)
    end

    attribute :access_on_cancel, Store.Subscriptions.Types.AccessOnCancel do
      allow_nil?(false)
      default(:keep_until_period_end)
      public?(true)
    end

    attribute :grace_period_days, :integer do
      allow_nil?(false)
      default(7)
      constraints(min: 0)
      public?(true)
    end

    attribute :max_retry_attempts, :integer do
      allow_nil?(false)
      default(3)
      constraints(min: 0)
      public?(true)
    end

    attribute :retry_schedule_hours, {:array, :integer} do
      allow_nil?(false)
      default([0, 24, 72])
      public?(true)
    end

    attribute :entitlement_kind, Store.Entitlements.Types.EntitlementKind do
      allow_nil?(true)
      public?(true)
    end

    attribute :entitlement_scope_key, :string do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription_plan, Store.Subscriptions.SubscriptionPlan do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states([:draft])
    default_initial_state(:draft)

    transitions do
      transition(:publish, from: :draft, to: :effective)
      transition(:retire, from: :effective, to: :retired)
    end
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :get_effective_for_plan do
      get?(true)

      argument :subscription_plan_id, :uuid do
        allow_nil?(false)
      end

      filter(
        expr(
          subscription_plan_id == ^arg(:subscription_plan_id) and
            status == :effective
        )
      )
    end

    create :create_draft do
      accept([:subscription_plan_id | @commercial_fields])

      change(set_attribute(:status, :draft))
      change(set_attribute(:version, 1))
      change(&normalize_fields/2)
      validate(&validate_billing_timezone/2)
      validate(&validate_anchor/2)
      validate(&validate_term/2)
      validate(&validate_retry_schedule/2)
      validate(&validate_entitlement/2)
    end

    update :update_draft do
      require_atomic?(false)
      accept(@commercial_fields)

      change(filter(expr(status == :draft)))
      change(optimistic_lock(:version))
      change(&normalize_fields/2)
      validate(&validate_billing_timezone/2)
      validate(&validate_anchor/2)
      validate(&validate_term/2)
      validate(&validate_retry_schedule/2)
      validate(&validate_entitlement/2)
    end

    update :publish do
      require_atomic?(false)
      accept([])

      validate(&validate_billing_timezone/2)

      change(
        {Store.Support.Governance.TransitionState,
         target: :effective, state_attribute: :status, lock_attribute: :version}
      )
    end

    update :retire do
      require_atomic?(false)
      accept([])

      change(
        {Store.Support.Governance.TransitionState,
         target: :retired, state_attribute: :status, lock_attribute: :version}
      )
    end
  end

  code_interface do
    define(
      :get_effective_for_plan,
      action: :get_effective_for_plan,
      args: [:subscription_plan_id]
    )
  end

  postgres do
    table("plan_revisions")
    repo(Store.Repo)
    migration_defaults(retry_schedule_hours: "[0, 24, 72]")

    references do
      reference(:subscription_plan, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:status, "plan_revisions_status_value_check",
        check: "status IN ('draft', 'effective', 'retired')"
      )

      check_constraint(:version, "plan_revisions_version_check", check: "version >= 1")

      check_constraint(:interval_unit, "plan_revisions_interval_unit_value_check",
        check: "interval_unit IN ('day', 'month', 'year')"
      )

      check_constraint(:interval_count, "plan_revisions_interval_count_check",
        check: "interval_count >= 1"
      )

      check_constraint(:amount_minor, "plan_revisions_amount_minor_non_negative_check",
        check: "amount_minor >= 0"
      )

      check_constraint(:trial_days, "plan_revisions_trial_days_non_negative_check",
        check: "trial_days IS NULL OR trial_days >= 0"
      )

      check_constraint(:anchor_mode, "plan_revisions_anchor_mode_value_check",
        check: "anchor_mode IN ('start_anniversary', 'fixed_day_of_month')"
      )

      check_constraint(:anchor_day_of_month, "plan_revisions_anchor_day_requirement_check",
        check:
          "(anchor_mode <> 'fixed_day_of_month') OR (anchor_day_of_month >= 1 AND anchor_day_of_month <= 31)"
      )

      check_constraint(:term_mode, "plan_revisions_term_mode_value_check",
        check: "term_mode IN ('until_canceled', 'fixed_cycles', 'fixed_end_at')"
      )

      check_constraint(:term_cycles, "plan_revisions_term_cycles_requirement_check",
        check: "(term_mode <> 'fixed_cycles') OR (term_cycles IS NOT NULL AND term_cycles >= 1)"
      )

      check_constraint(:term_end_at, "plan_revisions_term_end_requirement_check",
        check: "(term_mode <> 'fixed_end_at') OR (term_end_at IS NOT NULL)"
      )

      check_constraint(:access_on_past_due, "plan_revisions_access_on_past_due_value_check",
        check: "access_on_past_due IN ('keep_during_grace', 'remove_immediately')"
      )

      check_constraint(:access_on_cancel, "plan_revisions_access_on_cancel_value_check",
        check: "access_on_cancel IN ('keep_until_period_end', 'remove_immediately')"
      )

      check_constraint(:grace_period_days, "plan_revisions_grace_period_days_check",
        check: "grace_period_days >= 0"
      )

      check_constraint(:max_retry_attempts, "plan_revisions_max_retry_attempts_check",
        check: "max_retry_attempts >= 0"
      )
    end

    custom_indexes do
      index([:subscription_plan_id], name: "plan_revisions_subscription_plan_id_index")

      index([:subscription_plan_id],
        unique: true,
        where: "status = 'effective'",
        name: "plan_revisions_one_effective_per_plan_index"
      )
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:currency, &String.upcase/1)
    |> normalize_attr(:billing_timezone, & &1)
    |> normalize_attr(:entitlement_scope_key, & &1)
    |> normalize_retry_schedule()
  end

  defp validate_billing_timezone(changeset, _context) do
    case BillingTimezone.validate(Ash.Changeset.get_attribute(changeset, :billing_timezone)) do
      :ok -> :ok
      {:error, error} -> {:error, field: :billing_timezone, message: error.message}
    end
  end

  defp normalize_attr(changeset, attr, transform) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        value =
          value
          |> String.trim()
          |> transform.()
          |> empty_to_nil()

        Ash.Changeset.change_attribute(changeset, attr, value)

      _ ->
        changeset
    end
  end

  defp normalize_retry_schedule(changeset) do
    case Ash.Changeset.get_attribute(changeset, :retry_schedule_hours) do
      schedule when is_list(schedule) ->
        normalized =
          schedule
          |> Enum.filter(fn hour -> is_integer(hour) and hour >= 0 end)
          |> Enum.uniq()
          |> Enum.sort()

        Ash.Changeset.change_attribute(changeset, :retry_schedule_hours, normalized)

      _ ->
        changeset
    end
  end

  defp validate_anchor(changeset, _context) do
    anchor_mode =
      Ash.Changeset.get_attribute(changeset, :anchor_mode) || changeset.data.anchor_mode

    anchor_day = Ash.Changeset.get_attribute(changeset, :anchor_day_of_month)

    if anchor_mode == :fixed_day_of_month and not is_integer(anchor_day) do
      {:error, field: :anchor_day_of_month, message: "is required for fixed_day_of_month plans"}
    else
      :ok
    end
  end

  defp validate_term(changeset, _context) do
    term_mode = Ash.Changeset.get_attribute(changeset, :term_mode) || changeset.data.term_mode
    term_cycles = Ash.Changeset.get_attribute(changeset, :term_cycles)
    term_end_at = Ash.Changeset.get_attribute(changeset, :term_end_at)

    cond do
      term_mode == :fixed_cycles and not is_integer(term_cycles) ->
        {:error, field: :term_cycles, message: "is required for fixed_cycles plans"}

      term_mode == :fixed_end_at and not match?(%DateTime{}, term_end_at) ->
        {:error, field: :term_end_at, message: "is required for fixed_end_at plans"}

      true ->
        :ok
    end
  end

  defp validate_retry_schedule(changeset, _context) do
    max_retry_attempts =
      Ash.Changeset.get_attribute(changeset, :max_retry_attempts) ||
        changeset.data.max_retry_attempts

    retry_schedule = Ash.Changeset.get_attribute(changeset, :retry_schedule_hours)

    cond do
      not is_list(retry_schedule) ->
        {:error, field: :retry_schedule_hours, message: "must be a list of non-negative integers"}

      retry_schedule == [] and max_retry_attempts > 0 ->
        {:error, field: :retry_schedule_hours, message: "must include at least one retry offset"}

      length(retry_schedule) < max_retry_attempts ->
        {:error,
         field: :retry_schedule_hours, message: "must contain offsets for configured retries"}

      true ->
        :ok
    end
  end

  defp validate_entitlement(changeset, _context) do
    entitlement_kind = resolved_attribute(changeset, :entitlement_kind)
    entitlement_scope_key = resolved_attribute(changeset, :entitlement_scope_key)

    if not is_nil(entitlement_kind) and not is_binary(entitlement_scope_key) do
      {:error,
       field: :entitlement_scope_key, message: "is required when entitlement_kind is present"}
    else
      :ok
    end
  end

  defp resolved_attribute(changeset, attribute) do
    if Ash.Changeset.changing_attribute?(changeset, attribute) do
      Ash.Changeset.get_attribute(changeset, attribute)
    else
      Map.get(changeset.data || %{}, attribute)
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
