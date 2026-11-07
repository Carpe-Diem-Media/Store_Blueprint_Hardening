# JC-290 renewal dispatch integration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development with separate spec and quality reviews.

**Goal:** Apply current method authority to every renewal charge POST, including uncertain-request replay, while retaining exact financial evidence.

**Architecture:** Fresh dispatch takes the existing session gates before its short claim transaction. Exact-reference replay uses the same gates and must match current authority to its captured references. Requests return from checkout before response application. A changed method permits exact observation, never substitution or a new financial request. A due worker may still observe a reached request after current chargeability is withdrawn.

**Tech stack:** Existing Subscriptions facade, Ash resources, PostgreSQL, session helper, ExUnit and StripeAPIStub. No schema, dependency, service, provider contract or pool change.

## Files and prerequisites

Modify lib/store/subscriptions/facade.ex. Create test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs. The mutation and session helper tasks must have passed separate reviews. Preserve their APIs and keys. The final CI/resource evidence task will add this module and the cleanup module to both required connection-test runs.

## Task 3: Guard every charge request

- [ ] Write the functional regression cases below before production changes. The dispatcher-first case must fail because a writer commits before the actual POST, not because an event is absent. The crash-before-request case characterizes exact recovery and must not POST a stale method. All installed adapters currently prohibit replay POSTs, so this case already passed before integration. Retain the raw RED output.
- [ ] Keep request_off_session_renewal_charge/6's existing pre-claim observation event, reconciliation decision, typed input and outer authentication settlement. Replace only the attach-and-submit case with this call:

```elixir
dispatch_renewal_collection(subscription, plan, bound_attempt, collection_attempt, input, now)
```

Add these functions. The callback verifies current identity again after both gates are held. A fresh claim still commits before the observation seam and HTTP. The released event means gates released, never payment success or proof of provider receipt.

