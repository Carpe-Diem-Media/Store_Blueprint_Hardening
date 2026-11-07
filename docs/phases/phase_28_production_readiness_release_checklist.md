# Phase 28 — Production Readiness & Release Checklist (Single‑Tenant Store)

## Outcome
Ship a **working, enterprise‑grade** single‑tenant ecommerce site (physical + digital + subscriptions) with:
- predictable runtime configuration
- safe secrets handling
- hardened webhook + outbound integrations
- observability and operational runbooks
- backup/restore confidence
- repeatable go‑live / rollback procedure

This phase is not “more features”. It is the **go‑to‑production contract** for the blueprint.

---

## Scope
### In-scope
- Runtime configuration finalization (`runtime.exs` + env vars)
- Secrets handling rules (no secrets in repo)
- Payment gateway production hardening (webhooks, idempotency, replay)
- Email delivery production hardening (outbox, rate, retries)
- Object storage hardening for digital products (signed URLs)
- Logging + metrics + tracing hooks
- Error reporting + alerting + dashboards
- Backups + restore drills + DR notes
- Security hardening (headers, session/cookie, CSP posture, admin step‑up)
- Performance posture (cache layers, DB indexes verification, rate limiting)
- Operational runbooks (support, incident flow, reconciliation)

### Out of scope (explicitly)
- Multi‑tenant / marketplace capability
- Advanced proration, complex subscription upgrades/downgrades
- Full WMS/ERP integration
- Custom shipping carrier integrations beyond the deterministic rules engine baseline

---

## Preconditions (must be true before Phase 28)
- Phases 00–14 complete and passing `mix check` gates.
- Phase 19 (Catalog), Phase 20 (Cart), Phase 21 (Checkout), Phase 22 (Fulfillment),
  Phase 23 (Comms), Phase 24 (Digital), Phase 26–27 (Subscriptions) implemented to MVP scope.
- Governance docs are consistent (no contradictory webhook rules).
- All outbound IO is routed through wrappers/workers (no web IO).

---

## Runtime Configuration Contract

### Rule: production config must be environment-driven
- All secrets and provider keys must be **ENV-only** (or secret manager), loaded in `runtime.exs`.
- `config/prod.exs` must not contain credentials.
- `dev.exs` may use sandbox keys, but must never share the same credentials as prod.

### Required config categories (minimum)
1. **Database**
   - `DATABASE_URL`
   - optional `ECTO_IPV6`
   - `POOL_SIZE`
   - `STORE_DB_POOL_MODE` (`session` or `transaction`)
   - `POOL_SIZE` must be at least 3. Subscription workers default to `min(4, POOL_SIZE - 2)` per node, reserving at least two primary Repo connections.
   - Optional `STORE_SUBSCRIPTIONS_QUEUE_LIMIT` must be a positive integer no greater than `POOL_SIZE - 2`.
   - New renewal POSTs require declared session mode and a direct PostgreSQL or session-pooled endpoint. Transaction mode keeps `prepare: :unnamed` and rejects fresh renewal POSTs.
2. **Phoenix**
   - `SECRET_KEY_BASE`
   - `PHX_SERVER`
   - `PHX_HOST`
   - `PORT`
3. **Ash**
   - test-only: `config :ash, :missed_notifications, :raise`
4. **Payments**
   - `STORE_PAYMENTS_ENABLED_PROVIDERS` (baseline production truth: keep non-Stripe providers disabled until direct adapter+webhook proof exists)
   - optional `STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI` (UI hint only)
   - Stripe-required when enabled: `STORE_STRIPE_WEBHOOK_SECRET`, `STORE_STRIPE_SECRET_KEY`, `STORE_STRIPE_PUBLISHABLE_KEY`
5. **Email**
   - `STORE_COMMS_PROVIDER` (`swoosh` or `req_postmark`)
   - provider API key(s) (for `req_postmark`, require Postmark token)
6. **Digital storage**
   - `STORE_DIGITAL_STORAGE_PROVIDER`
   - bucket, region, access keys
   - signed URL TTL defaults
7. **Observability**
   - `SENTRY_DSN`
   - `STORE_LOG_LEVEL`, `STORE_LOG_FORMAT`
   - `STORE_CSP_MODE`, `STORE_CSP_POLICY`, `STORE_CSP_REPORT_URI`

---

## Production Hardening Requirements

### A) Webhooks (payments + refunds)
**Invariant:** webhooks are the system of record for payment status.
- Controller MUST:
  - verify signature with raw body + headers
  - reject invalid/missing signatures
  - enqueue exactly one worker per receipt
- Worker MUST:
  - assert verification status
  - apply interlocks idempotently
  - never double-apply order transitions

**Operational requirement**
- Log receipt IDs and provider event IDs for reconciliation.
- Add rate limiting at edge (reverse proxy / Cloudflare) on webhook endpoints.

