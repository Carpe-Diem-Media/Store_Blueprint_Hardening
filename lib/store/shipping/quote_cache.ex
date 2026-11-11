defmodule Store.Shipping.QuoteCache do
  @moduledoc """
  Revision-fenced Shipping quote cache with Cachex hot storage and Redis warm storage.

  PostgreSQL revision reads define the authority point for each quote. Cache keys
  include that revision; Cachex and Redis values are projections only. PubSub
  removes superseded local generations as a cleanup optimization.
  """

  import Cachex.Spec

  alias Store.Repo
  alias Store.Shipping.ConfigRevision
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Support.Errors.Error
  alias Store.Support.Governance.Idempotency
  alias Store.Support.Redis

  @cache_ttl_ms :timer.seconds(45)
  @warm_ttl_seconds 900
  @topic "store:shipping:quote_cache"
  @max_revision_attempts 2

  @type validity :: nil | {:before, DateTime.t()} | {:through, DateTime.t()}
  @type cache_metadata :: %{cache: String.t(), layer: String.t(), request_key: String.t()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {Supervisor, :start_link, [children(), [strategy: :one_for_one, name: supervisor_name()]]}
    }
  end

  @spec fetch(QuoteRequest.t(), (DateTime.t() -> term()), keyword()) ::
          {:ok, [term()], cache_metadata()} | {:error, Error.t()}
  def fetch(%QuoteRequest{} = request, fallback, opts \\ [])
      when is_function(fallback, 1) and is_list(opts) do
    deps = dependencies(opts)
    request_key = request_key(request)

    case safe_call(deps.in_transaction?, []) do
      true -> fetch_transactional(request, request_key, fallback, deps, 0)
      false -> fetch_revision(request, request_key, fallback, deps, 0)
      _other -> authority_unavailable()
    end
  end

  @spec invalidate_all_local() :: :ok
  def invalidate_all_local do
    case Cachex.clear(__MODULE__) do
      {:ok, _count} -> :ok
      _ -> :ok
    end
  end

  @spec invalidate_all(String.t() | nil) :: :ok
  def invalidate_all(reason \\ nil) do
    # Do not publish an uncommitted revision. A rollback could reuse that
    # number and a delayed message would otherwise evict the restored generation.
    if Repo.in_transaction?() do
      :ok
    else
      case ConfigRevision.read() do
        {:ok, revision} ->
          message =
            {:invalidate_all, __MODULE__, reason,
             DateTime.utc_now() |> DateTime.truncate(:microsecond), revision}

          _ = handle_invalidation_message(message)
          _ = Phoenix.PubSub.broadcast(Store.PubSub, @topic, message)

        {:error, _error} ->
          :ok
      end
    end

    :ok
  end

  @doc false
  @spec handle_invalidation_message(term()) :: :ok
  def handle_invalidation_message({:invalidate_all, __MODULE__, _reason, _occurred_at, revision})
      when is_integer(revision) and revision > 0 do
    discard_local_through(revision)
    :ok
  end

  # Older nodes may still publish the unversioned message. It is intentionally
  # ignored because it cannot distinguish a late event from a newer generation.
  def handle_invalidation_message({:invalidate_all, __MODULE__, _reason, _occurred_at}), do: :ok

  def handle_invalidation_message(_message), do: :ok

  @spec request_key(QuoteRequest.t()) :: String.t()
  def request_key(%QuoteRequest{} = request) do
    payload = %{
      country: request.destination_country_code,
      region: request.destination_region_code,
      postal: request.destination_postal_code,
      currency: request.currency_code,
      weight: request.shipping_weight_grams
    }

    "v1:" <> Idempotency.payload_hash(payload)
  end

  defp dependencies(opts) do
    %{
      read_revision: Keyword.get(opts, :revision_reader, &ConfigRevision.read/0),
      in_transaction?: Keyword.get(opts, :in_transaction?, &Repo.in_transaction?/0),
      clock: Keyword.get(opts, :clock, &current_time/0),
      redis_get: Keyword.get(opts, :redis_get, &Redis.term_get/1),
      redis_put: Keyword.get(opts, :redis_put, &Redis.term_put/3)
    }
  end

  # Transaction-local quote data must never enter Cachex or Redis. A sandbox
  # rollback restores the durable revision, so a cached value from the rolled
  # back generation could otherwise become reachable under a reused revision.
  defp fetch_transactional(request, request_key, fallback, deps, attempt) do
    case load_transactional_value(fallback, deps) do
      {:ok, value} ->
        {:ok, value, metadata("miss", "cold", request_key)}

      {:retry, _reason} ->
        retry_transactional_or_error(request, request_key, fallback, deps, attempt)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp retry_transactional_or_error(_request, _request_key, _fallback, _deps, attempt)
       when attempt + 1 >= @max_revision_attempts do
    {:error, internal_error("shipping configuration changed during quote calculation")}
  end

  defp retry_transactional_or_error(request, request_key, fallback, deps, attempt) do
    fetch_transactional(request, request_key, fallback, deps, attempt + 1)
  end

  defp load_transactional_value(fallback, deps) do
    now = deps.clock.()

    with {:ok, revision} <- read_revision(deps),
         {:ok, envelope} <- compute_value(revision, fallback, now),
         :ok <- ensure_temporally_current(envelope, deps.clock.()),
         {:ok, ^revision} <- read_revision(deps),
         :ok <- ensure_temporally_current(envelope, deps.clock.()) do
      {:ok, envelope.value}
    else
      {:ok, current_revision} when is_integer(current_revision) ->
        {:retry, {:revision_changed, current_revision}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :temporal_boundary} ->
        {:retry, :temporal_boundary}
    end
  end

  defp fetch_revision(request, request_key, fallback, deps, attempt) do
    case safe_call(deps.read_revision, []) do
      {:ok, revision} when is_integer(revision) and revision > 0 ->
        fetch_generation(request, request_key, fallback, deps, revision, attempt)

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        authority_unavailable()
    end
  end

  defp fetch_generation(request, request_key, fallback, deps, revision, attempt) do
    key = cache_key(revision, request_key)
    initial_now = deps.clock.()

    case Cachex.get(__MODULE__, key) do
      {:ok, envelope} when is_map(envelope) ->
        if valid_envelope?(envelope, revision, initial_now) and
             valid_envelope?(envelope, revision, deps.clock.()) do
          {:ok, envelope.value, metadata("hit", "hot", request_key)}
        else
          _ = Cachex.del(__MODULE__, key)
          fetch_miss(request, key, revision, request_key, fallback, deps, attempt)
        end

      {:ok, nil} ->
        fetch_miss(request, key, revision, request_key, fallback, deps, attempt)

      {:ok, _unexpected} ->
        _ = Cachex.del(__MODULE__, key)
        fetch_miss(request, key, revision, request_key, fallback, deps, attempt)

      {:error, _reason} ->
        fetch_uncached(request, revision, request_key, fallback, deps, attempt)
    end
  end

  defp fetch_miss(request, key, revision, request_key, fallback, deps, attempt) do
    fetch_result =
      Cachex.fetch(
        __MODULE__,
        key,
        fn _key -> cache_fetch_value(revision, request_key, fallback, deps) end,
        []
      )

    handle_cache_fetch_result(
      fetch_result,
      request,
      revision,
      request_key,
      fallback,
      deps,
      attempt
    )
  end

  defp cache_fetch_value(revision, request_key, fallback, deps) do
    case load_and_verify(revision, request_key, fallback, deps) do
      {:ok, envelope} ->
        {:commit, envelope, expire: cache_expiration(envelope.validity, deps.clock.())}

      {:retry, reason} ->
        {:ignore, {:retry, reason}}

      {:error, error} ->
        {:ignore, {:error, error}}
    end
  end

  defp handle_cache_fetch_result(
         result,
         request,
         revision,
         request_key,
         fallback,
         deps,
         attempt
       ) do
    case result do
      {:commit, envelope} when is_map(envelope) ->
        response_from_envelope(envelope, revision, request_key, deps, "miss")
        |> finish_response(request, request_key, fallback, deps, attempt)

      {:ok, envelope} when is_map(envelope) ->
        response_from_envelope(envelope, revision, request_key, deps, "hit")
        |> finish_response(request, request_key, fallback, deps, attempt)

      {:ignore, {:retry, _reason}} ->
        retry_or_error(request, request_key, fallback, deps, attempt)

      {:ignore, {:error, %Error{} = error}} ->
        {:error, error}

      {:error, _reason} ->
        fetch_uncached(request, revision, request_key, fallback, deps, attempt)

      _other ->
        fetch_uncached(request, revision, request_key, fallback, deps, attempt)
    end
  end

  defp finish_response({:retry, _reason}, request, request_key, fallback, deps, attempt),
    do: retry_or_error(request, request_key, fallback, deps, attempt)

  defp finish_response(result, _request, _request_key, _fallback, _deps, _attempt), do: result

  defp response_from_envelope(envelope, revision, request_key, deps, cache_status) do
    if valid_envelope?(envelope, revision, deps.clock.()) do
      layer = if cache_status == "hit", do: "hot", else: Atom.to_string(envelope.source_layer)
      {:ok, envelope.value, metadata(cache_status, layer, request_key)}
    else
      _ = Cachex.del(__MODULE__, cache_key(revision, request_key))
      {:retry, :temporal_boundary}
    end
  end

  defp fetch_uncached(request, revision, request_key, fallback, deps, attempt) do
    case load_and_verify(revision, request_key, fallback, deps) do
      {:ok, envelope} ->
        {:ok, envelope.value,
         metadata("miss", Atom.to_string(envelope.source_layer), request_key)}

      {:retry, _reason} ->
        retry_or_error(request, request_key, fallback, deps, attempt)

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_and_verify(revision, request_key, fallback, deps) do
    now = deps.clock.()

    with {:ok, envelope} <- load_value(revision, request_key, fallback, deps, now),
         :ok <- ensure_temporally_current(envelope, deps.clock.()),
         {:ok, ^revision} <- read_revision(deps),
         :ok <- ensure_temporally_current(envelope, deps.clock.()) do
      if envelope.source_layer == :cold do
        _ = write_warm(revision, request_key, envelope, deps, deps.clock.())
      end

      case ensure_temporally_current(envelope, deps.clock.()) do
        :ok -> {:ok, envelope}
        {:error, :temporal_boundary} -> {:retry, :temporal_boundary}
      end
    else
      {:ok, current_revision} when is_integer(current_revision) ->
        if current_revision == revision,
          do: {:retry, :temporal_boundary},
          else: {:retry, :revision_changed}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :temporal_boundary} ->
        {:retry, :temporal_boundary}
    end
  end

  defp load_value(revision, request_key, fallback, deps, now) do
    case safe_call(deps.redis_get, [redis_key(revision, request_key)]) do
      {:ok, {:hit, envelope}} when is_map(envelope) ->
        if valid_envelope?(envelope, revision, now) do
          {:ok, %{envelope | source_layer: :warm}}
        else
          compute_value(revision, fallback, now)
        end

      _miss_or_failure ->
        compute_value(revision, fallback, now)
    end
  end

  defp compute_value(revision, fallback, now) do
    case safe_call(fallback, [now]) do
      {:ok, value, validity} when is_list(value) ->
        {:ok,
         %{
           revision: revision,
           value: value,
           validity: validity,
           source_layer: :cold
         }}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        {:error, internal_error("unable to calculate shipping quote")}
    end
  end

  defp read_revision(deps) do
    case safe_call(deps.read_revision, []) do
      {:ok, revision} when is_integer(revision) and revision > 0 -> {:ok, revision}
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, authority_unavailable() |> elem(1)}
    end
  end

  defp ensure_temporally_current(envelope, now) do
    if valid_envelope?(envelope, envelope.revision, now),
      do: :ok,
      else: {:error, :temporal_boundary}
  end

  defp retry_or_error(_request, _request_key, _fallback, _deps, attempt)
       when attempt + 1 >= @max_revision_attempts do
    {:error, internal_error("shipping configuration changed during quote calculation")}
  end

  defp retry_or_error(request, request_key, fallback, deps, attempt) do
    fetch_revision(request, request_key, fallback, deps, attempt + 1)
  end

  defp valid_envelope?(
         %{revision: revision, value: value, validity: validity, source_layer: layer},
         expected_revision,
         %DateTime{} = now
       )
       when revision == expected_revision and is_list(value) and layer in [:cold, :warm] do
    valid_time?(validity, now)
  end

  defp valid_envelope?(_envelope, _expected_revision, _now), do: false

  defp valid_time?(nil, _now), do: true

  defp valid_time?({:before, %DateTime{} = boundary}, %DateTime{} = now),
    do: DateTime.compare(now, boundary) == :lt

  defp valid_time?({:through, %DateTime{} = boundary}, %DateTime{} = now),
    do: DateTime.compare(now, boundary) in [:lt, :eq]

  defp valid_time?(_validity, _now), do: false

  defp cache_expiration(validity, now) do
    validity
    |> remaining_milliseconds(now)
    |> min(@cache_ttl_ms)
    |> max(1)
  end

  defp remaining_milliseconds(nil, _now), do: @cache_ttl_ms

  defp remaining_milliseconds({_kind, %DateTime{} = boundary}, %DateTime{} = now) do
    max(DateTime.diff(boundary, now, :millisecond), 1)
  end

  defp remaining_milliseconds(_validity, _now), do: @cache_ttl_ms

  defp write_warm(revision, request_key, envelope, deps, now) do
    ttl =
      envelope.validity
      |> remaining_seconds(now)
      |> min(@warm_ttl_seconds)
      |> max(1)

    safe_call(deps.redis_put, [redis_key(revision, request_key), envelope, ttl])
  end

  defp remaining_seconds(nil, _now), do: @warm_ttl_seconds

  defp remaining_seconds({_kind, %DateTime{} = boundary}, %DateTime{} = now) do
    microseconds = DateTime.diff(boundary, now, :microsecond)
    max(div(microseconds + 999_999, 1_000_000), 1)
  end

  defp remaining_seconds(_validity, _now), do: @warm_ttl_seconds

  defp discard_local_through(revision) do
    case Cachex.keys(__MODULE__) do
      {:ok, keys} ->
        keys
        |> Enum.filter(&(cached_revision(&1) < revision))
        |> Enum.each(fn key -> _ = Cachex.del(__MODULE__, key) end)

      _ ->
        :ok
    end
  end

  defp cached_revision("v2:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [revision, _request_key] ->
        case Integer.parse(revision) do
          {revision, ""} -> revision
          _ -> -1
        end

      _ ->
        -1
    end
  end

  defp cached_revision(_key), do: -1

  defp safe_call(fun, args) do
    apply(fun, args)
  rescue
    _error -> {:error, internal_error("shipping quote cache operation failed")}
  catch
    :exit, _reason -> {:error, internal_error("shipping quote cache operation failed")}
  end

  defp metadata(cache, layer, request_key),
    do: %{cache: cache, layer: layer, request_key: request_key}

  defp authority_unavailable,
    do: {:error, internal_error("shipping configuration revision is unavailable")}

  defp internal_error(message), do: Error.new("INTERNAL_ERROR", message)

  defp cache_key(revision, request_key), do: "v2:#{revision}:#{request_key}"
  defp redis_prefix, do: "cache:shipping:quote"
  defp redis_key(revision, key), do: "#{redis_prefix()}:v2:#{revision}:#{key}"
  defp current_time, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp supervisor_name, do: Module.concat(__MODULE__, Supervisor)

  defp children do
    [
      %{
        id: Module.concat(__MODULE__, Cachex),
        start:
          {Cachex, :start_link,
           [
             __MODULE__,
             [
               expiration:
                 expiration(
                   default: @cache_ttl_ms,
                   interval: :timer.seconds(15),
                   lazy: true
                 )
             ]
           ]}
      },
      %{
        id: Module.concat(__MODULE__, Subscriber),
        start: {Task, :start_link, [fn -> subscriber_loop() end]}
      }
    ]
  end

  defp subscriber_loop do
    Phoenix.PubSub.subscribe(Store.PubSub, @topic)

    receive do
      message ->
        _ = handle_invalidation_message(message)
        subscriber_loop()
    end
  end
end
