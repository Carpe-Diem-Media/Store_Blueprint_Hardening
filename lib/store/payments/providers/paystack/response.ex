defmodule Store.Payments.Providers.Paystack.Response do
  @moduledoc false

  alias Store.Support.Errors.Error

  @type operation :: :initialize | :verify | :charge_authorization
  @type response :: {:ok, 100..599, term()} | {:error, :timeout | :connection}
  @type outcome ::
          :checkout_initialized
          | :success_observation
          | :failure_observation
          | :reversal_observation
          | :unresolved
          | :error
  @type recovery :: :none | :validate_target | :verify_reference | :retry_read | :operator_review
  @type transaction :: %{
          id: String.t(),
          reference: String.t(),
          amount_minor: pos_integer(),
          currency: String.t(),
          environment: String.t()
        }

  @type result :: %{
          required(:outcome) => outcome(),
          required(:recovery) => recovery(),
          required(:diagnostics) => map(),
          required(:error) => Error.t() | nil,
          optional(:transaction) => transaction(),
          optional(:checkout) => %{
            authorization_url: String.t(),
            access_code: String.t(),
            reference: String.t()
          }
        }

  # https://paystack.com/docs/payments/gateway-responses/
  @gateway [
    {"approved", :approved, ~w(00 000)},
    {"refer_to_card_issuer", :declined, ~w(01)},
    {"refer_to_card_issuer_special", :declined, ~w(02)},
    {"invalid_merchant", :merchant, ~w(03 109)},
    {"pickup_card", :declined, ~w(04 200)},
    {"do_not_honor", :declined, ~w(05)},
    {"processing_error", :ambiguous, ~w(06)},
    {"pickup_card_special", :declined, ~w(07)},
    {"honour_with_identification", :authentication, ~w(08 001)},
    {"processing", :ambiguous, ~w(09)},
    {"partial_approval", :ambiguous, ~w(10 002)},
    {"vip_approval", :ambiguous, ~w(11)},
    {"invalid_transaction", :merchant, ~w(12)},
    {"invalid_amount", :merchant, ~w(13 110)},
    {"invalid_account_number", :declined, ~w(14 111)},
    {"no_such_issuer", :declined, ~w(15)},
    {"approved_update_track_3", :ambiguous, ~w(16)},
    {"customer_cancellation", :cancellation, ~w(17)},
    {"customer_dispute", :dispute, ~w(18)},
    {"reenter_transaction", :ambiguous, ~w(19)},
    {"invalid_response", :ambiguous, ~w(20)},
    {"no_action_taken", :ambiguous, ~w(21)},
    {"suspected_malfunction", :ambiguous, ~w(22)},
    {"unacceptable_transaction_fee", :merchant, ~w(23)},
    {"file_update_not_supported", :merchant, ~w(24)},
    {"unable_to_locate_record", :ambiguous, ~w(25)},
    {"duplicate_file_update", :merchant, ~w(26)},
    {"file_update_field_edit_error", :merchant, ~w(27)},
    {"file_temporarily_unavailable", :ambiguous, ~w(28)},
    {"file_update_not_successful", :merchant, ~w(29)},
    {"format_error", :merchant, ~w(30 181)},
    {"bank_not_supported", :declined, ~w(31)},
    {"completed_partially", :ambiguous, ~w(32)},
    {"expired_card", :declined, ~w(33 54 101)},
    {"suspected_fraud", :declined, ~w(34 59)},
    {"contact_acquirer", :ambiguous, ~w(35 60)},
    {"restricted_card", :declined, ~w(36 62)},
    {"call_acquirer_security", :ambiguous, ~w(37 66)},
    {"pin_tries_exceeded", :authentication, ~w(38 75 106)},
    {"no_credit_account", :declined, ~w(39)},
    {"function_not_supported", :merchant, ~w(40 115)},
    {"pickup_lost_card", :declined, ~w(41)},
    {"no_universal_account", :declined, ~w(42)},
    {"pickup_stolen_card", :declined, ~w(43)},
    {"no_investment_account", :declined, ~w(44)},
    {"account_closed", :declined, ~w(45 189)},
    {"identification_required", :authentication, ~w(46 130)},
    {"identification_cross_check_required", :authentication, ~w(47)},
    {"insufficient_funds", :declined, ~w(51)},
    {"no_checking_account", :declined, ~w(52)},
    {"no_savings_account", :declined, ~w(53)},
    {"invalid_pin", :authentication, ~w(55 117)},
    {"no_card_record", :declined, ~w(56)},
    {"transaction_not_permitted_cardholder", :declined, ~w(57 119)},
    {"transaction_not_permitted_terminal", :merchant, ~w(58)},
    {"daily_limit_exceeded", :declined, ~w(61)},
    {"security_violation", :declined, ~w(63)},
    {"original_amount_incorrect", :merchant, ~w(64)},
    {"withdrawal_frequency_exceeded", :declined, ~w(65)},
    {"hard_capture", :declined, ~w(67)},
    {"response_received_too_late", :ambiguous, ~w(68)},
    {"advice_received_too_late", :ambiguous, ~w(69)},
    {"unable_to_locate_previous_message", :ambiguous, ~w(76)},
    {"previous_message_inconsistent", :ambiguous, ~w(77)},
    {"card_blocked_first_use", :declined, ~w(78)},
    {"credit_issuer_unavailable", :ambiguous, ~w(80)},
    {"pin_cryptographic_error", :authentication, ~w(81)},
    {"cvv_verification_failed", :authentication, ~w(82)},
    {"unable_to_verify_pin", :authentication, ~w(83)},
    {"verification_no_decline", :authentication, ~w(85)},
    {"cutoff_in_progress", :ambiguous, ~w(90)},
    {"issuer_or_switch_inoperative", :ambiguous, ~w(91)},
    {"routing_destination_not_found", :ambiguous, ~w(92)},
    {"legal_violation", :declined, ~w(93)},
    {"duplicate_transmission", :ambiguous, ~w(94)},
    {"reconcile_error", :ambiguous, ~w(95)},
    {"system_malfunction", :ambiguous, ~w(96)},
    {"transaction_timeout", :ambiguous, ~w(97 911)},
    {"blocked_by_cardholder", :declined, ~w(9G)},
    {"declined", :declined, ~w(100)},
    {"invalid_cvv", :authentication, ~w(122)},
    {"invalid_from_date", :declined, ~w(125)},
    {"unsupported_currency", :merchant, ~w(183)},
    {"card_replaced", :declined, ~w(187)},
    {"bank_unavailable", :ambiguous, ~w(912)}
  ]
  @category_by_gateway Map.new(@gateway, fn {gateway, category, _} -> {gateway, category} end)
  @gateway_by_processor for {gateway, _, processors} <- @gateway,
                            processor <- processors,
                            into: %{},
                            do: {processor, gateway}

  @api_error_types ~w(api_error validation_error processor_error)
  @api_error_codes ~w(
    duplicate_reference email_address_authorization_code_mismatch invalid_amount invalid_params missing_params
    transaction_not_found unknown
  )
  @transaction_statuses ~w(success failed abandoned ongoing pending processing queued timeout reversed)
  @transaction_evidence_outcomes %{
    "success" => :success_observation,
    "reversed" => :reversal_observation
  }

  @processing_failed "PAYMENT_PROCESSING_FAILED"
  @unresolved "PAYMENT_OUTCOME_UNRESOLVED"
  @invalid_payload "PAYMENT_PAYLOAD_INVALID"
  @unverified "PAYMENT_EVENT_UNVERIFIED"

  @spec decode(operation(), response()) :: result()
  def decode(operation, {:ok, status, body})
      when operation in [:initialize, :verify, :charge_authorization] and status in 100..599 do
    diagnostics = %{http_status: status}

    case {operation, status, body} do
      {:initialize, http, %{"status" => true, "data" => data}} when http in [200, 201] ->
        checkout(data, diagnostics)

      {operation, 200, %{"status" => true, "data" => data}}
      when operation in [:verify, :charge_authorization] and is_map(data) ->
        transaction(data, diagnostics)

      {_, http, _} when http in 400..599 ->
        api_error(operation, status, body, diagnostics)

      {_, http, %{"status" => false}} when http in 200..299 ->
        api_error(operation, status, body, diagnostics)

      _ ->
        uncertain(operation, @invalid_payload, diagnostics)
    end
  end

  def decode(operation, {:error, :timeout}),
    do: uncertain(operation, "PAYMENT_PROVIDER_TIMEOUT", %{})

  def decode(operation, {:error, :connection}),
    do: uncertain(operation, "PAYMENT_PROVIDER_DOWN", %{})

  defp checkout(
         %{"authorization_url" => url, "access_code" => access_code, "reference" => reference},
         diagnostics
       )
       when is_binary(url) and is_binary(access_code) and byte_size(access_code) > 0 and
              is_binary(reference) and byte_size(reference) > 0 do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: "https",
         host: "checkout.paystack.com",
         port: 443,
         userinfo: nil,
         path: "/" <> path
       }}
      when path != "" ->
        diagnostics
        |> result(:checkout_initialized, :none)
        |> Map.put(:checkout, %{
          authorization_url: url,
          access_code: access_code,
          reference: reference
        })

      _ ->
        unresolved(@invalid_payload, diagnostics)
    end
  end

  defp checkout(_data, diagnostics), do: unresolved(@invalid_payload, diagnostics)

  defp transaction(data, diagnostics) do
    raw_processor = Map.get(data, "response_code")
    processor = processor_code(raw_processor)
    gateway = reported_gateway(Map.get(data, "gateway_response_code"))
    inferred_gateway = Map.get(@gateway_by_processor, processor)
    effective_gateway = gateway || inferred_gateway
    category = Map.get(@category_by_gateway, effective_gateway, :unknown)
    status = known_value(Map.get(data, "status"), @transaction_statuses)

    diagnostics =
      Map.merge(diagnostics, %{
        transaction_status: status,
        processor_code: processor,
        gateway_code: gateway,
        gateway_category: category
      })

    cond do
      invalid_processor?(raw_processor, processor) ->
        unresolved(@invalid_payload, diagnostics)

      gateway_conflict?(gateway, inferred_gateway, processor) ->
        unresolved(@unverified, diagnostics)

      outcome_conflict?(status, effective_gateway) ->
        unresolved(@unverified, diagnostics)

      status == nil ->
        unresolved(@invalid_payload, diagnostics)

      true ->
        case transaction_identity(data) do
          {:ok, transaction} ->
            status
            |> transaction_outcome(category, effective_gateway, diagnostics)
            |> Map.put(:transaction, transaction)

          :error ->
            unresolved(@invalid_payload, diagnostics)
        end
    end
  end

  defp invalid_processor?(raw, nil), do: raw != nil
  defp invalid_processor?(_raw, _processor), do: false

  defp gateway_conflict?(_gateway, nil, processor) when processor != nil, do: true
  defp gateway_conflict?(nil, _inferred, _processor), do: false
  defp gateway_conflict?(_gateway, nil, _processor), do: false
  defp gateway_conflict?(gateway, inferred, _processor), do: gateway != inferred

  defp outcome_conflict?("success", gateway), do: gateway not in [nil, "approved"]
  defp outcome_conflict?(status, "approved") when status in ["failed", "abandoned"], do: true
  defp outcome_conflict?(_status, _gateway), do: false

  defp transaction_outcome(status, _category, _gateway, diagnostics)
       when is_map_key(@transaction_evidence_outcomes, status) do
    result(diagnostics, Map.fetch!(@transaction_evidence_outcomes, status), :validate_target)
  end

  defp transaction_outcome("failed", :merchant, _gateway, diagnostics),
    do: failure(diagnostics, :failure_observation, :operator_review, @processing_failed)

  defp transaction_outcome("failed", :dispute, _gateway, diagnostics),
    do: failure(diagnostics, :unresolved, :operator_review, @unverified)

  defp transaction_outcome("failed", category, gateway, diagnostics)
       when category in [:authentication, :declined] do
    diagnostics
    |> result(:failure_observation, :verify_reference)
    |> Map.update!(:diagnostics, &Map.put(&1, :cause, "PAYMENT_FAILED"))
    |> Map.put(:error, Error.new("PAYMENT_FAILED", decline_message(gateway)))
  end

  defp transaction_outcome("failed", :unknown, nil, diagnostics) do
    failure(diagnostics, :failure_observation, :verify_reference, "PAYMENT_FAILED")
  end

  defp transaction_outcome(_status, _category, _gateway, diagnostics),
    do: unresolved(@unresolved, diagnostics)

  defp transaction_identity(%{
         "id" => id,
         "reference" => reference,
         "amount" => amount,
         "currency" => currency,
         "domain" => environment
       })
       when is_binary(reference) and byte_size(reference) > 0 and is_integer(amount) and
              amount > 0 and
              is_binary(currency) and environment in ["test", "live"] do
    with id when is_binary(id) <- transaction_id(id),
         true <- currency =~ ~r/\A[A-Z]{3}\z/ do
      {:ok,
       %{
         id: id,
         reference: reference,
         amount_minor: amount,
         currency: currency,
         environment: environment
       }}
    else
      _ -> :error
    end
  end

  defp transaction_identity(_data), do: :error

  defp transaction_id(id) when is_integer(id) and id > 0, do: Integer.to_string(id)

  defp transaction_id(id) when is_binary(id) do
    if id =~ ~r/\A[1-9][0-9]*\z/, do: id
  end

  defp transaction_id(_id), do: nil

  defp api_error(operation, http, body, diagnostics) do
    body = if is_map(body), do: body, else: %{}
    code = known_value(Map.get(body, "code"), @api_error_codes)

    diagnostics =
      Map.merge(diagnostics, %{
        api_error_code: code,
        api_error_type: known_value(Map.get(body, "type"), @api_error_types)
      })

    api_error_result(operation, http, code, diagnostics)
  end

  defp api_error_result(operation, 429, _code, diagnostics),
    do: uncertain(operation, "RATE_LIMITED", diagnostics)

  defp api_error_result(operation, 408, _code, diagnostics),
    do: uncertain(operation, "PAYMENT_PROVIDER_TIMEOUT", diagnostics)

  defp api_error_result(operation, http, _code, diagnostics) when http in 500..599,
    do: uncertain(operation, "PAYMENT_PROVIDER_DOWN", diagnostics)

  defp api_error_result(:verify, 404, _code, diagnostics),
    do: unresolved(@unresolved, diagnostics)

  defp api_error_result(_operation, http, code, diagnostics)
       when http in [200, 400] and code in ["duplicate_reference", "transaction_not_found"],
       do: unresolved(@unresolved, diagnostics)

  defp api_error_result(operation, http, _code, diagnostics) when http in 200..299,
    do: uncertain(operation, @processing_failed, diagnostics)

  defp api_error_result(_operation, _http, _code, diagnostics),
    do: failure(diagnostics, :error, :operator_review, @processing_failed)

  defp processor_code(code) when is_binary(code) and byte_size(code) in 2..3 do
    if code =~ ~r/\A[A-Z0-9]+\z/, do: code
  end

  defp processor_code(_code), do: nil

  defp reported_gateway(nil), do: nil

  defp reported_gateway(code) do
    if Map.has_key?(@category_by_gateway, code), do: code, else: "unknown"
  end

  defp known_value(nil, _allowed), do: nil

  defp known_value(value, allowed) do
    if value in allowed, do: value, else: :unknown
  end

  defp uncertain(:verify, cause, diagnostics)
       when cause in ["RATE_LIMITED", "PAYMENT_PROVIDER_TIMEOUT", "PAYMENT_PROVIDER_DOWN"],
       do: failure(diagnostics, :unresolved, :retry_read, cause)

  defp uncertain(_operation, cause, diagnostics), do: unresolved(cause, diagnostics)

  defp unresolved(cause, diagnostics),
    do: failure(diagnostics, :unresolved, :verify_reference, @unresolved, cause)

  defp result(diagnostics, outcome, recovery),
    do: %{outcome: outcome, recovery: recovery, diagnostics: diagnostics, error: nil}

  defp failure(diagnostics, outcome, recovery, code, cause \\ nil) do
    result = result(Map.put(diagnostics, :cause, cause || code), outcome, recovery)
    %{result | error: Error.new(code, message(code))}
  end

  defp decline_message("insufficient_funds"),
    do: "The card issuer reported insufficient funds."

  defp decline_message("expired_card"), do: "The card issuer reported that the card has expired."
  defp decline_message(_code), do: message("PAYMENT_FAILED")

  defp message(@unresolved), do: "We are checking the payment status."
  defp message(@unverified), do: "We could not verify the payment status."
  defp message("PAYMENT_FAILED"), do: "The payment was unsuccessful."
  defp message("RATE_LIMITED"), do: "Payment checks are temporarily limited. Try again shortly."

  defp message(_code),
    do: "We could not process the payment. Contact support if the issue continues."
end
