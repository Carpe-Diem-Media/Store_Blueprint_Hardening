defmodule StoreWeb.WebhookControllerTest do
  use StoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessRefundWebhookReceiptWorker
  alias Store.Workers.ProcessWebhookReceiptWorker

  setup do
    {:ok, initial_receipt_count: webhook_receipt_count()}
  end

  test "Paystack acknowledges after enqueue and repairs a missing handoff on resend", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    configure_paystack_signing!()
    raw_body = paystack_event()
    response = post_paystack(conn, raw_body)
    assert %{"data" => %{"webhook_receipt_id" => receipt_id}} = json_response(response, 200)

    receipt = Store.Repo.get!(WebhookReceipt, receipt_id)
    assert receipt.provider_event_id == "charge.success:123456"
    assert receipt.payload_sha256 == Base.encode16(:crypto.hash(:sha256, raw_body), case: :lower)
    assert receipt.headers == %{}
    refute receipt.raw_body =~ "AUTH_fixture"
    refute receipt.raw_body =~ "payer@example.test"

    assert [job] = all_enqueued(worker: ProcessWebhookReceiptWorker)
    assert {:ok, _job} = Store.DirectRepo.delete(job)

    parent = self()
    handler_id = {__MODULE__, :paystack_replay, make_ref()}

    :telemetry.attach(
      handler_id,
      [:store, :payments, :webhook_received],
      fn _, _, metadata, _ -> send(parent, {:paystack_receipt, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    resend = post_paystack(recycle(conn), raw_body, -1)
    assert json_response(resend, 200)["data"]["webhook_receipt_id"] == receipt_id
    assert_receive {:paystack_receipt, %{receipt_id: ^receipt_id, duplicate: true}}

    replay = post_paystack(recycle(conn), raw_body)
    assert json_response(replay, 200)["data"]["webhook_receipt_id"] == receipt_id

    assert [%Oban.Job{args: %{"webhook_receipt_id" => ^receipt_id}}] =
             all_enqueued(worker: ProcessWebhookReceiptWorker)

    assert webhook_receipt_count() == initial_receipt_count + 1
  end

  test "Paystack acknowledges a signed ping and rejects unsigned events", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    configure_paystack_signing!()
    assert response(post_paystack(conn, ~s({"event":"ping"})), 200) == ""

    invalid =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/paystack", paystack_event())

    assert json_response(invalid, 401)["errors"]["code"] == "PAYMENT_SIGNATURE_MISSING"
    assert webhook_receipt_count() == initial_receipt_count
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
  end

  defp configure_paystack_signing! do
    previous = Application.get_env(:store, :payments, [])
    config = [webhook_signing_secret: "whsec_controller_fixture"]
    Application.put_env(:store, :payments, Keyword.put(previous, :paystack, config))
    on_exit(fn -> Application.put_env(:store, :payments, previous) end)
  end

  defp post_paystack(conn, raw_body, clock_offset \\ 0) do
    timestamp = Integer.to_string(System.system_time(:second) + clock_offset)
    signed = [timestamp, ".", raw_body]
    digest = :crypto.mac(:hmac, :sha512, "whsec_controller_fixture", signed)
    signature = "t=#{timestamp},v1=whk_fixture:" <> Base.encode16(digest, case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("paystack-signature", signature)
    |> post(~p"/api/webhooks/paystack", raw_body)
  end

  defp paystack_event do
    Jason.encode!(%{
      event: "charge.success",
      data: %{
        id: 123_456,
        status: "success",
        reference: "checkout-018f4a1c7b2d7a918f0162e0a3c4b5d6",
        domain: "test",
        amount: 1000,
        currency: "ZAR",
        authorization: %{authorization_code: "AUTH_fixture"},
        customer: %{email: "payer@example.test"}
      }
    })
  end

  test "controller stores raw receipt, enqueues worker, and leaves transition to worker", %{
    conn: conn
  } do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent)
    signature = stripe_signature(raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"data" => %{"webhook_receipt_id" => webhook_receipt_id}} = json_response(conn, 202)

    assert_enqueued(
      worker: ProcessWebhookReceiptWorker,
      args: %{"webhook_receipt_id" => webhook_receipt_id},
      queue: "webhooks"
    )

    assert {:ok, [receipt]} =
             WebhookReceipt
             |> Ash.Query.filter(expr(id == ^webhook_receipt_id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert receipt.raw_body == raw_body
    assert get_in(receipt.headers, ["content-type"]) == ["application/json"]

    assert :submitted == fetch_payment_intent!(payment_intent.id).state
  end

  test "duplicate payload ingest is idempotent and reuses receipt record", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_payment_duplicate_001")
    signature = stripe_signature(raw_body)
    expected_key = "stripe:evt_payment_duplicate_001"

    conn1 =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    conn2 =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    receipt_id_1 = json_response(conn1, 202)["data"]["webhook_receipt_id"]
    receipt_id_2 = json_response(conn2, 202)["data"]["webhook_receipt_id"]

    assert receipt_id_1 == receipt_id_2

    assert [
             %Oban.Job{args: %{"webhook_receipt_id" => ^receipt_id_1}}
           ] =
             all_enqueued(
               worker: ProcessWebhookReceiptWorker,
               args: %{"webhook_receipt_id" => receipt_id_1}
             )

    count =
      WebhookReceipt
      |> Ash.Query.filter(expr(idempotency_key == ^expected_key))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  test "successful webhook ingest emits persist, enqueue, and response telemetry", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_webhook_telemetry_001")
    signature = stripe_signature(raw_body)

    with_ingress_telemetry(fn ->
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> post(~p"/api/webhooks/stripe", raw_body)

      assert json_response(conn, 202)

      assert_receive {:telemetry, :persist, measurements, metadata}
      assert metadata.route == :webhook
      assert metadata.provider == "stripe"
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)

      assert_receive {:telemetry, :enqueue, measurements, metadata}
      assert metadata.route == :webhook
      assert metadata.provider == "stripe"
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)

      assert_receive {:telemetry, :response, measurements, metadata}
      assert metadata.route == :webhook
      assert metadata.status_bucket == "2xx"
      assert metadata.result == :ok
      assert measurements.duration > 0
    end)
  end

  test "refund event payload routes to dedicated refund worker", %{conn: conn} do
    raw_body =
      Jason.encode!(%{
        "id" => "evt_refund_route_001",
        "type" => "refund.succeeded",
        "data" => %{
          "object" => %{
            "id" => "pi_refund_route_001",
            "amount" => 0,
            "currency" => "usd"
          }
        }
      })

    signature = stripe_signature(raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"data" => %{"webhook_receipt_id" => webhook_receipt_id}} = json_response(conn, 202)

    assert_enqueued(
      worker: ProcessRefundWebhookReceiptWorker,
      args: %{"webhook_receipt_id" => webhook_receipt_id},
      queue: "refunds"
    )
  end

  test "missing stripe signature is rejected", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_sig_missing_001")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_MISSING"}} = json_response(conn, 401)

    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
    assert webhook_receipt_count() == initial_receipt_count
  end

  test "invalid stripe signature is rejected", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_sig_invalid_001")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=1,v1=bad")
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_INVALID"}} = json_response(conn, 401)

    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
    assert webhook_receipt_count() == initial_receipt_count
  end

  test "unknown provider is rejected before persistence", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    raw_body = Jason.encode!(%{"id" => "evt_unknown_provider"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/not-a-provider", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_PROVIDER_UNSUPPORTED"}} = json_response(conn, 400)

    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
    assert webhook_receipt_count() == initial_receipt_count
  end

  test "signature verification uses exact raw body bytes", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()

    compact_raw_body = stripe_payment_event_raw_body(payment_intent, "evt_raw_bytes_001")

    modified_raw_body =
      Jason.encode!(Jason.decode!(compact_raw_body), pretty: true)

    signature_for_compact = stripe_signature(compact_raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature_for_compact)
      |> post(~p"/api/webhooks/stripe", modified_raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_INVALID"}} = json_response(conn, 401)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
  end

  defp create_submitted_payment_intent! do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{provider: :stripe})
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    payment_intent
    |> Ash.Changeset.for_update(:submit, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp stripe_payment_event_raw_body(payment_intent, event_id \\ "evt_payment_webhook_001") do
    Jason.encode!(%{
      "id" => event_id,
      "type" => "payment_intent.succeeded",
      "data" => %{
        "object" => %{
          "id" => payment_intent.id,
          "amount_received" => payment_intent.amount_received_minor,
          "currency" => String.downcase(payment_intent.currency || "USD"),
          "metadata" => %{}
        }
      }
    })
  end

  defp stripe_signature(raw_body, secret \\ nil) do
    secret = secret || stripe_webhook_secret()
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    payload = "#{timestamp}.#{raw_body}"

    signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp stripe_webhook_secret do
    :store
    |> Application.get_env(:payments, [])
    |> Keyword.get(:stripe, [])
    |> Keyword.fetch!(:webhook_secret)
  end

  defp webhook_receipt_count do
    WebhookReceipt
    |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  defp with_ingress_telemetry(fun) when is_function(fun, 0) do
    parent = self()
    events = [:persist, :enqueue, :response]

    Enum.each(events, fn stage ->
      :telemetry.attach(
        {__MODULE__, stage, System.unique_integer([:positive])},
        [:store, :payments, :ingress, stage],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, stage, measurements, metadata})
        end,
        nil
      )
    end)

    try do
      fun.()
    after
      :telemetry.list_handlers([:store, :payments, :ingress, :persist])
      |> Enum.filter(&match?({__MODULE__, :persist, _}, &1.id))
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)

      :telemetry.list_handlers([:store, :payments, :ingress, :enqueue])
      |> Enum.filter(&match?({__MODULE__, :enqueue, _}, &1.id))
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)

      :telemetry.list_handlers([:store, :payments, :ingress, :response])
      |> Enum.filter(&match?({__MODULE__, :response, _}, &1.id))
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)
    end
  end
end
