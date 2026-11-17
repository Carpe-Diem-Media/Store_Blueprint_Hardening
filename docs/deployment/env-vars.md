# Runtime Environment Contract

This document is the deployment contract for runtime configuration enforced by `config/runtime.exs`, with release/runtime context from `Dockerfile`, `compose.yaml`, `rel/env.sh.eex`, and `pgbouncer/pgbouncer.ini`.

## Workstation development and tests

The workstation `dev-core` stack owns these shared PostgreSQL 18 and Redis 7
endpoints. The repository connects to them and never manages their containers.

| Environment | PostgreSQL | Database | Role | Redis |
| --- | --- | --- | --- | --- |
| Development | `127.0.0.1:55432` | `store_blueprint_dev` | `store_blueprint_dev` | `127.0.0.1:56379` |
| Test | `127.0.0.1:55433` | `store_blueprint_test` plus the existing direct suffix | `store_blueprint_test` | `127.0.0.1:56380` |

The tracked `.devcore/project.conf` declares the project roles and databases.
`devcore-project activate` provisions these allocations and writes ignored
profile files with mode `0600`. The DEV profile supplies `STORE_DEV_DATABASE_*`
values, and the TEST profile supplies `STORE_TEST_DATABASE_*` values. The app
uses direct PostgreSQL connections for both `Store.Repo` and `Store.DirectRepo`.

Run workstation commands through the matching profile:

```sh
devcore-project run dev -- mix setup
devcore-project run dev -- mix phx.server
devcore-project run test -- mix test
```

The TEST role is non-superuser and has `CREATEDB` for partition-suffixed
databases. Ordinary test config appends `STORE_TEST_DB_SUFFIX` or
`MIX_TEST_PARTITION` to `STORE_TEST_DATABASE_NAME`, which defaults to
`store_blueprint_test`. CI retains its existing TEST service defaults. Each test
process gets its own key prefix under `store_blueprint_hardening:test:`.

PostgreSQL migrations install the `citext` extension. The selected PostgreSQL
server must provide `citext`; the workstation PostgreSQL 18 TEST migration was
verified using the non-superuser project role.

Performance smoke runs set `STORE_PERF_SMOKE=true` and must provide
`STORE_PERF_DATABASE_NAME`, `STORE_PERF_DATABASE_HOST`,
`STORE_PERF_DATABASE_PORT`, `STORE_PERF_REDIS_HOST`, and
`STORE_PERF_REDIS_PORT` for project-isolated PostgreSQL 18 and Redis 7. The
performance database name must be exactly `store_blueprint_perf` (not
`store_blueprint_dev` or any `store_blueprint_test*` database). CI creates a separate job-owned performance
database before running the smoke suite. Outside CI, the performance PostgreSQL
and Redis endpoints cannot use the locked workstation DEV or TEST loopback ports.
`STORE_PERF_DATABASE_USERNAME` defaults to `store_blueprint_test` and
`STORE_PERF_DATABASE_PASSWORD` defaults to `STORE_TEST_DATABASE_PASSWORD`.
Redis ACL settings use `STORE_PERF_REDIS_USERNAME` and
`STORE_PERF_REDIS_PASSWORD`. CI supplies job-owned ephemeral services. These
settings keep performance fixtures away from shared workstation DEV/TEST data.

`.env.production.example` is the safe production template for `compose.yaml`;
it is separate from the workstation `.env.example`.

## Runtime modes

- `PHX_SERVER=true` enables the web server in release mode.
- `STORE_DB_POOL_MODE`:
  - `session` (default): normal prepared statement behavior.
  - `transaction`: sets `prepare: :unnamed` for `Store.Repo` only, which is the PgBouncer-safe mode for transaction pooling.
- `STORE_RATE_LIMIT_BACKEND`:
  - `ets` (default) or `redis`.
- `STORE_COMMS_PROVIDER`:
  - `swoosh` (default) or `req_postmark`.
- `STORE_DIGITAL_STORAGE_PROVIDER`:
  - `s3` (default) or `fake`.

## Required in production

The app raises at boot if these are missing in `MIX_ENV=prod`:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `STORE_TOKEN_SIGNING_SECRET`
- `STORE_GOOGLE_CLIENT_ID`
- `STORE_GOOGLE_CLIENT_SECRET`
- `STORE_GOOGLE_REDIRECT_URI_BASE`
- `STORE_QUOTE_HASH_SECRET`
- `SENTRY_DSN`

