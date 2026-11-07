defmodule Store.Subscriptions.Actions.ReadAppliedAccessVerificationWindow do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  alias Store.Repo
  alias Store.Subscriptions.Queries.AppliedAccessVerificationQuery

  @impl true
  def run(input, _opts, _context) do
    input.arguments
    |> AppliedAccessVerificationQuery.new()
    |> case do
      {:ok, query} -> {:ok, Repo.all(AppliedAccessVerificationQuery.to_ecto(query))}
      {:error, reason} -> {:error, reason}
    end
  end
end