```elixir
defp dispatch_renewal_collection(subscription, plan, bound_attempt, collection, input, now) do
  result =
    if collection.dispatch_state == :not_started do
      PaymentMethodAuthorityGate.with_dispatch_session_gates(
        subscription.user_id,
        subscription.provider,
        fn -> current_dispatch_identity(subscription) end,
        fn identity, proof ->
          with {:ok, current} <- current_dispatch_identity(subscription),
               true <- current == identity,
               {:ok, claim} <- RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input) do
            if claim.dispatch_claimed? do
              attempt = claim.renewal_attempt || bound_attempt
              emit_fresh_dispatch_claimed(subscription, attempt, claim)

              with {:ok, payment_intent} <- maybe_submit_virtual_payment_intent(claim.payment_intent),
                   :ok <- PaymentMethodAuthorityGate.confirm_dispatch_session(proof) do
                response = initiate_renewal_charge(
                  subscription, attempt, claim.order, payment_intent,
                  claim.provider_payment_method, claim.collection_attempt
                )
                {:fresh_response, attempt, claim.order, payment_intent, claim.collection_attempt, response}
              end
            else
              {:existing_claim, claim}
            end
          else
            false -> {:error, :method_authority_changed}
            error -> error
          end
        end
      )
    else
      case RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input) do
        {:ok, claim} -> {:existing_claim, claim}
        error -> error
      end
    end

  case result do
    {:fresh_response, attempt, order, payment_intent, claimed_collection, response} ->
      emit_dispatch_gate_released(subscription, attempt, claimed_collection, payment_intent)
      apply_off_session_renewal_response(
        subscription, attempt, order, payment_intent, claimed_collection, response, now
      )

    {:existing_claim, claim} ->
      submit_claimed_renewal_collection(subscription, plan, bound_attempt, claim, now)

    {:error, %Error{code: "RENEWAL_AUTHORITY_WITHDRAWN"}} ->
      fence_withdrawn_renewal_collection(collection, now)

    {:error, reason} when reason in [:method_authority_changed, :lock_unavailable, :transaction_required] ->
      {:error, stale_dispatch_authority()}

    error -> error
  end
end

defp current_dispatch_identity(subscription) do
  with {:ok, current} <- fetch_subscription_for_renewal(subscription.id),
       true <- current.user_id == subscription.user_id and current.provider == subscription.provider,
       {:ok, method} <- fetch_active_stored_payment_method(current),
       true <- method.provider == current.provider,
       true <- current.provider_customer_ref == method.provider_customer_ref,
       true <- current.provider_billing_ref == method.provider_payment_method_ref do
    {:ok, %{
      provider: current.provider,
      method_id: method.id,
      customer_ref: method.provider_customer_ref,
      method_ref: method.provider_payment_method_ref
    }}
  else
    false -> {:error, :method_authority_changed}
    {:error, %Error{code: "PAYMENT_METHOD_REQUIRED"}} -> {:error, :method_authority_changed}
    _ -> {:error, :lock_unavailable}
  end
end

defp request_captured_renewal_charge(subscription, attempt, order, payment_intent, method, collection) do
  result = PaymentMethodAuthorityGate.with_dispatch_session_gates(
    subscription.user_id,
    subscription.provider,
    fn -> current_dispatch_identity(subscription) end,
    fn identity, proof ->
      with {:ok, current} <- current_dispatch_identity(subscription),
           true <- current == identity,
           true <- captured_method_matches?(current, payment_intent, method),
           {:ok, submitted} <- maybe_submit_virtual_payment_intent(payment_intent),
           :ok <- PaymentMethodAuthorityGate.confirm_dispatch_session(proof) do
        response = initiate_renewal_charge(subscription, attempt, order, submitted, method, collection)
        {:captured_response, submitted, response}
      else
        false -> {:error, :method_authority_changed}
        error -> error
      end
    end
  )

  case result do
    {:captured_response, submitted, response} ->
      emit_dispatch_gate_released(subscription, attempt, collection, submitted)
      {:captured_response, submitted, response}

    {:error, :method_authority_changed} -> {:observe_captured, payment_intent}
    {:error, reason} when reason in [:lock_unavailable, :transaction_required] ->
      {:error, stale_dispatch_authority()}
    error -> error
  end
end

defp captured_method_matches?(identity, payment_intent, method) do
  identity.customer_ref == payment_intent.provider_customer_ref and
    identity.method_ref == payment_intent.provider_payment_method_ref and
    identity.customer_ref == method.provider_customer_ref and
    identity.method_ref == method.provider_payment_method_ref
end

defp initiate_renewal_charge(subscription, attempt, order, payment_intent, method, collection) do
  Providers.charge_off_session(
    subscription.provider,
    renewal_collection_charge_request(attempt, order, payment_intent, method, collection),
    []
  )
end

defp stale_dispatch_authority do
  Error.new("STALE_RECORD", "renewal dispatch authority changed before provider request")
end

defp emit_fresh_dispatch_claimed(subscription, attempt, claim) do
  :telemetry.execute(
    [:store, :subscriptions, :renewal_charge_dispatch_claimed], %{},
    %{source: :fresh_dispatch, subscription_id: subscription.id,
      renewal_attempt_id: attempt.id, collection_attempt_id: claim.collection_attempt.id,
      payment_intent_id: claim.payment_intent.id}
  )
end

defp emit_dispatch_gate_released(subscription, attempt, collection, payment_intent) do
  :telemetry.execute(
    [:store, :subscriptions, :renewal_charge_dispatch_released], %{},
    %{subscription_id: subscription.id, renewal_attempt_id: attempt.id,
      collection_attempt_id: collection.id, payment_intent_id: payment_intent.id}
  )
end
```

- [ ] Replace submit_off_session_renewal_charge/8 with this wrapper and move its existing response logic into apply_off_session_renewal_response/7. Exact observation after changed method remains outside the gates.

