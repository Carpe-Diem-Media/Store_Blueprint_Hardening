defmodule Store.Orders.OrderLineComponentAllocation do
  @moduledoc """
  Immutable attribution of an accepted order line to one component instance.

  The offer component defines the accepted price basis. The instance UUID is
  a separate commercial identity and does not identify the definition.
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Orders

  attributes do
    uuid_v7_primary_key(:id)

    attribute :component_instance_id, Ash.Type.UUIDv7 do
      allow_nil? false
      public? true
    end

    attribute :evaluation_line_id, Ash.Type.UUIDv7 do
      allow_nil? false
      public? true
    end

    attribute :gross_minor, :integer do
      allow_nil? false
      public? true
    end

    attribute :discount_minor, :integer do
      allow_nil? false
      public? true
    end

    attribute :net_minor, :integer do
      allow_nil? false
      public? true
    end

    attribute :tax_minor, :integer do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :allocation_set, Store.Orders.OrderLineComponentAllocationSet do
      allow_nil? false
      public? true
    end

    belongs_to :order_line_item, Store.Orders.OrderLineItem do
      allow_nil? false
      public? true
    end

    belongs_to :offer_component, Store.Pricing.MembershipOfferRevisionComponent do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :set_instance, [:allocation_set_id, :component_instance_id]
    identity :set_definition, [:allocation_set_id, :offer_component_id]
  end

  actions do
    defaults [:read]
  end

  postgres do
    table "order_line_component_allocations"
    repo Store.Repo

    references do
      reference :allocation_set, on_delete: :restrict
      reference :order_line_item, on_delete: :restrict
      reference :offer_component, on_delete: :restrict
    end

    custom_indexes do
      index [:order_line_item_id]
      index [:offer_component_id]
    end

    check_constraints do
      check_constraint :gross_minor, "order_line_component_allocations_amounts_check",
        check: "gross_minor >= 0 AND discount_minor >= 0 AND net_minor >= 0 AND tax_minor >= 0 AND discount_minor <= gross_minor AND net_minor = gross_minor - discount_minor"
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if context_equals(:system?, true)
      authorize_if {Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]}
      authorize_if expr(allocation_set.order.user_id == ^actor(:id))
    end
  end
end
