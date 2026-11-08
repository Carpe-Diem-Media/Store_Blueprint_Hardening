# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash, default_string_length_count: :codepoints

config :store,
  ecto_repos: [Store.Repo, Store.DirectRepo],
  ash_domains: [
    Store.Accounts,
    Store.Admin,
    Store.Catalog,
    Store.Carts,
    Store.Comms,
    Store.Digital,
    Store.Checkout,
    Store.Orders,
    Store.Payments,
    Store.Subscriptions,
    Store.Entitlements,
    Store.Fulfillment,
    Store.Shipping,
    Store.Pricing,
    Store.Tools
  ],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Deterministic local defaults; production ENFORCED values come from runtime env.
config :store, :inventory_admission,
  mode: :disabled,
  scope: "default",
  repo_pool_capacity: nil,
  repo_headroom: nil,
  b_total: nil,
  q_variant_max: 10,
  q_global_max: 100,
  queue_window_ms: 10_000,
  db_window_ms: 2_000,
  lease_window_ms: 3_000,
  safety_margin_ms: 500,
  cleanup_limit: 100,
  metadata_retention_ms: 86_400_000,
  database_safety_window_ms: 1_000,
  recovery_retry_budget: 3,
  recovery_deadline_ms: 5_000,
  redis_restart_quarantine_ms: 2_000,
  hmac_key: nil,
  hmac_key_version: "v1"

# Configure the endpoint
config :store, StoreWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  session_secure: false,
  render_errors: [
    formats: [html: StoreWeb.ErrorHTML, json: StoreWeb.ErrorJSON, jsonapi: StoreWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Store.PubSub,
  live_view: [signing_salt: "33Mw/8JS"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :store, Store.Mailer, adapter: Swoosh.Adapters.Local

config :store, :payments,
  enabled_providers: [],
  default_purchase_provider_for_ui: nil,
  checkout: [
    return_base_url: "http://localhost:4000/checkout/return",
    cancel_base_url: "http://localhost:4000/checkout/cancel"
  ],
  stripe: [
    api_base_url: "https://api.stripe.com",
    webhook_secret: nil,
    secret_key: nil,
    publishable_key: "pk_test_store_blueprint",
    api_version: "2025-02-24.acacia",
    payment_timeout_ms: 5_000,
    payment_provider_task_timeout_ms: 4_000,
    payment_http_pool_size: 400,
    payment_http_receive_timeout_ms: 6_000,
    payment_http_pool_timeout_ms: 5_000,
    request_options: []
  ]

config :store, :subscription_features,
  expose_purchase?: false,
  provider_managed_mode_enabled?: false,
  immediate_switching_enabled?: false

config :store, :comms,
  default_provider: :swoosh,
  from_name: "Store",
  from_email: "no-reply@store.local",
  support_email: "support@store.local",
  req_postmark: [
    url: "https://api.postmarkapp.com/email",
    server_token: nil,
    from_name: "Store",
    from_email: "no-reply@store.local"
  ]

config :store, :digital,
  storage_provider: :fake,
  signed_url_ttl_seconds: 120,
  default_grant_ttl_days: 30,
  default_max_downloads: nil,
  refund_revocation_policy: :strict_line_scoped,
  fake_host: "downloads.local",
  allowed_redirect_hosts: ["downloads.local"]

config :store, :rate_limit,
  backend: Store.Support.RateLimit.EtsBackend,
  webhook_limit: 120,
  webhook_window_seconds: 60,
  admin_limit: 300,
  admin_window_seconds: 60,
  public_waiting_room_limit: 380,
  public_waiting_room_hard_limit: 450,
  public_waiting_room_window_seconds: 10,
  live_waiting_room_limit: 380,
  live_waiting_room_hard_limit: 450,
  live_waiting_room_window_seconds: 10,
  waiting_room_refresh_seconds: 10,
  signed_download_limit: 10,
  signed_download_window_seconds: 60

config :store, :trusted_proxy,
  headers: ["cf-connecting-ip", "x-forwarded-for"],
  proxies: [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
    "2400:cb00::/32",
    "2606:4700::/32",
    "2803:f800::/32",
    "2405:b500::/32",
    "2405:8100::/32",
    "2a06:98c0::/29",
    "2c0f:f248::/32"
  ]

config :store, :operations, webhook_retention_days: 30
config :store, :enable_ops_telemetry_poller, true

config :store, :security_headers,
  csp_mode: :disabled,
  csp_policy: nil,
  csp_report_uri: nil

# Ensure DirectRepo uses the primary migration path and delegates schema management
config :store, Store.DirectRepo,
  priv: "priv/repo",
  migration_repo: Store.Repo

config :store, Oban,
  repo: Store.DirectRepo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Store.Workers.ExpireInventoryReservationsWorker},
       {"* * * * *", Store.Workers.ExpirePendingProviderSetupOrdersWorker},
       {"* * * * *", Store.Workers.FlushRedisAggregateBucketsWorker},
       {"*/5 * * * *", Store.Workers.ReclaimStaleEmailOutboxWorker},
       {"*/5 * * * *", Store.Workers.RunDueSubscriptionRenewalsWorker},
       {"*/5 * * * *", Store.Workers.RunDueFailedPaymentSuspensionsWorker},
       {"*/5 * * * *", Store.Workers.RunDueScheduledCancellationsWorker},
       {"*/5 * * * *", Store.Workers.ReplayScheduledCancellationNotificationsWorker},
       {"*/5 * * * *", Store.Workers.RunSubscriptionAccessEffectRecoveryWorker},
       {"0 * * * *", Store.Workers.EnqueueMembershipRenewalRemindersWorker},
       {"15 2 * * *", Store.Workers.PurgeWebhookReceiptEvidenceWorker}
     ]}
  ],
  queues: [
    webhooks: 10,
    inventory: 10,
    refunds: 10,
    comms: 10,
    fulfillment: 10,
    digital: 10,
    subscriptions: 10,
    ops: 5
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  store: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  store: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :remote_ip,
    :actor_id,
    :order_id,
    :order_ref,
    :provider,
    :provider_event_id,
    :error_code,
    :oban_job_id,
    :worker
  ]

config :phoenix, :filter_parameters, [
  "password",
  "token",
  "secret",
  "api_key",
  "client_secret",
  "signing_secret",
  "webhook_secret",
  "card",
  "payment_method",
  "address",
  "phone",
  "email"
]

config :sentry,
  client: Store.Support.SentryHTTPClient,
  dsn: nil,
  environment_name: to_string(config_env()),
  enable_source_code_context: false,
  root_source_code_paths: [File.cwd!()],
  filter: Store.Support.SentryEventFilter

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# JSON:API media type support for accepts/content-negotiation.
config :mime, :types, %{
  "application/vnd.api+json" => ["jsonapi"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
