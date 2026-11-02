defmodule Store.Accounts.Token do
  @moduledoc """
  Token resource backing AshAuthentication token flows.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Accounts

  actions do
    read :read do
      primary?(true)
      public?(false)
    end
  end

  postgres do
    table("tokens")
    repo(Store.Repo)

    custom_indexes do
      index([:subject], name: "tokens_subject_index")
      index([:expires_at], name: "tokens_expires_at_index")
      index([:purpose, :subject], name: "tokens_purpose_subject_index")
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy always() do
      forbid_if(always())
    end
  end
end
