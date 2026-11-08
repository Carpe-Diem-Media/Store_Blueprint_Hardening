defmodule Store.Subscriptions.SubscriptionPlan do
  @moduledoc """
  Commercial subscription offer with cadence, anchor, term, and dunning policy.
  """

  import Ash.Expr

  alias Store.Subscriptions.BillingTimezone

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :status, Store.Subscriptions.Types.PlanStatus do
      allow_nil?(false)
      default(:active)
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
    has_many :variant_subscription_plans, Store.Subscriptions.VariantSubscriptionPlan do
      destination_attribute(:subscription_plan_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_key, [:key])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_public do
      filter(expr(status == :active))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_admin do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read :get_by_key_for_system do
      get?(true)

      argument :key, :string do
        allow_nil?(false)
      end

      filter(expr(key == ^arg(:key)))
    end

    create :create do
      accept([
        :key,
        :name,
        :status,
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
      ])

      change(&normalize_fields/2)
      validate(&validate_billing_timezone/2)
      validate(&validate_anchor/2)
      validate(&validate_term/2)
      validate(&validate_retry_schedule/2)
      validate(&validate_entitlement/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :name,
        :status,
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
      ])

      change(&normalize_fields/2)
      validate(&validate_billing_timezone/2)
      validate(&validate_anchor/2)
      validate(&validate_term/2)
      validate(&validate_retry_schedule/2)
      validate(&validate_entitlement/2)
    end

    update :archive do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :archived))
    end

    update :activate do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :active))
    end
  end

  code_interface do
    define(:list_for_public, action: :read_for_public)
    define(:list_for_admin, action: :read_for_admin)
    define(:get_for_admin, action: :get_for_admin, args: [:id])
    define(:get_by_key_for_system, action: :get_by_key_for_system, args: [:key])
  end

  postgres do
    table("subscription_plans")
    repo(Store.Repo)
    migration_defaults(retry_schedule_hours: "[0, 24, 72]")

    custom_indexes do
      index([:status], name: "subscription_plans_status_index")
      index([:interval_unit, :interval_count], name: "subscription_plans_interval_index")
      index([:key], name: "subscription_plans_key_index")
    end
  end

  policies do
    policy action(:read_for_public) do
      authorize_if(always())
    end

    policy action([:read, :read_for_admin, :get_for_admin]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:get_by_key_for_system) do
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
    |> normalize_attr(:key, &String.upcase/1)
    |> normalize_attr(:name, & &1)
    |> normalize_attr(:currency, &String.upcase/1)
    |> normalize_attr(:billing_timezone, & &1)
    |> normalize_attr(:entitlement_scope_key, & &1)
    |> normalize_retry_schedule()
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

  defp validate_billing_timezone(changeset, _context) do
    case BillingTimezone.validate(Ash.Changeset.get_attribute(changeset, :billing_timezone)) do
      :ok -> :ok
      {:error, error} -> {:error, field: :billing_timezone, message: error.message}
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
    entitlement_kind =
      Ash.Changeset.get_attribute(changeset, :entitlement_kind) || changeset.data.entitlement_kind

    entitlement_scope_key = Ash.Changeset.get_attribute(changeset, :entitlement_scope_key)

    if not is_nil(entitlement_kind) and not is_binary(entitlement_scope_key) do
      {:error,
       field: :entitlement_scope_key, message: "is required when entitlement_kind is present"}
    else
      :ok
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
