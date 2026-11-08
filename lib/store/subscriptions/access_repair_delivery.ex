defmodule Store.Subscriptions.AccessRepairDelivery do
  @moduledoc """
  Records pending sender-side invalidation work for an already-applied AccessEffect repair.

  A generation is complete only after local cache invalidation and publication succeed for every
  stored recipient. This record does not prove that another node received or processed a message.
  It never owns or changes subscription grant authority.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  resource do
    description("""
    One durable delivery request for an AccessEffect. Its generation and complete recipient
    snapshot let recovery retry post-commit cache invalidation and PubSub publication without
    changing the APPLIED effect or its grants.
    """)
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :recipient_user_ids, {:array, :uuid} do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(false)
    end

    attribute :generation, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(false)
    end

    attribute :delivered_generation, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(false)
    end

    attribute :delivered_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :access_effect, Store.Subscriptions.AccessEffect do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_access_effect, [:access_effect_id])
  end

  actions do
    defaults([])

    read :read do
      public?(false)
      primary?(true)
    end

    read :read_for_access_effect do
      public?(false)

      argument :access_effect_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(access_effect_id == ^arg(:access_effect_id)))
    end

    create :create_for_system do
      public?(false)

      description(
        "Creates the first pending sender-side delivery generation for an APPLIED repair."
      )

      accept([:access_effect_id, :recipient_user_ids, :generation, :delivered_generation])
    end

    update :request_for_system do
      public?(false)
      require_atomic?(false)
      description("Stores the next complete recipient snapshot for a pending repair delivery.")
      accept([:recipient_user_ids, :generation])
    end

    update :acknowledge_for_system do
      public?(false)
      require_atomic?(true)
      description("Acknowledges only the delivered generation and exact recipient snapshot.")

      argument :generation, :integer do
        allow_nil?(false)
        constraints(min: 1)
      end

      argument :recipient_user_ids, {:array, :uuid} do
        allow_nil?(false)
      end

      argument :delivered_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      accept([])
      change(set_attribute(:delivered_generation, arg(:generation)))
      change(set_attribute(:delivered_at, arg(:delivered_at)))

      change(
        filter(
          expr(
            generation == ^arg(:generation) and
              recipient_user_ids == ^arg(:recipient_user_ids) and
              delivered_generation < generation
          )
        )
      )
    end

    action :read_pending_for_system, {:array, :map} do
      public?(false)
      transaction?(false)
      description("Reads a bounded keyset page of pending sender-side delivery obligations.")

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

      run(Store.Subscriptions.Actions.ReadPendingAccessRepairDeliveries)
    end
  end

  postgres do
    table("access_repair_deliveries")
    repo(Store.Repo)

    references do
      reference(:access_effect, on_delete: :delete)
    end

    check_constraints do
      check_constraint(:generation, "access_repair_deliveries_generation_check",
        check: "generation >= 1"
      )

      check_constraint(
        :delivered_generation,
        "access_repair_deliveries_generation_order_check",
        check: "delivered_generation >= 0 AND delivered_generation <= generation"
      )

      check_constraint(:delivered_at, "access_repair_deliveries_delivery_time_check",
        check:
          "(delivered_generation = 0 AND delivered_at IS NULL) OR " <>
            "(delivered_generation > 0 AND delivered_at IS NOT NULL)"
      )

      check_constraint(:recipient_user_ids, "access_repair_deliveries_recipient_count_check",
        check: "cardinality(recipient_user_ids) > 0"
      )
    end

    custom_indexes do
      index([:inserted_at, :id],
        where: "delivered_generation < generation",
        name: "access_repair_deliveries_pending_index"
      )
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:acknowledge_for_system) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:read_pending_for_system) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end
  end
end
