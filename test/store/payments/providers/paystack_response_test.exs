defmodule Store.Payments.Providers.PaystackResponseTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Paystack
  alias Store.Support.Errors.Error

  # Paystack's published processor and gateway pairs, with Store feedback categories.
  @gateway_fixtures [
    {"00", "approved", :approved},
    {"01", "refer_to_card_issuer", :declined},
    {"02", "refer_to_card_issuer_special", :declined},
    {"03", "invalid_merchant", :merchant},
    {"04", "pickup_card", :declined},
    {"05", "do_not_honor", :declined},
    {"06", "processing_error", :ambiguous},
    {"07", "pickup_card_special", :declined},
    {"08", "honour_with_identification", :authentication},
    {"09", "processing", :ambiguous},
    {"10", "partial_approval", :ambiguous},
    {"11", "vip_approval", :ambiguous},
    {"12", "invalid_transaction", :merchant},
    {"13", "invalid_amount", :merchant},
    {"14", "invalid_account_number", :declined},
    {"15", "no_such_issuer", :declined},
    {"16", "approved_update_track_3", :ambiguous},
    {"17", "customer_cancellation", :cancellation},
    {"18", "customer_dispute", :dispute},
    {"19", "reenter_transaction", :ambiguous},
    {"20", "invalid_response", :ambiguous},
    {"21", "no_action_taken", :ambiguous},
    {"22", "suspected_malfunction", :ambiguous},
    {"23", "unacceptable_transaction_fee", :merchant},
    {"24", "file_update_not_supported", :merchant},
    {"25", "unable_to_locate_record", :ambiguous},
    {"26", "duplicate_file_update", :merchant},
    {"27", "file_update_field_edit_error", :merchant},
    {"28", "file_temporarily_unavailable", :ambiguous},
    {"29", "file_update_not_successful", :merchant},
    {"30", "format_error", :merchant},
    {"31", "bank_not_supported", :declined},
    {"32", "completed_partially", :ambiguous},
    {"33", "expired_card", :declined},
    {"34", "suspected_fraud", :declined},
    {"35", "contact_acquirer", :ambiguous},
    {"36", "restricted_card", :declined},
    {"37", "call_acquirer_security", :ambiguous},
    {"38", "pin_tries_exceeded", :authentication},
    {"39", "no_credit_account", :declined},
    {"40", "function_not_supported", :merchant},
    {"41", "pickup_lost_card", :declined},
    {"42", "no_universal_account", :declined},
    {"43", "pickup_stolen_card", :declined},
    {"44", "no_investment_account", :declined},
    {"45", "account_closed", :declined},
    {"46", "identification_required", :authentication},
    {"47", "identification_cross_check_required", :authentication},
    {"51", "insufficient_funds", :declined},
    {"52", "no_checking_account", :declined},
    {"53", "no_savings_account", :declined},
    {"54", "expired_card", :declined},
    {"55", "invalid_pin", :authentication},
    {"56", "no_card_record", :declined},
    {"57", "transaction_not_permitted_cardholder", :declined},
    {"58", "transaction_not_permitted_terminal", :merchant},
    {"59", "suspected_fraud", :declined},
    {"60", "contact_acquirer", :ambiguous},
    {"61", "daily_limit_exceeded", :declined},
    {"62", "restricted_card", :declined},
    {"63", "security_violation", :declined},
    {"64", "original_amount_incorrect", :merchant},
    {"65", "withdrawal_frequency_exceeded", :declined},
    {"66", "call_acquirer_security", :ambiguous},
    {"67", "hard_capture", :declined},
    {"68", "response_received_too_late", :ambiguous},
    {"69", "advice_received_too_late", :ambiguous},
    {"75", "pin_tries_exceeded", :authentication},
    {"76", "unable_to_locate_previous_message", :ambiguous},
    {"77", "previous_message_inconsistent", :ambiguous},
    {"78", "card_blocked_first_use", :declined},
    {"80", "credit_issuer_unavailable", :ambiguous},
    {"81", "pin_cryptographic_error", :authentication},
    {"82", "cvv_verification_failed", :authentication},
    {"83", "unable_to_verify_pin", :authentication},
    {"85", "verification_no_decline", :authentication},
    {"90", "cutoff_in_progress", :ambiguous},
    {"91", "issuer_or_switch_inoperative", :ambiguous},
    {"92", "routing_destination_not_found", :ambiguous},
    {"93", "legal_violation", :declined},
    {"94", "duplicate_transmission", :ambiguous},
    {"95", "reconcile_error", :ambiguous},
    {"96", "system_malfunction", :ambiguous},
    {"97", "transaction_timeout", :ambiguous},
    {"9G", "blocked_by_cardholder", :declined},
    {"000", "approved", :approved},
    {"001", "honour_with_identification", :authentication},
    {"002", "partial_approval", :ambiguous},
    {"100", "declined", :declined},
    {"101", "expired_card", :declined},
    {"106", "pin_tries_exceeded", :authentication},
    {"109", "invalid_merchant", :merchant},
    {"110", "invalid_amount", :merchant},
    {"111", "invalid_account_number", :declined},
    {"115", "function_not_supported", :merchant},
    {"117", "invalid_pin", :authentication},
    {"119", "transaction_not_permitted_cardholder", :declined},
    {"122", "invalid_cvv", :authentication},
    {"125", "invalid_from_date", :declined},
    {"130", "identification_required", :authentication},
    {"181", "format_error", :merchant},
    {"183", "unsupported_currency", :merchant},
    {"187", "card_replaced", :declined},
    {"189", "account_closed", :declined},
    {"200", "pickup_card", :declined},
    {"911", "transaction_timeout", :ambiguous},
    {"912", "bank_unavailable", :ambiguous}
  ]

  @transaction %{
    "id" => 9_007_199_254_740_993,
    "reference" => "renewal-sandbox",
    "amount" => 1000,
    "currency" => "ZAR",
    "domain" => "test"
  }

  for {raw, gateway, category} <- @gateway_fixtures do
    test "maps processor #{raw} and gateway #{gateway}" do
      raw = unquote(raw)
      gateway = unquote(gateway)
      category = unquote(category)
      status = fixture_status(category)
      data = %{"status" => status, "response_code" => raw, "gateway_response_code" => gateway}

      assert %{diagnostics: diagnostics} = result = transaction(:verify, data)
      assert diagnostics.processor_code == raw
      assert diagnostics.gateway_code == gateway
      assert diagnostics.gateway_category == category
      assert diagnostics.transaction_status == status
      assert_feedback(result, category)

      raw_only = Map.delete(data, "gateway_response_code")

      assert %{diagnostics: %{gateway_category: ^category, gateway_code: nil}} =
               raw_only_result = transaction(:charge_authorization, raw_only)

      assert_feedback(raw_only_result, category)
    end
  end

  test "reads the machine code separately from provider text and metadata" do
    val = %{
      "status" => false,
      "type" => "validation_error",
      "code" => "invalid_amount",
      "message" => "sensitive provider text",
      "meta" => %{"nextStep" => "sensitive metadata", "next_step" => "sensitive metadata"}
    }

    assert %{
             error: %Error{code: "PAYMENT_PROCESSING_FAILED", meta: %{}},
             diagnostics: diagnostics
           } =
             response(:initialize, 400, val)

    assert diagnostics == %{
             http_status: 400,
             api_error_type: "validation_error",
             api_error_code: "invalid_amount",
             cause: "PAYMENT_PROCESSING_FAILED"
           }
  end

  for {status, type, provider_code, cause, recovery} <- [
        {400, "validation_error", "missing_params", "PAYMENT_PROCESSING_FAILED",
         :operator_review},
        {400, "validation_error", "invalid_amount", "PAYMENT_PROCESSING_FAILED",
         :operator_review},
        {400, "api_error", "duplicate_reference", "PAYMENT_OUTCOME_UNRESOLVED",
         :verify_reference},
        {400, "api_error", "transaction_not_found", "PAYMENT_OUTCOME_UNRESOLVED",
         :verify_reference},
        {400, "processor_error", "email_address_authorization_code_mismatch",
         "PAYMENT_PROCESSING_FAILED", :operator_review},
        {401, "api_error", nil, "PAYMENT_PROCESSING_FAILED", :operator_review},
        {403, "api_error", "unknown", "PAYMENT_PROCESSING_FAILED", :operator_review},
        {404, nil, nil, "PAYMENT_PROCESSING_FAILED", :operator_review},
        {408, nil, nil, "PAYMENT_PROVIDER_TIMEOUT", :verify_reference},
        {422, "validation_error", nil, "PAYMENT_PROCESSING_FAILED", :operator_review},
        {429, "api_error", nil, "RATE_LIMITED", :verify_reference},
        {502, nil, nil, "PAYMENT_PROVIDER_DOWN", :verify_reference},
        {503, nil, nil, "PAYMENT_PROVIDER_DOWN", :verify_reference}
      ] do
    test "maps HTTP #{status} and API code #{inspect(provider_code)} for a possible write" do
      status = unquote(status)
      type = unquote(type)
      provider_code = unquote(provider_code)
      cause = unquote(cause)
      recovery = unquote(recovery)

      body =
        if type,
          do: %{"status" => false, "type" => type, "code" => provider_code},
          else: "<html>outside the API</html>"

      assert %{diagnostics: %{cause: ^cause}, recovery: ^recovery} =
               result = response(:charge_authorization, status, body)

      assert result.error.code == expected_api_error(recovery, cause)
    end
  end

  test "preserves the sandbox invalid_params code without recording the provider message" do
    body = %{
      "status" => false,
      "type" => "validation_error",
      "code" => "invalid_params",
      "message" => "Enter a valid email address for fixture@example.test"
    }

    assert %{
             diagnostics: %{api_error_code: "invalid_params"},
             recovery: :operator_review,
             error: %Error{code: "PAYMENT_PROCESSING_FAILED"} = error
           } = result = response(:initialize, 400, body)

    refute inspect(result.diagnostics) =~ "fixture@example.test"
    refute error.message =~ "fixture@example.test"
  end

  test "a throttled read backs off without turning the response into a payment outcome" do
    assert %{error: %Error{code: "RATE_LIMITED"}, outcome: :unresolved, recovery: :retry_read} =
             response(:verify, 429, %{"status" => false})
  end

  test "a missing provider resource on verify keeps the existing reference unresolved" do
    assert %{
             outcome: :unresolved,
             recovery: :verify_reference,
             error: %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"}
           } =
             response(:verify, 404, "Not found")
  end

  test "an HTTP success envelope with an API error still retains its diagnostic code" do
    assert %{
             outcome: :unresolved,
             recovery: :verify_reference,
             diagnostics: %{api_error_code: "duplicate_reference"}
           } =
             response(:charge_authorization, 200, %{
               "status" => false,
               "code" => "duplicate_reference"
             })
  end

  test "tracks the distinct diagnostic cause of timeout and connection loss" do
    for {reason, cause} <- [
          {:timeout, "PAYMENT_PROVIDER_TIMEOUT"},
          {:connection, "PAYMENT_PROVIDER_DOWN"}
        ] do
      assert %{
               error: %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"},
               recovery: :verify_reference,
               diagnostics: %{cause: ^cause}
             } =
               Paystack.decode_response(:charge_authorization, {:error, reason})
    end
  end

  test "a public error and operator diagnostics never echo arbitrary provider strings" do
    body = %{
      "status" => false,
      "code" => "AUTH_secret",
      "type" => "secret-type",
      "message" => "card details"
    }

    assert %{
             diagnostics: %{api_error_code: :unknown, api_error_type: :unknown},
             error: %Error{meta: %{}}
           } = result = response(:verify, 400, body)

    refute inspect(result) =~ "AUTH_secret"
    refute inspect(result) =~ "card details"
  end

  test "a success response with missing gateway codes still yields candidate evidence" do
    assert %{
             outcome: :success_observation,
             error: nil,
             recovery: :validate_target,
             transaction: %{id: "9007199254740993", reference: "renewal-sandbox"},
             diagnostics: %{gateway_code: nil, processor_code: nil}
           } =
             transaction(:verify, %{"status" => "success"})
  end

  test "a reversed transaction carries evidence without reporting a successful payment" do
    assert %{
             outcome: :reversal_observation,
             recovery: :validate_target,
             transaction: %{id: "9007199254740993"}
           } =
             transaction(:verify, %{"status" => "reversed", "response_code" => "00"})
  end

  test "a normalized-only gateway classification works and retains safe declined feedback" do
    assert %{
             error: %Error{
               code: "PAYMENT_FAILED",
               message: "The card issuer reported insufficient funds."
             },
             diagnostics: %{processor_code: nil, gateway_category: :declined}
           } =
             transaction(:verify, %{
               "status" => "failed",
               "gateway_response_code" => "insufficient_funds"
             })
  end

  test "ongoing is unresolved while an authentication code alone supplies no Store action" do
    assert %{
             outcome: :unresolved,
             recovery: :verify_reference,
             error: %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"}
           } =
             transaction(:verify, %{"status" => "ongoing", "response_code" => "001"})
  end

  test "contradictory approval and processor classification cannot release a payment" do
    for fields <- [
          %{"status" => "success", "gateway_response_code" => "do_not_honor"},
          %{"status" => "failed", "gateway_response_code" => "approved"},
          %{"status" => "success", "gateway_response_code" => "approved", "response_code" => "05"}
        ] do
      assert %{
               outcome: :unresolved,
               recovery: :verify_reference,
               diagnostics: %{cause: "PAYMENT_EVENT_UNVERIFIED"}
             } = transaction(:verify, fields)
    end
  end

  test "unknown codes and statuses fail closed and missing or malformed status is diagnosed" do
    assert %{
             outcome: :unresolved,
             diagnostics: %{
               transaction_status: :unknown,
               processor_code: "ZZ",
               gateway_code: "unknown"
             }
           } =
             transaction(:verify, %{
               "status" => "future_status",
               "response_code" => "ZZ",
               "gateway_response_code" => "future_gateway"
             })

    assert %{outcome: :unresolved, diagnostics: %{cause: "PAYMENT_PAYLOAD_INVALID"}} =
             transaction(:charge_authorization, %{"status" => "success", "id" => 23.5})

    assert %{outcome: :unresolved, diagnostics: %{cause: "PAYMENT_PAYLOAD_INVALID"}} =
             response(:charge_authorization, 200, %{"status" => true, "data" => nil})
  end

  test "an unknown or malformed processor code on a failure stays unresolved" do
    for raw <- ["ZZ", 5, "opaque provider text"] do
      assert %{
               outcome: :unresolved,
               recovery: :verify_reference,
               error: %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"}
             } =
               transaction(:verify, %{"status" => "failed", "response_code" => raw})
    end
  end

  test "valid initialization exposes only the supported hosted session as a successful result" do
    session = %{
      "authorization_url" => "https://checkout.paystack.com/session",
      "access_code" => "checkout-code",
      "reference" => "renewal-sandbox"
    }

    for http <- [200, 201] do
      assert %{
               outcome: :checkout_initialized,
               error: nil,
               recovery: :none,
               checkout: %{access_code: "checkout-code", reference: "renewal-sandbox"}
             } =
               response(:initialize, http, %{"status" => true, "data" => session})
    end

    assert %{outcome: :unresolved, diagnostics: %{cause: "PAYMENT_PAYLOAD_INVALID"}} =
             response(:initialize, 200, %{
               "status" => true,
               "data" =>
                 Map.put(
                   session,
                   "authorization_url",
                   "https://checkout.paystack.com.example/session"
                 )
             })

    assert %{outcome: :unresolved, diagnostics: %{cause: "PAYMENT_PAYLOAD_INVALID"}} =
             response(:verify, 201, %{"status" => true, "data" => @transaction})
  end

  defp assert_feedback(
         %{outcome: :success_observation, error: nil, recovery: :validate_target},
         :approved
       ),
       do: :ok

  defp assert_feedback(result, category) do
    {outcome, error_code, recovery} =
      case category do
        :merchant -> {:failure_observation, "PAYMENT_PROCESSING_FAILED", :operator_review}
        :dispute -> {:unresolved, "PAYMENT_EVENT_UNVERIFIED", :operator_review}
        :ambiguous -> {:unresolved, "PAYMENT_OUTCOME_UNRESOLVED", :verify_reference}
        :cancellation -> {:unresolved, "PAYMENT_OUTCOME_UNRESOLVED", :verify_reference}
        _ -> {:failure_observation, "PAYMENT_FAILED", :verify_reference}
      end

    assert %{
             outcome: ^outcome,
             error: %Error{code: ^error_code, message: message, meta: %{}},
             diagnostics: %{cause: ^error_code},
             recovery: ^recovery
           } = result

    assert is_binary(message) and byte_size(message) > 0
  end

  defp transaction(operation, data) do
    response(operation, 200, %{"status" => true, "data" => Map.merge(@transaction, data)})
  end

  defp response(operation, http, body) do
    Paystack.decode_response(operation, {:ok, http, body})
  end

  defp fixture_status(:approved), do: "success"
  defp fixture_status(_category), do: "failed"

  defp expected_api_error(:verify_reference, _cause), do: "PAYMENT_OUTCOME_UNRESOLVED"
  defp expected_api_error(_recovery, cause), do: cause
end
