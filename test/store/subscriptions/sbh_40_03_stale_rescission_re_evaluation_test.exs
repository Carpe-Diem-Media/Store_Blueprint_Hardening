defmodule Store.Subscriptions.Sbh4003StaleRescissionReEvaluationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo

  alias Store.Subscriptions.{
    ContractChange,
    Facade,
    RenewalCollectionAttempt,
    Subscription
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "boundary terminalization wins over a stale rescission" do
    suffix = Ecto.UUID.generate()

    fixture =
      Sandbox.unboxed_run(Repo, fn -> create_fixture!(suffix) end)

    on_exit(fn -> cleanup_fixture!(fixture) end)

    scheduled =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, subscription} =
                 Facade.cancel_subscription_for_user(
                   fixture.customer,
                   fixture.subscription.id,
                   :period_end
                 )

        subscription
      end)

    boundary_at = scheduled.cancel_at_period_end_at
    assert scheduled.cancel_at_period_end
    assert is_nil(scheduled.cancel_after_renewal_attempt_id)

    owner = self()
    barrier = make_ref()
    handler_id = {__MODULE__, :stale_rescission, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :contract_change, :before_persist],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id and
               metadata.intent_kind == :materialized do
            send(config.owner, {:rescission_before_persist, config.barrier})

            receive do
              {:release_rescission, ^barrier} -> :ok
            after
              30_000 -> send(config.owner, {:rescission_barrier_timeout, config.barrier})
            end
          end
        end,
        %{owner: owner, barrier: barrier, subscription_id: scheduled.id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rescission_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            scheduled.id,
            :rescind_period_end
          )
        end)
      end)

    assert_receive {:rescission_before_persist, ^barrier}, 10_000

    assert {:ok, %{due_count: 1, canceled_count: 1}} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.run_due_scheduled_cancellations_for_system(
                 now: DateTime.add(boundary_at, 1, :microsecond)
               )
             end)

    terminal = Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(scheduled.id) end)
    assert terminal.status == :canceled
    assert terminal.canceled_at == boundary_at
    assert terminal.ended_at == boundary_at
    refute terminal.cancel_at_period_end
    assert is_nil(terminal.cancel_at_period_end_at)
    assert is_nil(terminal.cancel_after_renewal_attempt_id)

    terminal_change_ids =
      Sandbox.unboxed_run(Repo, fn -> contract_change_ids(scheduled.id) end)

    send(rescission_task.pid, {:release_rescission, barrier})

    assert {:error,
            %{
              code: "VALIDATION_ERROR",
              message: "only a current scheduled cancellation can be rescinded"
            }} = Task.await(rescission_task, 10_000)

    final = Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(scheduled.id) end)
    assert final.status == :canceled
    assert final.canceled_at == boundary_at
    assert final.ended_at == boundary_at
    assert is_nil(final.current_contract_change_id)
    refute final.cancel_at_period_end
    assert is_nil(final.cancel_at_period_end_at)
    assert is_nil(final.cancel_after_renewal_attempt_id)

    assert Sandbox.unboxed_run(Repo, fn -> contract_change_ids(scheduled.id) end) ==
             terminal_change_ids
  end

  test "stale rescission recomputes its target after the exact paid occurrence is reconciled" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    suffix = Ecto.UUID.generate()

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        create_fixture!(suffix, started_at: DateTime.add(now, -40 * 86_400, :second))
      end)

    on_exit(fn -> cleanup_fixture!(fixture) end)
    enable_stripe!()

    reached =
      Sandbox.unboxed_run(Repo, fn ->
        ReachedRenewalFixtures.prepare_reached!(fixture.subscription.id, now)
      end)

    attempt = reached.attempt
    assert DateTime.compare(attempt.period_end_at, now) == :gt

    scheduled =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, subscription} =
                 Facade.cancel_subscription_for_user(
                   fixture.customer,
                   fixture.subscription.id,
                   :period_end
                 )

        subscription
      end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id
    stale_effective_at = scheduled.next_renewal_at

    owner = self()
    barrier = make_ref()
    once = :atomics.new(1, [])
    handler_id = {__MODULE__, :fresh_target, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :contract_change, :before_persist],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id and
               metadata.intent_kind == :materialized and
               :atomics.exchange(config.once, 1, 1) == 0 do
            send(config.owner, {:rescission_before_persist, config.barrier})

            receive do
              {:release_rescission, ^barrier} -> :ok
            after
              30_000 -> send(config.owner, {:rescission_barrier_timeout, config.barrier})
            end
          end
        end,
        %{owner: owner, barrier: barrier, once: once, subscription_id: scheduled.id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rescission_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            scheduled.id,
            :rescind_period_end
          )
        end)
      end)

    assert_receive {:rescission_before_persist, ^barrier}, 10_000

    {payment_intent, collection} =
      Sandbox.unboxed_run(Repo, fn ->
        payment_intent = reached.payment_intent

        StripeAPIStub.stub_payment_observation(
          payment_intent.provider_payment_id,
          ReachedRenewalFixtures.observation_body(reached, "succeeded")
        )

        assert {:ok, observed} =
                 Store.Payments.Facade.observe_payment_intent_for_system(
                   %Store.Payments.Inputs.ObservePaymentIntentInput{
                     payment_intent_id: payment_intent.id
                   }
                 )

        assert {:ok, %{outcome: :authoritative_success}} =
                 Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

        {payment_intent, fetch_collection_for_attempt!(attempt.id)}
      end)

    assert collection.financial_outcome == :verified_success

    assert {:ok, :reconciled} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
                 renewal_attempt_id: attempt.id,
                 collection_attempt_id: collection.id,
                 payment_intent_id: payment_intent.id
               )
             end)

    promoted = Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(scheduled.id) end)
    assert promoted.cancel_at_period_end
    assert promoted.cancel_at_period_end_at == attempt.period_end_at
    assert is_nil(promoted.cancel_after_renewal_attempt_id)
    assert promoted.next_renewal_at != stale_effective_at

    send(rescission_task.pid, {:release_rescission, barrier})
    assert {:ok, rescinded} = Task.await(rescission_task, 10_000)
    refute rescinded.cancel_at_period_end

    fresh_target =
      Sandbox.unboxed_run(Repo, fn ->
        fetch_contract_change!(rescinded.current_contract_change_id)
      end)

    assert fresh_target.instruction_kind == :renew_unchanged
    assert fresh_target.target_plan_revision_id == promoted.current_plan_revision_id
    assert fresh_target.target_variant_id == promoted.variant_id
    assert fresh_target.target_quantity == promoted.quantity
    assert fresh_target.target_amount_minor == promoted.renewal_amount_minor
    assert fresh_target.target_currency == promoted.renewal_currency
    assert fresh_target.effective_at == promoted.next_renewal_at
    refute fresh_target.effective_at == stale_effective_at
  end

  test "a second aggregate conflict stops after one rescission re-evaluation" do
    suffix = Ecto.UUID.generate()
    fixture = Sandbox.unboxed_run(Repo, fn -> create_fixture!(suffix) end)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    scheduled =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, subscription} =
          Facade.cancel_subscription_for_user(
            fixture.customer,
            fixture.subscription.id,
            :period_end
          )

        subscription
      end)

    original_contract_change_ids =
      Sandbox.unboxed_run(Repo, fn -> contract_change_ids(scheduled.id) end)

    owner = self()
    barrier = make_ref()
    attempts = :atomics.new(1, [])
    handler_id = {__MODULE__, :bounded_rescission, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :contract_change, :before_persist],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id and
               metadata.intent_kind == :materialized do
            attempt = :atomics.add_get(config.attempts, 1, 1)

            if attempt <= 2 do
              send(config.owner, {:rescission_before_persist, config.barrier, attempt})

              receive do
                {:release_rescission, ^barrier, ^attempt} -> :ok
              after
                30_000 ->
                  send(config.owner, {:rescission_barrier_timeout, config.barrier, attempt})
              end
            end
          end
        end,
        %{
          owner: owner,
          barrier: barrier,
          attempts: attempts,
          subscription_id: scheduled.id
        }
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    rescission_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            scheduled.id,
            :rescind_period_end
          )
        end)
      end)

    for attempt <- 1..2 do
      assert_receive {:rescission_before_persist, ^barrier, ^attempt}, 10_000

      Sandbox.unboxed_run(Repo, fn -> bump_subscription_aggregate!(scheduled.id, attempt) end)
      send(rescission_task.pid, {:release_rescission, barrier, attempt})
    end

    assert {:error, %{code: "STALE_RECORD"}} = Task.await(rescission_task, 10_000)
    assert :atomics.get(attempts, 1) == 2

    current = Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(scheduled.id) end)
    assert current.status == :active
    assert current.cancel_at_period_end

    assert Sandbox.unboxed_run(Repo, fn -> contract_change_ids(scheduled.id) end) ==
             original_contract_change_ids
  end

  test "ordinary rescission keeps its existing result without a stale retry" do
    suffix = Ecto.UUID.generate()
    fixture = Sandbox.unboxed_run(Repo, fn -> create_fixture!(suffix) end)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    assert {:ok, scheduled} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.cancel_subscription_for_user(
                 fixture.customer,
                 fixture.subscription.id,
                 :period_end
               )
             end)

    {result, stats} =
      Sandbox.unboxed_run(Repo, fn ->
        RepoStats.capture(fn ->
          Facade.cancel_subscription_for_user(
            fixture.customer,
            scheduled.id,
            :rescind_period_end
          )
        end)
      end)

    assert {:ok, rescinded} = result
    refute rescinded.cancel_at_period_end
    assert is_nil(rescinded.cancel_at_period_end_at)
    assert is_nil(rescinded.cancel_after_renewal_attempt_id)
    assert rescinded.current_contract_change_id

    current_change =
      Sandbox.unboxed_run(Repo, fn ->
        fetch_contract_change!(rescinded.current_contract_change_id)
      end)

    assert current_change.instruction_kind == :renew_unchanged
    assert stats.query_count == 14
  end

  defp create_fixture!(suffix, opts \\ []) do
    customer = SubscriptionsFixtures.create_customer!("jc341_#{suffix}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc341_#{suffix}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    overrides =
      case Keyword.fetch(opts, :started_at) do
        {:ok, started_at} -> %{started_at: started_at}
        :error -> %{}
      end
      |> Map.put(:provider_billing_ref, "pm_jc341_#{suffix}")

    %{subscription: subscription, order: order, line_item: line_item, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, overrides)

    %{
      customer: customer,
      line_item_id: line_item.id,
      order_id: order.id,
      plan_id: plan.id,
      product_id: product.id,
      revision_id: revision.id,
      subscription: subscription,
      variant_id: variant.id
    }
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_for_attempt!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp bump_subscription_aggregate!(subscription_id, attempt) do
    subscription = fetch_subscription!(subscription_id)
    unique = Ecto.UUID.generate() |> String.replace("-", "")

    updated =
      subscription
      |> Ash.Changeset.for_update(
        :set_provider_billing_reference,
        %{
          provider_customer_ref: "cus_jc341_#{attempt}_#{unique}",
          provider_billing_ref: "pm_jc341_#{attempt}_#{unique}"
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert updated.aggregate_version == subscription.aggregate_version + 1
    assert updated.cancel_at_period_end
    updated
  end

  defp contract_change_ids(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp cleanup_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      user_id = Ecto.UUID.dump!(fixture.customer.id)
      variant_id = Ecto.UUID.dump!(fixture.variant_id)
      product_id = Ecto.UUID.dump!(fixture.product_id)
      plan_id = Ecto.UUID.dump!(fixture.plan_id)

      Repo.query!("UPDATE subscriptions SET current_contract_change_id = NULL WHERE id = $1", [
        subscription_id
      ])

      Repo.query!(
        "DELETE FROM oban_jobs WHERE args->>'subscription_id' = $1 OR args->>'order_id' IN (SELECT id::text FROM orders WHERE user_id = $2)",
        [fixture.subscription.id, user_id]
      )

      Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 OR order_id IN (SELECT id FROM orders WHERE user_id = $2)",
        [
          subscription_id,
          user_id
        ]
      )

      Repo.query!(
        "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

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

      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard"
        )

        Repo.query!(
          "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
          [subscription_id]
        )

        Repo.query!(
          "ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard"
        )
      end)

      Repo.query!(
        "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [subscription_id]
      )

      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])

      Repo.query!(
        "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])

      Repo.transaction(fn ->
        Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
        Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
        Repo.query!("DELETE FROM variants WHERE id = $1", [variant_id])
      end)

      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end

  defp enable_stripe! do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )
  end
end
