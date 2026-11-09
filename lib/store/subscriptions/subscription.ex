defmodule Store.Subscriptions.Subscription do
  @moduledoc """
  Customer subscription instance with replay-safe activation and renewal metadata.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  @unresolved_contract_message "subscription commercial contract is unresolved"

  attributes do
    uuid_v7_primary_key(:id)

    attribute :user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Subscriptions.Types.SubscriptionStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :aggregate_version, :integer do
      allow_nil?(false)
      default(1)
      public?(false)
    end

    attribute :payment_method_setup_generation, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(false)
      description("Monotonic authority version that invalidates older payment method setups.")
    end

    attribute :provider, Store.Payments.Types.Provider do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_subscription_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :billing_mode, Store.Subscriptions.Types.BillingMode do
      allow_nil?(false)
      public?(true)
    end

    attribute :billing_status_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :cancel_at_period_end, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :cancel_at_period_end_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :cancel_after_renewal_attempt_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :current_dunning_renewal_attempt_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :current_period_start_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :current_period_end_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :next_renewal_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :past_due_since_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :failed_payment_boundary_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :canceled_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :ended_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :canceled_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_customer_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_billing_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :quantity, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    attribute :renewal_amount_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :renewal_currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :membership_key, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :pending_renewal_amount_minor, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :pending_renewal_currency, :string do
      allow_nil?(true)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :change_effective_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :dunning_attempt_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :next_retry_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :retry_suppressed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :source_order_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :source_order_line_item_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :current_plan_revision_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :current_contract_change_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription_plan, Store.Subscriptions.SubscriptionPlan do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :current_plan_revision, Store.Subscriptions.PlanRevision do
      source_attribute(:current_plan_revision_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :current_contract_change, Store.Subscriptions.ContractChange do
      source_attribute(:current_contract_change_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :cancel_after_renewal_attempt, Store.Subscriptions.RenewalAttempt do
      source_attribute(:cancel_after_renewal_attempt_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :current_dunning_renewal_attempt, Store.Subscriptions.RenewalAttempt do
      source_attribute(:current_dunning_renewal_attempt_id)
      destination_attribute(:id)
      define_attribute?(false)
      allow_nil?(true)
      attribute_writable?(false)
      public?(false)
    end

    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :pending_subscription_plan, Store.Subscriptions.SubscriptionPlan do
      source_attribute(:pending_subscription_plan_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :pending_variant, Store.Catalog.Variant do
      source_attribute(:pending_variant_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :stored_payment_method, Store.Subscriptions.StoredPaymentMethod do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    has_many :items, Store.Subscriptions.SubscriptionItem do
      destination_attribute(:subscription_id)
      public?(true)
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:activate_now, from: [:pending, :past_due], to: :active)
      transition(:mark_past_due_transition, from: :active, to: :past_due)
      transition(:mark_suspended_transition, from: :past_due, to: :suspended)

      transition(:cancel_now_transition,
        from: [:pending, :active, :past_due, :suspended],
        to: :canceled
      )

      transition(:scheduled_boundary_cancellation_transition, from: :active, to: :canceled)

      transition(:mark_expired_transition, from: [:active, :past_due, :suspended], to: :expired)
      transition(:extend_period, from: :past_due, to: :active)
      transition(:extend_period, from: :suspended, to: :active)
      transition(:extend_period, from: :active, to: :active)
    end
  end

  identities do
    identity(:unique_source_order_line_item, [:source_order_line_item_id])
    identity(:unique_provider_subscription_ref, [:provider, :provider_subscription_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    action :read_access_inventory_window_for_system, {:array, :map} do
      public?(false)
      transaction?(false)

      argument :through_id, :uuid do
        allow_nil?(false)
      end

      argument :after_id, :uuid do
        allow_nil?(true)
      end

      argument :limit, :integer do
        allow_nil?(false)
        default(100)
        constraints(min: 1, max: 500)
      end

      run(Store.Subscriptions.Actions.ReadSubscriptionAccessInventoryWindow)
    end

    read :read_for_user do
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 100)
      filter(expr(user_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_user do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id) and user_id == ^actor(:id)))
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

    read :read_due_for_system do
      argument :now, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :limit, :integer do
        allow_nil?(false)
        default(100)
        constraints(min: 1, max: 500)
      end

      argument :after_renewal_at, :utc_datetime_usec do
        allow_nil?(true)
      end

      argument :after_id, :uuid do
        allow_nil?(true)
      end

      filter(
        expr(
          ((status == :active and not is_nil(next_renewal_at) and next_renewal_at <= ^arg(:now)) or
             (status == :past_due and not is_nil(failed_payment_boundary_at) and
                is_nil(retry_suppressed_at) and
                (is_nil(next_retry_at) or next_retry_at <= ^arg(:now)))) and
            cancel_at_period_end == false and
            (is_nil(^arg(:after_id)) or
               (not is_nil(^arg(:after_renewal_at)) and
                  (next_renewal_at > ^arg(:after_renewal_at) or
                     (next_renewal_at == ^arg(:after_renewal_at) and id > ^arg(:after_id)) or
                     is_nil(next_renewal_at))) or
               (is_nil(^arg(:after_renewal_at)) and is_nil(next_renewal_at) and
                  id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [next_renewal_at: :asc_nils_last, id: :asc], limit: arg(:limit)))
    end

    read :read_due_failed_payment_boundary_for_system do
      argument :now, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_boundary_at, :utc_datetime_usec do
        allow_nil?(true)
      end

      argument :after_id, :uuid do
        allow_nil?(true)
      end

      argument :limit, :integer do
        allow_nil?(false)
        default(100)
        constraints(min: 1, max: 500)
      end

      filter(
        expr(
          status == :past_due and not is_nil(failed_payment_boundary_at) and
            failed_payment_boundary_at <= ^arg(:now) and
            (is_nil(^arg(:after_boundary_at)) or
               failed_payment_boundary_at > ^arg(:after_boundary_at) or
               (failed_payment_boundary_at == ^arg(:after_boundary_at) and
                  id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [failed_payment_boundary_at: :asc, id: :asc], limit: arg(:limit)))
    end

    read :read_due_scheduled_cancellations_for_system do
      argument :now, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_boundary_at, :utc_datetime_usec do
        allow_nil?(true)
      end

      argument :after_id, :uuid do
        allow_nil?(true)
      end

      argument :limit, :integer do
        allow_nil?(false)
        default(100)
        constraints(min: 1, max: 500)
      end

      filter(
        expr(
          status == :active and cancel_at_period_end == true and
            not is_nil(cancel_at_period_end_at) and cancel_at_period_end_at <= ^arg(:now) and
            (is_nil(^arg(:after_boundary_at)) or
               cancel_at_period_end_at > ^arg(:after_boundary_at) or
               (cancel_at_period_end_at == ^arg(:after_boundary_at) and id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [cancel_at_period_end_at: :asc, id: :asc], limit: arg(:limit)))
    end

    read :read_past_due_missing_boundary_for_system do
      argument :after_id, :uuid do
        allow_nil?(true)
      end

      argument :limit, :integer do
        allow_nil?(false)
        default(100)
        constraints(min: 1, max: 500)
      end

      filter(
        expr(
          status == :past_due and is_nil(failed_payment_boundary_at) and
            (is_nil(^arg(:after_id)) or id > ^arg(:after_id))
        )
      )

      prepare(build(sort: [id: :asc], limit: arg(:limit)))
    end

    create :create_from_order_line do
      accept([
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
      ])

      validate(fn changeset, _context ->
        if is_binary(Ash.Changeset.get_attribute(changeset, :current_plan_revision_id)) do
          :ok
        else
          {:error, field: :current_plan_revision_id, message: @unresolved_contract_message}
        end
      end)

      upsert?(true)
      upsert_identity(:unique_source_order_line_item)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :activate_now do
      require_atomic?(false)

      validate(fn changeset, _context ->
        if Ash.Changeset.get_data(changeset, :status) == :past_due and
             not is_nil(Ash.Changeset.get_data(changeset, :current_dunning_renewal_attempt_id)) do
          {:error,
           field: :current_dunning_renewal_attempt_id,
           message: "paid recovery must reconcile the current dunning RenewalAttempt"}
        else
          :ok
        end
      end)

      accept([
        :started_at,
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(
        {Store.Support.Governance.TransitionState,
         target: :active, state_attribute: :status, lock_attribute: nil}
      )

      change(set_attribute(:past_due_since_at, nil))
      change(set_attribute(:failed_payment_boundary_at, nil))
      change(set_attribute(:billing_status_reason, nil))
      change(set_attribute(:dunning_attempt_count, 0))
      change(set_attribute(:next_retry_at, nil))
      change(set_attribute(:retry_suppressed_at, nil))
      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :mark_past_due_transition do
      require_atomic?(false)

      argument :dunning_renewal_attempt_id, :uuid do
        allow_nil?(true)
        public?(false)
      end

      accept([
        :billing_status_reason,
        :past_due_since_at,
        :failed_payment_boundary_at,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(fn changeset, _context ->
        source_status = Ash.Changeset.get_data(changeset, :status)

        current_attempt_id =
          Ash.Changeset.get_data(changeset, :current_dunning_renewal_attempt_id)

        incoming_attempt_id = Ash.Changeset.get_argument(changeset, :dunning_renewal_attempt_id)

        cond do
          source_status == :active and is_nil(current_attempt_id) ->
            Ash.Changeset.change_attribute(
              changeset,
              :current_dunning_renewal_attempt_id,
              incoming_attempt_id
            )

          source_status == :past_due and is_nil(current_attempt_id) and
              is_nil(incoming_attempt_id) ->
            changeset

          source_status == :past_due and not is_nil(current_attempt_id) and
              incoming_attempt_id == current_attempt_id ->
            changeset

          is_nil(current_attempt_id) and is_nil(incoming_attempt_id) ->
            changeset

          current_attempt_id == incoming_attempt_id ->
            changeset

          true ->
            Ash.Changeset.add_error(changeset,
              field: :current_dunning_renewal_attempt_id,
              message: "current dunning RenewalAttempt identity cannot be replaced"
            )
        end
      end)

      change(fn changeset, _context ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :past_due_since_at)) do
          Ash.Changeset.change_attribute(
            changeset,
            :past_due_since_at,
            DateTime.utc_now() |> DateTime.truncate(:microsecond)
          )
        else
          changeset
        end
      end)

      change(
        {Store.Support.Governance.TransitionState,
         target: :past_due, state_attribute: :status, lock_attribute: nil}
      )

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :mark_suspended_transition do
      public?(false)
      require_atomic?(false)

      accept([:billing_status_reason, :past_due_since_at, :dunning_attempt_count])

      change(
        {Store.Support.Governance.TransitionState,
         target: :suspended, state_attribute: :status, lock_attribute: nil}
      )

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :cancel_after_renewal_attempt_id) do
          nil ->
            changeset
            |> Ash.Changeset.change_attribute(:cancel_at_period_end, false)
            |> Ash.Changeset.change_attribute(:cancel_at_period_end_at, nil)

          _attempt_id ->
            changeset
            |> Ash.Changeset.change_attribute(:cancel_at_period_end, true)
            |> Ash.Changeset.change_attribute(:cancel_at_period_end_at, nil)
        end
      end)

      change(set_attribute(:next_retry_at, nil))
      change(set_attribute(:retry_suppressed_at, nil))
      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :cancel_at_period_end_transition do
      public?(false)
      require_atomic?(false)

      accept([
        :cancel_at_period_end_at,
        :cancel_after_renewal_attempt_id,
        :current_contract_change_id,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at
      ])

      change(set_attribute(:cancel_at_period_end, true))
      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :rescind_cancel_at_period_end_transition do
      public?(false)
      require_atomic?(false)

      accept([
        :current_contract_change_id,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at
      ])

      change(set_attribute(:cancel_at_period_end, false))
      change(set_attribute(:cancel_at_period_end_at, nil))
      change(set_attribute(:cancel_after_renewal_attempt_id, nil))
      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :cancel_now_transition do
      public?(false)
      require_atomic?(false)

      accept([
        :canceled_reason,
        :current_contract_change_id,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at
      ])

      change(
        {Store.Support.Governance.TransitionState,
         target: :canceled, state_attribute: :status, lock_attribute: nil}
      )

      change(fn changeset, _context ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        changeset
        |> Ash.Changeset.change_attribute(:cancel_at_period_end, false)
        |> Ash.Changeset.change_attribute(:cancel_at_period_end_at, nil)
        |> Ash.Changeset.change_attribute(:cancel_after_renewal_attempt_id, nil)
        |> Ash.Changeset.change_attribute(:canceled_at, now)
        |> Ash.Changeset.change_attribute(:ended_at, now)
        |> Ash.Changeset.change_attribute(:next_renewal_at, nil)
        |> Ash.Changeset.change_attribute(:next_retry_at, nil)
        |> Ash.Changeset.change_attribute(:retry_suppressed_at, nil)
        |> Ash.Changeset.change_attribute(:current_dunning_renewal_attempt_id, nil)
      end)

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :scheduled_boundary_cancellation_transition do
      public?(false)
      require_atomic?(false)

      accept([:canceled_reason])

      change(
        {Store.Support.Governance.TransitionState,
         target: :canceled, state_attribute: :status, lock_attribute: nil}
      )

      change(fn changeset, _context ->
        boundary_at = Ash.Changeset.get_data(changeset, :cancel_at_period_end_at)

        changeset
        |> Ash.Changeset.change_attribute(:cancel_at_period_end, false)
        |> Ash.Changeset.change_attribute(:cancel_at_period_end_at, nil)
        |> Ash.Changeset.change_attribute(:cancel_after_renewal_attempt_id, nil)
        |> Ash.Changeset.change_attribute(:canceled_at, boundary_at)
        |> Ash.Changeset.change_attribute(:ended_at, boundary_at)
        |> Ash.Changeset.change_attribute(:next_renewal_at, nil)
        |> Ash.Changeset.change_attribute(:next_retry_at, nil)
        |> Ash.Changeset.change_attribute(:retry_suppressed_at, nil)
        |> Ash.Changeset.change_attribute(:current_dunning_renewal_attempt_id, nil)
      end)

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :extend_period do
      require_atomic?(false)

      argument :recovery_renewal_attempt_id, :uuid do
        allow_nil?(true)
        public?(false)
      end

      validate(fn changeset, _context ->
        source_status = Ash.Changeset.get_data(changeset, :status)

        current_attempt_id =
          Ash.Changeset.get_data(changeset, :current_dunning_renewal_attempt_id)

        recovery_attempt_id = Ash.Changeset.get_argument(changeset, :recovery_renewal_attempt_id)

        if not is_nil(current_attempt_id) and
             (source_status not in [:past_due, :suspended] or
                recovery_attempt_id != current_attempt_id) do
          {:error,
           field: :current_dunning_renewal_attempt_id,
           message: "paid recovery does not match the current dunning RenewalAttempt"}
        else
          :ok
        end
      end)

      accept([
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at,
        :cancel_at_period_end_at,
        :cancel_after_renewal_attempt_id,
        :subscription_plan_id,
        :current_plan_revision_id,
        :variant_id,
        :quantity,
        :renewal_amount_minor,
        :renewal_currency,
        :membership_key,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(
        {Store.Support.Governance.TransitionState,
         target: :active, state_attribute: :status, lock_attribute: nil}
      )

      change(set_attribute(:past_due_since_at, nil))
      change(set_attribute(:failed_payment_boundary_at, nil))
      change(set_attribute(:current_dunning_renewal_attempt_id, nil))
      change(set_attribute(:billing_status_reason, nil))
      change(set_attribute(:dunning_attempt_count, 0))
      change(set_attribute(:next_retry_at, nil))
      change(set_attribute(:retry_suppressed_at, nil))
      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :queue_change do
      public?(false)
      require_atomic?(false)

      accept([
        :current_contract_change_id,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :consume_contract_change_for_renewal do
      public?(false)
      require_atomic?(false)

      accept([
        :current_contract_change_id,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at
      ])

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :mark_expired_transition do
      require_atomic?(false)
      accept([:canceled_reason])

      change(
        {Store.Support.Governance.TransitionState,
         target: :expired, state_attribute: :status, lock_attribute: nil}
      )

      change(fn changeset, _context ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        changeset
        |> Ash.Changeset.change_attribute(:ended_at, now)
        |> Ash.Changeset.change_attribute(:next_renewal_at, nil)
        |> Ash.Changeset.change_attribute(:next_retry_at, nil)
        |> Ash.Changeset.change_attribute(:retry_suppressed_at, nil)
        |> Ash.Changeset.change_attribute(:current_dunning_renewal_attempt_id, nil)
      end)

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :set_provider_billing_reference do
      require_atomic?(false)

      accept([
        :provider_customer_ref,
        :provider_billing_ref,
        :stored_payment_method_id,
        :billing_status_reason,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(Store.Subscriptions.Changes.AcquireSubscriptionBindingAuthority)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :payment_method_setup_generation,
          changeset.data.payment_method_setup_generation + 1
        )
      end)

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end

    update :advance_payment_method_setup_generation do
      description(
        "Supersedes older setups before provider creation, including if creation fails."
      )

      public?(false)
      require_atomic?(false)
      accept([])

      change(Store.Subscriptions.Changes.AcquireSubscriptionBindingAuthority)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :payment_method_setup_generation,
          changeset.data.payment_method_setup_generation + 1
        )
      end)

      change(Store.Subscriptions.Changes.OptimisticAggregateLock)
    end
  end

  code_interface do
    define(:list_for_user, action: :read_for_user)
    define(:get_for_user, action: :get_for_user, args: [:id])
    define(:list_for_admin, action: :read_for_admin)
    define(:get_for_admin, action: :get_for_admin, args: [:id])
    define(:list_due_for_system, action: :read_due_for_system, args: [:now, :limit])

    define(:list_due_failed_payment_boundaries_for_system,
      action: :read_due_failed_payment_boundary_for_system,
      args: [:now, :after_boundary_at, :after_id, :limit]
    )

    define(:list_due_scheduled_cancellations_for_system,
      action: :read_due_scheduled_cancellations_for_system,
      args: [:now, :after_boundary_at, :after_id, :limit]
    )

    define(:list_past_due_missing_boundaries_for_system,
      action: :read_past_due_missing_boundary_for_system,
      args: [:after_id, :limit]
    )
  end

  postgres do
    table("subscriptions")
    repo(Store.Repo)

    check_constraints do
      check_constraint(
        :cancel_at_period_end,
        "subscriptions_scheduled_cancellation_target_check",
        check: """
        (cancel_at_period_end = false AND cancel_at_period_end_at IS NULL AND
          cancel_after_renewal_attempt_id IS NULL) OR
        (cancel_at_period_end = true AND
          num_nonnulls(cancel_at_period_end_at, cancel_after_renewal_attempt_id) = 1)
        """
      )

      check_constraint(
        :failed_payment_boundary_at,
        "subscriptions_active_failed_payment_boundary_check",
        check: "NOT (status = 'active' AND failed_payment_boundary_at IS NOT NULL)"
      )

      check_constraint(
        :current_dunning_renewal_attempt_id,
        "subscriptions_current_dunning_renewal_attempt_status_check",
        check: "current_dunning_renewal_attempt_id IS NULL OR status IN ('past_due', 'suspended')"
      )
    end

    references do
      reference(:cancel_after_renewal_attempt, on_delete: :restrict)
      reference(:current_dunning_renewal_attempt, on_delete: :restrict)
      reference(:current_plan_revision, on_delete: :restrict)
      reference(:current_contract_change, on_delete: :restrict)
    end

    custom_indexes do
      index([:user_id, :status], name: "subscriptions_user_id_status_index")
      index([:status, :next_renewal_at], name: "subscriptions_status_next_renewal_at_index")
      index([:status, :next_retry_at], name: "subscriptions_status_next_retry_at_index")

      index([:failed_payment_boundary_at, :id],
        where: "status = 'past_due' AND failed_payment_boundary_at IS NOT NULL",
        name: "subscriptions_failed_payment_boundary_due_index"
      )

      index([:cancel_at_period_end_at, :id],
        where:
          "status = 'active' AND cancel_at_period_end = true AND cancel_at_period_end_at IS NOT NULL",
        name: "subscriptions_active_scheduled_cancellation_due_index"
      )

      index([:ended_at, :id],
        where: "status = 'canceled' AND canceled_reason = 'canceled_period_end'",
        name: "subscriptions_scheduled_cancellation_notification_replay_index"
      )

      index([:id],
        where: "status = 'past_due' AND failed_payment_boundary_at IS NULL",
        name: "subscriptions_past_due_missing_boundary_index"
      )

      index([:provider, :provider_subscription_id], name: "subscriptions_provider_ref_index")
      index([:source_order_line_item_id], name: "subscriptions_source_order_line_item_id_index")
      index([:subscription_plan_id], name: "subscriptions_subscription_plan_id_index")
      index([:current_plan_revision_id], name: "subscriptions_current_plan_revision_id_index")

      index([:current_contract_change_id],
        name: "subscriptions_current_contract_change_id_index"
      )

      index([:variant_id], name: "subscriptions_variant_id_index")
      index([:pending_subscription_plan_id], name: "subscriptions_pending_plan_id_index")
      index([:pending_variant_id], name: "subscriptions_pending_variant_id_index")
      index([:user_id, :membership_key], name: "subscriptions_user_membership_key_index")
      index([:stored_payment_method_id], name: "subscriptions_stored_payment_method_id_index")
    end
  end

  policies do
    policy action(:read_access_inventory_window_for_system) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    bypass action([
             :read,
             :read_for_admin,
             :get_for_admin,
             :read_due_for_system,
             :read_due_failed_payment_boundary_for_system,
             :read_due_scheduled_cancellations_for_system,
             :read_past_due_missing_boundary_for_system
           ]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:read_for_user, :get_for_user]) do
      access_type(:runtime)
      authorize_if(always())
    end

    policy action([
             :cancel_at_period_end_transition,
             :rescind_cancel_at_period_end_transition,
             :cancel_now_transition,
             :scheduled_boundary_cancellation_transition
           ]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action([:queue_change]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action([
             :activate_now,
             :mark_past_due_transition,
             :mark_suspended_transition,
             :extend_period,
             :mark_expired_transition,
             :set_provider_billing_reference,
             :consume_contract_change_for_renewal
           ]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:advance_payment_method_setup_generation) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end
  end
end
