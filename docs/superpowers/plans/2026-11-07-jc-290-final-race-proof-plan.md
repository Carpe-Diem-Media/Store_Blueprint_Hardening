# JC-290 final race proof implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development with separate spec and quality reviews.

**Goal:** Prove the integrated payment-method protocol across race winners, recovery and direct resource mutations, then include it in required CI.

**Architecture:** Extend the existing committed real-connection test module with actual PostgreSQL wait dependencies and actual entered provider requests. Keep production semantics unchanged unless a failing proof identifies a defect required by JC-290. Root reviews any such production fix before implementation.

**Tech stack:** Existing ExUnit, Repo, Ash actions, StripeAPIStub and CI job. No new dependency, pool or service.

## Task 4: Complete the race matrix

**Files:** Modify test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs, test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs and .github/workflows/ci.yml. The facade integration must first pass separate spec and quality reviews.

- [ ] Add the following cases and helpers inside the existing race module, reusing its create_dispatch_fixture!, cleanup_dispatch_fixture!, mutate_method!, current_subscription!, reached_identity!, start_dispatch, attach_dispatch_barrier!, backend_pid!, assert_writer_blocked! and assert_eventually functions. Those functions are defined in the prior committed task. Direct resource contention must call public Ash actions without manually acquiring a binding gate.