```elixir
defp submit_off_session_renewal_charge(
       subscription, _plan, attempt, order, payment_intent, method, collection, now
     ) do
  case request_captured_renewal_charge(subscription, attempt, order, payment_intent, method, collection) do
    {:observe_captured, exact_intent} -> reconcile_existing_renewal_collection(exact_intent, collection)
    {:captured_response, submitted, response} ->
      apply_off_session_renewal_response(subscription, attempt, order, submitted, collection, response, now)
    error -> error
  end
end

defp apply_off_session_renewal_response(
       subscription, attempt, order, payment_intent, collection, response, now
     ) do
  with {:ok, charge_response} <- response,
       {:ok, payment_intent} <- persist_payment_intent_provider_refs(payment_intent, charge_response),
       observation <- direct_charge_observation(subscription.provider, payment_intent, charge_response),
       {:ok, %{outcome: outcome}} <-
         PaymentsFacade.record_and_apply_payment_observation_for_system(payment_intent, observation) do
    handle_off_session_renewal_outcome(
      outcome, subscription, attempt, order, payment_intent, collection, charge_response, now
    )
  else
    {:error, %Error{code: "PAYMENT_EVENT_UNVERIFIED"}} ->
      {:error, Error.new("PAYMENT_OUTCOME_UNRESOLVED", "provider response does not identify the exact payment transaction")}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] Replace the separate not-due submit_reached_collection/7 path too. Preserve its existing replayed_collection_outcome mapping. There must be only one Providers.charge_off_session call site left in this facade, inside initiate_renewal_charge, and both of its callers must hold the session gates.

```elixir
defp submit_reached_collection(
       subscription, attempt, order, payment_intent, method, collection, financial_outcome
     ) do
  if financial_outcome == :unresolved do
    case request_captured_renewal_charge(subscription, attempt, order, payment_intent, method, collection) do
      {:observe_captured, exact_intent} -> reconcile_reached_collection(exact_intent)
      {:captured_response, submitted, response} ->
        apply_replayed_charge_response(subscription, submitted, response)
      error -> error
    end
  else
    {:error, Error.new(
      "PAYMENT_OUTCOME_UNRESOLVED", "only an unresolved collection may be replayed for submission",
      %{existing_collection_replay?: true}
    )}
  end
end

defp apply_replayed_charge_response(subscription, submitted, response) do
  with {:ok, charge_response} <- response,
       {:ok, updated} <- persist_payment_intent_provider_refs(submitted, charge_response),
       {:ok, %{outcome: outcome}} <- PaymentsFacade.record_and_apply_payment_observation_for_system(
         updated, direct_charge_observation(subscription.provider, updated, charge_response)
       ) do
    replayed_collection_outcome(updated, outcome)
  else
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] In run_claimed_due_renewal/4's else clauses, handle PAYMENT_METHOD_REQUIRED before the generic renewal_failure clause. Existing fresh missing-method behavior remains when there is no reached collection. An existing reached collection may be observed without authorizing any POST.

```elixir
{:error, %Error{code: "PAYMENT_METHOD_REQUIRED"} = reason} ->
  reconcile_reached_after_method_withdrawal(subscription, attempt, now, reason)
```

