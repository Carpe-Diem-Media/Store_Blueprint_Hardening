defmodule Store.Subscriptions.RenewalAttempt do
  @moduledoc """
  Idempotency anchor for one subscription renewal per billing period.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :period_start_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :period_end_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :plan_revision_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :variant_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :quantity, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(false)
    end

    attribute :amount_minor, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(false)
    end

    attribute :currency, :string do
      allow_nil?(true)
      constraints(min_length: 3, max_length: 3)
      public?(false)
    end

    attribute :contract_change_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :expected_subscription_version, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(false)
    end

    attribute :charged_contract_version, :integer do
      allow_nil?(true)
      public?(false)
    end

    attribute :charged_contract_snapshot, :map do
      allow_nil?(true)
      public?(false)
    end

    attribute :renewal_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Subscriptions.Types.RenewalAttemptStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :order_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :payment_intent_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_message, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :attempt_no, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :plan_revision, Store.Subscriptions.PlanRevision do
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :contract_change, Store.Subscriptions.ContractChange do
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_subscription_renewal_key, [:subscription_id, :renewal_key])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_subscription do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(subscription_id == ^arg(:subscription_id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 100, max_page_size: 500)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :create_or_reuse do
      public?(false)

      accept([
        :subscription_id,
        :period_start_at,
        :period_end_at,
        :renewal_key,
        :plan_revision_id,
        :variant_id,
        :quantity,
        :amount_minor,
        :currency,
        :contract_change_id,
        :expected_subscription_version,
        :charged_contract_version,
        :charged_contract_snapshot,
        :status,
        :order_id,
        :payment_intent_id,
        :failure_code,
        :failure_message,
        :attempt_no
      ])

      upsert?(true)
      upsert_identity(:unique_subscription_renewal_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_succeeded do
      require_atomic?(false)
      accept([:order_id, :payment_intent_id])
      change(set_attribute(:status, :succeeded))
      change(set_attribute(:failure_code, nil))
      change(set_attribute(:failure_message, nil))
    end

    update :mark_processing do
      require_atomic?(false)
      accept([:order_id, :payment_intent_id])

      change(
        filter(
          expr(
            status != :succeeded and
              (is_nil(failure_code) or failure_code != "RENEWAL_AUTHORITY_WITHDRAWN")
          )
        )
      )

      change(set_attribute(:status, :processing))
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:failure_code, :failure_message, :attempt_no])

      change(
        filter(
          expr(
            status != :succeeded and
              (is_nil(failure_code) or failure_code != "RENEWAL_AUTHORITY_WITHDRAWN")
          )
        )
      )

      change(set_attribute(:status, :failed))
    end

    update :mark_authority_withdrawn do
      require_atomic?(false)
      accept([:failure_message])

      change(
        filter(
          expr(
            status != :succeeded and
              (status != :failed or is_nil(failure_code) or failure_code != "PAYMENT_FAILED")
          )
        )
      )

      change(set_attribute(:status, :failed))
      change(set_attribute(:failure_code, "RENEWAL_AUTHORITY_WITHDRAWN"))
    end
  end

  code_interface do
    define(:list_for_subscription, action: :read_for_subscription, args: [:subscription_id])
    define(:list_for_admin, action: :read_for_admin)
  end

  postgres do
    table("renewal_attempts")
    repo(Store.Repo)

    references do
      reference(:plan_revision, on_delete: :restrict)
      reference(:contract_change, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(
        :charged_contract_version,
        "renewal_attempts_charged_contract_completeness_check",
        check: """
          (
            charged_contract_version IS NULL
            AND plan_revision_id IS NULL
            AND variant_id IS NULL
            AND quantity IS NULL
            AND amount_minor IS NULL
            AND currency IS NULL
            AND contract_change_id IS NULL
            AND expected_subscription_version IS NULL
            AND charged_contract_snapshot IS NULL
          ) OR (
            charged_contract_version = 1
            AND plan_revision_id IS NOT NULL
            AND variant_id IS NOT NULL
            AND quantity IS NOT NULL AND quantity > 0
            AND amount_minor IS NOT NULL AND amount_minor >= 0
            AND currency IS NOT NULL AND currency ~ '^[A-Z]{3}$'
            AND expected_subscription_version IS NOT NULL
              AND expected_subscription_version > 0
            AND charged_contract_snapshot IS NOT NULL
              AND jsonb_typeof(charged_contract_snapshot) = 'object'
              AND charged_contract_snapshot ?& ARRAY[
                'version', 'subscription_plan_key',
                'interval_unit', 'interval_count', 'trial_days', 'anchor_mode',
                'anchor_day_of_month', 'billing_timezone', 'term_mode', 'term_cycles',
                'term_end_at', 'access_on_past_due', 'access_on_cancel',
                'grace_period_days', 'max_retry_attempts', 'retry_schedule_hours',
                'entitlement_kind', 'entitlement_scope_key'
              ]
              AND jsonb_typeof(charged_contract_snapshot->'version') = 'number'
              AND charged_contract_snapshot->>'version' = '1'
              AND jsonb_typeof(charged_contract_snapshot->'subscription_plan_key') = 'string'
              AND jsonb_typeof(charged_contract_snapshot->'interval_unit') = 'string'
              AND charged_contract_snapshot->>'interval_unit' IN ('day', 'month', 'year')
              AND jsonb_typeof(charged_contract_snapshot->'interval_count') = 'number'
              AND (charged_contract_snapshot->>'interval_count')::numeric > 0
              AND (charged_contract_snapshot->>'interval_count')::numeric =
                trunc((charged_contract_snapshot->>'interval_count')::numeric)
              AND (
                jsonb_typeof(charged_contract_snapshot->'trial_days') = 'null'
                OR (
                  jsonb_typeof(charged_contract_snapshot->'trial_days') = 'number'
                  AND (charged_contract_snapshot->>'trial_days')::numeric >= 0
                  AND (charged_contract_snapshot->>'trial_days')::numeric =
                    trunc((charged_contract_snapshot->>'trial_days')::numeric)
                )
              )
              AND jsonb_typeof(charged_contract_snapshot->'anchor_mode') = 'string'
              AND charged_contract_snapshot->>'anchor_mode'
                IN ('start_anniversary', 'fixed_day_of_month')
              AND jsonb_typeof(charged_contract_snapshot->'billing_timezone') = 'string'
              AND charged_contract_snapshot->>'billing_timezone' <> ''
              AND jsonb_typeof(charged_contract_snapshot->'term_mode') = 'string'
              AND charged_contract_snapshot->>'term_mode'
                IN ('until_canceled', 'fixed_cycles', 'fixed_end_at')
              AND (
                jsonb_typeof(charged_contract_snapshot->'anchor_day_of_month') = 'null'
                OR (
                  jsonb_typeof(charged_contract_snapshot->'anchor_day_of_month') = 'number'
                  AND (charged_contract_snapshot->>'anchor_day_of_month')::numeric BETWEEN 1 AND 31
                  AND (charged_contract_snapshot->>'anchor_day_of_month')::numeric =
                    trunc((charged_contract_snapshot->>'anchor_day_of_month')::numeric)
                )
              )
              AND (
                jsonb_typeof(charged_contract_snapshot->'term_cycles') = 'null'
                OR (
                  jsonb_typeof(charged_contract_snapshot->'term_cycles') = 'number'
                  AND (charged_contract_snapshot->>'term_cycles')::numeric > 0
                  AND (charged_contract_snapshot->>'term_cycles')::numeric =
                    trunc((charged_contract_snapshot->>'term_cycles')::numeric)
                )
              )
              AND (
                jsonb_typeof(charged_contract_snapshot->'term_end_at') = 'null'
                OR jsonb_typeof(charged_contract_snapshot->'term_end_at') = 'string'
              )
              AND (
                charged_contract_snapshot->>'term_mode' <> 'fixed_cycles'
                OR jsonb_typeof(charged_contract_snapshot->'term_cycles') = 'number'
              )
              AND (
                charged_contract_snapshot->>'term_mode' <> 'fixed_end_at'
                OR jsonb_typeof(charged_contract_snapshot->'term_end_at') = 'string'
              )
              AND jsonb_typeof(charged_contract_snapshot->'access_on_past_due') = 'string'
              AND charged_contract_snapshot->>'access_on_past_due'
                IN ('keep_during_grace', 'remove_immediately')
              AND jsonb_typeof(charged_contract_snapshot->'access_on_cancel') = 'string'
              AND charged_contract_snapshot->>'access_on_cancel'
                IN ('keep_until_period_end', 'remove_immediately')
              AND jsonb_typeof(charged_contract_snapshot->'grace_period_days') = 'number'
              AND (charged_contract_snapshot->>'grace_period_days')::numeric >= 0
              AND (charged_contract_snapshot->>'grace_period_days')::numeric =
                trunc((charged_contract_snapshot->>'grace_period_days')::numeric)
              AND jsonb_typeof(charged_contract_snapshot->'max_retry_attempts') = 'number'
              AND (charged_contract_snapshot->>'max_retry_attempts')::numeric >= 0
              AND (charged_contract_snapshot->>'max_retry_attempts')::numeric =
                trunc((charged_contract_snapshot->>'max_retry_attempts')::numeric)
              AND jsonb_typeof(charged_contract_snapshot->'retry_schedule_hours') = 'array'
              AND NOT jsonb_path_exists(
                charged_contract_snapshot,
                '$.retry_schedule_hours[*] ? (@.type() != "number" || @ < 0 || @ != @.floor())'
              )
              AND (
                charged_contract_snapshot->'entitlement_kind' = 'null'::jsonb
                OR charged_contract_snapshot->>'entitlement_kind'
                  IN ('membership_access', 'digital_library', 'discount_tier')
              )
              AND (
                charged_contract_snapshot->'entitlement_scope_key' = 'null'::jsonb
                OR jsonb_typeof(charged_contract_snapshot->'entitlement_scope_key') = 'string'
              )
          )
        """
      )
    end

    custom_indexes do
      index([:subscription_id], name: "renewal_attempts_subscription_id_index")
      index([:inserted_at], name: "renewal_attempts_inserted_at_index")
      index([:status, :inserted_at], name: "renewal_attempts_status_inserted_at_index")
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
    end
  end
end
