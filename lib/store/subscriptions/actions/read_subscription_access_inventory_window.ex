defmodule Store.Subscriptions.Actions.ReadSubscriptionAccessInventoryWindow do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  alias Store.Repo
  alias Store.Subscriptions.Queries.SubscriptionAccessInventoryQuery

  @impl true
  def run(input, _opts, _context) do
    with {:ok, query} <- SubscriptionAccessInventoryQuery.new(input.arguments) do
      {:ok, Repo.all(SubscriptionAccessInventoryQuery.to_ecto(query))}
    end
  end
end
