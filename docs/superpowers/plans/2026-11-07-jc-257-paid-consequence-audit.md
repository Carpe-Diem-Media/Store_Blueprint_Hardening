# JC-257 paid-consequence enqueue audit implementation plan

> **For agentic workers:** Use subagent-driven-development or executing-plans. Steps use checkbox syntax. This task adds audit tests and does not change production behavior.

**Goal:** Characterize that a verified paid Stripe webhook creates one fulfillment job on ordinary success and leaves paid truth without a fulfillment job when the fulfillment enqueue fails, even after a distinct-event replay.

**Architecture:** Add one async-false `Store.DataCase` test module using the existing `ProcessWebhookReceiptWorker`, `Store.DirectRepo` Oban testing setup, `Store.Repo` sandbox fixtures, and an exact-order PostgreSQL trigger on `oban_jobs`. The trigger changes `max_attempts` to zero only for the audited fulfillment worker and order, causing the existing `positive_max_attempts` constraint to return a real Oban insert error. No production files change.

**Tech Stack:** Elixir, ExUnit, Ash 3, Ecto SQL Sandbox, Oban, PostgreSQL.

---

## File map

- Create `test/store/workers/jc257_paid_consequence_handoff_audit_test.exs`. This contains the two behavior tests, paid physical-order fixtures, verified receipt builder, narrowly scoped trigger lifecycle, and exact owned-job cleanup.

No production code or shared fixture code changes.

## Task 1: Add the audit test module

- [ ] Create the file with this complete module. The assertions inspect only fulfillment jobs owned by the fixture order; email jobs that can be committed by post-payment consequences are removed by the test cleanup using their owned outbox IDs.

```elixir
defmodule Store.Workers.JC257PaidConsequenceHandoffAuditTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Ecto.Adapters.SQL.Sandbox
  import Ash.Expr
  require Ash.Query

  alias Store.Comms.EmailOutbox
  alias Store.Orders.{Order, OrderLineItem, PaymentApplication}
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.SubscriptionsFixtures
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
      assert fixture.product.product_kind == :physical
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

    %{product: product, variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        product_kind: :physical,
        base_variant_price_minor: 1_000
      })

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
```

The fixture uses `Store.SubscriptionsFixtures.create_subscription_sellable!/1` with `product_kind: :physical`, then asserts the product kind and nil subscription snapshot fields on its genuine order line. It finalizes USD totals at 1,000 minor units and creates a submitted Stripe intent for the same amount. `process_receipt!/1` runs the actual webhook worker inside `Sandbox.unboxed_run(Store.DirectRepo, ...)`; this keeps the expected Oban constraint violation out of the shared DirectRepo sandbox transaction. No provider HTTP call is part of this verified receipt processing path.

Both tests clean committed jobs in `try/after` while the Store.Repo sandbox is available to query their owned `EmailOutbox` rows. Each registers `on_exit` before any DDL as a fallback. `Store.DataCase.setup/1` registers sandbox-owner shutdown before the test body. ExUnit's `ExUnit.OnExitHandler.run/2` executes callbacks in reverse registration order, so fallback cleanup runs before owner shutdown while the shared owner is alive. The unique trigger and function use compact UUIDv7 characters in their names, and the trigger predicate matches the exact worker and order.

### Task 2: Verify only this audit test

- [ ] Format the module, then run these commands from the repository root. The DevCore prefix comes from the project instructions and must stay on each command so test credentials come from DevCore.

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted test/store/workers/jc257_paid_consequence_handoff_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/workers/jc257_paid_consequence_handoff_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/workers/jc257_paid_consequence_handoff_audit_test.exs
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
```

The two tests should pass on the current implementation. The ordinary case delivers the same persisted success receipt twice and proves the physical order receives one matching job and one PaymentApplication. The failure case proves the actual enqueue error branch logs the failure, payment truth and its one application commit, and a later distinct verified success event does not enqueue fulfillment. This uses the actual transaction boundary and webhook replay logic. It does not prove process-exit or machine-crash durability because the test runs with `Store.Repo` Sandbox; JC263 owns broader crash certification. It does not establish shipping, inventory reservation, email, subscription, digital access, or other paid-consequence recovery behavior.

- [ ] Commit only the new test file after the focused checks pass.

## Self-review

- The plan adds one audit-only test file and no remediation.
- The failure is a real `Oban.insert/1` database error from the `positive_max_attempts` check constraint. The trigger uses the actual stored Oban worker name from `tmp/jc257/probe_oban_constraint.exs`, without an `Elixir.` prefix. It matches one worker and one fixture order. Cleanup removes only listed paid-consequence worker jobs whose args contain that order ID, plus delivery jobs tied to that order's EmailOutbox IDs.
- The test asserts a nonempty physical line with finalized USD totals matching the Stripe intent.
- The replay event has a new provider event ID for the same submitted PaymentIntent.
- Do not describe the result as full crash durability or as proof that every paid consequence fails to replay.

Root self-review checked both scenario requirements, named fault behavior against the rollback probe, source field names, worker strings, the physical fixture, test transaction limits, unique DDL identifiers, and exact owned cleanup. The audit report and remaining recovery matrix are separate tasks.
