defmodule Store.Orders do
  @moduledoc """
  Orders domain for lifecycle state-machine resources and inventory reservations.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Orders.{
    InventoryReservation,
    InventoryReservations,
    Order,
    SnapshotWriter,
    TaxShippingSnapshotWriter
  }

  alias Store.Payments.PaymentIntent
  alias Store.Pricing.Contract
  alias Store.Repo
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.Error
  alias Store.Support.Governance.Idempotency
  alias Store.Support.ID.OrderRef
  alias Store.Support.ID.UUIDv7

  @max_order_ref_attempts 5
  @default_pending_provider_setup_ttl_seconds 15 * 60
  @default_pending_provider_setup_batch_size 200

  resources do
    resource(Store.Orders.Order)
    resource(Store.Orders.OrderLineItem)
    resource(Store.Orders.OrderLineComponentAllocationSet)
    resource(Store.Orders.OrderLineComponentAllocation)
    resource(Store.Orders.OrderAdjustment)
    resource(Store.Orders.RefundAdjustment)
    resource(Store.Orders.InventoryReservation)
    resource(Store.Orders.PaymentApplication)
  end

  json_api do
    prefix("/api/v1")
    show_raised_errors?(false)

    routes do
      base_route("/orders", Order) do
        index(:read_for_user, derive_filter?: false, derive_sort?: false)
        get(:get_for_user, derive_filter?: false, derive_sort?: false)
      end

      base_route("/admin/orders", Order) do
        index(:read_for_admin, derive_filter?: false, derive_sort?: false)
        get(:get_for_admin, derive_filter?: false, derive_sort?: false)
      end
    end
  end

  @type begin_checkout_attrs :: %{
          required(:line_items) => [map()],
          required(:currency) => String.t(),
          required(:as_of) => DateTime.t() | String.t(),
          optional(:user_id) => String.t(),
          optional(:checkout_scope) => String.t(),
          optional(:pricing_contract_version) => String.t(),
          optional(:tax_shipping_inputs) => map()
        }

  @spec create_order(map(), keyword()) :: {:ok, Order.t()} | {:error, term()}
  def create_order(attrs \\ %{}, opts \\ []) when is_map(attrs) and is_list(opts) do
    generator = Keyword.get(opts, :order_ref_generator, &OrderRef.generate/0)
    max_attempts = Keyword.get(opts, :max_attempts, @max_order_ref_attempts)
    ash_opts = Keyword.drop(opts, [:order_ref_generator, :max_attempts])

    do_create_order(attrs, generator, ash_opts, max_attempts)
  end

  @spec begin_checkout(begin_checkout_attrs(), keyword()) ::
          {:ok,
           %{
             order: Order.t(),
             checkout_key: String.t(),
             cart_fingerprint: String.t(),
             duplicate?: boolean(),
             notifications: [Ash.Notifier.Notification.t()]
           }}
          | {:error, Error.t() | term()}
  def begin_checkout(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    return_notifications? = Keyword.get(opts, :return_notifications?, false)
    generator = Keyword.get(opts, :order_ref_generator, &OrderRef.generate/0)
    max_attempts = Keyword.get(opts, :max_attempts, @max_order_ref_attempts)

    ash_opts =
      Keyword.drop(opts, [
        :pricing_contract_version,
        :return_notifications?,
        :order_ref_generator,
        :max_attempts
      ])

    with {:ok, request} <- normalize_begin_checkout_request(attrs, opts),
         cart_fingerprint <-
           Idempotency.cart_fingerprint(
             request.line_items,
             request.currency,
             request.as_of,
             request.pricing_contract_version,
             request.tax_shipping_inputs
           ),
         checkout_key <-
           Idempotency.checkout_key(
             request.user_id,
             cart_fingerprint,
             request.checkout_scope
           ),
         {:ok, order, duplicate?, notifications} <-
           create_or_reuse_checkout_order(
             request,
             checkout_key,
             ash_opts,
             return_notifications?,
             generator,
             max_attempts
           ) do
      {:ok,
       %{
         order: order,
         checkout_key: checkout_key,
         cart_fingerprint: cart_fingerprint,
         duplicate?: duplicate?,
         notifications: notifications
       }}
    end
  rescue
    error in ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", Exception.message(error))}
  end

  @spec write_priced_snapshot(String.t(), Contract.Output.t() | map(), keyword()) ::
          {:ok,
           %{
             line_items: [Store.Orders.OrderLineItem.t()],
             adjustments: [Store.Orders.OrderAdjustment.t()]
           }}
          | {:error, term()}
  def write_priced_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    SnapshotWriter.write_priced_snapshot(order_id, output, opts)
  end

  @spec write_tax_shipping_snapshot(
          String.t(),
          Store.Pricing.TaxShippingContract.Output.t() | map(),
          keyword()
        ) ::
          {:ok, %{order: Store.Orders.Order.t(), idempotent?: boolean()}} | {:error, term()}
  def write_tax_shipping_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    TaxShippingSnapshotWriter.write_tax_shipping_snapshot(order_id, output, opts)
  end

  @spec reserve_inventory(String.t(), [map()], keyword()) ::
          {:ok,
           %{
             reservations: [InventoryReservation.t()],
             inventory_items: [Store.Catalog.InventoryItem.t()]
           }}
          | {:error, term()}
  def reserve_inventory(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    InventoryReservations.reserve_inventory(order_id, items, opts)
  end

  @spec reserve_inventory_for_checkout(String.t(), [map()], keyword()) ::
          {:ok, %{reserved_rows: [map()]}} | {:error, term()}
  def reserve_inventory_for_checkout(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    InventoryReservations.reserve_inventory_for_checkout(order_id, items, opts)
  end

  @spec invalidate_inventory_availability_for_variants([String.t()]) :: :ok
  def invalidate_inventory_availability_for_variants(variant_ids) when is_list(variant_ids) do
    InventoryReservations.invalidate_variant_availability_for_variants(variant_ids)
  end

  @spec reserve_exact_generation(String.t(), String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok,
           %{
             reservation: InventoryReservation.t(),
             inventory_item: Store.Catalog.InventoryItem.t(),
             replayed?: boolean()
           }}
          | {:error, Error.t() | :ambiguous_database_outcome | :invalid_identity}
  def reserve_exact_generation(order_id, variant_id, reservation_key, quantity, opts \\ [])
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_integer(quantity) and is_list(opts) do
    if quantity > 0 do
      InventoryReservations.reserve_exact_generation(
        order_id,
        variant_id,
        reservation_key,
        quantity,
        opts
      )
    else
      {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact reservation input", %{})}
    end
  end

  @spec recover_exact_generation(String.t(), String.t(), String.t()) ::
          :not_found
          | {:ok, {:found, map()}}
          | {:error, :contradictory_evidence | :database_unavailable | :invalid_identity}
  def recover_exact_generation(order_id, variant_id, reservation_key)
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) do
    InventoryReservations.recover_exact_generation(order_id, variant_id, reservation_key)
  end

  @spec guard_exact_generation(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()}
          | {:error,
             :transaction_required
             | :invalid_identity
             | :not_found
             | :contradictory_evidence
             | :quantity_mismatch
             | :not_active
             | :database_unavailable}
  def guard_exact_generation(order_id, variant_id, reservation_key, required_quantity)
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_integer(required_quantity) and required_quantity > 0 do
    InventoryReservations.guard_exact_generation(
      order_id,
      variant_id,
      reservation_key,
      required_quantity
    )
  end

  def guard_exact_generation(_order_id, _variant_id, _reservation_key, _required_quantity),
    do: {:error, :invalid_identity}

  @spec release_exact_generation(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{reservation: InventoryReservation.t() | nil, changed?: boolean()}}
          | {:error, Error.t() | :ambiguous_database_outcome | :invalid_identity}
  def release_exact_generation(order_id, variant_id, reservation_key, opts \\ [])
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_list(opts) do
    InventoryReservations.release_exact_generation(order_id, variant_id, reservation_key, opts)
  end

  @spec consume_exact_generation(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{reservation: InventoryReservation.t() | nil, changed?: boolean()}}
          | {:error, Error.t() | :ambiguous_database_outcome | :invalid_identity}
  def consume_exact_generation(order_id, variant_id, reservation_key, opts \\ [])
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_list(opts) do
    InventoryReservations.consume_exact_generation(order_id, variant_id, reservation_key, opts)
  end

  @spec settle_exact_generation_in_caller_transaction(
          String.t(),
          String.t(),
          String.t(),
          :consume | :release,
          keyword()
        ) ::
          {:ok, %{reservation: InventoryReservation.t() | nil, changed?: boolean()}}
          | {:error, term()}
  def settle_exact_generation_in_caller_transaction(
        order_id,
        variant_id,
        reservation_key,
        action,
        opts \\ []
      )
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             action in [:consume, :release] and is_list(opts) do
    InventoryReservations.settle_exact_generation_in_caller_transaction(
      order_id,
      variant_id,
      reservation_key,
      action,
      opts
    )
  end

  @spec consume_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{consumed_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def consume_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    InventoryReservations.consume_reservations_for_order(order_id, opts)
  end

  @spec settle_withdrawn_renewal_reservations_for_payment(String.t()) ::
          {:ok, %{consumed_count: 0, reservations: []}} | {:error, term()}
  @doc false
  def settle_withdrawn_renewal_reservations_for_payment(order_id) when is_binary(order_id) do
    InventoryReservations.settle_withdrawn_renewal_reservations_for_payment(order_id)
  end

  @spec release_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{released_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def release_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    InventoryReservations.release_reservations_for_order(order_id, opts)
  end

  @spec expire_reservations(DateTime.t(), keyword()) ::
          {:ok, %{expired_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def expire_reservations(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    InventoryReservations.expire_reservations(now, opts)
  end

  @spec sweep_stale_pending_provider_setup(DateTime.t(), keyword()) ::
          {:ok,
           %{
             swept_count: non_neg_integer(),
             released_count: non_neg_integer(),
             order_ids: [String.t()]
           }}
          | {:error, term()}
  def sweep_stale_pending_provider_setup(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    ttl_seconds =
      Keyword.get(opts, :ttl_seconds, pending_provider_setup_ttl_seconds())

    batch_size = Keyword.get(opts, :batch_size, pending_provider_setup_batch_size())
    cutoff = DateTime.add(DateTime.truncate(now, :microsecond), -ttl_seconds, :second)

    stale_pending_provider_setup_orders(cutoff, batch_size)
    |> Enum.reduce_while(
      {:ok, %{swept_count: 0, released_count: 0, order_ids: [], notifications: []}},
      &sweep_pending_provider_setup_order(&1, &2, now)
    )
    |> finalize_pending_provider_setup_sweep_notifications()
  end

  @spec pending_provider_setup_backlog_snapshot(DateTime.t(), keyword()) ::
          %{
            count: non_neg_integer(),
            oldest_age_seconds: non_neg_integer(),
            newest_age_seconds: non_neg_integer(),
            distinct_order_count: non_neg_integer(),
            reserved_variant_count: non_neg_integer(),
            without_provider_refs_count: non_neg_integer(),
            recoverable_created_intent_count: non_neg_integer()
          }
  def pending_provider_setup_backlog_snapshot(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    now = DateTime.truncate(now, :microsecond)

    stats =
      Repo.one(
        from(order in Order,
          where:
            order.state == ^:pending_provider_setup and
              not is_nil(order.provider_setup_started_at),
          select: %{
            count: count(order.id),
            distinct_order_count: count(order.id, :distinct),
            oldest_started_at: min(order.provider_setup_started_at),
            newest_started_at: max(order.provider_setup_started_at)
          }
        )
      ) || %{}

    snapshot = %{
      count: Map.get(stats, :count, 0),
      oldest_age_seconds: started_at_age_seconds(Map.get(stats, :oldest_started_at), now),
      newest_age_seconds: started_at_age_seconds(Map.get(stats, :newest_started_at), now),
      distinct_order_count: Map.get(stats, :distinct_order_count, 0),
      reserved_variant_count: pending_provider_reserved_variant_count(),
      without_provider_refs_count: pending_provider_without_refs_count(),
      recoverable_created_intent_count: pending_provider_recoverable_created_intent_count()
    }

    if Keyword.get(opts, :emit_telemetry?, true) do
      :telemetry.execute(
        [:store, :checkout, :pending_provider_setup, :backlog],
        snapshot,
        %{source: Keyword.get(opts, :source, :snapshot)}
      )
    end

    snapshot
  end

  @spec order_topic(String.t()) :: String.t()
  def order_topic(order_id) when is_binary(order_id), do: "store:orders:#{order_id}"

  defp do_create_order(_attrs, _generator, _ash_opts, attempts) when attempts <= 0 do
    {:error, "unable to generate unique order_ref after retry limit"}
  end

  defp do_create_order(attrs, generator, ash_opts, attempts) do
    attrs_with_order_ref =
      if explicit_order_ref?(attrs) do
        attrs
      else
        Map.put(attrs, :order_ref, generator.())
      end

    result =
      Order
      |> Ash.Changeset.for_create(:create, attrs_with_order_ref)
      |> Ash.create(Keyword.merge([domain: __MODULE__, authorize?: false], ash_opts))

    cond do
      retryable_order_ref_conflict?(result, attrs) and attempts > 1 ->
        do_create_order(attrs, generator, ash_opts, attempts - 1)

      retryable_order_ref_conflict?(result, attrs) ->
        {:error, "unable to generate unique order_ref after retry limit"}

      true ->
        result
    end
  end

  defp retryable_order_ref_conflict?({:error, error}, attrs) do
    not explicit_order_ref?(attrs) and order_ref_conflict?(error)
  end

  defp retryable_order_ref_conflict?(_, _attrs), do: false

  defp explicit_order_ref?(attrs),
    do: Map.has_key?(attrs, :order_ref) or Map.has_key?(attrs, "order_ref")

  defp normalize_begin_checkout_request(attrs, opts) do
    request = %{
      user_id: attr(attrs, :user_id),
      checkout_scope: attr(attrs, :checkout_scope),
      line_items: attr(attrs, :line_items, []),
      currency: attr(attrs, :currency),
      as_of: attr(attrs, :as_of),
      pricing_contract_version:
        attr(attrs, :pricing_contract_version, Keyword.get(opts, :pricing_contract_version, "v1")),
      tax_shipping_inputs: attr(attrs, :tax_shipping_inputs, %{})
    }

    with :ok <- validate_user_id(request.user_id),
         :ok <- validate_checkout_scope(request.checkout_scope),
         :ok <- validate_line_items(request.line_items),
         :ok <- require_binary(request.currency, "currency is required"),
         :ok <- validate_as_of(request.as_of),
         :ok <-
           require_binary(
             request.pricing_contract_version,
             "pricing_contract_version must be a string"
           ),
         :ok <- require_map(request.tax_shipping_inputs, "tax_shipping_inputs must be a map") do
      {:ok, request}
    end
  end

  defp create_or_reuse_checkout_order(
         request,
         checkout_key,
         ash_opts,
         return_notifications?,
         generator,
         max_attempts
       ) do
    with {:ok, existing_order} <- find_order_by_checkout_key(checkout_key, ash_opts) do
      case existing_order do
        %Order{state: state} = order when state in [:pending_payment, :pending_provider_setup] ->
          {:ok, order, true, []}

        %Order{} ->
          {:error,
           Error.new(
             "CHECKOUT_DUPLICATE",
             "checkout key already used for a non-pending order"
           )}

        nil ->
          create_checkout_order(
            request.user_id,
            checkout_key,
            ash_opts,
            return_notifications?,
            generator,
            max_attempts
          )
      end
    end
  end

  defp create_checkout_order(
         _user_id,
         _checkout_key,
         _ash_opts,
         _return_notifications?,
         _generator,
         attempts
       )
       when attempts <= 0 do
    {:error, Error.new("INTERNAL_ERROR", "unable to generate unique order_ref after retry limit")}
  end

  defp create_checkout_order(
         user_id,
         checkout_key,
         ash_opts,
         return_notifications?,
         generator,
         attempts
       ) do
    create_attrs = %{user_id: user_id, checkout_key: checkout_key, order_ref: generator.()}

    create_ash_opts =
      if return_notifications? do
        Keyword.put(ash_opts, :return_notifications?, true)
      else
        ash_opts
      end

    Order
    |> Ash.Changeset.for_create(:begin_checkout, create_attrs, context: %{system?: true})
    |> Ash.create(checkout_ash_opts(create_ash_opts))
    |> unwrap_checkout_order_create_result(
      user_id,
      checkout_key,
      ash_opts,
      return_notifications?,
      generator,
      attempts
    )
  end

  defp find_order_by_checkout_key(checkout_key, ash_opts) do
    query = Order |> Ash.Query.filter(expr(checkout_key == ^checkout_key))

    case Ash.read(query, checkout_ash_opts(ash_opts)) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp checkout_ash_opts(ash_opts) do
    context =
      ash_opts
      |> Keyword.get(:context, %{})
      |> Map.put_new(:system?, true)

    ash_opts
    |> Keyword.put(:domain, __MODULE__)
    |> Keyword.put(:authorize?, false)
    |> Keyword.put(:context, context)
  end

  defp validate_user_id(nil), do: :ok

  defp validate_user_id(user_id) when is_binary(user_id) do
    if UUIDv7.valid?(user_id) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "user_id must be a valid UUID")}
    end
  end

  defp validate_user_id(_user_id),
    do: {:error, Error.new("VALIDATION_ERROR", "user_id must be a UUID string")}

  defp validate_line_items(line_items) when is_list(line_items) do
    if line_items == [] do
      {:error, Error.new("VALIDATION_ERROR", "line_items must not be empty")}
    else
      validate_line_items_list(line_items)
    end
  end

  defp validate_line_items(_line_items),
    do: {:error, Error.new("VALIDATION_ERROR", "line_items must be a list")}

  defp validate_line_items_list(line_items) do
    Enum.reduce_while(line_items, :ok, &validate_line_item_step/2)
  end

  defp validate_line_item_step(line_item, :ok) do
    case validate_line_item_fields(line_item) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp validate_line_item_fields(line_item) do
    case validate_line_item_id(line_item) do
      :ok -> validate_line_item_quantity(line_item)
      {:error, _} = error -> error
    end
  end

  defp validate_line_item_id(line_item) when is_map(line_item) do
    id =
      Map.get(line_item, :variant_id) ||
        Map.get(line_item, "variant_id") ||
        Map.get(line_item, :sku_id) ||
        Map.get(line_item, "sku_id")

    if is_binary(id) and UUIDv7.valid?(id) do
      :ok
    else
      {:error,
       Error.new("VALIDATION_ERROR", "each line item requires valid UUID variant_id or sku_id")}
    end
  end

  defp validate_line_item_id(_line_item) do
    {:error, Error.new("VALIDATION_ERROR", "each line item must be a map")}
  end

  defp validate_line_item_quantity(line_item) when is_map(line_item) do
    quantity = Map.get(line_item, :quantity) || Map.get(line_item, "quantity")

    if is_integer(quantity) and quantity > 0 do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "line item quantity must be a positive integer")}
    end
  end

  defp validate_line_item_quantity(_line_item) do
    {:error, Error.new("VALIDATION_ERROR", "line item quantity must be a positive integer")}
  end

  defp validate_as_of(%DateTime{}), do: :ok
  defp validate_as_of(as_of) when is_binary(as_of), do: :ok
  defp validate_as_of(_as_of), do: {:error, Error.new("VALIDATION_ERROR", "as_of is required")}

  defp validate_checkout_scope(nil), do: :ok
  defp validate_checkout_scope(scope) when is_binary(scope), do: :ok

  defp validate_checkout_scope(_scope),
    do: {:error, Error.new("VALIDATION_ERROR", "checkout_scope must be a string")}

  defp require_binary(value, _message) when is_binary(value), do: :ok
  defp require_binary(_value, message), do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp require_map(value, _message) when is_map(value), do: :ok
  defp require_map(_value, message), do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp order_ref_conflict?(error) do
    message = Exception.message(error)
    String.contains?(message, "order_ref") and String.contains?(message, "already been taken")
  end

  defp stale_pending_provider_setup_orders(cutoff, batch_size) do
    Order
    |> where(
      [order],
      order.state == ^:pending_provider_setup and
        not is_nil(order.provider_setup_started_at) and
        order.provider_setup_started_at <= ^cutoff
    )
    |> order_by([order], asc: order.provider_setup_started_at, asc: order.id)
    |> limit(^batch_size)
    |> Repo.all()
  end

  defp sweep_pending_provider_setup_order(
         %Order{id: order_id} = order,
         {:ok, acc},
         now
       ) do
    case cancel_stale_pending_provider_setup(order, now) do
      {:ok, %{released_count: released_count, notifications: notifications}} ->
        {:cont,
         {:ok,
          %{
            swept_count: acc.swept_count + 1,
            released_count: acc.released_count + released_count,
            order_ids: [order_id | acc.order_ids],
            notifications: [notifications | acc.notifications]
          }}}

      {:skip, _reason} ->
        {:cont, {:ok, acc}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp cancel_stale_pending_provider_setup(%Order{id: order_id}, now) do
    cancel_stale_pending_provider_setup_transaction(order_id, now)
  end

  defp pending_provider_setup_ttl_seconds do
    Application.get_env(:store, :payments, [])
    |> Keyword.get(
      :provider_setup_ttl_seconds,
      env_positive_integer(
        "STORE_PROVIDER_SETUP_TTL_SECONDS",
        @default_pending_provider_setup_ttl_seconds
      )
    )
  end

  defp pending_provider_setup_batch_size do
    env_positive_integer(
      "STORE_PROVIDER_SETUP_SWEEP_BATCH_SIZE",
      @default_pending_provider_setup_batch_size
    )
  end

  defp unwrap_checkout_order_create_result(
         {:ok, %Order{state: state} = order},
         _user_id,
         _checkout_key,
         _ash_opts,
         _return_notifications?,
         _generator,
         _attempts
       )
       when state in [:pending_payment, :pending_provider_setup],
       do: {:ok, order, false, []}

  defp unwrap_checkout_order_create_result(
         {:ok, %Order{state: state} = order, notifications},
         _user_id,
         _checkout_key,
         _ash_opts,
         _return_notifications?,
         _generator,
         _attempts
       )
       when state in [:pending_payment, :pending_provider_setup] and is_list(notifications),
       do: {:ok, order, false, notifications}

  defp unwrap_checkout_order_create_result(
         {:ok, %Order{}},
         _user_id,
         _checkout_key,
         _ash_opts,
         _return_notifications?,
         _generator,
         _attempts
       ) do
    {:error,
     Error.new("CHECKOUT_DUPLICATE", "checkout key did not resolve to pending_payment state")}
  end

  defp unwrap_checkout_order_create_result(
         {:ok, %Order{}, _notifications},
         _user_id,
         _checkout_key,
         _ash_opts,
         _return_notifications?,
         _generator,
         _attempts
       ) do
    {:error,
     Error.new("CHECKOUT_DUPLICATE", "checkout key did not resolve to pending_payment state")}
  end

  defp unwrap_checkout_order_create_result(
         {:error, error},
         user_id,
         checkout_key,
         ash_opts,
         return_notifications?,
         generator,
         attempts
       ) do
    if order_ref_conflict?(error) and attempts > 1 do
      create_checkout_order(
        user_id,
        checkout_key,
        ash_opts,
        return_notifications?,
        generator,
        attempts - 1
      )
    else
      {:error, error}
    end
  end

  defp cancel_stale_pending_provider_setup_transaction(order_id, now) do
    Repo.transaction(fn ->
      case locked_pending_provider_setup_order(order_id) do
        nil ->
          Repo.rollback(:skip)

        %Order{} = locked_order ->
          maybe_cancel_locked_pending_provider_setup(locked_order, now)
      end
    end)
  end

  defp locked_pending_provider_setup_order(order_id) do
    Repo.one(
      from(order in Order,
        where: order.id == ^order_id and order.state == ^:pending_provider_setup,
        lock: "FOR UPDATE"
      )
    )
  end

  defp maybe_cancel_locked_pending_provider_setup(%Order{} = locked_order, now) do
    with {:ok, release_result} <-
           InventoryReservations.release_reservations_for_order(locked_order.id, now: now),
         {:ok, _cancelled_order, notifications} <-
           cancel_pending_provider_setup_order(locked_order) do
      %{released_count: release_result.released_count, notifications: notifications}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_pending_provider_setup_order(%Order{} = order) do
    order
    |> Ash.Changeset.for_update(:cancel, %{}, context: %{system?: true})
    |> Ash.update(
      domain: __MODULE__,
      authorize?: false,
      return_notifications?: true,
      context: %{system?: true}
    )
  end

  defp finalize_pending_provider_setup_sweep_notifications(
         {:ok, %{notifications: notifications} = result}
       ) do
    ordered_order_ids = Enum.reverse(result.order_ids)
    batched_notifications = notifications |> Enum.reverse() |> List.flatten()

    case AshNotifications.notify_post_commit(
           batched_notifications,
           context: %{flow: :expire_pending_provider_setup, order_ids: ordered_order_ids}
         ) do
      :ok ->
        Enum.each(ordered_order_ids, fn order_id ->
          notify_order_state_change(order_id, :cancelled, :pending_provider_setup_expired)
        end)

        {:ok,
         result
         |> Map.put(:order_ids, ordered_order_ids)
         |> Map.delete(:notifications)}

      other ->
        {:error, other}
    end
  end

  defp finalize_pending_provider_setup_sweep_notifications({:skip, reason}),
    do: {:skip, reason}

  defp finalize_pending_provider_setup_sweep_notifications({:error, reason}),
    do: {:error, reason}

  @spec notify_order_state_change(String.t(), atom(), atom()) :: :ok
  def notify_order_state_change(order_id, state, reason)
      when is_binary(order_id) and is_atom(state) and is_atom(reason) do
    Phoenix.PubSub.broadcast(
      Store.PubSub,
      order_topic(order_id),
      {:order_state_changed, order_id, state, reason,
       DateTime.utc_now() |> DateTime.truncate(:microsecond)}
    )

    :ok
  end

  defp pending_provider_reserved_variant_count do
    Repo.one(
      from(reservation in InventoryReservation,
        join: order in Order,
        on: order.id == reservation.order_id,
        where:
          order.state == ^:pending_provider_setup and
            reservation.state == ^:active,
        select: count(reservation.variant_id, :distinct)
      )
    ) || 0
  end

  defp pending_provider_without_refs_count do
    Repo.one(
      from(order in Order,
        left_join: payment_intent in PaymentIntent,
        on: payment_intent.order_id == order.id,
        where: ^pending_provider_without_refs_dynamic(),
        select: count(order.id, :distinct)
      )
    ) || 0
  end

  defp pending_provider_recoverable_created_intent_count do
    Repo.one(
      from(order in Order,
        join: payment_intent in PaymentIntent,
        on: payment_intent.order_id == order.id,
        where: ^pending_provider_recoverable_created_dynamic(),
        select: count(order.id, :distinct)
      )
    ) || 0
  end

  defp pending_provider_without_refs_dynamic do
    dynamic(
      [order, payment_intent],
      order.state == ^:pending_provider_setup and
        not is_nil(order.provider_setup_started_at) and
        is_nil(payment_intent.provider_session_id) and
        is_nil(payment_intent.provider_payment_id) and
        is_nil(payment_intent.provider_customer_ref) and
        is_nil(payment_intent.provider_payment_method_ref) and
        is_nil(payment_intent.provider_checkout_url) and
        is_nil(payment_intent.provider_client_secret)
    )
  end

  defp pending_provider_recoverable_created_dynamic do
    dynamic(
      [order, payment_intent],
      order.state == ^:pending_provider_setup and
        not is_nil(order.provider_setup_started_at) and
        payment_intent.state == ^:created and
        (not is_nil(payment_intent.provider_session_id) or
           not is_nil(payment_intent.provider_payment_id) or
           not is_nil(payment_intent.provider_customer_ref) or
           not is_nil(payment_intent.provider_payment_method_ref) or
           not is_nil(payment_intent.provider_checkout_url) or
           not is_nil(payment_intent.provider_client_secret))
    )
  end

  defp started_at_age_seconds(nil, _now), do: 0

  defp started_at_age_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    Kernel.max(DateTime.diff(now, started_at, :second), 0)
  end

  defp env_positive_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end
end
