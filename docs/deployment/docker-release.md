# Docker Release Operations

This document describes the release/container model implemented by `Dockerfile`, `compose.yaml`, and release scripts.

## Image model

- Multi-stage build:
  - Build stage: `elixir:1.19.5-otp-28`
  - Runtime stage: `debian:bookworm-slim`
- Runtime process:
  - Non-root user: `appuser`
  - Exposed port: `4000`
  - Command: `bin/store start`
- `PHX_SERVER=true` is set in the runtime image.

## Build sequence

The release build performs:

1. `mix deps.get` / `mix deps.compile`
2. `mix compile`
3. `mix assets.deploy`
4. `mix release`

Compiling before assets ensures compile-time/generated assets are available before deployment packaging.

## Required env before boot

Use `docs/deployment/env-vars.md` as the canonical env contract. Pass the values
to Compose through `.env.production` (or the deployment platform's environment).
At minimum in production:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `SENTRY_DSN`
- `STORE_TOKEN_SIGNING_SECRET`
- `STORE_GOOGLE_CLIENT_ID`
- `STORE_GOOGLE_CLIENT_SECRET`
- `STORE_GOOGLE_REDIRECT_URI_BASE`
- `STORE_QUOTE_HASH_SECRET`

Additional runtime nuance:

- `PHX_HOST` is optional and defaults to `example.com` unless explicitly set.
- Provider secrets are conditional by enabled provider (for example, Stripe keys are required only when `STORE_PAYMENTS_ENABLED_PROVIDERS` includes `stripe`).

## Preflight and migration commands

Run release commands inside the container/image, not `mix` on production hosts:

- Preflight:
  - `bin/store eval "Store.Release.preflight()"`
- Migrations:
  - `bin/store eval "Store.Release.migrate_all()"`
- Restore audit:
  - `bin/store eval "Store.Release.restore_audit()"`

## Health checks

- Liveness: `GET /health/live`
- Readiness: `GET /health/ready`

## PgBouncer and pool mode

- `pgbouncer/pgbouncer.ini` sets `pool_mode = transaction`.
- In app runtime, use `STORE_DB_POOL_MODE=transaction` to enable `prepare: :unnamed` on `Store.Repo`.
- Keep `POOL_SIZE` consistent with PgBouncer pool sizing and Postgres capacity.

### DirectRepo separation in PgBouncer-fronted deployments

`Store.DirectRepo` always runs in session-mode. It is the repo Oban is configured to use (see `config/config.exs`) and is also used for migrations. Oban requires advisory locks and prepared statements, which PgBouncer transaction pooling does not support.

When `DATABASE_URL` points at PgBouncer in transaction mode, set `STORE_DIRECT_DATABASE_URL` to a direct Postgres URL that bypasses PgBouncer. The Oban queues, cron plugins, and `Store.Release.migrate*` commands all use `Store.DirectRepo` and must reach Postgres directly.

If both URLs are the same (single-Postgres deployments without PgBouncer in front), you can leave `STORE_DIRECT_DATABASE_URL` unset; `Store.DirectRepo` will fall back to `DATABASE_URL`.

## Operational notes

- Trust proxy settings should be explicit in edge-proxied environments:
  - `STORE_TRUSTED_PROXY_PROXIES`
  - `STORE_TRUSTED_PROXY_HEADERS`
- For clustered deploys, release script behavior in `rel/env.sh.eex` uses:
  - `STORE_CLUSTER_TRANSPORT` (`inet6` default, `inet` optional)
  - explicit `DNS_CLUSTER_QUERY` for service discovery
- Cloudflare/edge policy should avoid caching authenticated, cart, checkout, and order flows.

## Repository Compose contract

`compose.yaml` is the repository-owned deployment contract. It builds and runs
the application only, binds the web endpoint to loopback for a host or external
reverse proxy, and reads runtime settings from the Compose environment file or
deployment environment.

PostgreSQL and Redis are external to this Compose project. Set their production
connection values in `.env.production`; do not add workstation PostgreSQL
DEV/TEST or Redis DEV/TEST services to this file. The current application
topology needs no production override.

`docker-compose.yml` is retained as legacy local infrastructure while its
existing containers and data are preserved. It is not the ordinary development
or deployment configuration authority. Follow the workstation endpoint
contract in `README.md` for development. Do not remove its volumes or change
their PostgreSQL data directory as part of this migration.

For production, copy `.env.production.example` to an ignored `.env.production`
file and supply real runtime values. Validate it with
`docker compose -f compose.yaml --env-file .env.production config --quiet`. The
Compose service passes production settings only; it does not pass workstation
DEV/TEST database passwords into the application container. Then run the
release preflight and migration commands described above.
