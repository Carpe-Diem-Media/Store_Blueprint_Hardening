defmodule Store.Subscriptions.AccessEffectTargetOrderContentionTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 60_000

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures

  import Ash.Expr
  require Ash.Query

  @transaction_timeout 30_000
  @task_timeout 15_000
  @blocking_timeout 8_000
  @cursor_floor "00000000-0000-7000-8000-000000000000"

  setup_all do
    assert_test_database!()

    pool_size = Repo.config()[:pool_size]

    unless is_integer(pool_size) and pool_size >= 3 do
      raise "target-order contention proof requires Repo pool_size >= 3, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)

    {:ok, effective_repo_pool_size: pool_size}
  end

  setup do
    direct_repo_owner = Sandbox.start_owner!(Store.DirectRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(direct_repo_owner) end)
    {:ok, direct_repo_owner: direct_repo_owner}
  end

  test "cancellation producer and F0.5 serialize in both lock-arrival orders", context do
    producer_first = create_committed_source!("producer_first")

    try do
      run_race!(producer_first, :producer_first, context.direct_repo_owner)
      assert_final_effective_target!(producer_first)
    after
      cleanup_owned_source!(producer_first)
    end

    reconciler_first = create_committed_source!("reconciler_first")

    try do
      run_race!(reconciler_first, :reconciler_first, context.direct_repo_owner)
      assert_pre_cancellation_effect_derived_from_source!(reconciler_first)
      assert_final_effective_target!(reconciler_first)

      IO.puts(
        "F0_5_CONTENTION pool_size=#{context.effective_repo_pool_size} both_orders=serialized"
      )
    after
      cleanup_owned_source!(reconciler_first)
    end
  end

  defp run_race!(fixture, order, direct_repo_owner) do
    parent = self()
    run_ref = make_ref()

    holder = Task.async(fn -> run_holder_task(order, fixture, parent, run_ref) end)

    assert_receive {^run_ref, :holder_ready}, @task_timeout
    :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, holder.pid)
    send(holder.pid, {run_ref, :start_holder})

    assert_receive {^run_ref, :holder_locked, holder_backend_pid, _holder_result}, @task_timeout

    contender =
      Task.async(fn ->
        send(parent, {run_ref, :contender_ready})

        receive do
          {^run_ref, :start_contender} -> :ok
        end

        Repo.transaction(
          fn -> run_contender_transaction(order, fixture, parent, run_ref) end,
          timeout: @transaction_timeout
        )
      end)

    assert_receive {^run_ref, :contender_ready}, @task_timeout
    :ok = Sandbox.allow(Store.DirectRepo, direct_repo_owner, contender.pid)
    send(contender.pid, {run_ref, :start_contender})

    assert_receive {^run_ref, :contender_started, contender_backend_pid}, @task_timeout
    assert contender_backend_pid != holder_backend_pid
    blockers = await_blocking_pid!(contender_backend_pid, holder_backend_pid)

    send(holder.pid, {run_ref, :release_holder})
    assert {:ok, _holder_result} = Task.await(holder, @task_timeout)

    contender_result = Task.await(contender, @task_timeout)

    contender_summary =
      case {order, contender_result} do
        {:producer_first, {:ok, %{noop_count: noop_count, repaired_count: repaired_count}}} ->
          assert noop_count >= 1
          "noop=#{noop_count},repaired=#{repaired_count}"

        {:reconciler_first, {:ok, %Store.Subscriptions.Subscription{status: :canceled}}} ->
          "canceled=true"

        other ->
          flunk("unexpected #{order} contention result #{inspect(other)}")
      end

    IO.puts(
      "F0_5_CONTENTION order=#{order} holder_pid=#{holder_backend_pid} " <>
        "contender_pid=#{contender_backend_pid} blockers=#{inspect(blockers)} " <>
        "result=#{contender_summary}"
    )
  end

  defp run_contender_transaction(order, fixture, parent, run_ref) do
    contender_backend_pid = backend_pid!()
    send(parent, {run_ref, :contender_started, contender_backend_pid})

    case order do
      :producer_first -> reconcile!(fixture)
      :reconciler_first -> cancel_now!(fixture)
    end
  end

  defp run_holder_task(order, fixture, parent, run_ref) do
    send(parent, {run_ref, :holder_ready})

    receive do
      {^run_ref, :start_holder} ->
        Repo.transaction(
          fn -> run_holder_transaction(order, fixture, parent, run_ref) end,
          timeout: @transaction_timeout
        )
    end
  end

  defp run_holder_transaction(order, fixture, parent, run_ref) do
    result =
      case order do
        :producer_first -> cancel_now!(fixture)
        :reconciler_first -> reconcile!(fixture)
      end

    holder_backend_pid = backend_pid!()
    send(parent, {run_ref, :holder_locked, holder_backend_pid, result})

    receive do
      {^run_ref, :release_holder} -> result
    after
      @transaction_timeout -> Repo.rollback(:holder_release_timeout)
    end
  end

  defp cancel_now!(fixture) do
    case Facade.cancel_subscription_for_user(fixture.customer, fixture.subscription.id, :now) do
      {:ok, canceled} -> canceled
      other -> Repo.rollback({:cancel_failed, other})
    end
  end

  defp reconcile!(fixture) do
    case Facade.run_access_effect_target_order_reconciliation_for_system(
           limit: 1,
           as_of: fixture.through_inserted_at,
           after_inserted_at: fixture.after_inserted_at,
           after_id: @cursor_floor
         ) do
      {:ok, result} -> result
      other -> Repo.rollback({:reconciliation_failed, other})
    end
  end

  defp create_committed_source!(label) do
    Repo.transaction(
      fn ->
        unique = Ecto.UUID.generate()
        customer = SubscriptionsFixtures.create_customer!("f05_contention_#{label}_#{unique}")

        %{product: product, variant: variant} =
          SubscriptionsFixtures.create_subscription_sellable!()

        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            entitlement_kind: :membership_access,
            entitlement_scope_key: "f05-contention-#{label}-#{unique}",
            access_on_cancel: :keep_until_period_end
          })

        variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

        fixture =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            create_payment_intent?: false
          })

        assert fixture.revision.access_on_cancel == :keep_until_period_end
        assert fixture.subscription.current_plan_revision_id == fixture.revision.id

        stale_input =
          input!(%{
            subscription_id: fixture.subscription.id,
            source_version: fixture.subscription.aggregate_version,
            disposition: :non_effective,
            entitlement_kind: nil,
            entitlement_scope_key: nil,
            valid_from_at: nil,
            valid_until_at: nil,
            source_order_line_item_id: fixture.line_item.id,
            contract_change_id: fixture.subscription.current_contract_change_id,
            plan_revision_id: fixture.revision.id
          })

        {:ok, candidate} = Facade.establish_access_effect_for_system(stale_input)

        Repo.query!(
          "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
          [
            Ecto.UUID.dump!(fixture.subscription.id)
          ]
        )

        inserted_at = candidate.inserted_at

        Map.merge(fixture, %{
          customer: customer,
          product: product,
          plan: plan,
          variant_plan: variant_plan,
          candidate: candidate,
          pre_cancellation_source_version: fixture.subscription.aggregate_version + 1,
          through_inserted_at: inserted_at,
          after_inserted_at: inserted_at
        })
      end,
      timeout: @transaction_timeout
    )
    |> case do
      {:ok, fixture} ->
        fixture

      {:error, reason} ->
        raise "unable to create target-order contention source: #{inspect(reason)}"
    end
  end

  defp input!(attrs) do
    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise "invalid target-order contention effect: #{inspect(reason)}"
    end
  end

  defp assert_final_effective_target!(fixture) do
    subscription = fetch_subscription!(fixture.subscription.id)
    assert {:ok, effect} = Facade.get_current_access_effect_for_system(subscription)

    assert subscription.status == :canceled
    assert subscription.canceled_reason == "user_request"
    assert %DateTime{} = subscription.canceled_at
    assert effect.status in [:required, :pending, :failed_retryable, :applied]
    assert effect.disposition == :effective
    assert effect.source_version == subscription.aggregate_version
    assert effect.entitlement_kind == fixture.revision.entitlement_kind
    assert effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert effect.valid_from_at == subscription.current_period_start_at
    assert effect.valid_until_at == subscription.current_period_end_at
    assert effect.source_order_line_item_id == subscription.source_order_line_item_id
    assert effect.contract_change_id == subscription.current_contract_change_id
    assert effect.plan_revision_id == subscription.current_plan_revision_id
    assert effect.plan_revision_id == fixture.revision.id
    assert current_effect_count!(subscription.id, subscription.aggregate_version) == 1

    assert {:ok, outcome} = Facade.execute_effective_access_effect_for_system(effect.id)
    assert outcome in [:applied, :applied_projection_pending, :noop]

    assert {:ok, current_effect} = Facade.get_current_access_effect_for_system(subscription)
    assert current_effect.id == effect.id
    assert current_effect.disposition == :effective
    assert current_effect.source_version == subscription.aggregate_version

    assert [grant] = active_grants_for!(subscription.id)
    assert grant.source_kind == :subscription
    assert grant.source_id == subscription.id
    assert grant.kind == current_effect.entitlement_kind
    assert grant.scope_key == current_effect.entitlement_scope_key
    assert grant.valid_from_at == current_effect.valid_from_at
    assert grant.valid_to_at == current_effect.valid_until_at
  end

  defp assert_pre_cancellation_effect_derived_from_source!(fixture) do
    effect =
      fetch_effect_for_source_version!(
        fixture.subscription.id,
        fixture.pre_cancellation_source_version
      )

    assert effect.disposition == :effective
    assert effect.source_version == fixture.pre_cancellation_source_version
    assert effect.entitlement_kind == fixture.revision.entitlement_kind
    assert effect.entitlement_scope_key == fixture.revision.entitlement_scope_key
    assert effect.valid_from_at == fixture.subscription.current_period_start_at
    assert effect.valid_until_at == fixture.subscription.current_period_end_at
    assert effect.source_order_line_item_id == fixture.subscription.source_order_line_item_id
    assert effect.contract_change_id == fixture.subscription.current_contract_change_id
    assert effect.plan_revision_id == fixture.revision.id
    assert current_effect_count!(fixture.subscription.id, effect.source_version) == 1

    assert fixture.candidate.disposition == :non_effective
    assert fetch_access_effect!(fixture.candidate.id).status == :superseded
  end

  defp current_effect_count!(subscription_id, source_version) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM access_effects WHERE subscription_id = $1 AND source_version = $2
        """,
        [Ecto.UUID.dump!(subscription_id), source_version]
      )

    count
  end

  defp fetch_access_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_effect_for_source_version!(subscription_id, source_version) do
    AccessEffect
    |> Ash.Query.filter(
      expr(subscription_id == ^subscription_id and source_version == ^source_version)
    )
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp active_grants_for!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(
      expr(source_kind == :subscription and source_id == ^subscription_id and status == :active)
    )
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Store.Subscriptions.Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_blocking_pid!(blocked_pid, expected_blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @blocking_timeout
    poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, [])
  end

  defp poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, last_blockers) do
    %{rows: [[blockers]]} =
      Repo.query!("SELECT pg_blocking_pids($1)", [blocked_pid], timeout: 1_000)

    cond do
      expected_blocker_pid in blockers ->
        blockers

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "PostgreSQL did not report backend #{expected_blocker_pid} blocking #{blocked_pid}; " <>
            "last pg_blocking_pids result was #{inspect(last_blockers)}"
        )

      true ->
        :erlang.yield()
        poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, blockers)
    end
  end

  defp cleanup_owned_source!(fixture) do
    Repo.transaction(
      fn ->
        subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
        item_id = Ecto.UUID.dump!(fixture.item.id)
        line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
        order_id = Ecto.UUID.dump!(fixture.order.id)
        variant_plan_id = Ecto.UUID.dump!(fixture.variant_plan.id)
        revision_id = Ecto.UUID.dump!(fixture.revision.id)
        plan_id = Ecto.UUID.dump!(fixture.plan.id)
        product_id = Ecto.UUID.dump!(fixture.product.id)
        customer_id = Ecto.UUID.dump!(fixture.customer.id)

        Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])
        Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])
        Repo.query!("DELETE FROM subscription_items WHERE id = $1", [item_id])
        Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
        Repo.query!("DELETE FROM email_outboxes WHERE order_id = $1", [order_id])
        Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
        Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
        Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
        Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
        Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])
        Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [variant_plan_id])
        Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [revision_id])
        Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
        Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
        Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
        Repo.query!("DELETE FROM users WHERE id = $1", [customer_id])
      end,
      timeout: @transaction_timeout
    )

    :ok
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
  end
end
