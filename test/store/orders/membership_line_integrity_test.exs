defmodule Store.Orders.MembershipLineIntegrityTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL

  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Support.ID.UUIDv7

  test "database rejects an occurrence without an offer revision" do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{
        order_ref: "ORDMEM#{System.unique_integer([:positive])}"
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    line =
      OrderLineItem
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        line_no: 1,
        currency: "USD",
        sku_snapshot: "SKU",
        product_title_snapshot: "Membership",
        quantity: 1,
        unit_price_minor: 100,
        line_total_minor: 100,
        net_line_total_minor: 100
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    occurrence = Ecto.UUID.dump!(UUIDv7.generate())
    id = Ecto.UUID.dump!(line.id)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE order_line_items SET membership_occurrence_key_snapshot = $1 WHERE id = $2",
               [occurrence, id]
             )
  end
end
