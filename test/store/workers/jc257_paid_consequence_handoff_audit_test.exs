defmodule Store.Workers.JC257PaidConsequenceHandoffAuditTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Ecto.Adapters.SQL.Sandbox
  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.{Product, Variant}
  alias Store.Comms.EmailOutbox
  alias Store.Orders.{Order, OrderLineItem, PaymentApplication}
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessWebhookReceiptWorker

  @fulfillment_worker "Store.Workers.EnsureFulfillmentForPaidOrderWorker"
  @email_worker "Store.Workers.DeliverEmailOutboxWorker"
  @paid_consequence_workers [
    @fulfillment_worker,
    "Store.Digital.Workers.IssueGrantsForPaidOrderWorker",
    "Store.Workers.EnsureSubscriptionsForPaidOrderWorker",
    "Store.Workers.ReconcilePaidSubscriptionRenewalWorker"
  ]

  test "paid physical order success and duplicate event enqueue one fulfillment job" do
    fixture = paid_physical_order_fixture!()
    on_exit(fn -> cleanup_owned_jobs!(fixture.order.id) end)

    try do
      assert fixture.product.product_kind == :simple
      assert fixture.line_item.subscription_plan_id_snapshot == nil
      assert fixture.line_item.subscription_plan_revision_id_snapshot == nil
      assert fixture.order.currency_code == "USD"
      assert fixture.order.items_subtotal_minor == 1_000
      assert fixture.order.shipping_total_minor == 0
      assert fixture.order.grand_total_minor == fixture.payment_intent.amount_received_minor

      assert :ok = process_receipt!(fixture.success_receipt)
      assert :ok = process_receipt!(fixture.success_receipt)

      assert_paid_once!(fixture.order.id, fixture.payment_intent.id)
      assert length(fulfillment_jobs(fixture.order.id)) == 1
    after
      cleanup_owned_jobs!(fixture.order.id)
    end
  end

  test "enqueue error commits paid truth and a distinct event replay does not restore fulfillment" do
    fixture = paid_physical_order_fixture!()
    fault = fault_names(fixture.order.id)

    on_exit(fn ->
      drop_fault_trigger!(fault)
      cleanup_owned_jobs!(fixture.order.id)
    end)

    try do
      install_fault_trigger!(fault)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = process_receipt!(fixture.success_receipt)
        end)

      assert log =~ "ensure_fulfillment_enqueue_failed order_id=#{fixture.order.id}"
      assert_paid_once!(fixture.order.id, fixture.payment_intent.id)
      assert fulfillment_jobs(fixture.order.id) == []

      drop_fault_trigger!(fault)

      assert :ok = process_receipt!(fixture.replay_receipt)
      assert_paid_once!(fixture.order.id, fixture.payment_intent.id)
      assert fulfillment_jobs(fixture.order.id) == []
    after
      drop_fault_trigger!(fault)
      cleanup_owned_jobs!(fixture.order.id)
    end
  end

  defp paid_physical_order_fixture! do
    suffix = Ash.UUIDv7.generate()
    user = Store.TestFixtures.register_user!(email: "jc257-#{suffix}@example.test")

    unique = String.replace(suffix, "-", "")

    product =
      Product
      |> Ash.Changeset.for_create(:create_draft, %{
        slug: "jc257-physical-#{unique}",
        title: "JC257 physical #{unique}",
        base_variant_sku: "JC257-PHYSICAL-#{unique}",
        base_variant_currency_code: "USD",
        base_variant_price_minor: 1_000,
        base_variant_stock_on_hand: 4
      })
      |> Ash.create!(domain: Store.Catalog, authorize?: false)
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, authorize?: false)

    variant =
      Variant
      |> Ash.Query.filter(expr(id == ^product.default_variant_id))
      |> Ash.read!(domain: Store.Catalog, authorize?: false)
      |> List.first()

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    line_item =
      OrderLineItem
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        line_no: 1,
        currency: "USD",
        quantity: 1,
        unit_price_minor: 1_000,
        line_total_minor: 1_000,
        sku_snapshot: variant.sku,
        product_title_snapshot: product.title,
        variant_title_snapshot: "Default",
        variant_id_snapshot: variant.id,
        discount_allocated_minor: 0,
        net_line_total_minor: 1_000
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order =
      order
      |> Ash.Changeset.for_update(
        :finalize_checkout_totals,
        %{
          currency_code: "USD",
          items_subtotal_minor: 1_000,
          shipping_total_minor: 0,
          grand_total_minor: 1_000
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        amount_received_minor: 1_000,
        currency: "USD",
        provider: :stripe
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)
      |> then(fn intent ->
        intent
        |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
        |> Ash.update!(
          domain: Store.Payments,
          authorize?: false,
          context: %{system?: true}
        )
      end)

    %{
      product: product,
      line_item: line_item,
      order: order,
      payment_intent: payment_intent,
      success_receipt: create_receipt!("evt_jc257_success_#{suffix}", payment_intent),
      replay_receipt: create_receipt!("evt_jc257_replay_#{suffix}", payment_intent)
    }
  end

  defp create_receipt!(event_id, payment_intent) do
    raw_body =
      Jason.encode!(%{
        "id" => event_id,
        "created" => 1_700_000_000,
        "livemode" => false,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id || payment_intent.id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency),
            "livemode" => false,
            "metadata" => %{"local_intent_id" => payment_intent.id},
            "status" => "succeeded"
          }
        }
      })

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, %{
      provider: "stripe",
      provider_event_id: event_id,
      event_type: "payment_intent.succeeded",
      verification_status: "verified",
      processing_status: "new",
      raw_body: raw_body,
      headers: %{"content-type" => ["application/json"]}
    })
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp process_receipt!(receipt) do
    Sandbox.unboxed_run(Store.DirectRepo, fn ->
      perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})
    end)
  end

  defp assert_paid_once!(order_id, payment_intent_id) do
    order =
      Order
      |> Ash.Query.filter(expr(id == ^order_id))
      |> Ash.read!(domain: Store.Orders, authorize?: false)
      |> List.first()

    intent =
      PaymentIntent
      |> Ash.Query.filter(expr(id == ^payment_intent_id))
      |> Ash.read!(domain: Store.Payments, authorize?: false)
      |> List.first()

    assert order.state == :paid
    assert intent.state == :succeeded

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order_id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  defp fulfillment_jobs(order_id) do
    Sandbox.unboxed_run(Store.DirectRepo, fn ->
      Store.DirectRepo.query!(
        "SELECT id FROM oban_jobs WHERE worker = $1 AND args->>'order_id' = $2",
        [@fulfillment_worker, order_id]
      ).rows
    end)
  end

  defp fault_names(order_id) do
    suffix = String.replace(order_id, "-", "")

    %{
      order_id: order_id,
      trigger: "jc257_force_fulfillment_#{suffix}",
      function: "jc257_force_fulfillment_fn_#{suffix}"
    }
  end

  defp install_fault_trigger!(%{order_id: order_id, trigger: trigger, function: function}) do
    Sandbox.unboxed_run(Store.DirectRepo, fn ->
      Store.DirectRepo.query!("""
      CREATE FUNCTION public.#{function}() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.worker = '#{@fulfillment_worker}'
          AND NEW.args->>'order_id' = '#{order_id}' THEN
          NEW.max_attempts := 0;
        END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Store.DirectRepo.query!("""
      CREATE TRIGGER #{trigger}
      BEFORE INSERT ON public.oban_jobs
      FOR EACH ROW EXECUTE FUNCTION public.#{function}();
      """)
    end)
  end

  defp drop_fault_trigger!(%{trigger: trigger, function: function}) do
    Sandbox.unboxed_run(Store.DirectRepo, fn ->
      Store.DirectRepo.query!("DROP TRIGGER IF EXISTS #{trigger} ON public.oban_jobs")
      Store.DirectRepo.query!("DROP FUNCTION IF EXISTS public.#{function}()")

      assert %{rows: [[0]]} =
               Store.DirectRepo.query!("""
               SELECT count(*) FROM pg_trigger
               WHERE tgname = '#{trigger}' AND NOT tgisinternal
               """)

      assert %{rows: [[0]]} =
               Store.DirectRepo.query!("""
               SELECT count(*) FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'public' AND p.proname = '#{function}'
               """)
    end)
  end

  defp cleanup_owned_jobs!(order_id) do
    outbox_ids =
      EmailOutbox
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.read!(domain: Store.Comms, authorize?: false)
      |> Enum.map(& &1.id)

    Sandbox.unboxed_run(Store.DirectRepo, fn ->
      Store.DirectRepo.query!(
        "DELETE FROM oban_jobs WHERE worker = ANY($1::text[]) AND args->>'order_id' = $2",
        [@paid_consequence_workers, order_id]
      )

      Enum.each(outbox_ids, fn outbox_id ->
        Store.DirectRepo.query!(
          "DELETE FROM oban_jobs WHERE worker = $1 AND args->>'email_outbox_id' = $2",
          [@email_worker, outbox_id]
        )

        assert %{rows: [[0]]} =
                 Store.DirectRepo.query!(
                   "SELECT count(*) FROM oban_jobs WHERE worker = $1 AND args->>'email_outbox_id' = $2",
                   [@email_worker, outbox_id]
                 )
      end)

      assert %{rows: [[0]]} =
               Store.DirectRepo.query!(
                 "SELECT count(*) FROM oban_jobs WHERE worker = ANY($1::text[]) AND args->>'order_id' = $2",
                 [@paid_consequence_workers, order_id]
               )
    end)
  end
end
