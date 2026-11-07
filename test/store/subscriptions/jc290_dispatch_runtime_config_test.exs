defmodule Store.Subscriptions.JC290DispatchRuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_env_keys ~w(
    STORE_TOKEN_SIGNING_SECRET STORE_GOOGLE_CLIENT_ID STORE_GOOGLE_CLIENT_SECRET
    STORE_GOOGLE_REDIRECT_URI_BASE STORE_QUOTE_HASH_SECRET DATABASE_URL SECRET_KEY_BASE
    SENTRY_DSN POOL_SIZE STORE_SUBSCRIPTIONS_QUEUE_LIMIT STORE_DB_POOL_MODE
    STORE_INVENTORY_ADMISSION_MODE STORE_COMMS_PROVIDER STORE_PAYMENTS_ENABLED_PROVIDERS
    STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI STORE_DIGITAL_STORAGE_PROVIDER
  )

  @test_env %{
    "STORE_TOKEN_SIGNING_SECRET" => "inert-token-signing-secret",
    "STORE_GOOGLE_CLIENT_ID" => "inert-google-client-id",
    "STORE_GOOGLE_CLIENT_SECRET" => "inert-google-client-secret",
    "STORE_GOOGLE_REDIRECT_URI_BASE" => "https://example.invalid/oauth",
    "STORE_QUOTE_HASH_SECRET" => "inert-quote-secret",
    "DATABASE_URL" => "postgres://unused:unused@127.0.0.1:1/unused",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "SENTRY_DSN" => "https://unused@example.invalid/1",
    "STORE_INVENTORY_ADMISSION_MODE" => "disabled",
    "STORE_COMMS_PROVIDER" => "swoosh",
    "STORE_PAYMENTS_ENABLED_PROVIDERS" => "",
    "STORE_DB_POOL_MODE" => "session",
    "STORE_PAYMENTS_DEFAULT_PURCHASE_PROVIDER_FOR_UI" => "",
    "STORE_DIGITAL_STORAGE_PROVIDER" => "fake",
    "STORE_SUBSCRIPTIONS_QUEUE_LIMIT" => nil
  }

  test "production runtime bounds subscription workers and preserves pool topology" do
    with_runtime_env(%{"POOL_SIZE" => nil, "STORE_SUBSCRIPTIONS_QUEUE_LIMIT" => nil}, fn config ->
      assert queue_limit(config) == 4
      assert primary_pool_size(config) == 10
    end)

    with_runtime_env(%{"POOL_SIZE" => "10"}, fn config ->
      assert queue_limit(config) == 4
      assert other_queue(config, :webhooks) == 10
      assert other_queue(config, :inventory) == 10
      assert primary_pool_size(config) == 10
      assert_topology(config, "session")
    end)

    with_runtime_env(%{"POOL_SIZE" => "4"}, fn config ->
      assert queue_limit(config) == 2
      assert primary_pool_size(config) == 4
    end)

    with_runtime_env(%{"POOL_SIZE" => "3"}, fn config ->
      assert queue_limit(config) == 1
      assert primary_pool_size(config) == 3
    end)

    with_runtime_env(
      %{"POOL_SIZE" => "10", "STORE_SUBSCRIPTIONS_QUEUE_LIMIT" => "6"},
      fn config ->
        assert queue_limit(config) == 6
        assert primary_pool_size(config) == 10
      end
    )
  end

  test "production runtime rejects invalid or over-capacity queue overrides" do
    for value <- ["9", "0", "-1", "bad", ""] do
      with_runtime_env(
        %{"POOL_SIZE" => "10", "STORE_SUBSCRIPTIONS_QUEUE_LIMIT" => value},
        fn _config ->
          assert_raise RuntimeError,
                       ~r/STORE_SUBSCRIPTIONS_QUEUE_LIMIT.*reserve at least two primary connections/,
                       fn ->
                         production_config!()
                       end
        end,
        evaluate: false
      )
    end

    with_runtime_env(
      %{"POOL_SIZE" => "2"},
      fn ->
        assert_raise RuntimeError, ~r/POOL_SIZE.*reserve at least two primary connections/, fn ->
          production_config!()
        end
      end,
      evaluate: false
    )
  end

  test "transaction mode keeps unnamed prepares and session mode does not" do
    for {mode, expected_prepare} <- [{"session", nil}, {"transaction", :unnamed}] do
      with_runtime_env(%{"POOL_SIZE" => "10", "STORE_DB_POOL_MODE" => mode}, fn config ->
        assert_topology(config, mode)
        assert Keyword.get(primary_repo(config), :prepare) == expected_prepare
      end)
    end
  end

  defp with_runtime_env(overrides, fun, options \\ []) do
    evaluate? = Keyword.get(options, :evaluate, true)
    changed = Map.merge(@test_env, overrides)
    previous = Map.new(@runtime_env_keys, &{&1, System.get_env(&1)})

    try do
      Enum.each(changed, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      config = if evaluate?, do: production_config!(), else: nil

      if is_function(fun, 0), do: fun.(), else: fun.(config)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp production_config! do
    root = Path.expand("../../..", __DIR__)
    base = Config.Reader.read!(Path.join(root, "config/config.exs"), env: :prod, target: :host)

    runtime =
      Config.Reader.read!(Path.join(root, "config/runtime.exs"), env: :prod, target: :host)

    Config.Reader.merge(base, runtime)
  end

  defp queue_limit(config),
    do:
      config
      |> Keyword.fetch!(:store)
      |> Keyword.fetch!(Oban)
      |> Keyword.fetch!(:queues)
      |> Keyword.fetch!(:subscriptions)

  defp other_queue(config, queue),
    do:
      config
      |> Keyword.fetch!(:store)
      |> Keyword.fetch!(Oban)
      |> Keyword.fetch!(:queues)
      |> Keyword.fetch!(queue)

  defp primary_repo(config), do: config |> Keyword.fetch!(:store) |> Keyword.fetch!(Store.Repo)
  defp primary_pool_size(config), do: Keyword.fetch!(primary_repo(config), :pool_size)

  defp assert_topology(config, mode) do
    store = Keyword.fetch!(config, :store)
    assert Keyword.fetch!(store, :database_pool_mode) == mode

    assert Keyword.has_key?(Keyword.fetch!(store, Store.Repo), :prepare) ==
             (mode == "transaction")

    refute Keyword.has_key?(Keyword.fetch!(store, Store.DirectRepo), :prepare)
  end
end
