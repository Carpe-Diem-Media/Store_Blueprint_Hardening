import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/store start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :store, StoreWeb.Endpoint, server: true
end

config :store, StoreWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  optional_env = fn env ->
    case System.get_env(env) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  required_env! = fn env ->
    optional_env.(env) || raise "environment variable #{env} is missing."
  end

  parse_positive_integer! = fn env, default ->
    case System.get_env(env, default) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> raise "environment variable #{env} must be a positive integer"
        end

      _ ->
        raise "environment variable #{env} must be set"
    end
  end

  parse_integer! = fn env, value ->
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> raise "environment variable #{env} must be an integer"
    end
  end

  parse_optional_integer! = fn env ->
    case System.get_env(env) do
      nil -> nil
      value -> parse_integer!.(env, value)
    end
  end

  parse_required_integer! = fn env ->
    case System.get_env(env) do
      nil -> raise "environment variable #{env} is missing"
      value -> parse_integer!.(env, value)
    end
  end

  parse_mode! = fn env ->
    case System.get_env(env, "disabled") |> String.trim() |> String.downcase() do
      "disabled" -> :disabled
      "enforced" -> :enforced
      value -> raise "invalid #{env} value: #{value}"
    end
  end

  parse_bounded_string! = fn env, default, regex ->
    value = System.get_env(env, default) |> String.trim()

    if Regex.match?(regex, value) do
      value
    else
      raise "environment variable #{env} has an invalid value"
    end
  end

  inventory_admission_mode = parse_mode!.("STORE_INVENTORY_ADMISSION_MODE")

  inventory_admission_scope =
    parse_bounded_string!.(
      "STORE_INVENTORY_ADMISSION_SCOPE",
      "default",
      ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/
    )

  inventory_admission_hmac_key = System.get_env("STORE_INVENTORY_ADMISSION_HMAC_KEY")

  if inventory_admission_mode == :enforced and is_nil(inventory_admission_hmac_key) do
    raise "environment variable STORE_INVENTORY_ADMISSION_HMAC_KEY is missing"
  end

  inventory_admission_hmac_key_version =
    parse_bounded_string!.(
      "STORE_INVENTORY_ADMISSION_HMAC_KEY_VERSION",
      "v1",
      ~r/\Av[0-9]+\z/
    )

  inventory_admission_defaults = %{
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
    redis_restart_quarantine_ms: 2_000
  }

  inventory_admission_integer = fn env, key ->
    if inventory_admission_mode == :enforced do
      parse_required_integer!.(env)
    else
      case System.get_env(env) do
        nil -> Map.fetch!(inventory_admission_defaults, key)
        value -> parse_integer!.(env, value)
      end
    end
  end

  inventory_admission_capacity = fn env ->
    if inventory_admission_mode == :enforced do
      parse_required_integer!.(env)
    else
      parse_optional_integer!.(env)
    end
  end

  config :store, :inventory_admission,
    mode: inventory_admission_mode,
    scope: inventory_admission_scope,
    repo_pool_capacity:
      inventory_admission_capacity.("STORE_INVENTORY_ADMISSION_REPO_POOL_CAPACITY"),
    repo_headroom: inventory_admission_capacity.("STORE_INVENTORY_ADMISSION_REPO_HEADROOM"),
    b_total: inventory_admission_capacity.("STORE_INVENTORY_ADMISSION_B_TOTAL"),
    q_variant_max:
      inventory_admission_integer.("STORE_INVENTORY_ADMISSION_Q_VARIANT_MAX", :q_variant_max),
    q_global_max:
      inventory_admission_integer.("STORE_INVENTORY_ADMISSION_Q_GLOBAL_MAX", :q_global_max),
    queue_window_ms:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_QUEUE_WINDOW_MS",
        :queue_window_ms
      ),
    db_window_ms:
      inventory_admission_integer.("STORE_INVENTORY_ADMISSION_DB_WINDOW_MS", :db_window_ms),
    lease_window_ms:
      inventory_admission_integer.("STORE_INVENTORY_ADMISSION_LEASE_WINDOW_MS", :lease_window_ms),
    safety_margin_ms:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_SAFETY_MARGIN_MS",
        :safety_margin_ms
      ),
    cleanup_limit:
      inventory_admission_integer.("STORE_INVENTORY_ADMISSION_CLEANUP_LIMIT", :cleanup_limit),
    metadata_retention_ms:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_METADATA_RETENTION_MS",
        :metadata_retention_ms
      ),
    database_safety_window_ms:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_DATABASE_SAFETY_WINDOW_MS",
        :database_safety_window_ms
      ),
    recovery_retry_budget:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_RECOVERY_RETRY_BUDGET",
        :recovery_retry_budget
      ),
    recovery_deadline_ms:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_RECOVERY_DEADLINE_MS",
        :recovery_deadline_ms
      ),
    redis_restart_quarantine_ms:
      inventory_admission_integer.(
        "STORE_INVENTORY_ADMISSION_REDIS_RESTART_QUARANTINE_MS",
        :redis_restart_quarantine_ms
      ),
    hmac_key: inventory_admission_hmac_key,
    hmac_key_version: inventory_admission_hmac_key_version

  token_signing_secret = required_env!.("STORE_TOKEN_SIGNING_SECRET")

  google_client_id = required_env!.("STORE_GOOGLE_CLIENT_ID")

  google_client_secret = required_env!.("STORE_GOOGLE_CLIENT_SECRET")

  google_redirect_uri_base = required_env!.("STORE_GOOGLE_REDIRECT_URI_BASE")

  quote_hash_secret = required_env!.("STORE_QUOTE_HASH_SECRET")

  database_url = required_env!.("DATABASE_URL")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  db_pool_mode = System.get_env("STORE_DB_POOL_MODE", "session")

  # Store.DirectRepo MUST run in session-mode (Oban requires advisory locks and
  # prepared statements). When DATABASE_URL points at PgBouncer in transaction
  # pooling, set STORE_DIRECT_DATABASE_URL to a direct Postgres URL that
  # bypasses PgBouncer. If unset, DirectRepo falls back to DATABASE_URL.
  direct_database_url = optional_env.("STORE_DIRECT_DATABASE_URL") || database_url

  primary_pool_size = parse_positive_integer!.("POOL_SIZE", "10")

  if primary_pool_size < 3 do
    raise "POOL_SIZE must be at least 3 to reserve at least two primary connections outside subscription workers"
  end

  automatic_subscriptions_queue_limit = min(4, primary_pool_size - 2)

  subscriptions_queue_limit =
    case System.get_env("STORE_SUBSCRIPTIONS_QUEUE_LIMIT") do
      nil ->
        automatic_subscriptions_queue_limit

      value ->
        parsed =
          case Integer.parse(value) do
            {integer, ""} when integer > 0 ->
              integer

            _ ->
              raise "STORE_SUBSCRIPTIONS_QUEUE_LIMIT must be a positive integer no greater than POOL_SIZE - 2 to reserve at least two primary connections"
          end

        if parsed > primary_pool_size - 2 do
          raise "STORE_SUBSCRIPTIONS_QUEUE_LIMIT must be no greater than POOL_SIZE - 2 to reserve at least two primary connections"
        end

        parsed
    end

  repo_common_opts = [
    pool_size: primary_pool_size,
    socket_options: maybe_ipv6
  ]

  primary_repo_opts = Keyword.put(repo_common_opts, :url, database_url)

  primary_repo_opts =
    case db_pool_mode do
      "session" ->
        primary_repo_opts

      "transaction" ->
        Keyword.put(primary_repo_opts, :prepare, :unnamed)

      value ->
        raise "invalid STORE_DB_POOL_MODE value: #{value}"
    end

  direct_repo_opts = Keyword.put(repo_common_opts, :url, direct_database_url)

  config :store, Store.Repo, primary_repo_opts

  config :store, Store.DirectRepo, direct_repo_opts

  config :store, Oban, queues: [subscriptions: subscriptions_queue_limit]

  config :store, :database_pool_mode, db_pool_mode

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base = required_env!.("SECRET_KEY_BASE")

  host = System.get_env("PHX_HOST") || "example.com"

  sentry_dsn = required_env!.("SENTRY_DSN")

  log_level =
    case System.get_env("STORE_LOG_LEVEL", "info") do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      value -> raise "invalid STORE_LOG_LEVEL value: #{value}"
    end

  log_format =
    case System.get_env("STORE_LOG_FORMAT", "text") do
      "text" -> :text
      "json" -> :json
      value -> raise "invalid STORE_LOG_FORMAT value: #{value}"
    end

  csp_mode =
    case System.get_env("STORE_CSP_MODE", "disabled") do
      "disabled" -> :disabled
      "enforce" -> :enforce
      "report_only" -> :report_only
      value -> raise "invalid STORE_CSP_MODE value: #{value}"
    end

  csp_report_uri = System.get_env("STORE_CSP_REPORT_URI")

  csp_policy =
    case csp_mode do
      :disabled ->
        nil

      _ ->
        System.get_env(
          "STORE_CSP_POLICY",
          "default-src 'self'; script-src 'self' https://js.stripe.com; frame-src https://js.stripe.com https://hooks.stripe.com https://checkout.stripe.com; connect-src 'self' https://api.stripe.com; img-src 'self' data: https:; style-src 'self' 'unsafe-inline'"
        )
    end

  dns_cluster_query =
    System.get_env("DNS_CLUSTER_QUERY") ||
      System.get_env("RAILWAY_PRIVATE_DOMAIN") ||
      System.get_env("RAILWAY_PRIVATE_NETWORKING_DOMAIN")

  trusted_proxy_defaults =
    Application.get_env(:store, :trusted_proxy, [])
    |> Keyword.get(:proxies, [])

  trusted_proxy_proxies =
    System.get_env("STORE_TRUSTED_PROXY_PROXIES")
    |> case do
      nil ->
        trusted_proxy_defaults

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  trusted_proxy_headers =
    System.get_env("STORE_TRUSTED_PROXY_HEADERS", "cf-connecting-ip,x-forwarded-for")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :store, :dns_cluster_query, dns_cluster_query

  config :store, :trusted_proxy,
    headers: trusted_proxy_headers,
    proxies: trusted_proxy_proxies

  config :store, :token_signing_secret, token_signing_secret

  config :logger, level: log_level

  config :store, :log,
    format: log_format,
    level: log_level

  config :sentry,
    dsn: sentry_dsn,
    environment_name: "prod"

  config :store, :google_oauth,
    client_id: google_client_id,
    client_secret: google_client_secret,
    redirect_uri_base: google_redirect_uri_base

  config :store, StoreWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :store, :security_headers,
    csp_mode: csp_mode,
    csp_policy: csp_policy,
    csp_report_uri: csp_report_uri

  comms_provider_env = System.get_env("STORE_COMMS_PROVIDER", "swoosh")

  comms_provider =
    case comms_provider_env do
      "swoosh" -> :swoosh
      "req_postmark" -> :req_postmark
      value -> raise "invalid STORE_COMMS_PROVIDER value: #{value}"
    end

  payment_provider_aliases = %{
    "stripe" => :stripe,
    "payfast" => :payfast,
    "paystack" => :paystack,
    "yoco" => :yoco,
    "peach" => :peach_payments,
    "peach_payments" => :peach_payments,
    "peach-payments" => :peach_payments
  }

  normalize_payment_provider = fn
    provider when is_atom(provider) ->
      provider
      |> Atom.to_string()
      |> String.downcase()
      |> then(&Map.get(payment_provider_aliases, &1, :unknown))

    provider when is_binary(provider) ->
      provider
      |> String.trim()
      |> String.downcase()
      |> then(&Map.get(payment_provider_aliases, &1, :unknown))

    _provider ->
      :unknown
  end

  parse_enabled_payment_providers! = fn raw_value ->
    values =
      cond do
        is_nil(raw_value) ->
          []

        is_binary(raw_value) ->
          raw_value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)

        is_list(raw_value) ->
          raw_value

        true ->
          raise "STORE_PAYMENTS_ENABLED_PROVIDERS must be a comma-separated string or list"
      end

    values
    |> Enum.reduce([], fn value, acc ->
      case normalize_payment_provider.(value) do
        :unknown ->
          raise "unsupported payment provider in STORE_PAYMENTS_ENABLED_PROVIDERS: #{inspect(value)}"

        provider ->
          if provider in acc, do: acc, else: acc ++ [provider]
      end
    end)
  end

  parse_optional_payment_provider! = fn raw_value ->
    case raw_value do
      nil ->
        nil

      value when is_binary(value) ->
        if String.trim(value) == "" do
          nil
        else
          case normalize_payment_provider.(value) do
            :unknown ->
              raise "unsupported payment provider in STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI: #{inspect(value)}"

            provider ->
              provider
          end
        end

      value ->
        case normalize_payment_provider.(value) do
          :unknown ->
            raise "unsupported payment provider in STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI: #{inspect(value)}"

          provider ->
            provider
        end
    end
  end

  enabled_payment_providers =
    parse_enabled_payment_providers!.(System.get_env("STORE_PAYMENTS_ENABLED_PROVIDERS", ""))

  default_purchase_provider_for_ui =
    parse_optional_payment_provider!.(
      System.get_env("STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI")
    )

  if default_purchase_provider_for_ui &&
       default_purchase_provider_for_ui not in enabled_payment_providers do
    raise """
    STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI must be one of STORE_PAYMENTS_ENABLED_PROVIDERS.
    got=#{default_purchase_provider_for_ui}
    enabled=#{inspect(enabled_payment_providers)}
    """
  end

  stripe_webhook_secret =
    if :stripe in enabled_payment_providers do
      required_env!.("STORE_STRIPE_WEBHOOK_SECRET")
    else
      optional_env.("STORE_STRIPE_WEBHOOK_SECRET")
    end

  stripe_secret_key =
    if :stripe in enabled_payment_providers do
      required_env!.("STORE_STRIPE_SECRET_KEY")
    else
      optional_env.("STORE_STRIPE_SECRET_KEY")
    end

  stripe_publishable_key =
    if :stripe in enabled_payment_providers do
      required_env!.("STORE_STRIPE_PUBLISHABLE_KEY")
    else
      optional_env.("STORE_STRIPE_PUBLISHABLE_KEY") || "pk_test_store_blueprint"
    end

  payment_timeout_ms = parse_positive_integer!.("STORE_PAYMENT_TIMEOUT_MS", "5000")

  payment_provider_task_timeout_ms =
    parse_positive_integer!.("STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS", "4000")

  payment_http_pool_size = parse_positive_integer!.("STORE_PAYMENT_HTTP_POOL_SIZE", "400")

  payment_http_receive_timeout_ms =
    parse_positive_integer!.(
      "STORE_PAYMENT_HTTP_RECEIVE_TIMEOUT_MS",
      System.get_env("STORE_PAYMENT_TIMEOUT_MS", "6000")
    )

  payment_http_pool_timeout_ms =
    parse_positive_integer!.("STORE_PAYMENT_HTTP_POOL_TIMEOUT_MS", "5000")

  if payment_http_receive_timeout_ms <= payment_provider_task_timeout_ms do
    raise "STORE_PAYMENT_HTTP_RECEIVE_TIMEOUT_MS must be greater than STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS"
  end

  if payment_http_pool_timeout_ms <= payment_provider_task_timeout_ms do
    raise "STORE_PAYMENT_HTTP_POOL_TIMEOUT_MS must be greater than STORE_PAYMENT_PROVIDER_TASK_TIMEOUT_MS"
  end

  config :store, :payments,
    enabled_providers: enabled_payment_providers,
    default_purchase_provider_for_ui: default_purchase_provider_for_ui,
    stripe: [
      webhook_secret: stripe_webhook_secret,
      secret_key: stripe_secret_key,
      publishable_key: stripe_publishable_key,
      api_base_url: System.get_env("STORE_STRIPE_API_BASE_URL", "https://api.stripe.com"),
      api_version: System.get_env("STORE_STRIPE_API_VERSION", "2025-02-24.acacia"),
      payment_timeout_ms: payment_timeout_ms,
      payment_provider_task_timeout_ms: payment_provider_task_timeout_ms,
      payment_http_pool_size: payment_http_pool_size,
      payment_http_receive_timeout_ms: payment_http_receive_timeout_ms,
      payment_http_pool_timeout_ms: payment_http_pool_timeout_ms,
      request_options: []
    ]

  config :store, :shipping, quote_hash_secret: quote_hash_secret

  postmark_server_token =
    if comms_provider == :req_postmark do
      required_env!.("STORE_POSTMARK_SERVER_TOKEN")
    else
      optional_env.("STORE_POSTMARK_SERVER_TOKEN")
    end

  config :store, :comms,
    default_provider: comms_provider,
    from_name: System.get_env("STORE_COMMS_FROM_NAME", "Store"),
    from_email: System.get_env("STORE_COMMS_FROM_EMAIL", "no-reply@example.com"),
    support_email: System.get_env("STORE_COMMS_SUPPORT_EMAIL", "support@example.com"),
    req_postmark: [
      url: System.get_env("STORE_POSTMARK_URL", "https://api.postmarkapp.com/email"),
      server_token: postmark_server_token,
      from_name: System.get_env("STORE_COMMS_FROM_NAME", "Store"),
      from_email: System.get_env("STORE_COMMS_FROM_EMAIL", "no-reply@example.com")
    ]

  digital_provider =
    case System.get_env("STORE_DIGITAL_STORAGE_PROVIDER", "s3") do
      "s3" -> :s3
      "fake" -> :fake
      value -> raise "invalid STORE_DIGITAL_STORAGE_PROVIDER value: #{value}"
    end

  digital_allowed_hosts =
    System.get_env("STORE_DIGITAL_ALLOWED_REDIRECT_HOSTS", "downloads.example.com")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  refund_revocation_policy =
    case System.get_env("STORE_DIGITAL_REFUND_REVOCATION_POLICY", "strict_line_scoped") do
      "strict_line_scoped" -> :strict_line_scoped
      "strict_order_scoped" -> :strict_order_scoped
      "threshold" -> :threshold
      value -> raise "invalid STORE_DIGITAL_REFUND_REVOCATION_POLICY value: #{value}"
    end

  config :store, :digital,
    storage_provider: digital_provider,
    signed_url_ttl_seconds:
      parse_positive_integer!.("STORE_DIGITAL_SIGNED_URL_TTL_SECONDS", "120"),
    default_grant_ttl_days:
      parse_positive_integer!.("STORE_DIGITAL_DEFAULT_GRANT_TTL_DAYS", "30"),
    default_max_downloads: nil,
    refund_revocation_policy: refund_revocation_policy,
    fake_host: System.get_env("STORE_DIGITAL_FAKE_HOST", "downloads.local"),
    allowed_redirect_hosts: digital_allowed_hosts,
    s3: [
      region: System.get_env("STORE_DIGITAL_S3_REGION", "us-east-1"),
      access_key_id: optional_env.("STORE_DIGITAL_S3_ACCESS_KEY_ID"),
      secret_access_key: optional_env.("STORE_DIGITAL_S3_SECRET_ACCESS_KEY"),
      host: optional_env.("STORE_DIGITAL_S3_HOST"),
      scheme: optional_env.("STORE_DIGITAL_S3_SCHEME"),
      port:
        case optional_env.("STORE_DIGITAL_S3_PORT") do
          nil -> nil
          value -> String.to_integer(value)
        end
    ]

  if digital_provider == :s3 do
    for env <- ["STORE_DIGITAL_S3_ACCESS_KEY_ID", "STORE_DIGITAL_S3_SECRET_ACCESS_KEY"] do
      _ = required_env!.(env)
    end
  end

  rate_limit_backend =
    case System.get_env("STORE_RATE_LIMIT_BACKEND", "ets") do
      "ets" -> Store.Support.RateLimit.EtsBackend
      "redis" -> Store.Support.RateLimit.RedisBackend
      value -> raise "invalid STORE_RATE_LIMIT_BACKEND value: #{value}"
    end

  redis_tls? = System.get_env("STORE_REDIS_SSL", "false") in ~w(true 1)

  config :store, :rate_limit,
    backend: rate_limit_backend,
    redis_client: Store.Support.RateLimit.RedixClient,
    redis_name: :store_rate_limit_redis,
    redis_key_prefix: "store_blueprint_hardening:prod",
    webhook_limit: parse_positive_integer!.("STORE_WEBHOOK_RATE_LIMIT_LIMIT", "120"),
    webhook_window_seconds:
      parse_positive_integer!.("STORE_WEBHOOK_RATE_LIMIT_WINDOW_SECONDS", "60"),
    admin_limit: parse_positive_integer!.("STORE_ADMIN_RATE_LIMIT_LIMIT", "300"),
    admin_window_seconds: parse_positive_integer!.("STORE_ADMIN_RATE_LIMIT_WINDOW_SECONDS", "60"),
    public_waiting_room_limit: parse_positive_integer!.("STORE_PUBLIC_WAITING_ROOM_LIMIT", "380"),
    public_waiting_room_hard_limit:
      parse_positive_integer!.("STORE_PUBLIC_WAITING_ROOM_HARD_LIMIT", "450"),
    public_waiting_room_window_seconds:
      parse_positive_integer!.("STORE_PUBLIC_WAITING_ROOM_WINDOW_SECONDS", "10"),
    live_waiting_room_limit: parse_positive_integer!.("STORE_LIVE_WAITING_ROOM_LIMIT", "380"),
    live_waiting_room_hard_limit:
      parse_positive_integer!.("STORE_LIVE_WAITING_ROOM_HARD_LIMIT", "450"),
    live_waiting_room_window_seconds:
      parse_positive_integer!.("STORE_LIVE_WAITING_ROOM_WINDOW_SECONDS", "10"),
    waiting_room_refresh_seconds:
      parse_positive_integer!.("STORE_WAITING_ROOM_REFRESH_SECONDS", "10"),
    redis: [
      host: System.get_env("STORE_REDIS_HOST", "localhost"),
      port: String.to_integer(System.get_env("STORE_REDIS_PORT", "6379")),
      database: String.to_integer(System.get_env("STORE_REDIS_DB", "0")),
      username: optional_env.("STORE_REDIS_USERNAME"),
      password: optional_env.("STORE_REDIS_PASSWORD"),
      ssl: redis_tls?
    ],
    signed_download_limit: parse_positive_integer!.("STORE_DIGITAL_SIGNED_DOWNLOAD_LIMIT", "10"),
    signed_download_window_seconds:
      parse_positive_integer!.("STORE_DIGITAL_SIGNED_DOWNLOAD_WINDOW_SECONDS", "60")

  config :store, :operations,
    webhook_retention_days: parse_positive_integer!.("STORE_WEBHOOK_RETENTION_DAYS", "30")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :store, StoreWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :store, StoreWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :store, Store.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
