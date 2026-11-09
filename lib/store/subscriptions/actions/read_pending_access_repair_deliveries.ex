defmodule Store.Subscriptions.Actions.ReadPendingAccessRepairDeliveries do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  alias Store.Repo
  alias Store.Subscriptions.Queries.PendingAccessRepairDeliveryQuery

  @impl true
  def run(input, _opts, _context) do
    with {:ok, query} <- PendingAccessRepairDeliveryQuery.new(input.arguments) do
      {:ok, Repo.all(PendingAccessRepairDeliveryQuery.to_ecto(query))}
    end
  end
end
