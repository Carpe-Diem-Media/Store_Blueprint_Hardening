defmodule Store.Repo.Migrations.AllowDigitalCatalogProducts do
  use Ecto.Migration

  def up do
    drop constraint(:products, :products_product_kind_value_check)

    create constraint(:products, :products_product_kind_value_check,
             check: "product_kind IN ('simple', 'subscription', 'digital')"
           )
  end

  def down do
    drop constraint(:products, :products_product_kind_value_check)

    create constraint(:products, :products_product_kind_value_check,
             check: "product_kind IN ('simple', 'subscription')"
           )
  end
end
