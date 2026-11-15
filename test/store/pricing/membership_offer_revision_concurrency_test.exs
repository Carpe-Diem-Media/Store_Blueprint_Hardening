defmodule Store.Pricing.MembershipOfferRevisionConcurrencyTest do
  use Store.DataCase, async: false

  @moduletag :real_connections

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Pricing
  alias Store.Pricing.{MembershipOfferRevision, MembershipOfferRevisionComponent}
  alias Store.Repo

  @system_context %{system?: true}

  test "independent accept and child-write connections serialize without changing the accepted fingerprint" do
    for repetition <- 1..2 do
      fixture = Sandbox.unboxed_run(Repo, &committed_draft!/0)

      try do
        parent = self()

        operations = [:accept, :write_child]

        tasks =
          Enum.map(operations, fn operation ->
            Task.async(fn ->
              Sandbox.unboxed_run(Repo, fn ->
                Repo.checkout(fn ->
                  %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                  send(parent, {:ready, operation, self(), backend_pid})

                  receive do
                    :race ->
                      case operation do
                        :accept ->
                          Pricing.accept_membership_offer_revision_for_system(fixture.revision_id)

                        :write_child ->
                          create_component(fixture.revision_id)
                      end
                  after
                    10_000 -> raise "membership offer revision race barrier timed out"
                  end
                end)
              end)
            end)
          end)

        ready =
          Enum.map(operations, fn expected_operation ->
            assert_receive {:ready, ^expected_operation, pid, backend_pid}, 10_000
            {pid, backend_pid}
          end)

        assert length(Enum.uniq(Enum.map(ready, &elem(&1, 1)))) == 2
        Enum.each(ready, fn {pid, _backend_pid} -> send(pid, :race) end)

        results = Enum.map(tasks, &Task.await(&1, 30_000))
        assert Enum.any?(results, &match?({:ok, %MembershipOfferRevision{}}, &1))

        assert {:ok, accepted} = reload_revision(fixture.revision_id)
        assert accepted.status == "accepted"

        assert {:ok, components} = list_components(fixture.revision_id)
        assert length(components) in [1, 2]
        assert accepted.fingerprint == fingerprint(accepted, components)

        write_result = Enum.at(results, 1)

        case write_result do
          {:ok, %MembershipOfferRevisionComponent{}} -> assert length(components) == 2
          {:error, _} -> assert length(components) == 1
        end

        IO.puts(
          "JC274 membership offer acceptance race repetition=#{repetition} components=#{length(components)} fingerprint_verified=true"
        )
      after
        cleanup_committed_fixture!(fixture)
      end
    end
  end

  test "direct SQL cannot update or delete accepted evidence or add accepted components" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        draft = committed_draft!()

        assert {:ok, _accepted} =
                 Pricing.accept_membership_offer_revision_for_system(draft.revision_id)

        draft
      end)

    try do
      revision_id = Ecto.UUID.dump!(fixture.revision_id)
      component_id = Ecto.UUID.dump!(fixture.component_id)

      Sandbox.unboxed_run(Repo, fn ->
        assert_database_check_violation(
          "UPDATE membership_offer_revisions SET currency = 'EUR' WHERE id = $1",
          [revision_id]
        )

        assert_database_check_violation("DELETE FROM membership_offer_revisions WHERE id = $1", [
          revision_id
        ])

        assert_database_check_violation(
          "UPDATE membership_offer_revision_components SET gross_minor = 900 WHERE id = $1",
          [component_id]
        )

        assert_database_check_violation(
          "DELETE FROM membership_offer_revision_components WHERE id = $1",
          [component_id]
        )

        assert_database_check_violation(
          "INSERT INTO membership_offer_revision_components (id, revision_id, definition_key, gross_minor, discount_eligibility_key, tax_treatment_key) VALUES (uuid_generate_v7(), $1, $2, 50, 'eligible', 'standard')",
          [revision_id, Ecto.UUID.dump!(Ash.UUIDv7.generate())]
        )

        assert_database_check_violation("TRUNCATE membership_offer_revision_components", [])
        assert_database_check_violation("TRUNCATE membership_offer_revisions CASCADE", [])
      end)
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "database rejects direct acceptance with a fingerprint that omits the manifest" do
    fixture = Sandbox.unboxed_run(Repo, &committed_draft!/0)

    try do
      Sandbox.unboxed_run(Repo, fn ->
        assert_database_check_violation(
          "UPDATE membership_offer_revisions SET status = 'accepted', accepted_at = (now() AT TIME ZONE 'utc'), fingerprint = repeat('0', 64) WHERE id = $1",
          [Ecto.UUID.dump!(fixture.revision_id)]
        )
      end)

      assert {:ok, %MembershipOfferRevision{status: "draft"}} =
               Sandbox.unboxed_run(Repo, fn -> reload_revision(fixture.revision_id) end)
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  defp committed_draft! do
    revision =
      MembershipOfferRevision
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          offer_key: "membership.race.#{Ash.UUIDv7.generate()}",
          revision: 1,
          currency: "USD"
        },
        context: @system_context
      )
      |> Ash.create!(domain: Pricing, authorize?: false, context: @system_context)

    component = create_component!(revision.id)

    %{revision_id: revision.id, component_id: component.id}
  end

  defp create_component(revision_id) do
    MembershipOfferRevisionComponent
    |> Ash.Changeset.for_create(
      :create_draft,
      %{
        revision_id: revision_id,
        definition_key: Ash.UUIDv7.generate(),
        gross_minor: 500,
        discount_eligibility_key: "eligible",
        tax_treatment_key: "standard"
      },
      context: @system_context
    )
    |> Ash.create(domain: Pricing, authorize?: false, context: @system_context)
  end

  defp create_component!(revision_id) do
    assert {:ok, %MembershipOfferRevisionComponent{} = component} = create_component(revision_id)
    component
  end

  defp reload_revision(id) do
    Ash.get(MembershipOfferRevision, id, domain: Pricing, authorize?: false)
  end

  defp list_components(revision_id) do
    MembershipOfferRevisionComponent
    |> Ash.Query.filter(revision_id == ^revision_id)
    |> Ash.read(domain: Pricing, authorize?: false)
  end

  defp fingerprint(revision, components) do
    MembershipOfferRevision.Fingerprint.compute(
      revision.offer_key,
      revision.revision,
      revision.currency,
      components
    )
  end

  defp assert_database_check_violation(sql, params) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(sql, params)
  end

  defp cleanup_committed_fixture!(%{revision_id: revision_id}) do
    id = Ecto.UUID.dump!(revision_id)

    assert {:ok, :cleaned} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 Repo.query!(
                   "ALTER TABLE membership_offer_revision_components DISABLE TRIGGER membership_offer_revision_components_lock_guard"
                 )

                 Repo.query!(
                   "ALTER TABLE membership_offer_revisions DISABLE TRIGGER membership_offer_revisions_state_guard"
                 )

                 Repo.query!(
                   "DELETE FROM membership_offer_revision_components WHERE revision_id = $1",
                   [id]
                 )

                 Repo.query!("DELETE FROM membership_offer_revisions WHERE id = $1", [id])

                 Repo.query!(
                   "ALTER TABLE membership_offer_revisions ENABLE TRIGGER membership_offer_revisions_state_guard"
                 )

                 Repo.query!(
                   "ALTER TABLE membership_offer_revision_components ENABLE TRIGGER membership_offer_revision_components_lock_guard"
                 )

                 :cleaned
               end)
             end)
  end
end