```elixir
defp reconcile_reached_after_method_withdrawal(subscription, attempt, now, original_reason) do
  case RenewalCollectionAttempts.recover_reached_for_subscription_for_system(subscription.id, now) do
    {:ok, %{renewal_attempt: %{id: attempt_id}, payment_intent: intent, collection_attempt: collection}}
    when attempt_id == attempt.id ->
      reconcile_existing_renewal_collection(intent, collection)
      |> classify_claimed_renewal_charge_result(collection)

    {:ok, nil} -> {:renewal_failure, original_reason, nil}
    {:ok, _other_occurrence} ->
      {:error, Error.new("PAYMENT_OUTCOME_UNRESOLVED", "reached collection belongs to another renewal occurrence",
                         %{existing_collection_replay?: true})}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] Keep all immutable charged-contract, collection, PaymentIntent, reservation and request identities. Never reset uncertainty or mint another collection because a method changed. Unsupported observation keeps the existing unresolved result and evidence. New gate errors become STALE_RECORD and bypass dunning; existing provider result classification is preserved. Do not change RenewalCollectionDispatchPolicy or provider capabilities.

## Functional regression module

- [ ] Create the following module before changing production. Run its three cases with real connections and retain RED. Use the existing resource APIs and committed fixture cleanup.

```elixir
defmodule Store.Subscriptions.JC290PaymentMethodDispatchRaceTest do
  use ExUnit.Case, async: false
  @moduletag :real_connections
  @moduletag timeout: 60_000

  import Ash.Expr
  require Ash.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.{PaymentMethodAuthorityGate, StoredPaymentMethod, Subscription}
  alias Store.Subscriptions.Facade
  alias Store.SubscriptionsFixtures
  alias Store.Support.AshNotifications
  alias Store.TestSupport.StripeAPIStub

  setup_all do
    assert_test_database!()
    assert Repo.config()[:pool_size] >= 4
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup context do
    owner = Sandbox.start_owner!(Store.DirectRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "a dispatch blocks replacement through POST and applies success after replacement" do
    fixture = create_dispatch_fixture!("dispatch_first")
    parent = self()
    ref = make_ref()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed, :released])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      send(parent, {ref, :post, params})
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)

    dispatcher = start_dispatch(fixture)
    writer_key = {ref, :writer_task}

    try do
      assert_receive {^ref, :claimed, dispatcher_beam, dispatcher_pg, ids, false}, 10_000
      assert [[nil]] == Repo.query!("SELECT xact_start FROM pg_stat_activity WHERE pid=$1", [dispatcher_pg]).rows
      assert reached_identity!(fixture).collection_id == ids.collection_attempt_id

      writer = Task.async(fn ->
        Repo.checkout(fn ->
          send(parent, {ref, :writer_backend, backend_pid!()})
          mutate_method!(fixture, :replace)
          send(parent, {ref, :writer_committed})
          :ok
        end, timeout: 30_000)
      end)
      Process.put(writer_key, writer)
      assert_receive {^ref, :writer_backend, writer_pg}, 3_000
      refute writer_pg == dispatcher_pg
      assert_writer_blocked!(ref, writer_pg, dispatcher_pg)
      send(dispatcher_beam, {ref, :release, :claimed})
      assert_receive {^ref, :post, params}, 10_000
      assert params["payment_method"] == fixture.refs.old_method
      assert params["customer"] == fixture.refs.provider_customer
      assert_receive {^ref, :released, released_beam, _pg, released_ids, false}, 10_000
      assert released_ids.payment_intent_id == ids.payment_intent_id
      assert_receive {^ref, :writer_committed}, 10_000
      assert :ok = Task.await(writer, 3_000)
      assert current_subscription!(fixture).provider_billing_ref == fixture.refs.new_method
      send(released_beam, {ref, :release, :released})
      assert {:ok, :processed} = Task.await(dispatcher, 10_000)
      exact = reached_identity!(fixture)
      assert exact.payment_intent_id == ids.payment_intent_id
      assert exact.financial_outcome == "verified_success"
      assert exact.intent_method == fixture.refs.old_method
      assert exact.order_state == "paid"
      assert current_subscription!(fixture).provider_billing_ref == fixture.refs.new_method
    after
      :telemetry.detach(handler)
      send(dispatcher.pid, {ref, :release, :claimed})
      send(dispatcher.pid, {ref, :release, :released})
      Task.shutdown(dispatcher, :brutal_kill)
      if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  test "replacement after a crash before the first POST prevents stale replay" do
    fixture = create_dispatch_fixture!("crash")
    ref = make_ref()
    parent = self()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
    posts = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      send(parent, {ref, :unexpected_post, params})
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params, %{"status" => "processing"}))
    end)
    dispatcher = start_dispatch(fixture)

    try do
      assert_receive {^ref, :claimed, _beam, dispatcher_pg, ids, false}, 10_000
      before = reached_identity!(fixture)
      assert before.payment_intent_id == ids.payment_intent_id
      assert :atomics.get(posts, 1) == 0
      Process.unlink(dispatcher.pid)
      Process.exit(dispatcher.pid, :kill)
      assert_receive {:DOWN, monitor, :process, pid, :killed}, 3_000
      assert monitor == dispatcher.ref and pid == dispatcher.pid
      assert_eventually(fn -> Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [dispatcher_pg]).rows == [[0]] end)
      :telemetry.detach(handler)
      mutate_method!(fixture, :replace)
      result = Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: fixture.now)
      assert :atomics.get(posts, 1) == 0, "recovery POSTed the withdrawn captured method"
      assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} = result
      after_recovery = reached_identity!(fixture)
      assert Map.take(after_recovery, [:attempt_id, :collection_id, :payment_intent_id, :request_ref, :intent_method]) ==
               Map.take(before, [:attempt_id, :collection_id, :payment_intent_id, :request_ref, :intent_method])
      assert after_recovery.dispatch_state == "may_have_been_reached"
      assert after_recovery.financial_outcome == "unresolved"
      assert after_recovery.attempt_count == 1
      refute_receive {^ref, :unexpected_post, _}, 0
    after
      :telemetry.detach(handler)
      send(dispatcher.pid, {ref, :release, :claimed})
      Task.shutdown(dispatcher, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  test "a due worker observes the exact in-flight payment after method revocation" do
    fixture = create_dispatch_fixture!("observe_revoked")
    ref = make_ref()
    parent = self()
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      body = StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      send(parent, {ref, :submitted, body})
      StripeAPIStub.json_response(conn, body)
    end)

    try do
      assert {:ok, :processed} = Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: fixture.now)
      assert_receive {^ref, :submitted, body}, 3_000
      before = reached_identity!(fixture)
      mutate_method!(fixture, :revoke)
      StripeAPIStub.stub_observation(fn conn ->
        assert conn.method == "GET", "revoked method started another charge request"
        assert conn.request_path == "/v1/payment_intents/#{body["id"]}"
        send(parent, {ref, :observed})
        StripeAPIStub.json_response(conn, Map.put(body, "status", "succeeded"))
      end)
      assert {:ok, :processed} = Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: fixture.now)
      assert_receive {^ref, :observed}, 3_000
      after_recovery = reached_identity!(fixture)
      assert after_recovery.payment_intent_id == before.payment_intent_id
      assert after_recovery.collection_id == before.collection_id
      assert after_recovery.attempt_id == before.attempt_id
      assert after_recovery.financial_outcome == "verified_success"
      assert after_recovery.order_state == "paid"
      assert after_recovery.method_status == "revoked"
    after
      cleanup_dispatch_fixture!(fixture)
    end
  end

  defp start_dispatch(fixture) do
    Task.async(fn ->
      Repo.checkout(fn ->
        Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: fixture.now)
      end, timeout: 60_000)
    end)
  end

  defp attach_dispatch_barrier!(fixture, ref, phases) do
    parent = self()
    handler = {__MODULE__, ref}
    events = Enum.map(phases, &[:store, :subscriptions, event_name(&1)])
    :ok = :telemetry.attach_many(handler, events, fn event, _, metadata, _ ->
      if metadata.subscription_id == fixture.subscription.id do
        phase = if List.last(event) == :renewal_charge_dispatch_claimed, do: :claimed, else: :released
        send(parent, {ref, phase, self(), backend_pid!(), metadata, Repo.in_transaction?()})
        receive do
          {^ref, :release, ^phase} -> :ok
        after
          15_000 -> raise "JC290 dispatch barrier expired"
        end
      end
    end, nil)
    handler
  end
  defp event_name(:claimed), do: :renewal_charge_dispatch_claimed
  defp event_name(:released), do: :renewal_charge_dispatch_released
  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp current_subscription!(fixture) do
    Subscription
    |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reached_identity!(fixture) do
    sql = """
    SELECT a.id::text, c.id::text, p.id::text, p.provider_request_reference,
           p.provider_payment_method_ref, c.dispatch_state, c.financial_outcome,
           o.state, m.status,
           (SELECT count(*) FROM renewal_attempts WHERE subscription_id=a.subscription_id)
    FROM renewal_attempts a JOIN renewal_collection_attempts c ON c.renewal_attempt_id=a.id
    JOIN payment_intents p ON p.id=c.payment_intent_id JOIN orders o ON o.id=p.order_id
    JOIN stored_payment_methods m ON m.user_id=o.user_id AND m.provider='stripe'
      AND m.provider_customer_ref=p.provider_customer_ref
      AND m.provider_payment_method_ref=p.provider_payment_method_ref
    WHERE a.subscription_id=$1::text::uuid
    """
    [row] = Repo.query!(sql, [fixture.subscription.id]).rows
    [:attempt_id, :collection_id, :payment_intent_id, :request_ref, :intent_method,
     :dispatch_state, :financial_outcome, :order_state, :method_status, :attempt_count]
    |> Enum.zip(row) |> Map.new()
  end

  defp assert_writer_blocked!(ref, writer, dispatcher) do
    assert_eventually(fn ->
      receive do
        {^ref, :writer_committed} -> flunk("replacement committed before the actual charge POST")
      after
        0 -> :ok
      end
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [dispatcher, writer]).rows == [[true]]
    end)
  end

  defp assert_eventually(fun, remaining \\ 400) do
    cond do
      fun.() -> :ok
      remaining == 0 -> flunk("database condition did not become true")
      true -> Process.sleep(5); assert_eventually(fun, remaining - 1)
    end
  end
