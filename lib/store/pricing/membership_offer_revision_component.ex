defmodule Store.Pricing.MembershipOfferRevisionComponent do
  @moduledoc """
  Version-specific component definition within a Membership offer manifest.

  `definition_key` identifies the reusable offer definition. A customer's recurring
  Subscription component has a separate identity owned by the Subscriptions domain.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Pricing

  attributes do
    uuid_v7_primary_key(:id)

    attribute :definition_key, Ash.Type.UUIDv7 do
      allow_nil?(false)
      public?(true)
    end

    attribute :gross_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :discount_eligibility_key, :string do
      allow_nil?(false)
      constraints(min_length: 1, max_length: 128)
      public?(true)
    end

    attribute :tax_treatment_key, :string do
      allow_nil?(false)
      constraints(min_length: 1, max_length: 128)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :revision, Store.Pricing.MembershipOfferRevision do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:revision_definition, [:revision_id, :definition_key])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create_draft do
      accept([
        :revision_id,
        :definition_key,
        :gross_minor,
        :discount_eligibility_key,
        :tax_treatment_key
      ])

      change(&normalize_keys/2)
      validate(&validate_keys/2)
    end

    update :update_draft do
      require_atomic?(false)
      accept([:definition_key, :gross_minor, :discount_eligibility_key, :tax_treatment_key])

      change(&normalize_keys/2)
      validate(&validate_keys/2)
    end

    destroy :destroy_draft do
      require_atomic?(false)
    end
  end

  postgres do
    table("membership_offer_revision_components")
    repo(Store.Repo)

    check_constraints do
      check_constraint(:id, "membership_offer_revision_components_id_v7_check",
        check: "substring(id::text FROM 15 FOR 1) = '7'"
      )

      check_constraint(
        :definition_key,
        "membership_offer_revision_components_definition_key_v7_check",
        check: "substring(definition_key::text FROM 15 FOR 1) = '7'"
      )

      check_constraint(:gross_minor, "membership_offer_revision_components_gross_minor_check",
        check: "gross_minor >= 0"
      )

      check_constraint(
        :discount_eligibility_key,
        "membership_offer_revision_components_eligibility_key_check",
        check: "discount_eligibility_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'"
      )

      check_constraint(
        :tax_treatment_key,
        "membership_offer_revision_components_tax_treatment_key_check",
        check: "tax_treatment_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'"
      )
    end

    references do
      reference(:revision, on_delete: :restrict)
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update, :destroy]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_keys(changeset, _context) do
    changeset
    |> normalize_key(:discount_eligibility_key)
    |> normalize_key(:tax_treatment_key)
  end

  defp normalize_key(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      value when is_binary(value) ->
        Ash.Changeset.change_attribute(changeset, attribute, String.trim(value))

      _other ->
        changeset
    end
  end

  defp validate_keys(changeset, _context) do
    case validate_key(changeset, :discount_eligibility_key) do
      :ok -> validate_key(changeset, :tax_treatment_key)
      error -> error
    end
  end

  defp validate_key(changeset, attribute) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value) do
          :ok
        else
          {:error, field: attribute, message: "must be a non-empty stable key"}
        end

      _other ->
        {:error, field: attribute, message: "must be a non-empty stable key"}
    end
  end
end
