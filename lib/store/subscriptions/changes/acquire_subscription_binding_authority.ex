defmodule Store.Subscriptions.Changes.AcquireSubscriptionBindingAuthority do
  @moduledoc false

  use Ash.Resource.Change

  alias Store.Subscriptions.PaymentMethodAuthorityGate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case PaymentMethodAuthorityGate.lock_binding_for_transaction(
             changeset.data.user_id,
             changeset.data.provider
           ) do
        :ok ->
          changeset

        {:error, _reason} ->
          Ash.Changeset.add_error(
            changeset,
            "subscription payment method authority gate unavailable"
          )
      end
    end)
  end
end