defp create_dispatch_fixture!(label) do
  suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  customer = SubscriptionsFixtures.create_customer!("jc290_#{label}_#{suffix}")
  %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

  plan = SubscriptionsFixtures.create_subscription_plan!(%{
    interval_unit: :day,
    interval_count: 1,
    amount_minor: 2_600,
    retry_schedule_hours: [0, 24, 72],
    max_retry_attempts: 3,
    grace_period_days: 7
  })

  variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
  now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
  refs = %{
    provider_customer: "cus_jc290_#{suffix}",
    old_method: "pm_jc290_old_#{suffix}",
    new_method: "pm_jc290_new_#{suffix}"
  }

  created = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
    provider: :stripe,
    provider_customer_ref: refs.provider_customer,
    provider_billing_ref: refs.old_method,
    started_at: DateTime.add(now, -86_400, :second),
    next_renewal_at: DateTime.add(now, -1, :microsecond)
  })

  subscription =
    Subscription
    |> Ash.Query.filter(expr(id == ^created.subscription.id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

  %{
    customer: customer,
    product: product,
    variant: variant,
    variant_plan: variant_plan,
    plan: plan,
    subscription: subscription,
    item: created.item,
    order: created.order,
    line_item: created.line_item,
    revision: created.revision,
    refs: refs,
    now: now
  }
end

defp cleanup_dispatch_fixture!(fixture) do
  subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
  user_id = Ecto.UUID.dump!(fixture.customer.id)
  variant_id = Ecto.UUID.dump!(fixture.variant.id)
  plan_id = Ecto.UUID.dump!(fixture.plan.id)
  product_id = Ecto.UUID.dump!(fixture.product.id)

  case Repo.transaction(fn ->
         Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])
         Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

         Repo.query!(
           "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!(
           "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!(
           "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
           [user_id]
         )

         Repo.query!(
           "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL, current_contract_change_id = NULL WHERE id = $1",
           [subscription_id]
         )

         Repo.query!("ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard")

         try do
           Repo.query!(
             "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
             [subscription_id]
           )
         after
           Repo.query!("ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard")
         end

         Repo.query!(
           "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
           [user_id]
         )

         Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
         Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [subscription_id])
         Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
         Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

         Repo.query!(
           "DELETE FROM email_outboxes WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!(
           "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!(
           "DELETE FROM fulfillment_orders WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!(
           "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!(
           "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
           [user_id]
         )

         Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
         Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])
         Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
         Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
         Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
         Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
         Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
         Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
       end,
       timeout: 30_000
     ) do
    {:ok, _result} -> :ok
    {:error, reason} -> raise "unable to clean JC-290 fixture: #{inspect(reason)}"
  end
