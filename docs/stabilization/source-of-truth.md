# Stabilization Source of Truth

Last updated: 2026-05-07  
Scope: Phase 1 baseline for parallel stabilization workstreams.

## Purpose

This document is the factual baseline for all stabilization agents. It is derived from repository files listed in `docs/stabilization-pass.md` Phase 1 inputs and should be cited to avoid contradictory claims.

## Stack and architecture facts

- App/OTP: `Store` (`:store`).
- Primary stack: Elixir + Phoenix + LiveView + Alpine.js + Tailwind.
- Domain framework: Ash 3.x (`ash ~> 3.0`, `ash_postgres ~> 2.0`, `ash_json_api ~> 1.5`).
- API policy: JSON:API only (`ash_json_api`), no GraphQL path enabled by policy.
- Single-tenant policy from `AGENTS.md`: no `tenant_id`, no tenant routing, no marketplace semantics.
- Money and IDs policy from `AGENTS.md`:
  - money must be integer minor units + currency (no float money)
  - primary IDs are UUIDv7
  - binary UUID sort law applies for ordering/hash/tie-break behavior

## Domain map (configured Ash domains)

Configured in `config/config.exs`:

- `Store.Accounts`
- `Store.Admin`
- `Store.Catalog`
- `Store.Carts`
- `Store.Comms`
- `Store.Digital`
- `Store.Checkout`
- `Store.Orders`
- `Store.Payments`
- `Store.Subscriptions`
- `Store.Entitlements`
- `Store.Fulfillment`
- `Store.Shipping`
- `Store.Pricing`
- `Store.Tools`

## README status

`README.md` is still Phoenix boilerplate (default setup/start instructions, no project-specific operating contract).  
Treat README as a downstream integration artifact, not a current source of truth.

## Runtime environment contract (production)

Based on `config/runtime.exs`:

- App startup/runtime:
  - `PHX_SERVER`, `PORT`, `PHX_HOST`, `SECRET_KEY_BASE`
- Security/identity:
  - `STORE_TOKEN_SIGNING_SECRET`
  - Google OAuth: `STORE_GOOGLE_CLIENT_ID`, `STORE_GOOGLE_CLIENT_SECRET`, `STORE_GOOGLE_REDIRECT_URI_BASE`
  - Sentry: `SENTRY_DSN`
  - Logging/CSP controls: `STORE_LOG_LEVEL`, `STORE_LOG_FORMAT`, `STORE_CSP_MODE`, `STORE_CSP_POLICY`, `STORE_CSP_REPORT_URI`
- Database:
  - `DATABASE_URL`, optional `ECTO_IPV6`, `POOL_SIZE`
  - `STORE_DB_POOL_MODE` supports `session` or `transaction`
  - `POOL_SIZE` must be at least 3, leaving at least two primary Repo connections outside subscription workers
  - In `transaction` mode, `Store.Repo` uses `prepare: :unnamed`; the renewal facade rejects fresh renewal POSTs unless the declared mode is `session`
  - `session` mode requires a direct PostgreSQL endpoint or a session-pooled endpoint; the declared mode does not detect an undeclared proxy topology
  - `STORE_SUBSCRIPTIONS_QUEUE_LIMIT` optionally overrides the automatic subscriptions queue limit and must be a positive integer no greater than `POOL_SIZE - 2`
- Payments:
  - enabled providers from `STORE_PAYMENTS_ENABLED_PROVIDERS`
  - optional UI default from `STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI`
  - Stripe secrets required if Stripe enabled:
    - `STORE_STRIPE_WEBHOOK_SECRET`
    - `STORE_STRIPE_SECRET_KEY`
    - `STORE_STRIPE_PUBLISHABLE_KEY`
  - payment timeout/pool envs are validated as positive integers
- Comms:
  - `STORE_COMMS_PROVIDER` (`swoosh` / `req_postmark`)
  - Postmark token required if `req_postmark`
- Digital storage:
  - `STORE_DIGITAL_STORAGE_PROVIDER` (`s3` / `fake`)
  - S3 credentials required when provider is `s3`
- Rate limit backend:
  - `STORE_RATE_LIMIT_BACKEND` (`ets` / `redis`)
  - Redis config envs: host/port/db/username/password/ssl + key prefix

## Docker and release model

Based on `Dockerfile`:

- Multi-stage image:
  - build stage: `elixir:1.19.5-otp-28`
  - runtime stage: `debian:bookworm-slim`
- Build pipeline includes:
  - dependency fetch/compile
  - assets build (`mix assets.deploy`)
  - `mix release`
- Runtime container:
  - non-root `appuser`
  - exposes `4000`
  - starts with `bin/store start`
- `.tool-versions` aligns to:
  - Erlang `28.3`
  - Elixir `1.19.5-otp-28`

## Admin route protection evidence (current)

Based on `lib/store_web/router.ex` + `lib/store_web/live_user_auth.ex`:

