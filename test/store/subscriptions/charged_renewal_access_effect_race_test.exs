defmodule Store.Subscriptions.ChargedRenewalAccessEffectRaceTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 120_000

  # Verified RenewalCollectionAttempt rows are durable and the database rejects their deletion.
  # Run this real-connection file against a disposable DevCore test database suffix.

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade, RenewalAttempt, RenewalCollectionAttempt}
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  @transaction_timeout 30_000
  @task_timeout 15_000
  @blocking_timeout 8_000

  setup_all do
    expected_database = assert_test_database!()

    pool_size = Repo.config()[:pool_size]

    unless is_integer(pool_size) and pool_size >= 3 do
      raise "charged renewal race proof requires Store.Repo pool_size >= 3, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Store.Repo, :auto)
    :ok = Sandbox.mode(Store.DirectRepo, :auto)

    on_exit(fn ->
      :ok = Sandbox.mode(Store.Repo, :manual)
      :ok = Sandbox.mode(Store.DirectRepo, :manual)
    end)

    assert_connected_test_database!(Store.Repo, expected_database)
    assert_connected_test_database!(Store.DirectRepo, expected_database)

    {:ok, %{effective_repo_pool_size: pool_size}}
  end

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a newer :now cancellation supersedes the exact committed renewal effect" do
    fixture = renewal_fixture!("jc300_renewal_cancel_newer")
    run_ref = make_ref()
    telemetry_handler_id = attach_paid_renewal_barrier!(run_ref)
    parent = self()

    renewal_task =
      Task.async(fn ->
        Repo.checkout(fn ->
          backend_pid = backend_pid!()
          send(parent, {run_ref, :renewal_backend, backend_pid})

          Facade.reconcile_paid_subscription_renewal_for_system(
            fixture.attempt.order_id,
            handoff_opts(fixture.handoff)
          )
        end)
      end)

    try do
      assert_receive {^run_ref, :renewal_backend, renewal_backend}, @task_timeout

      assert_receive {^run_ref, :paid_renewal_access_sync_paused, renewal_process},
                     @task_timeout

      assert renewal_process == renewal_task.pid

      cancel_task =
        Task.async(fn ->
          Repo.checkout(fn ->
            backend_pid = backend_pid!()
            send(parent, {run_ref, :cancel_backend, backend_pid})

            Facade.cancel_subscription_for_user(
              fixture.customer,
              fixture.subscription.id,
              :now
            )
          end)
        end)

      assert_receive {^run_ref, :cancel_backend, cancel_backend}, @task_timeout
      assert renewal_backend != cancel_backend

      assert {:ok, %Subscription{status: :canceled} = canceled} =
               Task.await(cancel_task, @transaction_timeout)

      assert canceled.id == fixture.subscription.id
      assert canceled.canceled_reason == "user_request"
      assert fetch_attempt!(fixture.attempt.id).status == :processing

      [renewal_effect, cancellation_effect] = access_effects_for!(fixture.subscription.id)
      assert renewal_effect.disposition == :effective
      assert renewal_effect.status in [:required, :superseded]
      assert cancellation_effect.disposition == :effective
      assert cancellation_effect.status == :applied
      assert cancellation_effect.source_version > renewal_effect.source_version

      {_current_effect, cancellation_grant} =
        assert_current_funded_cancellation!(fixture, canceled, cancellation_effect)

      send(renewal_task.pid, {run_ref, :resume_paid_renewal_access_sync})
      assert {:ok, :reconciled} = Task.await(renewal_task, @transaction_timeout)

      subscription = fetch_subscription!(fixture.subscription.id)
      assert subscription.status == :canceled
      assert subscription.canceled_reason == "user_request"
      assert subscription.current_period_start_at == fixture.attempt.period_start_at
      assert subscription.current_period_end_at == fixture.attempt.period_end_at
      assert subscription.current_plan_revision_id == fixture.attempt.plan_revision_id
      assert fetch_order!(fixture.attempt.order_id).state == :paid
      assert fetch_attempt!(fixture.attempt.id).status == :succeeded

      [renewal_effect, cancellation_effect] = access_effects_for!(fixture.subscription.id)
      assert renewal_effect.status == :superseded
      assert cancellation_effect.disposition == :effective
      assert cancellation_effect.status == :applied

      {current_effect, final_grant} =
        assert_current_funded_cancellation!(fixture, subscription, cancellation_effect)

      assert current_effect.id == cancellation_effect.id
      assert funded_grant_identity(final_grant) == funded_grant_identity(cancellation_grant)
      assert count_payment_applications(fixture.attempt.order_id) == 1

      IO.puts(
        "JC300_RACE_NEWER_B_BEFORE_A renewal_backend=#{renewal_backend} " <>
          "cancel_backend=#{cancel_backend} A=#{renewal_effect.status} B=#{cancellation_effect.disposition}"
      )

      IO.puts(
        "JC247_POLICY_PATH_USED=YES FUNDED_ACCESS_ON_CANCEL=keep_until_period_end " <>
          "CANCELLATION_DISPOSITION=#{cancellation_effect.disposition}"
      )
    after
      if Process.alive?(renewal_task.pid) do
        send(renewal_task.pid, {run_ref, :resume_paid_renewal_access_sync})
        Task.shutdown(renewal_task, :brutal_kill)
      end

      :telemetry.detach(telemetry_handler_id)
    end
  end

  test "an F1 renewal holding the Subscription mutex commits before :now cancellation" do
    fixture = renewal_fixture!("jc300_renewal_cancel_after_f1", issue_initial_grant?: true)
    run_ref = make_ref()
    parent = self()

    {grant_barrier, barrier_backend, initial_grant_id} =
      start_exact_source_grant_barrier!(fixture.subscription.id, run_ref)

    renewal_task =
      Task.async(fn ->
        Repo.checkout(fn ->
          backend_pid = backend_pid!()
          send(parent, {run_ref, :renewal_backend, backend_pid})

          Facade.reconcile_paid_subscription_renewal_for_system(
            fixture.attempt.order_id,
            handoff_opts(fixture.handoff)
          )
        end)
      end)

    try do
      assert_receive {^run_ref, :renewal_backend, renewal_backend}, @task_timeout

      renewal_blockers =
        assert_barrier_observes_blocker!(
          grant_barrier,
          run_ref,
          renewal_backend,
          barrier_backend,
          :renewal_waiting_at_exact_source_convergence
        )

      assert barrier_backend in renewal_blockers

      assert Enum.any?(grants_for!(fixture.subscription.id), fn grant ->
               Ecto.UUID.dump!(grant.id) == initial_grant_id
             end)

      [renewal_effect] = access_effects_for!(fixture.subscription.id)
      assert renewal_effect.disposition == :effective
      assert renewal_effect.status == :required

      cancel_task =
        Task.async(fn ->
          Repo.checkout(fn ->
            backend_pid = backend_pid!()
            send(parent, {run_ref, :cancel_backend, backend_pid})

            Facade.cancel_subscription_for_user(
              fixture.customer,
              fixture.subscription.id,
              :now
            )
          end)
        end)

      assert_receive {^run_ref, :cancel_backend, cancel_backend}, @task_timeout
      assert length(Enum.uniq([renewal_backend, barrier_backend, cancel_backend])) == 3

      cancel_blockers =
        assert_barrier_observes_blocker!(
          grant_barrier,
          run_ref,
          cancel_backend,
          renewal_backend,
          :cancel_waiting_for_f1_subscription_mutex
        )

      assert renewal_backend in cancel_blockers

      send(grant_barrier.pid, {run_ref, :release})
      assert {:ok, :released} = Task.await(grant_barrier, @transaction_timeout)
      assert {:ok, :reconciled} = Task.await(renewal_task, @transaction_timeout)

      assert {:ok, %Subscription{status: :canceled} = canceled} =
               Task.await(cancel_task, @transaction_timeout)

      [renewal_effect, cancellation_effect] = access_effects_for!(fixture.subscription.id)
      assert renewal_effect.status == :applied
      assert cancellation_effect.disposition == :effective
      assert cancellation_effect.status == :applied
      assert cancellation_effect.source_version > renewal_effect.source_version

      subscription = fetch_subscription!(fixture.subscription.id)
      assert subscription.status == :canceled
      assert canceled.canceled_reason == "user_request"
      assert subscription.current_period_start_at == fixture.attempt.period_start_at
      assert subscription.current_period_end_at == fixture.attempt.period_end_at

      {current_effect, grant} =
        assert_current_funded_cancellation!(fixture, subscription, cancellation_effect)

      assert current_effect.id == cancellation_effect.id
      assert grant.status == :active
      assert fetch_attempt!(fixture.attempt.id).status == :succeeded
      assert fetch_order!(fixture.attempt.order_id).state == :paid
      assert count_payment_applications(fixture.attempt.order_id) == 1

      IO.puts(
        "JC300_RACE_A_BEFORE_B barrier_backend=#{barrier_backend} renewal_backend=#{renewal_backend} " <>
          "cancel_backend=#{cancel_backend} renewal_blockers=#{inspect(renewal_blockers)} " <>
          "cancel_blockers=#{inspect(cancel_blockers)} A=#{renewal_effect.status} B=#{cancellation_effect.disposition}"
      )
    after
      send(grant_barrier.pid, {run_ref, :release})

      if Process.alive?(renewal_task.pid), do: Task.shutdown(renewal_task, :brutal_kill)
      if Process.alive?(grant_barrier.pid), do: Task.shutdown(grant_barrier, :brutal_kill)
    end
  end

  defp renewal_fixture!(token, opts \\ []) do
    customer = SubscriptionsFixtures.create_customer!(token)
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{token}",
        access_on_cancel: :keep_until_period_end
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, fixture} =
      Repo.transaction(
        fn ->
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            create_payment_intent?: false,
            started_at: DateTime.add(now, -86_410, :second),
            next_renewal_at: DateTime.add(now, -10, :second),
            provider_billing_ref: "pm_#{token}"
          })
        end,
        timeout: @transaction_timeout
      )

    fixture =
      Map.merge(fixture, %{
        customer: customer,
        product: product,
        variant: variant,
        plan: plan,
        variant_plan: variant_plan,
        now: now
      })

    if Keyword.get(opts, :issue_initial_grant?, false) do
      assert {:ok, _grant} =
               EntitlementsFacade.issue_subscription_entitlement_for_system(
                 fixture.subscription,
                 plan
               )
    end

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(fixture.subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(fixture.subscription.id)
    collection = fetch_collection_for_attempt!(attempt.id)
    mark_collection_successful!(collection)

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    Map.merge(fixture, %{
      attempt: fetch_attempt!(attempt.id),
      collection: fetch_collection!(collection.id),
      handoff: handoff
    })
  end

  defp attach_paid_renewal_barrier!(run_ref) do
    handler_id = "jc300_paid_renewal_access_sync_#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :paid_renewal_access_sync],
        fn _event, _measurements, _metadata, config ->
          send(config.parent, {config.run_ref, :paid_renewal_access_sync_paused, self()})

          receive do
            {^run_ref, :resume_paid_renewal_access_sync} -> :ok
          after
            @task_timeout -> raise "timed out waiting to release the paid renewal boundary"
          end
        end,
        %{parent: parent, run_ref: run_ref}
      )

    handler_id
  end

  defp start_exact_source_grant_barrier!(subscription_id, run_ref) do
    parent = self()

    task =
      Task.async(fn ->
        hold_exact_source_grant_barrier!(subscription_id, run_ref, parent)
      end)

    assert_receive {^run_ref, :exact_source_grant_locked, barrier_backend, grant_id},
                   @task_timeout

    {task, barrier_backend, grant_id}
  end

  defp hold_exact_source_grant_barrier!(subscription_id, run_ref, parent) do
    Repo.checkout(fn ->
      Repo.transaction(
        fn ->
          barrier_backend = backend_pid!()

          %{rows: [[grant_id]]} =
            Repo.query!(
              """
              SELECT id
              FROM entitlement_grants
              WHERE source_kind = 'subscription' AND source_id = $1
              ORDER BY id
              LIMIT 1
              FOR UPDATE
              """,
              [Ecto.UUID.dump!(subscription_id)]
            )

          send(parent, {run_ref, :exact_source_grant_locked, barrier_backend, grant_id})
          await_barrier_messages!(run_ref, parent)
        end,
        timeout: @transaction_timeout
      )
    end)
  end

  defp assert_barrier_observes_blocker!(barrier, run_ref, blocked_pid, expected_blocker, label) do
    send(
      barrier.pid,
      {run_ref, :observe_blocking, blocked_pid, expected_blocker, self(), label}
    )

    receive do
      {^run_ref, :blocking_observed, ^label, blockers} -> blockers
    after
      @task_timeout -> flunk("timed out observing PostgreSQL lock blocking for #{label}")
    end
  end

  defp await_barrier_messages!(run_ref, parent) do
    receive do
      {^run_ref, :observe_blocking, blocked_pid, expected_blocker, observer, label} ->
        blockers = await_blocking_pid!(blocked_pid, expected_blocker)
        send(observer, {run_ref, :blocking_observed, label, blockers})
        await_barrier_messages!(run_ref, parent)

      {^run_ref, :release} ->
        :released
    after
      @transaction_timeout -> Repo.rollback(:exact_source_barrier_timeout)
    end
  end

  defp await_blocking_pid!(blocked_pid, expected_blocker) do
    deadline = System.monotonic_time(:millisecond) + @blocking_timeout
    poll_blocking_pids!(blocked_pid, expected_blocker, deadline, [])
  end

  defp poll_blocking_pids!(blocked_pid, expected_blocker, deadline, previous_blockers) do
    %{rows: [[blockers]]} =
      Repo.query!("SELECT pg_blocking_pids($1)", [blocked_pid], timeout: 1_000)

    cond do
      expected_blocker in blockers ->
        blockers

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "PostgreSQL did not report backend #{expected_blocker} blocking #{blocked_pid}; " <>
            "last pg_blocking_pids result was #{inspect(previous_blockers)}"
        )

      true ->
        receive do
        after
          10 -> poll_blocking_pids!(blocked_pid, expected_blocker, deadline, blockers)
        end
    end
  end

  defp fetch_attempt!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_latest_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_for_attempt!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection!(id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    Store.Orders.Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp access_effects_for!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp grants_for!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp active_grants_for!(subscription_id) do
    Enum.filter(grants_for!(subscription_id), &(&1.status == :active))
  end

  defp assert_current_funded_cancellation!(fixture, subscription, cancellation_effect) do
    assert subscription.status == :canceled
    assert subscription.canceled_reason == "user_request"
    assert subscription.current_plan_revision_id == fixture.revision.id
    assert fixture.attempt.plan_revision_id == fixture.revision.id
    assert subscription.current_period_start_at == fixture.attempt.period_start_at
    assert subscription.current_period_end_at == fixture.attempt.period_end_at

    assert cancellation_effect.disposition == :effective
    assert cancellation_effect.status == :applied
    assert cancellation_effect.source_version == subscription.aggregate_version
    assert cancellation_effect.plan_revision_id == subscription.current_plan_revision_id
    assert cancellation_effect.entitlement_kind == fixture.revision.entitlement_kind

    assert cancellation_effect.entitlement_scope_key ==
             fixture.revision.entitlement_scope_key

    assert cancellation_effect.valid_from_at == subscription.current_period_start_at
    assert cancellation_effect.valid_until_at == subscription.current_period_end_at

    assert {:ok, current_effect} = Facade.get_current_access_effect_for_system(subscription)
    assert current_effect.id == cancellation_effect.id

    assert [%EntitlementGrant{status: :active} = grant] =
             active_grants_for!(subscription.id)

    assert grant.kind == fixture.revision.entitlement_kind
    assert grant.scope_key == fixture.revision.entitlement_scope_key
    assert grant.valid_from_at == subscription.current_period_start_at
    assert grant.valid_to_at == subscription.current_period_end_at

    {current_effect, grant}
  end

  defp funded_grant_identity(grant) do
    {grant.id, grant.status, grant.kind, grant.scope_key, grant.valid_from_at, grant.valid_to_at}
  end

  defp mark_collection_successful!(collection) do
    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    {provider_reference, provider_reference_kind} =
      cond do
        is_binary(payment_intent.provider_payment_id) ->
          {payment_intent.provider_payment_id, :payment_intent}

        is_binary(payment_intent.provider_session_id) ->
          {payment_intent.provider_session_id, :checkout_session}

        true ->
          {payment_intent.provider_request_reference, :transaction_reference}
      end

    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: provider_reference,
      provider_reference_kind: provider_reference_kind,
      provider_transaction_id: payment_intent.provider_payment_id || "pi_#{payment_intent.id}",
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert outcome in [:authoritative_success, :already_applied_success]
    updated_collection = fetch_collection!(collection.id)

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated_collection.payment_attempt_id,
                 payment_intent_id: collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp handoff_opts(handoff) do
    [
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    ]
  end

  defp count_payment_applications(order_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM payment_applications WHERE order_id = $1", [
        Ecto.UUID.dump!(order_id)
      ])

    count
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp assert_test_database! do
    suffix = System.get_env("STORE_TEST_DB_SUFFIX")

    unless is_binary(suffix) and suffix != "" do
      raise "JC-300 race tests create immutable renewal collection history. " <>
              "Run with STORE_TEST_DB_SUFFIX=<unique suffix>. " <>
              "Shared canonical TEST execution is forbidden."
    end

    expected_database =
      System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test") <> suffix

    configured_databases = [Repo.config()[:database], Store.DirectRepo.config()[:database]]

    unless Mix.env() == :test and Enum.all?(configured_databases, &(&1 == expected_database)) do
      raise "real-connection test database guard failed: MIX_ENV=#{inspect(Mix.env())}, " <>
              "configured_databases=#{inspect(configured_databases)}, " <>
              "expected_database=#{inspect(expected_database)}"
    end

    expected_database
  end

  defp assert_connected_test_database!(repo, expected_database) do
    %{rows: [[actual_database]]} = repo.query!("SELECT current_database()")

    unless actual_database == expected_database do
      raise "real-connection test database guard failed: " <>
              "connected_database=#{inspect(actual_database)}, " <>
              "expected_database=#{inspect(expected_database)}"
    end

    :ok
  end
end