end

defp assert_test_database! do
  expected_database =
    System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test") <>
      (System.get_env("STORE_TEST_DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") || "")

  actual_database = Repo.config()[:database]

  unless Mix.env() == :test and actual_database == expected_database do
    raise "contention test database guard failed: MIX_ENV=#{inspect(Mix.env())}, " <>
            "configured_database=#{inspect(actual_database)}, expected_database=#{inspect(expected_database)}"
  end

  :ok
end

defp mutate_method!(fixture, :replace) do
  {:ok, {result, notifications}} = Repo.transaction(fn ->
    :ok = PaymentMethodAuthorityGate.lock_binding_for_transaction(fixture.customer.id, :stripe)

    current_subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    {:ok, method, method_notifications} =
      StoredPaymentMethod
      |> Ash.Changeset.for_create(:create_or_reuse, %{
        user_id: fixture.customer.id,
        provider: :stripe,
        provider_customer_ref: fixture.refs.provider_customer,
        provider_payment_method_ref: fixture.refs.new_method,
        status: :active,
        fingerprint: "fp_jc290_#{fixture.refs.new_method}"
      }, context: %{system?: true})
      |> Ash.create(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true},
        return_notifications?: true
      )

    {:ok, updated_subscription, subscription_notifications} =
      current_subscription
      |> Ash.Changeset.for_update(:set_provider_billing_reference, %{
        provider_customer_ref: fixture.refs.provider_customer,
        provider_billing_ref: fixture.refs.new_method,
        stored_payment_method_id: method.id
      }, context: %{system?: true})
      |> Ash.update(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true},
        return_notifications?: true
      )

    {{method, updated_subscription}, method_notifications ++ subscription_notifications}
  end)

  :ok = AshNotifications.notify_post_commit(notifications,
    context: %{flow: :jc290_test_method_replacement, subscription_id: fixture.subscription.id}
  )

  {method, updated_subscription} = result
  assert method.status == :active
  assert updated_subscription.provider_billing_ref == fixture.refs.new_method
  old_method =
    StoredPaymentMethod
    |> Ash.Query.filter(expr(
      user_id == ^fixture.customer.id and provider == :stripe and
        provider_customer_ref == ^fixture.refs.provider_customer and
        provider_payment_method_ref == ^fixture.refs.old_method
    ))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

  assert old_method.status == :active
  :ok
