defmodule Store.Payments.Providers.PaystackWebhookTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Paystack
  alias Store.Payments.Types.CanonicalReceipt

  @secret "whsec_fixture_for_tests"
  @now 1_760_270_400
  @reference "checkout-018f4a1c7b2d7a918f0162e0a3c4b5d6"

  test "verifies the original body and any valid current v1 signature" do
    body = "{ \"event\": \"ping\" }"
    header = signature(body, @now) <> ",v1=whk_other:" <> String.duplicate("0", 128)

    assert {:ok, %{"event" => "ping"}} =
             Paystack.verify_webhook(%{"paystack-signature" => [header]}, body, opts())

    assert {:error, %{code: "PAYMENT_SIGNATURE_INVALID"}} =
             Paystack.verify_webhook(
               %{"paystack-signature" => [header]},
               Jason.encode!(%{event: "ping"}),
               opts()
             )
  end

  test "rejects stale, future, malformed, and missing signatures" do
    body = ~s({"event":"ping"})

    for header <- [
          signature(body, @now - 301),
          signature(body, @now + 301),
          signature(body, @now) <> ",t=#{@now}",
          "t=#{@now},v1=invalid:deadbeef"
        ] do
      assert {:error, %{code: "PAYMENT_SIGNATURE_INVALID"}} =
               Paystack.verify_webhook(%{"paystack-signature" => [header]}, body, opts())
    end

    assert {:error, %{code: "PAYMENT_SIGNATURE_MISSING"}} =
             Paystack.verify_webhook(%{"x-paystack-signature" => ["legacy"]}, body, opts())
  end

  test "normalizes a checkout event and strips private payload data" do
    assert {:ok, %CanonicalReceipt{} = receipt} = Paystack.normalize_webhook(event())
    assert receipt.provider_event_id == "charge.success:9007199254740993"
    assert receipt.provider_request_reference == @reference
    assert receipt.provider_payment_id == "9007199254740993"
    assert receipt.provider_environment == "test"
    assert receipt.amount_minor == 1000
    refute Map.has_key?(receipt.raw_payload["data"], "authorization")
    refute Map.has_key?(receipt.raw_payload["data"], "customer")
  end

  test "ignores signed pings and unrelated account events" do
    assert :ignore = Paystack.normalize_webhook(%{"event" => "ping"})
    assert :ignore = Paystack.normalize_webhook(%{"event" => "refund.processed"})

    assert :ignore =
             Paystack.normalize_webhook(put_in(event()["data"]["reference"], "other-checkout"))
  end

  test "rejects live and incomplete checkout events" do
    assert {:error, %{code: "PAYMENT_PAYLOAD_INVALID"}} =
             Paystack.normalize_webhook(put_in(event()["data"]["domain"], "live"))

    assert {:error, %{code: "PAYMENT_PAYLOAD_INVALID"}} =
             Paystack.normalize_webhook(put_in(event()["data"]["id"], 2.5))
  end

  defp opts, do: [signing_secrets: [@secret], now: @now]

  defp signature(body, timestamp) do
    digest = :crypto.mac(:hmac, :sha512, @secret, [Integer.to_string(timestamp), ".", body])
    "t=#{timestamp},v1=whk_fixture:" <> Base.encode16(digest, case: :lower)
  end

  defp event do
    %{
      "event" => "charge.success",
      "data" => %{
        "reference" => @reference,
        "id" => 9_007_199_254_740_993,
        "amount" => 1000,
        "currency" => "ZAR",
        "status" => "success",
        "domain" => "test",
        "authorization" => %{"authorization_code" => "AUTH_fixture"},
        "customer" => %{"email" => "payer@example.test"}
      }
    }
  end
end
