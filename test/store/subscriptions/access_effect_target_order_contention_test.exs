defmodule Store.Subscriptions.AccessEffectTargetOrderContentionTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 60_000

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
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

  test "producer and reconciliation serialize in both lock-arrival orders", context do
    producer_first = create_committed_source!("producer_first")

    try do
      assert producer_first.revision.access_on_cancel == :remove_immediately
      assert producer_first.subscription.current_plan_revision_id == producer_first.revision.id
      run_race!(producer_first, :producer_first, context.direct_repo_owner)
      assert_final_non_effective_target!(producer_first)
    after
      cleanup_owned_source!(producer_first)
    end

    reconciler_first = create_committed_source!("reconciler_first")

    try do
      assert reconciler_first.revision.access_on_cancel == :remove_immediately

      assert reconciler_first.subscription.current_plan_revision_id ==
               reconciler_first.revision.id

      run_race!(reconciler_first, :reconciler_first, context.direct_repo_owner)
      assert_final_non_effective_target!(reconciler_first)

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
            access_on_cancel: :remove_immediately
          })

        variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

        fixture =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            create_payment_intent?: false
          })

        assert fixture.revision.access_on_cancel == :remove_immediately
        assert fixture.subscription.current_plan_revision_id == fixture.revision.id

        stale_input =
          input!(%{
            subscription_id: fixture.subscription.id,
            source_version: fixture.subscription.aggregate_version,
            disposition: :effective,
            entitlement_kind: fixture.revision.entitlement_kind,
            entitlement_scope_key: fixture.revision.entitlement_scope_key,
            valid_from_at: ~U[2020-01-01 00:00:00.000000Z],
            valid_until_at: fixture.subscription.current_period_end_at,
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

  defp assert_final_non_effective_target!(fixture) do
    subscription = fetch_subscription!(fixture.subscription.id)
    effect = exact_effect!(subscription.id, subscription.aggregate_version)

    assert subscription.status == :canceled
    assert effect.status in ["required", "pending", "failed_retryable"]
    assert effect.disposition == "non_effective"
    assert effect.source_version == subscription.aggregate_version
    assert effect.source_version > fixture.candidate.source_version
    assert effect.entitlement_kind == nil
    assert effect.entitlement_scope_key == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == nil
    assert effect.source_order_line_item_id == subscription.source_order_line_item_id
    assert effect.contract_change_id == subscription.current_contract_change_id
    assert effect.plan_revision_id == subscription.current_plan_revision_id
    assert exact_effect_count!(subscription.id, subscription.aggregate_version) == 1
    assert unresolved_effect_count!(fixture.subscription.id) == 1
  end

  defp exact_effect!(subscription_id, source_version) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT status::text, disposition::text, source_version,
               entitlement_kind::text, entitlement_scope_key, valid_from_at, valid_until_at,
               source_order_line_item_id::text, contract_change_id::text, plan_revision_id::text
        FROM access_effects
        WHERE subscription_id = $1 AND source_version = $2
        """,
        [Ecto.UUID.dump!(subscription_id), source_version]
      )

    [
      status,
      disposition,
      source_version,
      entitlement_kind,
      entitlement_scope_key,
      valid_from_at,
      valid_until_at,
      source_order_line_item_id,
      contract_change_id,
      plan_revision_id
    ] = row

    %{
      status: status,
      disposition: disposition,
      source_version: source_version,
      entitlement_kind: entitlement_kind,
      entitlement_scope_key: entitlement_scope_key,
      valid_from_at: valid_from_at,
      valid_until_at: valid_until_at,
      source_order_line_item_id: source_order_line_item_id,
      contract_change_id: contract_change_id,
      plan_revision_id: plan_revision_id
    }
  end

  defp exact_effect_count!(subscription_id, source_version) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM access_effects WHERE subscription_id = $1 AND source_version = $2",
        [Ecto.UUID.dump!(subscription_id), source_version]
      )

    count
  end

  defp unresolved_effect_count!(subscription_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM access_effects
        WHERE subscription_id = $1
          AND status IN ('required', 'pending', 'failed_retryable')
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    count
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
        Process.sleep(25)
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
