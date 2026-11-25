defmodule Store.Fulfillment do
  @moduledoc """
  Fulfillment domain for physical post-payment operational flows.
  """

  use Ash.Domain

  import Ash.Expr

  require Ash.Query

  alias Store.Fulfillment.{FulfillmentItem, FulfillmentOrder, Queries, Shipment}
  alias Store.Orders.{Order, OrderAdjustment, OrderLineItem}
  alias Store.Support.Errors.Error

  resources do
    resource(Store.Fulfillment.FulfillmentOrder)
    resource(Store.Fulfillment.Shipment)
    resource(Store.Fulfillment.FulfillmentItem)
  end

  @type ensure_result ::
          {:ok, %{fulfillment_order: FulfillmentOrder.t(), idempotent?: boolean()}}
          | {:error, Error.t() | term()}

  @spec list_fulfillment_orders_for_admin(Queries.AdminFulfillmentQueueQuery.t(), map()) ::
          {:ok, Ash.Page.Keyset.t()} | {:error, term()}
  def list_fulfillment_orders_for_admin(
        %Queries.AdminFulfillmentQueueQuery{
          limit: limit,
          after: after_cursor,
          before: before_cursor,
          state: state
        },
        actor
      )
      when is_map(actor) do
    FulfillmentOrder
    |> Ash.Query.for_read(:admin_queue, %{state: state}, actor: actor)
    |> Ash.Query.select([:id, :order_id, :state, :shipping_method_code, :inserted_at])
    |> Ash.Query.page(fulfillment_page_opts(limit, after_cursor, before_cursor))
    |> Ash.read(domain: __MODULE__, actor: actor)
  end

  @spec get_fulfillment_order_for_admin(Queries.AdminFulfillmentShowQuery.t(), map()) ::
          {:ok, FulfillmentOrder.t() | nil} | {:error, term()}
  def get_fulfillment_order_for_admin(%Queries.AdminFulfillmentShowQuery{id: id}, actor)
      when is_map(actor) do
    FulfillmentOrder
    |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)
    |> Ash.Query.load([:shipments, :items])
    |> Ash.read_one(domain: __MODULE__, actor: actor)
  end

  @spec ensure_fulfillment_for_paid_order(String.t(), keyword()) :: ensure_result()
  def ensure_fulfillment_for_paid_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    with {:ok, order} <- fetch_order(order_id),
         :ok <- ensure_paid(order),
         :ok <- ensure_totals_finalized(order),
         :ok <- ensure_shipping_adjustment_present(order.id),
         {:ok, fulfillment_order, idempotent?} <- get_or_create_fulfillment_order(order),
         {:ok, _items} <- ensure_fulfillment_items(fulfillment_order, order.id),
         {:ok, _shipment} <- ensure_initial_shipment(fulfillment_order) do
      {:ok, %{fulfillment_order: fulfillment_order, idempotent?: idempotent?}}
    end
  end

  @spec mark_packed(String.t(), map()) :: {:ok, FulfillmentOrder.t()} | {:error, term()}
  def mark_packed(fulfillment_order_id, actor)
      when is_binary(fulfillment_order_id) and is_map(actor) do
    with {:ok, fulfillment_order} <-
           fetch_fulfillment_order_for_update(fulfillment_order_id, actor) do
      fulfillment_order
      |> Ash.Changeset.for_update(:mark_packed, %{})
      |> Ash.update(domain: __MODULE__, actor: actor)
    end
  end

  @spec mark_shipped(String.t(), map(), map()) ::
          {:ok, %{fulfillment_order: FulfillmentOrder.t(), shipment: Shipment.t()}}
          | {:error, term()}
  def mark_shipped(fulfillment_order_id, shipment_attrs, actor)
      when is_binary(fulfillment_order_id) and is_map(shipment_attrs) and is_map(actor) do
    with {:ok, fulfillment_order} <-
           fetch_fulfillment_order_for_update(fulfillment_order_id, actor),
         {:ok, shipped_order} <-
           fulfillment_order
           |> Ash.Changeset.for_update(:mark_shipped, %{})
           |> Ash.update(domain: __MODULE__, actor: actor),
         {:ok, shipment} <- ensure_shipment_in_transit(shipped_order, shipment_attrs, actor) do
      {:ok, %{fulfillment_order: shipped_order, shipment: shipment}}
    end
  end

  @spec mark_delivered(String.t(), map()) ::
          {:ok, %{fulfillment_order: FulfillmentOrder.t(), shipment: Shipment.t() | nil}}
          | {:error, term()}
  def mark_delivered(fulfillment_order_id, actor)
      when is_binary(fulfillment_order_id) and is_map(actor) do
    with {:ok, fulfillment_order} <-
           fetch_fulfillment_order_for_update(fulfillment_order_id, actor),
         {:ok, delivered_order} <-
           fulfillment_order
           |> Ash.Changeset.for_update(:mark_delivered, %{})
           |> Ash.update(domain: __MODULE__, actor: actor),
         {:ok, shipment} <- maybe_mark_latest_shipment_delivered(delivered_order, actor) do
      {:ok, %{fulfillment_order: delivered_order, shipment: shipment}}
    end
  end

  @spec cancel(String.t(), map(), map()) :: {:ok, FulfillmentOrder.t()} | {:error, term()}
  def cancel(fulfillment_order_id, attrs, actor)
      when is_binary(fulfillment_order_id) and is_map(attrs) and is_map(actor) do
    with {:ok, fulfillment_order} <-
           fetch_fulfillment_order_for_update(fulfillment_order_id, actor),
         {:ok, canceled_order} <-
           fulfillment_order
           |> Ash.Changeset.for_update(:cancel, attrs)
           |> Ash.update(domain: __MODULE__, actor: actor),
         {:ok, _shipment} <- maybe_cancel_latest_shipment(canceled_order, actor) do
      {:ok, canceled_order}
    end
  end

  @spec get_fulfillment_by_order_id(String.t()) ::
          {:ok, FulfillmentOrder.t() | nil} | {:error, term()}
  def get_fulfillment_by_order_id(order_id) when is_binary(order_id) do
    FulfillmentOrder
    |> Ash.Query.for_read(:get_for_order_id, %{order_id: order_id}, actor: %{role: :system})
    |> Ash.Query.load([:shipments, :items])
    |> Ash.read_one(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp get_or_create_fulfillment_order(order) do
    case get_fulfillment_by_order_id(order.id) do
      {:ok, %FulfillmentOrder{} = fulfillment_order} ->
        {:ok, fulfillment_order, true}

      {:ok, nil} ->
        create_fulfillment_order(order)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_fulfillment_order(order) do
    attrs = %{
      order_id: order.id,
      state: :pending,
      shipping_method_code: order.shipping_method_code || order.shipping_rate_code || "STANDARD",
      shipping_address_snapshot: shipping_address_snapshot(order)
    }

    FulfillmentOrder
    |> Ash.Changeset.for_create(:ensure_for_order, attrs, context: %{system?: true})
    |> Ash.create(domain: __MODULE__, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, %FulfillmentOrder{} = fulfillment_order} ->
        {:ok, fulfillment_order, false}

      {:error, error} ->
        {:error, error}
    end
  end

  defp shipping_address_snapshot(order) do
    %{
      recipient_name: order.shipping_recipient_name,
      address_line1: order.shipping_address_line1,
      address_line2: order.shipping_address_line2,
      city: order.shipping_city,
      country_code: order.shipping_country_code,
      region_code: order.shipping_region_code,
      postal_code: order.shipping_postal_code,
      phone: order.shipping_phone
    }
  end

  defp ensure_fulfillment_items(%FulfillmentOrder{} = fulfillment_order, order_id) do
    case fetch_order_line_items(order_id) do
      {:ok, line_items} when line_items != [] ->
        created =
          Enum.map(line_items, fn line_item ->
            attrs = %{
              fulfillment_order_id: fulfillment_order.id,
              order_line_item_id: line_item.id,
              variant_id: line_item.variant_id_snapshot,
              quantity: line_item.quantity,
              product_title_snapshot: line_item.product_title_snapshot,
              variant_title_snapshot: line_item.variant_title_snapshot
            }

            FulfillmentItem
            |> Ash.Changeset.for_create(:create, attrs, context: %{system?: true})
            |> Ash.create(domain: __MODULE__, authorize?: false, context: %{system?: true})
          end)

        case Enum.split_with(created, &match?({:ok, _}, &1)) do
          {oks, []} -> {:ok, Enum.map(oks, fn {:ok, item} -> item end)}
          _ -> {:error, Error.new("INTERNAL_ERROR", "unable to persist fulfillment items")}
        end

      {:ok, []} ->
        {:error, Error.new("VALIDATION_ERROR", "order snapshot line items are required")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_initial_shipment(%FulfillmentOrder{} = fulfillment_order) do
    query =
      Shipment
      |> Ash.Query.for_read(:for_fulfillment_order, %{fulfillment_order_id: fulfillment_order.id})

    case Ash.read(query, domain: __MODULE__, authorize?: false, context: %{system?: true}) do
      {:ok, [shipment | _]} ->
        {:ok, shipment}

      {:ok, []} ->
        Shipment
        |> Ash.Changeset.for_create(
          :create,
          %{fulfillment_order_id: fulfillment_order.id, state: :created},
          context: %{system?: true}
        )
        |> Ash.create(domain: __MODULE__, authorize?: false, context: %{system?: true})

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read shipments")}
    end
  end

  defp ensure_shipment_in_transit(%FulfillmentOrder{} = fulfillment_order, attrs, actor) do
    with {:ok, shipment} <- ensure_initial_shipment(fulfillment_order) do
      shipment
      |> Ash.Changeset.for_update(
        :mark_in_transit,
        %{
          carrier: Map.get(attrs, "carrier") || Map.get(attrs, :carrier),
          tracking_ref: Map.get(attrs, "tracking_ref") || Map.get(attrs, :tracking_ref)
        }
      )
      |> Ash.update(domain: __MODULE__, actor: actor)
    end
  end

  defp maybe_mark_latest_shipment_delivered(%FulfillmentOrder{} = fulfillment_order, actor) do
    case latest_shipment(fulfillment_order.id) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Shipment{} = shipment} ->
        shipment
        |> Ash.Changeset.for_update(:mark_delivered, %{})
        |> Ash.update(domain: __MODULE__, actor: actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cancel_latest_shipment(%FulfillmentOrder{} = fulfillment_order, actor) do
    case latest_shipment(fulfillment_order.id) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Shipment{} = shipment} ->
        shipment
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(domain: __MODULE__, actor: actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_shipment(fulfillment_order_id) do
    query =
      Shipment
      |> Ash.Query.for_read(:for_fulfillment_order, %{fulfillment_order_id: fulfillment_order_id})
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: __MODULE__, authorize?: false, context: %{system?: true}) do
      {:ok, [shipment | _]} -> {:ok, shipment}
      {:ok, []} -> {:ok, nil}
      {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "unable to read shipments")}
    end
  end

  defp fetch_fulfillment_order_for_update(fulfillment_order_id, actor) do
    FulfillmentOrder
    |> Ash.Query.for_read(:admin_get, %{id: fulfillment_order_id}, actor: actor)
    |> Ash.read_one(domain: __MODULE__, actor: actor)
    |> case do
      {:ok, %FulfillmentOrder{} = fulfillment_order} -> {:ok, fulfillment_order}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "fulfillment order not found")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found")}
      {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "unable to read order")}
    end
  end

  defp fetch_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order_id and digital_only_snapshot == false))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "unable to read order line items")}
    end
  end

  defp ensure_paid(%Order{state: :paid}), do: :ok

  defp ensure_paid(%Order{}),
    do: {:error, Error.new("INVALID_STATE_TRANSITION", "order must be paid")}

  defp ensure_totals_finalized(%Order{totals_finalized_at: %DateTime{}}), do: :ok

  defp ensure_totals_finalized(%Order{}) do
    {:error, Error.new("VALIDATION_ERROR", "order totals must be finalized before fulfillment")}
  end

  defp ensure_shipping_adjustment_present(order_id) do
    query =
      OrderAdjustment |> Ash.Query.filter(expr(order_id == ^order_id and kind == "shipping"))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [_ | _]} ->
        :ok

      {:ok, []} ->
        {:error, Error.new("VALIDATION_ERROR", "shipping adjustment missing")}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read shipping adjustment")}
    end
  end

  defp fulfillment_page_opts(limit, after_cursor, before_cursor) do
    [limit: limit]
    |> maybe_put_page_cursor(:after, after_cursor)
    |> maybe_put_page_cursor(:before, before_cursor)
  end

  defp maybe_put_page_cursor(opts, _key, nil), do: opts
  defp maybe_put_page_cursor(opts, key, value), do: Keyword.put(opts, key, value)
end
