defmodule Store.Pricing.MembershipOfferRevisionTest do
  use Store.DataCase, async: false

  alias Store.Pricing

  alias Store.Pricing.{
    MembershipOfferRevision,
    MembershipOfferRevisionComponent,
    Promotion
  }

  @system_context %{system?: true}

  test "accepts a one-component manifest and exact replay returns the accepted evidence" do
    revision = create_revision!()
    component = create_component!(revision)

    assert {:ok, accepted} = Pricing.accept_membership_offer_revision_for_system(revision.id)
    assert accepted.id == revision.id
    assert accepted.status == "accepted"
    assert is_struct(accepted.accepted_at, DateTime)
    assert accepted.fingerprint == fingerprint(revision, [component])

    assert {:ok, replay} = Pricing.accept_membership_offer_revision_for_system(revision.id)
    assert replay.id == accepted.id
    assert replay.fingerprint == accepted.fingerprint
    assert replay.accepted_at == accepted.accepted_at
  end

  test "accepts the maximum sixteen-component manifest" do
    revision = create_revision!()

    components =
      for _index <- 1..16 do
        create_component!(revision)
      end

    assert {:ok, accepted} = Pricing.accept_membership_offer_revision_for_system(revision.id)
    assert accepted.status == "accepted"
    assert accepted.fingerprint == fingerprint(revision, components)
  end

  test "rejects zero-component and seventeen-component manifests without accepting them" do
    empty = create_revision!()

    assert {:error, _} = Pricing.accept_membership_offer_revision_for_system(empty.id)
    assert reload_revision!(empty.id).status == "draft"

    oversized = create_revision!()
    Enum.each(1..17, fn _index -> create_component!(oversized) end)

    assert {:error, _} = Pricing.accept_membership_offer_revision_for_system(oversized.id)
    assert reload_revision!(oversized.id).status == "draft"
  end

  test "rejects duplicate component definitions and negative gross amounts" do
    revision = create_revision!()
    component = create_component!(revision)

    assert {:error, _} =
             create_component(revision, %{
               definition_key: component.definition_key,
               gross_minor: 500
             })

    assert {:error, _} = create_component(revision, %{gross_minor: -1})
  end

  test "rejects invalid currency and malformed eligibility or tax-treatment keys" do
    assert {:error, _} = create_revision(%{currency: "US"})
    assert {:error, _} = create_revision(%{currency: "$$$"})

    revision = create_revision!()

    assert {:error, _} = create_component(revision, %{discount_eligibility_key: "  "})
    assert {:error, _} = create_component(revision, %{tax_treatment_key: "invalid key"})
  end

  test "fingerprint is stable across manifest order and changes with commercial fields" do
    first = component_values(100, "eligible", "standard")
    second = component_values(250, "excluded", "reduced")

    fingerprint =
      MembershipOfferRevision.Fingerprint.compute(
        "membership.offer",
        7,
        "USD",
        [first, second]
      )

    assert fingerprint ==
             MembershipOfferRevision.Fingerprint.compute(
               "membership.offer",
               7,
               "USD",
               [second, first]
             )

    refute fingerprint ==
             MembershipOfferRevision.Fingerprint.compute(
               "membership.offer",
               7,
               "USD",
               [%{first | gross_minor: first.gross_minor + 1}, second]
             )

    refute fingerprint ==
             MembershipOfferRevision.Fingerprint.compute(
               "membership.offer",
               7,
               "USD",
               [%{first | discount_eligibility_key: "different"}, second]
             )
  end

  test "same offer revision cannot be created twice with conflicting evidence" do
    revision = create_revision!()
    create_component!(revision, %{gross_minor: 800})
    assert {:ok, _accepted} = Pricing.accept_membership_offer_revision_for_system(revision.id)

    assert {:error, _} =
             create_revision(%{
               offer_key: revision.offer_key,
               revision: revision.revision,
               currency: revision.currency
             })
  end

  test "accepted revision and component definitions are immutable through Ash actions" do
    revision = create_revision!()
    component = create_component!(revision)
    assert {:ok, accepted} = Pricing.accept_membership_offer_revision_for_system(revision.id)

    assert {:error, _} =
             accepted
             |> Ash.Changeset.for_update(:update_draft, %{currency: "EUR"},
               context: @system_context
             )
             |> Ash.update(domain: Pricing, authorize?: false, context: @system_context)

    assert {:error, _} =
             component
             |> Ash.Changeset.for_update(:update_draft, %{gross_minor: 900},
               context: @system_context
             )
             |> Ash.update(domain: Pricing, authorize?: false, context: @system_context)

    assert {:error, _} =
             component
             |> Ash.Changeset.for_destroy(:destroy_draft, %{}, context: @system_context)
             |> Ash.destroy(domain: Pricing, authorize?: false, context: @system_context)
  end

  test "rejected revisions are terminal and cannot receive component definitions" do
    revision = create_revision!()
    component = create_component!(revision)

    rejected =
      revision
      |> Ash.Changeset.for_update(:reject, %{}, context: @system_context)
      |> Ash.update!(domain: Pricing, authorize?: false, context: @system_context)

    assert rejected.status == "rejected"

    assert {:error, _} =
             rejected
             |> Ash.Changeset.for_update(:update_draft, %{currency: "EUR"},
               context: @system_context
             )
             |> Ash.update(domain: Pricing, authorize?: false, context: @system_context)

    assert {:error, _} =
             component
             |> Ash.Changeset.for_update(:update_draft, %{gross_minor: 900},
               context: @system_context
             )
             |> Ash.update(domain: Pricing, authorize?: false, context: @system_context)

    assert {:error, _} = create_component(rejected, %{gross_minor: 700})
  end

  test "distinct revisions preserve their own immutable manifests" do
    definition_key = Ash.UUIDv7.generate()
    first = create_revision!(%{revision: 1})

    first_component =
      create_component!(first, %{definition_key: definition_key, gross_minor: 700})

    assert {:ok, accepted_first} = Pricing.accept_membership_offer_revision_for_system(first.id)

    second = create_revision!(%{revision: 2})

    second_component =
      create_component!(second, %{definition_key: definition_key, gross_minor: 950})

    assert {:ok, accepted_second} = Pricing.accept_membership_offer_revision_for_system(second.id)

    refute accepted_first.fingerprint == accepted_second.fingerprint
    assert reload_component!(first_component.id).gross_minor == 700
    assert reload_component!(second_component.id).gross_minor == 950
  end

  test "offer revisions do not mutate legacy promotion records" do
    promotion =
      Promotion
      |> Ash.Changeset.for_create(
        :create,
        %{code: "legacy-#{Ash.UUIDv7.generate()}", currency: "USD", discount_minor: 25},
        context: @system_context
      )
      |> Ash.create!(domain: Pricing, authorize?: false, context: @system_context)

    before = {promotion.code, promotion.currency, promotion.discount_minor, promotion.active}
    revision = create_revision!()
    create_component!(revision)
    assert {:ok, _accepted} = Pricing.accept_membership_offer_revision_for_system(revision.id)

    assert {:ok, reloaded} = Ash.get(Promotion, promotion.id, domain: Pricing, authorize?: false)
    assert {reloaded.code, reloaded.currency, reloaded.discount_minor, reloaded.active} == before
  end

  defp create_revision!(attrs \\ %{}) do
    assert {:ok, revision} = create_revision(attrs)
    revision
  end

  defp create_revision(attrs) do
    defaults = %{
      offer_key: "membership.offer.#{Ash.UUIDv7.generate()}",
      revision: 1,
      currency: "usd"
    }

    MembershipOfferRevision
    |> Ash.Changeset.for_create(:create_draft, Map.merge(defaults, attrs),
      context: @system_context
    )
    |> Ash.create(domain: Pricing, authorize?: false, context: @system_context)
  end

  defp create_component!(revision, attrs \\ %{}) do
    assert {:ok, component} = create_component(revision, attrs)
    component
  end

  defp create_component(revision, attrs) do
    defaults = %{
      revision_id: revision.id,
      definition_key: Ash.UUIDv7.generate(),
      gross_minor: 1_000,
      discount_eligibility_key: "eligible",
      tax_treatment_key: "standard"
    }

    MembershipOfferRevisionComponent
    |> Ash.Changeset.for_create(:create_draft, Map.merge(defaults, attrs),
      context: @system_context
    )
    |> Ash.create(domain: Pricing, authorize?: false, context: @system_context)
  end

  defp reload_revision!(id) do
    Ash.get!(MembershipOfferRevision, id, domain: Pricing, authorize?: false)
  end

  defp reload_component!(id) do
    Ash.get!(MembershipOfferRevisionComponent, id, domain: Pricing, authorize?: false)
  end

  defp fingerprint(revision, components) do
    MembershipOfferRevision.Fingerprint.compute(
      revision.offer_key,
      revision.revision,
      revision.currency,
      components
    )
  end

  defp component_values(gross_minor, eligibility, treatment) do
    %{
      definition_key: Ash.UUIDv7.generate(),
      gross_minor: gross_minor,
      discount_eligibility_key: eligibility,
      tax_treatment_key: treatment
    }
  end
end
