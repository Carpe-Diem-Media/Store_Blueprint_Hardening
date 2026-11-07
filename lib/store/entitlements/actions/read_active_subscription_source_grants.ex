defmodule Store.Entitlements.Actions.ReadActiveSubscriptionSourceGrants do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  alias Store.Entitlements.Queries.SubscriptionSourceVerificationQuery
  alias Store.Repo

  @impl true
  def run(input, _opts, _context) do
    with {:ok, query} <- SubscriptionSourceVerificationQuery.new(input.arguments) do
      read_grants(query)
    end
  end

  defp read_grants(%{source_ids: []}), do: {:ok, %{}}

  defp read_grants(query) do
    grants_by_source = Map.new(query.source_ids, &{&1, []})

    grants =
      query
      |> SubscriptionSourceVerificationQuery.to_ecto()
      |> Repo.all()
      |> Enum.reduce(grants_by_source, fn grant, acc ->
        Map.update!(acc, grant.source_id, &[grant | &1])
      end)
      |> Map.new(fn {source_id, source_grants} -> {source_id, Enum.reverse(source_grants)} end)

    {:ok, grants}
  end
end
