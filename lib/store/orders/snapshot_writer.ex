defmodule Store.Orders.SnapshotWriter do
  @moduledoc """
  Create-only writer for priced immutable order snapshot evidence.

  This module never updates existing snapshot rows. If a snapshot already exists
  for an order, writes are treated as idempotent no-op reads.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{OrderAdjustment, OrderLineItem}
  alias Store.Pricing.Contract
  alias Store.Pricing.Evaluator
  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7

  @type write_result ::
          {:ok,
           %{
             line_items: [OrderLineItem.t()],
             adjustments: [OrderAdjustment.t()],
             idempotent?: boolean()
           }}
          | {:error, Error.t()}

  @spec write_priced_snapshot(String.t(), Contract.Output.t() | map(), keyword()) ::
          write_result()
  def write_priced_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    output = to_output!(output)
    maybe_write_snapshot(order_id, output, opts)
  rescue
    KeyError -> {:error, Error.new("VALIDATION_ERROR", "Invalid priced snapshot output")}
    ArgumentError -> {:error, Error.new("VALIDATION_ERROR", "Invalid priced snapshot output")}
  end

  defp maybe_write_snapshot(order_id, %Contract.Output{} = output, _opts) do
    with {:ok, line_items} <- create_line_items(order_id, output, []),
         {:ok, adjustments} <- create_adjustments(order_id, output, []) do
      build_snapshot_write_result(order_id, line_items, adjustments)
    end
  end

  defp build_snapshot_write_result(order_id, [], []) do
    with {:ok, existing_line_items, existing_adjustments} <- read_existing_snapshot(order_id) do
      {:ok,
       %{
         line_items: Enum.sort_by(existing_line_items, & &1.line_no),
         adjustments: Enum.sort_by(existing_adjustments, & &1.sequence_no),
         idempotent?: true
       }}
    end
  end

  defp build_snapshot_write_result(_order_id, line_items, adjustments) do
    {:ok,
     %{
       line_items: Enum.sort_by(line_items, & &1.line_no),
       adjustments: Enum.sort_by(adjustments, & &1.sequence_no),
       idempotent?: false
     }}
  end

  defp create_line_items(order_id, %Contract.Output{} = output, _opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      output.lines
      |> Enum.sort_by(& &1.line_no)
      |> Enum.map(fn line ->
        %{
          id: UUIDv7.generate(),
          order_id: order_id,
          line_no: line.line_no,
          currency: output.currency,
          quantity: line.quantity,
          unit_price_minor: line.unit_price_minor,
          line_total_minor: line.line_total_minor,
          sku_snapshot: line.sku_snapshot,
          product_title_snapshot: line.product_title_snapshot,
          variant_title_snapshot: line.variant_title_snapshot,
          variant_id_snapshot: line.line_id,
          digital_only_snapshot: Map.get(line, :digital_only_snapshot, false),
          subscription_plan_id_snapshot: Map.get(line, :subscription_plan_id_snapshot),
          subscription_plan_revision_id_snapshot:
            Map.get(line, :subscription_plan_revision_id_snapshot),
          subscription_plan_key_snapshot: Map.get(line, :subscription_plan_key_snapshot),
          subscription_interval_unit_snapshot:
            Map.get(line, :subscription_interval_unit_snapshot),
          subscription_interval_count_snapshot:
            Map.get(line, :subscription_interval_count_snapshot),
          discount_allocated_minor: line.discount_allocated_minor,
          net_line_total_minor: line.net_line_total_minor,
          tax_category_snapshot: Map.get(line, :tax_category_snapshot, "STANDARD"),
          tax_rate_id_snapshot: Map.get(line, :tax_rate_id_snapshot),
          tax_rate_code_snapshot: Map.get(line, :tax_rate_code_snapshot),
          tax_rate_bps_snapshot: Map.get(line, :tax_rate_bps_snapshot),
          tax_minor: Map.get(line, :tax_minor, 0),
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_all_snapshots(
      OrderLineItem,
      entries,
      [:order_id, :line_no],
      "Unable to persist line-item snapshot"
    )
  end

  defp create_adjustments(order_id, %Contract.Output{} = output, _opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      output.applied_adjustments
      |> Enum.sort_by(&Evaluator.applied_adjustment_tuple/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {adjustment, sequence_no} ->
        %{
          id: UUIDv7.generate(),
          order_id: order_id,
          sequence_no: sequence_no,
          currency: output.currency,
          kind: "pricing_discount",
          amount_minor: -adjustment.discount_minor,
          reason: "#{adjustment.source_kind}:#{adjustment.source_code || "N/A"}",
          source_kind: adjustment.source_kind |> to_string() |> String.downcase(),
          source_code: adjustment.source_code,
          source_id: adjustment.source_id,
          precedence_rank: adjustment.precedence_rank,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_all_snapshots(
      OrderAdjustment,
      entries,
      [:order_id, :sequence_no],
      "Unable to persist adjustment snapshot"
    )
  end

  defp insert_all_snapshots(_schema, [], _conflict_target, _error_message), do: {:ok, []}

  defp insert_all_snapshots(schema, entries, conflict_target, error_message) do
    {inserted_count, rows} =
      Repo.insert_all(
        schema,
        entries,
        on_conflict: :nothing,
        conflict_target: conflict_target,
        returning: true
      )

    cond do
      inserted_count == length(entries) ->
        {:ok, Enum.map(rows, &returned_row_to_struct(schema, &1))}

      inserted_count == 0 ->
        {:ok, []}

      true ->
        {:error, Error.new("INTERNAL_ERROR", error_message)}
    end
  end

  defp returned_row_to_struct(_schema, %_{} = row), do: row

  defp returned_row_to_struct(schema, row) when is_map(row) do
    struct(schema, atomize_row_keys(row))
  end

  defp atomize_row_keys(row) do
    Map.new(row, fn {key, value} ->
      normalized_key =
        if is_binary(key) do
          String.to_existing_atom(key)
        else
          key
        end

      {normalized_key, value}
    end)
  end

  defp read_existing_line_items(order_id) do
    target_order_id = order_id
    query = Ash.Query.filter(OrderLineItem, expr(order_id == ^target_order_id))

    case Ash.read(query, domain: Store.Orders, context: %{system?: true}, authorize?: false) do
      {:ok, records} ->
        {:ok, records}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read line-item snapshot")}
    end
  end

  defp read_existing_adjustments(order_id) do
    target_order_id = order_id
    query = Ash.Query.filter(OrderAdjustment, expr(order_id == ^target_order_id))

    case Ash.read(query, domain: Store.Orders, context: %{system?: true}, authorize?: false) do
      {:ok, records} ->
        {:ok, records}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read adjustment snapshot")}
    end
  end

  defp to_output!(%Contract.Output{} = output), do: output

  defp to_output!(attrs) when is_map(attrs) do
    struct!(Contract.Output, attrs)
  end

  defp read_existing_snapshot(order_id) do
    with {:ok, line_items} <- read_existing_line_items(order_id),
         {:ok, adjustments} <- read_existing_adjustments(order_id) do
      {:ok, line_items, adjustments}
    end
  end
end
