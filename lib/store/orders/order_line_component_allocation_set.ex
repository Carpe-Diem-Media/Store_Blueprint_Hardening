defmodule Store.Orders.OrderLineComponentAllocationSet do
  @moduledoc """
  Durable accepted component-allocation evidence for one commercial occurrence.

  Proposed and validated evidence is transaction-local. Accepted evidence is
  terminal and protected by database constraints and triggers.
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Orders

  attributes do
    uuid_v7_primary_key(:id)

    attribute :occurrence_key, Ash.Type.UUIDv7 do
      allow_nil?(false)
      public?(true)
    end

    attribute :target_fingerprint, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :allocation_fingerprint, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :pricing_fingerprint, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :allocation_rule_version, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :source_eligibility_key, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :source_rule_version, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tax_context, :map do
      description("""
      membership-tax-v1 frozen enabled-only evidence. The envelope binds order,
      occurrence, currency, canonical country/region and tax-as-of. Each unique
      persisted line includes category, net/tax minor amounts, selected rate
      identity/code/basis points and its complete selection-source snapshot.
      PostgreSQL verifies source consistency at COMMIT; trusted Pricing writer
      invocation and winning-candidate selection are a separate acceptance gate.
      """)

      allow_nil?(false)
      public?(true)
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end
  end

  relationships do
    belongs_to :order, Store.Orders.Order do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :offer_revision, Store.Pricing.MembershipOfferRevision do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :source_adjustment, Store.Orders.OrderAdjustment do
      allow_nil?(true)
      public?(true)
    end
  end

  identities do
    identity(:order_occurrence, [:order_id, :occurrence_key])
  end

  actions do
    defaults([:read])
  end

  postgres do
    table("order_line_component_allocation_sets")
    repo(Store.Repo)

    references do
      reference(:order, on_delete: :restrict)
      reference(:offer_revision, on_delete: :restrict)
      reference(:source_adjustment, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:id, "order_line_component_allocation_sets_id_v7_check",
        check:
          "substring(id::text FROM 15 FOR 1) = '7' AND substring(id::text FROM 20 FOR 1) IN ('8','9','a','b')"
      )

      check_constraint(
        :occurrence_key,
        "order_line_component_allocation_sets_occurrence_key_v7_check",
        check:
          "substring(occurrence_key::text FROM 15 FOR 1) = '7' AND substring(occurrence_key::text FROM 20 FOR 1) IN ('8','9','a','b')"
      )
    end

    custom_indexes do
      index([:offer_revision_id])
      index([:source_adjustment_id])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
      authorize_if(expr(order.user_id == ^actor(:id)))
    end
  end
end
