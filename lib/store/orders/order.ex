defmodule Store.Orders.Order do
  @moduledoc """
  Order lifecycle state machine with replay-safe transitions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Orders

  alias Store.Support.ID.OrderRef

  attributes do
    uuid_v7_primary_key(:id)

    attribute :state, Store.Orders.Types.OrderState do
      allow_nil?(false)
      default(:pending_payment)
      public?(true)
    end

    attribute :order_ref, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :checkout_key, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_rate_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_rate_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_quote_hash, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_quote_currency_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_quote_amount_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :shipping_weight_grams, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :shipping_method_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_rule_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_zone_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_effective_from, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_effective_to, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :currency_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :items_subtotal_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :shipping_total_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :grand_total_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :totals_finalized_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_cost_minor_original, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :shipping_cost_minor_effective, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :free_shipping_applied, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :free_shipping_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_tax_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :tax_total_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :billing_country_code, :string do
      allow_nil?(true)
    end

    attribute :billing_region_code, :string do
      allow_nil?(true)
    end

    attribute :shipping_country_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_region_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_postal_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_recipient_name, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_address_line1, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_address_line2, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_city, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_phone, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tax_as_of, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
    end

    attribute :provider_setup_started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  state_machine do
    initial_states([:pending_payment])
    default_initial_state(:pending_payment)

    transitions do
      transition(:begin_provider_setup, from: :pending_payment, to: :pending_provider_setup)
      transition(:provider_setup_ready, from: :pending_provider_setup, to: :pending_payment)
      transition(:mark_paid, from: :pending_payment, to: :paid)
      transition(:mark_paid, from: :pending_provider_setup, to: :paid)
      transition(:mark_payment_failed, from: :pending_payment, to: :payment_failed)
      transition(:mark_payment_failed, from: :pending_provider_setup, to: :payment_failed)
      transition(:cancel, from: :pending_payment, to: :cancelled)
      transition(:cancel, from: :pending_provider_setup, to: :cancelled)
      transition(:mark_refunded, from: :paid, to: :refunded)
    end
  end

  identities do
    identity(:unique_order_ref, [:order_ref])
    identity(:unique_checkout_key, [:checkout_key])
  end

  actions do
    defaults([:read])

    read :read_for_user do
      pagination(keyset?: true, required?: false, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_user do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read :get_for_user_by_ref do
      get?(true)

      argument :order_ref, :string do
        allow_nil?(false)
      end

      filter(expr(order_ref == ^arg(:order_ref)))
    end

    read :read_for_admin do
      pagination(keyset?: true, required?: false, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_admin do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :create do
      accept([:order_ref, :user_id, :checkout_key])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :order_ref) do
          nil -> Ash.Changeset.change_attribute(changeset, :order_ref, OrderRef.generate())
          _order_ref -> changeset
        end
      end)
    end

    create :begin_checkout do
      accept([:order_ref, :user_id, :checkout_key])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :order_ref) do
          nil -> Ash.Changeset.change_attribute(changeset, :order_ref, OrderRef.generate())
          _order_ref -> changeset
        end
      end)

      upsert?(true)
      upsert_identity(:unique_checkout_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_paid do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :provider_setup_started_at, nil)
      end)

      change({Store.Support.Governance.TransitionState, target: :paid})
    end

    update :mark_payment_failed do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :provider_setup_started_at, nil)
      end)

      change({Store.Support.Governance.TransitionState, target: :payment_failed})
    end

    update :cancel do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :provider_setup_started_at, nil)
      end)

      change({Store.Support.Governance.TransitionState, target: :cancelled})
    end

    update :mark_refunded do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :refunded})
    end

    update :write_tax_shipping_snapshot do
      require_atomic?(false)

      accept([
        :shipping_rate_id,
        :shipping_rate_code,
        :shipping_cost_minor_original,
        :shipping_cost_minor_effective,
        :free_shipping_applied,
        :free_shipping_reason,
        :shipping_tax_minor,
        :tax_total_minor,
        :billing_country_code,
        :billing_region_code,
        :shipping_country_code,
        :shipping_region_code,
        :shipping_postal_code,
        :tax_as_of
      ])
    end

    update :set_shipping_address do
      require_atomic?(false)

      accept([
        :shipping_country_code,
        :shipping_region_code,
        :shipping_postal_code,
        :shipping_recipient_name,
        :shipping_address_line1,
        :shipping_address_line2,
        :shipping_city,
        :shipping_phone
      ])
    end

    update :set_shipping_method do
      require_atomic?(false)
      accept([:shipping_rate_id, :shipping_rate_code])
    end

    update :set_renewal_shipping_profile do
      public?(false)
      require_atomic?(false)

      accept([
        :shipping_country_code,
        :shipping_region_code,
        :shipping_postal_code,
        :shipping_address_line1,
        :shipping_address_line2,
        :shipping_rate_code
      ])
    end

    update :set_shipping_quote_evidence do
      require_atomic?(false)

      accept([
        :shipping_quote_hash,
        :shipping_quote_currency_code,
        :shipping_quote_amount_minor,
        :shipping_weight_grams,
        :shipping_method_code,
        :shipping_rule_id,
        :shipping_zone_id,
        :shipping_effective_from,
        :shipping_effective_to
      ])
    end

    update :set_shipping_details do
      require_atomic?(false)

      accept([
        :shipping_country_code,
        :shipping_region_code,
        :shipping_postal_code,
        :shipping_recipient_name,
        :shipping_address_line1,
        :shipping_address_line2,
        :shipping_city,
        :shipping_phone,
        :shipping_rate_id,
        :shipping_rate_code,
        :shipping_quote_hash,
        :shipping_quote_currency_code,
        :shipping_quote_amount_minor,
        :shipping_weight_grams,
        :shipping_method_code,
        :shipping_rule_id,
        :shipping_zone_id,
        :shipping_effective_from,
        :shipping_effective_to
      ])
    end

    update :begin_provider_setup do
      require_atomic?(false)
      accept([:provider_setup_started_at])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :provider_setup_started_at,
          Ash.Changeset.get_attribute(changeset, :provider_setup_started_at) ||
            DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )
      end)

      change({Store.Support.Governance.TransitionState, target: :pending_provider_setup})
    end

    update :refresh_provider_setup do
      require_atomic?(false)
      accept([:provider_setup_started_at])
    end

    update :provider_setup_ready do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :provider_setup_started_at, nil)
      end)

      change({Store.Support.Governance.TransitionState, target: :pending_payment})
    end

    update :finalize_checkout_totals do
      require_atomic?(false)
      accept([:currency_code, :items_subtotal_minor, :shipping_total_minor, :grand_total_minor])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :totals_finalized_at,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )
      end)
    end
  end

  code_interface do
    define(:list_for_user, action: :read_for_user)
    define(:get_for_user, action: :get_for_user, args: [:id])
    define(:get_for_user_by_ref, action: :get_for_user_by_ref, args: [:order_ref])
    define(:list_for_admin, action: :read_for_admin)
    define(:get_for_admin, action: :get_for_admin, args: [:id])
  end

  json_api do
    type("order")
    includes([])
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("orders")
    repo(Store.Repo)

    custom_indexes do
      index([:state], name: "orders_state_index")

      index([:state, :provider_setup_started_at],
        name: "orders_state_provider_setup_started_at_index"
      )

      index([:order_ref], name: "orders_order_ref_index")
      index([:user_id], name: "orders_user_id_index")
      index([:user_id, :inserted_at, :id], name: "orders_user_id_inserted_at_id_index")
      index([:state, :inserted_at, :id], name: "orders_state_inserted_at_id_index")
      index([:shipping_rate_id], name: "orders_shipping_rate_id_index")
      index([:tax_as_of], name: "orders_tax_as_of_index")
      index([:currency_code], name: "orders_currency_code_index")
      index([:totals_finalized_at], name: "orders_totals_finalized_at_index")
    end
  end

  policies do
    bypass action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:read, :read_for_user, :get_for_user, :get_for_user_by_ref]) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:begin_checkout) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:cancel) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:mark_paid) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:begin_provider_setup) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:provider_setup_ready) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:refresh_provider_setup) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_payment_failed) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_refunded) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end

    policy action(:write_tax_shipping_snapshot) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:set_shipping_address) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:finalize_checkout_totals) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:set_shipping_method) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:set_renewal_shipping_profile) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:set_shipping_details) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
