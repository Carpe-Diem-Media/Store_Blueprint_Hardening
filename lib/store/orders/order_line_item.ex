defmodule Store.Orders.OrderLineItem do
  @moduledoc """
  Immutable order line-item snapshot evidence.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false,
    domain: Store.Orders

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.Authorization
  alias Store.Orders.Order

  attributes do
    uuid_v7_primary_key(:id)

    attribute :line_no, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :quantity, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :unit_price_minor, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :line_total_minor, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :sku_snapshot, :string do
      allow_nil?(false)
      default("")
      public?(true)
    end

    attribute :product_title_snapshot, :string do
      allow_nil?(false)
      default("")
      public?(true)
    end

    attribute :variant_title_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :variant_id_snapshot, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :membership_occurrence_key_snapshot, Ash.Type.UUIDv7 do
      allow_nil?(true)
      public?(true)
    end

    attribute :subscription_plan_id_snapshot, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :subscription_plan_revision_id_snapshot, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :subscription_plan_key_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :subscription_interval_unit_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :subscription_interval_count_snapshot, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :discount_allocated_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :net_line_total_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :tax_category_snapshot, :string do
      allow_nil?(false)
      default("STANDARD")
      public?(true)
    end

    attribute :tax_rate_id_snapshot, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :tax_rate_code_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tax_rate_bps_snapshot, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :tax_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, Store.Orders.Order do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :subscription_plan_revision_snapshot, Store.Subscriptions.PlanRevision do
      source_attribute(:subscription_plan_revision_id_snapshot)
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :membership_offer_revision_snapshot, Store.Pricing.MembershipOfferRevision do
      source_attribute(:membership_offer_revision_id_snapshot)
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_line_no_per_order, [:order_id, :line_no])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)

      prepare(fn query, context ->
        actor = Map.get(context, :actor)
        actor_id = actor && Map.get(actor, :id)
        source_context = Map.get(context, :source_context, %{})
        system_context? = get_in(source_context, [:system?]) == true
        authorization_disabled? = Map.get(context, :authorize?) == false

        cond do
          system_context? or authorization_disabled? ->
            query

          Authorization.has_any_role?(actor, [:super_admin, :admin, :support]) ->
            query

          is_binary(actor_id) ->
            visible_order_ids = visible_order_ids(actor_id)
            Ash.Query.filter(query, expr(order_id in ^visible_order_ids))

          true ->
            Ash.Query.filter(query, expr(false))
        end
      end)
    end

    create :create do
      accept([
        :order_id,
        :line_no,
        :currency,
        :quantity,
        :unit_price_minor,
        :line_total_minor,
        :sku_snapshot,
        :product_title_snapshot,
        :variant_title_snapshot,
        :variant_id_snapshot,
        :subscription_plan_id_snapshot,
        :subscription_plan_revision_id_snapshot,
        :subscription_plan_key_snapshot,
        :subscription_interval_unit_snapshot,
        :subscription_interval_count_snapshot,
        :discount_allocated_minor,
        :net_line_total_minor,
        :tax_category_snapshot,
        :tax_rate_id_snapshot,
        :tax_rate_code_snapshot,
        :tax_rate_bps_snapshot,
        :tax_minor
      ])
    end
  end

  postgres do
    table("order_line_items")
    repo(Store.Repo)

    references do
      reference(:subscription_plan_revision_snapshot, on_delete: :restrict)
      reference(:membership_offer_revision_snapshot, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(
        :membership_occurrence_key_snapshot,
        "order_line_items_membership_evidence_check",
        check:
          "(membership_offer_revision_id_snapshot IS NULL AND membership_occurrence_key_snapshot IS NULL) OR (membership_offer_revision_id_snapshot IS NOT NULL AND membership_occurrence_key_snapshot IS NOT NULL AND quantity = 1 AND substring(membership_occurrence_key_snapshot::text FROM 15 FOR 1) = '7' AND substring(membership_occurrence_key_snapshot::text FROM 20 FOR 1) IN ('8','9','a','b'))"
      )
    end

    custom_indexes do
      index([:order_id], name: "order_line_items_order_id_index")

      index([:order_id, :membership_occurrence_key_snapshot],
        name: "order_line_items_membership_occurrence_index"
      )

      index([:tax_rate_id_snapshot], name: "order_line_items_tax_rate_id_snapshot_index")
      index([:variant_id_snapshot], name: "order_line_items_variant_id_snapshot_index")

      index([:subscription_plan_id_snapshot],
        name: "order_line_items_subscription_plan_id_snapshot_index"
      )

      index([:subscription_plan_revision_id_snapshot],
        name: "order_line_items_subscription_plan_revision_id_snapshot_index"
      )
    end
  end

  policies do
    policy action(:read) do
      access_type(:runtime)
      authorize_if(actor_present())
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp visible_order_ids(actor_id) do
    Order
    |> Ash.Query.filter(expr(user_id == ^actor_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false)
    |> Enum.map(& &1.id)
  end
end
