defmodule Store.Orders.MembershipTaxEvaluationTest do
  use Store.DataCase, async: false

  alias Store.Orders.MembershipTaxEvaluation
  alias Store.Pricing.TaxRate

  @line "018f0000-0000-7000-8000-000000000001"
  @now ~U[2026-01-01 00:00:00Z]

  defp attrs do
    %{
      as_of: @now,
      currency: "USD",
      destination_country_code: "US",
      destination_region_code: "CA",
      subtotal_minor: 100,
      lines: [
        %{
          line_id: @line,
          line_no: 1,
          net_line_total_minor: 100,
          tax_category_snapshot: "standard"
        }
      ]
    }
  end

  defp rate!(bps) do
    TaxRate
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: "TAX-#{Ash.UUIDv7.generate()}",
        country_code: "US",
        region_code: "CA",
        product_tax_category: "STANDARD",
        rate_basis_points: bps,
        shipping_taxable: false
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  test "rejects disabled or caller-supplied tax-rate candidates" do
    rate!(0)
    assert {:error, _} = MembershipTaxEvaluation.evaluate(Map.put(attrs(), :tax_enabled?, false))
    assert {:error, _} = MembershipTaxEvaluation.evaluate(Map.put(attrs(), :tax_rates, []))
    assert {:error, _} = MembershipTaxEvaluation.evaluate(Map.put(attrs(), "tax_enabled?", false))
    assert {:error, _} = MembershipTaxEvaluation.evaluate(Map.put(attrs(), "tax_rates", []))
  end

  test "uses a Pricing-owned enabled zero-percent rate" do
    rate = rate!(0)
    assert {:ok, %{input: input, output: output}} = MembershipTaxEvaluation.evaluate(attrs())
    assert input.tax_enabled? == true
    assert [%{tax_rate_id: id, tax_rate_bps: 0, tax_minor: 0}] = output.line_taxes
    assert id == rate.id
  end

  test "rejects when no applicable rate exists" do
    assert {:error, _} = MembershipTaxEvaluation.evaluate(attrs())
  end

  test "evaluates positive tax using the persisted rate" do
    rate = rate!(1_250)
    assert {:ok, %{input: input, output: output}} = MembershipTaxEvaluation.evaluate(attrs())
    assert Enum.any?(input.tax_rates, &(&1.id == rate.id))
    assert [%{tax_rate_id: id, tax_rate_bps: 1_250, tax_minor: 13}] = output.line_taxes
    assert id == rate.id
  end

  test "does not select a rate from another jurisdiction" do
    rate!(1_250)

    assert {:error, _} =
             MembershipTaxEvaluation.evaluate(%{attrs() | destination_region_code: "NY"})
  end
end
