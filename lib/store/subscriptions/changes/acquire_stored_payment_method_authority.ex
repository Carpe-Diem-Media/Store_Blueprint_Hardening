defmodule Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority do
  @moduledoc false

  use Ash.Resource.Change

  alias Store.Subscriptions.PaymentMethodAuthorityGate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      attributes =
        case changeset.action_type do
          :create ->
            %{
              user_id: Ash.Changeset.get_attribute(changeset, :user_id),
              provider: Ash.Changeset.get_attribute(changeset, :provider),
              customer_ref: Ash.Changeset.get_attribute(changeset, :provider_customer_ref),
              payment_method_ref:
                Ash.Changeset.get_attribute(changeset, :provider_payment_method_ref),
              ensure_owner?: true
            }

          :update ->
            %{
              user_id: changeset.data.user_id,
              provider: changeset.data.provider,
              customer_ref: changeset.data.provider_customer_ref,
              payment_method_ref: changeset.data.provider_payment_method_ref,
              ensure_owner?: false
            }
        end

      with :ok <-
             PaymentMethodAuthorityGate.lock_binding_for_transaction(
               attributes.user_id,
               attributes.provider
             ),
           :ok <-
             PaymentMethodAuthorityGate.lock_method_for_transaction(
               attributes.provider,
               attributes.customer_ref,
               attributes.payment_method_ref
             ),
           :ok <- ensure_identity_owner(attributes) do
        changeset
      else
        {:error, :foreign_identity_owner} ->
          Ash.Changeset.add_error(changeset, "provider payment method belongs to another user")

        {:error, _reason} ->
          Ash.Changeset.add_error(changeset, "payment method authority gate unavailable")
      end
    end)
  end

  defp ensure_identity_owner(%{ensure_owner?: false}), do: :ok

  defp ensure_identity_owner(attributes) do
    PaymentMethodAuthorityGate.ensure_identity_owner(
      attributes.user_id,
      attributes.provider,
      attributes.customer_ref,
      attributes.payment_method_ref
    )
  end
end
