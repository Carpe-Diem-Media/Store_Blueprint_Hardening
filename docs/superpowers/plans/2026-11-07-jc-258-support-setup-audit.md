# JC-258 support setup audit implementation plan

> **For agentic workers:** Use subagent-driven-development or executing-plans. Steps use checkbox syntax.

**Goal:** Reproduce support payment-method setup initiation and inspect current detail fields without changing permissions.

**Architecture:** Add one focused DataCase module using existing role and Subscription fixtures, the actual facade, and local Stripe request verification. Keep all data in the normal sandbox and preserve exact application-environment restoration.

**Tech Stack:** Elixir, Ash, ExUnit, PostgreSQL Sandbox and Req.Test.

## Scope

Add one focused audit test module at `test/store/governance/jc258_support_payment_setup_audit_test.exs`. Do not edit production authorization, facade, policy, resource, or UI code. The tests record current actor-driven facade behavior. They do not define the product's `LIMITED` field allowlist, prove setup completion or stored-method replacement, or claim that a support-read policy check itself performed a mutation.

Use `Store.DataCase, async: false`, the existing `Store.TestFixtures`, `Store.SubscriptionsFixtures`, `Store.TestSupport.StripeAPIStub`, and the actual `Store.Subscriptions.Facade`. Keep each fixture in the SQL sandbox. Configure only the local Stripe test key, publishable key, enabled provider, and `StripeAPIStub.req_options()`. Restore `Application.fetch_env(:store, :payments)` exactly on exit, including the distinction between an absent key and a key set to `[]`.

## Proposed complete test module

- [ ] Create the new test file with this complete module. It uses the existing facade and fixture APIs inspected in this branch. It records no provider secret in assertions or output.