### B) Email delivery
**Invariant:** outbound email is *auditable and idempotent*.
- All emails route through EmailOutbox + Oban worker.
- Uniqueness keys prevent duplicates on retries/replays.
- Failures do not mutate order/payment state.

**Operational requirement**
- Dashboard: “emails pending/failed last 15m/24h”.
- Alerting threshold: sustained failures.

### C) Digital downloads
**Invariant:** access is grant-gated and revocable.
- Signed URLs only, short TTL.
- DownloadGrant is authoritative.
- Refund policies define revoke rules.

### D) Subscriptions
**Invariant:** renewals are scheduled, not user-triggered.
- Renewal worker owns the process.
- Idempotency per period via `renewal_key`.
- Cancellation boundaries enforced.

---

## Security Checklist (minimum)

### App security
- Secure cookies in prod: `secure: true`, `same_site: "Lax"` or stricter.
- Force HTTPS (HSTS at proxy + app awareness).
- CSP posture (start in report-only if needed; then enforce).
- CSRF enabled for browser surfaces.
- Admin “step-up” enforced for destructive operations (refund, cancellations, fulfillment).

### Data security
- Do not log secrets, raw payment tokens, or full address lines in error logs.
- Encrypt at rest (DB + backups).
- Ensure least privilege DB user.

### Dependency hygiene
- `mix deps.audit` (or equivalent) in CI.
- lockfile committed and reviewed.

---

## Performance & Scaling Checklist (single-tenant, enterprise posture)

### DB
- Verify all indexes required by:
  - Orders lookups (order_ref, user_id)
  - Payment intent lookup (provider_event_id, idempotency keys)
  - Cart lookup (cart_token)
  - Download grants (order_line_item_id, asset_id)
  - Subscription renewal keys
- Confirm no N+1 relationship loads in storefront and admin grids.

### Caching posture (baseline)
- Hot: ETS/Cachex for shipping rules, tax tables, and frequently-read catalog lists
- Warm: Redis optional (if deployed) for rate limits and ephemeral counters
- Cold: Postgres is durable source, not the “every request read path” for high-velocity pages

### Release performance budgets
- Target: sub-100ms for typical read endpoints (excluding external IO)
- Checkout p99 target: sub-5s (provider redirect included)

---

## Observability & Ops

### Logs
- Structured logs (JSON recommended in prod).
- Correlation IDs for:
  - checkout initiation
  - payment intent
  - webhook receipt
  - email outbox send
  - fulfillment transitions

### Metrics
Minimum counters/gauges:
- webhook receipts per minute + failures
- payment interlock applications + replays
- email outbox pending/failed
- digital grant issuance/revocation
- subscription renewals attempted/succeeded/failed

### Alerts (minimum)
- Webhook signature failures spike
- Email failure rate above threshold
- Renewal failures sustained
- DB connection pool saturation

---

## Backup / Restore / DR

### Backup requirements
- Daily full DB backup (minimum), with retention policy.
- Store encryption keys securely.
- If using object storage for digital assets: ensure bucket versioning or lifecycle policies.

### Restore drill (must be documented and rehearsed)
- Restore into staging
- Run:
  - `mix check`
  - smoke tests (checkout → pay → email)
- Validate key invariants:
  - order snapshots intact
  - refund caps enforceable
  - download grants consistent

---

## Go‑Live Checklist (do not skip)

### Pre-flight (day before)
- Sandbox → prod key cutover plan written
- Webhook endpoint configured in provider dashboard
- DNS / TLS verified
- Rate limits and WAF rules enabled for:
  - auth endpoints
  - webhook endpoints
  - admin endpoints
- Admin step-up tested

### Launch (day of)
1. Deploy release artifact
2. Run migrations
3. Smoke tests:
   - register/login
   - browse product
   - add to cart
   - checkout
   - complete payment (real or test mode)
   - confirm order paid
   - confirm receipt email sent
   - for digital: confirm grant + signed URL works
4. Monitor dashboards 60 minutes

### Rollback plan
- If deployment must rollback:
  - do not “undo” payments in app
  - rollback code, keep DB migrations forward-safe
  - reconcile paid orders via provider dashboard + webhook replays

---

## Acceptance Criteria
- A new operator can follow the doc and safely launch the store.
- Payment webhooks are verified and replay-safe under retries.
- Emails are auditable, idempotent, and do not cause retry loops.
- Digital download access is grant-based with revocation behavior defined.
- Subscriptions renew via scheduled workers with idempotency.
- Backups exist and restore drill steps are documented and succeed.

---

## Governance Impact
This phase introduces **operational laws**, but does not require governance doc edits *if*:
- webhook verification rules are already codified,
- outbound IO quarantine is enforced,
- idempotency and uniqueness constraints exist for outbox/grants/renewals.

If any of those are not already encoded as gates/tests, schedule a governance update before declaring “enterprise complete”.
