defmodule Store.Comms.DomainTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Comms.EmailOutbox
  alias Store.Orders.Order
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.Workers.{DeliverEmailOutboxWorker, EnqueueMembershipRenewalRemindersWorker}

  test "enqueue_order_receipt_for_system is idempotent by canonical key" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_receipt_user"))
    order = create_finalized_order!(user.id)

    assert {:ok, first} = Store.Comms.enqueue_order_receipt_for_system(order.id)
    assert {:ok, second} = Store.Comms.enqueue_order_receipt_for_system(order.id)

    assert first.id == second.id
    assert first.idempotency_key == "order_receipt:order:#{order.id}"
    assert first.provider == :swoosh
    assert first.template_kind == :order_receipt

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false)

    assert_enqueued(
      worker: DeliverEmailOutboxWorker,
      args: %{"email_outbox_id" => first.id},
      queue: "comms"
    )
  end

  test "template_kind/refund_id coherence validation rejects invalid combinations" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_coherence_user"))
    order = create_finalized_order!(user.id)

    attrs = %{
      order_id: order.id,
      refund_id: nil,
      template_kind: :refund_requested,
      to_email: user.email,
      subject: "invalid",
      body_text: "",
      body_html: nil,
      template_assigns: %{},
      idempotency_key: "invalid:#{System.unique_integer([:positive])}",
      provider: :swoosh
    }

    assert {:error, error} =
             EmailOutbox
             |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
             |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert Exception.message(error) =~
             "template_kind/order_id/refund_id/subscription_id combination is invalid"
  end

  test "identity-link template accepts only reference-less outbox rows" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_identity_user"))
    order = create_finalized_order!(user.id)

    base_attrs = %{
      order_id: nil,
      refund_id: nil,
      subscription_id: nil,
      template_kind: :identity_link_confirmation,
      to_email: user.email,
      subject: "Confirm linking your google login",
      body_text: "",
      body_html: nil,
      template_assigns: %{
        "confirmation_url" => "http://localhost:4000/confirm-new-user/token",
        "identity_provider" => "Google"
      },
      provider: :swoosh
    }

    for field <- [:order_id, :refund_id, :subscription_id] do
      attrs = Map.put(base_attrs, field, order.id)

      assert {:error, error} =
               EmailOutbox
               |> Ash.Changeset.for_create(
                 :enqueue,
                 Map.put(attrs, :idempotency_key, "identity-invalid-ref:#{field}")
               )
               |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

      assert Exception.message(error) =~
               "template_kind/order_id/refund_id/subscription_id combination is invalid"
    end

    secret_attrs =
      Map.put(base_attrs, :template_assigns, %{
        "confirmation_url" => "http://localhost:4000/confirm-new-user/token",
        "identity_provider" => "Google",
        "oauth_tokens" => %{"access_token" => "must-not-persist"}
      })

    assert {:error, error} =
             EmailOutbox
             |> Ash.Changeset.for_create(
               :enqueue,
               Map.put(secret_attrs, :idempotency_key, "identity-invalid-assigns")
             )
             |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert Exception.message(error) =~ "identity_link_confirmation assigns are invalid"
  end

  test "identity-link enqueue validates recipient provider URL and token" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_identity_valid"))
    confirmation_url = "http://localhost:4000/confirm-new-user/token"

    invalid_user = %{user | email: "not-an-email"}

    assert {:error, :invalid_recipient_email} =
             Store.Comms.enqueue_identity_link_confirmation_for_system(
               invalid_user,
               confirmation_url,
               "not-a-token",
               :google
             )

    assert {:error, :invalid_identity_provider} =
             Store.Comms.enqueue_identity_link_confirmation_for_system(
               user,
               confirmation_url,
               "not-a-token",
               :github
             )

    assert {:error, :invalid_confirmation_url} =
             Store.Comms.enqueue_identity_link_confirmation_for_system(
               user,
               "not-a-url",
               "not-a-token",
               :google
             )

    assert {:error, :invalid_confirmation_token} =
             Store.Comms.enqueue_identity_link_confirmation_for_system(
               user,
               confirmation_url,
               "not-a-token",
               :google
             )
  end

  test "identity-link delivery uses existing permanent failure bookkeeping" do
    user =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_identity_failure"))

    attrs = %{
      order_id: nil,
      refund_id: nil,
      subscription_id: nil,
      template_kind: :identity_link_confirmation,
      to_email: user.email,
      subject: "Confirm linking your google login",
      body_text: "",
      body_html: nil,
      template_assigns: %{
        "confirmation_url" => "http://localhost:4000/confirm-new-user/token",
        "identity_provider" => "Google"
      },
      idempotency_key: "identity-failure:#{System.unique_integer([:positive])}",
      provider: :req_postmark
    }

    assert {:ok, outbox} =
             EmailOutbox
             |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
             |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert {:discard, _reason} =
             perform_job(DeliverEmailOutboxWorker, %{"email_outbox_id" => outbox.id})

    updated = fetch_outbox!(outbox.id)
    assert updated.state == :failed
    assert updated.attempt_count == 1
    assert updated.last_error =~ "missing_postmark_config"
  end

  test "provider enum rejects unknown values" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_provider_user"))
    order = create_finalized_order!(user.id)

    attrs = %{
      order_id: order.id,
      refund_id: nil,
      template_kind: :order_receipt,
      to_email: user.email,
      subject: "invalid provider",
      body_text: "",
      body_html: nil,
      template_assigns: %{},
      idempotency_key: "provider-invalid:#{System.unique_integer([:positive])}",
      provider: :bogus
    }

    assert {:error, error} =
             EmailOutbox
             |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
             |> Ash.create(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert Exception.message(error) =~ "provider"
  end

  test "enqueue rejects non-enum provider input" do
    user =
      TestFixtures.register_user!(
        email: TestFixtures.unique_email("phase23_provider_string_user")
      )

    order = create_finalized_order!(user.id)

    assert {:error, :invalid_provider} =
             Store.Comms.enqueue_order_receipt_for_system(order.id, provider: "req_postmark")
  end

  test "CAS delivery claim prevents duplicate sends and increments attempts once" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_cas_user"))
    order = create_finalized_order!(user.id)
    {:ok, outbox} = Store.Comms.enqueue_order_receipt_for_system(order.id)

    assert :ok = Store.Comms.deliver_outbox_email_for_system(outbox.id)
    assert {:discard, :already_sent} = Store.Comms.deliver_outbox_email_for_system(outbox.id)

    updated = fetch_outbox!(outbox.id)
    assert updated.state == :sent
    assert updated.attempt_count == 1
    assert not is_nil(updated.sent_at)
  end

  test "reclaim_stale_processing_for_system resets stale processing rows to pending" do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_reclaim_user"))
    order = create_finalized_order!(user.id)
    {:ok, outbox} = Store.Comms.enqueue_order_receipt_for_system(order.id)

    stale_started_at = DateTime.utc_now() |> DateTime.add(-3600, :second)

    assert {:ok, _} =
             SQL.query(
               Store.Repo,
               """
               UPDATE email_outboxes
               SET state = 'processing',
                   processing_started_at = $2
               WHERE id = $1::text::uuid
               """,
               [outbox.id, stale_started_at]
             )

    assert {:ok, %{reclaimed_count: 1, outbox_ids: [reclaimed_id]}} =
             Store.Comms.reclaim_stale_processing_for_system(timeout_seconds: 60)

    assert reclaimed_id == outbox.id

    updated = fetch_outbox!(outbox.id)
    assert updated.state == :pending
    assert is_nil(updated.processing_started_at)

    assert_enqueued(
      worker: DeliverEmailOutboxWorker,
      args: %{"email_outbox_id" => outbox.id},
      queue: "comms"
    )
  end

  test "membership renewal reminders only enqueue for active memberships and are idempotent" do
    customer = SubscriptionsFixtures.create_customer!("phase27a_membership_reminder")
    other_customer = SubscriptionsFixtures.create_customer!("phase27a_membership_reminder_other")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        name: "Gold Membership",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    target_now = ~U[2026-03-08 10:00:00Z]
    renewal_at = DateTime.add(target_now, 7 * 86_400 + 600, :second)

    %{subscription: active_subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        status: :active,
        next_renewal_at: renewal_at
      })

    %{subscription: past_due_subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(other_customer.id, variant, plan, %{
        status: :past_due,
        next_renewal_at: renewal_at
      })

    assert :ok =
             perform_job(EnqueueMembershipRenewalRemindersWorker, %{
               "now" => DateTime.to_iso8601(target_now)
             })

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(
                 subscription_id == ^active_subscription.id and template_kind == :renewal_reminder
               )
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert 0 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(
                 subscription_id == ^past_due_subscription.id and
                   template_kind == :renewal_reminder
               )
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert :ok =
             perform_job(EnqueueMembershipRenewalRemindersWorker, %{
               "now" => DateTime.to_iso8601(target_now)
             })

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(
                 subscription_id == ^active_subscription.id and template_kind == :renewal_reminder
               )
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  test "membership access ended email is idempotent by subscription reason and period" do
    customer = SubscriptionsFixtures.create_customer!("phase27a_access_ended")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        name: "Premium Membership",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:premium"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        current_period_end_at: ~U[2026-03-31 00:00:00Z]
      })

    assert {:ok, first} =
             Store.Comms.enqueue_membership_access_ended_for_system(
               subscription.id,
               "grace_expired"
             )

    assert {:ok, second} =
             Store.Comms.enqueue_membership_access_ended_for_system(
               subscription.id,
               "grace_expired"
             )

    assert first.id == second.id
    assert first.template_kind == :access_ended
  end

  test "caller-proven cancellation evidence avoids mutable plan reads and keeps existing outbox behavior" do
    customer = SubscriptionsFixtures.create_customer!("jc247_c_proven_email")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        name: "Original Membership Name",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:original"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{})

    plan
    |> Ash.Changeset.for_update(
      :update,
      %{
        name: "Changed Plan",
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:changed"
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    {result, plan_query_count} =
      capture_subscription_plan_reads(fn ->
        Store.Comms.enqueue_membership_access_ended_for_system(
          subscription.id,
          "canceled_now",
          membership_access_proven?: true,
          provider: :swoosh
        )
      end)

    assert {:ok, first} = result
    assert plan_query_count == 0
    assert first.subscription_id == subscription.id
    assert first.template_kind == :access_ended
    assert first.to_email == to_string(customer.email)
    assert first.subject == "Membership access ended"
    assert first.provider == :swoosh

    assert first.idempotency_key =~
             "membership_access_ended:sub:#{subscription.id}:reason:canceled_now:period_end:"

    assert first.template_assigns["subscription_plan_id"] == subscription.subscription_plan_id
    assert first.template_assigns["reason"] == "canceled_now"

    assert {:ok, second} =
             Store.Comms.enqueue_membership_access_ended_for_system(
               subscription.id,
               "canceled_now",
               membership_access_proven?: true,
               provider: :swoosh
             )

    assert second.id == first.id

    assert_enqueued(
      worker: DeliverEmailOutboxWorker,
      args: %{"email_outbox_id" => first.id},
      queue: "comms"
    )
  end

  defp capture_subscription_plan_reads(fun) do
    counter_key = {__MODULE__, :subscription_plan_reads, make_ref()}
    handler_id = "comms_plan_read_count_#{System.unique_integer([:positive])}"
    Process.put(counter_key, 0)

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, config ->
          query = Map.get(metadata, :query, "")

          if is_binary(query) and String.contains?(String.downcase(query), "subscription_plans") do
            Process.put(config.counter_key, Process.get(config.counter_key, 0) + 1)
          end
        end,
        %{counter_key: counter_key}
      )

    try do
      result = fun.()
      {result, Process.get(counter_key, 0)}
    after
      :telemetry.detach(handler_id)
      Process.delete(counter_key)
    end
  end

  defp create_finalized_order!(user_id) do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user_id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: "USD",
        grand_total_minor: 12_500,
        items_subtotal_minor: 12_500,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_outbox!(id) do
    assert {:ok, [outbox]} =
             EmailOutbox
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Comms, authorize?: false, context: %{system?: true})

    outbox
  end
end
