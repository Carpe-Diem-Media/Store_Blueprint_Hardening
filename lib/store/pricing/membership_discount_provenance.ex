defmodule Store.Pricing.MembershipDiscountProvenance do
  @moduledoc """
  Derives transient, keyed Membership discount provenance from a Pricing evaluation.

  The caller supplies the original evaluation input, its output, an accepted offer
  manifest and a proposed definition-to-instance/line mapping. This result does
  not accept an order or prove payment. Commerce must validate and persist it.
  Global, manual and multiple-source discounts are rejected.
  """

  alias Store.Pricing.{Contract, Evaluator, MembershipOfferRevision}

  @rule "membership-keyed-discount-v1"

  @doc """
  Validates the evaluation and returns a canonical provisional attribution.

  Each mapping has `line_id`, `definition_id` (the offer component row ID), and
  `instance_id`. Every definition must appear exactly once. Only mapped lines
  are attributed, while source reconciliation includes all evaluated lines.
  """
  @spec derive(Contract.Input.t(), Contract.Output.t(), map(), [map()], [map()]) ::
          {:ok, map()} | {:error, :invalid_provenance}
  def derive(
        %Contract.Input{} = input,
        %Contract.Output{} = output,
        revision,
        components,
        mapping
      )
      when is_map(revision) and is_list(components) and is_list(mapping) do
    with {:ok, ^output} <- Evaluator.evaluate(input),
         true <- valid_revision?(revision, components, output.currency),
         {:ok, source} <- source(input, output),
         true <- is_nil(source) or Enum.any?(input.lines, &(&1.eligible? == true)),
         {:ok, rows} <- map_components(components, mapping, output.lines),
         true <- mapped_line_discounts_eligible?(rows, input.lines, output.lines),
         {:ok, allocated} <- allocate(rows, output.lines, source) do
      result = %{
        rule_version: @rule,
        currency: output.currency,
        offer_revision_id: revision.id,
        offer_fingerprint: revision.fingerprint,
        source: source,
        lines:
          output.lines
          |> Enum.sort_by(&uuid_bytes!(&1.line_id))
          |> Enum.map(fn line ->
            %{
              line_id: line.line_id,
              gross_minor: line.line_total_minor,
              discount_minor: line.discount_allocated_minor,
              net_minor: line.net_line_total_minor
            }
          end),
        components: allocated
      }

      fingerprint =
        :crypto.hash(:sha256, :erlang.term_to_binary(result, [:deterministic]))
        |> Base.encode16(case: :lower)

      {:ok, Map.put(result, :fingerprint, fingerprint)}
    else
      _ -> {:error, :invalid_provenance}
    end
  rescue
    _ in [ArgumentError, KeyError, FunctionClauseError, ArithmeticError] ->
      {:error, :invalid_provenance}
  end

  def derive(_, _, _, _, _), do: {:error, :invalid_provenance}

  defp valid_revision?(revision, components, currency) do
    revision.status == "accepted" and revision.currency == currency and
      valid_uuid?(revision.id) and length(components) in 1..16 and
      Enum.all?(components, &valid_component?(&1, revision.id)) and
      unique?(Enum.map(components, & &1.id)) and
      unique?(Enum.map(components, & &1.definition_key)) and
      revision.fingerprint ==
        MembershipOfferRevision.Fingerprint.compute(
          revision.offer_key,
          revision.revision,
          currency,
          components
        )
  end

  defp valid_component?(component, revision_id) do
    component.revision_id == revision_id and valid_uuid?(component.id) and
      valid_uuid?(component.definition_key) and is_integer(component.gross_minor) and
      component.gross_minor >= 0 and is_binary(component.discount_eligibility_key) and
      component.discount_eligibility_key != "" and is_binary(component.tax_treatment_key)
  end

  defp source(input, output) do
    total = Enum.reduce(output.lines, 0, &(&1.discount_allocated_minor + &2))
    find_source(input, output.applied_adjustments, total, output.discount_total_minor)
  end

  defp find_source(_input, [], 0, 0), do: {:ok, nil}

  defp find_source(input, [adjustment], total, total)
       when adjustment.source_kind in [:coupon, :promotion] and
              adjustment.discount_minor == total and total > 0 do
    candidates = Enum.reject([input.coupon | input.promotions], &is_nil/1)

    matching =
      Enum.filter(
        candidates,
        &(&1.id == adjustment.source_id and &1.source_kind == adjustment.source_kind)
      )

    verified_candidate(matching, adjustment)
  end

  defp find_source(_, _, _, _), do: :error

  defp verified_candidate([%Contract.Candidate{eligibility_key: key} = candidate], adjustment)
       when is_binary(key) and byte_size(key) > 0 do
    if valid_uuid?(candidate.id) and candidate_fields_valid?(candidate) do
      {:ok,
       %{
         kind: adjustment.source_kind,
         id: candidate.id,
         eligibility_key: key,
         applied_minor: adjustment.discount_minor,
         code: adjustment.source_code,
         precedence_rank: adjustment.precedence_rank,
         inserted_at: adjustment.inserted_at
       }}
    else
      :error
    end
  end

  defp verified_candidate(_, _), do: :error

  defp candidate_fields_valid?(candidate) do
    expected = %Contract.Candidate{
      id: nil,
      source_kind: nil,
      discount_minor: nil,
      inserted_at: nil
    }

    Enum.sort(Map.keys(candidate)) == Enum.sort(Map.keys(expected))
  end

  defp map_components(components, mapping, lines) do
    ids = Enum.map(components, & &1.id)
    line_ids = Enum.map(lines, & &1.line_id)

    valid =
      length(mapping) == length(components) and unique?(line_ids) and
        Enum.all?(line_ids, &valid_uuid?/1) and
        unique?(Enum.map(mapping, & &1.definition_id)) and
        unique?(Enum.map(mapping, & &1.instance_id)) and
        Enum.sort(Enum.map(mapping, & &1.definition_id)) == Enum.sort(ids) and
        Enum.all?(mapping, &(valid_uuid?(&1.instance_id) and &1.line_id in line_ids))

    if valid do
      rows =
        Enum.map(mapping, fn m ->
          c = Enum.find(components, &(&1.id == m.definition_id))

          %{
            line_id: m.line_id,
            definition_id: c.id,
            definition_key: c.definition_key,
            instance_id: m.instance_id,
            eligibility_key: c.discount_eligibility_key,
            gross_minor: c.gross_minor,
            discount_minor: 0
          }
        end)

      {:ok, Enum.sort_by(rows, &uuid_bytes!(&1.instance_id))}
    else
      :error
    end
  end

  defp mapped_line_discounts_eligible?(rows, input_lines, evaluated_lines) do
    inputs = Map.new(input_lines, &{&1.id, &1})
    evaluated = Map.new(evaluated_lines, &{&1.line_id, &1})

    Enum.all?(rows, fn row ->
      input = Map.fetch!(inputs, row.line_id)
      line = Map.fetch!(evaluated, row.line_id)
      input.eligible? == true or line.discount_allocated_minor == 0
    end)
  end

  defp allocate(rows, lines, source) do
    Enum.reduce_while(lines, {:ok, rows}, fn line, {:ok, current} ->
      case allocate_line(current, line, source) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp allocate_line(rows, line, source) do
    group = Enum.filter(rows, &(&1.line_id == line.line_id))
    if group == [], do: {:ok, rows}, else: allocate_group(rows, group, line, source)
  end

  defp allocate_group(rows, group, line, source) do
    discount = line.discount_allocated_minor

    eligible =
      Enum.filter(
        group,
        &(source != nil and &1.eligibility_key == source.eligibility_key and &1.gross_minor > 0)
      )

    basis = Enum.reduce(eligible, 0, &(&1.gross_minor + &2))
    gross = Enum.reduce(group, 0, &(&1.gross_minor + &2))

    if line.quantity != 1 or gross != line.line_total_minor or discount < 0 or discount > basis or
         (discount > 0 and basis == 0) do
      :error
    else
      {:ok, apply_allocation(rows, eligible, line.line_id, discount, basis)}
    end
  end

  defp apply_allocation(rows, eligible, line_id, discount, basis) do
    base =
      Map.new(eligible, fn row -> {row.instance_id, div(row.gross_minor * discount, basis)} end)

    remainder = discount - Enum.sum(Map.values(base))
    extras = eligible |> Enum.take(remainder) |> MapSet.new(& &1.instance_id)

    Enum.map(rows, fn row ->
      amount =
        Map.get(base, row.instance_id, 0) +
          if(MapSet.member?(extras, row.instance_id), do: 1, else: 0)

      if row.line_id == line_id, do: %{row | discount_minor: amount}, else: row
    end)
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, <<_::48, 7::4, _::12, 2::2, _::62>> = bytes} -> Ecto.UUID.load!(bytes) == id
      _ -> false
    end
  end

  defp valid_uuid?(_), do: false
  defp uuid_bytes!(id), do: Ecto.UUID.dump!(id)
  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))
end
