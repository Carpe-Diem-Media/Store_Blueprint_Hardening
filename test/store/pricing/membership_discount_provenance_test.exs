defmodule Store.Pricing.MembershipDiscountProvenanceTest do
  use ExUnit.Case, async: true

  alias Store.Pricing.Contract.{Candidate, Input, Line}
  alias Store.Pricing.{Evaluator, MembershipDiscountProvenance, MembershipOfferRevision}

  @line "018f0000-0000-7000-8000-000000000001"
  @source "018f0000-0000-7000-8000-000000000002"
  @revision "018f0000-0000-7000-8000-000000000003"
  @a "018f0000-0000-7000-8000-000000000004"
  @b "018f0000-0000-7000-8000-000000000005"
  @i1 "018f0000-0000-7000-8000-000000000006"
  @i2 "018f0000-0000-7000-8000-000000000007"
  @now ~U[2026-01-01 00:00:00Z]

  defp fixture(discount \\ 1) do
    components = [
      %{
        id: @a,
        revision_id: @revision,
        definition_key: @a,
        gross_minor: 50,
        discount_eligibility_key: "member",
        tax_treatment_key: "standard"
      },
      %{
        id: @b,
        revision_id: @revision,
        definition_key: @b,
        gross_minor: 50,
        discount_eligibility_key: "member",
        tax_treatment_key: "standard"
      }
    ]

    revision = %{
      id: @revision,
      status: "accepted",
      offer_key: "offer",
      revision: 1,
      currency: "ZAR",
      fingerprint: MembershipOfferRevision.Fingerprint.compute("offer", 1, "ZAR", components)
    }

    candidate = %Candidate{
      id: @source,
      source_kind: :coupon,
      discount_minor: discount,
      inserted_at: @now,
      eligibility_key: "member"
    }

    input = %Input{
      as_of: @now,
      currency: "ZAR",
      lines: [
        %Line{
          id: @line,
          line_no: 1,
          sku_snapshot: "",
          product_title_snapshot: "",
          quantity: 1,
          unit_price_minor: 100,
          line_total_minor: 100
        }
      ],
      coupon: if(discount == 0, do: nil, else: candidate),
      eligibility: %{"member" => true}
    }

    {:ok, output} = Evaluator.evaluate(input)

    mapping = [
      %{line_id: @line, definition_id: @a, instance_id: @i1},
      %{line_id: @line, definition_id: @b, instance_id: @i2}
    ]

    {input, output, revision, components, mapping}
  end

  defp derive({input, output, revision, components, mapping}),
    do: MembershipDiscountProvenance.derive(input, output, revision, components, mapping)

  test "allocates one minor unit in binary instance order and fingerprints canonically" do
    {input, output, revision, components, mapping} = fixture()
    assert {:ok, result} = derive({input, output, revision, components, mapping})
    assert Enum.map(result.components, & &1.discount_minor) == [1, 0]

    assert {:ok, reordered} =
             derive({input, output, revision, Enum.reverse(components), Enum.reverse(mapping)})

    assert result.fingerprint == reordered.fingerprint
  end

  test "zero discount succeeds" do
    assert {:ok, result} = fixture(0) |> derive()
    assert Enum.all?(result.components, &(&1.discount_minor == 0))
    assert result.source == nil
  end

  test "rejects nil source key and forged output" do
    {input, output, revision, components, mapping} = fixture()
    nil_input = %{input | coupon: %{input.coupon | eligibility_key: nil}}
    {:ok, nil_output} = Evaluator.evaluate(nil_input)
    assert {:error, _} = derive({nil_input, nil_output, revision, components, mapping})

    assert {:error, _} =
             derive({input, %{output | discount_total_minor: 99}, revision, components, mapping})
  end

  test "mixed groups exclude ineligible gross" do
    {input, output, revision, components, mapping} = fixture(25)
    [a, b] = components
    components = [a, %{b | discount_eligibility_key: "other"}]

    revision = %{
      revision
      | fingerprint: MembershipOfferRevision.Fingerprint.compute("offer", 1, "ZAR", components)
    }

    assert {:ok, result} = derive({input, output, revision, components, mapping})
    assert Enum.map(result.components, & &1.discount_minor) == [25, 0]
    assert [%{discount_minor: 25, gross_minor: 100, net_minor: 75}] = result.lines
    assert result.source.applied_minor == 25
    assert {:error, _} = derive({input, output, revision, [%{a | gross_minor: 0}, b], mapping})
  end

  test "rejects insufficient or zero eligible basis" do
    {input, output, revision, components, mapping} = fixture(51)
    [a, b] = components
    components = [a, %{b | discount_eligibility_key: "other"}]

    revision = %{
      revision
      | fingerprint: MembershipOfferRevision.Fingerprint.compute("offer", 1, "ZAR", components)
    }

    assert {:error, _} = derive({input, output, revision, components, mapping})
    components = Enum.map(components, &%{&1 | discount_eligibility_key: "other"})

    revision = %{
      revision
      | fingerprint: MembershipOfferRevision.Fingerprint.compute("offer", 1, "ZAR", components)
    }

    assert {:error, _} = derive({input, output, revision, components, mapping})
  end

  test "rejects multiple sources and ambiguous source identities" do
    {input, _output, revision, components, mapping} = fixture(1)
    promotion = %{input.coupon | id: @a, source_kind: :promotion}
    input = %{input | promotions: [promotion]}
    {:ok, output} = Evaluator.evaluate(input)
    assert {:error, _} = derive({input, output, revision, components, mapping})

    input = %{
      input
      | promotions: [%{promotion | id: @source, source_kind: :coupon, discount_minor: 0}]
    }

    {:ok, output} = Evaluator.evaluate(input)
    assert {:error, _} = derive({input, output, revision, components, mapping})
  end

  test "rejects invalid mappings, revision, currency and global assertions" do
    {input, output, revision, components, mapping} = fixture()

    assert {:error, _} =
             derive({input, output, %{revision | currency: "USD"}, components, mapping})

    assert {:error, _} =
             derive({input, output, %{revision | status: "draft"}, components, mapping})

    assert {:error, _} = derive({input, output, revision, components, tl(mapping)})
    nil_input = %{input | coupon: Map.put(%{input.coupon | eligibility_key: nil}, :global, true)}
    {:ok, nil_output} = Evaluator.evaluate(nil_input)
    assert {:error, _} = derive({nil_input, nil_output, revision, components, mapping})

    assert {:error, _} =
             derive(
               {input, output, revision,
                components ++
                  components ++
                  components ++
                  components ++ components ++ components ++ components ++ components ++ components,
                mapping}
             )
  end

  test "changed source key changes fingerprint" do
    {input, output, revision, components, mapping} = fixture()
    {:ok, first} = derive({input, output, revision, components, mapping})

    input = %{
      input
      | coupon: %{input.coupon | eligibility_key: "other"},
        eligibility: %{"other" => true}
    }

    components = Enum.map(components, &%{&1 | discount_eligibility_key: "other"})

    revision = %{
      revision
      | fingerprint: MembershipOfferRevision.Fingerprint.compute("offer", 1, "ZAR", components)
    }

    {:ok, output} = Evaluator.evaluate(input)
    {:ok, second} = derive({input, output, revision, components, mapping})
    refute first.fingerprint == second.fingerprint
  end

  test "accepts sixteen components and rejects seventeen" do
    {input, output, revision, _components, _mapping} = fixture(1)

    uuid = fn n ->
      "018f0000-0000-7000-8000-" <>
        (n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0"))
    end

    components =
      Enum.map(1..16, fn n ->
        %{
          id: uuid.(100 + n),
          revision_id: @revision,
          definition_key: uuid.(200 + n),
          gross_minor: if(n == 1, do: 85, else: 1),
          discount_eligibility_key: "member",
          tax_treatment_key: "standard"
        }
      end)

    mapping =
      Enum.with_index(components, 1)
      |> Enum.map(fn {component, n} ->
        %{line_id: @line, definition_id: component.id, instance_id: uuid.(300 + n)}
      end)

    revision = %{
      revision
      | fingerprint: MembershipOfferRevision.Fingerprint.compute("offer", 1, "ZAR", components)
    }

    assert {:ok, result} = derive({input, output, revision, components, mapping})
    assert length(result.components) == 16

    assert {:error, _} =
             derive({input, output, revision, components ++ [hd(components)], mapping})
  end

  test "rejects a global claim even with a concrete key" do
    {input, _output, revision, components, mapping} = fixture()
    input = %{input | coupon: Map.put(input.coupon, :global, true)}
    {:ok, output} = Evaluator.evaluate(input)
    assert {:error, _} = derive({input, output, revision, components, mapping})
  end

  test "rejects mismatched source total when evaluator caps eligible lines" do
    {input, _, revision, components, mapping} = fixture(80)
    extra = %{hd(input.lines) | id: @a, line_no: 2, eligible?: false}

    input = %{
      input
      | lines: [%{hd(input.lines) | line_total_minor: 50, unit_price_minor: 50}, extra],
        coupon: %{input.coupon | discount_minor: 80}
    }

    {:ok, output} = Evaluator.evaluate(input)
    assert hd(output.applied_adjustments).discount_minor == 80
    assert output.discount_total_minor == 50
    assert {:error, _} = derive({input, output, revision, components, mapping})
  end

  test "retains all evaluated lines for source reconciliation in a mixed order" do
    {input, _, revision, components, mapping} = fixture(10)
    other = %{hd(input.lines) | id: @a, line_no: 2}
    input = %{input | lines: [hd(input.lines), other]}
    {:ok, output} = Evaluator.evaluate(input)
    assert {:ok, result} = derive({input, output, revision, components, mapping})
    assert Enum.map(result.lines, & &1.discount_minor) == [5, 5]
    assert result.source.applied_minor == Enum.sum(Enum.map(result.lines, & &1.discount_minor))
    assert Enum.sum(Enum.map(result.components, & &1.discount_minor)) == 5
  end

  test "rejects a membership line with quantity greater than one" do
    {input, _, revision, components, mapping} = fixture()
    input = %{input | lines: [%{hd(input.lines) | quantity: 2}]}
    {:ok, output} = Evaluator.evaluate(input)
    assert {:error, _} = derive({input, output, revision, components, mapping})
  end

  test "rejects manual sources without proof" do
    {input, _, revision, components, mapping} = fixture()

    input = %{
      input
      | coupon: nil,
        promotions: [%{input.coupon | source_kind: :manual_adjustment}]
    }

    {:ok, output} = Evaluator.evaluate(input)
    assert [%{source_kind: :manual_adjustment}] = output.applied_adjustments
    assert {:error, _} = derive({input, output, revision, components, mapping})
  end
end
