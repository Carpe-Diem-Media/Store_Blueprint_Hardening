defmodule Store.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends password reset emails.
  """

  use AshAuthentication.Sender
  use StoreWeb, :verified_routes
  alias Store.Accounts.Emails

  @impl AshAuthentication.Sender
  def send(user, token, _opts) do
    case Emails.deliver_reset_password_instructions(
           user,
           url(~p"/password-reset/#{token}")
         ) do
      {:ok, _email} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
