# Payment Provider Readiness

Last updated: 2026-05-07  
Scope: Phase 2C payment readiness reconciliation for stabilization.

## Purpose

This document is the operational truth for payment provider readiness. It separates business-flow capability from provider integration depth so provider enablement cannot be misinterpreted.

## Evidence-based readiness matrix

| Provider | API intent + off-session charge | Webhook signature verification | Canonical webhook normalization | Production readiness |
| --- | --- | --- | --- | --- |
| Stripe | Implemented | Implemented | Implemented | Implemented |
| PayFast | Scaffold only | Scaffold only | Scaffold only | Not production-ready |
| Paystack | One-time ZAR card checkout and exact-reference verification in Test Mode. Off-session charging disabled. | Dedicated Test Mode signing secret and timestamped HMAC | Signed `charge.success` for one-time checkout | Sandbox only. See the [Paystack integration reference](paystack-integration.md). |
| Yoco | Scaffold only | Scaffold only | Scaffold only | Not production-ready |
| Peach Payments | Scaffold only | Scaffold only | Scaffold only | Not production-ready |

Readiness interpretation:

- "Implemented" means direct code evidence exists for provider adapter behavior and webhook contract depth.
- "Scaffold only" means provider alias/config/capability declarations exist, but core adapter contract paths are not implemented end-to-end.

## Enablement guardrails

- `STORE_PAYMENTS_ENABLED_PROVIDERS` must include only providers that are implementation-complete.
- In the current baseline, production-safe enablement is Stripe-only unless direct code proof changes this matrix.
- Do not treat provider return/cancel URLs as proof of payment.
- Never treat query params as payment confirmation.

## Boundary constraints from AGENTS.md

- Provider modules may build payloads, verify signatures, and normalize payloads to canonical receipts.
- Provider modules must not perform `Repo.*`, `Ash.*`, Oban enqueue, or business-rule state transitions.
- Webhook controllers are receipt ingress only: verify signature, normalize, persist receipt optionally, enqueue exactly one job.
- Payment state transitions happen in workers/domain facades, not in controllers.

## Open gaps and safest implementation order

1. Implement one non-Stripe provider end-to-end behind the existing contract surface:
   - `create_intent`
   - `charge_off_session`
   - `verify_webhook`
   - `normalize_webhook`
2. Add adapter-level tests that prove webhook verification and normalization are complete before provider enablement.
3. Add operational docs for provider-specific secret requirements and rollout constraints after implementation evidence exists.
4. Enable provider in runtime configuration only after steps 1-3 are complete.

## Risk ranking

- High: accidental enablement of scaffold-only providers in `STORE_PAYMENTS_ENABLED_PROVIDERS`.
- Medium: docs that conflate subscription business capability with provider integration readiness.
- Medium: missing provider-by-provider evidence checklist for go-live decisions.
- Low: wording drift across docs when this file is not used as citation source.

## Evidence consulted

- `AGENTS.md`
- `docs/stabilization/source-of-truth.md`
- `docs/agent_notes/subscription_payments_evaluation.md`
- `docs/stabilization-pass.md`
