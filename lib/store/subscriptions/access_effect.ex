defmodule Store.Subscriptions.AccessEffect do
  @moduledoc """
  Durable desired access outcome and lifecycle obligation for one Subscription source version.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput

  @fingerprint_domain :store_subscriptions_access_effect_target
  @fingerprint_version 2

  attributes do
    uuid_v7_primary_key(:id)

    attribute :status, Store.Subscriptions.Types.AccessEffectStatus do
      allow_nil?(false)
      default(:required)
      public?(false)
    end

    attribute :source_version, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(false)
    end

    attribute :disposition, Store.Subscriptions.Types.AccessDisposition do
      allow_nil?(false)
      public?(false)
    end

    attribute :entitlement_kind, Store.Entitlements.Types.EntitlementKind do
      allow_nil?(true)
      public?(false)
    end

    attribute :entitlement_scope_key, :string do
      allow_nil?(true)
      constraints(min_length: 1, max_length: 255)
      public?(false)
    end

    attribute :valid_from_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :valid_until_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :target_fingerprint, :string do
      allow_nil?(false)
      constraints(min_length: 64, max_length: 64)
      public?(false)
    end

    attribute :projection_user_ids, {:array, :uuid} do
      allow_nil?(true)
      public?(false)
    end

    attribute :projection_delivered_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :source_order_line_item, Store.Orders.OrderLineItem do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :contract_change, Store.Subscriptions.ContractChange do
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :plan_revision, Store.Subscriptions.PlanRevision do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_subscription_source_version, [:subscription_id, :source_version])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    action :read_applied_verification_window_for_system, {:array, :map} do
      public?(false)
      transaction?(false)

      argument :as_of, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_inserted_at, :utc_datetime_usec do
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

      run(Store.Subscriptions.Actions.ReadAppliedAccessVerificationWindow)
    end

    read :read_for_subscription_source_version do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      argument :source_version, :integer do
        allow_nil?(false)
      end

      filter(
        expr(
          subscription_id == ^arg(:subscription_id) and
            source_version == ^arg(:source_version)
        )
      )
    end

    read :read_current_for_subscription do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(subscription_id == ^arg(:subscription_id)))
      prepare(build(sort: [source_version: :desc]))
    end

    read :read_recoverable_effective_for_system do
      argument :through_updated_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_updated_at, :utc_datetime_usec do
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
          disposition == :effective and
            (status == :required or status == :pending or status == :failed_retryable) and
            updated_at <= ^arg(:through_updated_at) and
            (is_nil(^arg(:after_updated_at)) or
               updated_at > ^arg(:after_updated_at) or
               (updated_at == ^arg(:after_updated_at) and id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [updated_at: :asc, id: :asc], limit: arg(:limit)))
    end

    read :read_recoverable_non_effective_for_system do
      argument :through_updated_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_updated_at, :utc_datetime_usec do
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
          disposition == :non_effective and
            (status == :required or status == :pending or status == :failed_retryable) and
            updated_at <= ^arg(:through_updated_at) and
            (is_nil(^arg(:after_updated_at)) or
               updated_at > ^arg(:after_updated_at) or
               (updated_at == ^arg(:after_updated_at) and id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [updated_at: :asc, id: :asc], limit: arg(:limit)))
    end

    read :read_target_order_candidates_for_system do
      argument :through_inserted_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_inserted_at, :utc_datetime_usec do
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
          (status == :required or status == :pending or status == :failed_retryable) and
            inserted_at <= ^arg(:through_inserted_at) and
            (is_nil(^arg(:after_inserted_at)) or
               inserted_at > ^arg(:after_inserted_at) or
               (inserted_at == ^arg(:after_inserted_at) and id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [inserted_at: :asc, id: :asc], limit: arg(:limit)))
    end

    read :read_pending_projection_repair_for_system do
      argument :through_inserted_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :after_inserted_at, :utc_datetime_usec do
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
          status == :applied and not is_nil(projection_user_ids) and
            is_nil(projection_delivered_at) and
            inserted_at <= ^arg(:through_inserted_at) and
            (is_nil(^arg(:after_inserted_at)) or
               inserted_at > ^arg(:after_inserted_at) or
               (inserted_at == ^arg(:after_inserted_at) and id > ^arg(:after_id)))
        )
      )

      prepare(build(sort: [inserted_at: :asc, id: :asc], limit: arg(:limit)))
    end

    create :establish do
      public?(false)

      accept([
        :subscription_id,
        :source_order_line_item_id,
        :contract_change_id,
        :plan_revision_id,
        :source_version,
        :disposition,
        :entitlement_kind,
        :entitlement_scope_key,
        :valid_from_at,
        :valid_until_at
      ])

      change(set_attribute(:status, :required))
      change(&set_target_fingerprint/2)
    end

    update :mark_pending_from_required do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :required)))
      change(set_attribute(:status, :pending))
    end

    update :mark_applied do
      public?(false)
      require_atomic?(false)
      accept([:projection_user_ids])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :applied))
    end

    update :mark_projection_delivered do
      public?(false)
      require_atomic?(false)
      accept([:projection_delivered_at])
      change(filter(expr(status == :applied and not is_nil(projection_user_ids))))
    end

    update :mark_failed_retryable do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :failed_retryable))
    end

    update :retry_to_pending do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :failed_retryable)))
      change(set_attribute(:status, :pending))
    end

    update :supersede do
      public?(false)
      require_atomic?(false)
      accept([])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :superseded))
    end
  end

  postgres do
    table("access_effects")
    repo(Store.Repo)

    check_constraints do
      check_constraint(:status, "access_effects_status_value_check",
        check: "status IN ('required', 'pending', 'applied', 'failed_retryable', 'superseded')"
      )

      check_constraint(:source_version, "access_effects_source_version_check",
        check: "source_version >= 1"
      )

      check_constraint(:disposition, "access_effects_disposition_value_check",
        check: "disposition IN ('effective', 'non_effective')"
      )

      check_constraint(:entitlement_scope_key, "access_effects_entitlement_pair_complete_check",
        check:
          "(entitlement_kind IS NULL AND entitlement_scope_key IS NULL) OR " <>
            "(entitlement_kind IS NOT NULL AND entitlement_scope_key IS NOT NULL)"
      )

      check_constraint(:target_fingerprint, "access_effects_fingerprint_length_check",
        check: "length(target_fingerprint) = 64"
      )

      check_constraint(
        :projection_delivered_at,
        "access_effects_projection_delivery_evidence_check",
        check: "projection_delivered_at IS NULL OR projection_user_ids IS NOT NULL"
      )
    end

    custom_indexes do
      index([:updated_at, :id],
        where:
          "disposition = 'non_effective' AND status IN ('required', 'pending', 'failed_retryable')",
        name: "access_effects_non_effective_recovery_index"
      )

      index([:updated_at, :id],
        where:
          "disposition = 'effective' AND status IN ('required', 'pending', 'failed_retryable')",
        name: "access_effects_effective_recovery_index"
      )

      index([:inserted_at, :id],
        where: "status IN ('required', 'pending', 'failed_retryable')",
        name: "access_effects_target_order_reconciliation_index"
      )

      index([:inserted_at, :id],
        where:
          "status = 'applied' AND projection_user_ids IS NOT NULL AND projection_delivered_at IS NULL",
        name: "access_effects_projection_repair_index"
      )

      index([:inserted_at, :id],
        where: "status = 'applied'",
        name: "access_effects_applied_verification_index",
        concurrently: true
      )
    end
  end

  policies do
    policy action(:read_applied_verification_window_for_system) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end
  end

  @doc false
  @spec target_fingerprint(EstablishAccessEffectInput.t() | map()) :: String.t()
  def target_fingerprint(%EstablishAccessEffectInput{} = input) do
    target_fingerprint(Map.from_struct(input))
  end

  def target_fingerprint(fields) when is_map(fields) do
    descriptor =
      {@fingerprint_domain, @fingerprint_version,
       uuid_bytes!(Map.fetch!(fields, :subscription_id)), Map.fetch!(fields, :source_version),
       Map.fetch!(fields, :disposition), Map.fetch!(fields, :entitlement_kind),
       Map.fetch!(fields, :entitlement_scope_key),
       datetime_micros(Map.get(fields, :valid_from_at)),
       datetime_micros(Map.fetch!(fields, :valid_until_at)),
       uuid_bytes!(Map.fetch!(fields, :source_order_line_item_id)),
       optional_uuid_bytes(Map.fetch!(fields, :contract_change_id)),
       uuid_bytes!(Map.fetch!(fields, :plan_revision_id))}

    encode_fingerprint(descriptor)
  end

  @doc false
  @spec legacy_target_fingerprint_v1(EstablishAccessEffectInput.t() | map()) :: String.t()
  def legacy_target_fingerprint_v1(%EstablishAccessEffectInput{} = input) do
    legacy_target_fingerprint_v1(Map.from_struct(input))
  end

  def legacy_target_fingerprint_v1(fields) when is_map(fields) do
    descriptor =
      {@fingerprint_domain, 1, uuid_bytes!(Map.fetch!(fields, :subscription_id)),
       Map.fetch!(fields, :source_version), Map.fetch!(fields, :disposition),
       Map.fetch!(fields, :entitlement_kind), Map.fetch!(fields, :entitlement_scope_key),
       datetime_micros(Map.fetch!(fields, :valid_until_at)),
       uuid_bytes!(Map.fetch!(fields, :source_order_line_item_id)),
       optional_uuid_bytes(Map.fetch!(fields, :contract_change_id)),
       uuid_bytes!(Map.fetch!(fields, :plan_revision_id))}

    encode_fingerprint(descriptor)
  end

  @doc false
  @spec persisted_fingerprint_status(t()) :: :v2_match | :v1_legacy_match | :mismatch
  def persisted_fingerprint_status(%{__struct__: __MODULE__} = effect) do
    if effect.target_fingerprint == target_fingerprint(effect) do
      :v2_match
    else
      persisted_v1_fingerprint_status(effect)
    end
  rescue
    _error in [ArgumentError, MatchError] -> :mismatch
  end

  defp persisted_v1_fingerprint_status(%{valid_from_at: nil} = effect) do
    if effect.target_fingerprint == legacy_target_fingerprint_v1(effect) do
      :v1_legacy_match
    else
      :mismatch
    end
  end

  defp persisted_v1_fingerprint_status(_effect), do: :mismatch

  defp encode_fingerprint(descriptor) do
    :crypto.hash(:sha256, :erlang.term_to_binary(descriptor, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp uuid_bytes!(uuid) do
    {:ok, bytes} = Ecto.UUID.dump(uuid)
    bytes
  end

  defp optional_uuid_bytes(nil), do: nil
  defp optional_uuid_bytes(uuid), do: uuid_bytes!(uuid)

  defp datetime_micros(nil), do: nil
  defp datetime_micros(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp set_target_fingerprint(changeset, _context) do
    fields =
      Map.new(
        [
          :subscription_id,
          :source_version,
          :disposition,
          :entitlement_kind,
          :entitlement_scope_key,
          :valid_from_at,
          :valid_until_at,
          :source_order_line_item_id,
          :contract_change_id,
          :plan_revision_id
        ],
        fn field -> {field, Ash.Changeset.get_attribute(changeset, field)} end
      )

    if valid_fingerprint_fields?(fields) do
      Ash.Changeset.change_attribute(changeset, :target_fingerprint, target_fingerprint(fields))
    else
      Ash.Changeset.add_error(changeset,
        field: :target_fingerprint,
        message: "cannot fingerprint incomplete AccessEffect target evidence"
      )
    end
  end

  defp valid_fingerprint_fields?(fields) do
    Enum.all?(
      [:subscription_id, :source_order_line_item_id, :plan_revision_id],
      &(is_binary(Map.get(fields, &1)) and Map.get(fields, &1) != "")
    ) and is_integer(fields.source_version) and fields.source_version > 0 and
      not is_nil(fields.disposition)
  end
end
