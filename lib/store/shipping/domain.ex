defmodule Store.Shipping do
  @moduledoc """
  Shipping domain for persisted methods/rules and deterministic quote options.
  """

  use Ash.Domain

  import Ash.Expr
  require Ash.Query

  alias Store.Shipping.Inputs.QuoteRequest

  alias Store.Shipping.Queries.{
    AdminShippingMethodsQuery,
    AdminShippingRateRulesQuery,
    AdminShippingZonesQuery
  }

  alias Store.Shipping.{QuoteCache, QuoteHash, ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Shipping.Types.{QuoteEvidence, QuoteOption}
  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  resources do
    resource(Store.Shipping.ShippingZone)
    resource(Store.Shipping.ShippingMethod)
    resource(Store.Shipping.ShippingRateRule)
  end

  @spec list_shipping_zones_for_admin(AdminShippingZonesQuery.t(), map()) ::
          {:ok, [ShippingZone.t()]} | {:error, term()}
  def list_shipping_zones_for_admin(%AdminShippingZonesQuery{limit: limit}, actor)
      when is_map(actor) do
    ShippingZone
    |> Ash.Query.for_read(:admin_index, %{limit: limit}, actor: actor)
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_shipping_zone_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, ShippingZone.t() | nil} | {:error, term()}
  def get_shipping_zone_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    ShippingZone
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec list_shipping_methods_for_admin(AdminShippingMethodsQuery.t(), map()) ::
          {:ok, [ShippingMethod.t()]} | {:error, term()}
  def list_shipping_methods_for_admin(%AdminShippingMethodsQuery{limit: limit}, actor)
      when is_map(actor) do
    ShippingMethod
    |> Ash.Query.for_read(:admin_index, %{limit: limit}, actor: actor)
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_shipping_method_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, ShippingMethod.t() | nil} | {:error, term()}
  def get_shipping_method_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    ShippingMethod
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec list_shipping_rate_rules_for_admin(AdminShippingRateRulesQuery.t(), map()) ::
          {:ok, [ShippingRateRule.t()]} | {:error, term()}
  def list_shipping_rate_rules_for_admin(
        %AdminShippingRateRulesQuery{
          limit: limit,
          shipping_zone_id: shipping_zone_id,
          shipping_method_id: shipping_method_id
        },
        actor
      )
      when is_map(actor) do
    ShippingRateRule
    |> Ash.Query.for_read(
      :admin_index,
      %{
        limit: limit,
        shipping_zone_id: shipping_zone_id,
        shipping_method_id: shipping_method_id
      },
      actor: actor
    )
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_shipping_rate_rule_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, ShippingRateRule.t() | nil} | {:error, term()}
  def get_shipping_rate_rule_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    ShippingRateRule
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec quote_options(QuoteRequest.t(), keyword()) ::
          {:ok, [QuoteOption.t()]} | {:error, Error.t()}
  def quote_options(request, opts \\ [])

  def quote_options(%QuoteRequest{} = request, opts) when is_list(opts) do
    started_at = System.monotonic_time()

    with {:ok, options, cache_metadata} <- quote_result(request, opts) do
      emit_quote_telemetry(started_at, options, cache_metadata)
      {:ok, options}
    end
  end

  def quote_options(_request, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "quote request is required")}
  end

  defp quote_result(request, opts) do
    case Keyword.fetch(opts, :as_of) do
      {:ok, %DateTime{} = as_of} ->
        quote_options_at(request, as_of)

      {:ok, _invalid_as_of} ->
        {:error, Error.new("VALIDATION_ERROR", "quote evaluation time is invalid")}

      :error ->
        quote_options_current(request, opts)
    end
  end

  defp quote_options_at(request, as_of) do
    with {:ok, options, _validity} <- quote_options_from_db(request, as_of) do
      {:ok, options,
       %{cache: "miss", layer: "cold", request_key: QuoteCache.request_key(request)}}
    end
  end

  defp quote_options_current(request, opts) do
    clock = Keyword.get(opts, :clock, &current_quote_time/0)

    if is_function(clock, 0) do
      QuoteCache.fetch(request, fn now -> quote_options_from_db(request, now) end,
        clock: clock,
        in_transaction?: Keyword.get(opts, :repo_in_transaction?, &Store.Repo.in_transaction?/0)
      )
    else
      {:error, Error.new("VALIDATION_ERROR", "quote clock is invalid")}
    end
  end

  defp quote_options_from_db(request, now) do
    query =
      ShippingRateRule
      |> Ash.Query.filter(expr(currency == ^request.currency_code and active == true))
      |> Ash.Query.load([:shipping_zone, :shipping_method])

    case Ash.read(query, domain: __MODULE__, authorize?: false, context: %{system?: true}) do
      {:ok, rules} ->
        candidates = Enum.filter(rules, &static_eligible_rule?(&1, request))

        options =
          candidates
          |> Enum.filter(&active_window?(&1.starts_at, &1.ends_at, now))
          |> Enum.map(&to_quote_option(&1, request))
          |> Enum.sort_by(&quote_option_sort_tuple/1)

        {:ok, options, next_eligibility_boundary(candidates, now)}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read shipping quote rules")}
    end
  end

  defp static_eligible_rule?(%ShippingRateRule{} = rule, %QuoteRequest{} = request) do
    zone = Map.get(rule, :shipping_zone)
    method = Map.get(rule, :shipping_method)

    method_active? = match?(%ShippingMethod{active: true}, method)

    method_active? and
      zone_eligible?(zone, request) and
      weight_eligible?(
        rule.weight_min_grams,
        rule.weight_max_grams,
        request.shipping_weight_grams
      )
  end

  defp active_window?(nil, nil, _now), do: true

  defp active_window?(starts_at, nil, now) when is_struct(starts_at, DateTime),
    do: DateTime.compare(starts_at, now) in [:lt, :eq]

  defp active_window?(nil, ends_at, now) when is_struct(ends_at, DateTime),
    do: DateTime.compare(now, ends_at) in [:lt, :eq]

  defp active_window?(starts_at, ends_at, now)
       when is_struct(starts_at, DateTime) and is_struct(ends_at, DateTime) do
    DateTime.compare(starts_at, now) in [:lt, :eq] and
      DateTime.compare(now, ends_at) in [:lt, :eq]
  end

  defp active_window?(_starts_at, _ends_at, _now), do: false

  defp next_eligibility_boundary(candidates, %DateTime{} = now) do
    candidates
    |> Enum.flat_map(&rule_boundaries(&1, now))
    |> Enum.reduce(nil, &earlier_boundary/2)
  end

  defp rule_boundaries(%ShippingRateRule{starts_at: starts_at, ends_at: ends_at}, now) do
    if valid_rule_interval?(starts_at, ends_at) do
      start_boundary =
        if match?(%DateTime{}, starts_at) and DateTime.compare(starts_at, now) == :gt do
          [{:before, starts_at}]
        else
          []
        end

      end_boundary =
        if match?(%DateTime{}, ends_at) and DateTime.compare(now, ends_at) in [:lt, :eq] do
          [{:through, ends_at}]
        else
          []
        end

      start_boundary ++ end_boundary
    else
      []
    end
  end

  defp valid_rule_interval?(starts_at, ends_at) do
    case {starts_at, ends_at} do
      {%DateTime{} = start, %DateTime{} = finish} -> DateTime.compare(start, finish) != :gt
      _ -> true
    end
  end

  defp earlier_boundary(candidate, nil), do: candidate

  defp earlier_boundary(
         {candidate_kind, candidate_at} = candidate,
         {current_kind, current_at} = current
       ) do
    case DateTime.compare(candidate_at, current_at) do
      :lt ->
        candidate

      :gt ->
        current

      :eq ->
        if boundary_rank(candidate_kind) < boundary_rank(current_kind),
          do: candidate,
          else: current
    end
  end

  defp boundary_rank(:before), do: 0
  defp boundary_rank(:through), do: 1

  defp zone_eligible?(nil, _request), do: true

  defp zone_eligible?(%ShippingZone{active: true} = zone, %QuoteRequest{} = request) do
    country_ok = zone.country_code == request.destination_country_code
    region_ok = is_nil(zone.region_code) or zone.region_code == request.destination_region_code
    country_ok and region_ok
  end

  defp zone_eligible?(_zone, _request), do: false

  defp weight_eligible?(nil, nil, _weight_grams), do: true

  defp weight_eligible?(min_grams, nil, weight_grams) when is_integer(min_grams),
    do: weight_grams >= min_grams

  defp weight_eligible?(nil, max_grams, weight_grams) when is_integer(max_grams),
    do: weight_grams <= max_grams

  defp weight_eligible?(min_grams, max_grams, weight_grams)
       when is_integer(min_grams) and is_integer(max_grams) do
    weight_grams >= min_grams and weight_grams <= max_grams
  end

  defp weight_eligible?(_min_grams, _max_grams, _weight_grams), do: false

  defp to_quote_option(%ShippingRateRule{} = rule, %QuoteRequest{} = request) do
    method = Map.fetch!(rule, :shipping_method)
    zone = Map.get(rule, :shipping_zone)

    evidence =
      %QuoteEvidence{
        currency_code: request.currency_code,
        amount_minor: Kernel.max(rule.shipping_cost_minor || 0, 0),
        shipping_weight_grams: request.shipping_weight_grams,
        destination_country_code: request.destination_country_code,
        destination_region_code: request.destination_region_code,
        destination_postal_code: request.destination_postal_code,
        shipping_method_code: method.code,
        shipping_rule_id: rule.id,
        zone_id: zone && zone.id,
        effective_from: rule.starts_at,
        effective_to: rule.ends_at
      }

    %QuoteOption{
      quote_hash: QuoteHash.hash_evidence(evidence),
      currency_code: evidence.currency_code,
      amount_minor: evidence.amount_minor,
      shipping_weight_grams: evidence.shipping_weight_grams,
      destination_country_code: evidence.destination_country_code,
      destination_region_code: evidence.destination_region_code,
      destination_postal_code: evidence.destination_postal_code,
      shipping_method_code: evidence.shipping_method_code,
      shipping_rule_id: evidence.shipping_rule_id,
      zone_id: evidence.zone_id,
      effective_from: evidence.effective_from,
      effective_to: evidence.effective_to,
      label: method.name
    }
  end

  defp quote_option_sort_tuple(%QuoteOption{} = option) do
    {
      option.amount_minor,
      option.shipping_method_code,
      uuid_sort_key(option.shipping_rule_id),
      uuid_sort_key(option.zone_id)
    }
  end

  defp uuid_sort_key(nil), do: {0, <<>>}

  defp uuid_sort_key(uuid) when is_binary(uuid) do
    {1, BinaryUuidSort.normalize_raw16!(uuid)}
  end

  defp emit_quote_telemetry(started_at, options, cache_metadata)
       when is_integer(started_at) and is_list(options) and is_map(cache_metadata) do
    :telemetry.execute(
      [:store, :shipping, :quote],
      %{
        duration: System.monotonic_time() - started_at,
        result_count: length(options)
      },
      %{
        cache: Map.get(cache_metadata, :cache, "miss"),
        layer: Map.get(cache_metadata, :layer, "cold"),
        result: :ok,
        request_key: Map.get(cache_metadata, :request_key)
      }
    )
  end

  defp current_quote_time, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
