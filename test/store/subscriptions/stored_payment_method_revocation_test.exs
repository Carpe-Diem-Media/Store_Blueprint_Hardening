defmodule Store.Subscriptions.StoredPaymentMethodRevocationTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.Inputs.StartSubscriptionPaymentMethodUpdateInput
  alias Store.Subscriptions.{StoredPaymentMethod, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  @provider_refs %{
    provider: :stripe,
    provider_customer_ref: "cus_sbh_80_01",
    provider_payment_method_ref: "pm_sbh_80_01"
  }

  setup context do
    StripeAPIStub.setup_default(context)
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("sbh_80_01"))

    {:ok, user: user}
  end

  defp create_spm!(user, attrs \\ %{}) do
    base =
      Map.merge(
        %{
          user_id: user.id,
          status: :active,
          fingerprint: "fp_sbh_80_01"
        },
        @provider_refs
      )

    attrs = Map.merge(base, attrs)

    StoredPaymentMethod
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp upsert_spm(user, status) do
    base =
      Map.merge(
        %{
          user_id: user.id,
          status: status,
          fingerprint: "fp_sbh_80_01"
        },
        @provider_refs
      )

    StoredPaymentMethod
    |> Ash.Changeset.for_create(:create_or_reuse, base, context: %{system?: true})
    |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_spm!(id) do
    StoredPaymentMethod
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_active!(spm) do
    spm
    |> Ash.Changeset.for_update(:mark_active, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_inactive!(spm) do
    spm
    |> Ash.Changeset.for_update(:mark_inactive, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp mark_revoked!(spm) do
    spm
    |> Ash.Changeset.for_update(:mark_revoked, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp stale_record_error?({:error, %Ash.Error.Invalid{errors: errors}}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record_error?(_), do: false

  defp identity_count! do
    StoredPaymentMethod
    |> Ash.Query.filter(
      expr(
        provider == :stripe and provider_customer_ref == "cus_sbh_80_01" and
          provider_payment_method_ref == "pm_sbh_80_01"
      )
    )
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  describe "legal transitions" do
    test "ACTIVE -> INACTIVE succeeds", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      assert {:ok, updated} = mark_inactive!(spm)
      assert updated.status == :inactive
      assert reload_spm!(spm.id).status == :inactive
    end

    test "INACTIVE -> ACTIVE succeeds", %{user: user} do
      spm = create_spm!(user, %{status: :inactive})

      assert {:ok, updated} = mark_active!(spm)
      assert updated.status == :active
      assert reload_spm!(spm.id).status == :active
    end

    test "ACTIVE -> REVOKED succeeds", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      assert {:ok, updated} = mark_revoked!(spm)
      assert updated.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
    end

    test "INACTIVE -> REVOKED succeeds", %{user: user} do
      spm = create_spm!(user, %{status: :inactive})

      assert {:ok, updated} = mark_revoked!(spm)
      assert updated.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
    end

    test "repeated revoke remains REVOKED", %{user: user} do
      spm =
        create_spm!(user, %{status: :active})
        |> then(fn spm ->
          {:ok, revoked} = mark_revoked!(spm)
          revoked
        end)

      assert {:ok, again} = mark_revoked!(spm)
      assert again.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
    end
  end

  describe "terminal-state protection" do
    test "REVOKED -> mark_active cannot commit", %{user: user} do
      spm =
        create_spm!(user, %{status: :active})
        |> then(fn spm ->
          {:ok, revoked} = mark_revoked!(spm)
          revoked
        end)

      stale = %{spm | status: :active}

      assert stale_record_error?(mark_active!(stale))
      assert reload_spm!(spm.id).status == :revoked
    end

    test "REVOKED -> mark_inactive cannot commit", %{user: user} do
      spm =
        create_spm!(user, %{status: :active})
        |> then(fn spm ->
          {:ok, revoked} = mark_revoked!(spm)
          revoked
        end)

      stale = %{spm | status: :inactive}

      assert stale_record_error?(mark_inactive!(stale))
      assert reload_spm!(spm.id).status == :revoked
    end
  end

  describe "upsert bypass protection" do
    test "payment method authority callbacks fail closed outside a transaction", %{user: user} do
      create_attrs =
        %{
          user_id: user.id,
          status: :active,
          fingerprint: "fp_sbh_80_01"
        }
        |> Map.merge(@provider_refs)

      create_changeset =
        StoredPaymentMethod
        |> Ash.Changeset.for_create(:create_or_reuse, create_attrs, context: %{system?: true})
        |> AcquireStoredPaymentMethodAuthority.change([], %{})

      assert {%Ash.Changeset{valid?: false}, _instructions} =
               Ash.Changeset.run_before_actions(create_changeset)

      assert identity_count!() == 0

      spm = create_spm!(user, %{status: :active})

      for action <- [:mark_active, :mark_inactive, :mark_revoked] do
        update_changeset =
          spm
          |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
          |> AcquireStoredPaymentMethodAuthority.change([], %{})

        assert {%Ash.Changeset{valid?: false}, _instructions} =
                 Ash.Changeset.run_before_actions(update_changeset)

        assert reload_spm!(spm.id).status == :active
      end
    end

    for status <- [:active, :inactive, :revoked] do
      test "create_or_reuse rejects a foreign owner for #{status}", %{user: user} do
        original = create_spm!(user, %{status: unquote(status)})
        foreign_user = TestFixtures.register_user!(email: TestFixtures.unique_email("sbh_80_02"))

        assert {:error, %Ash.Error.Invalid{}} = upsert_spm(foreign_user, unquote(status))

        reloaded = reload_spm!(original.id)
        assert reloaded.user_id == user.id
        assert reloaded.status == unquote(status)
        assert reloaded.fingerprint == original.fingerprint
        assert identity_count!() == 1
      end
    end

    test "create_or_reuse cannot resurrect REVOKED row to ACTIVE", %{user: user} do
      spm =
        create_spm!(user, %{status: :active})
        |> then(fn spm ->
          {:ok, revoked} = mark_revoked!(spm)
          revoked
        end)

      assert {:ok, result} = upsert_spm(user, :active)
      assert result.id == spm.id
      assert result.status == :revoked
      assert Ash.Resource.get_metadata(result, :upsert_skipped) == true
      assert reload_spm!(spm.id).status == :revoked
    end

    test "create_or_reuse cannot resurrect REVOKED row to INACTIVE", %{user: user} do
      spm =
        create_spm!(user, %{status: :active})
        |> then(fn spm ->
          {:ok, revoked} = mark_revoked!(spm)
          revoked
        end)

      assert {:ok, result} = upsert_spm(user, :inactive)
      assert result.id == spm.id
      assert result.status == :revoked
      assert Ash.Resource.get_metadata(result, :upsert_skipped) == true
      assert reload_spm!(spm.id).status == :revoked
    end

    test "ordinary nonterminal create_or_reuse transitions remain valid", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      assert {:ok, inactive} = upsert_spm(user, :inactive)
      assert inactive.id == spm.id
      assert inactive.status == :inactive

      assert {:ok, active} = upsert_spm(user, :active)
      assert active.id == spm.id
      assert active.status == :active

      assert identity_count!() == 1
    end

    test "create_or_reuse revokes ACTIVE identity through upsert", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      assert {:ok, result} = upsert_spm(user, :revoked)
      assert result.id == spm.id
      assert result.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
      assert identity_count!() == 1
    end

    test "create_or_reuse revokes INACTIVE identity through upsert", %{user: user} do
      spm = create_spm!(user, %{status: :inactive})

      assert {:ok, result} = upsert_spm(user, :revoked)
      assert result.id == spm.id
      assert result.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
      assert identity_count!() == 1
    end

    test "repeated create_or_reuse with REVOKED status cannot recreate identity", %{user: user} do
      spm =
        create_spm!(user, %{status: :active})
        |> then(fn spm ->
          {:ok, revoked} = upsert_spm(user, :revoked)
          assert revoked.id == spm.id
          revoked
        end)

      assert {:ok, again} = upsert_spm(user, :revoked)
      assert again.id == spm.id
      assert again.status == :revoked
      assert Ash.Resource.get_metadata(again, :upsert_skipped) == true
      assert reload_spm!(spm.id).status == :revoked
      assert identity_count!() == 1
    end
  end

  describe "concurrency" do
    test "revocation wins against stale mark_active writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})
      stale = %{spm | status: :active}

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      revive_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_revive))

          wait_until(fn ->
            match?(%{release_revive?: true}, Agent.get(barrier, & &1))
          end)

          mark_active!(stale)
        end)

      wait_until(fn ->
        match?(%{phase: :at_revive}, Agent.get(barrier, & &1))
      end)

      assert {:ok, _revoked} = mark_revoked!(spm)
      Agent.update(barrier, &Map.put(&1, :release_revive?, true))

      assert stale_record_error?(Task.await(revive_task, 5_000))
      assert reload_spm!(spm.id).status == :revoked
    end

    test "revocation wins against stale upsert-active writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      upsert_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_upsert))

          wait_until(fn ->
            match?(%{release_upsert?: true}, Agent.get(barrier, & &1))
          end)

          upsert_spm(user, :active)
        end)

      wait_until(fn ->
        match?(%{phase: :at_upsert}, Agent.get(barrier, & &1))
      end)

      assert {:ok, _revoked} = mark_revoked!(spm)
      Agent.update(barrier, &Map.put(&1, :release_upsert?, true))

      assert {:ok, result} = Task.await(upsert_task, 5_000)
      assert result.id == spm.id
      assert result.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
    end

    test "revocation wins against stale mark_inactive writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})
      stale = %{spm | status: :inactive}

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      deactivate_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_deactivate))

          wait_until(fn ->
            match?(%{release_deactivate?: true}, Agent.get(barrier, & &1))
          end)

          mark_inactive!(stale)
        end)

      wait_until(fn ->
        match?(%{phase: :at_deactivate}, Agent.get(barrier, & &1))
      end)

      assert {:ok, _revoked} = mark_revoked!(spm)
      Agent.update(barrier, &Map.put(&1, :release_deactivate?, true))

      assert stale_record_error?(Task.await(deactivate_task, 5_000))
      assert reload_spm!(spm.id).status == :revoked
    end

    test "revocation wins against stale upsert-inactive writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      upsert_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_upsert))

          wait_until(fn ->
            match?(%{release_upsert?: true}, Agent.get(barrier, & &1))
          end)

          upsert_spm(user, :inactive)
        end)

      wait_until(fn ->
        match?(%{phase: :at_upsert}, Agent.get(barrier, & &1))
      end)

      assert {:ok, _revoked} = mark_revoked!(spm)
      Agent.update(barrier, &Map.put(&1, :release_upsert?, true))

      assert {:ok, result} = Task.await(upsert_task, 5_000)
      assert result.id == spm.id
      assert result.status == :revoked
      assert Ash.Resource.get_metadata(result, :upsert_skipped) == true
      assert reload_spm!(spm.id).status == :revoked
    end

    test "upsert revocation wins against stale mark_active writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})
      stale = %{spm | status: :active}

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      revive_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_revive))

          wait_until(fn ->
            match?(%{release_revive?: true}, Agent.get(barrier, & &1))
          end)

          mark_active!(stale)
        end)

      wait_until(fn ->
        match?(%{phase: :at_revive}, Agent.get(barrier, & &1))
      end)

      assert {:ok, revoked} = upsert_spm(user, :revoked)
      assert revoked.id == spm.id
      assert revoked.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
      Agent.update(barrier, &Map.put(&1, :release_revive?, true))

      assert stale_record_error?(Task.await(revive_task, 5_000))
      assert reload_spm!(spm.id).status == :revoked
    end

    test "upsert revocation wins against stale mark_inactive writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})
      stale = %{spm | status: :inactive}

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      deactivate_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_deactivate))

          wait_until(fn ->
            match?(%{release_deactivate?: true}, Agent.get(barrier, & &1))
          end)

          mark_inactive!(stale)
        end)

      wait_until(fn ->
        match?(%{phase: :at_deactivate}, Agent.get(barrier, & &1))
      end)

      assert {:ok, revoked} = upsert_spm(user, :revoked)
      assert revoked.id == spm.id
      assert revoked.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
      Agent.update(barrier, &Map.put(&1, :release_deactivate?, true))

      assert stale_record_error?(Task.await(deactivate_task, 5_000))
      assert reload_spm!(spm.id).status == :revoked
    end

    test "upsert revocation wins against stale upsert-active writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      upsert_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_upsert))

          wait_until(fn ->
            match?(%{release_upsert?: true}, Agent.get(barrier, & &1))
          end)

          upsert_spm(user, :active)
        end)

      wait_until(fn ->
        match?(%{phase: :at_upsert}, Agent.get(barrier, & &1))
      end)

      assert {:ok, revoked} = upsert_spm(user, :revoked)
      assert revoked.id == spm.id
      assert revoked.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
      Agent.update(barrier, &Map.put(&1, :release_upsert?, true))

      assert {:ok, result} = Task.await(upsert_task, 5_000)
      assert result.id == spm.id
      assert result.status == :revoked
      assert Ash.Resource.get_metadata(result, :upsert_skipped) == true
      assert reload_spm!(spm.id).status == :revoked
    end

    test "upsert revocation wins against stale upsert-inactive writer", %{user: user} do
      spm = create_spm!(user, %{status: :active})

      {:ok, barrier} = Agent.start_link(fn -> %{phase: :waiting} end)

      upsert_task =
        Task.async(fn ->
          Agent.update(barrier, &Map.put(&1, :phase, :at_upsert))

          wait_until(fn ->
            match?(%{release_upsert?: true}, Agent.get(barrier, & &1))
          end)

          upsert_spm(user, :inactive)
        end)

      wait_until(fn ->
        match?(%{phase: :at_upsert}, Agent.get(barrier, & &1))
      end)

      assert {:ok, revoked} = upsert_spm(user, :revoked)
      assert revoked.id == spm.id
      assert revoked.status == :revoked
      assert reload_spm!(spm.id).status == :revoked
      Agent.update(barrier, &Map.put(&1, :release_upsert?, true))

      assert {:ok, result} = Task.await(upsert_task, 5_000)
      assert result.id == spm.id
      assert result.status == :revoked
      assert Ash.Resource.get_metadata(result, :upsert_skipped) == true
      assert reload_spm!(spm.id).status == :revoked
    end
  end

  describe "facade production path" do
    test "create_subscriptions_from_paid_order_for_system cannot resurrect revoked stored payment method",
         %{user: user} do
      customer = %{id: user.id}
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      plan = SubscriptionsFixtures.create_subscription_plan!()
      _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

      spm =
        create_spm!(user, %{
          provider_customer_ref: "cus_sbh_80_01_facade",
          provider_payment_method_ref: "pm_sbh_80_01_facade"
        })

      assert {:ok, _revoked} = mark_revoked!(spm)

      %{order: order} =
        SubscriptionsFixtures.create_paid_order_with_subscription_line!(
          customer.id,
          variant,
          plan,
          %{
            provider_customer_ref: "cus_sbh_80_01_facade",
            provider_billing_ref: "pm_sbh_80_01_facade"
          }
        )

      assert {:ok, _result} =
               SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order.id)

      reloaded =
        StoredPaymentMethod
        |> Ash.Query.filter(expr(id == ^spm.id))
        |> Ash.read_one!(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )

      assert reloaded.status == :revoked
    end

    test "handle_payment_method_update_succeeded_for_system fails closed for revoked stored payment method in past_due recovery" do
      customer = SubscriptionsFixtures.create_customer!("sbh_80_01_pm_update")
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      plan = SubscriptionsFixtures.create_subscription_plan!()
      _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

      provider_customer_ref = "cus_sbh_80_01_pm_update"
      provider_payment_method_ref = "pm_sbh_80_01_pm_update"

      future_retry_at =
        DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:microsecond)

      %{subscription: subscription} =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
          provider_customer_ref: provider_customer_ref,
          provider_billing_ref: provider_payment_method_ref,
          next_retry_at: future_retry_at
        })

      past_due_subscription =
        subscription
        |> Ash.Changeset.for_update(
          :mark_past_due_transition,
          %{
            past_due_since_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
            billing_status_reason: "PAYMENT_METHOD_REQUIRED",
            next_retry_at: future_retry_at
          },
          context: %{system?: true}
        )
        |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

      spm_id = past_due_subscription.stored_payment_method_id

      spm =
        StoredPaymentMethod
        |> Ash.Query.filter(expr(id == ^spm_id))
        |> Ash.read_one!(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )

      assert {:ok, _revoked} = mark_revoked!(spm)

      payment_intent =
        create_succeeded_setup_intent!(
          customer,
          past_due_subscription,
          provider_payment_method_ref
        )

      assert {:error, error} =
               SubscriptionsFacade.handle_payment_method_update_succeeded_for_system(
                 payment_intent.id
               )

      assert error.code == "PAYMENT_METHOD_REQUIRED"

      reloaded_spm =
        StoredPaymentMethod
        |> Ash.Query.filter(expr(id == ^spm_id))
        |> Ash.read_one!(
          domain: Store.Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )

      assert reloaded_spm.status == :revoked

      reloaded_subscription = reload_subscription!(past_due_subscription.id)
      assert reloaded_subscription.status == :past_due
      assert reloaded_subscription.billing_status_reason == "PAYMENT_METHOD_REQUIRED"

      assert reloaded_subscription.retry_suppressed_at ==
               past_due_subscription.retry_suppressed_at

      assert reloaded_subscription.next_retry_at == future_retry_at

      refute_enqueued(
        worker: ProcessSubscriptionRenewalWorker,
        args: %{"subscription_id" => past_due_subscription.id}
      )
    end

    test "handle_payment_method_update_succeeded_for_system fails closed when stored payment method is absent" do
      customer = SubscriptionsFixtures.create_customer!("sbh_80_01_pm_update_nil")
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      plan = SubscriptionsFixtures.create_subscription_plan!()
      _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

      provider_customer_ref = "cus_sbh_80_01_pm_update_nil"
      provider_payment_method_ref = "pm_sbh_80_01_pm_update_nil"

      future_retry_at =
        DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:microsecond)

      %{subscription: subscription} =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
          provider_customer_ref: provider_customer_ref,
          provider_billing_ref: provider_payment_method_ref,
          next_retry_at: future_retry_at
        })

      past_due_subscription =
        subscription
        |> Ash.Changeset.for_update(
          :mark_past_due_transition,
          %{
            past_due_since_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
            billing_status_reason: "PAYMENT_METHOD_REQUIRED",
            next_retry_at: future_retry_at
          },
          context: %{system?: true}
        )
        |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

      original_stored_payment_method_id = past_due_subscription.stored_payment_method_id

      payment_intent = create_succeeded_setup_intent!(customer, past_due_subscription, nil)

      assert {:error, error} =
               SubscriptionsFacade.handle_payment_method_update_succeeded_for_system(
                 payment_intent.id
               )

      assert error.code == "PAYMENT_METHOD_REQUIRED"

      reloaded_subscription = reload_subscription!(past_due_subscription.id)
      assert reloaded_subscription.status == :past_due
      assert reloaded_subscription.billing_status_reason == "PAYMENT_METHOD_REQUIRED"
      assert reloaded_subscription.stored_payment_method_id == original_stored_payment_method_id

      assert reloaded_subscription.retry_suppressed_at ==
               past_due_subscription.retry_suppressed_at

      assert reloaded_subscription.next_retry_at == future_retry_at

      refute_enqueued(
        worker: ProcessSubscriptionRenewalWorker,
        args: %{"subscription_id" => past_due_subscription.id}
      )
    end
  end

  defp reload_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_succeeded_setup_intent!(customer, subscription, method_ref) do
    assert {:ok, result} =
             SubscriptionsFacade.start_subscription_payment_method_update_for_user(
               customer,
               subscription.id,
               %StartSubscriptionPaymentMethodUpdateInput{subscription_id: subscription.id}
             )

    intent =
      PaymentIntent
      |> Ash.Query.filter(expr(id == ^result.payment_intent_id))
      |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    intent =
      if is_binary(method_ref) do
        intent
        |> Ash.Changeset.for_update(
          :set_provider_reference,
          %{provider_payment_method_ref: method_ref},
          context: %{system?: true}
        )
        |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      else
        intent
      end

    intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp wait_until(predicate, attempts \\ 200)
       when is_function(predicate, 0) and is_integer(attempts) do
    do_wait_until(predicate, attempts)
  end

  defp do_wait_until(predicate, 0) do
    assert predicate.(), "wait_until/2 timed out waiting for synchronization predicate"
    :ok
  end

  defp do_wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(5)
      do_wait_until(predicate, attempts - 1)
    end
  end
end
