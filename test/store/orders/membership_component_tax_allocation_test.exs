defmodule Store.Orders.MembershipComponentTaxAllocationTest do
  use ExUnit.Case, async: true

  alias Store.Orders.MembershipComponentTaxAllocation

  @a "018f0000-0000-7000-8000-000000000001"
  @b "018f0000-0000-7000-8000-000000000002"
  @zero "018f0000-0000-7000-8000-000000000003"

  test "attributes accepted line tax using integer floor and binary instance UUID remainder" do
    rows = [%{instance_id: @b, net_minor: 50}, %{instance_id: @a, net_minor: 50}]
    assert {:ok, amounts} = MembershipComponentTaxAllocation.allocate(rows, 1)
    assert amounts == %{@a => 1, @b => 0}
    assert {:ok, ^amounts} = MembershipComponentTaxAllocation.allocate(Enum.reverse(rows), 1)
  end

  test "zero-net components never receive a tax remainder" do
    rows = [%{instance_id: @zero, net_minor: 0}, %{instance_id: @a, net_minor: 2}]
    assert {:ok, %{@a => 1, @zero => 0}} = MembershipComponentTaxAllocation.allocate(rows, 1)
  end

  test "rejects positive tax with zero total net and duplicate instance IDs" do
    assert {:error, :invalid_tax_allocation} =
             MembershipComponentTaxAllocation.allocate([%{instance_id: @a, net_minor: 0}], 1)

    assert {:error, :invalid_tax_allocation} =
             MembershipComponentTaxAllocation.allocate(
               [%{instance_id: @a, net_minor: 1}, %{instance_id: @a, net_minor: 1}],
               1
             )
  end

  test "accepts zero tax for a zero-net line" do
    assert {:ok, %{@a => 0}} =
             MembershipComponentTaxAllocation.allocate([%{instance_id: @a, net_minor: 0}], 0)
  end
end
