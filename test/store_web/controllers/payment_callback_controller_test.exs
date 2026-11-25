defmodule StoreWeb.PaymentCallbackControllerTest do
  use StoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessWebhookReceiptWorker

  setup do
    {:ok, initial_receipt_count: webhook_receipt_count()}
  end

  test "callback controller stores receipt, enqueues payment webhook worker, and is enqueue-only",
       %{
         conn: conn
       } do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    raw_body = stripe_payment_event_raw_body(payment_intent)
    signature = stripe_signature(raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/payments/stripe/callback", raw_body)

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
    assert :submitted == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state
  end

  test "callback rejects missing stripe signature", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_callback_missing_sig")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/payments/stripe/callback", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_MISSING"}} = json_response(conn, 401)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    assert webhook_receipt_count() == initial_receipt_count
  end

  test "callback signature verification is bound to raw body bytes", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    compact_raw_body = stripe_payment_event_raw_body(payment_intent, "evt_callback_raw_bytes")
    modified_raw_body = Jason.encode!(Jason.decode!(compact_raw_body), pretty: true)
    signature_for_compact = stripe_signature(compact_raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature_for_compact)
      |> post(~p"/api/payments/stripe/callback", modified_raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_INVALID"}} = json_response(conn, 401)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    assert webhook_receipt_count() == initial_receipt_count
  end

  test "callback rejects unknown provider before persistence", %{
    conn: conn,
    initial_receipt_count: initial_receipt_count
  } do
    raw_body = Jason.encode!(%{"id" => "evt_callback_unknown_provider"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/payments/not-a-provider/callback", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_PROVIDER_UNSUPPORTED"}} = json_response(conn, 400)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    assert webhook_receipt_count() == initial_receipt_count
  end

  test "callback ingest emits persist, enqueue, and response telemetry", %{conn: conn} do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_callback_telemetry_001")
    signature = stripe_signature(raw_body)

    with_ingress_telemetry(fn ->
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> post(~p"/api/payments/stripe/callback", raw_body)

      assert json_response(conn, 202)

      assert_receive {:telemetry, :persist, measurements, metadata}
      assert metadata.route == :callback
      assert metadata.provider == "stripe"
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)

      assert_receive {:telemetry, :enqueue, measurements, metadata}
      assert metadata.route == :callback
      assert metadata.provider == "stripe"
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)

      assert_receive {:telemetry, :response, measurements, metadata}
      assert metadata.route == :callback
      assert metadata.status_bucket == "2xx"
      assert metadata.result == :ok
      assert measurements.duration > 0
    end)
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_submitted_payment_intent!(order_id) do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{order_id: order_id, provider: :stripe})
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    payment_intent
    |> Ash.Changeset.for_update(:submit, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp stripe_payment_event_raw_body(payment_intent, event_id \\ "evt_callback_001") do
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
