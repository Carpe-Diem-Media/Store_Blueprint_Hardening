defmodule Store.Orders.TaxShippingSnapshotWriter do
  @moduledoc """
  Idempotent writer for order-level tax and shipping snapshot evidence.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Pricing.TaxShippingContract
  alias Store.Support.Errors.Error

  @type write_result ::
          {:ok,
           %{
             order: Order.t(),
             idempotent?: boolean()
           }}
          | {:error, Error.t()}

  @spec write_tax_shipping_snapshot(String.t(), TaxShippingContract.Output.t() | map(), keyword()) ::
          write_result()
  def write_tax_shipping_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    output = to_output!(output)

    with {:ok, order} <- read_order(order_id),
         {:ok, order_or_existing, idempotent?} <- maybe_write_order_snapshot(order, output, opts) do
      {:ok, %{order: order_or_existing, idempotent?: idempotent?}}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping snapshot output")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping snapshot output")}
  end

  defp maybe_write_order_snapshot(%Order{} = order, %TaxShippingContract.Output{} = output, opts)
       when is_nil(order.shipping_rate_id) and is_nil(order.tax_as_of) do
    ash_opts =
      Keyword.merge(
        [domain: Store.Orders, authorize?: false, context: %{system?: true}],
        Keyword.delete(opts, :location)
      )

    attrs =
      %{
        shipping_rate_id: output.selected_shipping_rate_id,
        shipping_rate_code: output.selected_shipping_rate_code,
        shipping_cost_minor_original: output.shipping_cost_minor_original,
        shipping_cost_minor_effective: output.shipping_cost_minor_effective,
        free_shipping_applied: output.free_shipping_applied,
        free_shipping_reason: output.free_shipping_reason,
        shipping_tax_minor: output.shipping_tax_minor,
        tax_total_minor: output.tax_total_minor,
        tax_as_of: output.tax_as_of
      }
      |> Map.merge(location_snapshot(output, Keyword.get(opts, :location, :shipping)))

    case order
         |> Ash.Changeset.for_update(:write_tax_shipping_snapshot, attrs,
           context: %{system?: true}
         )
         |> Ash.update(ash_opts) do
      {:ok, updated_order} ->
        {:ok, updated_order, false}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to persist tax/shipping snapshot")}
    end
  end

  defp maybe_write_order_snapshot(%Order{} = order, _output, _opts) do
    {:ok, order, true}
  end

  defp location_snapshot(output, :billing) do
    %{
      billing_country_code: output.destination_country_code,
      billing_region_code: output.destination_region_code
    }
  end

  defp location_snapshot(output, :shipping) do
    %{
      shipping_country_code: output.destination_country_code,
      shipping_region_code: output.destination_region_code,
      shipping_postal_code: output.destination_postal_code
    }
  end

  defp read_order(order_id) do
    query = Ash.Query.filter(Order, expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order]} ->
        {:ok, order}

      {:ok, []} ->
        {:error, Error.new("ORDER_NOT_FOUND", "Order not found")}

      {:ok, _many} ->
        {:error, Error.new("INTERNAL_ERROR", "Unexpected order lookup result")}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read order")}
    end
  end

  defp to_output!(%TaxShippingContract.Output{} = output), do: output
  defp to_output!(attrs) when is_map(attrs), do: struct!(TaxShippingContract.Output, attrs)
end
