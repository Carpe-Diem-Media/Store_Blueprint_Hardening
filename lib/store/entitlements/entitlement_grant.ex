defmodule Store.Entitlements.EntitlementGrant do
  @moduledoc """
  Durable entitlement grant derived from subscription lifecycle.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Entitlements

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    action :read_active_subscription_sources_for_system, :map do
      public?(false)
      transaction?(false)

      argument :source_ids, {:array, :uuid} do
        allow_nil?(false)
        constraints(max_length: 500)
      end

      run(Store.Entitlements.Actions.ReadActiveSubscriptionSourceGrants)
    end

    read :read_for_user do
      pagination(offset?: true, required?: false, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 100, max_page_size: 500)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :issue do
      accept([
        :user_id,
        :kind,
        :scope_key,
        :source_kind,
        :source_id,
        :status,
        :valid_from_at,
        :valid_to_at,
        :revoked_at,
        :revoked_reason
      ])

      upsert?(true)
      upsert_identity(:unique_user_scope_source)
      upsert_fields([:status, :valid_to_at, :revoked_at, :revoked_reason, :updated_at])
      return_skipped_upsert?(true)
    end

    create :converge_source_target do
      accept([:user_id, :kind, :scope_key, :source_id, :valid_from_at, :valid_to_at])

      upsert?(true)
      upsert_identity(:unique_user_scope_source)

      upsert_fields([
        :status,
        :valid_from_at,
        :valid_to_at,
        :revoked_at,
        :revoked_reason,
        :updated_at
      ])

      change(set_attribute(:source_kind, :subscription))
      change(set_attribute(:status, :active))
      change(set_attribute(:revoked_at, nil))
      change(set_attribute(:revoked_reason, nil))
    end

    update :revoke do
      require_atomic?(false)
      accept([:revoked_reason, :revoked_at])

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :revoked)
        |> maybe_set_revoked_at()
      end)
    end

    update :revoke_for_source_convergence do
      require_atomic?(true)
      accept([:revoked_reason])
      require_attributes([:revoked_reason])

      change(set_attribute(:status, :revoked))
      change(atomic_update(:revoked_at, expr(now())))
    end

    update :expire do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :expired))
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :kind, Store.Entitlements.Types.EntitlementKind do
      allow_nil?(false)
      public?(true)
    end

    attribute :scope_key, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :source_kind, Store.Entitlements.Types.EntitlementSourceKind do
      allow_nil?(false)
      default(:subscription)
      public?(true)
    end

    attribute :source_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Entitlements.Types.EntitlementStatus do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    attribute :valid_from_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    attribute :valid_to_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :revoked_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_user_scope_source, [:user_id, :kind, :scope_key, :source_kind, :source_id])
  end

  code_interface do
    define(:list_for_user, action: :read_for_user)
    define(:list_for_admin, action: :read_for_admin)
  end

  postgres do
    table("entitlement_grants")
    repo(Store.Repo)

    custom_indexes do
      index([:user_id, :kind, :scope_key, :status], name: "entitlement_grants_lookup_index")
      index([:source_kind, :source_id], name: "entitlement_grants_source_index")
      index([:valid_to_at], name: "entitlement_grants_valid_to_at_index")

      index([:source_id, :id],
        where: "source_kind = 'subscription' AND status = 'active'",
        name: "entitlement_grants_active_subscription_source_index",
        concurrently: true
      )
    end
  end

  policies do
    policy action(:read_active_subscription_sources_for_system) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    bypass action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:read_for_user) do
      access_type(:filter)
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp maybe_set_revoked_at(changeset) do
    if match?(%DateTime{}, Ash.Changeset.get_attribute(changeset, :revoked_at)) do
      changeset
    else
      Ash.Changeset.change_attribute(
        changeset,
        :revoked_at,
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
    end
  end
end
