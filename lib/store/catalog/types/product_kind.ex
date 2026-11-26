defmodule Store.Catalog.Types.ProductKind do
  @moduledoc """
  Catalog product kind for checkout and fulfillment routing.
  """

  use Ash.Type.Enum,
    values: [:simple, :subscription, :digital]
end