end

defp mutate_method!(fixture, :revoke) do
  {:ok, {result, notifications}} = Repo.transaction(fn ->
    :ok = PaymentMethodAuthorityGate.lock_binding_for_transaction(fixture.customer.id, :stripe)

    current_subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^fixture.subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    method =
      StoredPaymentMethod
      |> Ash.Query.filter(expr(
        user_id == ^fixture.customer.id and provider == :stripe and
          provider_customer_ref == ^fixture.refs.provider_customer and
          provider_payment_method_ref == ^fixture.refs.old_method
      ))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    {:ok, revoked_method, method_notifications} =
      method
      |> Ash.Changeset.for_update(:mark_revoked, %{}, context: %{system?: true})
      |> Ash.update(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true},
        return_notifications?: true
      )

    {{revoked_method, current_subscription}, method_notifications}
  end)

  :ok = AshNotifications.notify_post_commit(notifications,
    context: %{flow: :jc290_test_method_revocation, subscription_id: fixture.subscription.id}
  )

  {method, _current_subscription} = result
  assert method.status == :revoked
  :ok
end

end
```

## Validation and commit

- [ ] Run the regression module before production and retain its RED output in ignored tmp/jc290/task3-red.log. Expected product failures are a replacement committed before POST and blocked observation after revocation. Crash recovery is characterization because all installed adapters prohibit same-request POST replay.
- [ ] Implement the facade changes above. Add the existing PaymentMethodAuthorityGate alias alongside the other Subscriptions aliases.
- [ ] Run the new module twice and the existing subscription regression suite. Do not run database commands concurrently.

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs --include real_connections
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions
mise exec -- mix format --check-formatted lib/store/subscriptions/facade.ex test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs
git diff --check
```

Expected: zero failures. Real-connection cases remain excluded from the normal subscription command and are explicitly run above. Full strict checks, expanded race matrix and CI integration belong to the final evidence task.

- [ ] Inspect the complete diff and commit only the facade and new regression module. Report exact head, RED and GREEN evidence, and limitations. Separate spec review must pass before separate quality review.

## Root self-review

The production snippets cover both charge POST paths, keep the short claim transaction committed before provider I/O, and release session gates before applying financial evidence. They preserve the same collection and request on method changes. The due preflight fallback permits only observation of the same reached occurrence. Types and fields match current resource code, and the session callback returns its value without another tuple wrapper. Tests use actual facade and fixture APIs, distinct PostgreSQL backends, an entered POST, and a committed writer. The crash case retains a checkout on both RED and GREEN so process death owns a database session. The complete ticket also needs the final proof task's reverse arrival order, revocation, terminal non-success, mutation contention, stale CAS, unrelated work and resource measurements. No provider-contract change or remote receipt claim is authorized.

## Execution correction

At 9d7be0859fcad8d2c6280eb236d65e38a35aa8dd, the facade and four focused tests passed separate spec and quality reviews. All installed adapters disable or omit supports_same_request_replay?, so generic replay POST logic cannot be dynamically exercised through the public facade. An attempted successful replay expectation was incorrect and was replaced with observation-only characterization. The response tuple handling in that dormant path was corrected by inspection. The due fallback uses the direct same-attempt observation helper in this plan and preserves lookup errors. Meaningful original RED coverage contains two failures, followed by four passing focused tests twice and 132 passing related tests.
