# Paystack integration reference

Evidence recorded on 2026-11-25 and 2026-11-26. Store source baseline `949821ac589addb6e595f6333370ed65cf8d5ef7`.

This reference covers the NewYou launch payment flow for South African card payments in ZAR, the Store Blueprint boundaries that own it, and the Paystack interactions needed to certify it. [JC-284](https://linear.app/jc-dev/issue/JC-284/newyou-launch-provider-gate-paystack-recurringpayment-adapter) tracks integration and certification. OQ-004 governs the recurring mechanism and remaining provider decisions. Store's [payment provider contract](../governance/payment_provider_contract.md) and [readiness register](provider-readiness.md) govern the runtime.

**Status:** Store's signed-in, one-time ZAR checkout and exact-reference verification were exercised against Paystack Test Mode. Store applied an approved payment once and kept a declined payment pending. Store accepted a signed `charge.success` through its public test endpoint. A Paystack dashboard resend reused the receipt, worker job, and single payment application while the original paid TEST order was present. An earlier direct Paystack probe proved an off-session charge using a reusable authorization. Refunds and renewals still need Store integration.

## Where the integration fits in Store

- **Checkout and returns.** Checkout and Orders own the purchase and amount. Payments owns the local payment intent and the provider request. A successful initialization supplies the hosted Paystack checkout destination. The browser return and cancel paths display Store state. Callback parameters never authorize fulfilment. Store also has a separate signed server-to-server callback route at `POST /api/payments/:provider/callback`. [Router](../../lib/store_web/router.ex) · [Callback controller](../../lib/store_web/controllers/payment_callback_controller.ex)
- **Provider adapter.** The adapter initializes signed-in, one-time ZAR checkout and verifies exact transaction references using a test restricted key. It maps Paystack responses into Store observations and safe errors. Sandbox webhook verification uses a separate signing secret. Order, refund, subscription, and entitlement transitions belong to the domain facades and workers. The adapter can generate renewal references. Off-session collection and Paystack refunds remain unimplemented. [Provider resolver](../../lib/store/payments/providers.ex) · [Paystack adapter](../../lib/store/payments/providers/paystack.ex) · [Adapter behaviour](../../lib/store/payments/providers/behavior.ex)
- **Verification and reconciliation.** The system observation path verifies the durable transaction reference, records the evidence, and checks provider, environment, amount, currency, and identity against the payment intent. The system application path decides the commercial outcome. A decline supplies safe feedback and stays unresolved for Store. Browser return and cancel URLs are read-only. [Observation reconciliation](../../lib/store/payments/observation_reconciliation.ex) · [Provider observation](../../lib/store/payments/types/provider_observation.ex)
- **Webhook ingress.** `POST /api/webhooks/paystack` verifies the raw body and acknowledges a recognized checkout event with HTTP `200` after persisting its receipt and inserting its Oban job. Signed events outside this checkout scope receive HTTP `200` without a receipt or job. A resend repairs an unprocessed receipt with no job. The worker verifies the stored reference with Paystack and matches the event's transaction ID, amount, currency, and environment before applying payment. [Webhook controller](../../lib/store_web/controllers/webhook_controller.ex) · [Canonical receipt](../../lib/store/payments/types/canonical_receipt.ex) · [Payment worker](../../lib/store/workers/process_webhook_receipt_worker.ex) · [Paystack webhooks](https://paystack.com/docs/payments/webhooks/)
- **Recurring collection.** Store's subscription lifecycle owns scheduling, payment method authority, and durable renewal identity. The existing typed charge request has fields for the internal collection identity, provider request reference, provider credential, and optional provider customer email. The email field currently has no production assignment in `lib/store`, and the stored payment method resource has no dedicated email attribute. Decide how to retain and retrieve the email tied to the authorization before sending a Paystack charge. Confirm credential access controls and redaction before connecting the existing storage to the adapter. [Renewal charge request](../../lib/store/payments/types/renewal_collection_charge_request.ex) · [Stored payment method](../../lib/store/subscriptions/stored_payment_method.ex)
- **Commercial effects.** Store applies verified payment against its own order or renewal attempt. A retry or replay uses the existing collection and application identity. A second confirmed payment for the same renewal requires excess-collection handling. Refund, dispute, and entitlement effects remain governed by their Store domain rules. [Payment application](../../lib/store/orders/payment_application.ex) · [Refunds](../../lib/store/payments/refunds.ex)

### Identity and money mapping

| Value | Meaning and handling |
| --- | --- |
| Store order ID, payment intent ID, collection attempt ID, and renewal key | Distinct local identities. One intended renewal has one stable commercial identity across dispatch, reconciliation, and application. |
| Paystack request `reference` | Store inserts `checkout-<32 lowercase hex digits>` derived from the order UUID on a new intent before dispatch, then uses that stored value for verification. The renewal adapter maps a collection UUID to `renewal-<32 lowercase hex digits>`. |
| Paystack transaction `data.id` | Provider transaction identity returned by verification. Keep it distinct from the request reference and preserve its precision across serializers. |
| Paystack `authorization.authorization_code` and original email | Reusable payment credential and its email binding. Require `authorization.reusable: true` on the verified transaction. Keep the code opaque and the email protected. |
| Paystack `authorization_url` and `access_code` | Hosted checkout data returned by initialization. Treat both as sensitive session data. |
| Paystack event identity | Store uses `paystack:charge.success:<transaction ID>` for this checkout event. PostgreSQL's upsert returns the existing receipt ID on conflict. Store compares that ID with the attempted insert ID to detect duplicates. Local tests and a public HTTPS probe confirmed receipt and job reuse across separately signed deliveries. |
| Amount and currency | Integer minor units and explicit uppercase currency. The observed payment used `1000` and `ZAR` for R10.00. |

## Paystack interactions

| Flow | Paystack API or event | Expected Store handling |
| --- | --- | --- |
| Start hosted checkout | `POST /transaction/initialize` with email and amount. Send explicit ZAR, a unique reference, and the approved channel; the sandbox used `card`. A configured callback URL is a browser return. | Persist the local attempt and reference. Send the customer to the returned hosted checkout. |
| Read payment outcome | `GET /transaction/verify/{reference}` | Inspect `data.status` and check the exact reference, transaction identity where known, expected environment, amount, and currency. HTTP `200` and top-level `status: true` alone establish successful execution of the API request. |
| Acquire and replace a card | Complete hosted payment, then verify and inspect the authorization. | Accept reusable authorization only after verifying the originating transaction. Version or replace payment authority through Store's existing method lifecycle. Reconcile unresolved attempts against their original bound authority. |
| Charge a stored card | `POST /transaction/charge_authorization` with authorization code, original email, amount, currency, and stable reference. | Honor Store's renewal guards. Reconcile by exact reference on timeout, lost response, or duplicate-reference rejection before considering another collection. |
| Receive provider evidence | Signed webhook events including `charge.success`, plus applicable refund and dispute events. | Verify raw bytes before trusting the payload, normalize into Store's canonical receipt, and route idempotently. Keep signed browser-independent evidence distinct from redirects. |
| Request and reconcile a refund | `POST /refund` targets the original transaction ID or reference. A partial refund supplies an amount. Read refund state and consume applicable refund events. | Bind provider refund evidence to an existing Store refund attempt. Compare pending, processing, needs-attention, failed, and processed outcomes. Certify retry and duplicate protection before enablement. |
| Handle disputes and settlements | Dispute API and events such as `charge.dispute.create` and `charge.dispute.resolve`. Settlement data is environment-dependent. | Preserve a distinct evidence trail and define operator recovery and applicable compensations with the owning domain. Settlement and live dispute behavior require separate evidence. |

[Transaction API](https://paystack.com/docs/v2/api/transaction) · [Transaction statuses](https://paystack.com/docs/v2/za/payments/concepts/transaction-statuses) · [Recurring authorization](https://paystack.com/docs/v2/za/payments/recurring/charge-authorization) · [Refund lifecycle](https://paystack.com/docs/payments/refunds/) · [Disputes](https://paystack.com/docs/payments/manage-disputes/)

### Webhook verification and configuration

- In Paystack's **Test Mode**, generate the **Webhook signing secret**. Supply it privately to Store in `STORE_PAYSTACK_TEST_WEBHOOK_SIGNING_SECRET`. The separate restricted transaction key still goes in `STORE_PAYSTACK_TEST_RESTRICTED_KEY`. Add the HTTPS URL ending in `/api/webhooks/paystack` under **Test webhook URL**.
- Store checks the timestamped `Paystack-Signature` against the original request bytes with a 300-second tolerance. The format is `t=<unix-seconds>,v1=whk_<key-id>:<hex-hmac>`. Store compares each supplied digest with HMAC-SHA512 of the timestamp, a dot, and the raw body, keyed by the dedicated signing secret. Store's sandbox ingress expects this header. Paystack's deprecated `X-Paystack-Signature` uses a different format. Signing material, headers, customer fields, and card authorization details stay out of Paystack receipts. The receipt holds the original body hash and the six fields needed for checkout verification. [Paystack signature verification](https://paystack.com/docs/payments/webhooks/#verify-event-origin)
- [Signature tests](../../test/store/payments/providers/paystack_webhook_test.exs) cover altered bytes, stale and future timestamps, missing or malformed signatures, and out-of-scope events. [Ingress tests](../../test/store_web/controllers/webhook_controller_test.exs) cover HTTP `200`, receipt redaction, and recovery after the job is lost. [Worker tests](../../test/store/payments/create_intent_for_order_test.exs) cover a mismatch, a matching payment, and replay.

### Public sandbox webhook evidence

- After the Test webhook URL was saved in Paystack, a locally signed ping returned HTTP `200` through a tunnel restricted to `POST /api/webhooks/paystack`.
- A hosted R26.60 payment produced a Paystack-signed `charge.success`. Store persisted the minimized receipt and enqueued the payment worker. In DevCore TEST, the harness ran that worker, which verified the payment server-side and moved the test order to `paid`.
- A locally re-signed delivery through the same public path registered as a duplicate, reused the receipt, retained one job, and left the order paid. The test rolled back its local fixtures.
- In an earlier run, a dashboard resend reached Store after the original TEST fixtures had rolled back. Store recorded the verified receipt and discarded the job because the matching payment intent was absent. The transaction restricted key returned HTTP `403` for the webhook history API.
- In the follow-up run, the R26.60 Test Mode transaction `6799812749` was delivered and applied in a single DevCore TEST session. The harness kept the paid order and its records in place while the event was resent from Paystack's dashboard. Store reused the original receipt ID and job ID. The order stayed `paid` with the same payment-application ID and exactly one application. The harness completed with one test passing and zero failures.

[Webhook verification and retry rules](https://paystack.com/docs/payments/webhooks/) · [Dashboard resend](https://support.paystack.com/en/articles/10609026)

## Observed sandbox results

The requests used the actual Paystack test API and hosted checkout. Responses below are reduced to fields needed to reproduce or understand the result. No live API calls ran.

| Case | HTTP result | Observed behavior |
| --- | --- | --- |
| Verify without authentication | `401` | The endpoint was reachable and rejected the unauthenticated request. |
| Verify an unknown reference | `400`, `transaction_not_found` | No transaction for that reference was returned. |
| Initialize without email | `400`, `missing_params` | Email was required. |
| Initialize without amount | `400`, `invalid_amount` | The request was rejected. |
| Initialize an R10.00 card payment | `200`, top-level `status: true` | Returned `authorization_url`, `access_code`, and the submitted `reference`. |
| Verify the unpaid checkout | `200`, top-level `status: true` | `data.status: abandoned`, `domain: test`, `amount: 1000`, `currency: ZAR`, and gateway response `The transaction was not completed`. No reusable authorization was returned. |
| Repeat initialization with the same reference | `400`, `duplicate_reference` | The duplicate initialization was rejected. |
| Complete another checkout with the hosted sandbox Success option, then verify | `200`, `data.status: success` | The reference, `domain: test`, `amount: 1000`, and `currency: ZAR` matched. A transaction ID and reusable authorization were present. |
| Charge the reusable authorization, then verify | Both `200`, `data.status: success` | Verified R10.00 and the exact renewal reference. The renewal transaction ID differed from the initial checkout transaction ID. |
| Repeat the renewal request with the same reference | `400`, `duplicate_reference` | Verification again returned the original successful renewal and the same transaction ID. This was a sequential replay after success. |
| Charge the authorization with a different email | `400`, `email_address_authorization_code_mismatch` | Verify for that attempt's reference returned `400`, `transaction_not_found`. |
| Discard the response to a separate renewal charge, then verify | Verify returned `200`, `data.status: success` | Exact-reference lookup recovered the successful R10.00 charge. The caller discarded the response deliberately. No transport timeout was induced. |

No observation above establishes finality for every `abandoned`, `failed`, or `transaction_not_found` response. Establish timing and whether a later successful observation is possible before mapping these to irreversible Store outcomes. Concurrent same-reference submissions, provider-side charge cancellation, and test-to-live equivalence remain unverified.

## Error and gateway response contract

The API error code, transaction status, and gateway classification answer different questions. Keep all three in the adapter test fixtures and preserve the distinction in operator diagnostics.

1. **HTTP status and top-level API fields** describe execution of the request. Read HTTP status, `status`, `type`, and `code` together. A non-JSON or malformed response needs a safe fallback. Paystack describes three error types: `api_error`, `validation_error`, and `processor_error`. Its prose uses `meta.next_step` while its example uses `meta.nextStep`. Both are optional diagnostic hints.
2. **`data.status`** describes the provider transaction. Apply success only after Store has eligible, exact payment evidence. A verified success may arrive with both gateway fields null, as the bank-authentication sandbox case did. If a present gateway code conflicts with the transaction status, preserve both and reconcile the inconsistency.
3. **`data.gateway_response_code`** is Paystack's normalized processor classification. `data.response_code` is the raw card processor code. Keep it as a string, including leading zeroes and `9G`. Use the gateway classification for diagnostic feedback. If only the raw code is available, the documented mapping can suggest a diagnostic category. A gateway field alone cannot apply payment, declare finality, or authorize a retry. Treat missing, mismatched, and new codes explicitly.

[API error schema](https://paystack.com/docs/api/errors/) · [Gateway response fields and code inventory](https://paystack.com/docs/payments/gateway-responses/)

### HTTP and API error handling

The [Paystack decoder](../../lib/store/payments/providers/paystack/response.ex) maps decoded initialization, verification, and charge authorization responses using [registered Store error codes](../../lib/store/support/errors/error_codes.ex). Its result carries a customer-safe error, allowlisted operator diagnostics, and a recovery hint. The sandbox adapter consumes this result for initialization and verification. The current [API error responder](../../lib/store_web/controllers/api/error_responder.ex) defaults to HTTP `500` for unmapped Store codes, including `PAYMENT_FAILED`, `PAYMENT_OUTCOME_UNRESOLVED`, and `PAYMENT_AUTHENTICATION_REQUIRED`. Test and explicitly handle these outcomes if exposing them through that responder.

| Provider result | Evidence | Proposed Store feedback and action |
| --- | --- | --- |
| HTTP `200` | Sandbox: API success with transaction `failed`, `ongoing`, `abandoned`, and `success`. | Inspect `data.status` and validate the target. Return the applicable payment result. Do not forward HTTP `200` as payment confirmation. |
| HTTP `201` | Documented resource creation. Fixture required for applicable endpoints. | Treat as a resource-creation response only when the operation supports it and the payload validates. Check payment status independently. |
| HTTP `400` / `missing_params`, `invalid_amount` | Sandbox initialization. | The decoder returns `PAYMENT_PROCESSING_FAILED` for a request Store sent. Operators get the provider code. The caller-facing input boundary can use `VALIDATION_ERROR` for a field the caller can correct. |
| HTTP `400` / `duplicate_reference` | Sandbox initialization and recurring charge replay. | Reconcile the exact reference. Reuse the confirmed outcome or retain `PAYMENT_OUTCOME_UNRESOLVED`. Report a mismatch if the returned transaction conflicts with the durable Store expectation. |
| HTTP `400` / `transaction_not_found` | Sandbox verify with an unknown reference and after email mismatch. | A known ambiguous attempt stays `PAYMENT_OUTCOME_UNRESOLVED`. Continue bounded reconciliation or operator review. A single lookup cannot establish safe release or retry. |
| HTTP `400` / `email_address_authorization_code_mismatch` | Sandbox recurring charge. | `PAYMENT_PROCESSING_FAILED` for an incorrect credential binding. Retrieve the linked original email or use approved payment-method replacement. Show a generic payment-method support message. |
| HTTP `401` | Sandbox request without a key. Invalid and expired credentials need fixtures. | `PAYMENT_PROCESSING_FAILED` for outbound credential setup. Alert operators. Store user authentication is independent of Paystack authentication. |
| HTTP `403` | Sandbox refund read with the transaction-only key returned `type: api_error`, `code: unknown`. | `PAYMENT_PROCESSING_FAILED` for scope or account permissions. Alert operators and avoid automatic retry with the unchanged credentials. Classify by endpoint and status when the code is generic. |
| HTTP `404` | Sandbox nonexistent route returned a non-JSON body. | Distinguish an invalid integration route from an absent provider resource. Reconcile a known ambiguous write before concluding it is absent. Support plain-text or HTML errors without logging the body. |
| HTTP `422` | Documented refund retry guard. Fixture required. | Show an operation-specific refund state error. Check whether the refund is eligible for retry before changing Store state. |
| HTTP `429` | Documented rate limit. Fixture required. | `RATE_LIMITED` for throttling. Apply bounded backoff using Paystack's reset information when valid. Verify an uncertain write before retrying it. |
| HTTP `5xx`, timeout, connection reset, or malformed success body | Fault injection required. | `PAYMENT_PROVIDER_DOWN`, `PAYMENT_PROVIDER_TIMEOUT`, or `PAYMENT_PAYLOAD_INVALID` as the diagnostic cause. Retain `PAYMENT_OUTCOME_UNRESOLVED` for a potentially accepted write and reconcile by reference. |
| Unknown status, error type, or code | Fixture required. | Use the safe operation-specific fallback and preserve sanitized evidence. Unknown values cannot authorize a payment effect. |

[Restricted key behavior](https://paystack.com/docs/v2/api/authentication) · [Rate-limit headers](https://paystack.com/docs/api/rate-limits/) · [Refund retry contract](https://paystack.com/docs/payments/refunds/)

### Sandbox gateway checks

- **Successful checkout:** Verify returned HTTP `200`, `data.status: success`, `response_code: "00"`, and `gateway_response_code: "approved"`. This matched Paystack's documented pair.
- **Declined preset:** Verify returned HTTP `200`, top-level `status: true`, `data.status: failed`, `response_code: "05"`, and `gateway_response_code: "do_not_honor"`. This matched Paystack's documented pair.
- **Insufficient funds test card:** Checkout displayed an insufficient funds message. Verify returned HTTP `200`, `data.status: failed`, `response_code: "51"`, and `gateway_response_code: "insufficient_funds"`. This matched Paystack's documented pair.
- **Bank Authentication preset:** While checkout waited for authentication, verify returned HTTP `200` with `data.status: ongoing`. A later verification returned `data.status: success`. Both gateway fields were null in both observations. This is a fixture for an in-progress payment and a success response without gateway codes.
- **Other processor outcomes:** The remaining 104 documented pairs have no sandbox evidence in this run. Add sandbox evidence where Paystack offers a matching scenario. Cover all 107 pairs in adapter fixtures.

[South African test payment scenarios](https://paystack.com/docs/v2/za/developer-tools/integration/test-payments)

### Store checkout sandbox evidence

- Two signed-in ZAR orders were created through Store's checkout and payment-intent flow in DevCore TEST. The harness submitted hosted Paystack test payments and invoked Store's system observation and application entry points. The temporary TEST fixtures were rolled back after the run.
- The approved R26.60 transaction matched Store's reference, ZAR amount in minor units, and test environment. Store resolved it as `authoritative_success`, put the order in `paid`, and returned `already_applied_success` on replay.
- The declined transaction returned `PAYMENT_FAILED` feedback from the mapper. Store resolved it as `unresolved` and retained the order in `pending_payment`.
- The harness verified and applied payment through system functions. Phoenix's customer return page and signed Paystack event delivery were outside the run.

### Gateway code inventory and proposed Store feedback

The inventory contains all 107 pairs published in the cited Paystack gateway guide at review time. It includes 85 standard entries and 22 Amex entries. The code pairs are Paystack's documented values. The group, Store result, and operator action are the proposed integration contract.

#### Approved

Proposed Store result: Verified payment. Apply only after exact target checks and eligible verified success.

| Processor code | Paystack gateway code |
| --- | --- |
| `00` | `approved` |
| `000` | `approved` |

#### Authentication or verification

Proposed Store result: `PAYMENT_AUTHENTICATION_REQUIRED` only with an explicit actionable provider state. For existing hosted flows, follow verified provider instructions. Otherwise show a safe retry or payment-method prompt once the current outcome is resolved.

| Processor code | Paystack gateway code |
| --- | --- |
| `08` | `honour_with_identification` |
| `38` | `pin_tries_exceeded` |
| `46` | `identification_required` |
| `47` | `identification_cross_check_required` |
| `55` | `invalid_pin` |
| `75` | `pin_tries_exceeded` |
| `81` | `pin_cryptographic_error` |
| `82` | `cvv_verification_failed` |
| `83` | `unable_to_verify_pin` |
| `85` | `verification_no_decline` |
| `001` | `honour_with_identification` |
| `106` | `pin_tries_exceeded` |
| `117` | `invalid_pin` |
| `122` | `invalid_cvv` |
| `130` | `identification_required` |

#### Card or issuer declined

Proposed Store result: `PAYMENT_FAILED` or `PAYMENT_METHOD_REQUIRED` when applicable. Show a customer-safe decline message. Insufficient funds, expired cards, and blocked cards can get specific feedback when safe. Fraud, lost-card, and stolen-card detail stays restricted.

| Processor code | Paystack gateway code |
| --- | --- |
| `01` | `refer_to_card_issuer` |
| `02` | `refer_to_card_issuer_special` |
| `04` | `pickup_card` |
| `05` | `do_not_honor` |
| `07` | `pickup_card_special` |
| `14` | `invalid_account_number` |
| `15` | `no_such_issuer` |
| `31` | `bank_not_supported` |
| `33` | `expired_card` |
| `34` | `suspected_fraud` |
| `36` | `restricted_card` |
| `39` | `no_credit_account` |
| `41` | `pickup_lost_card` |
| `42` | `no_universal_account` |
| `43` | `pickup_stolen_card` |
| `44` | `no_investment_account` |
| `45` | `account_closed` |
| `51` | `insufficient_funds` |
| `52` | `no_checking_account` |
| `53` | `no_savings_account` |
| `54` | `expired_card` |
| `56` | `no_card_record` |
| `57` | `transaction_not_permitted_cardholder` |
| `59` | `suspected_fraud` |
| `61` | `daily_limit_exceeded` |
| `62` | `restricted_card` |
| `63` | `security_violation` |
| `65` | `withdrawal_frequency_exceeded` |
| `67` | `hard_capture` |
| `78` | `card_blocked_first_use` |
| `93` | `legal_violation` |
| `9G` | `blocked_by_cardholder` |
| `100` | `declined` |
| `101` | `expired_card` |
| `111` | `invalid_account_number` |
| `119` | `transaction_not_permitted_cardholder` |
| `125` | `invalid_from_date` |
| `187` | `card_replaced` |
| `189` | `account_closed` |
| `200` | `pickup_card` |

#### Cancellation

Proposed Store result: Existing cancellation result or `PAYMENT_OUTCOME_UNRESOLVED` while uncertain. Show checkout cancellation when confirmed. Verify the outstanding attempt before accepting a replacement.

| Processor code | Paystack gateway code |
| --- | --- |
| `17` | `customer_cancellation` |

#### Dispute indication

Proposed Store result: `PAYMENT_EVENT_UNVERIFIED` until dispute evidence is matched. Route for review. Require a separately verified dispute event or API record for a dispute effect.

| Processor code | Paystack gateway code |
| --- | --- |
| `18` | `customer_dispute` |

#### Merchant or request issue

Proposed Store result: `PAYMENT_PROCESSING_FAILED`. Operator inspects merchant setup or request. Customer gets a generic payment-processing message. Reconcile any uncertain write.

| Processor code | Paystack gateway code |
| --- | --- |
| `03` | `invalid_merchant` |
| `12` | `invalid_transaction` |
| `13` | `invalid_amount` |
| `23` | `unacceptable_transaction_fee` |
| `24` | `file_update_not_supported` |
| `26` | `duplicate_file_update` |
| `27` | `file_update_field_edit_error` |
| `29` | `file_update_not_successful` |
| `30` | `format_error` |
| `40` | `function_not_supported` |
| `58` | `transaction_not_permitted_terminal` |
| `64` | `original_amount_incorrect` |
| `109` | `invalid_merchant` |
| `110` | `invalid_amount` |
| `115` | `function_not_supported` |
| `181` | `format_error` |
| `183` | `unsupported_currency` |

#### Ambiguous or upstream issue

Proposed Store result: `PAYMENT_OUTCOME_UNRESOLVED` for possible writes. Verify the exact reference and review provider availability or unusual partial results. Never release goods, collect a new payment, or infer finality from this classification alone.

| Processor code | Paystack gateway code |
| --- | --- |
| `06` | `processing_error` |
| `09` | `processing` |
| `10` | `partial_approval` |
| `11` | `vip_approval` |
| `16` | `approved_update_track_3` |
| `19` | `reenter_transaction` |
| `20` | `invalid_response` |
| `21` | `no_action_taken` |
| `22` | `suspected_malfunction` |
| `25` | `unable_to_locate_record` |
| `28` | `file_temporarily_unavailable` |
| `32` | `completed_partially` |
| `35` | `contact_acquirer` |
| `37` | `call_acquirer_security` |
| `60` | `contact_acquirer` |
| `66` | `call_acquirer_security` |
| `68` | `response_received_too_late` |
| `69` | `advice_received_too_late` |
| `76` | `unable_to_locate_previous_message` |
| `77` | `previous_message_inconsistent` |
| `80` | `credit_issuer_unavailable` |
| `90` | `cutoff_in_progress` |
| `91` | `issuer_or_switch_inoperative` |
| `92` | `routing_destination_not_found` |
| `94` | `duplicate_transmission` |
| `95` | `reconcile_error` |
| `96` | `system_malfunction` |
| `97` | `transaction_timeout` |
| `002` | `partial_approval` |
| `911` | `transaction_timeout` |
| `912` | `bank_unavailable` |

#### Unknown or missing classifications

An unlisted raw code is documented as `unknown`. Add fixtures for a new raw code, an explicit `unknown` gateway code, both fields absent, and conflicting raw and normalized codes. Support a normalized code without a raw code for channels where no processor code is returned. Use generic customer feedback and operator diagnostics. Only eligible verified transaction state establishes a commercial effect.

### Adapter tests and operator feedback

- **Sandbox tests:** Exercise the published South African test cards and hosted presets. Record the verified status, normalized code, raw code, and whether either code is absent. Record scope and transport separately from transaction outcome. Avoid forcing outages or rate limits against Paystack.
- **Adapter fixture tests.** The [decoder tests](../../test/store/payments/providers/paystack_response_test.exs) exercise all 107 documented pairs. The [adapter tests](../../test/store/payments/providers/paystack_checkout_test.exs) check the HTTP payload and reference, environment, and decline classification. The [checkout tests](../../test/store/payments/create_intent_for_order_test.exs) cover reuse, declined feedback, amount mismatch, replay, legacy references, and interrupted setup. Signed fixtures, live delivery, and dashboard replay are recorded above.
- **Lifecycle tests:** Cover timeout after provider acceptance, duplicate-reference rejection, an initial not-found result followed by success, and status changes across observations. Assert exact-reference reconciliation, at most one commercial application, and no automatic new charge while the previous result is uncertain.
- **Operator feedback:** Correlate by operation, Store attempt ID, provider reference, test/live mode, HTTP status, API error type and code, transaction status, normalized gateway code, raw processor code, and recovery decision. Redact free-form provider messages and metadata before retaining them. Customer-facing feedback uses stable Store codes and approved text. Keep authorization codes, card data, keys, signatures, and full provider bodies out of ordinary logs.

Sandbox initialization and verification use the decoder, including the verification requested by the signed checkout webhook worker. Off-session charging remains part of JC-284.

### Local Store sandbox configuration

- Supply a test restricted key to the Store process in `STORE_PAYSTACK_TEST_RESTRICTED_KEY`. Store reads this variable in DEV and TEST. Use `transactions:write`, which includes reads.
- Set `STORE_PAYSTACK_SANDBOX_CHECKOUT=1` when launching Store in DEV to select Paystack for storefront sandbox checkout. Use a signed-in buyer and an order with a positive ZAR total and no subscription lines. The Pay button uses the enabled purchase gateway selected on the server and is unavailable when there is no enabled default.
- Set `STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI` to the intended enabled gateway in deployments that expose the storefront Pay button. Before changing a deployed gateway, reconcile outstanding checkouts. Payment intent keys include the provider, so reuse under one gateway does not establish safety when switching an unresolved order to another. [Payment intent identity](../../lib/store/support/governance/idempotency.ex)
- The signed Paystack webhook worker verifies the exact transaction before applying payment. For a direct system check, call `Store.Payments.Facade.observe_payment_intent_for_system/1` with an `ObservePaymentIntentInput`, then pass the result to `apply_observed_payment_outcome_for_system/1`. The browser return is read-only.
- A Paystack intent created by the original scaffold can lack a provider reference. The immutable reference constraint prevents backfilling it through an update. In this case checkout returns `PAYMENT_OUTCOME_UNRESOLVED` with `missing_durable_reference` for support review before any provider call.

### HTTPS browser access and callback reproduction

1. Open the sandbox storefront access page. On the local test tunnel it is `/__sandbox/access`. Click **Visit Site** on the ngrok first-visit page, if shown, then enter the private sandbox access code. The access code and the synthetic Store buyer password are separate credentials. Retrieve them through the operator's local credential files or private sharing channel. Keep both out of the guide, PR, logs, and screenshots. Use a buyer account from DevCore TEST with a real-format synthetic email, such as one under `example.com`.
2. Sign in as the buyer, add a digital-only product with a configured asset, enter the billing location, and start a fresh checkout. Keep the same browser session from sign-in through Paystack and back to Store. Store supplies `/checkout/return` on the same HTTPS origin with the order's checkout key as the per-transaction `callback_url`. The dashboard **Test callback URL** can remain blank. The **Test webhook URL** is the separate signed `POST /api/webhooks/paystack` endpoint. [Paystack Initialize Transaction](https://paystack.com/docs/api/transaction/#initialize-transaction)
3. Complete the hosted Test Mode payment and wait for Paystack to navigate. Record whether it returned automatically, whether Store showed the same order, and whether exact-reference verification, webhook processing, one payment application, one grant, and zero shipping agree. Opening the return manually provides separate route evidence. A browser redirect never applies a payment.

The workstation tunnel and its access proxy are temporary test infrastructure. The browser access form reached Store sign-in with an HTTP `303` followed by `200` after its referrer policy was corrected to preserve the form's same-origin `Origin` header. Cross-origin form submissions still returned `403`. The signed ping returned `200` and the unsigned webhook request returned `401` on the same hostname. The subsequent hosted payment also returned the buyer to Store automatically, as recorded below.


## Reproduce the provider evidence

1. Use a restricted key in Paystack Test Mode with `transactions:write`, which includes transaction reads. The direct probe used `NEWYOU_PAYSTACK_TEST_RESTRICTED_KEY` supplied from a private, owner-readable file outside the repository. Supply separate test webhook signing credentials and additional API scopes only for the endpoints under test. [Restricted scopes and authentication](https://paystack.com/docs/v2/api/authentication)
2. Send authenticated HTTPS requests to `api.paystack.co` using a fresh reference and a synthetic email. Pass the bearer header without exposing the key in command arguments or logs. Initialize with `amount: 1000`, `currency: ZAR`, and `channels: ["card"]`. Verify the unpaid reference first if reproducing the abandonment observation.
3. For success, open a fresh checkout using its returned URL, confirm it displays Test Mode, and select the sandbox Success option or use a published reusable test card. Verify the transaction and obtain the authorization in memory. [South African sandbox payment scenarios](https://paystack.com/docs/v2/za/developer-tools/integration/test-payments)
4. Charge with the exact original email and a fresh `renewal-<32 lowercase hex digits>` reference. Verify that reference, repeat the same charge, and compare verified transaction identities. Use separate references for the email-mismatch and discarded-response cases.
5. Record the date, mode, endpoint, redacted request shape, HTTP status, provider code, verified transaction status, reference match, amount, currency, and identity comparisons. For webhook cases include timeline, normalized event identity, receipt and job outcome, and resulting domain effect. Keep API keys, webhook signing material, checkout links, access codes, authorization codes, and customer data out of shared evidence.

## Checkout retries and interrupted payments

The regression tests use a finalized Store order, PostgreSQL TEST, and controlled Paystack HTTP responses. The overlapping case holds the first initialize response until the second caller completes. It exercises the backend path shared by both clicks. Two actual browser tabs on Paystack's hosted page remain a separate sandbox check. [Checkout regression tests](../../test/store/payments/create_intent_for_order_test.exs) · [Paystack transaction verification](https://paystack.com/docs/payments/verify-payments/)

- **Two tabs or overlapping Pay clicks.** Store creates one local payment intent. If both requests reach initialization before Store saves the checkout URL, they can send two POSTs with the same Paystack reference and payload. The fixture returns `duplicate_reference` for the second POST and Store reports `PAYMENT_OUTCOME_UNRESOLVED`. When the first request completes, either caller can resume using the persisted URL. The direct sandbox duplicate-reference probe previously confirmed Paystack rejects reinitializing the same reference.
- **Connection lost after Store saves the URL.** Refreshing and clicking again reuses the intent and URL without a new POST. The test discards the first caller's response and performs the retry separately.
- **Initialize response lost before Store saves the URL.** Store keeps the order in `pending_provider_setup` with one `created` intent and no URL. A refresh retries the same reference. An absent transaction, a duplicate reference response, or an ongoing status leaves payment unresolved. If exact-reference verification later proves success, Store can now apply that payment to the `created` intent. The matching webhook worker can do the same. A repeated success reuses the payment application, and a Pay request after the order is paid returns `PAYMENT_ALREADY_SUCCEEDED` without calling Paystack.
- **Success arrives after checkout expiry.** The existing stale-setup sweep can cancel an unresolved order and release its inventory. Later exact-reference success leaves the order cancelled and records no payment application. The customer may have paid at Paystack while Store still shows a cancelled order. This is a certification blocker. Define the approved handling for reservations, customer feedback, and remediation before exposing this checkout to customers. [Stale setup worker](../../lib/store/workers/expire_pending_provider_setup_orders_worker.ex)
- **Browser and operational follow-up.** Two connected LiveViews shared one Paystack redirect and one initialize request in a test with a simulated provider. Exercise a rapid double click, two browser tabs, offline navigation, refresh before and after redirect, and two attempts to submit the same hosted session in Paystack Test Mode. Verify final order status and the customer message in each tab. Also cover an expired hosted session and missing webhook delivery. The scheduled setup recovery currently selects intents with persisted provider response fields. An intent with only its request reference does not qualify. [Storefront test](../../test/store_web/live/cart_checkout_live_test.exs) · [Setup recovery query](../../lib/store/payments/domain.ex)

Run the checkout and webhook regression tests locally with DevCore TEST. The simulated responses need no Paystack credentials.

```bash
devcore-project run test -- mix test \
  test/store/payments/create_intent_for_order_test.exs \
  test/store/payments/provider_fault_isolation_test.exs \
  test/store/payments/providers/paystack*test.exs \
  test/store/workers/{process_webhook_receipt,expire_pending_provider_setup_orders,expire_inventory_reservations}_worker_test.exs \
  test/store_web/controllers/{webhook,payment_callback}_controller_test.exs \
  test/store_web/live/cart_checkout_live_test.exs \
  test/store/orders/pending_provider_setup_backlog_test.exs
```

## NewYou digital launch

The recommended scope for JC-284 is one-time digital purchases and Store-scheduled digital subscriptions. Paystack handles card checkout, charges, and verification. Store owns collection timing and customer access. Physical and mixed carts need a separate launch decision.

- **Proved locally with Paystack response fixtures.** A ZAR order explicitly classified as digital retained one payment intent after a lost initialize response. A mismatched verification created no payment application, grant job, or customer grant. Exact-reference success made the order paid and enqueued one digital grant job and zero physical fulfillment jobs. Replaying both payment and grant workers kept the same payment application and buyer-visible grant. Another account saw no grant. [Checkout and grant test](../../test/store/payments/create_intent_for_order_test.exs)
- **Digital shipping is disabled.** Select **Digital download** in the product form before publishing. Attach the downloadable asset through the existing digital catalog workflow. The storefront collects billing country and region, and the finalized order stores the location and tax calculation. It creates no shipping quote, shipping adjustment, or stock hold. A download link on a physical product does not change its shipping behavior. A mixed cart reserves and fulfills only its physical items. [Admin product form](../../lib/store_web/live/admin/products/form_component.ex) · [Checkout test](../../test/store/checkout/domain_test.exs)
- **First paid subscription and renewal.** Confirm Store's ownership of the billing schedule under OQ-004. Bind a verified reusable authorization and its original Paystack email to the customer and payment method. Prove that first payment activates the subscription and a scheduled renewal extends access once. Exercise duplicate collection requests, an uncertain charge recovered by exact reference, card replacement, a decline, and cancellation at the renewal boundary. The earlier direct Paystack charge proves the provider operation. Store's Paystack subscription checkout and off-session charge are still disabled. [Paystack adapter](../../lib/store/payments/providers/paystack.ex)
- **Release checks.** Exercise checkout expiry, a missed grant handoff after payment commits, refund and dispute handling, and the exceptions support must resolve. Then repeat the purchase and renewal flows in Paystack Test Mode and compare the provider transaction, Store payment application, and customer access. The local test proves payment-to-grant behavior with fixtures. It does not establish NewYou storefront or renewal readiness.

### Approved checkout design

Start with one-time, signed-in ZAR checkout. Classify a product as digital-only explicitly in Catalog and retain that classification on the finalized order line. A download link alone describes access to an asset. A physical product can have the same link and still need shipping. Existing product rows keep their current classification. Consider inferring delivery from download links only if Catalog can rule out physical products with attached downloads.

For a cart containing only products explicitly classified as digital, collect the approved billing location and use Store's existing tax rules to calculate and record tax. Do not require a shipping quote, charge for shipping, reserve physical stock, or enqueue physical fulfillment. Physical and mixed carts keep the existing shipping path. Subscription checkout and renewal stay in the next Paystack milestone. The current subscription-only totals shortcut does not evaluate tax, so it is unsuitable as the digital-only pricing implementation. [Tax and shipping contract](../governance/tax_shipping.md) · [Checkout finalization](../../lib/store/checkout/domain.ex)

For the initial South African digital launch, use the buyer's billing country and region as NewYou's approved tax location inputs. Apply Store's existing tax contract to those inputs and retain the calculation evidence. This is a NewYou launch requirement and makes no claim about tax requirements in other markets.

Acceptance tests should prove that digital checkout can finalize without a shipping quote, missing or invalid required location blocks finalization, the order retains its tax evidence and has zero shipping, and physical and mixed carts still use shipping as required. Then exercise one hosted Paystack Test Mode purchase through the storefront and verify one payment application and one buyer-visible grant after replay. Keep the existing late-payment test as a separate launch gate.

Run the focused checkout, digital grant, refund-revocation, and webhook tests with DevCore TEST.

```bash
devcore-project run test -- mix test \
  test/store/payments/create_intent_for_order_test.exs \
  test/store/digital/facade_test.exs \
  test/store/payments/refunds_digital_revocation_test.exs \
  test/store_web/controllers/webhook_controller_test.exs
```

## NewYou CER checkout proof

The evidence below is for the Store sandbox checkout. NewYou's locked `DEC-292` selects Paystack for the initial South African ZAR release. The exact pressure-test scenarios come from NewYou's CER working pack and its archived v0.30.3 discovery. The provider invariants use the Paystack Pre-JIT contract v1.0.0. The working packs describe required proof and do not resolve `OQ-004` or certify NewYou as a whole. The NewYou checkout used for this review was at `846a92c9`. [JC-284](https://linear.app/jc-dev/issue/JC-284/newyou-launch-provider-gate-paystack-recurringpayment-adapter)

### Observed in Paystack Test Mode

- A signed-in synthetic buyer added a published digital product with zero physical stock, entered ZA and WC, and saw R20.00 plus R3.00 tax with zero shipping. A browser return with a fabricated success parameter rendered the read-only return page before any genuine payment.
- Paystack accepted the real storefront initialize request with its per-order callback and confirmed Test Mode transaction `6800241582`. Exact-reference verification returned success for R23.00 ZAR. Store processed the signed webhook, marked the order paid, and stored one payment application and one active grant for the buyer and the purchased asset. It recorded zero physical fulfillment orders and zero inventory holds. The buyer's Downloads page displayed the asset and Download action. Test storage uses the fake adapter.
- In the first run, hosted checkout remained on its transaction-status screen. Browser network requests to the Paystack completion host failed with `ERR_NETWORK_CHANGED`. After reload, hosted checkout showed the link as unavailable or already completed. Manually opening the configured return URL loaded the correct order in the same signed-in browser.
- On 2026-11-26, the tester confirmed that Paystack automatically redirected the browser after a fresh hosted Test Mode payment. The screenshot showed Store's read-only payment return for order `NGD8PNACE`, billing location `ZA` / `WC`, an R20.00 subtotal, R3.00 tax, and an R23.00 total. A read-only DevCore TEST query matched the order's durable reference to verified and processed `charge.success:6801181341`, in Test Mode for 2,300 ZAR minor units. Store recorded a paid order, one payment application, one active download grant for the buyer, zero shipping, zero physical fulfillment orders, and zero inventory holds. Store supplied the per-transaction callback. The Paystack dashboard fallback remained blank.
- Paystack returned HTTP `400`, `validation_error`, and `invalid_params` for the synthetic email ending in `.test`. Exact-reference verification reported no transaction. Using a synthetic `example.com` address let the same checkout reference initialize. The decoder retains the diagnostic code and excludes the raw provider message. [Response fixture](../../test/store/payments/providers/paystack_response_test.exs)

### Executable checkout cases

- **PAY-INV-005.** A forged browser return carrying a reference and `status=success` cannot start payment. An injected Pay event leaves the order pending and creates no payment intent. [LiveView test](../../test/store_web/live/cart_checkout_live_test.exs)
- **CER-PT-002 / PAY-INV-007.** Independent verification and webhook tasks compete to apply success for the same digital order. Both finish, and Store records one commercial payment application, one grant job, and one buyer grant. Replaying the webhook or grant job preserves the original grant. This test shares a DevCore TEST sandbox, so multi-connection or multi-node contention remains open. [Payment and grant test](../../test/store/payments/create_intent_for_order_test.exs)
- **CER-PT-003 / PAY-INV-004 and PAY-INV-009.** Simulated initialize timeout and conflicting amount evidence leave the original order unpaid. An earlier failure is unresolved. Valid success can then apply, and replaying the persisted earlier failure cannot reverse paid state or access. This covers checkout evidence ordering. Actual network timeout after Paystack accepts a write, missing webhook recovery without an operator action, and renewal finality remain open. [Payment and grant test](../../test/store/payments/create_intent_for_order_test.exs)
- **CER-PT-001 / PAY-INV-017.** An ordinary payment application and its Oban grant job now commit in the same database transaction. The regression first fails against the previous separate-connection handoff. The new implementation exposes both rows inside the transaction, rolls both back after an injected interruption, then retries the same evidence and commits one application and one grant job. In DevCore TEST, a separate VM used simulated Paystack responses, committed payment and the job, then stopped abruptly before grant execution. A fresh VM found the original job and one payment application. It ran and replayed the grant worker with one active grant and the same grant ID. Prolonged outage and escalation after grant retry exhaustion remain open.

The remaining CER gates include renewals (`CER-PT-004` through `008`, `015` through `018`), refunds and disputes (`009`, `010`), and a genuine second collection (`019`). Gift, EFT, membership composition, and protected fulfillment or access lifecycle cases (`011` through `014`, `020`) require the corresponding NewYou commercial flows. Do not count duplicate delivery as proof of handling two genuinely successful collections.

```bash
devcore-project run test -- mix test --seed 259775 \
  test/store/catalog/facade_public_product_test.exs \
  test/store_web/live/cart_checkout_live_test.exs \
  test/store/payments/create_intent_for_order_test.exs \
  test/store/payments/providers/paystack*test.exs \
  test/store_web/controllers/webhook_controller_test.exs
```

## Ten launch checks and remaining proof

1. **Automatic HTTPS callback. Verified.** Paystack returned the buyer to the read-only page for order `NGD8PNACE` after the fresh R23.00 Test Mode payment. Store persisted the verified webhook, one payment application, and one buyer grant. Sign-in, checkout, and return used the same HTTPS sandbox origin.
2. **Two tabs, double-click, and refresh.** LiveView tests reuse one hosted redirect after Store saves it. A controlled overlap before it is saved produces two requests with the same reference and one local intent. Verify double-click, independent tabs, offline, and refresh in a real hosted browser. Verify there is one provider transaction as well as one local application.
3. **Browser closes before return.** The R23.00 order was already paid and had a grant before Store's return route was opened. This proves the webhook can deliver independently of browser navigation. Intentionally close a fresh hosted checkout immediately after payment submission and verify the same result from a new session.
4. **Lost response and webhook gaps.** Controlled tests reconcile an ambiguous write by the original reference, then preserve paid state against replayed failure. Prove a real accepted write with a lost response and automated reconciliation after a missing delivery. A negative or missing lookup alone cannot authorize a fresh charge. [Checkout tests](../../test/store/payments/create_intent_for_order_test.exs)
5. **Interrupted download handoff.** Verified locally with a rolled-back payment transaction and an abrupt VM stop after commit. The restart found the original job and issued the grant once. The Paystack response was simulated. The exhaust-retry support case remains open.
6. **Verified success after checkout expiry.** The checkout regression still verifies that a cancelled order remains cancelled after provider success. Implement a durable resolution path that records verified money and routes the order for grant or refund review under the approved checkout policy. Prove both paths before rollout.
7. **Genuine excess collection.** NewYou `DEC-314` requires one make-whole obligation for the exact verified excess and at most one entitlement result. The webhook replay tests use the same provider transaction. Prove two verified transaction IDs for one accepted obligation and a separate intended second purchase, then verify that repeat evidence creates no second correction.
8. **First subscription payment and scheduled renewal.** The direct Paystack sandbox used a reusable authorization. Store's Paystack off-session adapter remains disabled. Prove authorization binding, scheduled collection, and one paid-period extension for each launch cadence through NewYou.
9. **Decline, replacement, and cancellation.** Generic Store tests cover renewal authority and races. Prove these with Paystack using the selected renewal mechanism under `OQ-004`, including exact-reference reconciliation before a new charge and access across the approved billing or grace boundary.
10. **Refunds and disputes after access.** Generic Store tests cover download revocation. The current Paystack Test restricted key received HTTP `403` on both refund and transaction-dispute reads for the sandbox purchase. No refund was submitted. Provider refund writes, verification, event replay, and dispute evidence still need a sandbox credential with the applicable scopes and adapter support. NewYou `DEC-300` and `DEC-314` govern which source of access may change and how to handle a monetary loss without proven component attribution. [Refund API](https://paystack.com/docs/api/refund/) · [Dispute API](https://paystack.com/docs/api/dispute/)

## Certification gaps and proposed Store changes

### OQ-004 capability status

The trial covers the one-time sandbox path and direct provider calls. NewYou's selection of Paystack for the first ZAR release is locked in `DEC-292`. The choice between Store-scheduled charges and Paystack-managed subscriptions remains open under `OQ-004`.

1. **Recurring mechanism.** Paystack exposes authorization charging and managed subscriptions. The sandbox demonstrated a direct authorization charge. Store keeps both recurring paths disabled pending the decision and lifecycle proof.
2. **Authorization acquisition and replacement.** The R10.00 hosted test payment returned reusable authorization. A direct charge with a different email failed. Store has yet to implement and verify original-email binding and safe replacement.
3. **Zero or small verification.** R10.00 paid authorization acquisition worked in ZAR Test Mode. Verify zero-value or lower-value setup and confirm the approved customer flow.
4. **References and retries.** Exact-reference lookup and sequential duplicate-reference rejection worked in Test Mode. Store simulated overlapping initialize attempts using one persisted reference. Real concurrent collection remains open.
5. **Decline, timeout, and authentication.** A real decline and bank-authentication cases supplied provider diagnostics. Fixtures cover ambiguous HTTP and transport responses. A real network interruption after acceptance and a recurring retry with authentication still need proof.
6. **Cancellation and finality.** Store treats failed, missing, or ambiguous evidence as unresolved. Verify which provider operations can neutralize a submitted charge and how long a later success is possible.
7. **Replacement while renewal is unresolved.** Prove how the existing renewal resolves when the customer replaces the card. The original reference and authorization evidence must remain traceable.
8. **Webhook verification and identity.** Dedicated test signing, canonical receipt redaction, signed checkout delivery, and dashboard replay were exercised. Recurring, refund, and dispute payloads remain outside the implemented checkout event scope.
9. **Missing, delayed, and reordered delivery.** Exact-reference reads and fixture-based reordering are covered. Exercise automatic recovery from a missing event or an initialize response lost before persistence.
10. **Failure followed by success.** Store's checkout fixture accepted later authoritative success after an unresolved failure and preserved it on replay. Prove renewal semantics and resolve success after checkout expiry.
11. **Monthly and annual billing.** Prove scheduling, boundary times, and one paid-period extension for each selected launch cadence.
12. **Upgrade and proration.** Prove the approved adjustment and commercial application under NewYou's upgrade policy.
13. **Refunds.** The transaction-only restricted key returned `403` on a refund read. Test scoped full and partial refund submissions, repeated requests, failure, retry, events, and access consequences.
14. **Disputes.** The same key returned `403` on a dispute read. Test scoped evidence, event ordering, resolution, and source-scoped access effects.
15. **Managed subscription lifecycle.** If selected, prove cancellation, disable, re-enable, card replacement, invoice behavior, and compatibility with NewYou's billing and future changes.
16. **Settlement and operator reconciliation.** Validate scoped settlement reads and correlate them with verified transaction and Store application identifiers.
17. **Test versus live.** The adapter accepts Test Mode credentials and observations. Live account enablement, signing, limits, and behavior require a separately approved verification run.
18. **South African channels and limits.** The Test Mode checkout exercised ZAR card payments. Confirm launch-account channels, limits, and the applicable permissions before any other method is enabled.

| Evidence still needed | Where it can change Store |
| --- | --- |
| Provider authorization acquisition and replacement, checkout abandonment, and zero or low-value ZAR card setup | Extend the sandbox checkout evidence to the approved card-acquisition flow and add the authorization email binding through the existing payment-method lifecycle. |
| Real timeout before and after provider acceptance, concurrent duplicate requests, initial absence followed by success, contention on payment method replacement, and whether an accepted charge can be cancelled | Test recovery from the same durable collection using exact-reference observation. Establish which outcomes allow release or a new attempt before enabling off-session collection. |
| Delayed or missing payment events and replay during recurring collection | Extend the verified one-time dashboard replay case to delayed and missing events. Exercise exact-reference recovery and replay when recurring collection is implemented. |
| Evidence for Store-scheduled authorization charging versus Paystack-managed subscriptions | Select the approach under OQ-004. Compare monthly and annual billing, cancellation, future contract and price changes, proration or immediate upgrades, promotions, add-ons, payment-method replacement, and recovery. If managed billing is considered, test enable, disable, card update, and invoice events against those same requirements. [Managed subscriptions](https://paystack.com/docs/v2/payments/recurring/subscriptions) |
| Full and partial refund processing, repeated requests, failure and needs-attention handling, dispute events, operator reconciliation, and settlement evidence | Use existing refund and dispute boundaries where they cover the observed behavior. Add only the provider mapping or missing domain behavior supported by a failing test and approved policy. Capture test/live differences, channel availability, account limits and operational recovery as separate evidence. |
| Store end-to-end ZAR purchase → verified payment → reusable authorization → renewal → webhook or reconciliation → entitlement effect | Add sanitized adapter fixtures and domain tests. Fault-inject delayed and out-of-order events, restarts, worker crashes, and concurrent operations. Run relevant Store tests in DevCore TEST and required CI before enabling Paystack. |

Resolve one-time checkout expiry and late-payment handling before enabling the storefront path. Saved-card renewal also requires the approved OQ-004 approach, including how Store acquires and links the reusable authorization and its original email.

### Performance & Scaling Review

The sandbox path reuses the existing checkout and payment-application queries and the indexed immutable provider reference. A cold initialize attempt sends one POST outside Store's database transaction. Overlapping requests can repeat that POST with the same reference. Webhook ingress verifies the body in memory and writes a receipt and a unique Oban job. The existing worker performs one Paystack GET on an unprocessed checkout receipt and reuses the evidence and outcome interlocks. Verified recovery of a `created` Paystack checkout uses the existing order and intent locks and the indexed payment-application key. It adds no outbound call or extra state update to payment application. Paystack response telemetry carries the operation, outcome, and allowlisted diagnostic codes. Sandbox latency and throughput are unmeasured.

The storefront gateway selection reads application configuration at LiveView mount and again on Pay. Selection adds no database query, cache, or background job. The existing payment call still checks the enabled-provider gate.

Ordinary payment application inserts the existing unique digital grant job using the same Store.Repo transaction as the order and payment transition. This moves the existing job write and its Oban uniqueness check inside the order lock. It starts no new background process or outbound provider call. Post-change lock duration and throughput are unmeasured.

Digital finalization commits the billing tax and priced line snapshot inside the existing checkout lock transaction. It performs one batched tax-rate read and skips shipping and inventory queries for the digital-only path. Mixed fulfillment filters the indexed order line lookup by the stored delivery flag. The cart availability cache still batches misses by variant ID with the existing TTL. Its database query now joins product and inventory to distinguish digital stock from physical stock.

### Runtime Resource Safety Review

Initialization reuses the bounded provider task and shared HTTP client. Each explicit verification makes a bounded read with retries disabled. The decoder retains allowlisted diagnostics. Runtime allocation, garbage collection, and convergence under repeated load are unmeasured.

Storefront selection adds one provider atom or `nil` to the socket. It opens no connection and starts no process.

Digital finalization starts no outbound call or process. The new location and tax data contain two codes, a timestamp, and one tax result per order line. The existing paid-order worker handles digital grant replay. Runtime allocation and post-load convergence remain unmeasured.

### PR validation record

The focused DevCore TEST run exercised the staged source without the unrelated membership writer changes. It passed 249 tests with seed `259775`.

```bash
devcore-project run test -- mix test --seed 259775 \
  test/store/catalog/facade_public_product_test.exs \
  test/store/checkout/domain_test.exs test/store/digital/facade_test.exs \
  test/store/payments/{create_intent_for_order,provider_fault_isolation,refunds_digital_revocation}_test.exs \
  test/store/payments/providers/paystack*test.exs \
  test/store/workers/{process_webhook_receipt,expire_pending_provider_setup_orders,expire_inventory_reservations}_worker_test.exs \
  test/store_web/controllers/{webhook,payment_callback}_controller_test.exs \
  test/store_web/live/{admin_live,cart_checkout_live}_test.exs \
  test/store/orders/pending_provider_setup_backlog_test.exs
```

- `mix format --check-formatted` and `mix ash_postgres.generate_migrations --check` passed. `mix check.static` exited `1`. It reported dependency advisories against the existing lockfile and documentation warnings. The boundary checks passed and Credo reported no issues.
- Hallmark's `sloplint.mjs --url http://127.0.0.1:4010/checkout --scope app --tier floor` rendered the missing-checkout-key page and reported seven failures for focus contrast, text contrast, and horizontal overflow. Direct lint on the two LiveView `.ex` files returned an unsupported-file error. An authenticated render of the digital billing and admin product forms, plus a baseline comparison, still needs to run. Hallmark verification remains open.
- A synthetic buyer authenticated over the HTTPS tunnel and reached the protected Downloads page. No login details or checkout tokens are part of the repository evidence.