```elixir
  for mutation <- [:replace, :revoke], status <- ["succeeded", "canceled"] do
    @tag :jc290_matrix
    test "dispatch first with #{mutation} preserves exact #{status} evidence" do
      run_dispatch_evidence_case!(unquote(mutation), unquote(status))
    end
  end

  for mutation <- [:replace, :revoke] do
    @tag :jc290_matrix
    test "#{mutation} wins before the dispatch claim" do
      fixture = create_dispatch_fixture!("writer_first")
      ref = make_ref()
      parent = self()
      handler = {__MODULE__, ref}
      posts = :atomics.new(1, [])
      :ok = :telemetry.attach(handler, [:store, :subscriptions, :renewal_charge_dispatch_check], fn _, _, ids, _ ->
        if ids.subscription_id == fixture.subscription.id do
          send(parent, {ref, :before_claim, self(), ids})
          receive do
            {^ref, :resume} -> :ok
          after
            10_000 -> raise "pre-claim barrier expired"
          end
        end
      end, nil)
      StripeAPIStub.stub_payment_intent(fn conn, params ->
        :atomics.add(posts, 1, 1)
        send(parent, {ref, :post_params, params})
        StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
      end)
      task = start_dispatch(fixture)
      try do
        assert_receive {^ref, :before_claim, beam, ids}, 10_000
        mutate_method!(fixture, unquote(mutation))
        send(beam, {ref, :resume})
        result = Task.await(task, 10_000)
        if unquote(mutation) == :replace do
          assert {:ok, :processed} = result
          assert_receive {^ref, :post_params, params}, 3_000
          assert params["payment_method"] == fixture.refs.new_method
          exact = reached_identity!(fixture)
          assert exact.attempt_id == ids.renewal_attempt_id
          assert exact.payment_intent_id == ids.payment_intent_id
          assert exact.attempt_count == 1
          assert :atomics.get(posts, 1) == 1
        else
          assert {:error, %{code: "STALE_RECORD"}} = result
          assert :atomics.get(posts, 1) == 0
          assert [["not_started", "unresolved", nil]] == Repo.query!(
            "SELECT c.dispatch_state,c.financial_outcome,c.payment_intent_id FROM renewal_collection_attempts c JOIN renewal_attempts a ON a.id=c.renewal_attempt_id WHERE a.subscription_id=$1::text::uuid", [fixture.subscription.id]).rows
          assert current_subscription!(fixture).dunning_attempt_count == fixture.subscription.dunning_attempt_count
        end
      after
        :telemetry.detach(handler)
        send(task.pid, {ref, :resume})
        Task.shutdown(task, :brutal_kill)
        cleanup_dispatch_fixture!(fixture)
      end
    end
  end

  @tag :jc290_matrix
  test "every direct StoredPaymentMethod mutation waits on the dispatch binding gate" do
    for action <- [:create, :upsert_active, :upsert_inactive, :upsert_revoked,
                   :mark_active, :mark_inactive, :mark_revoked] do
      fixture = create_dispatch_fixture!("action_#{action}")
      parent = self()
      ref = make_ref()
      identity = %{provider: :stripe, customer_ref: fixture.refs.provider_customer, method_ref: fixture.refs.old_method}
      holder = Task.async(fn ->
        PaymentMethodAuthorityGate.with_dispatch_session_gates(fixture.customer.id, :stripe,
          fn -> {:ok, identity} end, fn _, proof ->
            send(parent, {ref, :held, proof.backend_pid})
            receive do
              {^ref, :release} -> :ok
            after
              10_000 -> raise "action gate barrier expired"
            end
          end)
      end)
      writer_key = {ref, :writer}
      try do
        assert_receive {^ref, :held, holder_pg}, 3_000
        writer = Task.async(fn ->
          Repo.checkout(fn ->
            send(parent, {ref, :writer_pg, backend_pid!()})
            result = direct_method_write(fixture, action)
            send(parent, {ref, :mutation_finished})
            result
          end)
        end)
        Process.put(writer_key, writer)
        assert_receive {^ref, :writer_pg, writer_pg}, 3_000
        refute writer_pg == holder_pg
        assert_eventually(fn ->
          receive do
            {^ref, :mutation_finished} -> flunk("#{action} bypassed its resource gate")
          after
            0 -> :ok
          end
          Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder_pg, writer_pg]).rows == [[true]]
        end)
        send(holder.pid, {ref, :release})
        assert :ok = Task.await(holder, 3_000)
        assert {:ok, _method} = Task.await(writer, 3_000)
      after
        send(holder.pid, {ref, :release})
        Task.shutdown(holder, :brutal_kill)
        if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
        cleanup_dispatch_fixture!(fixture)
      end
    end
  end

  @tag :jc290_matrix
  test "a stale direct binding writer cannot overwrite the replacement" do
    fixture = create_dispatch_fixture!("stale_binding")
    try do
      stale = current_subscription!(fixture)
      mutate_method!(fixture, :replace)
      winner = current_subscription!(fixture)
      assert winner.aggregate_version == stale.aggregate_version + 1
      result = stale
      |> Ash.Changeset.for_update(:set_provider_billing_reference, %{
        provider_customer_ref: stale.provider_customer_ref,
        provider_billing_ref: stale.provider_billing_ref,
        stored_payment_method_id: stale.stored_payment_method_id
      }, context: %{system?: true})
      |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      assert {:error, error} = result
      assert Store.Subscriptions.Facade.StaleWrite.stale_record_error?(error)
      assert current_subscription!(fixture).stored_payment_method_id == winner.stored_payment_method_id
      assert current_subscription!(fixture).aggregate_version == winner.aggregate_version
    after
      cleanup_dispatch_fixture!(fixture)
    end
  end

  @tag :jc290_matrix
  test "an unrelated customer can renew while another dispatch is paused" do
    first = create_dispatch_fixture!("unrelated_first")
    other = create_dispatch_fixture!("unrelated_other")
    ref = make_ref()
    handler = attach_dispatch_barrier!(first, ref, [:claimed])
    task = start_dispatch(first)
    try do
      assert_receive {^ref, :claimed, beam, _pg, _ids, false}, 10_000
      assert {:ok, :processed} = Facade.process_due_subscription_renewal_for_system(other.subscription.id, now: other.now)
      assert reached_identity!(other).financial_outcome == "verified_success"
      send(beam, {ref, :release, :claimed})
      assert {:ok, :processed} = Task.await(task, 10_000)
    after
      :telemetry.detach(handler)
      send(task.pid, {ref, :release, :claimed})
      Task.shutdown(task, :brutal_kill)
      cleanup_dispatch_fixture!(first)
      cleanup_dispatch_fixture!(other)
    end
  end

  for mutation <- [:replace, :revoke], route <- [:due, :not_due] do
    @tag :jc290_matrix
    test "crashed dispatch with #{mutation} observes only on the #{route} route" do
      fixture = create_dispatch_fixture!("crash_matrix")
      ref = make_ref()
      handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
      posts = :atomics.new(1, [])
      StripeAPIStub.stub_payment_intent(fn conn, params ->
        :atomics.add(posts, 1, 1)
        StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params, %{"status" => "processing"}))
      end)
      task = start_dispatch(fixture)
      try do
        assert_receive {^ref, :claimed, _beam, pg, _ids, false}, 10_000
        exact = reached_identity!(fixture)
        Process.unlink(task.pid)
        Process.exit(task.pid, :kill)
        assert_receive {:DOWN, monitor, :process, pid, :killed}, 3_000
        assert monitor == task.ref and pid == task.pid
        assert_eventually(fn -> Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [pg]).rows == [[0]] end)
        :telemetry.detach(handler)
        mutate_method!(fixture, unquote(mutation))
        # Select the not-due recovery branch with the facade's explicit clock input.
        now = if unquote(route) == :due, do: fixture.now,
          else: DateTime.add(fixture.subscription.next_renewal_at, -1, :microsecond)
        assert {:error, %{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
          Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: now)
        assert :atomics.get(posts, 1) == 0
        after_recovery = reached_identity!(fixture)
        assert Map.take(after_recovery, [:attempt_id, :collection_id, :payment_intent_id, :request_ref, :intent_method]) ==
          Map.take(exact, [:attempt_id, :collection_id, :payment_intent_id, :request_ref, :intent_method])
        assert after_recovery.attempt_count == 1
        assert after_recovery.financial_outcome == "unresolved"
      after
        :telemetry.detach(handler)
        send(task.pid, {ref, :release, :claimed})
        Task.shutdown(task, :brutal_kill)
        cleanup_dispatch_fixture!(fixture)
      end
    end
  end

  defp direct_method_write(fixture, action) do
    opts = [domain: Store.Subscriptions, authorize?: false, context: %{system?: true}]
    if action in [:create, :upsert_active, :upsert_inactive, :upsert_revoked] do
      status = case action do
        :upsert_inactive -> :inactive
        :upsert_revoked -> :revoked
        _ -> :active
      end
      ref = if action == :create, do: fixture.refs.new_method, else: fixture.refs.old_method
      StoredPaymentMethod
      |> Ash.Changeset.for_create(:create_or_reuse, %{
        user_id: fixture.customer.id, provider: :stripe,
        provider_customer_ref: fixture.refs.provider_customer,
        provider_payment_method_ref: ref, status: status
      }, context: %{system?: true})
      |> Ash.create(opts)
    else
      method = StoredPaymentMethod
      |> Ash.Query.filter(expr(id == ^fixture.subscription.stored_payment_method_id))
      |> Ash.read_one!(opts)
      method
      |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
      |> Ash.update(opts)
    end
  end

  defp run_dispatch_evidence_case!(mutation, status) do
    fixture = create_dispatch_fixture!("evidence_matrix")
    parent = self()
    ref = make_ref()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed, :released])
    posts = :atomics.new(1, [])
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      send(parent, {ref, :post_entered, params})
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params, %{"status" => status}))
    end)
    task = start_dispatch(fixture)
    writer_key = {ref, :writer}
    try do
      assert_receive {^ref, :claimed, beam, pg, ids, false}, 10_000
      writer = Task.async(fn ->
        Repo.checkout(fn ->
          send(parent, {ref, :writer_backend, backend_pid!()})
          mutate_method!(fixture, mutation)
          send(parent, {ref, :writer_committed})
          :ok
        end)
      end)
      Process.put(writer_key, writer)
      assert_receive {^ref, :writer_backend, writer_pg}, 3_000
      assert_writer_blocked!(ref, writer_pg, pg)
      send(beam, {ref, :release, :claimed})
      assert_receive {^ref, :post_entered, params}, 10_000
      assert params["payment_method"] == fixture.refs.old_method
      assert_receive {^ref, :released, released_beam, _pg, released_ids, false}, 10_000
      assert released_ids.payment_intent_id == ids.payment_intent_id
      assert_receive {^ref, :writer_committed}, 3_000
      assert :ok = Task.await(writer, 3_000)
      send(released_beam, {ref, :release, :released})
      assert {:ok, :processed} = Task.await(task, 10_000)
      exact = reached_identity!(fixture)
      expected = if status == "succeeded", do: "verified_success", else: "verified_terminal_financial_non_success"
      assert exact.financial_outcome == expected
      assert exact.payment_intent_id == ids.payment_intent_id
      assert exact.collection_id == ids.collection_attempt_id
      assert exact.attempt_count == 1
      assert exact.intent_method == fixture.refs.old_method
      assert :atomics.get(posts, 1) == 1
      current = current_subscription!(fixture)
      if mutation == :replace do
        assert current.provider_billing_ref == fixture.refs.new_method
        assert exact.method_status == "active"
      else
        assert current.provider_billing_ref == fixture.refs.old_method
        assert exact.method_status == "revoked"
      end
      # Exact recovery after a terminal result cannot initiate another charge.
      _ = Facade.process_due_subscription_renewal_for_system(fixture.subscription.id, now: fixture.now)
      assert :atomics.get(posts, 1) == 1
    after
      :telemetry.detach(handler)
      send(task.pid, {ref, :release, :claimed})
      send(task.pid, {ref, :release, :released})
      Task.shutdown(task, :brutal_kill)
      if writer = Process.delete(writer_key), do: Task.shutdown(writer, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

  @tag :jc290_matrix
  test "losing the owned session after claim prevents provider invocation" do
    fixture = create_dispatch_fixture!("connection_lost")
    ref = make_ref()
    handler = attach_dispatch_barrier!(fixture, ref, [:claimed])
    posts = :atomics.new(1, [])
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(posts, 1, 1)
      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params))
    end)
    task = start_dispatch(fixture)
    try do
      assert_receive {^ref, :claimed, beam, pg, ids, false}, 10_000
      Process.unlink(task.pid)
      assert [[true]] == Repo.query!("SELECT pg_terminate_backend($1::integer)", [pg]).rows
      send(beam, {ref, :release, :claimed})
      result = Task.yield(task, 5_000)
      refute is_nil(result), "dispatch did not stop after losing its database session"
      assert :atomics.get(posts, 1) == 0
      exact = reached_identity!(fixture)
      assert exact.payment_intent_id == ids.payment_intent_id
      assert exact.dispatch_state == "may_have_been_reached"
      assert exact.financial_outcome == "unresolved"
      assert_eventually(fn -> Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE pid=$1", [pg]).rows == [[0]] end)
    after
      :telemetry.detach(handler)
      send(task.pid, {ref, :release, :claimed})
      Task.shutdown(task, :brutal_kill)
      cleanup_dispatch_fixture!(fixture)
    end
  end

```