```elixir
defmodule Store.Governance.JC258SupportPaymentSetupAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    previous_payments = Application.fetch_env(:store, :payments)
    StripeAPIStub.setup_default(context)
    configure_stripe_test_payments()

    on_exit(fn -> restore_payments(previous_payments) end)
    :ok
  end

  test "support admin detail exposes the actual composed subscription fields" do
    support = actor_with_role!(:support, "jc258_detail_support")
    fixture = stripe_subscription_fixture!("jc258_detail")
    subscription = fixture.subscription
    StripeAPIStub.stub_unexpected!("reading admin detail must not call Stripe")

    assert {:ok, detail} =
             SubscriptionsFacade.get_subscription_detail_for_admin(support, subscription.id)

    assert detail.subscription.id == subscription.id
    assert detail.subscription.user_id == fixture.customer.id
    assert detail.subscription.provider_customer_ref == "cus_jc258_detail"
    assert detail.subscription.provider_billing_ref == "pm_jc258_detail"
    assert detail.subscription.subscription_plan.id == subscription.subscription_plan_id
    assert detail.subscription.pending_subscription_plan == nil
    assert detail.subscription.variant.id == subscription.variant_id
    assert detail.subscription.pending_variant == nil
    assert length(detail.subscription.items) == 1
    assert detail.subscription.stored_payment_method.provider_customer_ref ==
             "cus_jc258_detail"
    assert detail.subscription.stored_payment_method.provider_payment_method_ref ==
             "pm_jc258_detail"
    assert detail.subscription.stored_payment_method.fingerprint == "fp_jc258_detail"
    assert is_list(detail.renewal_attempts)
    assert is_list(detail.plan_targets)
    assert is_list(detail.variant_targets)
    assert detail.action_capabilities.can_update_payment_method?
    assert detail.action_capabilities.payment_method_update_provider == :stripe

    # This captures returned field names for the audit without turning LIMITED
    # into an invented field policy. Keep synthetic references in the fixture.
    assert (Map.keys(Map.from_struct(detail)) |> Enum.sort()) ==
             [:action_capabilities, :plan_targets, :renewal_attempts, :subscription, :variant_targets]

    returned_subscription_fields =
      detail.subscription
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.sort()

    assert :provider_customer_ref in returned_subscription_fields
    assert :provider_billing_ref in returned_subscription_fields
    assert :user_id in returned_subscription_fields
  end

  test "support facade setup invokes Stripe and persists a submitted setup intent" do
    support = actor_with_role!(:support, "jc258_setup_support")
    fixture = stripe_subscription_fixture!("jc258_support_setup")
    input = setup_input!(fixture.subscription.id)
    calls = start_supervised!({Agent, fn -> [] end})

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/setup_intents"
      params = StripeAPIStub.form_params(conn)
      response = StripeAPIStub.setup_intent_response(params)

      Agent.update(calls, &[
        Map.take(params, ["customer", "metadata[local_intent_id]", "metadata[subscription_id]"])
        | &1
      ])

      Req.Test.json(conn, response)
    end)

    assert {:ok, result} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_admin(
               support,
               fixture.subscription.id,
               input
             )

    assert result.provider == :stripe
    assert result.publishable_key == "pk_test_jc258_audit"
    assert is_binary(result.client_secret)

    assert [observed_request] = Agent.get(calls, &Enum.reverse/1)
    assert observed_request["customer"] == "cus_jc258_support_setup"
    assert observed_request["metadata[subscription_id]"] == fixture.subscription.id
    assert observed_request["metadata[local_intent_id]"] == result.payment_intent_id

    intent = fetch_payment_intent!(result.payment_intent_id)
    assert intent.purpose == :subscription_payment_method_update
    assert intent.subscription_id == fixture.subscription.id
    assert intent.provider_customer_ref == "cus_jc258_support_setup"
    assert intent.provider_payment_id =~ ~r/^seti_test_/
    assert intent.state == :submitted
    assert_secret_match!(result.client_secret, intent.provider_client_secret)
    expected_client_secret =
      observed_request
      |> StripeAPIStub.setup_intent_response()
      |> Map.fetch!("client_secret")

    assert_secret_match!(result.client_secret, expected_client_secret)
  end

  test "admin, super admin, and the owning customer can start setup through their facade" do
    calls = start_supervised!({Agent, fn -> [] end})

    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/setup_intents"
      params = StripeAPIStub.form_params(conn)
      response = StripeAPIStub.setup_intent_response(params)

      Agent.update(calls, &[
        Map.take(params, ["customer", "metadata[local_intent_id]", "metadata[subscription_id]"])
        | &1
      ])

      Req.Test.json(conn, response)
    end)

    fixtures_and_results =
      Enum.map([:admin, :super_admin], fn role ->
        actor = actor_with_role!(role, "jc258_#{role}")
        fixture = stripe_subscription_fixture!("jc258_#{role}")
        input = setup_input!(fixture.subscription.id)

        assert {:ok, result} =
                 SubscriptionsFacade.start_subscription_payment_method_update_for_admin(
                   actor,
                   fixture.subscription.id,
                   input
                 )

        assert_setup_result!(result, fixture.subscription.id)
        {fixture, result}
      end)

    fixture = stripe_subscription_fixture!("jc258_owner")
    input = setup_input!(fixture.subscription.id)

    assert {:ok, result} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               fixture.customer,
               fixture.subscription.id,
               input
             )

    assert_setup_result!(result, fixture.subscription.id)
    fixtures_and_results = fixtures_and_results ++ [{fixture, result}]

    assert length(Agent.get(calls, & &1)) == 3

    for {{expected_fixture, expected_result}, observed_request} <-
          Enum.zip(fixtures_and_results, Agent.get(calls, &Enum.reverse/1)) do
      assert observed_request["customer"] == expected_fixture.subscription.provider_customer_ref
      assert observed_request["metadata[subscription_id]"] == expected_fixture.subscription.id
      assert observed_request["metadata[local_intent_id]"] == expected_result.payment_intent_id
    end
  end

  test "admin setup rejects owners, non-owners, and editors before provider work" do
    fixture = stripe_subscription_fixture!("jc258_rejected_admin_setup")
    ordinary_owner = fixture.customer
    non_owner = SubscriptionsFixtures.create_customer!("jc258_admin_non_owner")
    editor = actor_with_role!(:editor, "jc258_editor")
    input = setup_input!(fixture.subscription.id)
    before_count = setup_intent_count(fixture.subscription.id)
    StripeAPIStub.stub_unexpected!("rejected admin setup must not call Stripe")

    for actor <- [ordinary_owner, non_owner, editor] do
      assert {:error, error} =
               SubscriptionsFacade.start_subscription_payment_method_update_for_admin(
                 actor,
                 fixture.subscription.id,
                 input
               )

      assert error.code == "FORBIDDEN"
    end

    assert setup_intent_count(fixture.subscription.id) == before_count
  end

  test "customer setup remains owner scoped and nil actors fail the facade contract" do
    owner_fixture = stripe_subscription_fixture!("jc258_user_owner")
    other_customer = SubscriptionsFixtures.create_customer!("jc258_user_non_owner")
    input = setup_input!(owner_fixture.subscription.id)
    before_count = setup_intent_count(owner_fixture.subscription.id)
    StripeAPIStub.stub_unexpected!("non-owner and nil-actor setup must not call Stripe")

    assert {:ok, nil} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               other_customer,
               owner_fixture.subscription.id,
               input
             )

    assert {:error, error} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_admin(
               nil,
               owner_fixture.subscription.id,
               input
             )

    assert error.code == "VALIDATION_ERROR"
    assert setup_intent_count(owner_fixture.subscription.id) == before_count
  end

  test "support cannot directly create a PaymentIntent under its own actor authority" do
    support = actor_with_role!(:support, "jc258_direct_intent_support")
    fixture = stripe_subscription_fixture!("jc258_direct_intent")
    before_count = setup_intent_count(fixture.subscription.id)
    StripeAPIStub.stub_unexpected!("direct PaymentIntent create must not call Stripe")

    changeset =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        purpose: :subscription_payment_method_update,
        subscription_id: fixture.subscription.id,
        amount_received_minor: 0,
        currency: "USD",
        provider_customer_ref: "cus_jc258_direct_intent",
        payment_intent_key: "jc258-direct-#{Ash.UUIDv7.generate()}"
      })

    assert changeset.valid?

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(changeset, domain: Store.Payments, actor: support)

    assert setup_intent_count(fixture.subscription.id) == before_count
  end

  defp stripe_subscription_fixture!(prefix) do
    customer = SubscriptionsFixtures.create_customer!(prefix)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_#{prefix}",
        provider_billing_ref: "pm_#{prefix}",
        stored_payment_method_fingerprint: "fp_#{prefix}"
      })

    %{customer: customer, subscription: subscription}
  end

  defp actor_with_role!(role, prefix) do
    actor = TestFixtures.register_user!(email: TestFixtures.unique_email(prefix))
    _assignment = TestFixtures.assign_role!(actor, role)
    actor
  end

  defp setup_input!(subscription_id) do
    assert {:ok, input} =
             StartSubscriptionPaymentMethodUpdateInput.new(%{
               "subscription_id" => subscription_id
             })

    input
  end

  defp assert_setup_result!(result, subscription_id) do
    assert result.provider == :stripe
    assert result.publishable_key == "pk_test_jc258_audit"
    assert is_binary(result.client_secret)
    intent = fetch_payment_intent!(result.payment_intent_id)
    assert intent.purpose == :subscription_payment_method_update
    assert intent.subscription_id == subscription_id
    assert intent.state == :submitted
  end

  defp assert_secret_match!(returned_secret, expected_secret) do
    unless is_binary(returned_secret) and returned_secret == expected_secret do
      flunk("returned setup credential did not match the expected value")
    end
  end

  defp setup_intent_count(subscription_id) do
    PaymentIntent
    |> Ash.Query.filter(
      expr(
        subscription_id == ^subscription_id and purpose == :subscription_payment_method_update
      )
    )
    |> Ash.count!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_payment_intent!(payment_intent_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^payment_intent_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp configure_stripe_test_payments do
    payments = Application.get_env(:store, :payments, [])
    stripe = Keyword.get(payments, :stripe, [])

    stripe =
      Keyword.merge(stripe,
        webhook_secret: "whsec_jc258_local_only",
        secret_key: "sk_test_jc258_audit",
        publishable_key: "pk_test_jc258_audit",
        request_options: StripeAPIStub.req_options()
      )

    Application.put_env(
      :store,
      :payments,
      payments
      |> Keyword.put(:enabled_providers, [:stripe])
      |> Keyword.put(:stripe, stripe)
    )
  end

  defp restore_payments(:error), do: Application.delete_env(:store, :payments)
  defp restore_payments({:ok, previous}), do: Application.put_env(:store, :payments, previous)
end
```

