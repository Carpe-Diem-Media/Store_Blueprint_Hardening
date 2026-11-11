defmodule Store.Shipping.DomainTest do
  use Store.DataCase, async: false

  alias Store.Shipping
  alias Store.Shipping.Inputs.QuoteRequest

  alias Store.Shipping.{
    ConfigRevision,
    QuoteCache,
    ShippingMethod,
    ShippingRateRule,
    ShippingZone
  }

  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.Redis

  test "same quote request returns stable option ordering and hashes" do
    zone = create_zone!("US", "CA")
    method_alpha = create_method!("ALPHA", "Alpha")
    method_beta = create_method!("BETA", "Beta")
    method_gamma = create_method!("GAMMA", "Gamma")

    _rule_alpha_1 = create_rule!(zone.id, method_alpha.id, 500)
    _rule_alpha_2 = create_rule!(zone.id, method_alpha.id, 500)
    _rule_beta = create_rule!(zone.id, method_beta.id, 500)
    _rule_gamma = create_rule!(zone.id, method_gamma.id, 900)

    request =
      quote_request!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, options_first} = quote_options(request)
    assert {:ok, options_second} = quote_options(request)

    assert options_second == options_first

    assert Enum.map(options_first, & &1.quote_hash) ==
             Enum.map(options_second, & &1.quote_hash)

    assert Enum.map(options_first, &{&1.amount_minor, &1.shipping_method_code}) == [
             {500, "ALPHA"},
             {500, "ALPHA"},
             {500, "BETA"},
             {900, "GAMMA"}
           ]

    alpha_rule_ids =
      options_first
      |> Enum.filter(&(&1.shipping_method_code == "ALPHA"))
      |> Enum.map(& &1.shipping_rule_id)

    assert alpha_rule_ids == BinaryUuidSort.sort_uuids(alpha_rule_ids)
  end

  test "quote_options emits cold then hot cache telemetry" do
    zone = create_zone!("ZA", "GP")
    method = create_method!("GROUND", "Ground")
    _rule = create_rule!(zone.id, method.id, 750)

    request =
      quote_request!(%{
        destination_country_code: "ZA",
        destination_region_code: "GP",
        destination_postal_code: "2000",
        currency_code: "USD",
        shipping_weight_grams: 500
      })

    parent = self()
    request_key = QuoteCache.request_key(request)
    handler_id = {__MODULE__, :shipping_quote, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:store, :shipping, :quote],
      fn _event, measurements, metadata, pid ->
        if metadata[:request_key] == request_key do
          send(pid, {:shipping_quote, measurements, metadata})
        end
      end,
      parent
    )

    try do
      assert {:ok, [_option]} = quote_options(request)
      assert {:ok, [_option]} = quote_options(request)

      assert_receive {:shipping_quote, first_measurements, first_metadata}
      assert_receive {:shipping_quote, second_measurements, second_metadata}

      assert first_metadata.cache == "miss"
      assert first_metadata.layer == "cold"
      assert first_metadata.result == :ok
      assert is_binary(first_metadata.request_key)
      assert first_measurements.result_count == 1

      assert second_metadata.cache == "hit"
      assert second_metadata.layer == "hot"
      assert second_metadata.result == :ok
      assert second_metadata.request_key == first_metadata.request_key
      assert second_measurements.result_count == 1
    after
      :telemetry.detach(handler_id)
    end
  end

  test "direct Ash mutation advances the quote generation before the next cache hit" do
    zone = create_zone!("ZA", "WC")
    method = create_method!("FREIGHT", "Freight")
    rule = create_rule!(zone.id, method.id, 700)
    request = quote_request!(quote_attrs("ZA", "WC", 10))

    assert {:ok, [%{amount_minor: 700}]} = quote_options(request)

    assert {:ok, _updated_rule} =
             rule
             |> Ash.Changeset.for_update(
               :update,
               %{shipping_cost_minor: 1_100},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Shipping,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, [%{amount_minor: 1_100}]} = quote_options(request)
  end

  test "transaction-local quote data cannot leak through a rolled back revision" do
    request = quote_request!(quote_attrs("ZA", "NC", 15))
    starting_revision = revision!()

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               zone = create_zone!("ZA", "NC")
               method = create_method!("ROLLBACK", "Rollback")
               _rule = create_rule!(zone.id, method.id, 2_050)

               assert {:ok, revision} = ConfigRevision.read()
               assert revision > starting_revision
               assert {:ok, [_option]} = Shipping.quote_options(request)

               request_key = QuoteCache.request_key(request)
               hot_key = "v2:#{revision}:#{request_key}"
               warm_key = Redis.key("cache:shipping:quote:v2:#{revision}:#{request_key}")

               assert {:ok, nil} = Cachex.get(QuoteCache, hot_key)
               assert {:ok, :miss} = Redis.term_get(warm_key)

               Repo.rollback(:rolled_back)
             end)

    assert revision!() == starting_revision
    assert {:ok, []} = quote_options(request)
  end

  test "explicit as_of requests do not reuse a quote from another evaluation time" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    starts_at = DateTime.add(now, 60, :second)
    zone = create_zone!("US", "NY")
    method = create_method!("FUTURE", "Future")
    _rule = create_rule!(zone.id, method.id, 950, starts_at: starts_at)
    request = quote_request!(quote_attrs("US", "NY", 20))

    before_start = DateTime.add(starts_at, -1, :second)

    assert {:ok, []} = quote_options(request, as_of: before_start)
    assert {:ok, [%{amount_minor: 950}]} = quote_options(request, as_of: starts_at)
  end

  test "rule end remains eligible at equality and expires immediately after" do
    ends_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    zone = create_zone!("CA", "ON")
    method = create_method!("EXPIRING", "Expiring")
    _rule = create_rule!(zone.id, method.id, 1_200, ends_at: ends_at)
    request = quote_request!(quote_attrs("CA", "ON", 30))

    assert {:ok, [%{amount_minor: 1_200}]} = quote_options(request, as_of: ends_at)

    assert {:ok, []} =
             quote_options(request, as_of: DateTime.add(ends_at, 1, :microsecond))
  end

  test "cached future rule activates at its exact starts_at boundary" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    starts_at = DateTime.add(now, 60, :second)
    zone = create_zone!("GB", "ENG")
    method = create_method!("SCHEDULED", "Scheduled")
    _rule = create_rule!(zone.id, method.id, 1_450, starts_at: starts_at)
    request = quote_request!(quote_attrs("GB", "ENG", 40))

    with_clock(now, fn clock, set_time ->
      assert {:ok, []} = quote_options(request, clock: clock)
      set_time.(starts_at)
      assert {:ok, [%{amount_minor: 1_450}]} = quote_options(request, clock: clock)
    end)
  end

  test "cached rule remains eligible at ends_at equality and expires after it" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    ends_at = DateTime.add(now, 60, :second)
    zone = create_zone!("AU", "NSW")
    method = create_method!("TEMPORARY", "Temporary")
    _rule = create_rule!(zone.id, method.id, 1_600, ends_at: ends_at)
    request = quote_request!(quote_attrs("AU", "NSW", 50))

    with_clock(now, fn clock, set_time ->
      assert {:ok, [%{amount_minor: 1_600}]} = quote_options(request, clock: clock)
      set_time.(ends_at)
      assert {:ok, [%{amount_minor: 1_600}]} = quote_options(request, clock: clock)
      set_time.(DateTime.add(ends_at, 1, :microsecond))
      assert {:ok, []} = quote_options(request, clock: clock)
    end)
  end

  test "transaction-local quote is rechecked if a rule boundary passes during revision validation" do
    boundary = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.add(1, :second)
    initial_time = DateTime.add(boundary, -1, :microsecond)
    {:ok, clock_state} = Agent.start_link(fn -> initial_time end)
    {:ok, revision_reads} = Agent.start_link(fn -> 0 end)
    {:ok, fallback_calls} = Agent.start_link(fn -> 0 end)
    request = quote_request!(quote_attrs("ZA", "NC", 72))

    dependencies = [
      in_transaction?: fn -> true end,
      clock: fn -> Agent.get(clock_state, & &1) end,
      revision_reader: fn ->
        Agent.get_and_update(revision_reads, fn
          1 ->
            Agent.update(clock_state, fn _ -> DateTime.add(boundary, 1, :microsecond) end)
            {{:ok, 101}, 2}

          count ->
            {{:ok, 101}, count + 1}
        end)
      end
    ]

    assert {:ok, [:active_rule], %{cache: "miss", layer: "cold"}} =
             QuoteCache.fetch(
               request,
               fn now ->
                 Agent.update(fallback_calls, &(&1 + 1))

                 if DateTime.compare(now, boundary) == :lt do
                   {:ok, [], {:before, boundary}}
                 else
                   {:ok, [:active_rule], nil}
                 end
               end,
               dependencies
             )

    assert Agent.get(fallback_calls, & &1) == 2
  end

  test "hot quote is rejected when its temporal boundary passes after the cache read" do
    boundary = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.add(1, :second)
    before_boundary = DateTime.add(boundary, -1, :microsecond)
    after_boundary = DateTime.add(boundary, 1, :microsecond)
    {:ok, clock_reads} = Agent.start_link(fn -> 0 end)
    request = quote_request!(quote_attrs("ZA", "NC", 73))
    request_key = QuoteCache.request_key(request)
    hot_key = "v2:103:#{request_key}"

    assert {:ok, true} =
             Cachex.put(QuoteCache, hot_key, %{
               revision: 103,
               value: [:before_boundary],
               validity: {:before, boundary},
               source_layer: :cold
             })

    dependencies = [
      in_transaction?: fn -> false end,
      revision_reader: fn -> {:ok, 103} end,
      clock: fn ->
        Agent.get_and_update(clock_reads, fn
          0 -> {before_boundary, 1}
          count -> {after_boundary, count + 1}
        end)
      end,
      redis_get: fn _key -> {:ok, :miss} end,
      redis_put: fn _key, _value, _ttl -> :ok end
    ]

    assert {:ok, [:after_boundary], %{cache: "miss"}} =
             QuoteCache.fetch(
               request,
               fn now ->
                 assert DateTime.compare(now, boundary) == :gt
                 {:ok, [:after_boundary], nil}
               end,
               dependencies
             )
  end

  test "a delayed legacy PubSub invalidation preserves the current generation" do
    zone = create_zone!("NZ", "AUK")
    method = create_method!("LOCAL", "Local")
    _rule = create_rule!(zone.id, method.id, 1_750)
    request = quote_request!(quote_attrs("NZ", "AUK", 60))

    assert {:ok, options} = quote_options(request)

    message =
      {:invalidate_all, QuoteCache, "delayed",
       DateTime.utc_now() |> DateTime.truncate(:microsecond)}

    assert :ok = QuoteCache.handle_invalidation_message(message)

    assert {:ok, revision} = ConfigRevision.read()

    assert :ok =
             QuoteCache.handle_invalidation_message(
               {:invalidate_all, QuoteCache, "older-generation", DateTime.utc_now(), revision - 1}
             )

    assert :ok =
             QuoteCache.handle_invalidation_message(
               {:invalidate_all, QuoteCache, "current-generation", DateTime.utc_now(), revision}
             )

    assert {:ok, ^options, %{cache: "hit", layer: "hot"}} =
             fetch_quote(request, fn _now ->
               flunk("current generation should remain cached")
             end)
  end

  test "revision authority failure never serves a populated hot value" do
    request = quote_request!(quote_attrs("ZA", "NC", 70))

    dependencies = [
      revision_reader: fn -> {:ok, 91} end,
      redis_get: fn _key -> {:error, :redis_unavailable} end,
      redis_put: fn _key, _value, _ttl -> {:error, :redis_unavailable} end
    ]

    assert {:ok, [:trusted_at_revision_91], %{cache: "miss"}} =
             fetch_quote(
               request,
               fn _now -> {:ok, [:trusted_at_revision_91], nil} end,
               dependencies
             )

    assert {:error, %Store.Support.Errors.Error{code: "INTERNAL_ERROR"}} =
             fetch_quote(
               request,
               fn _now -> flunk("a failed revision read must not reach the fallback") end,
               Keyword.put(dependencies, :revision_reader, fn ->
                 {:error, :database_unavailable}
               end)
             )
  end

  test "unversioned Cachex entries are not trusted" do
    request = quote_request!(quote_attrs("ZA", "NW", 75))
    assert {:ok, true} = Cachex.put(QuoteCache, QuoteCache.request_key(request), [:legacy_value])

    assert :ok =
             Redis.term_put(
               "cache:shipping:quote:#{QuoteCache.request_key(request)}",
               [:legacy_warm_value],
               900
             )

    assert {:ok, [:revisioned_value], %{cache: "miss"}} =
             fetch_quote(
               request,
               fn _now -> {:ok, [:revisioned_value], nil} end,
               revision_reader: fn -> {:ok, 93} end,
               redis_put: fn _key, _value, _ttl -> :ok end
             )
  end

  test "an in-flight warm result from a superseded revision is discarded" do
    request = quote_request!(quote_attrs("ZA", "EC", 80))
    {:ok, revision_state} = Agent.start_link(fn -> 1 end)
    {:ok, warm_reads} = Agent.start_link(fn -> 0 end)

    dependencies = [
      revision_reader: fn -> {:ok, Agent.get(revision_state, & &1)} end,
      redis_get: fn _key ->
        Agent.get_and_update(warm_reads, fn
          0 ->
            Agent.update(revision_state, fn _ -> 2 end)

            {{:ok,
              {:hit, %{revision: 1, value: [:superseded], validity: nil, source_layer: :cold}}},
             1}

          count ->
            {{:ok, :miss}, count + 1}
        end)
      end,
      redis_put: fn _key, _value, _ttl -> :ok end
    ]

    assert {:ok, [:revision_2_value], %{cache: "miss"}} =
             fetch_quote(
               request,
               fn _now -> {:ok, [:revision_2_value], nil} end,
               dependencies
             )
  end

  test "a committed revision change during database refill gets one bounded retry" do
    request = quote_request!(quote_attrs("ZA", "FS", 90))
    {:ok, revision_state} = Agent.start_link(fn -> 1 end)
    {:ok, fallback_calls} = Agent.start_link(fn -> 0 end)

    dependencies = [
      revision_reader: fn -> {:ok, Agent.get(revision_state, & &1)} end,
      redis_get: fn _key -> {:ok, :miss} end,
      redis_put: fn _key, _value, _ttl -> :ok end
    ]

    assert {:ok, [:revision_2_value], _metadata} =
             fetch_quote(
               request,
               fn _now ->
                 count = Agent.get_and_update(fallback_calls, &{&1, &1 + 1})
                 if count == 0, do: Agent.update(revision_state, fn _ -> 2 end)
                 {:ok, [if(count == 0, do: :superseded, else: :revision_2_value)], nil}
               end,
               dependencies
             )

    assert Agent.get(fallback_calls, & &1) == 2
  end

  test "quote database reads stay bounded as eligible rule count grows" do
    zone = create_zone!("ZA", "LP")
    method = create_method!("MEASURED", "Measured")
    _rule = create_rule!(zone.id, method.id, 1_850)
    Enum.each(1..19, fn _index -> create_rule!(zone.id, method.id, 1_850) end)
    request = quote_request!(quote_attrs("ZA", "LP", 100))

    {cold_result, cold_queries} = observe_repo_queries(fn -> quote_options(request) end)

    assert {:ok, options} = cold_result
    assert length(options) == 20
    assert cold_queries == 5

    assert {:ok, _count} = Cachex.clear(QuoteCache)

    {warm_result, warm_queries} = observe_repo_queries(fn -> quote_options(request) end)

    assert {:ok, options} = warm_result
    assert length(options) == 20
    assert warm_queries == 2

    assert {:ok, options} = quote_options(request)
    assert length(options) == 20

    {result, hot_queries} = observe_repo_queries(fn -> quote_options(request) end)

    assert {:ok, options} = result
    assert length(options) == 20
    assert hot_queries == 1
  end

  test "hot and warm quote projections retain their existing TTL limits" do
    zone = create_zone!("ZA", "GP")
    method = create_method!("TTL", "TTL")
    _rule = create_rule!(zone.id, method.id, 1_900)
    request = quote_request!(quote_attrs("ZA", "GP", 110))

    assert {:ok, [_option]} = quote_options(request)
    assert {:ok, revision} = ConfigRevision.read()

    request_key = QuoteCache.request_key(request)
    hot_key = "v2:#{revision}:#{request_key}"
    warm_key = Redis.key("cache:shipping:quote:v2:#{revision}:#{request_key}")

    assert {:ok, hot_ttl_ms} = Cachex.ttl(QuoteCache, hot_key)
    assert hot_ttl_ms > 0 and hot_ttl_ms <= :timer.seconds(45)

    assert {:ok, warm_ttl_seconds} = Redis.command(["TTL", warm_key])
    assert warm_ttl_seconds > 0 and warm_ttl_seconds <= 900
  end

  defp quote_request!(attrs) do
    unique = Ecto.UUID.generate()

    attrs =
      Map.update!(attrs, :destination_postal_code, fn postal ->
        "#{postal}-#{unique}"
      end)

    {:ok, request} = QuoteRequest.new(attrs)
    request
  end

  defp quote_options(request, opts \\ []) do
    Shipping.quote_options(request, Keyword.put_new(opts, :repo_in_transaction?, fn -> false end))
  end

  defp fetch_quote(request, fallback, opts \\ []) do
    QuoteCache.fetch(request, fallback, Keyword.put_new(opts, :in_transaction?, fn -> false end))
  end

  defp revision! do
    {:ok, revision} = ConfigRevision.read()
    revision
  end

  defp quote_attrs(country, region, weight) do
    %{
      destination_country_code: country,
      destination_region_code: region,
      destination_postal_code: "TEST",
      currency_code: "USD",
      shipping_weight_grams: weight
    }
  end

  defp with_clock(initial_time, callback) do
    {:ok, clock_state} = Agent.start_link(fn -> initial_time end)
    clock = fn -> Agent.get(clock_state, & &1) end
    set_time = fn time -> Agent.update(clock_state, fn _ -> time end) end

    try do
      callback.(clock, set_time)
    after
      Agent.stop(clock_state)
    end
  end

  defp observe_repo_queries(fun) do
    parent = self()
    handler_id = {__MODULE__, :shipping_perf_query, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:store, :repo, :query],
      fn _event, _measurements, metadata, pid ->
        send(pid, {:shipping_perf_query, metadata[:query]})
      end,
      parent
    )

    try do
      result = fun.()

      {result, collect_repo_queries(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_repo_queries(count) do
    receive do
      {:shipping_perf_query, _query} -> collect_repo_queries(count + 1)
    after
      0 -> count
    end
  end

  defp create_zone!(country_code, region_code) do
    code = "ZONE_#{System.unique_integer([:positive])}"

    ShippingZone
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, country_code: country_code, region_code: region_code, active: true},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_method!(code, name) do
    ShippingMethod
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, name: name, active: true, sort_order: 100},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_rule!(shipping_zone_id, shipping_method_id, shipping_cost_minor, opts \\ []) do
    code = "RULE_#{System.unique_integer([:positive])}"

    ShippingRateRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: code,
        shipping_zone_id: shipping_zone_id,
        shipping_method_id: shipping_method_id,
        currency: "USD",
        shipping_cost_minor: shipping_cost_minor,
        active: true,
        precedence_rank: 10
      }
      |> Map.merge(Map.new(opts)),
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end
end
