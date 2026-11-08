defmodule Store.Subscriptions.Jc247AKeepDuringGraceTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "first bound payment failure establishes keep-grace EFFECTIVE target at grace boundary" do
    fixture = create_due_fixture!("jc247_a_first_failure")

    fixture = prepare_observation!(fixture, "canceled")

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    attempt = fetch_attempt!(subscription.id)

    assert subscription.status == :past_due
    assert subscription.current_dunning_renewal_attempt_id == attempt.id
    assert %DateTime{} = subscription.failed_payment_boundary_at

    [effect] = access_effects!(subscription.id)
    assert effect.disposition == :effective
    assert effect.entitlement_kind == :membership_access
    assert effect.valid_from_at == subscription.current_period_start_at
    assert effect.valid_until_at == subscription.failed_payment_boundary_at
    assert effect.plan_revision_id == subscription.current_plan_revision_id
    assert effect.contract_change_id == subscription.current_contract_change_id
  end

  test "past_due retry failure does not establish a second keep-grace producer effect" do
    fixture = create_due_fixture!("jc247_a_retry_no_second_effect")

    fixture = prepare_observation!(fixture, "canceled")

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    [first_effect] = access_effects!(subscription.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             prepare_retry_observation!(fixture, subscription.next_retry_at, "canceled")

    subscription = reload_subscription!(subscription.id)
    effects = access_effects!(subscription.id)
    assert length(effects) == 1
    assert hd(effects).id == first_effect.id
    assert subscription.aggregate_version > first_effect.source_version
  end

  test "nil/nil funded composition produces EFFECTIVE keep-grace target without valid_from_at" do
    fixture = create_due_fixture!("jc247_a_nil_nil", entitlement_pair: {nil, nil})

    fixture = prepare_observation!(fixture, "canceled")

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)

    [effect] = access_effects!(subscription.id)
    assert effect.disposition == :effective
    assert effect.entitlement_kind == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == subscription.failed_payment_boundary_at
  end

  test "effect establishment failure rolls back commercial past_due transition" do
    fixture = create_due_fixture!("jc247_a_effect_rollback")

    fixture = prepare_observation!(fixture, "canceled")

    before = reload_subscription!(fixture.subscription.id)
    fail_access_effect_insert!(fixture.subscription.id)

    assert {:error, error} =
             Repo.checkout(fn ->
               Repo.query!(
                 "SELECT set_config('store.jc247_fail_access_effect_subscription', $1, true)",
                 [fixture.subscription.id]
               )

               fixture.run.()
             end)

    assert reload_subscription!(fixture.subscription.id).status == before.status
    assert access_effects!(fixture.subscription.id) == []
    assert error.code in ["PAYMENT_FAILED", "INTERNAL_ERROR"]
  end

  test "first authentication-required transition establishes keep-grace effect and preserves outer result" do
    fixture = create_due_fixture!("jc247_a_auth_required")

    fixture = prepare_observation!(fixture, "requires_action")

    assert {:ok, :processed} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    assert subscription.status == :past_due
    assert subscription.billing_status_reason == "PAYMENT_AUTHENTICATION_REQUIRED"

    [effect] = access_effects!(subscription.id)
    assert effect.disposition == :effective
    assert effect.valid_until_at == subscription.failed_payment_boundary_at
  end

  test "authentication-required replay does not create a second keep-grace producer effect" do
    fixture = create_due_fixture!("jc247_a_auth_replay")
    fixture = prepare_observation!(fixture, "requires_action")

    assert {:ok, :processed} = fixture.run.()
    subscription = reload_subscription!(fixture.subscription.id)
    [first_effect] = access_effects!(subscription.id)

    stub_observation!(fixture.reached, "requires_action")

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: DateTime.add(subscription.failed_payment_boundary_at, -1, :second)
             )

    assert length(access_effects!(subscription.id)) == 1
    assert hd(access_effects!(subscription.id)).id == first_effect.id
  end

  test "fault injection for one subscription does not break AccessEffect insert for another" do
    armed = create_due_fixture!("jc247_a_fault_isolation_armed")
    other = create_due_fixture!("jc247_a_fault_isolation_other")

    other = prepare_observation!(other, "canceled")
    fail_access_effect_insert!(armed.subscription.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} = other.run.()
    assert length(access_effects!(other.subscription.id)) == 1
    assert access_effects!(armed.subscription.id) == []
  end

  test "malformed keep-grace pair interval rolls back past_due without AccessEffect" do
    fixture = create_due_fixture!("jc247_a_malformed_pair")
    fixture = prepare_observation!(fixture, "canceled")
    force_malformed_keep_grace_boundary!(fixture.subscription.id)

    before = reload_subscription!(fixture.subscription.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Repo.checkout(fn ->
               Repo.query!(
                 "SELECT set_config('store.jc247_malformed_boundary_subscription', $1, true)",
                 [fixture.subscription.id]
               )

               Repo.query!("SELECT set_config('store.jc247_force_malformed_boundary', '1', true)")

               fixture.run.()
             end)

    assert reload_subscription!(fixture.subscription.id).status == before.status
    assert access_effects!(fixture.subscription.id) == []
  end

  test "postcommit F1 convergence does not change committed payment-failure outer result" do
    fixture = create_due_fixture!("jc247_a_f1_error_outer")

    fixture = prepare_observation!(fixture, "canceled")

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()
    subscription = reload_subscription!(fixture.subscription.id)
    assert subscription.status == :past_due
    [effect] = access_effects!(subscription.id)

    assert {:ok, :noop} = Facade.execute_effective_access_effect_for_system(effect.id)

    {:ok, %{rows: [[status]]}} =
      Repo.query("SELECT status FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(effect.id)])

    assert status == "applied"
    assert reload_subscription!(subscription.id).status == :past_due
  end

  defp create_due_fixture!(label, opts \\ []) do
    {kind, scope} =
      Keyword.get(opts, :entitlement_pair, {:membership_access, "membership:#{label}"})

    now = db_now!()
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan_attrs = %{
      interval_unit: :day,
      interval_count: 1,
      retry_schedule_hours: [0, 24, 72],
      max_retry_attempts: 3,
      grace_period_days: 7
    }

    plan_attrs =
      if kind == nil and scope == nil do
        Map.merge(plan_attrs, %{entitlement_kind: nil, entitlement_scope_key: nil})
      else
        Map.merge(plan_attrs, %{entitlement_kind: kind, entitlement_scope_key: scope})
      end

    plan = SubscriptionsFixtures.create_subscription_plan!(plan_attrs)

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{label}",
        started_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :microsecond)
      })

    %{
      subscription: subscription,
      now: now,
      run: fn -> Facade.process_due_subscription_renewal_for_system(subscription.id, now: now) end
    }
  end

  defp prepare_observation!(fixture, status) do
    StripeAPIStub.stub_unexpected!("legacy preparation must not contact Stripe")
    reached = ReachedRenewalFixtures.prepare_reached!(fixture.subscription.id, fixture.now)
    stub_observation!(reached, status)
    Map.put(fixture, :reached, reached)
  end

  defp prepare_retry_observation!(fixture, now, status) do
    StripeAPIStub.stub_unexpected!("legacy retry preparation must not contact Stripe")
    reached = ReachedRenewalFixtures.prepare_reached!(fixture.subscription.id, now)
    first = fixture.reached

    assert reached.attempt.id == first.attempt.id
    assert reached.order.id == first.order.id
    refute reached.collection.id == first.collection.id
    refute reached.payment_intent.id == first.payment_intent.id

    stub_observation!(reached, status)
    Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: now)
  end

  defp stub_observation!(reached, status) do
    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, status)
    )
  end

  defp unique_label(label), do: "#{label}_#{Ecto.UUID.generate()}"

  defp db_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp reload_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effects!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp force_malformed_keep_grace_boundary!(subscription_id) do
    {trigger_name, function_name} = install_subscription_boundary_trigger!(subscription_id)
    on_exit(fn -> drop_trigger_and_function!("subscriptions", trigger_name, function_name) end)
  end

  defp fail_access_effect_insert!(subscription_id) do
    {trigger_name, function_name} = install_access_effect_insert_trigger!()
    on_exit(fn -> drop_trigger_and_function!("access_effects", trigger_name, function_name) end)

    Repo.checkout(fn ->
      Repo.query!(
        "SELECT set_config('store.jc247_fail_access_effect_subscription', $1, true)",
        [subscription_id]
      )
    end)
  end

  defp install_access_effect_insert_trigger! do
    suffix = System.unique_integer([:positive])
    trigger_name = "jc247_fail_access_effect_#{suffix}"
    function_name = "jc247_fail_access_effect_fn_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.subscription_id::text = current_setting('store.jc247_fail_access_effect_subscription', true) THEN
        RAISE EXCEPTION 'injected JC-247 AccessEffect insert failure';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON access_effects
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp install_subscription_boundary_trigger!(_subscription_id) do
    suffix = System.unique_integer([:positive])
    trigger_name = "jc247_malformed_boundary_#{suffix}"
    function_name = "jc247_malformed_boundary_fn_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF current_setting('store.jc247_force_malformed_boundary', true) = '1'
         AND NEW.status::text = 'past_due'
         AND NEW.id::text = current_setting('store.jc247_malformed_boundary_subscription', true) THEN
        NEW.failed_payment_boundary_at := NEW.current_period_start_at;
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp drop_trigger_and_function!(table, trigger_name, function_name) do
    Repo.query("DROP TRIGGER IF EXISTS #{trigger_name} ON #{table}")
    Repo.query("DROP FUNCTION IF EXISTS #{function_name}()")
    :ok
  end
end
