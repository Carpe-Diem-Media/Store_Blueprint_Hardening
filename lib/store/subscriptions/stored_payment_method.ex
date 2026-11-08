defmodule Store.Subscriptions.StoredPaymentMethod do
  @moduledoc """
  Durable provider payment method reference used by merchant-managed renewals.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider, Store.Payments.Types.Provider do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_customer_ref, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_payment_method_ref, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Subscriptions.Types.StoredPaymentMethodStatus do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    attribute :fingerprint, :string do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :subscriptions, Store.Subscriptions.Subscription do
      destination_attribute(:stored_payment_method_id)
      public?(true)
    end
  end

  identities do
    identity(
      :unique_provider_customer_payment_method,
      [:provider, :provider_customer_ref, :provider_payment_method_ref]
    )
  end

  actions do
    defaults([:read])

    read :get_for_system do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :create_or_reuse do
      transaction?(true)

      accept([
        :user_id,
        :provider,
        :provider_customer_ref,
        :provider_payment_method_ref,
        :status,
        :fingerprint
      ])

      upsert?(true)
      upsert_identity(:unique_provider_customer_payment_method)
      upsert_fields([:status, :fingerprint])
      upsert_condition(expr(status != :revoked))
      return_skipped_upsert?(true)

      change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
    end

    update :mark_active do
      require_atomic?(false)
      accept([])
      change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
      change(filter(expr(status != :revoked)))
      change(set_attribute(:status, :active))
    end

    update :mark_inactive do
      require_atomic?(false)
      accept([])
      change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
      change(filter(expr(status != :revoked)))
      change(set_attribute(:status, :inactive))
    end

    update :mark_revoked do
      require_atomic?(false)
      accept([])
      change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
      change(set_attribute(:status, :revoked))
    end
  end

  code_interface do
    define(:get_for_system, action: :get_for_system, args: [:id])
  end

  postgres do
    table("stored_payment_methods")
    repo(Store.Repo)

    identity_index_names(
      unique_provider_customer_payment_method:
        "stored_payment_methods_unique_provider_customer_pm_index"
    )

    custom_indexes do
      index([:user_id, :status], name: "stored_payment_methods_user_id_status_index")
      index([:provider, :status], name: "stored_payment_methods_provider_status_index")
    end
  end

  policies do
    bypass action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