- `/admin` scope uses browser + admin rate limit pipeline.
- Admin LiveViews run inside `ash_authentication_live_session` with `on_mount: [{StoreWeb.LiveUserAuth, :live_user_required}]`.
- `live_user_required` redirects unauthenticated users to `/sign-in`.
- Phase 2D audit confirms router/on_mount here is authentication-only and must be paired with role checks for admin depth.
- Phase 2D minimal fix added explicit role gates to `StoreWeb.Admin.Subscriptions.IndexLive` and `StoreWeb.Admin.Subscriptions.ShowLive` mount paths.

Current evidence level:

- Router-level auth mount exists and is explicit.
- Role-depth evidence now includes per-LiveView mount role gates plus domain policy backstops for subscriptions admin routes.
- Remaining audit depth should continue to verify per-surface role intent consistency (`admin` vs `support`) across all `/admin/**` LiveViews.

## Payment provider status (implementation baseline)

From `docs/agent_notes/subscription_payments_evaluation.md`, `docs/payments/provider-readiness.md`, and runtime config:

- Stripe: implemented end-to-end for adapter API calls plus webhook verification and canonical normalization.
- PayFast / Paystack / Yoco / Peach Payments:
  - present in provider alias/config scaffolding
  - scaffold-only unless direct code evidence proves full adapter and webhook contract implementation

Working baseline rules for all agents:

- Treat Stripe as implemented.
- Treat non-Stripe providers as scaffold-only until direct code evidence proves otherwise.
- Do not enable scaffold-only providers in production via `STORE_PAYMENTS_ENABLED_PROVIDERS`.
- Keep payment/webhook boundaries from `AGENTS.md`: webhook controllers are ingress-only and domain state transitions happen in workers/domain facades.

## CI / quality gates baseline

From `mix.exs` aliases:

- `mix check` includes:
  - formatting, compile warnings as errors, deps audit, tests, credo, docs
  - web boundary gates:
    - `check.web_no_http`
    - `check.web_no_oban_enqueue`
    - `check.web_no_ash_query`
    - `check.web_no_direct_ash_calls`
    - `check.no_repo_in_web`
  - governance gates:
    - `check.no_ash_graphql_dep`
    - `check.api_v1_forward_only`
    - docs/surface checks
- `mix check.types` runs dialyzer.

## Performance and scaling baseline assumptions (no runtime changes in Phase 1)

Hot paths (from `AGENTS.md`): storefront reads, cart, checkout, webhooks, outbox/email, digital downloads, renewals.

Current architecture assumptions for later performance review:

- Hot:
  - checkout/payment/provider boundary
  - webhook ingest + worker processing
  - subscription renewal workers
- Warm:
  - admin dashboards/indexes
  - fulfillment/email outbox operations
- Cold:
  - docs and one-off tooling flows

Mechanisms present in code/config:

- Redis and ETS:
  - rate limiting backend can be ETS or Redis (`STORE_RATE_LIMIT_BACKEND`)
  - Redis-backed key prefix and connection config exist
- Cachex:
  - dependency present (`cachex ~> 4.1`)
- Oban:
  - multiple queues configured (`webhooks`, `inventory`, `refunds`, `comms`, `fulfillment`, `digital`, `subscriptions`, `ops`)
  - subscriptions defaults to 4 in ordinary config; production derives `min(4, POOL_SIZE - 2)` per node unless `STORE_SUBSCRIPTIONS_QUEUE_LIMIT` specifies another positive limit no greater than `POOL_SIZE - 2`
  - cron plugins for renewal/outbox/ops jobs
- PgBouncer transaction mode:
  - repository has `pgbouncer/pgbouncer.ini` with `pool_mode = transaction`
  - app runtime supports `STORE_DB_POOL_MODE=transaction` with `prepare: :unnamed`, while new renewal POSTs remain unavailable in that mode
- Telemetry/logging:
  - telemetry dependencies configured
  - logger metadata includes operational/payment keys (request_id, actor_id, order_ref, provider, error_code, oban_job_id, etc.)
  - sentry integration is configured

## Known risks and contradictions to avoid

- README is not yet project truth; do not use it as capability evidence.
- Admin auth has router/on_mount evidence plus targeted role-gate evidence for subscriptions admin LiveViews; continue per-surface role-depth verification across remaining `/admin/**` surfaces.
- Non-Stripe payment providers must not be described as production-ready without direct adapter evidence.
- Web boundary rules are strict (`AGENTS.md` + mix check gates); violations will create regressions even if functionally correct.
- Single-tenant invariants must be preserved (`no tenant_id` and no tenant routing).

## Evidence sources used

- `AGENTS.md`
- `README.md`
- `mix.exs`
- `.tool-versions`
- `Dockerfile`
- `config/runtime.exs`
- `config/config.exs`
- `lib/store_web/router.ex`
- `lib/store_web/live_user_auth.ex`
- `docs/agent_notes/subscription_payments_evaluation.md`
- `pgbouncer/pgbouncer.ini`
