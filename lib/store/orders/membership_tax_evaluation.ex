defmodule Store.Orders.MembershipTaxEvaluation do
  @moduledoc """
  Builds enabled-only Membership tax evidence using Pricing-owned rate reads.

  This is a provisional evaluation. The Commerce acceptance transaction must
  bind and freeze the input, selected output, and order lines before collection.
  """

  alias Store.Pricing
  alias Store.Pricing.TaxShippingEvaluator

  @allowed_keys [
    :as_of,
    :currency,
    :destination_country_code,
    :destination_region_code,
    :destination_postal_code,
    :subtotal_minor,
    :lines,
    :tax_enabled?
  ]

  @doc """
  Evaluates line taxes with tax enabled and shipping excluded.

  Caller-supplied tax-rate and shipping-rate candidates are rejected. Rate
  candidates are loaded by Pricing from its persisted definitions. A false tax
  mode is rejected rather than overridden.
  """
  @spec evaluate(map()) :: {:ok, %{input: map(), output: map()}} | {:error, term()}
  def evaluate(attrs) when is_map(attrs) do
    if Map.get(attrs, :tax_enabled?, true) == true and
         Enum.all?(Map.keys(attrs), &(&1 in @allowed_keys)) do
      attrs =
        attrs
        |> Map.take([
          :as_of,
          :currency,
          :destination_country_code,
          :destination_region_code,
          :destination_postal_code,
          :subtotal_minor,
          :lines
        ])
        |> Map.merge(%{shipping_weight_grams: 0, shipping_enabled?: false, tax_enabled?: true})

      with {:ok, input} <- Pricing.build_tax_shipping_input(attrs),
           {:ok, output} <- TaxShippingEvaluator.evaluate(input) do
        {:ok, %{input: input, output: output}}
      end
    else
      {:error, :invalid_tax_mode_or_candidates}
    end
  end

  def evaluate(_), do: {:error, :invalid_tax_mode_or_candidates}
end
