defmodule Store.Orders.MembershipComponentTaxAllocation do
  @moduledoc """
  Attributes an already evaluated line-tax amount to component net amounts.

  This pure calculation does not select a tax rate or accept financial evidence.
  """

  @doc """
  Returns amounts keyed by component instance UUID, or rejects an invalid basis.

  The line tax is divided over positive component net using floor division. Any
  remainder is assigned in ascending binary UUID order.
  """
  @spec allocate([map()], non_neg_integer()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, :invalid_tax_allocation}
  def allocate(rows, tax)
      when is_list(rows) and length(rows) in 1..16 and is_integer(tax) and tax >= 0 do
    with {:ok, entries} <- normalize(rows),
         true <- length(entries) == MapSet.size(MapSet.new(entries, &elem(&1, 0))),
         basis <- Enum.reduce(entries, 0, fn {_, _, net}, acc -> acc + net end),
         true <- tax == 0 or basis > 0 do
      eligible = Enum.filter(entries, fn {_, _, net} -> net > 0 end)

      base =
        Map.new(entries, fn {_, id, net} ->
          {id, if(basis == 0, do: 0, else: div(net * tax, basis))}
        end)

      remainder = tax - Enum.sum(Map.values(base))

      amounts =
        Enum.reduce(Enum.take(eligible, remainder), base, fn {_, id, _}, acc ->
          Map.update!(acc, id, &(&1 + 1))
        end)

      {:ok, amounts}
    else
      _ -> {:error, :invalid_tax_allocation}
    end
  end

  def allocate(_, _), do: {:error, :invalid_tax_allocation}

  defp normalize(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{instance_id: id, net_minor: net}, {:ok, acc}
      when is_binary(id) and is_integer(net) and net >= 0 ->
        case normalized_uuid(id) do
          {:ok, binary} -> {:cont, {:ok, [{binary, id, net} | acc]}}
          :error -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      :error -> :error
    end
  end

  defp normalized_uuid(id) do
    case Ecto.UUID.dump(id) do
      {:ok, <<_::48, 7::4, _::12, 2::2, _::62>> = binary} ->
        if Ecto.UUID.load!(binary) == id, do: {:ok, binary}, else: :error

      _ ->
        :error
    end
  end
end
