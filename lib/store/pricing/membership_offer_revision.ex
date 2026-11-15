defmodule Store.Pricing.MembershipOfferRevision do
  @moduledoc """
  Immutable accepted price and eligibility manifest for a product-agnostic offer.

  This record is Pricing input only. It does not select an offer for a customer,
  prove collection, create a subscription, or grant access.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Pricing

  attributes do
    uuid_v7_primary_key(:id)

    attribute :offer_key, :string do
      allow_nil?(false)
      constraints(min_length: 1, max_length: 160)
      public?(true)
    end

    attribute :revision, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :status, :string do
      allow_nil?(false)
      default("draft")
      public?(true)
    end

    attribute :fingerprint, :string do
      allow_nil?(true)
      constraints(max_length: 64)
      public?(true)
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :components, Store.Pricing.MembershipOfferRevisionComponent do
      destination_attribute(:revision_id)
      public?(true)
    end
  end

  identities do
    identity(:offer_revision, [:offer_key, :revision])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create_draft do
      accept([:offer_key, :revision, :currency])

      change(set_attribute(:status, "draft"))
      change(&normalize_draft/2)
      validate(&validate_draft/2)
    end

    update :update_draft do
      require_atomic?(false)
      accept([:offer_key, :revision, :currency])

      change(filter(expr(status == "draft")))
      change(&normalize_draft/2)
      validate(&validate_draft/2)
    end

    update :accept do
      require_atomic?(false)
      accept([:fingerprint, :accepted_at])

      change(filter(expr(status == "draft")))
      change(set_attribute(:status, "accepted"))
    end

    update :reject do
      require_atomic?(false)
      accept([])

      change(filter(expr(status == "draft")))
      change(set_attribute(:status, "rejected"))
    end
  end

  postgres do
    table("membership_offer_revisions")
    repo(Store.Repo)

    check_constraints do
      check_constraint(:id, "membership_offer_revisions_id_v7_check",
        check: "substring(id::text FROM 15 FOR 1) = '7'"
      )

      check_constraint(:offer_key, "membership_offer_revisions_offer_key_check",
        check: "length(btrim(offer_key)) BETWEEN 1 AND 160"
      )

      check_constraint(:revision, "membership_offer_revisions_revision_check",
        check: "revision > 0"
      )

      check_constraint(:currency, "membership_offer_revisions_currency_check",
        check: "currency ~ '^[A-Z]{3}$'"
      )

      check_constraint(:status, "membership_offer_revisions_status_check",
        check: "status IN ('draft', 'accepted', 'rejected')"
      )

      check_constraint(:fingerprint, "membership_offer_revisions_acceptance_check",
        check:
          "(status = 'accepted' AND accepted_at IS NOT NULL AND fingerprint ~ '^[0-9a-f]{64}$') OR (status IN ('draft', 'rejected') AND accepted_at IS NULL AND fingerprint IS NULL)"
      )
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
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_draft(changeset, _context) do
    changeset
    |> normalize_string(:offer_key, & &1)
    |> normalize_string(:currency, &String.upcase/1)
  end

  defp normalize_string(changeset, attribute, transform) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      value when is_binary(value) ->
        value = value |> String.trim() |> transform.()
        Ash.Changeset.change_attribute(changeset, attribute, value)

      _other ->
        changeset
    end
  end

  defp validate_draft(changeset, _context) do
    offer_key = Ash.Changeset.get_attribute(changeset, :offer_key)
    revision = Ash.Changeset.get_attribute(changeset, :revision)
    currency = Ash.Changeset.get_attribute(changeset, :currency)

    cond do
      not is_binary(offer_key) or String.trim(offer_key) == "" ->
        {:error, field: :offer_key, message: "must be a non-empty stable key"}

      not is_integer(revision) or revision < 1 ->
        {:error, field: :revision, message: "must be a positive revision number"}

      not is_binary(currency) or not Regex.match?(~r/\A[A-Z]{3}\z/, currency) ->
        {:error, field: :currency, message: "must be an uppercase ISO 4217 alpha-3 code"}

      true ->
        :ok
    end
  end

  defmodule Fingerprint do
    @moduledoc false

    @prefix <<"membership-offer-revision:v1", 0>>

    @spec compute(String.t(), pos_integer(), String.t(), [map() | struct()]) :: String.t()
    def compute(offer_key, revision, currency, components)
        when is_binary(offer_key) and is_integer(revision) and revision > 0 and
               is_binary(currency) and is_list(components) do
      sorted_components =
        Enum.map(components, fn component ->
          definition_key = field!(component, :definition_key)
          {Ecto.UUID.dump!(definition_key), component}
        end)
        |> Enum.sort_by(&elem(&1, 0))

      payload =
        IO.iodata_to_binary([
          @prefix,
          frame(offer_key),
          <<revision::signed-big-64>>,
          frame(currency),
          <<length(sorted_components)::unsigned-big-32>>,
          Enum.map(sorted_components, fn {definition_key, component} ->
            [
              definition_key,
              <<field!(component, :gross_minor)::signed-big-64>>,
              frame(field!(component, :discount_eligibility_key)),
              frame(field!(component, :tax_treatment_key))
            ]
          end)
        ])

      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)
    end

    defp field!(component, key), do: Map.fetch!(component, key)

    defp frame(value) when is_binary(value), do: [<<byte_size(value)::unsigned-big-32>>, value]
  end
end
