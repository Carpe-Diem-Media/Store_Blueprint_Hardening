defmodule Store.MixProject do
  use Mix.Project

  def project do
    [
      app: :store,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        check: :test,
        "check.ci": :test,
        "check.static": :test,
        "check.types": :test
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Store.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:tidewave, "~> 0.9", only: :dev},
      {:phoenix, ">= 1.8.9 and < 1.9.0-0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:decimal, "~> 3.1.2"},
      {:postgrex, ">= 0.22.4 and < 0.23.0-0"},
      {:ash, ">= 3.37.2 and < 4.0.0-0"},
      {:ash_postgres, "~> 2.15.2"},
      # These transitive security floors are explicit so parent ranges cannot
      # re-resolve the graph to an advisory-affected release.
      {:ash_sql, ">= 0.8.6 and < 1.0.0-0"},
      {:ash_phoenix, ">= 2.3.25 and < 3.0.0-0"},
      {:ash_json_api, "~> 1.5"},
      {:ash_state_machine, "~> 0.2.12"},
      {:open_api_spex, "~> 3.20"},
      {:ash_authentication, ">= 5.0.0-rc.15 and < 6.0.0-0"},
      {:ash_authentication_phoenix, ">= 3.0.0-rc.11 and < 4.0.0-0"},
      {:assent, ">= 0.3.2 and < 0.4.0"},
      {:simple_sat, "~> 0.1"},
      {:phoenix_html, ">= 4.4.0 and < 5.0.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:petal_components, "~> 4.16"},
      {:lazy_html, ">= 0.1.13", only: :test},
      {:phoenix_live_dashboard, "~> 0.9.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, ">= 1.26.3 and < 2.0.0-0"},
      {:oban, "~> 2.0"},
      {:req, "~> 0.7.0"},
      {:sentry, "~> 13.0"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:cachex, "~> 4.1"},
      {:redix, "~> 1.5"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.0"},
      {:bandit, ">= 1.14.1 and < 2.0.0-0"},
      # Security floors for transitive HTTP/authentication runtime packages.
      {:mint, ">= 1.11.0 and < 2.0.0-0"},
      {:plug, ">= 1.19.5 and < 2.0.0-0"},
      {:plug_crypto, ">= 2.2.1 and < 3.0.0-0"},
      {:hpax, ">= 1.0.4 and < 2.0.0-0"},
      {:thousand_island, ">= 1.5.0 and < 2.0.0-0"},
      {:ymlr, ">= 5.1.6 and < 6.0.0-0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.37", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind store", "esbuild store"],
      "assets.deploy": [
        "tailwind store --minify",
        "esbuild store --minify",
        "phx.digest"
      ],
      "check.static": [
        "hex.audit",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "check.req_usage",
        "check.web_no_http",
        "check.web_no_oban_enqueue",
        "check.web_no_ash_query",
        "check.web_no_direct_ash_calls",
        "check.admin_live_no_direct_ash",
        "check.surface_naming",
        "check.no_ash_graphql_dep",
        "check.api_v1_forward_only",
        "check.no_repo_in_web",
        "check.moduledoc",
        "check.docs_notes",
        "check.subscriptions_docs_sync",
        "credo --strict",
        "sobelow --private --skip --exit Medium",
        "docs"
      ],
      check: [
        "hex.audit",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "check.req_usage",
        "check.web_no_http",
        "check.web_no_oban_enqueue",
        "check.web_no_ash_query",
        "check.web_no_direct_ash_calls",
        "check.admin_live_no_direct_ash",
        "check.surface_naming",
        "check.no_ash_graphql_dep",
        "check.api_v1_forward_only",
        "check.no_repo_in_web",
        "check.moduledoc",
        "check.docs_notes",
        "check.subscriptions_docs_sync",
        "test",
        "credo --strict",
        "sobelow --private --skip --exit Medium",
        "docs"
      ],
      "check.ci": ["check"],
      "check.types": ["dialyzer --format short"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit, :inets],
      flags: [:error_handling, :unmatched_returns, :underspecs],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
