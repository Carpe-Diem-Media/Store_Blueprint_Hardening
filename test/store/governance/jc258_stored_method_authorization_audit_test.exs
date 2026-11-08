defmodule Store.Governance.JC258StoredMethodAuthorizationAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.StoredPaymentMethod
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("stored payment method writes must not call Stripe")
    :ok
  end

  test "create_or_reuse records current authorization for all actor contexts" do
    owner = TestFixtures.register_user!(email: TestFixtures.unique_email("jc258_spm_owner"))
    contexts = actor_contexts(owner)

    Enum.each(contexts, fn actor_context ->
      refs = provider_refs(actor_context.label)
      attrs = create_attrs(owner, refs)
      changeset = create_changeset(attrs, actor_context.context)

      assert changeset.valid?

      case create_result(changeset, actor_context) do
        {:ok, stored_method} when actor_context.label in [:admin, :super_admin, :system] ->
          assert stored_method.user_id == owner.id
          assert stored_method.provider == :stripe
          assert stored_method.provider_customer_ref == refs.customer_ref
          assert stored_method.provider_payment_method_ref == refs.method_ref
          assert stored_method.fingerprint == refs.fingerprint
          assert stored_method.status == :active

          persisted = reload_by_refs!(refs)
          assert persisted.id == stored_method.id
          assert persisted.user_id == owner.id
          assert persisted.provider_customer_ref == refs.customer_ref
          assert persisted.provider_payment_method_ref == refs.method_ref
          assert persisted.fingerprint == refs.fingerprint
          assert persisted.status == :active

        {:error, %Ash.Error.Forbidden{}}
        when actor_context.label in [:anonymous, :owner, :non_owner, :support, :editor] ->
          assert [] == read_by_refs!(refs)

        other ->
          flunk("unexpected create_or_reuse result for #{actor_context.label}: #{inspect(other)}")
      end
    end)
  end

  test "mark_active records current authorization for all actor contexts" do
    audit_transition(:mark_active, :inactive, :active)
  end

  test "mark_inactive records current authorization for all actor contexts" do
    audit_transition(:mark_inactive, :active, :inactive)
  end

  test "mark_revoked records current authorization for all actor contexts" do
    audit_transition(:mark_revoked, :active, :revoked)
  end

  defp audit_transition(action, initial_status, expected_status) do
    owner = TestFixtures.register_user!(email: TestFixtures.unique_email("jc258_spm_owner"))

    Enum.each(actor_contexts(owner), fn actor_context ->
      refs = provider_refs("#{action}_#{actor_context.label}")
      stored_method = create_fixture!(owner, refs, initial_status)
      before = snapshot(stored_method)

      changeset =
        Ash.Changeset.for_update(stored_method, action, %{}, context: actor_context.context)

      assert changeset.valid?

      case update_result(changeset, actor_context) do
        {:ok, updated} when actor_context.label in [:admin, :super_admin, :system] ->
          assert updated.id == stored_method.id
          assert updated.status == expected_status

          persisted = reload_by_refs!(refs)
          assert persisted.id == stored_method.id
          assert persisted.status == expected_status

        {:error, %Ash.Error.Forbidden{}}
        when actor_context.label in [:anonymous, :owner, :non_owner, :support, :editor] ->
          assert snapshot(reload_by_refs!(refs)) == before

        other ->
          flunk("unexpected #{action} result for #{actor_context.label}: #{inspect(other)}")
      end
    end)
  end

  defp actor_contexts(owner) do
    non_owner = TestFixtures.register_user!(email: TestFixtures.unique_email("jc258_spm_other"))

    role_contexts =
      Enum.map([:support, :editor, :admin, :super_admin], fn role ->
        actor = TestFixtures.register_user!(email: TestFixtures.unique_email("jc258_spm_#{role}"))
        _assignment = TestFixtures.assign_role!(actor, role)
        %{label: role, actor: actor, context: %{}}
      end)

    [
      %{label: :anonymous, actor: nil, context: %{}},
      %{label: :owner, actor: owner, context: %{}},
      %{label: :non_owner, actor: non_owner, context: %{}}
      | role_contexts
    ] ++ [%{label: :system, actor: nil, context: %{system?: true}}]
  end

  defp provider_refs(label) do
    token = "#{label}_#{System.unique_integer([:positive])}"

    %{
      customer_ref: "cus_jc258_#{token}",
      method_ref: "pm_jc258_#{token}",
      fingerprint: "fp_jc258_#{token}"
    }
  end

  defp create_attrs(owner, refs) do
    %{
      user_id: owner.id,
      provider: :stripe,
      provider_customer_ref: refs.customer_ref,
      provider_payment_method_ref: refs.method_ref,
      status: :active,
      fingerprint: refs.fingerprint
    }
  end

  defp create_changeset(attrs, context) do
    Ash.Changeset.for_create(StoredPaymentMethod, :create_or_reuse, attrs, context: context)
  end

  defp create_result(changeset, actor_context) do
    Ash.create(changeset, call_options(actor_context))
  end

  defp update_result(changeset, actor_context) do
    Ash.update(changeset, call_options(actor_context))
  end

  defp call_options(actor_context) do
    [
      domain: Store.Subscriptions,
      actor: actor_context.actor,
      context: actor_context.context
    ]
  end

  defp create_fixture!(owner, refs, status) do
    attrs = create_attrs(owner, refs) |> Map.put(:status, status)
    changeset = create_changeset(attrs, %{system?: true})
    assert changeset.valid?

    case Ash.create(changeset,
           domain: Store.Subscriptions,
           actor: nil,
           context: %{system?: true}
         ) do
      {:ok, stored_method} -> stored_method
      other -> flunk("system fixture create failed: #{inspect(other)}")
    end
  end

  defp read_by_refs!(refs) do
    customer_ref = refs.customer_ref
    method_ref = refs.method_ref

    StoredPaymentMethod
    |> Ash.Query.filter(
      expr(
        provider == :stripe and provider_customer_ref == ^customer_ref and
          provider_payment_method_ref == ^method_ref
      )
    )
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_by_refs!(refs) do
    case read_by_refs!(refs) do
      [stored_method] -> stored_method
      rows -> flunk("expected one exact stored method row, got #{length(rows)}")
    end
  end

  defp snapshot(stored_method) do
    Map.take(stored_method, [
      :status,
      :user_id,
      :provider,
      :provider_customer_ref,
      :provider_payment_method_ref,
      :fingerprint
    ])
  end
end
