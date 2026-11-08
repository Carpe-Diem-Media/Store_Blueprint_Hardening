defmodule Store.Payments.PaymentIntent do
  @moduledoc """
  Payment intent lifecycle state machine with replay-safe transitions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  alias Ash.Resource.Change.OptimisticLock

  attributes do
    uuid_v7_primary_key(:id)

    attribute :order_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :amount_received_minor, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      default("USD")
      public?(true)
    end

    attribute :provider, Store.Payments.Types.Provider do
      allow_nil?(false)
      public?(true)
    end

    attribute :purpose, Store.Payments.Types.PaymentIntentPurpose do
      allow_nil?(false)
      default(:order_checkout)
      public?(true)
    end

    attribute :subscription_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :subscription_setup_generation, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(false)

      description(
        "Subscription payment method setup generation captured at local intent creation."
      )
    end

    attribute :setup_binding_applied_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
      description("Time when this setup intent first changed the subscription binding.")
    end

    attribute :provider_payment_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_request_reference, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_session_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_customer_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_payment_method_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_checkout_url, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_client_secret, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :payment_intent_key, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :state, Store.Payments.Types.PaymentIntentState do
      allow_nil?(false)
      default(:created)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  state_machine do
    initial_states([:created])
    default_initial_state(:created)

    transitions do
      transition(:submit, from: :created, to: :submitted)
      transition(:prepare_renewal_dispatch, from: :created, to: :submitted)
      transition(:mark_requires_action, from: :submitted, to: :requires_action)
      transition(:mark_succeeded, from: :submitted, to: :succeeded)
      transition(:mark_succeeded, from: :requires_action, to: :succeeded)
      transition(:correct_to_succeeded, from: :failed, to: :succeeded)
      transition(:mark_failed, from: :submitted, to: :failed)
      transition(:mark_failed, from: :requires_action, to: :failed)
      transition(:cancel, from: :created, to: :cancelled)
      transition(:cancel, from: :submitted, to: :cancelled)
      transition(:cancel, from: :requires_action, to: :cancelled)
    end
  end

  identities do
    identity(:unique_payment_intent_key, [:payment_intent_key])
  end

  actions do
    defaults([:read])

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_admin do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :create do
      accept([
        :order_id,
        :amount_received_minor,
        :currency,
        :provider,
        :purpose,
        :subscription_id,
        :provider_payment_id,
        :provider_request_reference,
        :provider_session_id,
        :provider_customer_ref,
        :provider_payment_method_ref,
        :provider_checkout_url,
        :provider_client_secret,
        :payment_intent_key
      ])
    end

    create :create_subscription_setup do
      description(
        "Persists the setup operation reserved by a Subscription generation transaction."
      )

      public?(false)

      accept([
        :amount_received_minor,
        :currency,
        :provider,
        :subscription_id,
        :provider_customer_ref,
        :payment_intent_key,
        :subscription_setup_generation
      ])

      validate(fn changeset, _context ->
        generation = Ash.Changeset.get_attribute(changeset, :subscription_setup_generation)

        if is_integer(generation) and generation > 0 and
             is_binary(Ash.Changeset.get_attribute(changeset, :subscription_id)) do
          :ok
        else
          {:error,
           field: :subscription_setup_generation, message: "must be a positive generation"}
        end
      end)

      change(set_attribute(:purpose, :subscription_payment_method_update))
    end

    create :create_or_reuse do
      accept([
        :order_id,
        :amount_received_minor,
        :currency,
        :provider,
        :purpose,
        :subscription_id,
        :provider_payment_id,
        :provider_request_reference,
        :provider_session_id,
        :provider_customer_ref,
        :provider_payment_method_ref,
        :provider_checkout_url,
        :provider_client_secret,
        :payment_intent_key
      ])

      upsert?(true)
      upsert_identity(:unique_payment_intent_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :set_provider_reference do
      require_atomic?(false)

      accept([
        :provider,
        :purpose,
        :subscription_id,
        :provider_payment_id,
        :provider_session_id,
        :provider_customer_ref,
        :provider_payment_method_ref,
        :provider_checkout_url,
        :provider_client_secret
      ])
    end

    update :mark_setup_binding_applied do
      description(
        "Records binding application in the same transaction as the Subscription update."
      )

      public?(false)
      require_atomic?(false)
      accept([])

      change(
        filter(
          expr(
            state == :succeeded and purpose == :subscription_payment_method_update and
              not is_nil(subscription_setup_generation) and
              is_nil(setup_binding_applied_at)
          )
        )
      )

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :setup_binding_applied_at,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )
      end)

      change(fn changeset, context ->
        OptimisticLock.change(changeset, [attribute: :version], context)
      end)
    end

    update :prepare_renewal_dispatch do
      require_atomic?(false)
      accept([:provider_customer_ref, :provider_payment_method_ref])
      change({Store.Support.Governance.TransitionState, target: :submitted})
    end

    update :submit do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :submitted})
    end

    update :mark_requires_action do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :requires_action})
    end

    update :mark_succeeded do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :succeeded})
    end

    update :correct_to_succeeded do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :succeeded})
    end

    update :mark_failed do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :failed})
    end

    update :cancel do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :cancelled})
    end
  end

  code_interface do
    define(:list_for_admin, action: :read_for_admin)
    define(:get_for_admin, action: :get_for_admin, args: [:id])
  end

  json_api do
    type("payment_intent")
    includes([])
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("payment_intents")
    repo(Store.Repo)

    custom_indexes do
      index([:state], name: "payment_intents_state_index")
      index([:purpose], name: "payment_intents_purpose_index")
      index([:order_id], name: "payment_intents_order_id_index")
      index([:subscription_id], name: "payment_intents_subscription_id_index")
      index([:payment_intent_key], name: "payment_intents_payment_intent_key_index")
      index([:provider], name: "payment_intents_provider_index")
      index([:provider_payment_id], name: "payment_intents_provider_payment_id_index")
      index([:provider_session_id], name: "payment_intents_provider_session_id_index")

      index([:provider_request_reference],
        name: "payment_intents_provider_request_reference_index"
      )

      index([:provider_customer_ref], name: "payment_intents_provider_customer_ref_index")

      index([:provider_payment_method_ref],
        name: "payment_intents_provider_payment_method_ref_index"
      )

      index([:provider, :provider_payment_id],
        unique: true,
        where: "provider_payment_id IS NOT NULL",
        name: "payment_intents_unique_provider_payment_id_index"
      )

      index([:provider, :provider_session_id],
        unique: true,
        where: "provider_session_id IS NOT NULL",
        name: "payment_intents_unique_provider_session_id_index"
      )

      index([:provider, :provider_request_reference],
        unique: true,
        where: "provider_request_reference IS NOT NULL",
        name: "payment_intents_unique_provider_request_reference_index"
      )
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:create_or_reuse) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:create_subscription_setup) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:submit) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:prepare_renewal_dispatch) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:mark_requires_action) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_succeeded) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:correct_to_succeeded) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:mark_failed) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:cancel) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:set_provider_reference) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_setup_binding_applied) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end
  end
end