## Conditionally required in production

- Stripe when enabled via `STORE_PAYMENTS_ENABLED_PROVIDERS`:
  - `STORE_STRIPE_WEBHOOK_SECRET`
  - `STORE_STRIPE_SECRET_KEY`
  - `STORE_STRIPE_PUBLISHABLE_KEY`
- Postmark provider (`STORE_COMMS_PROVIDER=req_postmark`):
  - `STORE_POSTMARK_SERVER_TOKEN`
- S3 storage (`STORE_DIGITAL_STORAGE_PROVIDER=s3`):
  - `STORE_DIGITAL_S3_ACCESS_KEY_ID`
  - `STORE_DIGITAL_S3_SECRET_ACCESS_KEY`

## Optional with defaults

### Phoenix / endpoint / cluster

- `PHX_SERVER` (Docker release sets default `true`)
- `PORT` (default `4000`)
- `PHX_HOST` (default `example.com`)
- `ECTO_IPV6` (`true`/`1` enables IPv6 socket options)
- `DNS_CLUSTER_QUERY` (set explicitly when clustering is enabled)
- `STORE_CLUSTER_TRANSPORT` (`inet6` default in release env script, or `inet`)
- `STORE_TRUSTED_PROXY_PROXIES` (comma-separated CIDRs/IPs; defaults from compile-time config)
- `STORE_TRUSTED_PROXY_HEADERS` (default `cf-connecting-ip,x-forwarded-for`)

### Database pooling

- `STORE_DB_POOL_MODE` (`session` default; `transaction` for PgBouncer transaction pools). Applies to `Store.Repo` only; `Store.DirectRepo` always runs in session mode.
- `POOL_SIZE` (default `10`). Applies to both `Store.Repo` and `Store.DirectRepo`.
- `STORE_DIRECT_DATABASE_URL` (optional; defaults to `DATABASE_URL`). Connection string for `Store.DirectRepo`. When `DATABASE_URL` points at PgBouncer in transaction pooling, set this to a direct Postgres URL that bypasses PgBouncer; otherwise Oban (which runs on `Store.DirectRepo`) breaks because it requires advisory locks and prepared statements.

#### DirectRepo invariant

`Store.DirectRepo` must always run with session-mode connection semantics. The runtime never applies `prepare: :unnamed` to it, regardless of `STORE_DB_POOL_MODE`. Oban is wired to `Store.DirectRepo` (see `config/config.exs`) and requires session-mode behavior; routing it through PgBouncer transaction pooling will fail. Use `STORE_DIRECT_DATABASE_URL` to give `Store.DirectRepo` a direct connection in PgBouncer-fronted deployments.

### Logging and security headers

- `STORE_LOG_LEVEL` (`debug|info|warning|error`, default `info`)
- `STORE_LOG_FORMAT` (`text|json`, default `text`)
- `STORE_CSP_MODE` (`disabled|enforce|report_only`, default `disabled`)
- `STORE_CSP_POLICY` (default Stripe-compatible policy when CSP is enabled)
- `STORE_CSP_REPORT_URI` (optional report endpoint)

### Payments and provider HTTP tuning

- `STORE_PAYMENTS_ENABLED_PROVIDERS` (comma-separated list; default empty)
- `STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI` (must be in enabled providers when set)
- `STORE_STRIPE_API_BASE_URL` (default `https://api.stripe.com`)
- `STORE_STRIPE_API_VERSION` (default `2025-02-24.acacia`)
- `STORE_PAYMENT_TIMEOUT_MS` (default `5000`)
- `STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS` (default `4000`)
- `STORE_PAYMENT_HTTP_POOL_SIZE` (default `400`)
- `STORE_PAYMENT_HTTP_RECEIVE_TIMEOUT_MS` (defaults from `STORE_PAYMENT_TIMEOUT_MS`, fallback `6000`)
- `STORE_PAYMENT_HTTP_POOL_TIMEOUT_MS` (default `5000`)

Timeout guardrails enforced at boot:

- `STORE_PAYMENT_HTTP_RECEIVE_TIMEOUT_MS` must be greater than `STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS`.
- `STORE_PAYMENT_HTTP_POOL_TIMEOUT_MS` must be greater than `STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS`.