Before the implementation worker copies this module, review its proposed code against the exact branch. In particular, preserve the described assertions only when the relevant behavior still matches source. If formatting or Credo requires splitting long assertions, keep the behavior and coverage intact.

## Why these scenarios belong in this audit

- The support detail test records actual returned field names and synthetic provider references. It does not call any field forbidden. Since the matrix says `LIMITED` without naming an allowlist, the audit must report observed exposure and `NEEDS_PRODUCT_DECISION` instead of deciding which field should be hidden.
- The support initiation test runs the public actor-bearing admin facade with a valid, eligible Subscription, captures one stubbed Stripe setup-intent POST, and reads back the persisted PaymentIntent. It compares the returned credential with both the persisted field and the deterministic dummy response while keeping the credential out of failure output. This demonstrates the facade's support-read to system-write path. It does not test webhook completion or stored-method replacement.
- Admin, super-admin, and owner controls use an explicit setup-intent-only stub, require exactly three POSTs, and match each request's customer and metadata to its fresh Subscription and returned local intent ID.
- Ordinary-owner, non-owner-customer, and editor admin-facade calls must fail with the stable authorization error before either a provider request or a setup-purpose PaymentIntent write for that Subscription. The separate customer non-owner USER case records the facade's actual owner-scoped lookup result (`{:ok, nil}`), not a policy denial. A nil actor records the facade's existing argument contract result.
- The direct support Ash create uses valid accepted attributes. `Ash.Error.Forbidden` is the only denial counted as proof; a validation or state error would not satisfy this assertion. The before-and-after count includes only setup-purpose intents for the fixture Subscription.

