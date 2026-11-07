# JC258 stored payment method write audit plan

> **For agentic workers:** Use subagent-driven-development for this approved task. The root reviews and commits the plan before a fresh implementation worker starts.

**Goal:** Record the current actor authorization result for direct `create_or_reuse`, `mark_active`, `mark_inactive`, and `mark_revoked` calls on `StoredPaymentMethod` without changing permissions.

**Architecture:** Add one `Store.DataCase` governance audit test that invokes the Ash resource actions directly. Build a fresh valid identity for every action/context pair, then assert either a persisted mutation or an exact `Ash.Error.Forbidden` with unchanged persisted data. This is characterization evidence only. `StoredPaymentMethod` has no pinned row in `docs/governance/policy_matrix.md`, so the test records current authority and a product decision gap rather than defining permission law.

**Tech Stack:** Elixir, Ash 3, ExUnit, Ecto SQL Sandbox, PostgreSQL, `Store.TestFixtures`, and `Store.TestSupport.StripeAPIStub`.

---

## Scope and evidence

Create only `test/store/governance/jc258_stored_method_authorization_audit_test.exs`. Do not change resources, policies, facades, fixtures, gates, migration files, or governance authority docs. The audit covers eight contexts: anonymous, actual owner, non-owner, support, editor, admin, super admin, and system. It exercises four actions for each context.

The current resource policy in `lib/store/subscriptions/stored_payment_method.ex` allows create/update for admin, super admin, and system context. The actual owner, non-owner, support, editor, and anonymous contexts have no create/update grant. `AcquireStoredPaymentMethodAuthority` in `lib/store/subscriptions/changes/acquire_stored_payment_method_authority.ex` also takes transaction-scoped binding and method advisory locks. Keep each create/update invocation inside the action's normal Ash transaction. Do not directly call the change callback or gate.

The expected observation for all four actions is success for admin, super admin, and system, with `Ash.Error.Forbidden` for anonymous, actual owner, non-owner, support, and editor. Label this result `OBSERVED_CURRENT_AUTHORITY / NEEDS_PRODUCT_DECISION`. It records what the resource currently permits. The matrix requires non-read actions to deny by default unless explicitly allowed. The missing resource-specific grant therefore remains an authority conflict for human decision, rather than a positive permission certificate. Accepted trusted-system orchestration is reviewed separately. This audit does not add a `StoredPaymentMethod` row to the matrix.

JC253's gate and existing behavior are covered in `test/store/subscriptions/stored_payment_method_revocation_test.exs`: it proves transaction requirements, owner identity enforcement, ordinary transitions, terminal revocation behavior, and stale writer rejection. This audit does not repeat or extend those race guarantees. It only uses unique synthetic provider references and the ordinary resource actions.

Do not use `Ash.can?/3` as the verdict. Assert the action changeset is valid before execution so invalid input cannot masquerade as a permission denial. For every denied action, require `%Ash.Error.Forbidden{}`. For denied updates, reload and compare status, owner, provider, customer reference, method reference, and fingerprint. For denied creates, query the exact provider/customer/method identity and assert no row exists. For successful creates, assert the returned owner and all exact synthetic references. For successful updates, start `mark_active` from `:inactive` and start `mark_inactive` and `mark_revoked` from `:active`, then assert both returned and reloaded status. Treat validation, stale-record, or terminal-state errors as failures, not authorization denials.

Install `StripeAPIStub.stub_unexpected!` for each test. The exercised actions must not call a provider. Use only dummy `cus_jc258_*`, `pm_jc258_*`, and `fp_jc258_*` values. Do not add real provider calls or secret values.

The test does not certify identity replacement, concurrent writers, charges, subscription renewals, provider setup completion, facade behavior, or a future permission model. It does not claim a canonical matrix row exists for `StoredPaymentMethod`.

## File map

- Create `test/store/governance/jc258_stored_method_authorization_audit_test.exs`. It owns the direct action/context matrix, fixture construction, exact result checks, and exact-row reload helpers.

## Task 1: Add the complete direct authorization characterization module

**Files:**

- Create: `test/store/governance/jc258_stored_method_authorization_audit_test.exs`

- [ ] Add this complete module. Do not add production changes.

```elixir
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

        {:error, %Ash.Error.Forbidden{}} when actor_context.label in [:anonymous, :owner, :non_owner, :support, :editor] ->
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
```

The test source above is the proposed implementation, not a production permission change. If the current Ash version or formatter rejects a syntax detail, correct only that detail while keeping the scope and assertions intact. In particular, keep successful transition fixtures in the required initial state and keep exact synthetic identity assertions.

- [ ] Run the focused test through DevCore and capture its exit code and full output:

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/governance/jc258_stored_method_authorization_audit_test.exs
jc258_method_check_status=$?
printf 'exit=%s\n' "$jc258_method_check_status"
exit "$jc258_method_check_status"
```

Expected result: exit code `0`; all four tests pass. If the command fails, report the exact observed failure and fix only an issue in the new test before rerunning.

- [ ] Check formatting for the new file through DevCore and capture its exit code and output:

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted test/store/governance/jc258_stored_method_authorization_audit_test.exs
jc258_method_check_status=$?
printf 'exit=%s\n' "$jc258_method_check_status"
exit "$jc258_method_check_status"
```

Expected result: exit code `0` with no formatting diff.

- [ ] Run scoped positional Credo through DevCore and capture its exit code and output:

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/governance/jc258_stored_method_authorization_audit_test.exs
jc258_method_check_status=$?
printf 'exit=%s\n' "$jc258_method_check_status"
exit "$jc258_method_check_status"
```

Expected result: exit code `0` with no issues in the new file.

- [ ] Compile test code through DevCore and capture its exit code and output:

```bash
set +e
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
jc258_method_check_status=$?
printf 'exit=%s\n' "$jc258_method_check_status"
exit "$jc258_method_check_status"
```

Expected result: exit code `0`. Do not claim a check passed unless its command output and exit code were observed.

- [ ] Inspect the complete diff and confirm the only tracked change is the requested new test file. Confirm the new file contains no real secrets, provider calls, global count assertions, policy changes, or additional scope. Record `OBSERVED_CURRENT_AUTHORITY / NEEDS_PRODUCT_DECISION`: the canonical policy matrix has no StoredPaymentMethod row, and current create/update actions permit admin, super-admin, and system contexts.

## Handoff

Report the new test path, observed current authority, exact command exit codes, current branch and any blocker. After self-review, commit only the new test file when the root assigns implementation. Do not update Linear, publish, change branches or modify production code.
