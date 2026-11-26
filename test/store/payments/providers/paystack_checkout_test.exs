defmodule Store.Payments.Providers.PaystackCheckoutTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Paystack
  alias Store.Payments.Types.ProviderObservation
  alias Store.Support.Errors.Error

  @reference "checkout-018f4a1c7b2d7a918f0162e0a3c4b5d6"

  test "initializes hosted checkout using the durable reference and exact money" do
    opts =
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/transaction/initialize"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rk_test_fixture"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "amount" => 1000,
                 "currency" => "ZAR",
                 "reference" => @reference,
                 "email" => "payer@example.test",
                 "channels" => ["card"],
                 "callback_url" => "http://localhost:4000/checkout/return?checkout_key=checkout"
               }

        reply(conn, 200, %{
          "status" => true,
          "data" => %{
            "reference" => @reference,
            "access_code" => "session-code",
            "authorization_url" => "https://checkout.paystack.com/session-code"
          }
        })
      end)

    assert {:ok, %{provider: :paystack, provider_checkout_url: url}} =
             Paystack.create_intent(checkout_attrs(), opts)

    assert url == "https://checkout.paystack.com/session-code"
  end

  test "rejects an initialization response for another reference and preserves duplicate handling" do
    for {http, body} <- [
          {200,
           %{
             "status" => true,
             "data" => %{
               "reference" => "other-reference",
               "access_code" => "session-code",
               "authorization_url" => "https://checkout.paystack.com/session-code"
             }
           }},
          {400, %{"status" => false, "code" => "duplicate_reference"}}
        ] do
      assert {:error, %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"}} =
               Paystack.create_intent(checkout_attrs(), stub(&reply(&1, http, body)))
    end
  end

  test "rejects unsupported setup, missing email, invalid reference, and live credentials" do
    opts = stub(fn _ -> flunk("No provider request should run") end)

    for fields <- [
          %{checkout_mode: :setup},
          %{has_subscription_lines?: true},
          %{customer_email: nil},
          %{provider_request_reference: "unsafe/path"}
        ] do
      assert {:error, %Error{}} =
               Paystack.create_intent(Map.merge(checkout_attrs(), fields), opts)
    end

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DISABLED"}} =
             Paystack.create_intent(
               checkout_attrs(),
               Keyword.put(opts, :restricted_key, "rk_live_fixture")
             )
  end

  test "observes an exact transaction reference without treating a decline as final" do
    for {status, code, gateway, outcome, finality} <- [
          {"success", "00", "approved", :authoritative_success, :authoritative_success},
          {"failed", "05", "do_not_honor", :failure_observation, :non_terminal},
          {"ongoing", nil, nil, :unresolved, :non_terminal}
        ] do
      opts =
        stub(fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/transaction/verify/#{@reference}"
          reply(conn, 200, transaction(status, code, gateway))
        end)

      assert {:ok, %ProviderObservation{} = observation} =
               Paystack.observe_payment(identity(), opts)

      assert observation.provider_reference == @reference
      assert observation.provider_transaction_id == "9007199254740993"
      assert observation.amount_minor == 1000
      assert observation.currency == "ZAR"
      assert observation.provider_environment == "test"
      assert observation.normalized_outcome == outcome
      assert Paystack.classify_payment_finality(observation) == finality
    end
  end

  test "rejects a verification result with the wrong reference or environment" do
    for field <- [%{"reference" => "another-reference"}, %{"domain" => "live"}] do
      body = update_in(transaction("success", "00", "approved")["data"], &Map.merge(&1, field))

      assert {:error, %Error{code: "PAYMENT_EVENT_UNVERIFIED"}} =
               Paystack.observe_payment(identity(), stub(&reply(&1, 200, body)))
    end
  end

  defp checkout_attrs do
    %{
      checkout_mode: :payment,
      amount_minor: 1000,
      currency: "ZAR",
      provider_request_reference: @reference,
      customer_email: "payer@example.test",
      return_url: "http://localhost:4000/checkout/return?checkout_key=checkout"
    }
  end

  defp identity do
    %{provider_reference: @reference, provider_reference_kind: :transaction_reference}
  end

  defp stub(plug), do: [restricted_key: "rk_test_fixture", request_options: [plug: plug]]

  defp reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp transaction(status, code, gateway) do
    %{
      "status" => true,
      "data" => %{
        "id" => 9_007_199_254_740_993,
        "reference" => @reference,
        "domain" => "test",
        "amount" => 1000,
        "currency" => "ZAR",
        "status" => status,
        "response_code" => code,
        "gateway_response_code" => gateway
      }
    }
  end
end
