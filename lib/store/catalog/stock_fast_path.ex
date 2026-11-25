defmodule Store.Catalog.StockFastPath do
  @moduledoc """
  Best-effort fast-path stock checks for cart mutations.

  Cache/ETS first with DB fallback. Checkout reservations remain authoritative.
  """

  import Ecto.Query

  alias Store.Catalog.{InventoryItem, Product, Variant}
  alias Store.Repo
  alias Store.Support.Errors.Error

  @table :store_catalog_stock_fast_path
  @default_ttl_seconds 5

  @type sellable_qty :: non_neg_integer() | :infinite

  @spec precheck_variant_qty(Ecto.UUID.t(), pos_integer()) :: :ok | {:error, Error.t()}
  def precheck_variant_qty(variant_id, desired_qty)
      when is_binary(variant_id) and is_integer(desired_qty) and desired_qty > 0 do
    case sellable_qty_by_variant_ids([variant_id]) do
      %{^variant_id => :infinite} ->
        :ok

      %{^variant_id => qty} when is_integer(qty) and qty >= desired_qty ->
        :ok

      %{^variant_id => qty} when is_integer(qty) ->
        {:error,
         Error.new("OUT_OF_STOCK", "Insufficient available inventory", %{
           variant_id: variant_id,
           available: qty,
           requested: desired_qty
         })}

      _ ->
        {:error,
         Error.new("OUT_OF_STOCK", "Inventory item missing or out of stock", %{
           variant_id: variant_id
         })}
    end
  end

  def precheck_variant_qty(_variant_id, _desired_qty),
    do: {:error, Error.new("VALIDATION_ERROR", "variant_id and desired_qty are required")}

  @spec sellable_qty_by_variant_ids([Ecto.UUID.t()], keyword()) :: %{
          Ecto.UUID.t() => sellable_qty()
        }
  def sellable_qty_by_variant_ids(variant_ids, opts \\ [])
      when is_list(variant_ids) and is_list(opts) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    variant_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> do_sellable_qty_by_variant_ids(ttl_seconds)
  end

  @spec invalidate_variant_ids([Ecto.UUID.t()]) :: :ok
  def invalidate_variant_ids(variant_ids) when is_list(variant_ids) do
    table = ensure_table()

    variant_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(&:ets.delete(table, &1))

    :ok
  end

  def invalidate_variant_ids(_variant_ids), do: :ok

  defp do_sellable_qty_by_variant_ids([], _ttl_seconds), do: %{}

  defp do_sellable_qty_by_variant_ids(variant_ids, ttl_seconds) do
    table = ensure_table()
    now = System.system_time(:second)

    {hit_map, misses} =
      Enum.reduce(variant_ids, {%{}, []}, fn variant_id, {hits, missing} ->
        case :ets.lookup(table, variant_id) do
          [{^variant_id, expires_at, cached_qty}] when expires_at > now ->
            {Map.put(hits, variant_id, cached_qty), missing}

          [{^variant_id, _expires_at, _cached_qty}] ->
            :ets.delete(table, variant_id)
            {hits, [variant_id | missing]}

          _ ->
            {hits, [variant_id | missing]}
        end
      end)

    misses = Enum.reverse(misses)

    db_map =
      if misses == [] do
        %{}
      else
        load_qty_from_db(misses)
      end

    expires_at = now + ttl_seconds

    Enum.each(db_map, fn {variant_id, qty} ->
      :ets.insert(table, {variant_id, expires_at, qty})
    end)

    maybe_cleanup(table, now)
    Map.merge(hit_map, db_map)
  end

  defp load_qty_from_db(variant_ids) do
    rows =
      Variant
      |> join(:inner, [variant], product in Product, on: variant.product_id == product.id)
      |> join(:left, [variant, _product], item in InventoryItem,
        on: item.variant_id == variant.id
      )
      |> where([variant], variant.id in ^variant_ids)
      |> select(
        [variant, product, item],
        {variant.id, product.product_kind, item.stock_on_hand, item.reserved_count,
         item.allow_oversell}
      )
      |> Repo.all()

    base_map =
      Map.new(rows, fn {variant_id, product_kind, stock_on_hand, reserved_count, allow_oversell} ->
        qty =
          if product_kind == :digital or allow_oversell == true do
            :infinite
          else
            max((stock_on_hand || 0) - (reserved_count || 0), 0)
          end

        {variant_id, qty}
      end)

    Enum.reduce(variant_ids, base_map, fn variant_id, acc ->
      Map.put_new(acc, variant_id, 0)
    end)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end

  defp maybe_cleanup(table, now) do
    if rem(now, 60) == 0 do
      :ets.select_delete(
        table,
        [
          {{:"$1", :"$2", :"$3"}, [{:<, :"$2", now}], [true]}
        ]
      )
    end

    :ok
  end
end