- [x] Root renamed the cleanup case that terminates the backend before method acquisition. Its old name overstates lost-acknowledgement coverage. The complete changed declaration is:

```elixir
test "discards the owner when method acquisition follows connection loss", %{identity: identity} do
```

- [ ] Add both new modules to both existing required real-connection repetitions in .github/workflows/ci.yml. Preserve all other job configuration. Each resulting run line is:

```yaml
run: mix test --only real_connections test/store/subscriptions/source_fence_contention_test.exs test/store/subscriptions/access_effect_target_order_contention_test.exs test/store/subscriptions/jc290_payment_method_dispatch_cleanup_test.exs test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs
```

- [ ] Run the matrix first. If a test exposes a production defect, retain the failure and report its actual source to root before changing production. Do not weaken assertions to pass. A due crash case already passed before integration because the due path can stop before dispatch. Treat it as characterization. The not-due case must independently exercise reached-collection recovery. All installed adapters currently prohibit same-request POST replay, so its expected result is observation-only unresolved with zero POSTs. Do not change provider capabilities or add a test seam to force the dormant generic replay branch. Inspect its gate and response handling, and report dynamic coverage as unavailable under current adapter contracts.

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/jc290_payment_method_dispatch_race_test.exs --include real_connections
```

- [ ] Run both new modules and the two existing required modules together twice with --only real_connections, exactly matching CI. Use the same DevCore environment prefix. Run format and git diff --check. Report counts and raw log paths. Full mix check, strict suite and migration alignment are root's final checks after reviews.
- [ ] Inspect the full changed diff, commit only the three owned files, and report exact head and limitations. No pushes or merge.

## Root self-review

The tests cover each ticket requirement through explicit request and commit barriers. They prove direct public action gates without the fixture helper's manual gate. Existing optimistic_aggregate_version_test covers two simultaneous binding writers, and the added exact stale writer test proves replacement cannot be undone. The post-claim connection-loss case is a local fail-closed proof only. Provider stub entry is local request evidence, not real remote receipt or finality. The not-due branch uses the facade's injected clock two microseconds before the fixture's due timestamp to select recovery without mutating the captured occurrence. All owned tasks and telemetry handlers terminate before fixture cleanup. The cleanup trigger change is confined to a test transaction and follows the repository's existing committed-fixture pattern. Runtime measurements and exact-head full validation remain root's final evidence step.

## Provider capability correction

Source inspection after the integration RED run confirmed that every installed adapter disables or omits supports_same_request_replay?. The generic policy has a replay branch for a future certified adapter, but current recovery chooses observation. The crash tests are recovery characterization, not proof that the integration fixed an observed replay POST. Root had inferred capability support incorrectly and corrected the task before final implementation. Keep current contracts and record the dormant replay branch as dynamically unexercised.