The setup permission behavior is an audit candidate, not a fix request. Record the exact observed client-secret return in the audit evidence without copying a secret value into test output. Do not claim that `LIMITED` forbids any particular field until product authority names those fields.

## Verification for the implementation worker

- [ ] Format the new module, then run each command in its own shell invocation. Capture the exit status and output for each command. Use the required DevCore test environment and four-connection pool values. The worker should stop and report an environment/bootstrap failure if DevCore fails, not replace the test database or use a direct Mix command.

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/governance/jc258_support_payment_setup_audit_test.exs
```

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/facade_test.exs test/store/governance/subscriptions_policy_matrix_test.exs
```

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted
```

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/governance/jc258_support_payment_setup_audit_test.exs
```

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
```

Use a shell helper around each command to save its actual `$?` immediately and retain complete stdout/stderr. Do not print database credentials or include provider client secrets in captured output. Do not claim success unless each command returns zero.

## Evidence limits and review notes

The module does not assert an intended field policy because none is specified. It does not prove a support actor can complete setup, bind a replacement payment method, charge a customer, or transition the subscription. Its positive setup assertion proves that the current facade returns setup credentials and persists a submitted setup-purpose intent after a real local provider stub call. The direct create control proves only that support cannot execute the declared PaymentIntent `:create` action directly under its support actor. It does not prove that all PaymentIntent actions or all system-authorized calls are unavailable to support.

The actual error assertions rely on the inspected normalization contract: Ash forbidden errors become `FORBIDDEN`, while invalid facade arguments become `VALIDATION_ERROR`. If the focused test observes a different stable result, preserve the result as evidence and classify the difference. Do not weaken the assertion to accept unrelated validation or state errors.

- [ ] Commit only the new test module after verification and self-review.

## Root self-review

The plan covers the six requested scenarios with exact owned setup-intent counts, a direct valid-input support denial, strict setup request metadata checks, and permitted actor controls. Field exposure is observed without inventing LIMITED scope. No binding completion, charge, lifecycle, live provider, global row-count or production permission claim is introduced. Called helpers and fingerprint overrides exist in the current fixture source. Root reviewed the complete code, changed global counts to owned counts through author revision, and checked the complete module syntax before handoff.
