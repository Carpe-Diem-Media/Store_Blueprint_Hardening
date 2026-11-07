# Governance: Error Codes (Authoritative)
This document pins stable, registry-backed error codes referenced across governance docs.

## Rules (MUST)
1) All error codes MUST be **SCREAMING_SNAKE_CASE**.
2) Every error code returned from policies/validations/actions/webhook idempotency MUST exist in `Store.Support.Errors.ErrorCodes`.
3) Semantics MUST be stable. If meaning changes, introduce a NEW code.

## Canonical auth/error semantics (MUST)
- UNAUTHORIZED: actor missing / not signed in
- FORBIDDEN: actor present, but not allowed by policy
- NOT_FOUND: requested resource not found
- STEP_UP_REQUIRED: sensitive op without recent step-up
- INVALID_STATE_TRANSITION: forbidden lifecycle transition
- STALE_RECORD: optimistic lock failure / concurrent write
- WEBHOOK_DUPLICATE: duplicate receipt/event detected (often NOOP)
- VALIDATION_ERROR: generic validation failure when no more specific code fits
- INVALID_BILLING_TIMEZONE: runtime period calculation cannot resolve the commercial billing timezone
- INTERNAL_ERROR: unexpected internal failure (non-leaky, used as a safe fallback)

## Ecommerce correctness codes (MUST)
Pricing/discounts:
- INVALID_COUPON: coupon invalid/expired/ineligible

Checkout replay safety:
- CHECKOUT_DUPLICATE: duplicate begin_checkout detected (returns existing order)
- PAYMENT_INTENT_DUPLICATE: duplicate payment intent creation (returns existing intent)
- PAYMENT_ALREADY_SUCCEEDED: attempting to create/attach payment after success

Inventory/reservations:
- OUT_OF_STOCK: insufficient available inventory
- INVENTORY_ADMISSION_BUSY: Admission coordination made a definitive backpressure decision because an admission, queue, or budget bound prevents progress. No durable reservation attempt is implied; this is not OUT_OF_STOCK.
- INVENTORY_ADMISSION_UNAVAILABLE: Admission coordination cannot safely determine or perform the requested operation because Redis or required evidence is unavailable, contradictory, or uncertain. Fail closed; do not bypass admission into PostgreSQL. This is not a durable reservation result.
- INVENTORY_ADMISSION_UNSUPPORTED: The enforced admission boundary rejects this mutation path before durable mutation, including paths marked ENFORCED_UNAVAILABLE.
- RESERVATION_CONFLICT: concurrency conflict creating reservation

Refunds:
- REFUND_NOT_ALLOWED: wrong order/payment state
- REFUND_EXCEEDS_REFUNDABLE: refund amount exceeds refundable amount
- REFUND_DUPLICATE: duplicate refund request (returns existing refund / NOOP)
- IDEMPOTENCY_KEY_REUSE_MISMATCH: same idempotency key used with different refund payload/fingerprint
- CURRENCY_MISMATCH: refund currency does not match payment intent currency
- PAYMENT_PROVIDER_REFUND_FAILED: provider refund failed/declined

Tax/shipping:
- INVALID_ADDRESS: missing/invalid destination fields
- SHIPPING_RATE_NOT_FOUND: no eligible shipping rate
- TAX_RATE_NOT_FOUND: tax enabled but no applicable rate

## Baseline domain codes (recommended)
Orders:
- ORDER_NOT_FOUND
- ORDER_NOT_OWNED

Payments:
- PAYMENT_PROVIDER_VERIFICATION_FAILED
- PAYMENT_SIGNATURE_MISSING
- PAYMENT_SIGNATURE_INVALID
- PAYMENT_PAYLOAD_INVALID
- PAYMENT_EVENT_DUPLICATE
- PAYMENT_PROVIDER_DOWN
- PAYMENT_PROVIDER_TIMEOUT
- PAYMENT_PROCESSING_FAILED
- PAYMENT_EVENT_UNVERIFIED
- PAYMENT_OUTCOME_UNRESOLVED
- PAYMENT_PROVIDER_DISABLED
- PAYMENT_FAILED
- PAYMENT_METHOD_REQUIRED
- PAYMENT_PROVIDER_SELECTION_REQUIRED
- PAYMENT_PROVIDER_UNSUPPORTED
- PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED
- RATE_LIMITED

Catalog/Content:
- SLUG_TAKEN
- SKU_TAKEN
- VARIANT_IN_USE

Digital fulfillment:
- DIGITAL_GRANT_NOT_FOUND
- DIGITAL_GRANT_DENIED
- DIGITAL_GRANT_EXPIRED
- DIGITAL_GRANT_REVOKED
- DIGITAL_REDIRECT_UNSAFE
- DIGITAL_DOWNLOAD_RATE_LIMITED

Subscriptions:
- SUBSCRIPTION_NOT_FOUND
- SUBSCRIPTION_DUPLICATE
- SUBSCRIPTION_RENEWAL_DUPLICATE
- SUBSCRIPTION_MISSING_BILLING_REFERENCE
- SUBSCRIPTION_PLAN_NOT_FOUND
- SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED
- SUBSCRIPTION_PROVIDER_UNSUPPORTED
- SUBSCRIPTION_PROVIDER_MODE_DISABLED
- SUBSCRIPTION_BILLING_MODE_UNSUPPORTED
- SUBSCRIPTION_PURCHASE_DISABLED
- RENEWAL_AUTHORITY_WITHDRAWN: cancellation withdrew an unresolved subscription renewal occurrence before its exact Commerce payment application.
- RENEWAL_DISPATCH_UNAVAILABLE: fresh off-session renewal dispatch lacks the required provider-side revocation fence. This infrastructure error does not advance business dunning. Safe `cleanup_failure` or `preflight_failure` metadata distinguishes a failure while checking or releasing an older unsubmitted collection.
- VARIANT_PLAN_UNAVAILABLE
- SHIPPING_PROVIDER_DOWN
- SHIPPING_UNAVAILABLE
- SHIPPING_PROFILE_MISSING
- SHIPPING_COST_SURGE
- PAYMENT_METHOD_UPDATE_UNSUPPORTED
- PAYMENT_AUTHENTICATION_REQUIRED
- TARGET_ORDER_BLOCKED: historical AccessEffect reconciliation could not safely establish the current subscription target.
- TARGET_ORDER_UNPROVABLE: current subscription target evidence is incomplete or contradictory, so reconciliation fails closed.
- TARGET_ORDER_UNSUPPORTED_STATE: subscription lifecycle state requires renewed authority review before target-order reconciliation.

Entitlements:
- ENTITLEMENT_NOT_FOUND
- ENTITLEMENT_DUPLICATE

## Drift protocol (MUST)
1) Update registry first.
2) Update tests.
3) Only then use the code.

## Test gates (MUST)
- Registry uniqueness test (no duplicates)
- Core codes exist test (all codes in this document)