### Comms

- `STORE_COMMS_FROM_NAME` (default `Store`)
- `STORE_COMMS_FROM_EMAIL` (default `no-reply@example.com`)
- `STORE_COMMS_SUPPORT_EMAIL` (default `support@example.com`)
- `STORE_POSTMARK_URL` (default `https://api.postmarkapp.com/email`)

### Digital

- `STORE_DIGITAL_ALLOWED_REDIRECT_HOSTS` (default `downloads.example.com`)
- `STORE_DIGITAL_SIGNED_URL_TTL_SECONDS` (default `120`)
- `STORE_DIGITAL_DEFAULT_GRANT_TTL_DAYS` (default `30`)
- `STORE_DIGITAL_REFUND_REVOCATION_POLICY` (`strict_line_scoped|strict_order_scoped|threshold`, default `strict_line_scoped`)
- `STORE_DIGITAL_FAKE_HOST` (default `downloads.local`)
- `STORE_DIGITAL_S3_REGION` (default `us-east-1`)
- `STORE_DIGITAL_S3_HOST` (optional)
- `STORE_DIGITAL_S3_SCHEME` (optional)
- `STORE_DIGITAL_S3_PORT` (optional integer)

### Rate limiting and Redis

- `STORE_RATE_LIMIT_BACKEND` (`ets|redis`, default `ets`)
- Production Redis keys use the fixed `store_blueprint_hardening:prod` namespace.
- `STORE_REDIS_HOST` (default `localhost`)
- `STORE_REDIS_PORT` (default `6379`)
- `STORE_REDIS_DB` (default `0`)
- `STORE_REDIS_USERNAME` (optional)
- `STORE_REDIS_PASSWORD` (optional)
- `STORE_REDIS_SSL` (`true`/`1` enables TLS; default false)

Production Redis host, port, database, credentials, and TLS settings are
independent of the workstation Redis endpoints. Do not override the project
namespace with an unscoped prefix.
- `STORE_WEBHOOK_RATE_LIMIT_LIMIT` (default `120`)
- `STORE_WEBHOOK_RATE_LIMIT_WINDOW_SECONDS` (default `60`)
- `STORE_ADMIN_RATE_LIMIT_LIMIT` (default `300`)
- `STORE_ADMIN_RATE_LIMIT_WINDOW_SECONDS` (default `60`)
- `STORE_PUBLIC_WAITING_ROOM_LIMIT` (default `380`)
- `STORE_PUBLIC_WAITING_ROOM_HARD_LIMIT` (default `450`)
- `STORE_PUBLIC_WAITING_ROOM_WINDOW_SECONDS` (default `10`)
- `STORE_LIVE_WAITING_ROOM_LIMIT` (default `380`)
- `STORE_LIVE_WAITING_ROOM_HARD_LIMIT` (default `450`)
- `STORE_LIVE_WAITING_ROOM_WINDOW_SECONDS` (default `10`)
- `STORE_WAITING_ROOM_REFRESH_SECONDS` (default `10`)
- `STORE_DIGITAL_SIGNED_DOWNLOAD_LIMIT` (default `10`)
- `STORE_DIGITAL_SIGNED_DOWNLOAD_WINDOW_SECONDS` (default `60`)

### Operations

- `STORE_WEBHOOK_RETENTION_DAYS` (default `30`)

## PgBouncer transaction pooling implications

For PgBouncer in transaction mode (`pool_mode = transaction`), use:

- `STORE_DB_POOL_MODE=transaction`
- `DATABASE_URL` pointing at PgBouncer (transaction pool)
- `STORE_DIRECT_DATABASE_URL` pointing at Postgres directly (bypassing PgBouncer)

`STORE_DB_POOL_MODE=transaction` applies `prepare: :unnamed` to `Store.Repo` only, which is the PgBouncer-safe pattern for hot-path web traffic.

`Store.DirectRepo` is always configured for session-mode behavior. It is the repo Oban runs on and is also used for migrations and other non-hot-path operations that require prepared statements and advisory locks. If `STORE_DIRECT_DATABASE_URL` is unset, `Store.DirectRepo` falls back to `DATABASE_URL`, which is only safe when `DATABASE_URL` is itself a direct Postgres connection (i.e., not PgBouncer in transaction mode).
