# NewYou digital checkout implementation plan

**Goal** — Prove a signed-in NewYou buyer can purchase a one-time digital product in ZAR through Paystack Test Mode and receive exactly one download grant without a shipping quote.

**Architecture** — Catalog declares how products are fulfilled. Checkout freezes that classification and calculates the order total. Payments verifies the exact Paystack reference, and the existing digital worker delivers the grant.

**Stack** — Phoenix LiveView, Ash, PostgreSQL, Oban, and Paystack hosted checkout.

[Approved checkout design and sandbox evidence](../../payments/paystack-integration.md#approved-checkout-design) · [JC-284](https://linear.app/jc-dev/issue/JC-284/newyou-launch-provider-gate-paystack-recurringpayment-adapter)

## 1. Freeze digital delivery on the order

Files to inspect and extend include `lib/store/catalog/types/product_kind.ex`, `lib/store/catalog/product.ex`, `lib/store/orders/order_line_item.ex`, `lib/store/checkout/domain.ex`, and the affected Ash snapshots and migrations.

- [x] Add an explicit digital product classification and carry it into finalized order-line evidence. Historical order lines retain their physical fulfillment behavior. Use the recorded delivery flag for reservations and fulfillment, and the existing grant worker for downloads.
- [x] Verify a product with an attached download still requires shipping if its catalog type is physical. Verify a mixed order reserves and fulfills only its physical line.
- [x] Verify in the checkout domain that changing a product to physical after finalization leaves the order's digital delivery evidence unchanged.

## 2. Calculate digital totals with approved location evidence

The approved NewYou inputs for the initial South African digital launch are the buyer's billing country and region. Use Store's tax contract to calculate and record the tax evidence.

Files to inspect and extend include `lib/store/checkout/domain.ex`, `lib/store/pricing/tax_shipping_evaluator.ex`, `lib/store/pricing/tax_shipping_contract.ex`, `lib/store/orders/tax_shipping_snapshot_writer.ex`, and `test/store/checkout/domain_test.exs`.

- [x] Finalize an all-digital cart using its billing location without a shipping quote. Reject missing location or an unavailable tax rate. Verify retry keeps the same order line and total.
- [x] Keep the current tax rate selection and rounding. Record billing location, tax rate, and tax amount. Skip shipping only where no physical delivery applies.
- [x] Verify physical and mixed carts preserve the shipping quote requirement.
- [x] Verify in the checkout domain that changing the tax rate after finalization leaves the order's recorded rate and total unchanged.

## 3. Verify storefront payment and access in Test Mode

The DEV sandbox flag configures Paystack as the default purchase provider. The storefront Pay button uses the server's selected gateway when it is enabled.

Files to inspect include `lib/store/payments/providers.ex`, `lib/store_web/live/checkout_live/placeholder.ex`, `test/store_web/live/cart_checkout_live_test.exs`, and `test/store/payments/create_intent_for_order_test.exs`.

- [x] Add LiveView tests proving Paystack configuration reaches the initialize adapter, two tabs reuse the saved redirect, Stripe configuration still works, and an unavailable default cannot start payment.
- [x] Complete a digital purchase through hosted Paystack Test Mode. Exact-reference verification matched the R23.00 ZAR payment. The signed webhook applied one payment and issued one grant. The buyer saw the asset on the Downloads page. The other-account isolation check ran with provider response fixtures.
- [x] Resend a signed webhook for a separate paid sandbox order from the Paystack dashboard. Store kept the original receipt, worker job, and single payment application.
- [x] Prove automatic HTTPS return with a fresh payment. The tester confirmed that Paystack redirected back to order `NGD8PNACE`. Store matched the verified webhook and recorded one payment application and one buyer grant.
- [ ] Repeat checkout in two real browser tabs, with a rapid second click, connection loss, and a refresh. The LiveView and provider fixtures cover relevant Store paths. [Ten launch checks and remaining proof](../../payments/paystack-integration.md#ten-launch-checks-and-remaining-proof)

Keep the late-payment-after-expiry case open until Store has an approved handling path for the verified payment. Subscription authorization, renewal scheduling, and paid-through access belong to the next Paystack slice. The one-time checkout proof does not certify either flow.
