defmodule Store.Subscriptions.Facade do
  @moduledoc """
  Subscription surfaces for user/admin reads and system orchestration.
  """

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Carts.CartItem
  alias Store.Catalog.{Product, Variant}
  alias Store.Checkout.CheckoutDraft
  alias Store.Comms
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Orders
  alias Store.Orders.Order
  alias Store.Orders.OrderLineItem
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.RenewalCancellationRemediationInput
  alias Store.Payments.Inputs.RenewalOrderPaymentApplicationInput
  alias Store.Payments.Inputs.RenewalPaymentApplicationInput
  alias Store.Payments.{PaymentIntent, Providers}
  alias Store.Payments.Types.RenewalCollectionChargeRequest
  alias Store.Pricing.{Contract, TaxRate, TaxShippingContract, TaxShippingEvaluator}
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.Types.{QuoteEvidence, QuoteOption}
  alias Store.Subscriptions
  alias Store.Subscriptions.Facade.StaleWrite

  alias Store.Subscriptions.Inputs.{
    EstablishAccessEffectInput,
    QueueSubscriptionPlanChangeInput,
    QueueSubscriptionVariantChangeInput,
    StartSubscriptionPaymentMethodUpdateInput
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.{
    AttachAndClaimInput,
    CancellationReservationInput,
    FenceInput,
    StartInput
  }

  alias Store.Subscriptions.Queries.{
    AdminSubscriptionIndexQuery,
    UserSubscriptionIndexQuery
  }

  alias Store.Subscriptions.{
    AccessEffect,
    AccessEffectCurrentnessFence,
    AccessEffectTargetOrder,
    ContractChange,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    RenewalCollectionDispatchPolicy,
    Scheduler,
    StoredPaymentMethod,
    Subscription,
    SubscriptionItem,
    SubscriptionPlan,
    Types.SubscriptionDetail,
    VariantSubscriptionPlan
  }

  alias Store.Support.AshNotifications
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  @default_due_limit 100
  @unresolved_contract_message "subscription commercial contract is unresolved"
  @shipping_surge_percent_bps 2_000
  @shipping_surge_absolute_minor 5_000
  @renewal_authority_withdrawn_code "RENEWAL_AUTHORITY_WITHDRAWN"
  @effective_access_effect_projection_reason "effective_access_effect_applied"
  @non_effective_access_effect_projection_reason "non_effective_access_effect_applied"
  @payment_retry_reasons MapSet.new([
                           "PAYMENT_METHOD_REQUIRED",
                           "PAYMENT_FAILED",
                           "PAYMENT_AUTHENTICATION_REQUIRED"
                         ])
  @hard_retry_suppressed_reasons MapSet.new([
                                   "VARIANT_UNAVAILABLE",
                                   "VARIANT_PLAN_UNAVAILABLE",
                                   "SHIPPING_PROFILE_MISSING",
                                   "SHIPPING_UNAVAILABLE",
                                   "SHIPPING_COST_SURGE"
                                 ])
  @max_contract_change_stale_retries 2

  @spec establish_access_effect_for_system(EstablishAccessEffectInput.t()) ::
          {:ok, AccessEffect.t()} | {:error, Error.t() | term()}
  def establish_access_effect_for_system(%EstablishAccessEffectInput{} = input) do
    with {:ok, canonical_input} <- EstablishAccessEffectInput.new(Map.from_struct(input)) do
      with_access_effect_transaction(fn ->
        establish_access_effect_in_transaction(canonical_input)
      end)
    end
  end

  def establish_access_effect_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed AccessEffect input is required")}
  end

  @spec get_current_access_effect_for_system(Subscription.t()) ::
          {:ok, AccessEffect.t() | nil} | {:error, Error.t() | term()}
  def get_current_access_effect_for_system(%Subscription{id: subscription_id}) do
    read_current_access_effect(subscription_id)
  end

  def get_current_access_effect_for_system(_subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "typed Subscription is required")}
  end

  @spec validate_complete_bound_renewal_attempt_for_system(RenewalAttempt.t()) ::
          :ok | {:error, Error.t() | term()}
  def validate_complete_bound_renewal_attempt_for_system(%RenewalAttempt{} = attempt),
    do: ensure_complete_bound_renewal_attempt(attempt)

  def validate_complete_bound_renewal_attempt_for_system(_attempt) do
    {:error, Error.new("VALIDATION_ERROR", "typed RenewalAttempt is required")}
  end

  @spec mark_access_effect_pending_for_system(AccessEffect.t()) ::
          {:ok, AccessEffect.t()} | {:error, Error.t() | term()}
  def mark_access_effect_pending_for_system(%AccessEffect{} = effect) do
    with_access_effect_transaction(fn ->
      transition_access_effect(effect, :required, :pending, :mark_pending_from_required)
    end)
  end

  @spec mark_access_effect_applied_for_system(AccessEffect.t()) ::
          {:ok, AccessEffect.t()} | {:error, Error.t() | term()}
  def mark_access_effect_applied_for_system(%AccessEffect{} = effect) do
    with_access_effect_transaction(fn ->
      transition_access_effect(effect, :pending, :applied, :mark_applied)
    end)
  end

  @spec mark_access_effect_failed_retryable_for_system(AccessEffect.t()) ::
          {:ok, AccessEffect.t()} | {:error, Error.t() | term()}
  def mark_access_effect_failed_retryable_for_system(%AccessEffect{} = effect) do
    with_access_effect_transaction(fn ->
      transition_access_effect(effect, :pending, :failed_retryable, :mark_failed_retryable)
    end)
  end

  @spec retry_access_effect_for_system(AccessEffect.t()) ::
          {:ok, AccessEffect.t()} | {:error, Error.t() | term()}
  def retry_access_effect_for_system(%AccessEffect{} = effect) do
    with_access_effect_transaction(fn ->
      transition_access_effect(effect, :failed_retryable, :pending, :retry_to_pending)
    end)
  end

  @spec execute_effective_access_effect_for_system(String.t()) ::
          {:ok, :applied | :applied_projection_pending | :superseded | :noop}
          | {:error, Error.t() | term()}
  def execute_effective_access_effect_for_system(effect_id) when is_binary(effect_id) do
    if Repo.in_transaction?() do
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "EFFECTIVE AccessEffect execution must own its correctness transaction"
       )}
    else
      Repo.transaction(fn -> execute_effective_access_effect_in_transaction(effect_id) end)
      |> handle_effective_access_effect_transaction(effect_id)
    end
  end

  def execute_effective_access_effect_for_system(_effect_id) do
    {:error, Error.new("VALIDATION_ERROR", "AccessEffect id must be a UUID")}
  end

  defp handle_effective_access_effect_transaction(
         {:ok, {:applied, effect, user_ids}},
         _effect_id
       ) do
    :ok =
      AshNotifications.notify_post_commit([],
        context: %{
          flow: :execute_effective_access_effect,
          subscription_id: effect.subscription_id,
          access_effect_id: effect.id
        }
      )

    case deliver_access_effect_projection(
           effect,
           user_ids,
           @effective_access_effect_projection_reason
         ) do
      :ok -> {:ok, :applied}
      {:error, _reason} -> {:ok, :applied_projection_pending}
    end
  end

  defp handle_effective_access_effect_transaction({:ok, {:superseded, _effect}}, _effect_id),
    do: {:ok, :superseded}

  defp handle_effective_access_effect_transaction({:ok, :noop}, _effect_id),
    do: {:ok, :noop}

  defp handle_effective_access_effect_transaction(
         {:error, {:effective_execution_failure, reason}},
         effect_id
       ) do
    case record_effective_access_effect_failure(effect_id) do
      :ok ->
        {:error, Normalize.normalize(reason)}

      {:error, recording_reason} ->
        {:error,
         Error.new(
           "INTERNAL_ERROR",
           "EFFECTIVE AccessEffect failure could not be recorded",
           %{
             execution_failure: inspect(reason),
             failure_recording_failure: inspect(recording_reason)
           }
         )}
    end
  end

  defp handle_effective_access_effect_transaction(
         {:error, {:effective_proof_failure, reason}},
         _effect_id
       ),
       do: {:error, Normalize.normalize(reason)}

  defp handle_effective_access_effect_transaction({:error, reason}, _effect_id),
    do: {:error, Normalize.normalize(reason)}

  @spec execute_suspension_access_effect_for_system(String.t()) ::
          {:ok, :applied | :applied_projection_pending | :superseded | :noop}
          | {:error, Error.t() | term()}
  def execute_suspension_access_effect_for_system(effect_id) when is_binary(effect_id) do
    if Repo.in_transaction?() do
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "NON_EFFECTIVE AccessEffect execution must own its correctness transaction"
       )}
    else
      Repo.transaction(fn -> execute_non_effective_access_effect_in_transaction(effect_id) end)
      |> handle_non_effective_access_effect_transaction(effect_id)
    end
  end

  def execute_suspension_access_effect_for_system(_effect_id) do
    {:error, Error.new("VALIDATION_ERROR", "AccessEffect id must be a UUID")}
  end

  defp handle_non_effective_access_effect_transaction(
         {:ok, {:applied, effect, user_ids}},
         _effect_id
       ) do
    :ok =
      AshNotifications.notify_post_commit([],
        context: %{
          flow: :execute_suspension_access_effect,
          subscription_id: effect.subscription_id,
          access_effect_id: effect.id
        }
      )

    case deliver_access_effect_projection(
           effect,
           user_ids,
           @non_effective_access_effect_projection_reason
         ) do
      :ok -> {:ok, :applied}
      {:error, _reason} -> {:ok, :applied_projection_pending}
    end
  end

  defp handle_non_effective_access_effect_transaction(
         {:ok, {:superseded, _effect}},
         _effect_id
       ),
       do: {:ok, :superseded}

  defp handle_non_effective_access_effect_transaction({:ok, :noop}, _effect_id),
    do: {:ok, :noop}

  defp handle_non_effective_access_effect_transaction(
         {:error, {:non_effective_execution_failure, reason}},
         effect_id
       ) do
    case record_non_effective_access_effect_failure(effect_id) do
      :ok ->
        {:error, Normalize.normalize(reason)}

      {:error, recording_reason} ->
        non_effective_failure_recording_error(reason, recording_reason)
    end
  end

  defp handle_non_effective_access_effect_transaction(
         {:error, {:non_effective_proof_failure, reason}},
         _effect_id
       ),
       do: {:error, Normalize.normalize(reason)}

  defp handle_non_effective_access_effect_transaction({:error, reason}, _effect_id),
    do: {:error, Normalize.normalize(reason)}

  defp non_effective_failure_recording_error(execution_reason, recording_reason) do
    {:error,
     Error.new(
       "INTERNAL_ERROR",
       "NON_EFFECTIVE AccessEffect failure could not be recorded",
       %{
         execution_failure: inspect(execution_reason),
         failure_recording_failure: inspect(recording_reason)
       }
     )}
  end

  @spec repair_suspension_access_effect_projection_for_system(String.t()) ::
          :ok | {:error, Error.t() | term()}
  def repair_suspension_access_effect_projection_for_system(effect_id)
      when is_binary(effect_id) do
    with {:ok, effect} <- fetch_access_effect(effect_id),
         true <- effect.status == :applied and is_list(effect.projection_user_ids),
         :ok <-
           deliver_access_effect_projection(
             effect,
             effect.projection_user_ids,
             access_effect_projection_reason(effect)
           ) do
      :ok
    else
      false -> :ok
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  def repair_suspension_access_effect_projection_for_system(_effect_id) do
    {:error, Error.new("VALIDATION_ERROR", "AccessEffect id must be a UUID")}
  end

  @spec run_subscription_access_effect_recovery_for_system(keyword()) ::
          {:ok,
           %{
             execution_count: non_neg_integer(),
             effective_execution_count: non_neg_integer(),
             projection_count: non_neg_integer(),
             failed_count: non_neg_integer(),
             as_of: DateTime.t(),
             execution_cursor: %{timestamp: DateTime.t(), id: Ecto.UUID.t()} | nil,
             effective_execution_cursor: %{timestamp: DateTime.t(), id: Ecto.UUID.t()} | nil,
             projection_cursor: %{timestamp: DateTime.t(), id: Ecto.UUID.t()} | nil
           }}
          | {:error, Error.t() | term()}
  def run_subscription_access_effect_recovery_for_system(opts \\ [])

  def run_subscription_access_effect_recovery_for_system(opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_due_limit) |> bounded_due_limit()

    with :ok <- validate_effective_execution_cursor(opts),
         {:ok, as_of} <- recovery_as_of(opts),
         {:ok, projection_effects} <- recovery_effects(opts, :projection, as_of, limit),
         {:ok, recoverable_effects} <- recovery_effects(opts, :execution, as_of, limit),
         {:ok, effective_effects} <- recovery_effects(opts, :effective_execution, as_of, limit) do
      execution =
        Enum.reduce(recoverable_effects, %{completed: 0, failed: 0}, &execute_effect_result/2)

      effective_execution =
        Enum.reduce(effective_effects, %{completed: 0, failed: 0}, &execute_effect_result/2)

      projection =
        Enum.reduce(
          projection_effects,
          %{completed: 0, failed: 0},
          &repair_effect_projection_result/2
        )

      {:ok,
       %{
         execution_count: execution.completed,
         effective_execution_count: effective_execution.completed,
         projection_count: projection.completed,
         failed_count: execution.failed + effective_execution.failed + projection.failed,
         as_of: as_of,
         execution_cursor:
           if(Keyword.get(opts, :skip_execution, false),
             do: nil,
             else: recovery_cursor(recoverable_effects, limit, :updated_at)
           ),
         effective_execution_cursor:
           if(Keyword.get(opts, :skip_effective_execution, false),
             do: nil,
             else: recovery_cursor(effective_effects, limit, :updated_at)
           ),
         projection_cursor:
           if(Keyword.get(opts, :skip_projection, false),
             do: nil,
             else: recovery_cursor(projection_effects, limit, :inserted_at)
           )
       }}
    end
  end

  def run_subscription_access_effect_recovery_for_system(_opts) do
    {:error,
     Error.new("VALIDATION_ERROR", "AccessEffect recovery options must be a keyword list")}
  end

  @spec run_access_effect_target_order_reconciliation_for_system(keyword()) ::
          {:ok,
           %{
             repaired_count: non_neg_integer(),
             noop_count: non_neg_integer(),
             already_covered_count: non_neg_integer(),
             as_of: DateTime.t(),
             candidate_cursor: %{inserted_at: DateTime.t(), id: Ecto.UUID.t()} | nil
           }}
          | {:error, Error.t() | term()}
  def run_access_effect_target_order_reconciliation_for_system(opts \\ [])

  def run_access_effect_target_order_reconciliation_for_system(opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_due_limit) |> bounded_due_limit()

    with {:ok, as_of} <- recovery_as_of(opts),
         :ok <- validate_target_order_cursor(opts),
         {:ok, effects} <- target_order_candidates(opts, as_of, limit),
         {:ok, counts} <- reconcile_target_order_page(effects) do
      {:ok,
       %{
         repaired_count: counts.repaired,
         noop_count: counts.noop,
         already_covered_count: counts.already_covered,
         as_of: as_of,
         candidate_cursor: target_order_cursor(effects, limit)
       }}
    end
  end

  def run_access_effect_target_order_reconciliation_for_system(_opts) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "AccessEffect target-order reconciliation options must be a keyword list"
     )}
  end

  @spec list_subscriptions_for_user(map(), UserSubscriptionIndexQuery.t()) ::
          {:ok, [Subscription.t()]} | {:error, Error.t() | term()}
  def list_subscriptions_for_user(actor, %UserSubscriptionIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:read_for_user, %{}, actor: actor)
      |> maybe_filter_subscription_status(query.status)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, subscriptions} ->
        case Ash.load(subscriptions, [:subscription_plan],
               domain: Subscriptions,
               authorize?: false,
               context: %{system?: true}
             ) do
          {:ok, loaded} ->
            loaded
            |> maybe_filter_subscription_plan_key(query.plan_key)
            |> then(&{:ok, &1})

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def list_subscriptions_for_user(_actor, _query) do
    {:error, Error.new("VALIDATION_ERROR", "actor and user subscription query are required")}
  end

  @spec get_subscription_for_user(map(), Ecto.UUID.t()) ::
          {:ok, Subscription.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_for_user(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:get_for_user, %{id: subscription_id}, actor: actor)

    case Ash.read_one(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Subscription{} = subscription} ->
        subscription
        |> Ash.load([:subscription_plan, :items],
          domain: Subscriptions,
          authorize?: false,
          context: %{system?: true}
        )
        |> case do
          {:ok, loaded} -> {:ok, loaded}
          {:error, reason} -> {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def get_subscription_for_user(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec list_subscriptions_for_admin(map(), AdminSubscriptionIndexQuery.t()) ::
          {:ok, [Subscription.t()]} | {:error, Error.t() | term()}
  def list_subscriptions_for_admin(actor, %AdminSubscriptionIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> maybe_filter_subscription_status(query.status)
      |> maybe_filter_subscription_user(query.user_id)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, subscriptions} ->
        subscriptions
        |> maybe_filter_subscription_plan_key(query.plan_key)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def list_subscriptions_for_admin(_actor, _query) do
    {:error, Error.new("VALIDATION_ERROR", "actor and admin subscription query are required")}
  end

  @spec get_subscription_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, Subscription.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_for_admin(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    ash_query =
      Subscription
      |> Ash.Query.for_read(:get_for_admin, %{id: subscription_id}, actor: actor)
      |> Ash.Query.load([:subscription_plan, :items])

    case Ash.read_one(ash_query, domain: Subscriptions, actor: actor) do
      {:ok, subscription} -> {:ok, subscription}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  def get_subscription_for_admin(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec get_subscription_detail_for_user(map(), Ecto.UUID.t()) ::
          {:ok, SubscriptionDetail.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_detail_for_user(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, subscription} <- get_subscription_for_user(actor, subscription_id) do
      build_subscription_detail_result(subscription)
    end
  end

  def get_subscription_detail_for_user(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec get_subscription_detail_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, SubscriptionDetail.t() | nil} | {:error, Error.t() | term()}
  def get_subscription_detail_for_admin(actor, subscription_id)
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, subscription} <- get_subscription_for_admin(actor, subscription_id) do
      build_subscription_detail_result(subscription)
    end
  end

  def get_subscription_detail_for_admin(_actor, _subscription_id) do
    {:error, Error.new("VALIDATION_ERROR", "actor and subscription_id are required")}
  end

  @spec queue_subscription_plan_change_for_user(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionPlanChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_plan_change_for_user(
        actor,
        subscription_id,
        %QueueSubscriptionPlanChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_plan_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_plan_change_for_user(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue plan change input are required"
     )}
  end

  @spec queue_subscription_plan_change_for_admin(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionPlanChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_plan_change_for_admin(
        actor,
        subscription_id,
        %QueueSubscriptionPlanChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_plan_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_plan_change_for_admin(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue plan change input are required"
     )}
  end

  @spec queue_subscription_variant_change_for_user(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionVariantChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_variant_change_for_user(
        actor,
        subscription_id,
        %QueueSubscriptionVariantChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_variant_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_variant_change_for_user(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue variant change input are required"
     )}
  end

  @spec queue_subscription_variant_change_for_admin(
          map(),
          Ecto.UUID.t(),
          QueueSubscriptionVariantChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def queue_subscription_variant_change_for_admin(
        actor,
        subscription_id,
        %QueueSubscriptionVariantChangeInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      queue_variant_change_for_subscription(actor, subscription, input)
    end
  end

  def queue_subscription_variant_change_for_admin(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and queue variant change input are required"
     )}
  end

  @doc false
  @spec queue_plan_change_for_subscription(
          map(),
          Subscription.t(),
          QueueSubscriptionPlanChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  defp queue_plan_change_for_subscription(
         actor,
         %Subscription{} = subscription,
         %QueueSubscriptionPlanChangeInput{} = input
       )
       when is_map(actor) do
    with :ok <- ensure_input_subscription_id(input.subscription_id, subscription.id) do
      queue_plan_change(subscription, input.subscription_plan_id, actor)
    end
  end

  defp queue_plan_change_for_subscription(_actor, _subscription, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription, and queue plan change input are required"
     )}
  end

  @doc false
  @spec queue_variant_change_for_subscription(
          map(),
          Subscription.t(),
          QueueSubscriptionVariantChangeInput.t()
        ) :: {:ok, Subscription.t()} | {:error, Error.t() | term()}
  defp queue_variant_change_for_subscription(
         actor,
         %Subscription{} = subscription,
         %QueueSubscriptionVariantChangeInput{} = input
       )
       when is_map(actor) do
    with :ok <- ensure_input_subscription_id(input.subscription_id, subscription.id) do
      queue_variant_change(subscription, input.variant_id, actor)
    end
  end

  defp queue_variant_change_for_subscription(_actor, _subscription, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription, and queue variant change input are required"
     )}
  end

  @spec start_subscription_payment_method_update_for_user(
          map(),
          Ecto.UUID.t(),
          StartSubscriptionPaymentMethodUpdateInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def start_subscription_payment_method_update_for_user(
        actor,
        subscription_id,
        %StartSubscriptionPaymentMethodUpdateInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      start_payment_method_update(subscription)
    end
  end

  def start_subscription_payment_method_update_for_user(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and payment method update input are required"
     )}
  end

  @spec start_subscription_payment_method_update_for_admin(
          map(),
          Ecto.UUID.t(),
          StartSubscriptionPaymentMethodUpdateInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def start_subscription_payment_method_update_for_admin(
        actor,
        subscription_id,
        %StartSubscriptionPaymentMethodUpdateInput{} = input
      )
      when is_map(actor) and is_binary(subscription_id) do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         :ok <- ensure_input_subscription_id(input.subscription_id, subscription_id) do
      start_payment_method_update(subscription)
    end
  end

  def start_subscription_payment_method_update_for_admin(_actor, _subscription_id, _input) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "actor, subscription_id, and payment method update input are required"
     )}
  end

  @spec handle_payment_method_update_succeeded_for_system(Ecto.UUID.t()) ::
          :ok | {:error, Error.t() | term()}
  def handle_payment_method_update_succeeded_for_system(payment_intent_id)
      when is_binary(payment_intent_id) do
    with {:ok, %PaymentIntent{} = payment_intent} <-
           fetch_payment_intent_for_system(payment_intent_id),
         :ok <- ensure_setup_payment_intent(payment_intent),
         {:ok, %Subscription{} = subscription} <-
           fetch_subscription_for_renewal(payment_intent.subscription_id),
         {:ok, result} <- persist_updated_payment_method(subscription, payment_intent) do
      maybe_enqueue_immediate_collection_retry(result.subscription, result.retry_now?)
    end
  end

  def handle_payment_method_update_succeeded_for_system(_payment_intent_id) do
    {:error, Error.new("VALIDATION_ERROR", "payment_intent_id must be a UUID")}
  end

  @spec list_variant_subscription_plan_options_for_system(Ecto.UUID.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t() | term()}
  def list_variant_subscription_plan_options_for_system(variant_id, opts \\ [])

  def list_variant_subscription_plan_options_for_system(variant_id, opts)
      when is_binary(variant_id) and is_list(opts) do
    selected_plan_key = Keyword.get(opts, :selected_plan_key)

    with {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(variant_id),
         {:ok, plan_pairs} <- fetch_active_plans_for_variant(variant_id) do
      {:ok, build_plan_options_for_variant(variant, plan_pairs, selected_plan_key)}
    end
  end

  def list_variant_subscription_plan_options_for_system(_variant_id, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID")}
  end

  defp build_subscription_detail_result(nil), do: {:ok, nil}

  defp build_subscription_detail_result(%Subscription{} = subscription) do
    with {:ok, loaded_subscription} <- load_subscription_detail_relationships(subscription),
         {:ok, renewal_attempts} <- list_recent_renewal_attempts(loaded_subscription.id),
         {:ok, plan_targets} <- build_plan_targets(loaded_subscription),
         {:ok, variant_targets} <- build_variant_targets(loaded_subscription) do
      {:ok,
       %SubscriptionDetail{
         subscription: loaded_subscription,
         renewal_attempts: renewal_attempts,
         plan_targets: plan_targets,
         variant_targets: variant_targets,
         action_capabilities: action_capabilities_for_subscription(loaded_subscription)
       }}
    end
  end

  defp load_subscription_detail_relationships(%Subscription{} = subscription) do
    subscription
    |> Ash.load(
      [
        :subscription_plan,
        :pending_subscription_plan,
        :variant,
        :pending_variant,
        :stored_payment_method,
        :items
      ],
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
    |> case do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp list_recent_renewal_attempts(subscription_id) when is_binary(subscription_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(5)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, attempts} -> {:ok, attempts}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp build_plan_targets(%Subscription{} = subscription) do
    variant_id = effective_variant_id(subscription)
    selected_plan_id = effective_plan_id(subscription)

    with {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(variant_id),
         {:ok, plan_pairs} <- fetch_active_plans_for_variant(variant_id) do
      {:ok, build_plan_target_options(variant, plan_pairs, selected_plan_id)}
    end
  end

  defp build_variant_targets(%Subscription{} = subscription) do
    current_variant_id = effective_variant_id(subscription)
    selected_variant_id = effective_variant_id(subscription)
    plan_id = effective_plan_id(subscription)

    with {:ok, %Variant{} = current_variant} <- fetch_variant_for_renewal(current_variant_id),
         {:ok, variants} <-
           fetch_variant_targets_for_product_plan(current_variant.product_id, plan_id),
         {:ok, plan} <- fetch_plan(plan_id) do
      {:ok,
       Enum.map(variants, fn variant ->
         pricing = resolve_subscription_pricing(variant, plan)

         %{
           id: variant.id,
           label: variant.title || variant.sku || variant.id,
           price_minor: pricing.amount_minor,
           currency: pricing.currency,
           selected?: variant.id == selected_variant_id
         }
       end)}
    end
  end

  defp action_capabilities_for_subscription(%Subscription{} = subscription) do
    provider = Providers.normalize_provider(subscription.provider)

    can_queue_change? =
      subscription.status in [:active, :past_due] and not subscription.cancel_at_period_end

    %{
      can_cancel_now?: subscription.status in [:active, :past_due, :suspended],
      can_cancel_at_period_end?: subscription.status in [:active, :past_due, :suspended],
      can_queue_plan_change?: can_queue_change?,
      can_queue_variant_change?: can_queue_change?,
      can_update_payment_method?: payment_method_update_supported?(subscription),
      payment_method_update_provider: if(provider == :stripe, do: :stripe, else: nil)
    }
  end

  defp payment_method_update_supported?(%Subscription{} = subscription) do
    Providers.normalize_provider(subscription.provider) == :stripe and
      subscription.billing_mode == :merchant_managed and
      stripe_publishable_key() not in [nil, ""] and
      is_binary(subscription.provider_customer_ref)
  end

  defp queue_plan_change(subscription, target_plan_id, actor) do
    with :ok <- ensure_queueable_subscription(subscription) do
      persist_contract_change(subscription, {:plan_change, target_plan_id}, actor, :queue_change)
    end
  end

  defp queue_variant_change(subscription, target_variant_id, actor) do
    with :ok <- ensure_queueable_subscription(subscription) do
      persist_contract_change(
        subscription,
        {:variant_change, target_variant_id},
        actor,
        :queue_change
      )
    end
  end

  defp future_target_base(%Subscription{}, %ContractChange{} = contract_change),
    do: future_target_base_from_contract_change(contract_change)

  defp future_target_base(%Subscription{} = subscription, nil) do
    case current_bound_renewal_attempt(subscription) do
      {:ok, %RenewalAttempt{} = attempt} ->
        with :ok <- ensure_complete_bound_renewal_attempt(attempt),
             {:ok, revision} <- fetch_plan_revision(attempt.plan_revision_id) do
          {:ok,
           %{
             subscription_plan_id: revision.subscription_plan_id,
             plan_revision_id: attempt.plan_revision_id,
             plan_revision: revision,
             target_variant_id: attempt.variant_id,
             target_quantity: attempt.quantity,
             target_amount_minor: attempt.amount_minor,
             target_currency: attempt.currency,
             effective_at: attempt.period_end_at
           }}
        end

      {:ok, nil} ->
        {:ok,
         %{
           subscription_plan_id: subscription.subscription_plan_id,
           target_variant_id: subscription.variant_id,
           target_quantity: subscription.quantity,
           effective_at: nil
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp future_target_base_from_contract_change(%ContractChange{} = contract_change) do
    with {:ok, revision} <- fetch_plan_revision(contract_change.target_plan_revision_id) do
      {:ok,
       %{
         subscription_plan_id: revision.subscription_plan_id,
         plan_revision_id: revision.id,
         plan_revision: revision,
         target_variant_id: contract_change.target_variant_id,
         target_quantity: contract_change.target_quantity,
         target_amount_minor: contract_change.target_amount_minor,
         target_currency: contract_change.target_currency,
         effective_at: contract_change.effective_at
       }}
    end
  end

  defp current_bound_renewal_attempt(%Subscription{
         id: subscription_id,
         current_period_end_at: %DateTime{} = period_start_at,
         current_dunning_renewal_attempt_id: attempt_id
       })
       when not is_nil(attempt_id) do
    with {:ok, %RenewalAttempt{} = attempt} <- fetch_renewal_attempt_by_id(attempt_id),
         true <- attempt.subscription_id == subscription_id,
         true <- DateTime.compare(attempt.period_start_at, period_start_at) == :eq do
      {:ok, attempt}
    else
      false ->
        {:error,
         Error.new(
           "FAILED_PAYMENT_EVIDENCE_MISSING",
           "current dunning RenewalAttempt does not match the locked Subscription period"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_bound_renewal_attempt(%Subscription{
         id: subscription_id,
         current_period_end_at: %DateTime{} = period_start_at
       }) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(
        expr(subscription_id == ^subscription_id and period_start_at == ^period_start_at)
      )
      |> Ash.Query.limit(2)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [%RenewalAttempt{} = attempt]} ->
        {:ok, attempt}

      {:ok, _ambiguous} ->
        {:error, Error.new("VALIDATION_ERROR", "current renewal attempt evidence is ambiguous")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp current_bound_renewal_attempt(%Subscription{}), do: {:ok, nil}

  defp effective_at_for_target(%Subscription{}, %{effective_at: %DateTime{} = at}), do: {:ok, at}

  defp effective_at_for_target(%Subscription{} = subscription, _base),
    do: contract_change_effective_at(subscription)

  defp fetch_effective_plan_revision(plan_id) do
    case PlanRevision.get_effective_for_plan(plan_id,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %PlanRevision{} = revision} ->
        {:ok, revision}

      {:ok, nil} ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "subscription plan has no eligible effective revision"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}

      _multiple_or_invalid ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "subscription plan has an ambiguous effective revision"
         )}
    end
  end

  defp ensure_queueable_subscription(%Subscription{
         status: status,
         cancel_at_period_end: false
       })
       when status in [:active, :past_due],
       do: :ok

  defp ensure_queueable_subscription(%Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "subscription cannot accept a future contract change in its current lifecycle state"
     )}
  end

  defp ensure_subscription_plan_active(%SubscriptionPlan{status: :active}), do: :ok

  defp ensure_subscription_plan_active(%SubscriptionPlan{}) do
    {:error, Error.new("VALIDATION_ERROR", "subscription plan is not active for a new change")}
  end

  defp contract_change_effective_at(%Subscription{
         next_renewal_at: %DateTime{} = effective_at
       }),
       do: {:ok, effective_at}

  defp contract_change_effective_at(%Subscription{
         current_period_end_at: %DateTime{} = effective_at
       }),
       do: {:ok, effective_at}

  defp contract_change_effective_at(%Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "subscription has no future commercial boundary"
     )}
  end

  defp contract_change_projection(subscription, target, target_plan_id) do
    %{
      pending_subscription_plan_id:
        if(target_plan_id == subscription.subscription_plan_id,
          do: nil,
          else: pending_or_nil(target_plan_id)
        ),
      pending_variant_id:
        if(target.target_variant_id == subscription.variant_id,
          do: nil,
          else: pending_or_nil(target.target_variant_id)
        ),
      pending_renewal_amount_minor: target.target_amount_minor,
      pending_renewal_currency: target.target_currency,
      change_effective_at: target.effective_at
    }
  end

  defp persist_contract_change(subscription, target, projection, actor, subscription_action) do
    persist_contract_change(
      subscription,
      {:materialized, target, projection},
      actor,
      subscription_action
    )
  end

  defp persist_contract_change(%Subscription{} = subscription, intent, actor, subscription_action) do
    persist_contract_change_attempt(subscription, intent, actor, subscription_action, 0)
  end

  defp persist_contract_change_attempt(
         %Subscription{} = subscription,
         intent,
         actor,
         subscription_action,
         stale_retries
       ) do
    :telemetry.execute(
      [:store, :subscriptions, :contract_change, :before_persist],
      %{},
      %{subscription_id: subscription.id, intent_kind: contract_change_intent_kind(intent)}
    )

    transaction_result =
      Repo.transaction(fn ->
        persist_locked_contract_change_intent(subscription, intent, actor, subscription_action)
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, %{subscription: updated_subscription}, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :persist_contract_change,
              subscription_id: subscription.id,
              contract_change_id: Map.get(updated_subscription, :current_contract_change_id)
            }
          )

        with :ok <-
               maybe_enqueue_immediate_collection_retry(
                 updated_subscription,
                 retry_now?(updated_subscription)
               ) do
          {:ok, updated_subscription}
        end

      {:error, reason} ->
        normalized = Normalize.normalize(reason)

        retry_stale_contract_change(
          normalized,
          subscription,
          intent,
          actor,
          subscription_action,
          stale_retries
        )
    end
  end

  defp persist_locked_contract_change_intent(subscription, intent, actor, subscription_action) do
    with {:ok, locked_subscription} <- lock_contract_change_subscription(subscription),
         {:ok, current_target} <- current_contract_change(locked_subscription),
         {:ok, target, projection} <-
           materialize_contract_change_intent(locked_subscription, intent, current_target) do
      persist_locked_contract_change(
        locked_subscription,
        current_target,
        target,
        projection,
        actor,
        subscription_action
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_stale_contract_change(
         %Error{code: "STALE_RECORD"} = normalized,
         %Subscription{} = subscription,
         intent,
         actor,
         subscription_action,
         stale_retries
       )
       when stale_retries < @max_contract_change_stale_retries do
    if retryable_contract_change_intent?(intent) do
      case reload_subscription_after_stale_update(subscription.id) do
        %Subscription{} = fresh_subscription ->
          persist_contract_change_attempt(
            fresh_subscription,
            intent,
            actor,
            subscription_action,
            stale_retries + 1
          )

        nil ->
          {:error, normalized}
      end
    else
      {:error, normalized}
    end
  end

  defp retry_stale_contract_change(
         normalized,
         %Subscription{},
         _intent,
         _actor,
         _subscription_action,
         _stale_retries
       ),
       do: {:error, normalized}

  defp contract_change_intent_kind({:plan_change, _plan_id}), do: :plan_change
  defp contract_change_intent_kind({:variant_change, _variant_id}), do: :variant_change
  defp contract_change_intent_kind({:materialized, _target, _projection}), do: :materialized

  defp retryable_contract_change_intent?({:plan_change, _plan_id}), do: true
  defp retryable_contract_change_intent?({:variant_change, _variant_id}), do: true
  defp retryable_contract_change_intent?(_intent), do: false

  defp materialize_contract_change_intent(
         %Subscription{} = subscription,
         {:plan_change, plan_id},
         current_target
       ) do
    with :ok <- ensure_queueable_subscription(subscription),
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, base} <- future_target_base(subscription, current_target),
         {:ok, plan} <- fetch_plan(plan_id),
         :ok <- ensure_subscription_plan_active(plan),
         {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(base.target_variant_id),
         :ok <- ensure_variant_subscription_plan_active(variant.id, plan.id),
         :ok <- ensure_variant_catalog_renewable(variant),
         {:ok, revision} <- fetch_effective_plan_revision(plan.id),
         :ok <- ensure_revision_belongs_to_plan(revision, plan.id),
         {:ok, effective_at} <- effective_at_for_target(subscription, base) do
      target = %{
        instruction_kind: :plan_change,
        target_plan_revision_id: revision.id,
        target_variant_id: base.target_variant_id,
        target_quantity: base.target_quantity,
        target_amount_minor: revision.amount_minor,
        target_currency: revision.currency,
        effective_at: effective_at
      }

      {:ok, target, contract_change_projection(subscription, target, plan.id)}
    end
  end

  defp materialize_contract_change_intent(
         %Subscription{},
         {:materialized, target, projection},
         _current_target
       ),
       do: {:ok, target, projection}

  defp materialize_contract_change_intent(
         %Subscription{} = subscription,
         {:variant_change, variant_id},
         current_target
       ) do
    with :ok <- ensure_queueable_subscription(subscription),
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, base} <- future_target_base(subscription, current_target),
         {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(variant_id),
         {:ok, plan} <- fetch_plan(base.subscription_plan_id),
         :ok <- ensure_subscription_plan_active(plan),
         :ok <- ensure_variant_subscription_plan_active(variant.id, plan.id),
         :ok <- ensure_variant_catalog_renewable(variant),
         {:ok, revision, amount_minor, currency} <-
           future_target_revision_and_price(base, plan.id),
         :ok <- ensure_revision_belongs_to_plan(revision, plan.id),
         {:ok, effective_at} <- effective_at_for_target(subscription, base) do
      target = %{
        instruction_kind: :variant_change,
        target_plan_revision_id: revision.id,
        target_variant_id: variant.id,
        target_quantity: base.target_quantity,
        target_amount_minor: amount_minor,
        target_currency: currency,
        effective_at: effective_at
      }

      {:ok, target, contract_change_projection(subscription, target, plan.id)}
    end
  end

  defp future_target_revision_and_price(
         %{
           plan_revision: %PlanRevision{} = revision,
           target_amount_minor: amount_minor,
           target_currency: currency
         },
         _plan_id
       ) do
    {:ok, revision, amount_minor, currency}
  end

  defp future_target_revision_and_price(_base, plan_id) do
    with {:ok, revision} <- fetch_effective_plan_revision(plan_id) do
      {:ok, revision, revision.amount_minor, revision.currency}
    end
  end

  defp persist_locked_contract_change(
         subscription,
         current_target,
         target,
         projection,
         actor,
         subscription_action
       ) do
    case latest_contract_change(subscription.id) do
      {:ok, predecessor} ->
        if subscription_action == :queue_change and
             same_queued_contract_change?(current_target, target) do
          {:ok, %{subscription: subscription, notifications: []}}
        else
          persist_contract_change_tx(
            subscription,
            current_target,
            predecessor,
            target,
            projection,
            actor,
            subscription_action
          )
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp persist_contract_change_tx(
         subscription,
         current_target,
         predecessor,
         target,
         projection,
         actor,
         subscription_action
       ) do
    supersedes_id = current_target && current_target.id

    with :ok <- ensure_rescind_target_clear(subscription_action, current_target),
         {:ok, transition_notifications} <-
           maybe_transition_contract_change(current_target, :supersede),
         {:ok, contract_change, contract_change_notifications} <-
           create_contract_change(
             subscription,
             target,
             predecessor && predecessor.id,
             supersedes_id
           ),
         attrs <-
           projection
           |> Map.put(:current_contract_change_id, contract_change.id)
           |> then(&maybe_contract_correction_retry_attrs(subscription, &1)),
         {:ok, updated_subscription, subscription_notifications} <-
           update_subscription_contract_change(
             subscription,
             subscription_action,
             attrs,
             actor
           ) do
      {:ok,
       %{
         subscription: updated_subscription,
         notifications:
           transition_notifications ++ contract_change_notifications ++ subscription_notifications
       }}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_rescind_target_clear(:rescind_cancel_at_period_end_transition, nil), do: :ok

  defp ensure_rescind_target_clear(:rescind_cancel_at_period_end_transition, _current_target) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "scheduled cancellation has an unresolved current future target"
     )}
  end

  defp ensure_rescind_target_clear(_subscription_action, _current_target), do: :ok

  defp create_contract_change(
         subscription,
         target,
         predecessor_id,
         supersedes_id
       ) do
    attrs = %{
      subscription_id: subscription.id,
      target_plan_revision_id: target.target_plan_revision_id,
      target_variant_id: target.target_variant_id,
      predecessor_contract_change_id: predecessor_id,
      supersedes_contract_change_id: supersedes_id,
      instruction_kind: target.instruction_kind,
      ordering_version: subscription.aggregate_version + 1,
      effective_at: target.effective_at,
      target_quantity: target.target_quantity,
      target_amount_minor: target.target_amount_minor,
      target_currency: target.target_currency
    }

    ContractChange
    |> Ash.Changeset.for_create(:queue, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, contract_change, notifications} -> {:ok, contract_change, notifications}
      {:ok, contract_change} -> {:ok, contract_change, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp update_subscription_contract_change(subscription, action, attrs, actor) do
    subscription
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(domain: Subscriptions, actor: actor, return_notifications?: true)
    |> normalize_subscription_update_with_notifications(subscription)
  end

  defp maybe_transition_contract_change(nil, _transition), do: {:ok, []}

  defp maybe_transition_contract_change(%ContractChange{status: :queued} = change, transition) do
    change
    |> Ash.Changeset.for_update(transition, %{}, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, _updated, notifications} -> {:ok, notifications}
      {:ok, _updated} -> {:ok, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp maybe_transition_contract_change(%ContractChange{}, _transition) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "current subscription ContractChange is not queued"
     )}
  end

  defp current_contract_change(%Subscription{} = subscription) do
    case Map.get(subscription, :current_contract_change_id) do
      nil ->
        case fetch_queued_contract_change(subscription.id) do
          {:ok, nil} -> {:ok, nil}
          {:ok, _orphaned} -> {:error, inconsistent_current_contract_change_error()}
          {:error, reason} -> {:error, reason}
        end

      contract_change_id ->
        case fetch_contract_change_by_id(contract_change_id) do
          {:ok, %ContractChange{subscription_id: id, status: :queued} = target}
          when id == subscription.id ->
            {:ok, target}

          {:ok, _other} ->
            {:error, inconsistent_current_contract_change_error()}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fetch_queued_contract_change(subscription_id) do
    query =
      ContractChange
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id and status == :queued))
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [contract_change | _]} -> {:ok, contract_change}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp inconsistent_current_contract_change_error do
    Error.new("VALIDATION_ERROR", "current subscription ContractChange is inconsistent")
  end

  defp latest_contract_change(subscription_id) do
    query =
      ContractChange
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
      |> Ash.Query.sort(ordering_version: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [latest | _]} -> {:ok, latest}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_contract_change_by_id(id) do
    query = ContractChange |> Ash.Query.filter(expr(id == ^id))

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %ContractChange{} = contract_change} -> {:ok, contract_change}
      {:ok, nil} -> {:error, Error.new("VALIDATION_ERROR", "ContractChange was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp same_queued_contract_change?(%ContractChange{} = current, target) do
    current.instruction_kind == target.instruction_kind and
      current.target_plan_revision_id == target.target_plan_revision_id and
      current.target_variant_id == target.target_variant_id and
      current.target_quantity == target.target_quantity and
      current.target_amount_minor == target.target_amount_minor and
      current.target_currency == target.target_currency and
      current.effective_at == target.effective_at
  end

  defp same_queued_contract_change?(nil, _target), do: false

  defp lock_subscription_aggregate_version(%Subscription{} = subscription) do
    case Ecto.UUID.dump(subscription.id) do
      {:ok, subscription_uuid} ->
        case Repo.query(
               "SELECT aggregate_version FROM subscriptions WHERE id = $1 FOR UPDATE",
               [subscription_uuid]
             ) do
          {:ok, %{rows: [[version]]}} when version == subscription.aggregate_version ->
            :ok

          {:ok, %{rows: [[_version]]}} ->
            _ = reload_subscription_after_stale_update(subscription.id)

            {:error,
             Error.new(
               "STALE_RECORD",
               "subscription changed while the command was in progress; reload and re-evaluate it"
             )}

          {:ok, %{rows: []}} ->
            {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      :error ->
        {:error, Error.new("VALIDATION_ERROR", "subscription id must be a UUID")}
    end
  end

  defp lock_contract_change_subscription(%Subscription{} = subscription) do
    with {:ok, locked_subscription} <- fetch_subscription_for_renewal_locked(subscription.id),
         :ok <- ensure_expected_subscription_version(subscription, locked_subscription) do
      {:ok, locked_subscription}
    end
  end

  defp maybe_contract_correction_retry_attrs(%Subscription{} = subscription, attrs) do
    if subscription.status == :past_due and is_struct(subscription.retry_suppressed_at, DateTime) and
         retry_repair_authorized?(subscription, :contract_change) do
      attrs
      |> Map.put(:retry_suppressed_at, nil)
      |> Map.put(:next_retry_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    else
      attrs
    end
  end

  defp retry_repair_authorized?(%Subscription{status: :past_due} = subscription, repair_kind) do
    with {:ok, %RenewalAttempt{} = attempt} <- current_bound_renewal_attempt(subscription),
         :ok <- ensure_complete_bound_renewal_attempt(attempt),
         true <- attempt.status == :failed,
         true <- same_bound_renewal_occurrence?(subscription, attempt),
         true <- repair_matches_bound_failure?(repair_kind, attempt),
         true <- bound_retry_budget_remains?(subscription, attempt) do
      true
    else
      _ -> false
    end
  end

  defp retry_repair_authorized?(%Subscription{}, _repair_kind), do: false

  defp same_bound_renewal_occurrence?(
         %Subscription{
           id: subscription_id,
           current_period_end_at: %DateTime{} = period_start_at
         },
         %RenewalAttempt{
           subscription_id: attempt_subscription_id,
           period_start_at: %DateTime{} = attempt_period_start_at
         }
       ) do
    subscription_id == attempt_subscription_id and
      DateTime.compare(period_start_at, attempt_period_start_at) == :eq
  end

  defp same_bound_renewal_occurrence?(_subscription, _attempt), do: false

  defp repair_matches_bound_failure?(:contract_change, %RenewalAttempt{failure_code: code}),
    do: hard_retry_suppressed_reason?(code)

  defp repair_matches_bound_failure?(:payment_method, %RenewalAttempt{failure_code: code}) do
    MapSet.member?(@payment_retry_reasons, code) and code != "PAYMENT_AUTHENTICATION_REQUIRED"
  end

  defp repair_matches_bound_failure?(_repair_kind, _attempt), do: false

  defp bound_retry_budget_remains?(
         %Subscription{
           dunning_attempt_count: attempt_count,
           past_due_since_at: %DateTime{} = past_due_since_at
         } = subscription,
         %RenewalAttempt{} = attempt
       )
       when is_integer(attempt_count) and attempt_count > 0 do
    policy = renewal_policy_from_attempt(attempt)
    max_retry_attempts = Map.get(policy, :max_retry_attempts)

    is_integer(max_retry_attempts) and max_retry_attempts >= attempt_count and
      match?(%DateTime{}, Scheduler.next_retry_at(past_due_since_at, attempt_count - 1, policy)) and
      same_bound_renewal_occurrence?(subscription, attempt)
  end

  defp bound_retry_budget_remains?(_subscription, _attempt), do: false

  defp retry_now?(%Subscription{status: :past_due, retry_suppressed_at: nil}), do: true
  defp retry_now?(%Subscription{}), do: false

  defp start_payment_method_update(%Subscription{} = subscription) do
    with :ok <- ensure_payment_method_update_supported(subscription),
         payment_intent_key <- payment_method_update_intent_key(subscription.id),
         {:ok, payment_intent} <-
           create_subscription_payment_method_update_intent(subscription, payment_intent_key),
         {:ok, provider_payload} <-
           create_subscription_payment_method_update_provider_intent(
             subscription,
             payment_intent,
             payment_intent_key
           ),
         {:ok, payment_intent} <-
           persist_setup_intent_provider_reference(payment_intent, provider_payload),
         {:ok, submitted_intent} <- maybe_submit_virtual_payment_intent(payment_intent) do
      {:ok,
       %{
         payment_intent_id: submitted_intent.id,
         client_secret: submitted_intent.provider_client_secret,
         publishable_key: stripe_publishable_key(),
         provider: :stripe
       }}
    end
  end

  defp create_subscription_payment_method_update_intent(subscription, payment_intent_key) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider: subscription.provider,
        purpose: :subscription_payment_method_update,
        subscription_id: subscription.id,
        amount_received_minor: 0,
        currency: subscription.renewal_currency || "USD",
        provider_customer_ref: subscription.provider_customer_ref,
        payment_intent_key: payment_intent_key
      },
      context: %{system?: true}
    )
    |> Ash.create(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, payment_intent} -> {:ok, payment_intent}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp create_subscription_payment_method_update_provider_intent(
         subscription,
         payment_intent,
         payment_intent_key
       ) do
    Providers.create_intent(
      subscription.provider,
      %{
        intent_purpose: :subscription_payment_method_update,
        payment_intent_key: payment_intent_key,
        local_intent_id: payment_intent.id,
        subscription_id: subscription.id,
        provider_customer_ref: subscription.provider_customer_ref,
        currency: subscription.renewal_currency || "USD"
      },
      []
    )
  end

  defp persist_setup_intent_provider_reference(
         %PaymentIntent{} = payment_intent,
         provider_payload
       ) do
    payment_intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{
        provider: payment_intent.provider,
        provider_payment_id: Map.get(provider_payload, :provider_payment_id),
        provider_customer_ref: Map.get(provider_payload, :provider_customer_ref),
        provider_client_secret: Map.get(provider_payload, :provider_client_secret)
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, updated_intent} -> {:ok, updated_intent}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_payment_method_update_supported(%Subscription{} = subscription) do
    if payment_method_update_supported?(subscription) do
      :ok
    else
      {:error,
       Error.new(
         "PAYMENT_METHOD_UPDATE_UNSUPPORTED",
         "payment method update is not supported for this subscription"
       )}
    end
  end

  defp ensure_input_subscription_id(expected, actual) when expected == actual, do: :ok

  defp ensure_input_subscription_id(_expected, _actual) do
    {:error,
     Error.new("VALIDATION_ERROR", "input subscription id must match the route subscription id")}
  end

  defp fetch_active_plans_for_variant(variant_id) when is_binary(variant_id) do
    query =
      VariantSubscriptionPlan
      |> Ash.Query.for_read(:read_active_for_variant, %{variant_id: variant_id})
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, attachments} ->
        {:ok,
         attachments
         |> Enum.map(fn attachment ->
           {attachment.subscription_plan_id, attachment.subscription_plan}
         end)
         |> Enum.reject(fn {_id, plan} -> is_nil(plan) end)}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp build_plan_options_for_variant(%Variant{} = variant, plan_pairs, selected_plan_key) do
    Enum.map(plan_pairs, fn {_plan_id, plan} ->
      pricing = resolve_subscription_pricing(variant, plan)

      %{
        id: plan.id,
        key: plan.key,
        name: plan.name,
        label: plan.name || plan.key,
        price_minor: pricing.amount_minor,
        currency: pricing.currency,
        selected?: is_binary(selected_plan_key) and plan.key == selected_plan_key
      }
    end)
  end

  defp build_plan_target_options(%Variant{} = variant, plan_pairs, selected_plan_id) do
    Enum.map(plan_pairs, fn {_plan_id, plan} ->
      pricing = resolve_subscription_pricing(variant, plan)

      %{
        id: plan.id,
        key: plan.key,
        label: plan.name || plan.key,
        price_minor: pricing.amount_minor,
        currency: pricing.currency,
        selected?: plan.id == selected_plan_id
      }
    end)
  end

  defp fetch_variant_targets_for_product_plan(product_id, plan_id)
       when is_binary(product_id) and is_binary(plan_id) do
    query =
      from(variant in Variant,
        join: product in Product,
        on: product.id == variant.product_id,
        join: attachment in VariantSubscriptionPlan,
        on:
          attachment.variant_id == variant.id and attachment.subscription_plan_id == ^plan_id and
            attachment.active == true,
        where:
          variant.product_id == ^product_id and variant.status == :active and
            product.status == :published and not is_nil(product.published_at),
        order_by: [asc: variant.inserted_at, asc: variant.id]
      )

    {:ok, Repo.all(query)}
  rescue
    error -> {:error, Normalize.normalize(error)}
  end

  defp resolve_subscription_pricing(%Variant{} = variant, %SubscriptionPlan{} = plan) do
    amount_minor =
      cond do
        is_integer(plan.amount_minor) -> plan.amount_minor
        is_integer(variant.price_minor) -> variant.price_minor
        true -> 0
      end

    currency =
      cond do
        is_binary(plan.currency) -> String.upcase(plan.currency)
        is_binary(variant.currency_code) -> String.upcase(variant.currency_code)
        true -> "USD"
      end

    %{amount_minor: amount_minor, currency: currency}
  end

  defp effective_variant_id(%Subscription{} = subscription),
    do: subscription.pending_variant_id || subscription.variant_id

  defp effective_plan_id(%Subscription{} = subscription),
    do: subscription.pending_subscription_plan_id || subscription.subscription_plan_id

  defp pending_or_nil(value) when is_binary(value), do: value
  defp pending_or_nil(_value), do: nil

  defp payment_method_update_intent_key(subscription_id) do
    "pm-update:#{subscription_id}:#{System.unique_integer([:positive])}"
  end

  defp stripe_publishable_key do
    :store
    |> Application.get_env(:payments, [])
    |> Keyword.get(:stripe, [])
    |> Keyword.get(:publishable_key, "pk_test_store_blueprint")
  end

  defp fetch_payment_intent_for_system(payment_intent_id) when is_binary(payment_intent_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [%PaymentIntent{} = payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "payment intent not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_setup_payment_intent(%PaymentIntent{
         purpose: :subscription_payment_method_update,
         subscription_id: subscription_id
       })
       when is_binary(subscription_id),
       do: :ok

  defp ensure_setup_payment_intent(%PaymentIntent{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent is not a subscription payment method update intent"
     )}
  end

  defp persist_updated_payment_method(subscription, payment_intent) do
    case Repo.transaction(fn ->
           persist_updated_payment_method_tx(subscription, payment_intent)
         end)
         |> normalize_transaction_notifications() do
      {:ok, result, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :handle_payment_method_update_succeeded_for_system,
              subscription_id: subscription.id,
              payment_intent_id: payment_intent.id
            }
          )

        {:ok, result}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp persist_updated_payment_method_tx(subscription, payment_intent) do
    retry_repair_authorized? = retry_repair_authorized?(subscription, :payment_method)

    with {:ok, stored_payment_method, stored_payment_method_notifications} <-
           maybe_upsert_stored_payment_method(subscription.user_id, payment_intent),
         :ok <-
           ensure_stored_payment_method_active_for_payment_method_update(stored_payment_method),
         {:ok, updated_subscription, subscription_notifications} <-
           update_subscription_payment_method_reference(
             subscription,
             payment_intent,
             stored_payment_method,
             retry_repair_authorized?
           ) do
      {:ok,
       %{
         subscription: updated_subscription,
         retry_now?: retry_repair_authorized?,
         notifications: stored_payment_method_notifications ++ subscription_notifications
       }}
    else
      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp ensure_stored_payment_method_active_for_payment_method_update(%StoredPaymentMethod{
         status: :active
       }),
       do: :ok

  defp ensure_stored_payment_method_active_for_payment_method_update(_stored_payment_method) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription cannot renew without an active stored payment method"
     )}
  end

  defp update_subscription_payment_method_reference(
         subscription,
         payment_intent,
         stored_payment_method,
         retry_repair_authorized?
       ) do
    subscription
    |> Ash.Changeset.for_update(
      :set_provider_billing_reference,
      payment_method_reference_attrs(
        subscription,
        payment_intent,
        stored_payment_method,
        retry_repair_authorized?
      ),
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> normalize_subscription_update_with_notifications(subscription)
  end

  defp payment_method_reference_attrs(
         subscription,
         payment_intent,
         stored_payment_method,
         retry_repair_authorized?
       ) do
    %{
      provider_customer_ref:
        payment_intent.provider_customer_ref ||
          (stored_payment_method && stored_payment_method.provider_customer_ref),
      provider_billing_ref:
        payment_intent.provider_payment_method_ref ||
          (stored_payment_method && stored_payment_method.provider_payment_method_ref),
      stored_payment_method_id: stored_payment_method && stored_payment_method.id,
      billing_status_reason: nil,
      next_retry_at: payment_method_retry_at(subscription, retry_repair_authorized?),
      retry_suppressed_at:
        if(retry_repair_authorized?, do: nil, else: subscription.retry_suppressed_at)
    }
  end

  defp payment_method_retry_at(%Subscription{status: :past_due}, true) do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp payment_method_retry_at(%Subscription{} = subscription, _clear_retry_suppressed?),
    do: subscription.next_retry_at

  defp normalize_subscription_update_with_notifications(
         {:ok, updated_subscription, notifications},
         _subscription
       ) do
    {:ok, updated_subscription, notifications}
  end

  defp normalize_subscription_update_with_notifications(
         {:ok, updated_subscription},
         _subscription
       ) do
    {:ok, updated_subscription, []}
  end

  defp normalize_subscription_update_with_notifications({:error, reason}, subscription) do
    normalize_subscription_update_result({:error, reason}, subscription)
  end

  defp maybe_enqueue_immediate_collection_retry(_subscription, false), do: :ok

  defp maybe_enqueue_immediate_collection_retry(%Subscription{} = subscription, true) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case due_renewal_key(subscription, now) do
      {:ok, renewal_key} ->
        %{"subscription_id" => subscription.id, "renewal_key" => renewal_key}
        |> ProcessSubscriptionRenewalWorker.new()
        |> Oban.insert()

        :ok

      _ ->
        :ok
    end
  end

  @spec resolve_variant_subscription_plan_for_system(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, SubscriptionPlan.t() | nil} | {:error, Error.t() | term()}
  def resolve_variant_subscription_plan_for_system(variant_id, explicit_plan_id \\ nil)

  def resolve_variant_subscription_plan_for_system(variant_id, explicit_plan_id)
      when is_binary(variant_id) do
    query =
      VariantSubscriptionPlan
      |> Ash.Query.for_read(:read_active_for_variant, %{variant_id: variant_id})
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, plans} when is_binary(explicit_plan_id) ->
        match =
          Enum.find(plans, fn plan ->
            plan.subscription_plan_id == explicit_plan_id
          end)

        if match do
          {:ok, match.subscription_plan}
        else
          {:error,
           Error.new(
             "VALIDATION_ERROR",
             "subscription_plan_id is not active for the selected variant"
           )}
        end

      {:ok, [single]} ->
        {:ok, single.subscription_plan}

      {:ok, _many} ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "variant has multiple active subscription plans; explicit subscription_plan_id is required"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def resolve_variant_subscription_plan_for_system(_variant_id, _explicit_plan_id) do
    {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID")}
  end

  @spec ensure_membership_purchase_allowed_for_system(String.t() | nil, String.t() | [String.t()]) ::
          :ok | {:error, Error.t()}
  def ensure_membership_purchase_allowed_for_system(user_id, plan_id_or_ids)

  def ensure_membership_purchase_allowed_for_system(_user_id, nil), do: :ok

  def ensure_membership_purchase_allowed_for_system(user_id, plan_id) when is_binary(plan_id) do
    ensure_membership_purchase_allowed_for_system(user_id, [plan_id])
  end

  def ensure_membership_purchase_allowed_for_system(user_id, plan_ids) when is_list(plan_ids) do
    normalized_plan_ids =
      plan_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with {:ok, membership_keys} <- membership_keys_for_plan_ids(normalized_plan_ids),
         :ok <- ensure_membership_user(user_id, membership_keys),
         :ok <- ensure_no_open_membership_subscription(user_id, membership_keys) do
      ensure_no_pending_membership_order(user_id, membership_keys)
    end
  end

  def ensure_membership_purchase_allowed_for_system(_user_id, _plan_ids) do
    {:error, Error.new("VALIDATION_ERROR", "subscription plan ids must be UUIDs")}
  end

  @spec order_has_subscription_lines_for_system(Ecto.UUID.t()) ::
          {:ok, boolean()} | {:error, Error.t() | term()}
  def order_has_subscription_lines_for_system(order_id) when is_binary(order_id) do
    with {:ok, line_items} <- fetch_subscription_order_line_items(order_id) do
      {:ok, line_items != []}
    end
  end

  def order_has_subscription_lines_for_system(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  @spec order_is_subscription_only_for_system(Ecto.UUID.t()) ::
          {:ok, boolean()} | {:error, Error.t() | term()}
  def order_is_subscription_only_for_system(order_id) when is_binary(order_id) do
    with {:ok, line_items} <- fetch_all_order_line_items(order_id) do
      subscription_line_count =
        Enum.count(line_items, fn line_item ->
          is_binary(Map.get(line_item, :subscription_plan_id_snapshot))
        end)

      {:ok, line_items != [] and subscription_line_count == length(line_items)}
    end
  end

  def order_is_subscription_only_for_system(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  @spec create_subscriptions_from_paid_order_for_system(Ecto.UUID.t()) ::
          {:ok,
           %{
             order_id: Ecto.UUID.t(),
             subscription_line_count: non_neg_integer(),
             created_count: non_neg_integer(),
             skipped_count: non_neg_integer(),
             entitlement_issued_count: non_neg_integer()
           }}
          | {:error, Error.t() | term()}
  def create_subscriptions_from_paid_order_for_system(order_id) when is_binary(order_id) do
    with {:ok, order} <- fetch_paid_order(order_id),
         :ok <- ensure_initial_subscription_order(order.id),
         :ok <- ensure_order_user(order),
         {:ok, line_items} <- fetch_subscription_order_line_items(order.id),
         {:ok, payment_intent} <- fetch_succeeded_payment_intent(order.id),
         {:ok, result} <- build_subscription_creation_result(order, line_items, payment_intent) do
      {:ok,
       %{
         order_id: order.id,
         subscription_line_count: length(line_items),
         created_count: result.created,
         skipped_count: result.skipped,
         entitlement_issued_count: result.entitlements
       }}
    end
  end

  def create_subscriptions_from_paid_order_for_system(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  defp ensure_initial_subscription_order(order_id) do
    case fetch_renewal_attempt_by_order(order_id) do
      {:ok, %RenewalAttempt{}} ->
        {:error,
         Error.new(
           "SUBSCRIPTION_RENEWAL_ORDER",
           "renewal orders must reconcile the existing subscription instead of creating a new one"
         )}

      {:error, %Error{code: "NOT_FOUND"}} ->
        :ok

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp build_subscription_creation_result(order, line_items, payment_intent) do
    case run_subscription_creation_transaction(order, line_items, payment_intent) do
      {:ok, tx_result, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :create_subscriptions_from_paid_order_for_system,
              order_id: order.id
            }
          )

        {:ok,
         %{
           created: tx_result.created,
           skipped: tx_result.skipped,
           entitlements: issue_subscription_entitlements_after_commit(tx_result.entitlements)
         }}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp run_subscription_creation_transaction(order, line_items, payment_intent) do
    Repo.transaction(fn ->
      case maybe_upsert_stored_payment_method(order.user_id, payment_intent) do
        {:ok, stored_payment_method, stored_payment_method_notifications} ->
          reduce_subscription_line_items(
            order,
            line_items,
            payment_intent,
            stored_payment_method,
            stored_payment_method_notifications
          )

        {:error, reason} ->
          Repo.rollback(Normalize.normalize(reason))
      end
    end)
    |> normalize_transaction_notifications()
  end

  defp reduce_subscription_line_items(
         order,
         line_items,
         payment_intent,
         stored_payment_method,
         stored_payment_method_notifications
       ) do
    Enum.reduce_while(
      line_items,
      {:ok,
       %{
         created: 0,
         skipped: 0,
         entitlements: [],
         notifications: stored_payment_method_notifications
       }},
      fn line_item, {:ok, acc} ->
        reduce_subscription_line_item(
          order,
          line_item,
          payment_intent,
          stored_payment_method,
          acc
        )
      end
    )
  end

  defp reduce_subscription_line_item(order, line_item, payment_intent, stored_payment_method, acc) do
    case create_subscription_from_line(order, line_item, payment_intent, stored_payment_method) do
      {:ok, :created, %{subscription: subscription, plan: _plan, revision: revision},
       line_notifications} ->
        updated =
          %{
            created: acc.created + 1,
            skipped: acc.skipped,
            entitlements: [{subscription, revision} | acc.entitlements],
            notifications: acc.notifications ++ line_notifications
          }

        {:cont, {:ok, updated}}

      {:ok, :skipped, line_notifications} ->
        {:cont,
         {:ok,
          %{
            acc
            | skipped: acc.skipped + 1,
              notifications: acc.notifications ++ line_notifications
          }}}

      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  @spec cancel_subscription_for_user(
          map(),
          Ecto.UUID.t(),
          :now | :period_end | :rescind_period_end
        ) ::
          {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def cancel_subscription_for_user(actor, subscription_id, mode \\ :period_end)

  def cancel_subscription_for_user(actor, subscription_id, mode)
      when is_map(actor) and is_binary(subscription_id) and
             mode in [:now, :period_end, :rescind_period_end] do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_user(actor, subscription_id),
         {:ok, updated} <-
           if(mode == :rescind_period_end,
             do: run_rescind_cancellation_with_authorized_reload(subscription, actor),
             else: run_cancel_with_authorized_retry(subscription, mode, actor, :user)
           ) do
      {:ok, updated}
    else
      {:ok, nil} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def cancel_subscription_for_user(_actor, _subscription_id, _mode) do
    {:error, Error.new("VALIDATION_ERROR", "invalid cancel subscription request")}
  end

  @spec cancel_subscription_for_admin(map(), Ecto.UUID.t(), :now | :period_end) ::
          {:ok, Subscription.t()} | {:error, Error.t() | term()}
  def cancel_subscription_for_admin(actor, subscription_id, mode \\ :period_end)

  def cancel_subscription_for_admin(actor, subscription_id, mode)
      when is_map(actor) and is_binary(subscription_id) and mode in [:now, :period_end] do
    with {:ok, %Subscription{} = subscription} <-
           get_subscription_for_admin(actor, subscription_id),
         {:ok, canceled} <- run_cancel_with_authorized_retry(subscription, mode, actor, :admin) do
      {:ok, canceled}
    else
      {:ok, nil} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def cancel_subscription_for_admin(_actor, _subscription_id, _mode) do
    {:error, Error.new("VALIDATION_ERROR", "invalid cancel subscription request")}
  end

  @spec run_due_renewals_for_system(keyword()) ::
          {:ok,
           %{
             due_count: non_neg_integer(),
             success_count: non_neg_integer(),
             failed_count: non_neg_integer()
           }}
          | {:error, Error.t() | term()}
  def run_due_renewals_for_system(opts \\ []) when is_list(opts) do
    started_at = System.monotonic_time()
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    limit = Keyword.get(opts, :limit, @default_due_limit)

    query = Subscription |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: limit})

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, due_subscriptions} ->
        result = count_due_renewal_results(due_subscriptions, now)
        emit_subscription_tick_telemetry(started_at, length(due_subscriptions), result)

        {:ok,
         %{
           due_count: length(due_subscriptions),
           success_count: result.success,
           failed_count: result.failed
         }}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  @spec run_due_failed_payment_suspensions_for_system(keyword()) ::
          {:ok,
           %{
             due_count: non_neg_integer(),
             suspended_count: non_neg_integer(),
             failed_count: non_neg_integer(),
             cursor: %{timestamp: DateTime.t(), id: Ecto.UUID.t()} | nil,
             now: DateTime.t()
           }}
          | {:error, Error.t() | term()}
  def run_due_failed_payment_suspensions_for_system(opts \\ [])

  def run_due_failed_payment_suspensions_for_system(opts) when is_list(opts) do
    with {:ok, database_now} <- database_wall_clock_now() do
      now = Keyword.get(opts, :now, database_now)
      limit = opts |> Keyword.get(:limit, @default_due_limit) |> bounded_due_limit()

      query =
        Subscription
        |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{
          now: now,
          after_boundary_at: Keyword.get(opts, :after_boundary_at),
          after_id: Keyword.get(opts, :after_id),
          limit: limit
        })

      case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
        {:ok, subscriptions} ->
          result =
            Enum.reduce(subscriptions, %{suspended: 0, failed: 0}, &suspend_boundary_result/2)

          {:ok,
           %{
             due_count: length(subscriptions),
             suspended_count: result.suspended,
             failed_count: result.failed,
             cursor: boundary_cursor(subscriptions, limit),
             now: now
           }}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    end
  end

  def run_due_failed_payment_suspensions_for_system(_opts) do
    {:error, Error.new("VALIDATION_ERROR", "boundary suspension options must be a keyword list")}
  end

  @spec run_due_scheduled_cancellations_for_system(keyword()) ::
          {:ok,
           %{
             due_count: non_neg_integer(),
             canceled_count: non_neg_integer(),
             failed_count: non_neg_integer(),
             cursor: %{timestamp: DateTime.t(), id: Ecto.UUID.t()} | nil,
             now: DateTime.t()
           }}
          | {:error, Error.t() | term()}
  def run_due_scheduled_cancellations_for_system(opts \\ [])

  def run_due_scheduled_cancellations_for_system(opts) when is_list(opts) do
    with :ok <- validate_optional_keyset_cursor(opts[:after_boundary_at], opts[:after_id]),
         {:ok, database_now} <- database_wall_clock_now() do
      now = Keyword.get(opts, :now, database_now)
      limit = opts |> Keyword.get(:limit, @default_due_limit) |> bounded_due_limit()

      query =
        Subscription
        |> Ash.Query.for_read(:read_due_scheduled_cancellations_for_system, %{
          now: now,
          after_boundary_at: Keyword.get(opts, :after_boundary_at),
          after_id: Keyword.get(opts, :after_id),
          limit: limit
        })

      case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
        {:ok, subscriptions} ->
          result = terminalize_due_scheduled_cancellations(subscriptions, opts[:now])

          {:ok,
           %{
             due_count: length(subscriptions),
             canceled_count: result.canceled,
             failed_count: result.failed,
             cursor: scheduled_cancellation_cursor(subscriptions, limit),
             now: now
           }}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    end
  end

  def run_due_scheduled_cancellations_for_system(_opts) do
    {:error,
     Error.new("VALIDATION_ERROR", "scheduled cancellation options must be a keyword list")}
  end

  @spec replay_scheduled_cancellation_notifications_for_system(keyword()) ::
          {:ok,
           %{
             replay_count: non_neg_integer(),
             failed_count: non_neg_integer(),
             cursor: %{timestamp: DateTime.t(), id: Ecto.UUID.t()} | nil
           }}
          | {:error, Error.t() | term()}
  def replay_scheduled_cancellation_notifications_for_system(opts \\ [])

  def replay_scheduled_cancellation_notifications_for_system(opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_due_limit) |> bounded_due_limit()

    with :ok <- validate_optional_keyset_cursor(opts[:after_ended_at], opts[:after_id]),
         {:ok, candidates} <- missing_scheduled_cancellation_notifications(opts, limit) do
      {replay_count, failed_count} =
        Enum.reduce(candidates, {0, 0}, &count_replayed_notification/2)

      {:ok,
       %{
         replay_count: replay_count,
         failed_count: failed_count,
         cursor: notification_replay_cursor(candidates, limit)
       }}
    end
  end

  def replay_scheduled_cancellation_notifications_for_system(_opts) do
    {:error, Error.new("VALIDATION_ERROR", "notification replay options must be a keyword list")}
  end

  defp terminalize_due_scheduled_cancellations(subscriptions, now_override) do
    Enum.reduce(subscriptions, %{canceled: 0, failed: 0}, fn subscription, counts ->
      result = terminalize_due_scheduled_cancellation_for_system(subscription.id, now_override)
      count_due_scheduled_cancellation(result, counts)
    end)
  end

  defp count_due_scheduled_cancellation({:ok, :noop}, counts), do: counts

  defp count_due_scheduled_cancellation(
         {:ok, {:canceled, canceled, notifications}},
         counts
       ) do
    :ok =
      AshNotifications.notify_post_commit(notifications,
        context: %{
          flow: :scheduled_boundary_cancellation,
          subscription_id: canceled.id
        }
      )

    case enqueue_scheduled_cancellation_email(canceled) do
      {:ok, _outbox_or_skipped} ->
        %{counts | canceled: counts.canceled + 1}

      {:error, _reason} ->
        %{counts | canceled: counts.canceled + 1, failed: counts.failed + 1}
    end
  end

  defp count_due_scheduled_cancellation({:error, _reason}, counts),
    do: %{counts | failed: counts.failed + 1}

  defp count_replayed_notification(subscription, {replayed, failed}) do
    case enqueue_scheduled_cancellation_email(subscription) do
      {:ok, _outbox_or_skipped} -> {replayed + 1, failed}
      {:error, _reason} -> {replayed, failed + 1}
    end
  end

  defp validate_optional_keyset_cursor(nil, nil), do: :ok

  defp validate_optional_keyset_cursor(%DateTime{}, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> :ok
      :error -> {:error, Error.new("VALIDATION_ERROR", "keyset cursor id must be a UUID")}
    end
  end

  defp validate_optional_keyset_cursor(_timestamp, _id),
    do:
      {:error,
       Error.new("VALIDATION_ERROR", "keyset cursor timestamp and id are required together")}

  @spec list_past_due_missing_failed_payment_boundary_for_system(keyword()) ::
          {:ok, [Subscription.t()]} | {:error, Error.t() | term()}
  def list_past_due_missing_failed_payment_boundary_for_system(opts \\ [])

  def list_past_due_missing_failed_payment_boundary_for_system(opts) when is_list(opts) do
    query =
      Subscription
      |> Ash.Query.for_read(:read_past_due_missing_boundary_for_system, %{
        after_id: Keyword.get(opts, :after_id),
        limit: opts |> Keyword.get(:limit, @default_due_limit) |> bounded_due_limit()
      })

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, subscriptions} -> {:ok, subscriptions}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  def list_past_due_missing_failed_payment_boundary_for_system(_opts) do
    {:error, Error.new("VALIDATION_ERROR", "quarantine query options must be a keyword list")}
  end

  @spec list_due_renewal_jobs_for_system(keyword()) ::
          {:ok,
           [
             %{
               subscription_id: String.t(),
               renewal_key: String.t(),
               schedule_in: non_neg_integer()
             }
           ]}
          | {:error, Error.t() | term()}
  def list_due_renewal_jobs_for_system(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    limit = Keyword.get(opts, :limit, @default_due_limit)

    query =
      Subscription
      |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: limit})
      |> Ash.Query.load([:subscription_plan])

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, due_subscriptions} ->
        due_subscriptions
        |> build_due_renewal_jobs(now)
        |> case do
          {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
          {:error, reason} -> {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp build_due_renewal_jobs(due_subscriptions, now) do
    Enum.reduce_while(due_subscriptions, {:ok, []}, fn subscription, {:ok, jobs} ->
      case due_job_for_subscription(subscription, now) do
        {:ok, job} ->
          {:cont, {:ok, [job | jobs]}}

        {:error,
         %Error{
           code: "VALIDATION_ERROR",
           message: @unresolved_contract_message
         }} ->
          {:cont, {:ok, jobs}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec process_due_subscription_renewal_for_system(String.t(), keyword()) ::
          {:ok, :processed | :noop} | {:error, Error.t() | term()}
  def process_due_subscription_renewal_for_system(subscription_id, opts \\ [])

  def process_due_subscription_renewal_for_system(subscription_id, opts)
      when is_binary(subscription_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    renewal_key = Keyword.get(opts, :renewal_key)

    case fetch_subscription_for_renewal(subscription_id) do
      {:ok, %Subscription{} = subscription} ->
        process_loaded_subscription_renewal(subscription, renewal_key, now)

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def process_due_subscription_renewal_for_system(_subscription_id, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "subscription_id must be a UUID")}
  end

  defp process_loaded_subscription_renewal(subscription, renewal_key, now) do
    case ensure_subscription_due(subscription, now) do
      :ok -> process_due_subscription_at_due(subscription, renewal_key, now)
      :not_due -> recover_reached_renewal_collection(subscription.id, now)
    end
  end

  defp process_due_subscription_at_due(subscription, renewal_key, now) do
    with {:ok, current_renewal_key, live_revision} <- due_renewal_identity(subscription, now),
         :ok <- ensure_matching_renewal_key(renewal_key, current_renewal_key) do
      case run_single_due_renewal(subscription, now, live_revision) do
        :ok -> {:ok, :processed}
        {:error, reason} -> {:error, reason}
      end
    else
      :stale -> {:ok, :noop}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp recover_reached_renewal_collection(subscription_id, now) do
    case RenewalCollectionAttempts.recover_reached_for_subscription_for_system(
           subscription_id,
           now
         ) do
      {:ok, nil} ->
        {:ok, :noop}

      {:ok, %{payment_intent: %PaymentIntent{}} = exact_claim} ->
        recover_reached_renewal_claim(exact_claim, now)

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp recover_reached_renewal_claim(exact_claim, now) do
    case recover_reached_collection_charge(exact_claim, now) do
      {:ok, _payment_intent} -> {:ok, :processed}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp recover_reached_collection_charge(
         %{
           payment_intent:
             %PaymentIntent{provider_payment_id: provider_payment_id} = payment_intent
         },
         _now
       )
       when is_binary(provider_payment_id) and provider_payment_id != "" do
    case reconcile_existing_renewal_collection(payment_intent) do
      {:error, %Error{code: code}}
      when code in ["PAYMENT_FAILED", "PAYMENT_AUTHENTICATION_REQUIRED"] ->
        {:ok, payment_intent}

      result ->
        result
    end
  end

  defp recover_reached_collection_charge(
         %{
           subscription: %Subscription{} = subscription,
           renewal_attempt: %RenewalAttempt{} = attempt,
           order: %Order{} = order,
           payment_intent: %PaymentIntent{} = payment_intent,
           provider_payment_method: provider_payment_method,
           collection_attempt:
             %RenewalCollectionAttempt{
               financial_outcome: financial_outcome
             } =
               collection
         },
         _now
       ) do
    if reached_collection_requires_reconciliation?(collection, payment_intent, subscription) do
      reconcile_reached_collection(payment_intent)
    else
      submit_reached_collection(
        subscription,
        attempt,
        order,
        payment_intent,
        provider_payment_method,
        collection,
        financial_outcome
      )
    end
  end

  defp recover_reached_collection_charge(
         %{payment_intent: %PaymentIntent{} = payment_intent},
         _now
       ) do
    case reconcile_existing_renewal_collection(payment_intent) do
      {:error, %Error{code: code}}
      when code in ["PAYMENT_FAILED", "PAYMENT_AUTHENTICATION_REQUIRED"] ->
        {:ok, payment_intent}

      result ->
        result
    end
  end

  defp reconcile_reached_collection(payment_intent) do
    case reconcile_existing_renewal_collection(payment_intent) do
      {:error, %Error{code: "PAYMENT_AUTHENTICATION_REQUIRED"}} -> {:ok, payment_intent}
      result -> result
    end
  end

  defp submit_reached_collection(
         subscription,
         attempt,
         order,
         payment_intent,
         provider_payment_method,
         collection,
         financial_outcome
       ) do
    with true <- financial_outcome == :unresolved,
         {:ok, submitted_payment_intent} <- maybe_submit_virtual_payment_intent(payment_intent),
         {:ok, charge_response} <-
           Providers.charge_off_session(
             subscription.provider,
             renewal_collection_charge_request(
               attempt,
               order,
               submitted_payment_intent,
               provider_payment_method,
               collection
             ),
             []
           ),
         {:ok, updated_payment_intent} <-
           persist_payment_intent_provider_refs(submitted_payment_intent, charge_response),
         {:ok, %{outcome: outcome}} <-
           PaymentsFacade.record_and_apply_payment_observation_for_system(
             updated_payment_intent,
             direct_charge_observation(
               subscription.provider,
               updated_payment_intent,
               charge_response
             )
           ) do
      replayed_collection_outcome(updated_payment_intent, outcome)
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_OUTCOME_UNRESOLVED",
           "only an unresolved collection may be replayed for submission",
           %{existing_collection_replay?: true}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replayed_collection_outcome(payment_intent, outcome)
       when outcome in [
              :authoritative_success,
              :already_applied_success,
              :verified_terminal_non_success,
              :requires_action
            ],
       do: {:ok, payment_intent}

  defp replayed_collection_outcome(_payment_intent, _outcome) do
    {:error,
     Error.new(
       "PAYMENT_OUTCOME_UNRESOLVED",
       "replayed renewal collection remains financially unresolved",
       %{existing_collection_replay?: true}
     )}
  end

  @spec reconcile_paid_subscription_renewal_for_system(String.t(), keyword()) ::
          {:ok, :reconciled | :noop} | {:error, Error.t() | term()}
  def reconcile_paid_subscription_renewal_for_system(order_id, opts \\ [])

  def reconcile_paid_subscription_renewal_for_system(order_id, opts)
      when is_binary(order_id) and is_list(opts) do
    renewal_attempt_id = Keyword.get(opts, :renewal_attempt_id)
    collection_attempt_id = Keyword.get(opts, :collection_attempt_id)
    payment_intent_id = Keyword.get(opts, :payment_intent_id)

    case fetch_renewal_attempt_by_order(order_id, renewal_attempt_id) do
      {:ok, %RenewalAttempt{} = attempt} ->
        with :ok <- ensure_complete_bound_renewal_attempt(attempt),
             {:ok, exact_payment_intent_id} <-
               ensure_exact_reconciliation_handoff(
                 order_id,
                 attempt,
                 collection_attempt_id,
                 payment_intent_id
               ) do
          reconcile_validated_paid_renewal(order_id, attempt, exact_payment_intent_id)
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def reconcile_paid_subscription_renewal_for_system(_order_id, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  defp reconcile_validated_paid_renewal(order_id, attempt, payment_intent_id) do
    if attempt.failure_code == @renewal_authority_withdrawn_code do
      reconcile_withdrawn_paid_renewal(order_id, attempt, payment_intent_id)
    else
      reconcile_authorized_paid_renewal(order_id, attempt, payment_intent_id)
    end
  end

  defp ensure_exact_reconciliation_handoff(
         order_id,
         attempt,
         collection_attempt_id,
         payment_intent_id
       )
       when is_binary(collection_attempt_id) and is_binary(payment_intent_id) do
    with {:ok, handoff} <-
           RenewalCollectionAttempts.success_handoff_for_system(collection_attempt_id),
         true <-
           handoff.order_id == order_id and
             handoff.renewal_attempt_id == attempt.id and
             handoff.payment_intent_id == payment_intent_id do
      {:ok, handoff.payment_intent_id}
    else
      false ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "exact renewal collection handoff conflicts")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_exact_reconciliation_handoff(
         _order_id,
         _attempt,
         _collection_id,
         _payment_intent_id
       ) do
    {:error,
     Error.new("PAYMENT_EVENT_UNVERIFIED", "exact renewal collection identity is incomplete")}
  end

  defp reconcile_authorized_paid_renewal(order_id, attempt, payment_intent_id) do
    with :ok <- ensure_matching_attempt_payment(order_id, attempt, payment_intent_id),
         {:ok, %Order{state: :paid} = order} <- fetch_paid_order(order_id),
         :ok <- ensure_renewal_payment_application(order.id, payment_intent_id),
         {:ok, reconciliation} <- reconcile_paid_renewal_attempt(attempt),
         {:ok, result} <-
           finish_paid_renewal_reconciliation(
             reconciliation,
             attempt,
             order_id,
             payment_intent_id
           ) do
      {:ok, result}
    else
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp finish_paid_renewal_reconciliation(
         %{outcome: :canceled},
         _attempt,
         _order_id,
         _payment_intent_id
       ),
       do: {:ok, :noop}

  defp finish_paid_renewal_reconciliation(
         %{
           outcome: :scheduled_cancellation,
           subscription: updated_subscription,
           notifications: notifications
         },
         attempt,
         order_id,
         payment_intent_id
       ) do
    with :ok <-
           AshNotifications.notify_post_commit(notifications,
             context: %{
               flow: :reconcile_paid_renewal,
               subscription_id: attempt.subscription_id
             }
           ),
         {:ok, _attempt} <- mark_attempt_succeeded(attempt, order_id, payment_intent_id),
         {:ok, _outbox_or_skipped} <- enqueue_scheduled_cancellation_email(updated_subscription) do
      {:ok, if(attempt.status == :succeeded, do: :noop, else: :reconciled)}
    end
  end

  defp finish_paid_renewal_reconciliation(
         %{
           outcome: outcome,
           subscription: updated_subscription,
           target: entitlement_target,
           notifications: notifications,
           renewal_access_effect_id: effect_id,
           grant_writer_lane: grant_writer_lane
         },
         attempt,
         order_id,
         payment_intent_id
       ) do
    with :ok <-
           AshNotifications.notify_post_commit(notifications,
             context: %{
               flow: :reconcile_paid_renewal,
               subscription_id: attempt.subscription_id
             }
           ),
         :ok <- emit_paid_renewal_access_sync_boundary(updated_subscription, attempt),
         :ok <-
           sync_charged_renewal_access(
             grant_writer_lane,
             effect_id,
             updated_subscription,
             entitlement_target
           ),
         {:ok, _attempt} <- mark_attempt_succeeded(attempt, order_id, payment_intent_id) do
      {:ok,
       if(outcome == :already_applied and attempt.status == :succeeded,
         do: :noop,
         else: :reconciled
       )}
    end
  end

  defp reconcile_withdrawn_paid_renewal(order_id, attempt, payment_intent_id) do
    with :ok <- ensure_matching_attempt_payment(order_id, attempt, payment_intent_id),
         {:ok, %Order{} = order} <- fetch_order_for_system(order_id),
         :ok <- ensure_withdrawn_renewal_order_state(order),
         :ok <- ensure_renewal_payment_application(order.id, payment_intent_id),
         {:ok, _refund} <-
           PaymentsFacade.request_renewal_cancellation_remediation_for_system(
             %RenewalCancellationRemediationInput{
               renewal_attempt_id: attempt.id,
               order_id: order.id,
               payment_intent_id: payment_intent_id
             }
           ) do
      {:ok, :noop}
    else
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_withdrawn_renewal_order_state(%Order{state: state})
       when state in [:paid, :refunded],
       do: :ok

  defp ensure_withdrawn_renewal_order_state(_order) do
    {:error,
     Error.new("INVALID_STATE_TRANSITION", "order must be paid before renewal remediation")}
  end

  defp ensure_renewal_payment_application(order_id, payment_intent_id)
       when is_binary(payment_intent_id) do
    input = %RenewalPaymentApplicationInput{
      order_id: order_id,
      payment_intent_id: payment_intent_id
    }

    case PaymentsFacade.renewal_payment_application_status_for_system(input) do
      {:ok, :applied} ->
        :ok

      {:ok, :unapplied} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "paid renewal order has no exact payment application"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_renewal_payment_application(_order_id, _payment_intent_id) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal payment intent is missing")}
  end

  defp count_due_renewal_results(due_subscriptions, now) do
    Enum.reduce(due_subscriptions, %{success: 0, failed: 0}, fn subscription, acc ->
      result =
        with {:ok, _renewal_key, live_revision} <- due_renewal_identity(subscription, now) do
          run_single_due_renewal(subscription, now, live_revision)
        end

      case result do
        :ok -> %{success: acc.success + 1, failed: acc.failed}
        {:error, _reason} -> %{success: acc.success, failed: acc.failed + 1}
      end
    end)
  end

  defp due_job_for_subscription(%Subscription{} = subscription, now) do
    with {:ok, renewal_key} <- due_renewal_key(subscription, now) do
      {:ok,
       %{
         subscription_id: subscription.id,
         renewal_key: renewal_key,
         schedule_in: Scheduler.renewal_jitter_seconds(subscription.id)
       }}
    end
  end

  defp due_renewal_key(%Subscription{} = subscription, now) do
    with {:ok, renewal_key, _revision} <- due_renewal_identity(subscription, now) do
      {:ok, renewal_key}
    end
  end

  defp due_renewal_identity(%Subscription{} = subscription, now) do
    with :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, revision} <- fetch_plan_revision(subscription.current_plan_revision_id),
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         {:ok, renewal_period} <- renewal_period(subscription, revision, now) do
      {:ok, Scheduler.renewal_key(subscription.id, renewal_period.current_period_end_at),
       revision}
    end
  end

  defp fetch_subscription_for_renewal(subscription_id) do
    query = Subscription |> Ash.Query.filter(expr(id == ^subscription_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%Subscription{} = subscription | _]} ->
        {:ok, subscription}

      {:ok, []} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_subscription_for_renewal_locked(subscription_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(id == ^subscription_id))
      |> Ash.Query.lock("FOR UPDATE")

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %Subscription{} = subscription} -> {:ok, subscription}
      {:ok, nil} -> {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_expected_subscription_version(
         %Subscription{id: subscription_id, aggregate_version: expected_version},
         %Subscription{id: subscription_id, aggregate_version: expected_version}
       ),
       do: :ok

  defp ensure_expected_subscription_version(
         %Subscription{id: subscription_id},
         %Subscription{id: subscription_id}
       ) do
    _ = reload_subscription_after_stale_update(subscription_id)

    {:error,
     Error.new(
       "STALE_RECORD",
       "subscription changed while the command was in progress; reload and re-evaluate it"
     )}
  end

  defp ensure_expected_subscription_version(_expected, _locked) do
    {:error, Error.new("STALE_RECORD", "subscription identity changed while binding renewal")}
  end

  defp ensure_subscription_due(%Subscription{cancel_at_period_end: true}, _now), do: :not_due

  defp ensure_subscription_due(
         %Subscription{status: :active, next_renewal_at: %DateTime{} = next_at},
         now
       ) do
    if DateTime.compare(next_at, now) in [:lt, :eq], do: :ok, else: :not_due
  end

  defp ensure_subscription_due(
         %Subscription{status: :past_due, failed_payment_boundary_at: nil},
         _now
       ),
       do: :not_due

  defp ensure_subscription_due(
         %Subscription{status: :past_due, retry_suppressed_at: %DateTime{}},
         _now
       ),
       do: :not_due

  defp ensure_subscription_due(
         %Subscription{status: :past_due, retry_suppressed_at: nil, next_retry_at: nil},
         _now
       ),
       do: :ok

  defp ensure_subscription_due(
         %Subscription{
           status: :past_due,
           retry_suppressed_at: nil,
           next_retry_at: %DateTime{} = next_retry_at
         },
         now
       ) do
    if DateTime.compare(next_retry_at, now) in [:lt, :eq], do: :ok, else: :not_due
  end

  defp ensure_subscription_due(_subscription, _now), do: :not_due

  defp ensure_matching_renewal_key(nil, _current_renewal_key), do: :ok

  defp ensure_matching_renewal_key(expected_renewal_key, current_renewal_key)
       when expected_renewal_key == current_renewal_key,
       do: :ok

  defp ensure_matching_renewal_key(_expected_renewal_key, _current_renewal_key), do: :stale

  defp run_single_due_renewal(
         %Subscription{} = subscription,
         now,
         %PlanRevision{} = live_revision
       ) do
    started_at = System.monotonic_time()

    result =
      with :ok <- ensure_subscription_contract_resolved(subscription),
           :ok <-
             ensure_revision_belongs_to_plan(live_revision, subscription.subscription_plan_id),
           {:ok, renewal_identity_period} <- renewal_period(subscription, live_revision, now),
           renewal_key <-
             Scheduler.renewal_key(subscription.id, renewal_identity_period.current_period_end_at),
           {:ok, binding} <- bind_renewal_attempt(subscription, renewal_key, live_revision) do
        bound_subscription = binding.subscription
        bound_attempt = binding.attempt
        bound_policy = renewal_policy_from_attempt(bound_attempt)

        result =
          case claim_renewal_attempt(bound_attempt) do
            :ok ->
              run_claimed_due_renewal(bound_subscription, bound_attempt, now, live_revision)

            {:resume_existing, claimed_attempt} ->
              run_claimed_due_renewal(bound_subscription, claimed_attempt, now, live_revision)

            {:skip, :already_claimed} ->
              :ok

            {:error, reason} ->
              {:claim_error, reason}
          end

        settle_due_renewal_result(
          result,
          bound_subscription,
          bound_attempt,
          bound_policy,
          now
        )
      else
        {:error,
         %Error{
           code: "VALIDATION_ERROR",
           message: @unresolved_contract_message
         } = error} ->
          {:error, error}

        {:error, %Error{code: "STALE_RECORD"} = error} ->
          {:error, error}

        {:error, %Error{code: "VALIDATION_ERROR"} = error} ->
          {:error, error}

        {:error, reason} ->
          mark_subscription_past_due(subscription, reason)
          |> stale_result_or({:error, reason})
      end

    emit_subscription_renewal_attempt_telemetry(subscription, result, started_at)
    result
  end

  defp settle_due_renewal_result(
         {:claim_error, reason},
         _subscription,
         _attempt,
         _policy,
         _now
       ),
       do: {:error, reason}

  defp settle_due_renewal_result(
         {:renewal_failure, reason, collection_attempt},
         subscription,
         attempt,
         policy,
         now
       ) do
    case settle_renewal_failure(
           subscription,
           attempt,
           collection_attempt,
           policy,
           reason,
           now
         ) do
      {:ok, %{outcome: :failure_recorded} = settlement} ->
        finish_renewal_failure_settlement(settlement)
        {:error, reason}

      {:ok, %{outcome: :success_won, handoff: handoff}} ->
        reconcile_failure_suppressed_success(handoff)

      {:ok, %{outcome: outcome}}
      when outcome in [:success_already_terminal, :terminal_noop] ->
        :ok

      {:error, settlement_error} ->
        preserve_payment_failure_after_settlement_rollback(reason, settlement_error)
    end
  end

  defp settle_due_renewal_result(
         {:authentication_settlement_error, reason},
         _subscription,
         _attempt,
         _policy,
         _now
       ),
       do: {:error, reason}

  defp settle_due_renewal_result(result, _subscription, _attempt, _policy, _now), do: result

  defp preserve_payment_failure_after_settlement_rollback(
         %Error{code: "PAYMENT_FAILED"} = reason,
         %Error{code: "TARGET_ORDER_BLOCKED", meta: %{keep_grace_establishment: true}}
       ),
       do: {:error, reason}

  defp preserve_payment_failure_after_settlement_rollback(_reason, settlement_error),
    do: {:error, settlement_error}

  defp map_keep_grace_establishment_failure({:ok, _} = ok), do: ok

  defp map_keep_grace_establishment_failure({:error, error}),
    do: {:error, keep_grace_access_effect_establishment_failed(Normalize.normalize(error))}

  defp keep_grace_access_effect_establishment_failed(%Error{} = cause) do
    Error.new(
      "TARGET_ORDER_BLOCKED",
      "keep_during_grace AccessEffect establishment failed during payment failure settlement",
      %{cause: cause, keep_grace_establishment: true}
    )
  end

  defp ensure_subscription_contract_resolved(%Subscription{current_plan_revision_id: id})
       when is_binary(id),
       do: :ok

  defp ensure_subscription_contract_resolved(%Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       @unresolved_contract_message
     )}
  end

  defp ensure_no_future_target_for_renewal(%Subscription{} = subscription) do
    if is_binary(subscription.current_contract_change_id) or
         legacy_future_projection?(subscription) do
      {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}
    else
      case fetch_queued_contract_change(subscription.id) do
        {:ok, nil} ->
          :ok

        {:ok, _orphaned_target} ->
          {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp legacy_future_projection?(%Subscription{} = subscription) do
    is_binary(subscription.pending_subscription_plan_id) or
      is_binary(subscription.pending_variant_id) or
      not is_nil(subscription.pending_renewal_amount_minor) or
      not is_nil(subscription.pending_renewal_currency) or
      not is_nil(subscription.change_effective_at)
  end

  defp run_claimed_due_renewal(subscription, attempt, now, live_revision) do
    renewal_period = renewal_period_from_attempt(attempt)

    with {:ok, effective_contract} <- effective_renewal_contract(attempt, live_revision),
         :ok <- ensure_renewal_chargeability(subscription, effective_contract.plan),
         {:ok, checkout} <-
           build_or_reuse_renewal_checkout(
             subscription,
             effective_contract,
             renewal_period,
             attempt,
             now
           ) do
      request_off_session_renewal_charge(
        subscription,
        effective_contract.plan,
        attempt,
        checkout,
        checkout.collection_attempt,
        now
      )
      |> classify_claimed_renewal_charge_result(checkout.collection_attempt)
    else
      {:error, %Error{code: "STALE_RECORD"} = reason} ->
        {:error, reason}

      {:error, %Error{code: "PAYMENT_AUTHENTICATION_REQUIRED"}} ->
        :ok

      {:error,
       %Error{
         code: "PAYMENT_OUTCOME_UNRESOLVED",
         meta: %{existing_collection_replay?: true}
       } = reason} ->
        {:error, reason}

      {:error,
       %Error{
         code: "INVALID_STATE_TRANSITION",
         meta: %{already_succeeded?: true}
       }} ->
        :ok

      {:error, %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"}} ->
        :ok

      {:error, %Error{code: "RENEWAL_AUTHORITY_WITHDRAWN"}} ->
        :ok

      {:error, reason} ->
        {:renewal_failure, reason, nil}
    end
  end

  defp classify_claimed_renewal_charge_result({:ok, _payment_intent}, _collection_attempt),
    do: :ok

  defp classify_claimed_renewal_charge_result(
         {:error, %Error{code: "STALE_RECORD"} = reason},
         _collection_attempt
       ),
       do: {:error, reason}

  defp classify_claimed_renewal_charge_result(
         {:error, %Error{code: "PAYMENT_AUTHENTICATION_REQUIRED"}},
         _collection_attempt
       ),
       do: :ok

  defp classify_claimed_renewal_charge_result(
         {:error,
          %Error{
            code: "PAYMENT_OUTCOME_UNRESOLVED",
            meta: %{existing_collection_replay?: true}
          } = reason},
         _collection_attempt
       ),
       do: {:error, reason}

  defp classify_claimed_renewal_charge_result(
         {:error,
          %Error{
            code: "INVALID_STATE_TRANSITION",
            meta: %{already_succeeded?: true}
          }},
         _collection_attempt
       ),
       do: :ok

  defp classify_claimed_renewal_charge_result(
         {:error, %Error{code: "PAYMENT_OUTCOME_UNRESOLVED"}},
         _collection_attempt
       ),
       do: :ok

  defp classify_claimed_renewal_charge_result(
         {:error, %Error{code: "RENEWAL_AUTHORITY_WITHDRAWN"}},
         _collection_attempt
       ),
       do: :ok

  defp classify_claimed_renewal_charge_result(
         {:error, {:authentication_settlement_failed, reason}},
         _collection_attempt
       ),
       do: {:authentication_settlement_error, reason}

  defp classify_claimed_renewal_charge_result({:error, reason}, collection_attempt),
    do: {:renewal_failure, reason, collection_attempt}

  defp fetch_paid_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [%Order{state: :paid} = order | _]} ->
        {:ok, order}

      {:ok, [%Order{}]} ->
        {:error,
         Error.new(
           "INVALID_STATE_TRANSITION",
           "order must be paid before subscription activation"
         )}

      {:ok, []} ->
        {:error, Error.new("ORDER_NOT_FOUND", "order not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_order_for_system(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [%Order{} = order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_order_user(%Order{user_id: user_id}) when is_binary(user_id), do: :ok

  defp ensure_order_user(%Order{}) do
    {:error, Error.new("VALIDATION_ERROR", "subscriptions require an authenticated user")}
  end

  defp fetch_subscription_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(
        expr(order_id == ^order_id and not is_nil(subscription_plan_id_snapshot))
      )
      |> Ash.Query.sort(line_no: :asc)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_all_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.sort(line_no: :asc)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp create_subscription_from_line(
         %Order{} = order,
         %OrderLineItem{} = line_item,
         %PaymentIntent{} = payment_intent,
         stored_payment_method
       ) do
    with {:ok, nil} <- fetch_subscription_by_source_line(line_item.id),
         {:ok, plan} <- fetch_plan(Map.get(line_item, :subscription_plan_id_snapshot)),
         {:ok, revision} <-
           fetch_plan_revision(Map.get(line_item, :subscription_plan_revision_id_snapshot)),
         :ok <- ensure_revision_belongs_to_plan(revision, plan.id),
         :ok <- ensure_revision_has_purchase_history(revision),
         {:ok, provider_selection} <- resolve_provider_and_billing_mode(order, plan),
         period <-
           Scheduler.initial_period(
             DateTime.utc_now() |> DateTime.truncate(:microsecond),
             revision
           ),
         {:ok, subscription, subscription_notifications} <-
           create_subscription_record(
             order,
             line_item,
             plan,
             revision,
             period,
             provider_selection,
             payment_intent,
             stored_payment_method
           ),
         {:ok, _item, item_notifications} <-
           create_subscription_item_record(subscription, line_item, plan, revision) do
      {:ok, :created, %{subscription: subscription, plan: plan, revision: revision},
       subscription_notifications ++ item_notifications}
    else
      {:ok, %Subscription{}} ->
        {:ok, :skipped, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_subscription_by_source_line(source_order_line_item_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(source_order_line_item_id == ^source_order_line_item_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [subscription | _]} -> {:ok, subscription}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_plan(plan_id) when is_binary(plan_id) do
    query = SubscriptionPlan |> Ash.Query.filter(expr(id == ^plan_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%SubscriptionPlan{} = plan | _]} -> {:ok, plan}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "subscription plan not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_plan(_plan_id), do: {:error, Error.new("VALIDATION_ERROR", "plan_id must be a UUID")}

  defp fetch_plan_revision(revision_id) when is_binary(revision_id) do
    query = PlanRevision |> Ash.Query.filter(expr(id == ^revision_id))

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%PlanRevision{} = revision | _]} ->
        {:ok, revision}

      {:ok, []} ->
        {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_plan_revision(_revision_id) do
    {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}
  end

  defp ensure_revision_belongs_to_plan(
         %PlanRevision{subscription_plan_id: subscription_plan_id},
         subscription_plan_id
       ),
       do: :ok

  defp ensure_revision_belongs_to_plan(_revision, _subscription_plan_id) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "purchased plan revision does not belong to the snapshotted subscription plan"
     )}
  end

  defp ensure_revision_has_purchase_history(%PlanRevision{status: status})
       when status in [:effective, :retired],
       do: :ok

  defp ensure_revision_has_purchase_history(%PlanRevision{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "purchased plan revision was never effective"
     )}
  end

  defp resolve_provider_and_billing_mode(%Order{} = order, _plan) do
    with {:ok, %PaymentIntent{} = payment_intent} <- fetch_succeeded_payment_intent(order.id),
         {:ok, provider} <- normalize_selected_provider(payment_intent.provider),
         :ok <- Providers.ensure_enabled_provider(provider),
         {:ok, capabilities} <- fetch_provider_capabilities(provider),
         {:ok, billing_mode} <- choose_billing_mode(capabilities) do
      {:ok, %{provider: provider, billing_mode: billing_mode}}
    end
  end

  defp fetch_succeeded_payment_intent(order_id) when is_binary(order_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(expr(order_id == ^order_id and state == :succeeded))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [%PaymentIntent{} = payment_intent | _]} ->
        {:ok, payment_intent}

      {:ok, []} ->
        {:error,
         Error.new(
           "SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED",
           "subscription provider selection is missing for paid order"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_succeeded_payment_intent(_order_id) do
    {:error, Error.new("VALIDATION_ERROR", "order_id must be a UUID")}
  end

  defp normalize_selected_provider(provider) do
    case Providers.normalize_provider(provider) do
      :unknown ->
        {:error,
         Error.new("SUBSCRIPTION_PROVIDER_UNSUPPORTED", "subscription provider is unsupported")}

      known ->
        if Providers.known_provider?(known) do
          {:ok, known}
        else
          {:error,
           Error.new(
             "SUBSCRIPTION_PROVIDER_UNSUPPORTED",
             "subscription provider is unsupported"
           )}
        end
    end
  end

  defp fetch_provider_capabilities(provider) do
    case Providers.capabilities(provider) do
      capabilities when is_map(capabilities) ->
        {:ok, capabilities}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp choose_billing_mode(capabilities) when is_map(capabilities) do
    provider_managed_enabled? = subscription_feature_enabled?(:provider_managed_mode_enabled?)

    supports_provider_managed? =
      Map.get(capabilities, :supports_provider_managed_subscriptions?, false)

    supports_merchant_managed? =
      Map.get(capabilities, :supports_merchant_initiated_charges?, false)

    cond do
      provider_managed_enabled? and supports_provider_managed? ->
        {:ok, :provider_managed}

      supports_merchant_managed? ->
        {:ok, :merchant_managed}

      supports_provider_managed? and not provider_managed_enabled? ->
        {:error,
         Error.new(
           "SUBSCRIPTION_PROVIDER_MODE_DISABLED",
           "provider-managed subscriptions are disabled by feature flag"
         )}

      true ->
        {:error,
         Error.new(
           "SUBSCRIPTION_BILLING_MODE_UNSUPPORTED",
           "provider capabilities do not support subscription billing"
         )}
    end
  end

  defp subscription_feature_enabled?(key) when is_atom(key) do
    :store
    |> Application.get_env(:subscription_features, [])
    |> Keyword.get(key, false)
  end

  defp create_subscription_record(
         order,
         line_item,
         plan,
         revision,
         period,
         provider_selection,
         payment_intent,
         stored_payment_method
       ) do
    attrs = %{
      user_id: order.user_id,
      subscription_plan_id: plan.id,
      variant_id: line_item.variant_id_snapshot,
      status: :active,
      provider: provider_selection.provider,
      billing_mode: provider_selection.billing_mode,
      quantity: line_item.quantity,
      renewal_amount_minor: revision.amount_minor,
      renewal_currency: String.upcase(revision.currency),
      membership_key: membership_key_for_plan(revision),
      provider_customer_ref:
        payment_intent.provider_customer_ref ||
          (stored_payment_method && stored_payment_method.provider_customer_ref),
      provider_billing_ref:
        payment_intent.provider_payment_method_ref ||
          (stored_payment_method && stored_payment_method.provider_payment_method_ref),
      stored_payment_method_id: stored_payment_method && stored_payment_method.id,
      started_at: period.current_period_start_at,
      current_period_start_at: period.current_period_start_at,
      current_period_end_at: period.current_period_end_at,
      next_renewal_at: period.next_renewal_at,
      dunning_attempt_count: 0,
      next_retry_at: nil,
      source_order_id: order.id,
      source_order_line_item_id: line_item.id,
      current_plan_revision_id: revision.id
    }

    Subscription
    |> Ash.Changeset.for_create(:create_from_order_line, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> unwrap_create_with_notifications()
  end

  defp maybe_upsert_stored_payment_method(_user_id, %PaymentIntent{} = payment_intent)
       when payment_intent.provider_customer_ref in [nil, ""] or
              payment_intent.provider_payment_method_ref in [nil, ""] do
    {:ok, nil, []}
  end

  defp maybe_upsert_stored_payment_method(user_id, %PaymentIntent{} = payment_intent)
       when is_binary(user_id) do
    with {:ok, provider} <- normalize_selected_provider(payment_intent.provider) do
      StoredPaymentMethod
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          user_id: user_id,
          provider: provider,
          provider_customer_ref: payment_intent.provider_customer_ref,
          provider_payment_method_ref: payment_intent.provider_payment_method_ref,
          status: :active
        },
        context: %{system?: true}
      )
      |> Ash.create(
        domain: Subscriptions,
        authorize?: false,
        context: %{system?: true},
        return_notifications?: true
      )
      |> unwrap_create_with_notifications()
    end
  end

  defp maybe_upsert_stored_payment_method(_user_id, _payment_intent), do: {:ok, nil, []}

  defp create_subscription_item_record(subscription, line_item, plan, revision) do
    attrs = %{
      subscription_id: subscription.id,
      variant_id: line_item.variant_id_snapshot,
      quantity: line_item.quantity,
      plan_key_snapshot: line_item.subscription_plan_key_snapshot || plan.key,
      amount_minor_snapshot: revision.amount_minor,
      currency_snapshot: revision.currency,
      interval_unit_snapshot: revision.interval_unit,
      interval_count_snapshot: revision.interval_count,
      source_order_line_item_id: line_item.id
    }

    SubscriptionItem
    |> Ash.Changeset.for_create(:create_from_order_line, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> unwrap_create_with_notifications()
  end

  defp maybe_issue_entitlement(subscription, plan) do
    if is_nil(plan.entitlement_kind) do
      :skipped
    else
      case EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan) do
        {:ok, _grant} -> :issued
        {:error, _reason} -> :skipped
      end
    end
  end

  defp emit_paid_renewal_access_sync_boundary(
         %Subscription{},
         %RenewalAttempt{}
       ) do
    :telemetry.execute(
      [:store, :subscriptions, :paid_renewal_access_sync],
      %{count: 1},
      %{}
    )

    :ok
  end

  defp unwrap_create_with_notifications({:ok, record, notifications}) when is_list(notifications),
    do: {:ok, record, notifications}

  defp unwrap_create_with_notifications({:ok, record}), do: {:ok, record, []}
  defp unwrap_create_with_notifications({:error, reason}), do: {:error, reason}

  defp normalize_transaction_notifications({:ok, {:ok, tx_result}}) when is_map(tx_result) do
    {:ok, Map.delete(tx_result, :notifications), Map.get(tx_result, :notifications, [])}
  end

  defp normalize_transaction_notifications({:error, reason}),
    do: {:error, Normalize.normalize(reason)}

  defp issue_subscription_entitlements_after_commit(entitlement_pairs) do
    entitlement_pairs
    |> Enum.reverse()
    |> Enum.reduce(0, fn {subscription, plan}, count ->
      case maybe_issue_entitlement(subscription, plan) do
        :issued -> count + 1
        _ -> count
      end
    end)
  end

  defp run_cancel(%Subscription{} = subscription, mode, actor)
       when mode in [:period_end, :now] do
    attrs =
      %{
        current_contract_change_id: nil,
        pending_variant_id: nil,
        pending_subscription_plan_id: nil,
        pending_renewal_amount_minor: nil,
        pending_renewal_currency: nil,
        change_effective_at: nil
      }

    transaction_result =
      Repo.transaction(fn ->
        cancel_subscription_in_transaction(subscription, mode, attrs, actor)
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok,
       %{
         subscription: canceled,
         effective_mode: effective_mode,
         inventory_variant_ids: inventory_variant_ids,
         cancellation_access: cancellation_access
       }, notifications} ->
        _ = Orders.invalidate_inventory_availability_for_variants(inventory_variant_ids)

        :ok =
          AshNotifications.notify_post_commit(
            notifications,
            context: %{
              flow: :cancel_subscription,
              subscription_id: subscription.id,
              mode: mode,
              effective_mode: effective_mode
            }
          )

        case {effective_mode, canceled.status, canceled.canceled_reason} do
          {:now, _status, _reason} ->
            finalize_immediate_cancellation(canceled, cancellation_access)

          {:period_end, :canceled, "canceled_period_end"} ->
            _ = enqueue_scheduled_cancellation_email(canceled)

          _ ->
            :ok
        end

        {:ok, canceled}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp run_cancel_with_authorized_retry(%Subscription{} = subscription, :now, actor, audience)
       when audience in [:user, :admin] do
    case run_cancel_now_or_noop(subscription, actor) do
      {:error, %Error{code: "STALE_RECORD", message: message}}
      when message ==
             "subscription changed while the command was in progress; reload and re-evaluate it" ->
        case reload_authorized_subscription(audience, actor, subscription.id) do
          {:ok, %Subscription{} = fresh_subscription} ->
            run_cancel_now_or_noop(fresh_subscription, actor)

          {:ok, nil} ->
            {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      result ->
        result
    end
  end

  defp run_cancel_with_authorized_retry(%Subscription{} = subscription, mode, actor, _audience),
    do: run_cancel(subscription, mode, actor)

  defp run_cancel_now_or_noop(
         %Subscription{status: :canceled, cancel_at_period_end: false} = subscription,
         _actor
       ),
       do: {:ok, subscription}

  defp run_cancel_now_or_noop(%Subscription{} = subscription, actor),
    do: run_cancel(subscription, :now, actor)

  defp reload_authorized_subscription(:user, actor, subscription_id),
    do: get_subscription_for_user(actor, subscription_id)

  defp reload_authorized_subscription(:admin, actor, subscription_id),
    do: get_subscription_for_admin(actor, subscription_id)

  defp finalize_immediate_cancellation(
         %Subscription{},
         %{access_effect: %{id: effect_id, disposition: :effective}}
       ) do
    _ = execute_effective_access_effect_for_system(effect_id)
    :ok
  end

  defp finalize_immediate_cancellation(
         %Subscription{} = canceled,
         %{
           access_effect: %{id: effect_id, disposition: :non_effective},
           membership_access_ended_email?: true
         }
       ) do
    case execute_suspension_access_effect_for_system(effect_id) do
      {:ok, outcome} when outcome in [:applied, :applied_projection_pending] ->
        _ =
          Comms.enqueue_membership_access_ended_for_system(
            canceled.id,
            "canceled_now",
            membership_access_proven?: true
          )

      _ ->
        :ok
    end
  end

  defp finalize_immediate_cancellation(
         %Subscription{},
         %{access_effect: %{disposition: :non_effective}}
       ) do
    :ok
  end

  defp finalize_immediate_cancellation(%Subscription{}, _cancellation_access), do: :ok

  defp cancel_subscription_in_transaction(subscription, requested_mode, attrs, actor) do
    with :ok <- lock_subscription_aggregate_version(subscription),
         {:ok, renewal_attempt} <- find_cancellation_renewal_attempt(subscription),
         :ok <- ensure_cancellation_attempt_owner(subscription, renewal_attempt),
         {:ok, payment_application_status} <-
           cancellation_payment_application_status(renewal_attempt),
         :ok <-
           ensure_cancellation_payment_precedence(renewal_attempt, payment_application_status),
         effective_mode <-
           effective_cancellation_mode(
             requested_mode,
             subscription,
             renewal_attempt,
             payment_application_status
           ),
         :ok <- ensure_cancel_now_source_state(effective_mode, subscription),
         {:ok, target_attrs} <-
           cancellation_target_attrs(
             effective_mode,
             subscription,
             renewal_attempt,
             payment_application_status
           ),
         {:ok, attempt_notifications} <-
           classify_renewal_attempt_for_cancellation(
             renewal_attempt,
             payment_application_status,
             effective_mode
           ),
         {:ok, released_inventory} <-
           release_withdrawn_renewal_inventory(
             renewal_attempt,
             payment_application_status,
             effective_mode
           ),
         action <- cancellation_action(effective_mode),
         attrs <- cancellation_attrs(attrs, effective_mode, target_attrs),
         {:ok, current_target} <- current_contract_change(subscription),
         {:ok, transition_notifications} <-
           maybe_transition_contract_change(current_target, :cancel),
         {:ok, canceled, subscription_notifications} <-
           update_subscription_contract_change(subscription, action, attrs, actor),
         {:ok, cancellation_access} <-
           maybe_establish_immediate_cancellation_access_effect(effective_mode, canceled) do
      {:ok,
       %{
         subscription: canceled,
         effective_mode: effective_mode,
         cancellation_access: cancellation_access,
         notifications:
           attempt_notifications ++ transition_notifications ++ subscription_notifications,
         inventory_variant_ids:
           (Enum.map(released_inventory.reservations, & &1.variant_id) ++
              released_inventory.collection_variant_ids)
           |> Enum.uniq()
       }}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp find_cancellation_renewal_attempt(%Subscription{
         id: subscription_id,
         current_period_end_at: %DateTime{} = period_start_at
       }) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(
        expr(subscription_id == ^subscription_id and period_start_at == ^period_start_at)
      )
      |> Ash.Query.limit(2)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [%RenewalAttempt{} = attempt]} ->
        {:ok, attempt}

      {:ok, [_first, _second]} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "multiple renewal attempts match the current paid-period boundary"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp find_cancellation_renewal_attempt(%Subscription{}), do: {:ok, nil}

  defp ensure_cancellation_attempt_owner(_subscription, nil), do: :ok

  defp ensure_cancellation_attempt_owner(
         %Subscription{id: subscription_id},
         %RenewalAttempt{subscription_id: subscription_id}
       ),
       do: :ok

  defp ensure_cancellation_attempt_owner(_subscription, _attempt) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "scheduled cancellation attempt must belong to the target Subscription"
     )}
  end

  defp cancellation_payment_application_status(nil), do: {:ok, :unapplied}

  defp cancellation_payment_application_status(%RenewalAttempt{
         order_id: nil,
         payment_intent_id: nil
       }),
       do: {:ok, :unapplied}

  defp cancellation_payment_application_status(%RenewalAttempt{
         order_id: order_id,
         payment_intent_id: nil
       })
       when is_binary(order_id) do
    PaymentsFacade.serialize_renewal_order_payment_application_for_system(
      %RenewalOrderPaymentApplicationInput{order_id: order_id}
    )
  end

  defp cancellation_payment_application_status(%RenewalAttempt{
         order_id: order_id,
         payment_intent_id: payment_intent_id
       })
       when is_binary(order_id) and is_binary(payment_intent_id) do
    PaymentsFacade.serialize_renewal_payment_application_for_system(
      %RenewalPaymentApplicationInput{
        order_id: order_id,
        payment_intent_id: payment_intent_id
      }
    )
  end

  defp cancellation_payment_application_status(%RenewalAttempt{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "renewal attempt has an incomplete Order and PaymentIntent binding"
     )}
  end

  defp ensure_cancellation_payment_precedence(
         %RenewalAttempt{status: :succeeded},
         :unapplied
       ) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "successful renewal attempt has no exact payment application"
     )}
  end

  defp ensure_cancellation_payment_precedence(_attempt, _payment_application_status), do: :ok

  defp effective_cancellation_mode(:now, _subscription, _attempt, _payment_application_status),
    do: :now

  defp effective_cancellation_mode(
         :period_end,
         _subscription,
         %RenewalAttempt{},
         _payment_status
       ),
       do: :period_end

  defp effective_cancellation_mode(
         :period_end,
         %Subscription{current_period_end_at: %DateTime{} = period_end_at},
         nil,
         :unapplied
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    if DateTime.compare(period_end_at, now) == :gt do
      :period_end
    else
      :now
    end
  end

  defp effective_cancellation_mode(:period_end, %Subscription{}, nil, :unapplied), do: :now

  defp cancellation_target_attrs(
         :period_end,
         %Subscription{},
         %RenewalAttempt{id: attempt_id},
         :unapplied
       ) do
    {:ok, %{cancel_at_period_end_at: nil, cancel_after_renewal_attempt_id: attempt_id}}
  end

  defp cancellation_target_attrs(
         :period_end,
         %Subscription{} = subscription,
         %RenewalAttempt{id: attempt_id, period_end_at: period_end_at} = attempt,
         :applied
       ) do
    with {:ok, commercially_applied?} <-
           cancellation_attempt_commercially_applied?(subscription, attempt) do
      if commercially_applied? do
        {:ok, %{cancel_at_period_end_at: period_end_at, cancel_after_renewal_attempt_id: nil}}
      else
        {:ok, %{cancel_at_period_end_at: nil, cancel_after_renewal_attempt_id: attempt_id}}
      end
    end
  end

  defp cancellation_target_attrs(
         :period_end,
         %Subscription{current_period_end_at: %DateTime{} = period_end_at},
         nil,
         :unapplied
       ) do
    {:ok, %{cancel_at_period_end_at: period_end_at, cancel_after_renewal_attempt_id: nil}}
  end

  defp cancellation_target_attrs(:now, _subscription, _attempt, _payment_status) do
    {:ok, %{cancel_at_period_end_at: nil, cancel_after_renewal_attempt_id: nil}}
  end

  defp cancellation_attempt_commercially_applied?(subscription, attempt) do
    if reconciliation_period_matches?(subscription, attempt),
      do: exact_cancellation_reconciliation_applied?(subscription, attempt),
      else: {:ok, false}
  end

  defp exact_cancellation_reconciliation_applied?(subscription, attempt) do
    with {:ok, revision} <- fetch_plan_revision(attempt.plan_revision_id),
         {:ok, contract_change} <- lock_reconciliation_contract_change(attempt.contract_change_id),
         :ok <- validate_reconciliation_contract_change(contract_change, subscription, attempt) do
      cancellation_reconciliation_replay_result(
        subscription,
        contract_change,
        attempt,
        revision
      )
    end
  end

  defp cancellation_reconciliation_replay_result(subscription, contract_change, attempt, revision) do
    case exact_reconciliation_replay(
           subscription,
           contract_change,
           attempt,
           revision,
           renewal_entitlement_target(attempt)
         ) do
      {:continue, :replay} -> {:ok, true}
      {:continue, :apply} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancellation_action(:period_end), do: :cancel_at_period_end_transition
  defp cancellation_action(:now), do: :cancel_now_transition

  defp cancellation_attrs(attrs, :period_end, target_attrs),
    do: Map.merge(attrs, target_attrs)

  defp cancellation_attrs(attrs, :now, _target_attrs),
    do: Map.put(attrs, :canceled_reason, "user_request")

  defp classify_renewal_attempt_for_cancellation(nil, _payment_status, _requested_mode),
    do: {:ok, []}

  defp classify_renewal_attempt_for_cancellation(attempt, :applied, :now) do
    mark_attempt_succeeded_for_cancellation(attempt)
  end

  defp classify_renewal_attempt_for_cancellation(_attempt, :applied, :period_end), do: {:ok, []}

  defp classify_renewal_attempt_for_cancellation(_attempt, :unapplied, :period_end),
    do: {:ok, []}

  defp classify_renewal_attempt_for_cancellation(attempt, :unapplied, _requested_mode) do
    mark_attempt_authority_withdrawn(attempt)
  end

  defp release_withdrawn_renewal_inventory(_attempt, :unapplied, :period_end),
    do: {:ok, %{reservations: [], collection_variant_ids: []}}

  defp release_withdrawn_renewal_inventory(
         %RenewalAttempt{
           id: renewal_attempt_id,
           order_id: order_id,
           status: status,
           failure_code: failure_code
         },
         :unapplied,
         :now
       )
       when is_binary(order_id) and not (status == :failed and failure_code == "PAYMENT_FAILED") do
    with {:ok, %{reservations: reservations}} <-
           Orders.release_reservations_for_order(order_id,
             context: %{system?: true},
             invalidate?: false
           ),
         {:ok, collection_settlement} <-
           RenewalCollectionAttempts.release_withdrawn_collection_reservation_for_cancellation(
             %CancellationReservationInput{renewal_attempt_id: renewal_attempt_id}
           ) do
      {:ok,
       %{
         reservations: reservations,
         collection_variant_ids:
           Map.get(collection_settlement, :inventory_variant_ids_to_invalidate, [])
       }}
    else
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp release_withdrawn_renewal_inventory(_attempt, _payment_application_status, _mode),
    do: {:ok, %{reservations: [], collection_variant_ids: []}}

  defp mark_attempt_authority_withdrawn(%RenewalAttempt{
         status: :failed,
         failure_code: "PAYMENT_FAILED"
       }),
       do: {:ok, []}

  defp mark_attempt_authority_withdrawn(%RenewalAttempt{} = attempt) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_authority_withdrawn,
      %{failure_message: "cancellation withdrew this unresolved renewal occurrence"},
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> normalize_attempt_update_with_notifications()
  end

  defp mark_attempt_succeeded_for_cancellation(%RenewalAttempt{status: :succeeded}),
    do: {:ok, []}

  defp mark_attempt_succeeded_for_cancellation(%RenewalAttempt{} = attempt) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_succeeded,
      %{order_id: attempt.order_id, payment_intent_id: attempt.payment_intent_id},
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> normalize_attempt_update_with_notifications()
  end

  defp normalize_attempt_update_with_notifications({:ok, _attempt, notifications})
       when is_list(notifications),
       do: {:ok, notifications}

  defp normalize_attempt_update_with_notifications({:ok, _attempt}), do: {:ok, []}

  defp normalize_attempt_update_with_notifications({:error, reason}),
    do: {:error, Normalize.normalize(reason)}

  defp run_rescind_cancellation(%Subscription{} = subscription, actor) do
    with true <- subscription.cancel_at_period_end,
         true <- subscription.status in [:active, :past_due],
         :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, revision} <- fetch_plan_revision(subscription.current_plan_revision_id),
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         {:ok, effective_at} <- contract_change_effective_at(subscription) do
      target = %{
        instruction_kind: :renew_unchanged,
        target_plan_revision_id: revision.id,
        target_variant_id: subscription.variant_id,
        target_quantity: subscription.quantity,
        target_amount_minor: subscription.renewal_amount_minor,
        target_currency: subscription.renewal_currency,
        effective_at: effective_at
      }

      projection =
        contract_change_projection(
          subscription,
          target,
          subscription.subscription_plan_id
        )

      persist_contract_change(
        subscription,
        target,
        projection,
        actor,
        :rescind_cancel_at_period_end_transition
      )
    else
      false ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "only a current scheduled cancellation can be rescinded"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_rescind_cancellation_with_authorized_reload(%Subscription{} = subscription, actor) do
    case run_rescind_cancellation(subscription, actor) do
      {:error,
       %Error{
         code: "STALE_RECORD",
         message:
           "subscription changed while the command was in progress; reload and re-evaluate it"
       }} ->
        case get_subscription_for_user(actor, subscription.id) do
          {:ok, %Subscription{} = fresh_subscription} ->
            run_rescind_cancellation(fresh_subscription, actor)

          {:ok, nil} ->
            {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      result ->
        result
    end
  end

  defp renewal_period(
         %Subscription{current_period_end_at: %DateTime{} = period_start},
         %PlanRevision{} = revision,
         _now
       ) do
    {:ok, Scheduler.next_period(period_start, revision)}
  end

  defp renewal_period(%Subscription{}, %PlanRevision{}, _now) do
    {:error, Error.new("VALIDATION_ERROR", "subscription renewal boundary is missing")}
  end

  defp renewal_period_from_attempt(%RenewalAttempt{
         period_start_at: %DateTime{} = period_start,
         period_end_at: %DateTime{} = period_end
       }) do
    %{
      current_period_start_at: period_start,
      current_period_end_at: period_end,
      next_renewal_at: period_end
    }
  end

  defp bind_renewal_attempt(
         %Subscription{} = expected_subscription,
         renewal_key,
         live_revision
       ) do
    transaction_result =
      Repo.transaction(fn ->
        bind_locked_renewal_attempt(expected_subscription, renewal_key, live_revision)
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, binding, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(notifications,
            context: %{
              flow: :bind_renewal_attempt,
              subscription_id: expected_subscription.id,
              renewal_key: renewal_key
            }
          )

        {:ok, binding}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp bind_locked_renewal_attempt(expected_subscription, renewal_key, live_revision) do
    with {:ok, subscription} <-
           fetch_subscription_for_renewal_locked(expected_subscription.id),
         {:ok, existing_attempt} <- fetch_renewal_attempt_by_key(subscription.id, renewal_key) do
      case existing_attempt do
        %RenewalAttempt{} = attempt ->
          reuse_bound_renewal_attempt(attempt, subscription)

        nil ->
          bind_if_subscription_version_matches(
            expected_subscription,
            subscription,
            renewal_key,
            live_revision
          )
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp bind_if_subscription_version_matches(
         expected_subscription,
         subscription,
         renewal_key,
         live_revision
       ) do
    case ensure_expected_subscription_version(expected_subscription, subscription) do
      :ok ->
        bind_locked_new_renewal_attempt(
          subscription,
          expected_subscription.aggregate_version,
          renewal_key,
          live_revision
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp bind_locked_new_renewal_attempt(subscription, expected_version, renewal_key, live_revision) do
    with :ok <- ensure_subscription_contract_resolved(subscription),
         {:ok, target} <- current_contract_change(subscription),
         :ok <- ensure_live_contract_has_no_projection(subscription, target),
         {:ok, selection} <- renewal_binding_selection(subscription, target, live_revision),
         {:ok, plan} <- fetch_plan(selection.revision.subscription_plan_id),
         {:ok, period} <- renewal_period(subscription, selection.revision, nil),
         snapshot <- charged_contract_snapshot(selection.revision, plan),
         attrs <-
           renewal_attempt_binding_attrs(
             subscription,
             expected_version,
             selection,
             period,
             snapshot,
             renewal_key
           ),
         {:ok, attempt, attempt_notifications} <- create_bound_renewal_attempt(attrs),
         :ok <- ensure_complete_bound_renewal_attempt(attempt),
         {:ok, consumed_subscription, consume_notifications} <-
           consume_contract_change_for_renewal(subscription, target) do
      {:ok,
       %{
         subscription: consumed_subscription,
         attempt: attempt,
         notifications: attempt_notifications ++ consume_notifications
       }}
    else
      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp reuse_bound_renewal_attempt(
         %RenewalAttempt{} = attempt,
         %Subscription{} = subscription
       ) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt),
         true <- attempt.subscription_id == subscription.id do
      {:ok, %{subscription: subscription, attempt: attempt, notifications: []}}
    else
      false ->
        Repo.rollback(Error.new("STALE_RECORD", "renewal attempt subscription identity changed"))

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp renewal_binding_selection(
         %Subscription{} = subscription,
         nil,
         %PlanRevision{id: revision_id} = reusable_revision
       )
       when revision_id == subscription.current_plan_revision_id do
    with false <- legacy_future_projection?(subscription),
         revision = reusable_revision,
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         :ok <- ensure_revision_has_purchase_history(revision),
         :ok <-
           validate_renewal_contract_values(
             subscription.quantity,
             subscription.renewal_amount_minor,
             subscription.renewal_currency
           ) do
      {:ok,
       %{
         plan_revision_id: revision.id,
         revision: revision,
         variant_id: subscription.variant_id,
         quantity: subscription.quantity,
         amount_minor: subscription.renewal_amount_minor,
         currency: subscription.renewal_currency,
         contract_change_id: nil,
         contract_change: nil
       }}
    else
      true -> {:error, inconsistent_current_contract_change_error()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renewal_binding_selection(%Subscription{} = subscription, nil, _reusable_revision) do
    with false <- legacy_future_projection?(subscription),
         {:ok, %PlanRevision{} = revision} <-
           fetch_plan_revision(subscription.current_plan_revision_id),
         :ok <- ensure_revision_belongs_to_plan(revision, subscription.subscription_plan_id),
         :ok <- ensure_revision_has_purchase_history(revision),
         :ok <-
           validate_renewal_contract_values(
             subscription.quantity,
             subscription.renewal_amount_minor,
             subscription.renewal_currency
           ) do
      {:ok,
       %{
         plan_revision_id: revision.id,
         revision: revision,
         variant_id: subscription.variant_id,
         quantity: subscription.quantity,
         amount_minor: subscription.renewal_amount_minor,
         currency: subscription.renewal_currency,
         contract_change_id: nil,
         contract_change: nil
       }}
    else
      true -> {:error, inconsistent_current_contract_change_error()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renewal_binding_selection(
         %Subscription{} = subscription,
         %ContractChange{} = target,
         _reusable_revision
       ) do
    with :ok <- ensure_current_target_boundary(subscription, target),
         {:ok, %PlanRevision{} = revision} <- fetch_plan_revision(target.target_plan_revision_id),
         :ok <- ensure_revision_has_purchase_history(revision),
         :ok <- ensure_contract_change_price_matches(target, revision),
         :ok <-
           validate_renewal_contract_values(
             target.target_quantity,
             target.target_amount_minor,
             target.target_currency
           ) do
      {:ok,
       %{
         plan_revision_id: revision.id,
         revision: revision,
         variant_id: target.target_variant_id,
         quantity: target.target_quantity,
         amount_minor: target.target_amount_minor,
         currency: target.target_currency,
         contract_change_id: target.id,
         contract_change: target
       }}
    end
  end

  defp ensure_current_target_boundary(
         %Subscription{current_period_end_at: boundary},
         %ContractChange{effective_at: effective_at}
       ) do
    if effective_at == boundary do
      :ok
    else
      {:error, inconsistent_current_contract_change_error()}
    end
  end

  defp ensure_contract_change_price_matches(
         %ContractChange{} = target,
         %PlanRevision{} = revision
       ) do
    if target.target_amount_minor == revision.amount_minor and
         target.target_currency == revision.currency do
      :ok
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "ContractChange price evidence does not match its PlanRevision"
       )}
    end
  end

  defp ensure_live_contract_has_no_projection(%Subscription{} = subscription, nil) do
    if legacy_future_projection?(subscription),
      do: {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)},
      else: :ok
  end

  defp ensure_live_contract_has_no_projection(%Subscription{}, %ContractChange{}), do: :ok

  defp validate_renewal_contract_values(quantity, amount_minor, currency) do
    if is_integer(quantity) and quantity > 0 and is_integer(amount_minor) and amount_minor >= 0 and
         is_binary(currency) and Regex.match?(~r/^[A-Z]{3}$/, currency) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "renewal contract evidence is invalid")}
    end
  end

  defp renewal_attempt_binding_attrs(
         %Subscription{} = subscription,
         expected_version,
         selection,
         period,
         snapshot,
         renewal_key
       ) do
    %{
      subscription_id: subscription.id,
      period_start_at: period.current_period_start_at,
      period_end_at: period.current_period_end_at,
      renewal_key: renewal_key,
      plan_revision_id: selection.plan_revision_id,
      variant_id: selection.variant_id,
      quantity: selection.quantity,
      amount_minor: selection.amount_minor,
      currency: selection.currency,
      contract_change_id: selection.contract_change_id,
      expected_subscription_version: expected_version,
      charged_contract_version: 1,
      charged_contract_snapshot: snapshot,
      status: :pending
    }
  end

  defp charged_contract_snapshot(%PlanRevision{} = revision, %SubscriptionPlan{} = plan) do
    %{
      "version" => 1,
      "subscription_plan_key" => plan.key,
      "interval_unit" => Atom.to_string(revision.interval_unit),
      "interval_count" => revision.interval_count,
      "trial_days" => revision.trial_days,
      "anchor_mode" => Atom.to_string(revision.anchor_mode),
      "anchor_day_of_month" => revision.anchor_day_of_month,
      "billing_timezone" => revision.billing_timezone,
      "term_mode" => Atom.to_string(revision.term_mode),
      "term_cycles" => revision.term_cycles,
      "term_end_at" => datetime_snapshot(revision.term_end_at),
      "access_on_past_due" => Atom.to_string(revision.access_on_past_due),
      "access_on_cancel" => Atom.to_string(revision.access_on_cancel),
      "grace_period_days" => revision.grace_period_days,
      "max_retry_attempts" => revision.max_retry_attempts,
      "retry_schedule_hours" => revision.retry_schedule_hours,
      "entitlement_kind" => enum_snapshot(revision.entitlement_kind),
      "entitlement_scope_key" => revision.entitlement_scope_key
    }
  end

  defp datetime_snapshot(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_snapshot(_value), do: nil

  defp enum_snapshot(nil), do: nil
  defp enum_snapshot(value) when is_atom(value), do: Atom.to_string(value)

  defp renewal_policy_from_attempt(%RenewalAttempt{charged_contract_snapshot: snapshot})
       when is_map(snapshot) do
    %{
      interval_unit: snapshot_enum(snapshot, "interval_unit"),
      interval_count: Map.get(snapshot, "interval_count"),
      anchor_mode: snapshot_enum(snapshot, "anchor_mode"),
      anchor_day_of_month: Map.get(snapshot, "anchor_day_of_month"),
      billing_timezone: Map.get(snapshot, "billing_timezone"),
      term_mode: snapshot_enum(snapshot, "term_mode"),
      term_cycles: Map.get(snapshot, "term_cycles"),
      term_end_at: Map.get(snapshot, "term_end_at"),
      access_on_past_due: snapshot_enum(snapshot, "access_on_past_due"),
      access_on_cancel: snapshot_enum(snapshot, "access_on_cancel"),
      grace_period_days: Map.get(snapshot, "grace_period_days"),
      max_retry_attempts: Map.get(snapshot, "max_retry_attempts"),
      retry_schedule_hours: Map.get(snapshot, "retry_schedule_hours"),
      entitlement_kind: snapshot_enum(snapshot, "entitlement_kind"),
      entitlement_scope_key: Map.get(snapshot, "entitlement_scope_key")
    }
  end

  defp snapshot_enum(snapshot, key) do
    values = %{
      "interval_unit" => %{"day" => :day, "month" => :month, "year" => :year},
      "anchor_mode" => %{
        "start_anniversary" => :start_anniversary,
        "fixed_day_of_month" => :fixed_day_of_month
      },
      "term_mode" => %{
        "until_canceled" => :until_canceled,
        "fixed_cycles" => :fixed_cycles,
        "fixed_end_at" => :fixed_end_at
      },
      "access_on_past_due" => %{
        "keep_during_grace" => :keep_during_grace,
        "remove_immediately" => :remove_immediately
      },
      "access_on_cancel" => %{
        "keep_until_period_end" => :keep_until_period_end,
        "remove_immediately" => :remove_immediately
      },
      "entitlement_kind" => %{
        "membership_access" => :membership_access,
        "digital_library" => :digital_library,
        "discount_tier" => :discount_tier
      }
    }

    snapshot
    |> Map.get(key)
    |> then(&Map.get(Map.get(values, key, %{}), &1))
  end

  defp ensure_complete_bound_renewal_attempt(
         %RenewalAttempt{
           charged_contract_version: 1,
           plan_revision_id: plan_revision_id,
           variant_id: variant_id,
           quantity: quantity,
           amount_minor: amount_minor,
           currency: currency,
           expected_subscription_version: expected_version,
           charged_contract_snapshot: snapshot
         } = attempt
       ) do
    binding = %{
      plan_revision_id: plan_revision_id,
      variant_id: variant_id,
      quantity: quantity,
      amount_minor: amount_minor,
      currency: currency,
      expected_subscription_version: expected_version,
      snapshot: snapshot
    }

    if valid_bound_attempt_fields?(binding) and valid_attempt_period?(attempt) do
      :ok
    else
      {:error,
       Error.new("VALIDATION_ERROR", "renewal attempt charged-contract binding is incomplete")}
    end
  end

  defp ensure_complete_bound_renewal_attempt(%RenewalAttempt{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "renewal attempt has no durable charged-contract binding"
     )}
  end

  defp valid_bound_attempt_fields?(binding) do
    valid_bound_identity?(binding) and valid_bound_price?(binding) and
      valid_bound_version?(binding) and charged_contract_snapshot_valid?(binding.snapshot)
  end

  defp valid_bound_identity?(%{plan_revision_id: revision_id, variant_id: variant_id}),
    do: is_binary(revision_id) and is_binary(variant_id)

  defp valid_bound_price?(%{quantity: quantity, amount_minor: amount, currency: currency}) do
    is_integer(quantity) and quantity > 0 and is_integer(amount) and amount >= 0 and
      canonical_currency?(currency)
  end

  defp valid_bound_version?(%{expected_subscription_version: version}),
    do: is_integer(version) and version > 0

  defp valid_attempt_period?(%RenewalAttempt{period_start_at: start_at, period_end_at: end_at}),
    do: match?(%DateTime{}, start_at) and match?(%DateTime{}, end_at)

  defp canonical_currency?(currency) when is_binary(currency),
    do: Regex.match?(~r/^[A-Z]{3}$/, currency)

  defp canonical_currency?(_currency), do: false

  defp charged_contract_snapshot_valid?(snapshot) do
    snapshot_keys_present?(snapshot) and snapshot_identity_valid?(snapshot) and
      snapshot_period_valid?(snapshot) and snapshot_term_valid?(snapshot) and
      snapshot_access_valid?(snapshot) and snapshot_retry_valid?(snapshot) and
      snapshot_entitlement_valid?(snapshot)
  end

  defp snapshot_keys_present?(snapshot) do
    keys = [
      "version",
      "subscription_plan_key",
      "interval_unit",
      "interval_count",
      "trial_days",
      "anchor_mode",
      "anchor_day_of_month",
      "billing_timezone",
      "term_mode",
      "term_cycles",
      "term_end_at",
      "access_on_past_due",
      "access_on_cancel",
      "grace_period_days",
      "max_retry_attempts",
      "retry_schedule_hours",
      "entitlement_kind",
      "entitlement_scope_key"
    ]

    is_map(snapshot) and Enum.all?(keys, &Map.has_key?(snapshot, &1))
  end

  defp snapshot_identity_valid?(snapshot) do
    Map.get(snapshot, "version") == 1 and
      is_binary(Map.get(snapshot, "subscription_plan_key"))
  end

  defp snapshot_period_valid?(snapshot) do
    unit_valid? = Map.get(snapshot, "interval_unit") in ["day", "month", "year"]
    interval_count = Map.get(snapshot, "interval_count")
    count_valid? = is_integer(interval_count) and interval_count > 0

    anchor_valid? =
      Map.get(snapshot, "anchor_mode") in ["start_anniversary", "fixed_day_of_month"]

    timezone_valid? = is_binary(Map.get(snapshot, "billing_timezone"))
    trial_valid? = optional_non_negative_integer?(Map.get(snapshot, "trial_days"))
    anchor_day_valid? = optional_integer_in?(Map.get(snapshot, "anchor_day_of_month"), 1..31)

    unit_valid? and count_valid? and anchor_valid? and timezone_valid? and trial_valid? and
      anchor_day_valid?
  end

  defp snapshot_term_valid?(snapshot) do
    mode = Map.get(snapshot, "term_mode")

    valid_term_mode?(mode) and
      valid_term_cycles?(mode, Map.get(snapshot, "term_cycles")) and
      valid_term_end?(mode, Map.get(snapshot, "term_end_at"))
  end

  defp valid_term_mode?(mode),
    do: mode in ["until_canceled", "fixed_cycles", "fixed_end_at"]

  defp valid_term_cycles?(mode, cycles) do
    optional_cycles_valid? = is_nil(cycles) or (is_integer(cycles) and cycles > 0)
    required_cycles_valid? = mode != "fixed_cycles" or is_integer(cycles)

    optional_cycles_valid? and required_cycles_valid?
  end

  defp valid_term_end?(mode, end_at) do
    optional_end_valid? = is_nil(end_at) or is_binary(end_at)
    required_end_valid? = mode != "fixed_end_at" or is_binary(end_at)

    optional_end_valid? and required_end_valid?
  end

  defp snapshot_access_valid?(snapshot) do
    Map.get(snapshot, "access_on_past_due") in ["keep_during_grace", "remove_immediately"] and
      Map.get(snapshot, "access_on_cancel") in ["keep_until_period_end", "remove_immediately"] and
      non_negative_integer?(Map.get(snapshot, "grace_period_days"))
  end

  defp snapshot_retry_valid?(snapshot) do
    non_negative_integer?(Map.get(snapshot, "max_retry_attempts")) and
      is_list(Map.get(snapshot, "retry_schedule_hours")) and
      Enum.all?(Map.get(snapshot, "retry_schedule_hours"), &non_negative_integer?/1)
  end

  defp snapshot_entitlement_valid?(snapshot) do
    kind = Map.get(snapshot, "entitlement_kind")
    scope = Map.get(snapshot, "entitlement_scope_key")

    kind_valid? =
      is_nil(kind) or kind in ["membership_access", "digital_library", "discount_tier"]

    scope_valid? = is_nil(scope) or is_binary(scope)

    kind_valid? and scope_valid? and (is_nil(kind) or is_binary(scope))
  end

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)

  defp optional_integer_in?(nil, _range), do: true

  defp optional_integer_in?(value, range),
    do: is_integer(value) and value in range

  defp non_negative_integer?(value),
    do: is_integer(value) and value >= 0

  defp fetch_renewal_attempt_by_key(subscription_id, renewal_key) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(
        expr(subscription_id == ^subscription_id and renewal_key == ^renewal_key)
      )

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %RenewalAttempt{} = attempt} -> {:ok, attempt}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp create_bound_renewal_attempt(attrs) do
    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> unwrap_create_with_notifications()
    |> case do
      {:ok, %RenewalAttempt{} = attempt, notifications} -> {:ok, attempt, notifications}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp consume_contract_change_for_renewal(
         %Subscription{} = subscription,
         %ContractChange{id: contract_change_id} = target
       ) do
    with true <- subscription.current_contract_change_id == contract_change_id,
         {:ok, _bound_change, change_notifications} <- bind_contract_change_to_renewal(target),
         {:ok, updated_subscription, subscription_notifications} <-
           update_subscription_after_renewal_target_consumption(subscription) do
      {:ok, updated_subscription, change_notifications ++ subscription_notifications}
    else
      false -> {:error, inconsistent_current_contract_change_error()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_contract_change_for_renewal(%Subscription{} = subscription, nil),
    do: {:ok, subscription, []}

  defp bind_contract_change_to_renewal(%ContractChange{} = target) do
    target
    |> Ash.Changeset.for_update(:bind_to_renewal, %{}, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %ContractChange{} = bound, notifications} -> {:ok, bound, notifications}
      {:ok, %ContractChange{} = bound} -> {:ok, bound, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp update_subscription_after_renewal_target_consumption(subscription) do
    attrs = %{
      current_contract_change_id: nil,
      pending_variant_id: nil,
      pending_subscription_plan_id: nil,
      pending_renewal_amount_minor: nil,
      pending_renewal_currency: nil,
      change_effective_at: nil
    }

    subscription
    |> Ash.Changeset.for_update(:consume_contract_change_for_renewal, attrs,
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %Subscription{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %Subscription{} = updated} -> {:ok, updated, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp claim_renewal_attempt(%RenewalAttempt{
         id: attempt_id,
         updated_at: updated_at,
         status: status
       })
       when is_binary(attempt_id) and status in [:pending, :failed] do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    with {:ok, attempt_uuid} <- Ecto.UUID.dump(attempt_id),
         {:ok, previous_updated_at} <- to_naive_datetime(updated_at) do
      case Repo.query(
             "UPDATE renewal_attempts SET updated_at = $2 WHERE id = $1 AND status IN ('pending', 'failed') AND failure_code IS DISTINCT FROM 'RENEWAL_AUTHORITY_WITHDRAWN' AND updated_at = $3",
             [attempt_uuid, now, previous_updated_at]
           ) do
        {:ok, %{num_rows: 1}} ->
          :ok

        {:ok, _result} ->
          {:skip, :already_claimed}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    else
      :error ->
        {:error, Error.new("VALIDATION_ERROR", "renewal attempt id must be a UUID")}

      {:error, _reason} ->
        {:error, Error.new("VALIDATION_ERROR", "renewal attempt updated_at is required")}
    end
  end

  defp claim_renewal_attempt(
         %RenewalAttempt{
           id: attempt_id,
           updated_at: updated_at,
           status: :processing,
           order_id: order_id
         } = attempt
       )
       when is_binary(attempt_id) and is_binary(order_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    with {:ok, attempt_uuid} <- Ecto.UUID.dump(attempt_id),
         {:ok, previous_updated_at} <- to_naive_datetime(updated_at) do
      case Repo.query(
             "UPDATE renewal_attempts SET updated_at = $2 WHERE id = $1 AND status = 'processing' AND order_id = $4 AND updated_at = $3",
             [
               attempt_uuid,
               now,
               previous_updated_at,
               Ecto.UUID.dump!(order_id)
             ]
           ) do
        {:ok, %{num_rows: 1}} ->
          {:resume_existing, attempt}

        {:ok, _result} ->
          {:skip, :already_claimed}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    else
      :error ->
        {:error, Error.new("VALIDATION_ERROR", "renewal attempt id must be a UUID")}

      {:error, _reason} ->
        {:error, Error.new("VALIDATION_ERROR", "renewal attempt updated_at is required")}
    end
  end

  defp claim_renewal_attempt(%RenewalAttempt{}), do: {:skip, :already_claimed}

  defp to_naive_datetime(%DateTime{} = value), do: {:ok, DateTime.to_naive(value)}
  defp to_naive_datetime(%NaiveDateTime{} = value), do: {:ok, value}
  defp to_naive_datetime(_value), do: {:error, :invalid_datetime}

  defp settle_renewal_failure(
         subscription,
         attempt,
         collection_attempt,
         retry_policy,
         reason,
         now
       ) do
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, locked_subscription} <-
               fetch_subscription_for_renewal_locked(subscription.id),
             {:ok, locked_attempt} <-
               fetch_renewal_attempt_for_failure_settlement(attempt.id, subscription.id),
             {:ok, settlement} <-
               settle_locked_renewal_failure(
                 locked_subscription,
                 locked_attempt,
                 collection_attempt,
                 retry_policy,
                 reason,
                 now
               ) do
          {:ok, settlement}
        else
          {:error, settlement_error} -> Repo.rollback(settlement_error)
        end
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, settlement, notifications} ->
        {:ok, Map.put(settlement, :notifications, notifications)}

      {:error, settlement_error} ->
        {:error, settlement_error}
    end
  end

  defp settle_locked_renewal_failure(
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         collection_attempt,
         retry_policy,
         reason,
         now
       ) do
    with :ok <-
           RenewalCollectionAttempts.ensure_current_dunning_attempt_owner(subscription, attempt),
         :ok <- ensure_locked_dunning_attempt_identity(subscription, attempt),
         do:
           settle_locked_renewal_failure_with_identity(
             subscription,
             attempt,
             collection_attempt,
             retry_policy,
             reason,
             now
           )
  end

  defp settle_locked_renewal_failure_with_identity(
         subscription,
         attempt,
         collection_attempt,
         retry_policy,
         reason,
         now
       ) do
    cond do
      attempt.status == :succeeded ->
        {:ok, %{outcome: :success_already_terminal}}

      attempt.failure_code == @renewal_authority_withdrawn_code ->
        {:ok, %{outcome: :terminal_noop}}

      subscription.status in [:canceled, :expired, :pending] ->
        {:ok, %{outcome: :terminal_noop}}

      true ->
        settle_failure_after_paid_handoff(
          subscription,
          attempt,
          collection_attempt,
          retry_policy,
          reason,
          now
        )
    end
  end

  defp settle_failure_after_paid_handoff(
         subscription,
         attempt,
         collection_attempt,
         retry_policy,
         reason,
         now
       ) do
    case exact_paid_renewal_success_handoff(attempt) do
      {:ok, %{} = handoff} ->
        {:ok, %{outcome: :success_won, handoff: handoff}}

      {:ok, nil} ->
        persist_failure_and_dunning(
          subscription,
          attempt,
          collection_attempt,
          retry_policy,
          reason,
          now
        )

      {:error, authority_error} ->
        {:error, authority_error}
    end
  end

  defp ensure_locked_dunning_attempt_identity(
         %Subscription{status: :active} = subscription,
         %RenewalAttempt{} = attempt
       ) do
    ensure_bound_dunning_attempt_identity(subscription, attempt)
  end

  defp ensure_locked_dunning_attempt_identity(
         %Subscription{
           status: :past_due,
           current_dunning_renewal_attempt_id: nil
         },
         %RenewalAttempt{}
       ) do
    :ok
  end

  defp ensure_locked_dunning_attempt_identity(
         %Subscription{
           status: status,
           current_dunning_renewal_attempt_id: attempt_id
         } = subscription,
         %RenewalAttempt{id: attempt_id} = attempt
       )
       when status in [:past_due, :suspended] and not is_nil(attempt_id),
       do: ensure_bound_dunning_attempt_identity(subscription, attempt)

  defp ensure_locked_dunning_attempt_identity(
         %Subscription{status: :suspended},
         %RenewalAttempt{}
       ),
       do: :ok

  defp ensure_locked_dunning_attempt_identity(%Subscription{}, %RenewalAttempt{}), do: :ok

  defp ensure_bound_dunning_attempt_identity(subscription, attempt) do
    with true <- same_bound_renewal_occurrence?(subscription, attempt),
         :ok <- ensure_complete_bound_renewal_attempt(attempt) do
      :ok
    else
      false ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "RenewalAttempt does not match the locked Subscription period"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_failure_and_dunning(
         subscription,
         attempt,
         _collection_attempt,
         _retry_policy,
         reason,
         _now
       )
       when subscription.status == :suspended do
    with {:ok, _updated_attempt, attempt_notifications} <-
           mark_attempt_failed_in_transaction(attempt, reason) do
      {:ok,
       %{
         outcome: :failure_recorded,
         subscription: subscription,
         dunning_status: :suspended,
         dunning_count: subscription.dunning_attempt_count || 0,
         notifications: attempt_notifications
       }}
    end
  end

  defp persist_failure_and_dunning(
         %Subscription{status: status} = subscription,
         attempt,
         _collection_attempt,
         retry_policy,
         reason,
         now
       )
       when status in [:active, :past_due] do
    with {:ok, _updated_attempt, attempt_notifications} <-
           mark_attempt_failed_in_transaction(attempt, reason),
         {:ok, updated_subscription, dunning_notifications, dunning_count} <-
           mark_subscription_past_due_in_transaction(
             subscription,
             attempt,
             retry_policy,
             reason,
             now
           ),
         {:ok, past_due_access_effect} <-
           maybe_establish_first_transition_past_due_policy_effect(
             subscription,
             updated_subscription,
             attempt
           )
           |> map_keep_grace_establishment_failure() do
      {:ok,
       %{
         outcome: :failure_recorded,
         subscription: updated_subscription,
         dunning_status: :past_due,
         dunning_count: dunning_count,
         past_due_access_effect: past_due_access_effect,
         notifications: attempt_notifications ++ dunning_notifications
       }}
    end
  end

  defp persist_failure_and_dunning(_subscription, _attempt, _collection, _policy, _reason, _now) do
    {:error,
     Error.new("STALE_RECORD", "subscription lifecycle changed during failure settlement")}
  end

  defp mark_attempt_failed_in_transaction(%RenewalAttempt{} = attempt, reason) do
    {failure_code, failure_message} =
      case reason do
        %Error{code: code, message: message} ->
          {code, message}

        other ->
          {"INTERNAL_ERROR", inspect(other)}
      end

    attempt_no = max((attempt.attempt_no || 1) + 1, 1)

    attrs = %{
      failure_code: failure_code,
      failure_message: failure_message,
      attempt_no: attempt_no
    }

    attempt
    |> Ash.Changeset.for_update(:mark_failed, attrs, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %RenewalAttempt{} = updated, notifications} when is_list(notifications) ->
        {:ok, updated, notifications}

      {:ok, %RenewalAttempt{} = updated} ->
        {:ok, updated, []}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp mark_subscription_past_due_in_transaction(subscription, attempt, retry_policy, reason, now) do
    message =
      case reason do
        %Error{code: code} -> code
        other -> inspect(other)
      end

    with {:ok, max_retry_attempts} <- retry_policy_max_attempts(retry_policy) do
      next_attempt_count = max((subscription.dunning_attempt_count || 0) + 1, 1)
      past_due_since_at = dunning_anchor(subscription, now)

      failed_payment_boundary_at =
        failed_payment_boundary_for_first_failure(
          subscription,
          retry_policy,
          past_due_since_at
        )

      attrs =
        retry_failure_attrs(
          retry_policy,
          message,
          now,
          past_due_since_at,
          next_attempt_count,
          max_retry_attempts,
          failed_payment_boundary_at
        )

      private_arguments = dunning_transition_private_arguments(subscription, attempt)

      changeset =
        subscription
        |> Ash.Changeset.for_update(:mark_past_due_transition, attrs,
          context: %{system?: true},
          private_arguments: private_arguments
        )

      changeset
      |> Ash.update(
        domain: Subscriptions,
        authorize?: false,
        context: %{system?: true},
        return_notifications?: true
      )
      |> case do
        {:ok, %Subscription{} = updated, notifications} when is_list(notifications) ->
          {:ok, updated, notifications, next_attempt_count}

        {:ok, %Subscription{} = updated} ->
          {:ok, updated, [], next_attempt_count}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    end
  end

  defp dunning_transition_private_arguments(
         %Subscription{status: :active},
         %RenewalAttempt{id: attempt_id}
       ),
       do: %{dunning_renewal_attempt_id: attempt_id}

  defp dunning_transition_private_arguments(
         %Subscription{
           status: :past_due,
           current_dunning_renewal_attempt_id: attempt_id
         },
         %RenewalAttempt{id: attempt_id}
       )
       when not is_nil(attempt_id),
       do: %{dunning_renewal_attempt_id: attempt_id}

  defp dunning_transition_private_arguments(%Subscription{}, %RenewalAttempt{}), do: %{}

  defp fetch_renewal_attempt_for_failure_settlement(attempt_id, subscription_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(id == ^attempt_id and subscription_id == ^subscription_id))
      |> Ash.Query.lock("FOR UPDATE")

    case Ash.read_one(query,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %RenewalAttempt{} = attempt} ->
        {:ok, attempt}

      {:ok, nil} ->
        {:error, Error.new("STALE_RECORD", "renewal attempt changed during failure settlement")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp exact_paid_renewal_success_handoff(%RenewalAttempt{order_id: order_id} = attempt)
       when is_binary(order_id) do
    query =
      RenewalCollectionAttempt
      |> Ash.Query.filter(
        expr(
          renewal_attempt_id == ^attempt.id and
            financial_outcome == :verified_success
        )
      )
      |> Ash.Query.limit(2)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [%RenewalCollectionAttempt{} = collection]} ->
        exact_success_handoff_for_collection(attempt, collection)

      {:ok, [_first, _second | _rest]} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "renewal attempt has multiple successful collection records"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp exact_paid_renewal_success_handoff(%RenewalAttempt{}), do: {:ok, nil}

  defp exact_success_handoff_for_collection(attempt, collection) do
    with {:ok, handoff} <- RenewalCollectionAttempts.success_handoff_for_system(collection.id),
         true <-
           handoff.order_id == attempt.order_id and
             handoff.renewal_attempt_id == attempt.id and
             handoff.collection_attempt_id == collection.id and
             handoff.payment_intent_id == collection.payment_intent_id,
         {:ok, :applied} <-
           PaymentsFacade.renewal_payment_application_status_for_system(
             %RenewalPaymentApplicationInput{
               order_id: handoff.order_id,
               payment_intent_id: handoff.payment_intent_id
             }
           ),
         {:ok, %Order{state: :paid}} <- fetch_paid_order(handoff.order_id) do
      {:ok, handoff}
    else
      {:ok, :unapplied} ->
        {:ok, nil}

      false ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal success handoff identity conflicts")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_failure_suppressed_success(handoff) do
    case reconcile_paid_subscription_renewal_for_system(handoff.order_id,
           renewal_attempt_id: handoff.renewal_attempt_id,
           collection_attempt_id: handoff.collection_attempt_id,
           payment_intent_id: handoff.payment_intent_id
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_renewal_failure_settlement(settlement) do
    :ok =
      AshNotifications.notify_post_commit(settlement.notifications,
        context: %{
          flow: :settle_renewal_failure,
          subscription_id: settlement.subscription.id
        }
      )

    emit_subscription_dunning_telemetry(
      settlement.subscription,
      settlement.dunning_status,
      settlement.dunning_count
    )

    :ok = sync_past_due_access_after_commit(settlement)

    :ok
  end

  defp maybe_establish_first_transition_past_due_policy_effect(
         %Subscription{status: :active},
         %Subscription{} = updated_subscription,
         %RenewalAttempt{} = attempt
       ) do
    establish_keep_during_grace_access_effect(updated_subscription, attempt)
  end

  defp maybe_establish_first_transition_past_due_policy_effect(_before, _updated, _attempt),
    do: {:ok, nil}

  defp establish_keep_during_grace_access_effect(%Subscription{} = subscription, attempt) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt) do
      establish_keep_during_grace_access_effect_after_snapshot_proof(subscription, attempt)
    end
  end

  defp establish_keep_during_grace_access_effect_after_snapshot_proof(
         %Subscription{} = subscription,
         attempt
       ) do
    result =
      case renewal_policy_from_attempt(attempt) do
        %{access_on_past_due: :keep_during_grace} ->
          with {:ok, %PlanRevision{} = revision} <-
                 fetch_plan_revision(subscription.current_plan_revision_id) do
            AccessEffectTargetOrder.derive_keep_during_grace_target(
              subscription,
              attempt,
              revision
            )
          end

        %{access_on_past_due: :remove_immediately} ->
          AccessEffectTargetOrder.derive_remove_immediately_target(subscription, attempt)

        _ ->
          {:error,
           Error.new(
             "VALIDATION_ERROR",
             "renewal attempt charged-contract past_due policy is incomplete"
           )}
      end

    with {:ok, target} <- result,
         attrs <- AccessEffectTargetOrder.past_due_policy_establish_attrs(subscription, target),
         {:ok, input} <- EstablishAccessEffectInput.new(attrs),
         {:ok, %AccessEffect{id: effect_id, disposition: disposition}} <-
           establish_access_effect_for_system(input) do
      {:ok, %{id: effect_id, disposition: disposition}}
    else
      {:error, error} ->
        {:error, keep_grace_access_effect_establishment_failed(Normalize.normalize(error))}
    end
  end

  defp sync_past_due_access_after_commit(
         %{past_due_access_effect: %{id: effect_id, disposition: :effective}} = settlement
       )
       when is_binary(effect_id) do
    case sync_charged_renewal_access(
           :ordinary,
           effect_id,
           settlement.subscription,
           nil
         ) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp sync_past_due_access_after_commit(%{
         past_due_access_effect: %{id: effect_id, disposition: :non_effective}
       }) do
    _ = execute_suspension_access_effect_for_system(effect_id)
    :ok
  end

  defp sync_past_due_access_after_commit(_settlement), do: :ok

  defp ensure_renewal_chargeability(subscription, _plan) do
    with :ok <- Providers.ensure_enabled_provider(subscription.provider),
         {:ok, %StoredPaymentMethod{} = stored_payment_method} <-
           fetch_active_stored_payment_method(subscription),
         true <- stored_payment_method.provider == subscription.provider do
      :ok
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_METHOD_REQUIRED",
           "active stored payment method provider does not match subscription provider"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_active_stored_payment_method(%Subscription{stored_payment_method_id: nil}) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription cannot renew without an active stored payment method"
     )}
  end

  defp fetch_active_stored_payment_method(%Subscription{
         stored_payment_method_id: stored_payment_method_id,
         user_id: user_id
       })
       when is_binary(stored_payment_method_id) and is_binary(user_id) do
    query =
      StoredPaymentMethod
      |> Ash.Query.filter(
        expr(id == ^stored_payment_method_id and user_id == ^user_id and status == :active)
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%StoredPaymentMethod{} = stored_payment_method | _]} ->
        {:ok, stored_payment_method}

      {:ok, []} ->
        {:error,
         Error.new(
           "PAYMENT_METHOD_REQUIRED",
           "subscription cannot renew without an active stored payment method"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_active_stored_payment_method(%Subscription{}) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription cannot renew without an active stored payment method"
     )}
  end

  defp effective_renewal_contract(%RenewalAttempt{} = attempt, reusable_revision) do
    with :ok <- ensure_complete_bound_renewal_attempt(attempt),
         {:ok, %PlanRevision{} = revision} <-
           bound_revision_for_attempt(attempt, reusable_revision),
         {:ok, %Variant{} = variant} <- fetch_variant_for_renewal(attempt.variant_id) do
      snapshot = attempt.charged_contract_snapshot
      policy = renewal_policy_from_attempt(attempt)

      plan =
        Map.merge(policy, %{
          id: revision.subscription_plan_id,
          key: Map.get(snapshot, "subscription_plan_key"),
          amount_minor: attempt.amount_minor,
          currency: attempt.currency
        })

      membership_key =
        if policy.entitlement_kind == :membership_access,
          do: policy.entitlement_scope_key,
          else: nil

      {:ok,
       %{
         plan: plan,
         variant: variant,
         variant_id: attempt.variant_id,
         quantity: attempt.quantity,
         amount_minor: attempt.amount_minor,
         currency: attempt.currency,
         membership_key: membership_key,
         physical?: physical_renewal_variant?(variant),
         pending_change?: is_binary(attempt.contract_change_id)
       }}
    end
  end

  defp bound_revision_for_attempt(
         %RenewalAttempt{plan_revision_id: revision_id},
         %PlanRevision{id: revision_id} = revision
       ),
       do: {:ok, revision}

  defp bound_revision_for_attempt(%RenewalAttempt{plan_revision_id: revision_id}, _candidate),
    do: fetch_plan_revision(revision_id)

  defp build_or_reuse_renewal_checkout(
         subscription,
         effective_contract,
         renewal_period,
         attempt,
         now
       ) do
    with {:ok, order} <-
           fetch_or_create_renewal_order(
             subscription,
             effective_contract,
             renewal_period,
             attempt,
             now
           ),
         {:ok, processing_attempt} <- mark_attempt_processing(attempt, order.id, nil),
         {:ok, order} <-
           prepare_renewal_order(
             order,
             subscription,
             effective_contract,
             renewal_period,
             now,
             processing_attempt
           ),
         {:ok, collection_attempt} <-
           RenewalCollectionAttempts.start_and_assign_for_system(%StartInput{
             renewal_attempt_id: processing_attempt.id,
             subscription_id: subscription.id,
             now: now
           }),
         {:ok, provider_request_reference} <-
           Providers.renewal_collection_request_reference(
             subscription.provider,
             collection_attempt.id
           ),
         {:ok, payment_intent_result} <-
           Store.Payments.create_or_reuse_payment_intent(
             %{
               order_id: order.id,
               amount_received_minor: renewal_order_total_minor(order, effective_contract),
               currency: effective_contract.currency,
               provider: subscription.provider,
               payment_intent_key:
                 RenewalCollectionAttempts.payment_intent_key(collection_attempt.id),
               provider_request_reference: provider_request_reference
             },
             context: %{system?: true}
           ),
         payment_intent <- payment_intent_result.payment_intent,
         :ok <-
           emit_renewal_attempt_before_processing(
             subscription,
             processing_attempt,
             order,
             payment_intent
           ) do
      {:ok,
       %{
         order: order,
         payment_intent: payment_intent,
         renewal_attempt: processing_attempt,
         collection_attempt: collection_attempt
       }}
    end
  end

  defp emit_renewal_attempt_before_processing(
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         %Order{} = order,
         %PaymentIntent{} = payment_intent
       ) do
    :telemetry.execute(
      [:store, :subscriptions, :renewal_attempt_before_processing],
      %{attempt_no: attempt.attempt_no},
      %{
        subscription_id: subscription.id,
        renewal_attempt_id: attempt.id,
        order_id: order.id,
        payment_intent_id: payment_intent.id
      }
    )

    :ok
  end

  defp prepare_renewal_order(
         %Order{} = order,
         %Subscription{} = subscription,
         %{physical?: true} = effective_contract,
         _renewal_period,
         _now,
         %RenewalAttempt{}
       ) do
    with {:ok, shipping_profile} <- fetch_subscription_shipping_profile(subscription),
         {:ok, order} <- apply_shipping_profile_to_order(order, shipping_profile),
         {:ok, quote_option} <-
           quote_physical_renewal_shipping(shipping_profile, effective_contract),
         :ok <- ensure_shipping_quote_within_surge_limit(quote_option, shipping_profile) do
      prepare_reserved_physical_renewal_order(order, effective_contract, quote_option)
    end
  end

  defp prepare_renewal_order(
         %Order{} = order,
         %Subscription{} = _subscription,
         effective_contract,
         _renewal_period,
         _now,
         _attempt
       ) do
    case write_virtual_renewal_snapshot(order, effective_contract) do
      {:ok, _snapshot} ->
        finalize_renewal_order(order, effective_contract, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_reserved_physical_renewal_order(
         %Order{} = order,
         effective_contract,
         %QuoteOption{} = quote_option
       ) do
    quote_evidence = QuoteEvidence.from_quote_option(quote_option)

    with {:ok, _snapshot} <- write_virtual_renewal_snapshot(order, effective_contract),
         {:ok, order} <- persist_renewal_quote_evidence(order, quote_evidence),
         {:ok, quote_output} <-
           evaluate_physical_renewal_quote_output(order, effective_contract, quote_option),
         {:ok, _shipping_snapshot} <- Orders.write_tax_shipping_snapshot(order.id, quote_output) do
      finalize_renewal_order(order, effective_contract, quote_output)
    end
  end

  defp persist_renewal_quote_evidence(%Order{} = order, %QuoteEvidence{} = quote_evidence) do
    order
    |> Ash.Changeset.for_update(
      :set_shipping_quote_evidence,
      %{
        shipping_quote_hash: quote_evidence.quote_hash,
        shipping_quote_currency_code: quote_evidence.currency_code,
        shipping_quote_amount_minor: quote_evidence.amount_minor,
        shipping_weight_grams: quote_evidence.shipping_weight_grams,
        shipping_method_code: quote_evidence.shipping_method_code,
        shipping_rule_id: quote_evidence.shipping_rule_id,
        shipping_zone_id: quote_evidence.zone_id,
        shipping_effective_from: quote_evidence.effective_from,
        shipping_effective_to: quote_evidence.effective_to
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_or_create_renewal_order(
         _subscription,
         _effective_contract,
         _renewal_period,
         %RenewalAttempt{order_id: order_id},
         _now
       )
       when is_binary(order_id) do
    fetch_order_for_system(order_id)
  end

  defp fetch_or_create_renewal_order(
         subscription,
         effective_contract,
         renewal_period,
         _attempt,
         _now
       ) do
    begin_attrs = %{
      user_id: subscription.user_id,
      line_items: [
        %{variant_id: effective_contract.variant_id, quantity: effective_contract.quantity}
      ],
      currency: effective_contract.currency,
      as_of: renewal_period.current_period_start_at,
      pricing_contract_version: "phase27_virtual_renewal",
      tax_shipping_inputs: %{}
    }

    with {:ok, begin_checkout} <-
           Orders.begin_checkout(begin_attrs, context: %{system?: true}) do
      {:ok, begin_checkout.order}
    end
  end

  defp write_virtual_renewal_snapshot(%Order{} = order, effective_contract) do
    Orders.write_priced_snapshot(
      order.id,
      build_virtual_renewal_pricing_output(effective_contract)
    )
  end

  defp build_virtual_renewal_pricing_output(effective_contract) do
    quantity = effective_contract.quantity
    amount_minor = effective_contract.amount_minor
    line_total_minor = amount_minor * quantity

    %Contract.Output{
      currency: effective_contract.currency,
      subtotal_minor: line_total_minor,
      discount_total_minor: 0,
      total_minor: line_total_minor,
      lines: [
        %{
          line_id: effective_contract.variant_id,
          line_no: 1,
          sku_snapshot: effective_contract.variant.sku || "SUB-RENEWAL",
          product_title_snapshot: effective_contract.variant.product.title,
          variant_title_snapshot: effective_contract.variant.title,
          quantity: quantity,
          unit_price_minor: amount_minor,
          line_total_minor: line_total_minor,
          discount_allocated_minor: 0,
          net_line_total_minor: line_total_minor,
          subscription_plan_id_snapshot: effective_contract.plan.id,
          subscription_plan_key_snapshot: effective_contract.plan.key,
          subscription_interval_unit_snapshot:
            effective_contract.plan.interval_unit |> Atom.to_string(),
          subscription_interval_count_snapshot: effective_contract.plan.interval_count,
          tax_category_snapshot: "STANDARD",
          tax_minor: 0
        }
      ],
      line_allocations: [
        %Contract.LineAllocation{line_id: effective_contract.variant_id, discount_minor: 0}
      ],
      applied_adjustments: []
    }
  end

  defp finalize_renewal_order(%Order{} = order, effective_contract, nil) do
    total_minor = effective_contract.amount_minor * effective_contract.quantity

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: effective_contract.currency,
        items_subtotal_minor: total_minor,
        shipping_total_minor: 0,
        grand_total_minor: total_minor
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp finalize_renewal_order(%Order{} = order, _effective_contract, quote_output)
       when is_map(quote_output) do
    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: quote_output.currency,
        items_subtotal_minor: quote_output.subtotal_minor,
        shipping_total_minor: quote_output.shipping_cost_minor_effective,
        grand_total_minor: quote_output.order_total_minor
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp renewal_order_total_minor(%Order{} = order, effective_contract) do
    if is_integer(order.grand_total_minor) and order.grand_total_minor >= 0 do
      order.grand_total_minor
    else
      effective_contract.amount_minor * effective_contract.quantity
    end
  end

  defp fetch_subscription_shipping_profile(%Subscription{} = subscription) do
    case fetch_shipping_profile_order(subscription) do
      {:ok, %Order{} = profile_order} ->
        build_shipping_profile(profile_order)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_shipping_profile_order(%Subscription{} = subscription) do
    latest_paid_order_query =
      from(attempt in RenewalAttempt,
        join: order in Order,
        on: order.id == attempt.order_id,
        where: attempt.subscription_id == ^subscription.id and order.state == :paid,
        order_by: [desc: attempt.inserted_at, desc: attempt.id],
        limit: 1,
        select: order
      )

    case Repo.one(latest_paid_order_query) do
      %Order{} = order ->
        {:ok, order}

      nil when is_binary(subscription.source_order_id) ->
        fetch_order_for_system(subscription.source_order_id)

      nil ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "physical renewal requires a stored shipping profile"
         )}
    end
  rescue
    error ->
      {:error, Normalize.normalize(error)}
  end

  defp build_shipping_profile(%Order{} = order) do
    country_code = normalize_shipping_text(order.shipping_country_code)
    method_code = normalize_shipping_text(order.shipping_method_code)
    baseline_currency = normalize_shipping_text(order.shipping_quote_currency_code)
    address_line1 = normalize_shipping_text(order.shipping_address_line1)

    if country_code in [nil, ""] or method_code in [nil, ""] or address_line1 in [nil, ""] or
         not is_integer(order.shipping_quote_amount_minor) or baseline_currency in [nil, ""] do
      {:error,
       Error.new("SHIPPING_PROFILE_MISSING", "physical renewal requires prior shipping evidence")}
    else
      {:ok,
       %{
         source_order_id: order.id,
         shipping_country_code: country_code,
         shipping_region_code: normalize_shipping_text(order.shipping_region_code),
         shipping_postal_code: normalize_shipping_text(order.shipping_postal_code),
         shipping_address_line1: address_line1,
         shipping_address_line2: normalize_shipping_text(order.shipping_address_line2),
         shipping_method_code: method_code,
         baseline_shipping_amount_minor: order.shipping_quote_amount_minor,
         baseline_shipping_currency: baseline_currency
       }}
    end
  end

  defp apply_shipping_profile_to_order(%Order{} = order, shipping_profile) do
    order
    |> Ash.Changeset.for_update(
      :set_renewal_shipping_profile,
      %{
        shipping_country_code: shipping_profile.shipping_country_code,
        shipping_region_code: shipping_profile.shipping_region_code,
        shipping_postal_code: shipping_profile.shipping_postal_code,
        shipping_address_line1: shipping_profile.shipping_address_line1,
        shipping_address_line2: shipping_profile.shipping_address_line2,
        shipping_rate_code: shipping_profile.shipping_method_code
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp quote_physical_renewal_shipping(shipping_profile, effective_contract) do
    request_attrs = %{
      destination_country_code: shipping_profile.shipping_country_code,
      destination_region_code: shipping_profile.shipping_region_code,
      destination_postal_code: shipping_profile.shipping_postal_code,
      currency_code: effective_contract.currency,
      shipping_weight_grams: physical_renewal_weight_grams(effective_contract)
    }

    with {:ok, request} <- QuoteRequest.new(request_attrs),
         {:ok, options} <- ShippingFacade.quote_options_for_system(request, []) do
      select_shipping_quote_option(options, shipping_profile.shipping_method_code)
    else
      {:error, %Error{code: "VALIDATION_ERROR"}} ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "physical renewal requires a valid shipping profile"
         )}

      {:error, _reason} ->
        {:error,
         Error.new("SHIPPING_PROVIDER_DOWN", "unable to fetch shipping quote for renewal")}
    end
  end

  defp select_shipping_quote_option(options, shipping_method_code)
       when is_list(options) and is_binary(shipping_method_code) do
    case Enum.find(options, &(&1.shipping_method_code == shipping_method_code)) do
      %QuoteOption{} = option ->
        {:ok, option}

      nil ->
        {:error,
         Error.new(
           "SHIPPING_UNAVAILABLE",
           "stored shipping method is no longer available for renewal"
         )}
    end
  end

  defp ensure_shipping_quote_within_surge_limit(%QuoteOption{} = option, shipping_profile) do
    baseline_amount = shipping_profile.baseline_shipping_amount_minor
    baseline_currency = shipping_profile.baseline_shipping_currency
    current_currency = normalize_shipping_text(option.currency_code)

    cond do
      not is_integer(baseline_amount) or baseline_amount < 0 or baseline_currency in [nil, ""] ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "physical renewal requires prior shipping evidence"
         )}

      current_currency != baseline_currency ->
        {:error,
         Error.new(
           "SHIPPING_PROFILE_MISSING",
           "renewal shipping currency does not match the stored shipping profile"
         )}

      shipping_cost_surge?(option.amount_minor, baseline_amount) ->
        {:error,
         Error.new(
           "SHIPPING_COST_SURGE",
           "renewal shipping cost exceeds the allowed drift threshold"
         )}

      true ->
        :ok
    end
  end

  defp shipping_cost_surge?(current_amount_minor, baseline_amount_minor)
       when is_integer(current_amount_minor) and is_integer(baseline_amount_minor) do
    diff = current_amount_minor - baseline_amount_minor

    diff > @shipping_surge_absolute_minor or
      (baseline_amount_minor > 0 and
         diff * 10_000 > baseline_amount_minor * @shipping_surge_percent_bps)
  end

  defp evaluate_physical_renewal_quote_output(
         %Order{} = order,
         effective_contract,
         %QuoteOption{} = option
       ) do
    quote_evidence = QuoteEvidence.from_quote_option(option)
    subtotal_minor = effective_contract.amount_minor * effective_contract.quantity

    with {:ok, tax_rates} <- fetch_active_tax_rates(order.shipping_country_code),
         input <-
           TaxShippingContract.to_input!(%{
             as_of: DateTime.utc_now() |> DateTime.truncate(:microsecond),
             currency: effective_contract.currency,
             destination_country_code: order.shipping_country_code,
             destination_region_code: order.shipping_region_code,
             destination_postal_code: order.shipping_postal_code,
             subtotal_minor: subtotal_minor,
             shipping_weight_grams: quote_evidence.shipping_weight_grams,
             lines: [
               %{
                 line_id: effective_contract.variant_id,
                 line_no: 1,
                 net_line_total_minor: subtotal_minor,
                 tax_category_snapshot: "STANDARD"
               }
             ],
             shipping_rates: [shipping_candidate_from_quote_evidence(quote_evidence)],
             tax_rates: Enum.map(tax_rates, &tax_rate_candidate/1),
             free_shipping_coupon?: false,
             shipping_enabled?: true,
             tax_enabled?: true
           }),
         {:ok, output} <- TaxShippingEvaluator.evaluate(input) do
      {:ok, output}
    else
      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_active_tax_rates(country_code) when is_binary(country_code) do
    query = TaxRate |> Ash.Query.filter(expr(country_code == ^country_code))

    case Ash.read(query, domain: Store.Pricing, authorize?: false) do
      {:ok, tax_rates} -> {:ok, tax_rates}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp shipping_candidate_from_quote_evidence(%QuoteEvidence{} = quote_evidence) do
    %{
      id: quote_evidence.shipping_rule_id || "00000000-0000-0000-0000-000000000000",
      code: quote_evidence.shipping_method_code,
      shipping_cost_minor: quote_evidence.amount_minor,
      country_code: quote_evidence.destination_country_code,
      region_code: quote_evidence.destination_region_code,
      weight_min_grams: nil,
      weight_max_grams: nil,
      free_over_subtotal_minor: nil,
      allow_free_shipping_coupon: false,
      starts_at: quote_evidence.effective_from,
      ends_at: quote_evidence.effective_to,
      active?: true,
      precedence_rank: 0
    }
  end

  defp tax_rate_candidate(rate) do
    %{
      id: rate.id,
      code: rate.code,
      country_code: rate.country_code,
      region_code: rate.region_code,
      product_tax_category: rate.product_tax_category,
      rate_basis_points: rate.rate_basis_points,
      shipping_taxable: rate.shipping_taxable,
      starts_at: rate.starts_at,
      ends_at: rate.ends_at,
      active?: rate.active,
      precedence_rank: rate.precedence_rank
    }
  end

  defp physical_renewal_weight_grams(effective_contract) do
    max((effective_contract.variant.weight_grams || 0) * effective_contract.quantity, 0)
  end

  defp normalize_shipping_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_shipping_text(_value), do: nil

  defp hard_retry_suppressed_reason?(message) when is_binary(message) do
    MapSet.member?(@hard_retry_suppressed_reasons, message)
  end

  defp hard_retry_suppressed_reason?(_message), do: false

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{state: :created} = payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action, :succeeded] do
    {:ok, payment_intent}
  end

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{state: state} = payment_intent)
       when state in [:failed, :cancelled] do
    {:ok, payment_intent}
  end

  defp maybe_submit_virtual_payment_intent(%PaymentIntent{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent cannot be submitted from the current state"
     )}
  end

  defp request_off_session_renewal_charge(
         subscription,
         plan,
         _attempt,
         %{
           order: order,
           payment_intent: payment_intent,
           renewal_attempt: %RenewalAttempt{} = bound_attempt
         },
         collection_attempt,
         now
       ) do
    :telemetry.execute(
      [:store, :subscriptions, :renewal_charge_dispatch_check],
      %{attempt_no: bound_attempt.attempt_no},
      %{
        subscription_id: subscription.id,
        renewal_attempt_id: bound_attempt.id,
        order_id: order.id,
        payment_intent_id: payment_intent.id,
        collection_attempt_id: collection_attempt.id
      }
    )

    result =
      if reached_collection_requires_reconciliation?(
           collection_attempt,
           payment_intent,
           subscription
         ) do
        reconcile_existing_renewal_collection(payment_intent, collection_attempt)
      else
        input = %AttachAndClaimInput{
          collection_attempt_id: collection_attempt.id,
          renewal_attempt_id: bound_attempt.id,
          subscription_id: subscription.id,
          payment_intent_id: payment_intent.id,
          expected_epoch: collection_attempt.dispatch_epoch,
          now: now
        }

        case RenewalCollectionAttempts.attach_and_claim_dispatch_for_system(input) do
          {:ok, claim} ->
            submit_claimed_renewal_collection(subscription, plan, bound_attempt, claim, now)

          {:error, %Error{code: "RENEWAL_AUTHORITY_WITHDRAWN"}} ->
            fence_withdrawn_renewal_collection(collection_attempt, now)

          {:error, reason} ->
            {:error, reason}
        end
      end

    settle_replayed_authentication_required(
      result,
      subscription,
      bound_attempt,
      collection_attempt,
      now
    )
  end

  defp submit_claimed_renewal_collection(subscription, plan, bound_attempt, claim, now) do
    with {:ok, submitted_payment_intent} <-
           maybe_submit_virtual_payment_intent(claim.payment_intent) do
      case dispatch_action_for_claim(claim, subscription) do
        :reconcile ->
          reconcile_existing_renewal_collection(
            submitted_payment_intent,
            claim.collection_attempt
          )

        :submit ->
          submit_off_session_renewal_charge(
            subscription,
            plan,
            claim.renewal_attempt || bound_attempt,
            claim.order,
            submitted_payment_intent,
            claim.provider_payment_method,
            claim.collection_attempt,
            now
          )
      end
    end
  end

  defp fence_withdrawn_renewal_collection(collection_attempt, now) do
    input = %FenceInput{
      collection_attempt_id: collection_attempt.id,
      expected_epoch: collection_attempt.dispatch_epoch,
      now: now
    }

    case RenewalCollectionAttempts.fence_before_submission_for_system(input) do
      {:ok, _fenced_collection} -> {:ok, :renewal_authority_withdrawn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_action_for_claim(%{dispatch_claimed?: true}, _subscription), do: :submit

  defp dispatch_action_for_claim(
         %{collection_attempt: collection_attempt, payment_intent: payment_intent},
         %Subscription{} = subscription
       ) do
    if reached_collection_requires_reconciliation?(
         collection_attempt,
         payment_intent,
         subscription
       ),
       do: :reconcile,
       else: :submit
  end

  defp reached_collection_requires_reconciliation?(
         %RenewalCollectionAttempt{dispatch_state: :may_have_been_reached} = collection,
         %PaymentIntent{} = payment_intent,
         %Subscription{status: status}
       ) do
    capabilities = Providers.capabilities(payment_intent.provider)

    RenewalCollectionDispatchPolicy.recovery_action(
      collection,
      payment_intent,
      status,
      if(is_map(capabilities), do: capabilities, else: %{})
    ) == :reconcile
  end

  defp reached_collection_requires_reconciliation?(_collection, _payment_intent, _subscription),
    do: false

  defp reconcile_existing_renewal_collection(
         %PaymentIntent{} = payment_intent,
         %RenewalCollectionAttempt{} = collection_attempt
       ) do
    case RenewalCollectionAttempts.success_handoff_for_system(collection_attempt.id) do
      {:ok, %{payment_intent_id: payment_intent_id}}
      when payment_intent_id == payment_intent.id ->
        {:ok, payment_intent}

      _ ->
        reconcile_existing_renewal_collection(payment_intent)
    end
  end

  defp reconcile_existing_renewal_collection(%PaymentIntent{
         state: :requires_action,
         provider_payment_id: nil
       }) do
    {:error,
     Error.new(
       "PAYMENT_AUTHENTICATION_REQUIRED",
       "customer authentication is required before this renewal collection can continue"
     )}
  end

  defp reconcile_existing_renewal_collection(
         %PaymentIntent{
           provider_payment_id: provider_payment_id,
           provider_request_reference: provider_request_reference
         } = payment_intent
       )
       when (is_binary(provider_payment_id) and provider_payment_id != "") or
              (is_binary(provider_request_reference) and provider_request_reference != "") do
    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    with {:ok, observation_result} <- PaymentsFacade.observe_payment_intent_for_system(input),
         {:ok, %{outcome: outcome}} <-
           PaymentsFacade.apply_observed_payment_outcome_for_system(observation_result) do
      case outcome do
        outcome when outcome in [:authoritative_success, :already_applied_success] ->
          {:ok, payment_intent}

        :verified_terminal_non_success ->
          {:error,
           Error.new(
             "PAYMENT_FAILED",
             "existing renewal collection reached terminal financial non-success"
           )}

        :requires_action ->
          {:error,
           Error.new(
             "PAYMENT_AUTHENTICATION_REQUIRED",
             "customer authentication is required to complete renewal"
           )}

        _ ->
          {:error,
           Error.new(
             "PAYMENT_OUTCOME_UNRESOLVED",
             "existing renewal collection remains financially unresolved",
             %{existing_collection_replay?: true}
           )}
      end
    else
      {:error, %Error{code: "PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED"}} ->
        {:error,
         Error.new(
           "PAYMENT_OUTCOME_UNRESOLVED",
           "provider request identity cannot be observed with the configured adapter",
           %{existing_collection_replay?: true}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_existing_renewal_collection(%PaymentIntent{}) do
    {:error,
     Error.new(
       "PAYMENT_OUTCOME_UNRESOLVED",
       "renewal collection has no provider identity to reconcile",
       %{existing_collection_replay?: true}
     )}
  end

  defp submit_off_session_renewal_charge(
         subscription,
         _plan,
         attempt,
         order,
         payment_intent,
         stored_payment_method,
         collection_attempt,
         now
       ) do
    with {:ok, charge_response} <-
           Providers.charge_off_session(
             subscription.provider,
             renewal_collection_charge_request(
               attempt,
               order,
               payment_intent,
               stored_payment_method,
               collection_attempt
             ),
             []
           ),
         {:ok, payment_intent} <-
           persist_payment_intent_provider_refs(payment_intent, charge_response),
         observation <-
           direct_charge_observation(subscription.provider, payment_intent, charge_response),
         {:ok, %{outcome: outcome}} <-
           PaymentsFacade.record_and_apply_payment_observation_for_system(
             payment_intent,
             observation
           ) do
      handle_off_session_renewal_outcome(
        outcome,
        subscription,
        attempt,
        order,
        payment_intent,
        collection_attempt,
        charge_response,
        now
      )
    else
      {:error, %Error{code: "PAYMENT_EVENT_UNVERIFIED"}} ->
        {:error,
         Error.new(
           "PAYMENT_OUTCOME_UNRESOLVED",
           "provider response does not identify the exact payment transaction"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_off_session_renewal_outcome(
         outcome,
         _subscription,
         _attempt,
         _order,
         payment_intent,
         _collection_attempt,
         _charge_response,
         _now
       )
       when outcome in [:authoritative_success, :already_applied_success],
       do: {:ok, payment_intent}

  defp handle_off_session_renewal_outcome(
         :verified_terminal_non_success,
         _subscription,
         _attempt,
         _order,
         _payment_intent,
         _collection_attempt,
         _charge_response,
         _now
       ) do
    {:error, Error.new("PAYMENT_FAILED", "off-session renewal charge reached terminal failure")}
  end

  defp handle_off_session_renewal_outcome(
         :requires_action,
         subscription,
         attempt,
         order,
         payment_intent,
         collection_attempt,
         charge_response,
         now
       ) do
    case settle_authentication_required(subscription, attempt, collection_attempt, now) do
      {:ok, :settled} ->
        enqueue_authentication_required_email_result(
          enqueue_payment_authentication_required_email(order, charge_response)
        )

      {:ok, :success_won} ->
        {:ok, payment_intent}

      {:ok, :noop} ->
        {:error, payment_authentication_required_error()}

      {:error, reason} ->
        {:error, {:authentication_settlement_failed, reason}}
    end
  end

  defp handle_off_session_renewal_outcome(
         _outcome,
         _subscription,
         _attempt,
         _order,
         _payment_intent,
         _collection_attempt,
         _charge_response,
         _now
       ) do
    {:error,
     Error.new(
       "PAYMENT_OUTCOME_UNRESOLVED",
       "provider response does not establish terminal payment outcome"
     )}
  end

  defp enqueue_authentication_required_email_result({:ok, _outbox}),
    do: {:error, payment_authentication_required_error()}

  defp enqueue_authentication_required_email_result({:error, :missing_action_url}),
    do: {:error, payment_authentication_required_error()}

  defp enqueue_authentication_required_email_result({:error, reason}),
    do: {:error, {:authentication_settlement_failed, Normalize.normalize(reason)}}

  defp renewal_collection_charge_request(
         %RenewalAttempt{} = attempt,
         %Order{} = order,
         %PaymentIntent{} = payment_intent,
         provider_payment_method,
         %RenewalCollectionAttempt{} = collection
       ) do
    %RenewalCollectionChargeRequest{
      internal_collection_identity: payment_intent.payment_intent_key,
      provider_request_reference: payment_intent.provider_request_reference,
      collection_attempt_id: collection.id,
      payment_intent_id: payment_intent.id,
      renewal_attempt_id: attempt.id,
      order_id: order.id,
      subscription_id: attempt.subscription_id,
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      renewal_key: attempt.renewal_key,
      provider_customer_ref: provider_payment_method.provider_customer_ref,
      provider_customer_email: nil,
      provider_credential_ref: provider_payment_method.provider_payment_method_ref
    }
  end

  defp direct_charge_observation(provider, payment_intent, charge_response) do
    provider_status = Map.get(charge_response, :raw_provider_status)

    normalized_outcome =
      case Map.get(charge_response, :status) do
        :succeeded -> :authoritative_success
        :requires_action -> :requires_action
        :failed -> :failure_observation
        _ -> :unknown_or_contradictory
      end

    raw_provider_status =
      normalize_provider_status(provider_status || Map.get(charge_response, :status))

    provider_reference =
      charge_response.provider_payment_id || payment_intent.provider_request_reference

    provider_reference_kind =
      if is_binary(charge_response.provider_payment_id),
        do: :payment_intent,
        else: :transaction_reference

    observation_identity =
      {provider, provider_reference, provider_reference_kind, raw_provider_status,
       charge_response.amount_minor, charge_response.currency,
       charge_response.provider_environment}

    %Store.Payments.Types.ProviderObservation{
      provider: provider,
      provider_reference: provider_reference || "",
      provider_reference_kind: provider_reference_kind,
      provider_transaction_id: charge_response.provider_payment_id,
      local_payment_intent_id: payment_intent.id,
      observation_source: :direct_response,
      normalized_outcome: normalized_outcome,
      raw_provider_status: raw_provider_status,
      amount_minor: charge_response.amount_minor,
      currency: charge_response.currency,
      provider_environment: charge_response.provider_environment,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      evidence_sha256:
        :crypto.hash(:sha256, :erlang.term_to_binary(observation_identity, [:deterministic]))
        |> Base.encode16(case: :lower)
    }
  end

  defp normalize_provider_status(status) when is_binary(status), do: status
  defp normalize_provider_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_provider_status(_status), do: "unknown"

  defp persist_payment_intent_provider_refs(%PaymentIntent{} = payment_intent, charge_response) do
    payment_intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{
        provider: payment_intent.provider,
        provider_payment_id: Map.get(charge_response, :provider_payment_id),
        provider_customer_ref: Map.get(charge_response, :provider_customer_ref),
        provider_payment_method_ref: Map.get(charge_response, :provider_payment_method_ref),
        provider_client_secret: Map.get(charge_response, :provider_client_secret)
      },
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Store.Payments,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp mark_attempt_processing(%RenewalAttempt{} = attempt, order_id, payment_intent_id) do
    result =
      attempt
      |> Ash.Changeset.for_update(
        :mark_processing,
        %{order_id: order_id, payment_intent_id: payment_intent_id},
        context: %{system?: true}
      )
      |> Ash.update(
        domain: Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    case result do
      {:error, reason} ->
        case fetch_renewal_attempt_by_id(attempt.id) do
          {:ok, %RenewalAttempt{failure_code: @renewal_authority_withdrawn_code} = withdrawn} ->
            {:ok, withdrawn}

          _ ->
            {:error, Normalize.normalize(reason)}
        end

      other ->
        other
    end
  end

  defp fetch_renewal_attempt_by_id(attempt_id) do
    query = RenewalAttempt |> Ash.Query.filter(expr(id == ^attempt_id))

    case Ash.read_one(query,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %RenewalAttempt{} = attempt} -> {:ok, attempt}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "renewal attempt was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp settle_replayed_authentication_required(
         {:error, %Error{code: "PAYMENT_AUTHENTICATION_REQUIRED"} = error},
         subscription,
         attempt,
         collection_attempt,
         now
       ) do
    case settle_authentication_required(subscription, attempt, collection_attempt, now,
           replay?: true
         ) do
      {:ok, outcome} when outcome in [:success_won, :noop] -> {:ok, :processed}
      {:ok, _outcome} -> {:error, error}
      {:error, reason} -> {:error, {:authentication_settlement_failed, reason}}
    end
  end

  defp settle_replayed_authentication_required(
         result,
         _subscription,
         _attempt,
         _collection,
         _now
       ),
       do: result

  defp settle_authentication_required(subscription, attempt, collection_attempt, now, opts \\ []) do
    replay? = Keyword.get(opts, :replay?, false)

    transaction_result =
      Repo.transaction(fn ->
        with {:ok, locked_subscription} <-
               fetch_subscription_for_renewal_locked(subscription.id),
             {:ok, locked_attempt} <-
               fetch_renewal_attempt_for_failure_settlement(attempt.id, subscription.id),
             {:ok, settlement} <-
               settle_locked_authentication_required(
                 locked_subscription,
                 locked_attempt,
                 collection_attempt,
                 now,
                 replay?
               ) do
          {:ok, settlement}
        else
          {:error, settlement_error} -> Repo.rollback(settlement_error)
        end
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, %{outcome: :settled} = settlement, notifications} ->
        settlement = Map.put(settlement, :notifications, notifications)

        :ok =
          AshNotifications.notify_post_commit(settlement.notifications,
            context: %{
              flow: :settle_authentication_required_renewal,
              subscription_id: settlement.subscription.id,
              renewal_attempt_id: attempt.id,
              collection_attempt_id: collection_attempt.id
            }
          )

        emit_subscription_dunning_telemetry(
          settlement.subscription,
          :past_due,
          settlement.dunning_count
        )

        :ok = sync_past_due_access_after_commit(settlement)

        {:ok, :settled}

      {:ok, %{outcome: :success_won, handoff: handoff}, _notifications} ->
        case reconcile_failure_suppressed_success(handoff) do
          :ok -> {:ok, :success_won}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{outcome: :noop}, _notifications} ->
        {:ok, :noop}

      {:error, settlement_error} ->
        {:error, settlement_error}
    end
  end

  defp settle_locked_authentication_required(
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         collection_attempt,
         now,
         replay?
       ) do
    with :ok <-
           RenewalCollectionAttempts.ensure_current_dunning_attempt_owner(subscription, attempt),
         :ok <- ensure_locked_dunning_attempt_identity(subscription, attempt),
         do:
           settle_locked_authentication_required_with_identity(
             subscription,
             attempt,
             collection_attempt,
             now,
             replay?
           )
  end

  defp settle_locked_authentication_required_with_identity(
         subscription,
         attempt,
         collection_attempt,
         now,
         replay?
       ) do
    if authentication_required_terminal?(subscription, attempt) do
      {:ok, %{outcome: :noop}}
    else
      settle_authentication_required_after_paid_handoff(
        subscription,
        attempt,
        collection_attempt,
        now,
        replay?
      )
    end
  end

  defp authentication_required_terminal?(subscription, attempt) do
    attempt.status == :succeeded or
      attempt.failure_code == @renewal_authority_withdrawn_code or
      subscription.status in [:canceled, :expired, :pending, :suspended]
  end

  defp settle_authentication_required_after_paid_handoff(
         subscription,
         attempt,
         collection_attempt,
         now,
         replay?
       ) do
    case exact_paid_renewal_success_handoff(attempt) do
      {:ok, %{} = handoff} ->
        {:ok, %{outcome: :success_won, handoff: handoff}}

      {:ok, nil} ->
        persist_authentication_required_dunning(
          subscription,
          attempt,
          collection_attempt,
          now,
          replay?
        )

      {:error, authority_error} ->
        {:error, authority_error}
    end
  end

  defp persist_authentication_required_dunning(
         subscription,
         attempt,
         collection_attempt,
         now,
         replay?
       ) do
    with {:ok, {collection_outcome, exact_collection}} <-
           fetch_requires_action_collection(collection_attempt, attempt, replay?),
         false <- authentication_required_dunning_already_settled?(subscription) do
      case collection_outcome do
        :unresolved ->
          {:ok, %{outcome: :noop}}

        :requires_action ->
          persist_authentication_required_dunning_transition(
            subscription,
            attempt,
            exact_collection,
            now
          )
      end
    else
      true ->
        {:ok, %{outcome: :noop}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_authentication_required_dunning_transition(
         subscription,
         attempt,
         exact_collection,
         now
       ) do
    retry_policy = renewal_policy_from_attempt(attempt)
    next_attempt_count = max((subscription.dunning_attempt_count || 0) + 1, 1)
    past_due_since_at = dunning_anchor(subscription, now)

    failed_payment_boundary_at =
      failed_payment_boundary_for_first_failure(
        subscription,
        retry_policy,
        past_due_since_at
      )

    attrs = %{
      billing_status_reason: "PAYMENT_AUTHENTICATION_REQUIRED",
      past_due_since_at: past_due_since_at,
      failed_payment_boundary_at: failed_payment_boundary_at,
      dunning_attempt_count: next_attempt_count,
      next_retry_at: nil,
      retry_suppressed_at: now
    }

    private_arguments = dunning_transition_private_arguments(subscription, attempt)

    changeset =
      subscription
      |> Ash.Changeset.for_update(:mark_past_due_transition, attrs,
        context: %{system?: true},
        private_arguments: private_arguments
      )

    changeset
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %Subscription{} = updated, notifications} when is_list(notifications) ->
        finalize_authentication_required_dunning_settlement(
          subscription,
          updated,
          attempt,
          next_attempt_count,
          exact_collection,
          notifications
        )

      {:ok, %Subscription{} = updated} ->
        finalize_authentication_required_dunning_settlement(
          subscription,
          updated,
          attempt,
          next_attempt_count,
          exact_collection,
          []
        )

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp finalize_authentication_required_dunning_settlement(
         before_subscription,
         updated_subscription,
         attempt,
         dunning_count,
         exact_collection,
         notifications
       ) do
    with {:ok, past_due_access_effect} <-
           maybe_establish_first_transition_past_due_policy_effect(
             before_subscription,
             updated_subscription,
             attempt
           ) do
      {:ok,
       %{
         outcome: :settled,
         subscription: updated_subscription,
         dunning_count: dunning_count,
         collection_attempt: exact_collection,
         past_due_access_effect: past_due_access_effect,
         notifications: notifications
       }}
    end
  end

  defp fetch_requires_action_collection(
         %RenewalCollectionAttempt{
           id: collection_id,
           payment_intent_id: expected_payment_intent_id
         },
         %RenewalAttempt{id: attempt_id},
         replay?
       ) do
    query =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(id == ^collection_id and renewal_attempt_id == ^attempt_id))

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %RenewalCollectionAttempt{} = collection} ->
        validate_requires_action_collection_identity(
          collection,
          expected_payment_intent_id,
          replay?
        )

      {:ok, nil} ->
        {:error, Error.new("STALE_RECORD", "renewal collection owner changed")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp validate_requires_action_collection_identity(
         %RenewalCollectionAttempt{} = collection,
         expected_payment_intent_id,
         replay?
       ) do
    if is_nil(expected_payment_intent_id) or
         collection.payment_intent_id == expected_payment_intent_id do
      classify_requires_action_collection_outcome(collection, replay?)
    else
      {:error, Error.new("STALE_RECORD", "renewal collection payment identity changed")}
    end
  end

  defp classify_requires_action_collection_outcome(
         %RenewalCollectionAttempt{financial_outcome: :requires_action} = collection,
         _replay?
       ),
       do: {:ok, {:requires_action, collection}}

  defp classify_requires_action_collection_outcome(
         %RenewalCollectionAttempt{financial_outcome: :unresolved} = collection,
         true
       ),
       do: {:ok, {:unresolved, collection}}

  defp classify_requires_action_collection_outcome(%RenewalCollectionAttempt{}, _replay?) do
    {:error, Error.new("STALE_RECORD", "renewal collection no longer requires authentication")}
  end

  defp authentication_required_dunning_already_settled?(%Subscription{
         status: :past_due,
         billing_status_reason: "PAYMENT_AUTHENTICATION_REQUIRED",
         retry_suppressed_at: %DateTime{}
       }),
       do: true

  defp authentication_required_dunning_already_settled?(_subscription), do: false

  defp payment_authentication_required_error do
    Error.new(
      "PAYMENT_AUTHENTICATION_REQUIRED",
      "customer authentication is required to complete renewal"
    )
  end

  defp enqueue_payment_authentication_required_email(%Order{} = order, charge_response) do
    Comms.enqueue_payment_authentication_required_for_system(
      order.id,
      action_url: Map.get(charge_response, :action_url),
      provider_client_secret: Map.get(charge_response, :provider_client_secret)
    )
  end

  defp maybe_enqueue_membership_access_ended_email(
         %Subscription{} = subscription,
         %SubscriptionPlan{entitlement_kind: :membership_access},
         reason
       )
       when is_binary(reason) do
    Comms.enqueue_membership_access_ended_for_system(subscription.id, reason)
  end

  defp maybe_enqueue_membership_access_ended_email(_subscription, _plan, _reason), do: :ok

  defp enqueue_scheduled_cancellation_email(%Subscription{} = subscription) do
    Comms.enqueue_membership_access_ended_for_system(
      subscription.id,
      "canceled_period_end"
    )
  end

  defp fetch_variant_for_renewal(variant_id) when is_binary(variant_id) do
    query =
      Variant
      |> Ash.Query.filter(expr(id == ^variant_id))
      |> Ash.Query.load([:product])

    case Ash.read(query, domain: Store.Catalog, authorize?: false, context: %{system?: true}) do
      {:ok, [%Variant{} = variant | _]} ->
        {:ok, variant}

      {:ok, []} ->
        {:error, Error.new("VALIDATION_ERROR", "subscription variant is unavailable")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_variant_subscription_plan_active(variant_id, plan_id) do
    query =
      VariantSubscriptionPlan
      |> Ash.Query.filter(
        expr(variant_id == ^variant_id and subscription_plan_id == ^plan_id and active == true)
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [_ | _]} ->
        :ok

      {:ok, []} ->
        {:error,
         Error.new(
           "VARIANT_PLAN_UNAVAILABLE",
           "subscription plan is no longer active for this variant"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_variant_catalog_renewable(%Variant{
         status: :active,
         product: %Product{status: :published}
       }),
       do: :ok

  defp ensure_variant_catalog_renewable(%Variant{}) do
    {:error, Error.new("VALIDATION_ERROR", "subscription variant is unavailable")}
  end

  defp physical_renewal_variant?(%Variant{weight_grams: weight_grams})
       when is_integer(weight_grams) and weight_grams > 0,
       do: true

  defp physical_renewal_variant?(%Variant{}), do: false

  defp fetch_renewal_attempt_by_order(order_id, renewal_attempt_id \\ nil)

  defp fetch_renewal_attempt_by_order(order_id, renewal_attempt_id)
       when is_binary(order_id) and is_binary(renewal_attempt_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(id == ^renewal_attempt_id and order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%RenewalAttempt{} = attempt | _]} -> {:ok, attempt}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "renewal attempt not found for order")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_renewal_attempt_by_order(order_id, _renewal_attempt_id) when is_binary(order_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [%RenewalAttempt{} = attempt | _]} -> {:ok, attempt}
      {:ok, []} -> {:error, Error.new("NOT_FOUND", "renewal attempt not found for order")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_matching_attempt_payment(
         order_id,
         %RenewalAttempt{order_id: order_id},
         payment_intent_id
       )
       when is_binary(payment_intent_id),
       do: :ok

  defp ensure_matching_attempt_payment(_order_id, _attempt, _payment_intent_id) do
    {:error, Error.new("VALIDATION_ERROR", "renewal attempt does not match the paid order")}
  end

  defp reconcile_paid_renewal_attempt(%RenewalAttempt{} = attempt) do
    result =
      Repo.transaction(fn -> reconcile_paid_renewal_attempt_in_transaction(attempt) end)

    case result do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp reconcile_paid_renewal_attempt_in_transaction(attempt) do
    with {:ok, revision} <- fetch_plan_revision(attempt.plan_revision_id),
         {:ok, subscription} <- fetch_subscription_for_renewal_locked(attempt.subscription_id),
         {:ok, contract_change} <- lock_reconciliation_contract_change(attempt.contract_change_id),
         :ok <- validate_reconciliation_contract_change(contract_change, subscription, attempt) do
      target = renewal_entitlement_target(attempt)

      apply_locked_reconciliation(
        subscription,
        contract_change,
        attempt,
        revision,
        target
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_locked_reconciliation(
         %Subscription{} = subscription,
         contract_change,
         %RenewalAttempt{} = attempt,
         revision,
         target
       ) do
    case find_historical_charged_renewal_effect(subscription, attempt, target) do
      {:ok, %AccessEffect{} = effect} ->
        case charged_renewal_effect_handoff(effect, subscription, attempt, target) do
          {:ok, effect_id, lane} ->
            %{
              outcome: :already_applied,
              subscription: subscription,
              target: target,
              notifications: [],
              renewal_access_effect_id: effect_id,
              grant_writer_lane: lane
            }

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:ok, nil} ->
        apply_locked_reconciliation_without_historical_effect(
          subscription,
          contract_change,
          attempt,
          revision,
          target
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_locked_reconciliation_without_historical_effect(
         %Subscription{status: :canceled} = subscription,
         _contract_change,
         %RenewalAttempt{} = attempt,
         _revision,
         target
       ) do
    if subscription.canceled_reason == "canceled_period_end" and
         subscription.canceled_at == attempt.period_end_at and
         subscription.current_period_end_at == attempt.period_end_at do
      %{
        outcome: :scheduled_cancellation,
        subscription: subscription,
        target: target,
        notifications: []
      }
    else
      %{
        outcome: :canceled,
        subscription: subscription,
        target: target,
        notifications: []
      }
    end
  end

  defp apply_locked_reconciliation_without_historical_effect(
         subscription,
         contract_change,
         attempt,
         revision,
         target
       ) do
    case exact_reconciliation_replay(subscription, contract_change, attempt, revision, target) do
      {:continue, :replay} ->
        Repo.rollback(
          Error.new(
            "VALIDATION_ERROR",
            "charged renewal replay has no unique historical EFFECTIVE AccessEffect"
          )
        )

      {:continue, :apply} ->
        apply_first_reconciliation(subscription, contract_change, attempt, revision, target)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_first_reconciliation(subscription, contract_change, attempt, revision, target) do
    with :ok <- ensure_reconciliation_period_boundary(subscription, attempt),
         :ok <- ensure_reconciliation_no_future_target(subscription, contract_change, attempt),
         {:ok, updated, subscription_notifications} <-
           update_reconciled_subscription(subscription, attempt, revision, target),
         {:ok, change_notifications} <- apply_reconciliation_contract_change(contract_change),
         {:ok, outcome, terminal_subscription, terminal_notifications} <-
           terminalize_late_reconciled_cancellation(subscription, updated, attempt),
         {:ok, effect} <-
           maybe_establish_charged_renewal_access_effect(
             outcome,
             terminal_subscription,
             attempt,
             target
           ),
         {:ok, effect_id, grant_writer_lane} <-
           charged_renewal_effect_handoff(effect, terminal_subscription, attempt, target) do
      %{
        outcome: outcome,
        subscription: terminal_subscription,
        target: target,
        renewal_access_effect_id: effect_id,
        grant_writer_lane: grant_writer_lane,
        notifications:
          subscription_notifications ++ change_notifications ++ terminal_notifications
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_establish_charged_renewal_access_effect(
         :applied,
         %Subscription{} = renewed,
         %RenewalAttempt{} = attempt,
         target
       ),
       do: establish_charged_renewal_access_effect(renewed, attempt, target)

  defp maybe_establish_charged_renewal_access_effect(_outcome, _renewed, _attempt, _target),
    do: {:ok, nil}

  defp charged_renewal_effect_handoff(nil, _subscription, _attempt, _target),
    do: {:ok, nil, nil}

  defp charged_renewal_effect_handoff(
         %AccessEffect{} = effect,
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         target
       ) do
    with :ok <- validate_charged_renewal_effect_identity(effect, subscription, attempt, target),
         {:ok, predecessor} <- immediate_access_effect_predecessor(effect) do
      lane =
        case predecessor do
          %AccessEffect{disposition: :non_effective} -> :suspended_recovery
          %AccessEffect{disposition: :effective} -> :ordinary
          nil -> :ordinary
        end

      {:ok, effect.id, lane}
    end
  end

  defp validate_charged_renewal_effect_identity(effect, subscription, attempt, target) do
    if charged_renewal_effect_identity_matches?(effect, subscription, attempt, target) do
      :ok
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "charged renewal EFFECTIVE AccessEffect does not match immutable occurrence evidence"
       )}
    end
  end

  defp charged_renewal_effect_identity_matches?(effect, subscription, attempt, target) do
    Enum.all?([
      effect.subscription_id == subscription.id,
      effect.disposition == :effective,
      effect.plan_revision_id == attempt.plan_revision_id,
      effect.entitlement_kind == Map.get(target, :entitlement_kind),
      effect.entitlement_scope_key == Map.get(target, :entitlement_scope_key),
      charged_renewal_effect_start_matches?(effect, target, attempt),
      effect.source_order_line_item_id == subscription.source_order_line_item_id,
      datetime_equal?(effect.valid_until_at, attempt.period_end_at)
    ])
  end

  defp charged_renewal_effect_start_matches?(effect, target, attempt) do
    case {Map.get(target, :entitlement_kind), Map.get(target, :entitlement_scope_key)} do
      {kind, scope_key} when not is_nil(kind) and is_binary(scope_key) ->
        datetime_equal?(effect.valid_from_at, attempt.period_start_at)

      {nil, nil} ->
        is_nil(effect.valid_from_at)

      _ ->
        false
    end
  end

  defp find_historical_charged_renewal_effect(subscription, attempt, target) do
    with :ok <- validate_charged_renewal_target_pair(target) do
      query =
        AccessEffect
        |> Ash.Query.filter(
          expr(
            subscription_id == ^subscription.id and
              disposition == :effective and
              plan_revision_id == ^attempt.plan_revision_id and
              source_order_line_item_id == ^subscription.source_order_line_item_id and
              valid_until_at == ^attempt.period_end_at
          )
        )
        |> charged_renewal_target_filter(target, attempt)
        |> Ash.Query.sort(source_version: :desc)
        |> Ash.Query.limit(2)

      case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
        {:ok, [%AccessEffect{} = effect]} ->
          {:ok, effect}

        {:ok, []} ->
          {:ok, nil}

        {:ok, [_first, _second | _rest]} ->
          {:error,
           Error.new(
             "VALIDATION_ERROR",
             "charged renewal has ambiguous historical EFFECTIVE AccessEffect evidence"
           )}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    end
  end

  defp validate_charged_renewal_target_pair(target) do
    case {Map.get(target, :entitlement_kind), Map.get(target, :entitlement_scope_key)} do
      {nil, nil} ->
        :ok

      {kind, scope_key} when not is_nil(kind) and is_binary(scope_key) ->
        :ok

      _ ->
        {:error,
         Error.new("VALIDATION_ERROR", "charged renewal entitlement target pair is incomplete")}
    end
  end

  defp charged_renewal_target_filter(query, target, attempt) do
    case {Map.get(target, :entitlement_kind), Map.get(target, :entitlement_scope_key)} do
      {nil, nil} ->
        Ash.Query.filter(
          query,
          expr(
            is_nil(entitlement_kind) and is_nil(entitlement_scope_key) and
              is_nil(valid_from_at)
          )
        )

      {kind, scope_key} ->
        Ash.Query.filter(
          query,
          expr(
            entitlement_kind == ^kind and entitlement_scope_key == ^scope_key and
              valid_from_at == ^attempt.period_start_at
          )
        )
    end
  end

  defp immediate_access_effect_predecessor(%AccessEffect{} = effect) do
    query =
      AccessEffect
      |> Ash.Query.filter(
        expr(
          subscription_id == ^effect.subscription_id and
            source_version < ^effect.source_version
        )
      )
      |> Ash.Query.sort(source_version: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [predecessor]} -> {:ok, predecessor}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp datetime_equal?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp datetime_equal?(_, _), do: false

  defp maybe_establish_immediate_cancellation_access_effect(:now, %Subscription{} = canceled) do
    with {:ok, funded_revision} <- fetch_plan_revision(canceled.current_plan_revision_id),
         {:ok, target} <-
           AccessEffectTargetOrder.derive_cancel_now_target(canceled, funded_revision),
         attrs <-
           Map.merge(
             %{
               subscription_id: canceled.id,
               source_version: canceled.aggregate_version
             },
             target
           ),
         {:ok, input} <- EstablishAccessEffectInput.new(attrs),
         {:ok, effect} <- establish_access_effect_for_system(input) do
      {:ok,
       %{
         access_effect: %{id: effect.id, disposition: effect.disposition},
         membership_access_ended_email?: funded_revision.entitlement_kind == :membership_access
       }}
    end
  end

  defp maybe_establish_immediate_cancellation_access_effect(_effective_mode, _canceled),
    do: {:ok, nil}

  defp ensure_cancel_now_source_state(:now, %Subscription{status: status})
       when status in [:active, :past_due, :suspended],
       do: :ok

  defp ensure_cancel_now_source_state(:now, %Subscription{}) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "cancel-now requires an active, past_due, or suspended Subscription"
     )}
  end

  defp ensure_cancel_now_source_state(_effective_mode, %Subscription{}), do: :ok

  defp terminalize_late_reconciled_cancellation(
         %Subscription{} = previous,
         %Subscription{} = updated,
         %RenewalAttempt{} = attempt
       ) do
    awaiting_same_attempt? =
      previous.cancel_at_period_end and
        previous.cancel_after_renewal_attempt_id == attempt.id and
        updated.cancel_at_period_end and
        updated.cancel_after_renewal_attempt_id == nil and
        updated.cancel_at_period_end_at == attempt.period_end_at

    if awaiting_same_attempt?,
      do: terminalize_late_paid_cancellation(updated, attempt),
      else: {:ok, :applied, updated, []}
  end

  defp terminalize_late_paid_cancellation(updated, attempt) do
    case database_boundary_reached?(attempt.period_end_at) do
      {:ok, true} ->
        terminalize_reconciled_cancellation_at_boundary(updated, attempt)

      {:ok, false} ->
        {:ok, :applied, updated, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminalize_reconciled_cancellation_at_boundary(updated, attempt) do
    case terminalize_scheduled_cancellation_in_transaction(
           updated.id,
           attempt.period_end_at,
           nil
         ) do
      {:canceled, canceled, notifications} ->
        {:ok, :scheduled_cancellation, canceled, notifications}

      :noop ->
        {:error,
         Error.new(
           "STALE_RECORD",
           "late paid cancellation target changed during reconciliation"
         )}
    end
  end

  defp establish_charged_renewal_access_effect(
         %Subscription{} = renewed,
         %RenewalAttempt{} = attempt,
         target
       ) do
    attrs = AccessEffectTargetOrder.charged_renewal_establish_attrs(renewed, attempt, target)

    with {:ok, input} <- EstablishAccessEffectInput.new(attrs) do
      establish_access_effect_for_system(input)
    end
  end

  defp lock_reconciliation_contract_change(nil), do: {:ok, nil}

  defp lock_reconciliation_contract_change(id) do
    query = ContractChange |> Ash.Query.filter(expr(id == ^id)) |> Ash.Query.lock("FOR UPDATE")

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %ContractChange{} = change} -> {:ok, change}
      {:ok, nil} -> {:error, Error.new("VALIDATION_ERROR", "ContractChange was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp validate_reconciliation_contract_change(nil, _subscription, _attempt), do: :ok

  defp validate_reconciliation_contract_change(%ContractChange{} = change, subscription, attempt) do
    if reconciliation_contract_change_identity_matches?(change, subscription, attempt) and
         reconciliation_contract_change_target_matches?(change, attempt) and
         change.status in [:bound_to_renewal, :applied],
       do: :ok,
       else:
         {:error, Error.new("VALIDATION_ERROR", "ContractChange does not match charged renewal")}
  end

  defp reconciliation_contract_change_identity_matches?(change, subscription, attempt) do
    change.subscription_id == subscription.id and subscription.id == attempt.subscription_id
  end

  defp reconciliation_contract_change_target_matches?(change, attempt) do
    change.target_plan_revision_id == attempt.plan_revision_id and
      change.target_variant_id == attempt.variant_id and
      change.target_quantity == attempt.quantity and
      change.target_amount_minor == attempt.amount_minor and
      change.target_currency == attempt.currency and
      DateTime.compare(change.effective_at, attempt.period_start_at) == :eq
  end

  defp exact_reconciliation_replay(subscription, change, attempt, revision, target) do
    if reconciliation_subscription_exact?(subscription, attempt, revision, target) do
      if is_nil(change) or change.status == :applied do
        {:continue, :replay}
      else
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "charged renewal is exact but ContractChange is not applied"
         )}
      end
    else
      if change && change.status == :applied do
        {:error,
         Error.new("VALIDATION_ERROR", "applied ContractChange conflicts with Subscription")}
      else
        {:continue, :apply}
      end
    end
  end

  defp reconciliation_subscription_exact?(subscription, attempt, revision, target) do
    reconciliation_period_matches?(subscription, attempt) and
      reconciliation_plan_matches?(subscription, attempt, revision) and
      reconciliation_variant_quantity_matches?(subscription, attempt) and
      reconciliation_price_matches?(subscription, attempt) and
      subscription.membership_key == target.membership_key
  end

  defp reconciliation_period_matches?(subscription, attempt) do
    subscription.current_period_start_at == attempt.period_start_at and
      subscription.current_period_end_at == attempt.period_end_at and
      subscription.next_renewal_at == attempt.period_end_at
  end

  defp reconciliation_plan_matches?(subscription, attempt, revision) do
    subscription.current_plan_revision_id == attempt.plan_revision_id and
      subscription.subscription_plan_id == revision.subscription_plan_id
  end

  defp reconciliation_variant_quantity_matches?(subscription, attempt) do
    subscription.variant_id == attempt.variant_id and subscription.quantity == attempt.quantity
  end

  defp reconciliation_price_matches?(subscription, attempt) do
    subscription.renewal_amount_minor == attempt.amount_minor and
      subscription.renewal_currency == attempt.currency
  end

  defp ensure_reconciliation_period_boundary(subscription, attempt) do
    cond do
      subscription.id != attempt.subscription_id ->
        {:error, Error.new("VALIDATION_ERROR", "RenewalAttempt belongs to another Subscription")}

      not is_nil(subscription.current_dunning_renewal_attempt_id) and
          (subscription.status not in [:past_due, :suspended] or
             subscription.current_dunning_renewal_attempt_id != attempt.id) ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "paid RenewalAttempt does not own the current dunning episode"
         )}

      DateTime.compare(subscription.current_period_end_at, attempt.period_start_at) != :eq ->
        {:error, Error.new("VALIDATION_ERROR", "renewal period is stale or out of order")}

      true ->
        :ok
    end
  end

  defp ensure_reconciliation_no_future_target(subscription, bound_change, attempt) do
    if is_nil(subscription.current_contract_change_id) do
      ensure_no_future_target_for_renewal(subscription)
    else
      with {:ok, %ContractChange{} = queued_target} <- current_contract_change(subscription) do
        ensure_reconciliation_future_target(queued_target, bound_change, attempt, subscription)
      end
    end
  end

  defp ensure_reconciliation_future_target(target, bound_change, attempt, subscription) do
    with true <- DateTime.compare(target.effective_at, attempt.period_end_at) == :eq,
         :ok <-
           ensure_reconciliation_future_target_predecessor(
             target,
             bound_change,
             subscription.id
           ),
         {:ok, revision} <- fetch_plan_revision(target.target_plan_revision_id),
         true <- reconciliation_target_projection_matches?(subscription, target, revision) do
      :ok
    else
      false -> {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_reconciliation_future_target_predecessor(
         %ContractChange{} = target,
         %ContractChange{} = bound_change,
         subscription_id
       ) do
    query =
      ContractChange
      |> Ash.Query.filter(
        expr(
          subscription_id == ^subscription_id and
            ordering_version >= ^bound_change.ordering_version and
            ordering_version <= ^target.ordering_version
        )
      )
      |> Ash.Query.sort(ordering_version: :asc)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, changes} ->
        validate_reconciliation_contract_change_lineage(
          changes,
          bound_change,
          target,
          subscription_id
        )

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_reconciliation_future_target_predecessor(
         %ContractChange{} = target,
         nil,
         subscription_id
       ) do
    case latest_contract_change_before(subscription_id, target.ordering_version) do
      {:ok, nil} when is_nil(target.predecessor_contract_change_id) ->
        :ok

      {:ok, %ContractChange{id: predecessor_id}}
      when target.predecessor_contract_change_id == predecessor_id ->
        :ok

      {:ok, _mismatched_predecessor} ->
        {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_reconciliation_contract_change_lineage(
         [first | _] = changes,
         %ContractChange{} = bound_change,
         %ContractChange{} = target,
         subscription_id
       ) do
    last = List.last(changes)

    valid_lineage? =
      reconciliation_lineage_endpoints_match?(first, last, bound_change, target, subscription_id) and
        reconciliation_lineage_links_match?(changes, subscription_id) and
        reconciliation_lineage_statuses_valid?(changes)

    if valid_lineage?,
      do: :ok,
      else: {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}
  end

  defp validate_reconciliation_contract_change_lineage(
         _changes,
         %ContractChange{},
         %ContractChange{},
         _subscription_id
       ),
       do: {:error, Error.new("VALIDATION_ERROR", @unresolved_contract_message)}

  defp reconciliation_lineage_endpoints_match?(first, last, bound_change, target, subscription_id) do
    bound_change.subscription_id == subscription_id and
      first.id == bound_change.id and
      first.ordering_version == bound_change.ordering_version and
      first.status in [:bound_to_renewal, :applied] and
      target.subscription_id == subscription_id and
      target.ordering_version > bound_change.ordering_version and
      last.id == target.id and
      last.ordering_version == target.ordering_version and
      last.status == :queued
  end

  defp reconciliation_lineage_links_match?(changes, subscription_id) do
    Enum.all?(changes, &(&1.subscription_id == subscription_id)) and
      Enum.all?(Enum.chunk_every(changes, 2, 1, :discard), fn [previous, current] ->
        current.ordering_version > previous.ordering_version and
          current.predecessor_contract_change_id == previous.id
      end)
  end

  defp reconciliation_lineage_statuses_valid?(changes) do
    last_index = length(changes) - 1

    Enum.all?(Enum.with_index(changes), fn
      {_change, 0} -> true
      {change, ^last_index} -> change.status == :queued
      {change, _index} -> change.status == :superseded
    end)
  end

  defp latest_contract_change_before(subscription_id, ordering_version) do
    query =
      ContractChange
      |> Ash.Query.filter(
        expr(subscription_id == ^subscription_id and ordering_version < ^ordering_version)
      )
      |> Ash.Query.sort(ordering_version: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, [change | _]} -> {:ok, change}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp reconciliation_target_projection_matches?(subscription, target, revision) do
    subscription.pending_subscription_plan_id ==
      if(revision.subscription_plan_id == subscription.subscription_plan_id,
        do: nil,
        else: revision.subscription_plan_id
      ) and
      subscription.pending_variant_id ==
        if(target.target_variant_id == subscription.variant_id,
          do: nil,
          else: target.target_variant_id
        ) and
      subscription.pending_renewal_amount_minor == target.target_amount_minor and
      subscription.pending_renewal_currency == target.target_currency and
      subscription.change_effective_at == target.effective_at
  end

  defp renewal_entitlement_target(attempt) do
    policy = renewal_policy_from_attempt(attempt)
    scope_key = policy.entitlement_scope_key

    membership_key =
      if policy.entitlement_kind == :membership_access and is_binary(scope_key) and
           scope_key != "" do
        scope_key
      end

    %{
      entitlement_kind: policy.entitlement_kind,
      entitlement_scope_key: scope_key,
      membership_key: membership_key
    }
  end

  defp update_reconciled_subscription(subscription, attempt, revision, target) do
    attrs = %{
      current_period_start_at: attempt.period_start_at,
      current_period_end_at: attempt.period_end_at,
      next_renewal_at: attempt.period_end_at,
      current_plan_revision_id: attempt.plan_revision_id,
      subscription_plan_id: revision.subscription_plan_id,
      variant_id: attempt.variant_id,
      quantity: attempt.quantity,
      renewal_amount_minor: attempt.amount_minor,
      renewal_currency: attempt.currency,
      membership_key: target.membership_key,
      dunning_attempt_count: 0,
      next_retry_at: nil,
      retry_suppressed_at: nil
    }

    attrs =
      if subscription.cancel_at_period_end and
           subscription.cancel_after_renewal_attempt_id == attempt.id do
        Map.merge(attrs, %{
          cancel_at_period_end_at: attempt.period_end_at,
          cancel_after_renewal_attempt_id: nil
        })
      else
        attrs
      end

    private_arguments =
      if is_nil(subscription.current_dunning_renewal_attempt_id) do
        %{}
      else
        %{recovery_renewal_attempt_id: attempt.id}
      end

    changeset =
      subscription
      |> Ash.Changeset.for_update(:extend_period, attrs,
        context: %{system?: true},
        private_arguments: private_arguments
      )

    changeset
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:ok, updated} -> {:ok, updated, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp apply_reconciliation_contract_change(nil), do: {:ok, []}

  defp apply_reconciliation_contract_change(%ContractChange{status: :applied}), do: {:ok, []}

  defp apply_reconciliation_contract_change(%ContractChange{} = change) do
    change
    |> Ash.Changeset.for_update(:apply, %{}, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, _change, notifications} -> {:ok, notifications}
      {:ok, _change} -> {:ok, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp sync_charged_renewal_access(lane, effect_id, _subscription, _target)
       when lane in [:ordinary, :suspended_recovery] and is_binary(effect_id) do
    case execute_effective_access_effect_for_system(effect_id) do
      {:ok, outcome}
      when outcome in [:applied, :applied_projection_pending, :superseded, :noop] ->
        :ok

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}

      other ->
        {:error,
         Error.new(
           "INTERNAL_ERROR",
           "EFFECTIVE charged-renewal handoff returned an invalid outcome",
           %{outcome: inspect(other)}
         )}
    end
  end

  defp sync_charged_renewal_access(_lane, _effect_id, _subscription, _target) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "charged-renewal EFFECTIVE AccessEffect handoff classification is missing"
     )}
  end

  defp bounded_due_limit(limit) when is_integer(limit) and limit in 1..500, do: limit
  defp bounded_due_limit(_limit), do: @default_due_limit

  defp database_wall_clock_now do
    case Repo.query("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, now}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
      _ -> {:error, Error.new("INTERNAL_ERROR", "database wall clock is unavailable")}
    end
  end

  defp terminalize_due_scheduled_cancellation_for_system(subscription_id, now_override) do
    case Repo.transaction(fn ->
           terminalize_scheduled_cancellation_in_transaction(
             subscription_id,
             nil,
             now_override
           )
         end) do
      {:ok, :noop} ->
        {:ok, :noop}

      {:ok, {:canceled, subscription, notifications}} ->
        {:ok, {:canceled, subscription, notifications}}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp terminalize_scheduled_cancellation_in_transaction(
         subscription_id,
         expected_boundary_at,
         now_override
       ) do
    case fetch_subscription_for_renewal_locked(subscription_id) do
      {:ok,
       %Subscription{
         status: :active,
         cancel_at_period_end: true,
         cancel_at_period_end_at: %DateTime{} = boundary_at
       } = subscription} ->
        terminalize_if_boundary_current_and_due(
          subscription,
          boundary_at,
          expected_boundary_at,
          now_override
        )

      {:ok, %Subscription{}} ->
        :noop

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp terminalize_if_boundary_current_and_due(
         subscription,
         boundary_at,
         expected_boundary_at,
         now_override
       ) do
    with true <- is_nil(expected_boundary_at) or expected_boundary_at == boundary_at,
         {:ok, now} <- terminalization_now(now_override) do
      if DateTime.compare(now, boundary_at) == :lt do
        :noop
      else
        commit_scheduled_boundary_cancellation(subscription)
      end
    else
      false -> :noop
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp terminalization_now(%DateTime{} = now), do: {:ok, now}
  defp terminalization_now(nil), do: database_wall_clock_now()

  defp terminalization_now(_now),
    do: {:error, Error.new("VALIDATION_ERROR", "terminalization time must be a DateTime")}

  defp commit_scheduled_boundary_cancellation(subscription) do
    with {:ok, canceled, notifications} <-
           subscription
           |> Ash.Changeset.for_update(
             :scheduled_boundary_cancellation_transition,
             %{canceled_reason: "canceled_period_end"},
             context: %{system?: true}
           )
           |> Ash.update(
             domain: Subscriptions,
             authorize?: false,
             context: %{system?: true},
             return_notifications?: true
           )
           |> scheduled_cancellation_update_result(),
         {:ok, input} <-
           EstablishAccessEffectInput.new(%{
             subscription_id: canceled.id,
             source_version: canceled.aggregate_version,
             disposition: :non_effective,
             entitlement_kind: nil,
             entitlement_scope_key: nil,
             valid_from_at: nil,
             valid_until_at: nil,
             source_order_line_item_id: canceled.source_order_line_item_id,
             contract_change_id: canceled.current_contract_change_id,
             plan_revision_id: canceled.current_plan_revision_id
           }),
         {:ok, _effect} <- establish_access_effect_for_system(input) do
      {:canceled, canceled, notifications}
    else
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp scheduled_cancellation_update_result({:ok, subscription, notifications}),
    do: {:ok, subscription, notifications}

  defp scheduled_cancellation_update_result({:ok, subscription}),
    do: {:ok, subscription, []}

  defp scheduled_cancellation_update_result({:error, reason}),
    do: {:error, reason}

  defp missing_scheduled_cancellation_notifications(opts, limit) do
    after_ended_at = Keyword.get(opts, :after_ended_at)
    after_id = Keyword.get(opts, :after_id)

    case Repo.query(
           """
           SELECT s.id::text, s.ended_at, s.current_period_end_at
           FROM subscriptions s
           JOIN subscription_plans sp ON sp.id = s.subscription_plan_id
           WHERE s.status = 'canceled'
             AND s.canceled_reason = 'canceled_period_end'
             AND s.ended_at IS NOT NULL
             AND s.current_period_end_at IS NOT NULL
             AND sp.entitlement_kind = 'membership_access'
             AND (
               $1::timestamptz IS NULL OR
               s.ended_at > $1::timestamptz OR
               (s.ended_at = $1::timestamptz AND s.id > $2::uuid)
             )
             AND (
               NOT EXISTS (
                 SELECT 1
                 FROM email_outboxes eo
                 WHERE eo.subscription_id = s.id
                   AND eo.idempotency_key =
                     'membership_access_ended:sub:' || s.id::text ||
                     ':reason:canceled_period_end:period_end:' ||
                     to_char(
                       s.current_period_end_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                     )
               ) OR EXISTS (
                 SELECT 1
                 FROM email_outboxes eo
                 WHERE eo.subscription_id = s.id
                   AND eo.idempotency_key =
                     'membership_access_ended:sub:' || s.id::text ||
                     ':reason:canceled_period_end:period_end:' ||
                     to_char(
                       s.current_period_end_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                     )
                   AND eo.state = 'pending'
                   AND eo.updated_at <= clock_timestamp() - INTERVAL '5 minutes'
               )
             )
           ORDER BY s.ended_at ASC, s.id ASC
           LIMIT $3
           """,
           [after_ended_at, after_id, limit]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [id, ended_at, current_period_end_at] ->
           %Subscription{
             id: id,
             ended_at: ended_at,
             current_period_end_at: current_period_end_at
           }
         end)}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp notification_replay_cursor(subscriptions, limit) when length(subscriptions) == limit do
    subscription = List.last(subscriptions)
    %{timestamp: subscription.ended_at, id: subscription.id}
  end

  defp notification_replay_cursor(_subscriptions, _limit), do: nil

  defp suspend_boundary_result(subscription, counts) do
    case suspend_due_boundary_for_system(subscription.id) do
      {:ok, {:suspended, suspended, notifications}} ->
        :ok =
          AshNotifications.notify_post_commit(notifications,
            context: %{flow: :failed_payment_boundary_suspension, subscription_id: suspended.id}
          )

        %{counts | suspended: counts.suspended + 1}

      {:ok, {:reconcile, handoff}} ->
        case reconcile_paid_subscription_renewal_for_system(handoff.order_id,
               renewal_attempt_id: handoff.renewal_attempt_id,
               collection_attempt_id: handoff.collection_attempt_id,
               payment_intent_id: handoff.payment_intent_id
             ) do
          {:ok, _result} -> counts
          {:error, _reason} -> %{counts | failed: counts.failed + 1}
        end

      {:ok, :skipped} ->
        counts

      {:error, _reason} ->
        %{counts | failed: counts.failed + 1}
    end
  end

  defp suspend_due_boundary_for_system(subscription_id) do
    case Repo.transaction(fn -> suspend_due_boundary_in_transaction(subscription_id) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp suspend_due_boundary_in_transaction(subscription_id) do
    case fetch_subscription_for_renewal_locked(subscription_id) do
      {:ok,
       %Subscription{
         status: :past_due,
         failed_payment_boundary_at: %DateTime{} = boundary_at
       } = subscription} ->
        case database_boundary_reached?(boundary_at) do
          {:ok, true} -> suspend_if_no_exact_paid_success(subscription)
          {:ok, false} -> :skipped
          {:error, reason} -> Repo.rollback(reason)
        end

      {:ok, _subscription} ->
        :skipped

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp database_boundary_reached?(boundary_at) do
    case Repo.query("SELECT clock_timestamp() >= $1", [boundary_at]) do
      {:ok, %{rows: [[reached?]]}} when is_boolean(reached?) -> {:ok, reached?}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
      _ -> {:error, Error.new("INTERNAL_ERROR", "database boundary clock check failed")}
    end
  end

  defp suspend_if_no_exact_paid_success(subscription) do
    case current_bound_renewal_attempt(subscription) do
      {:ok, %RenewalAttempt{status: :succeeded}} ->
        :skipped

      {:ok, %RenewalAttempt{} = attempt} ->
        case authoritative_success_for_attempt(attempt) do
          {:success, handoff} ->
            {:reconcile, handoff}

          :success_pending ->
            :skipped

          :none ->
            commit_failed_payment_suspension(subscription)
        end

      {:ok, nil} ->
        Repo.rollback(
          Error.new(
            "FAILED_PAYMENT_EVIDENCE_MISSING",
            "due failed-payment boundary has no exact current RenewalAttempt"
          )
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp authoritative_success_for_attempt(attempt) do
    case find_authoritative_success_handoff(attempt) do
      {:success, handoff} ->
        serialize_authoritative_success(attempt, handoff)

      :success_pending ->
        :success_pending

      :none ->
        recheck_authoritative_success(attempt)
    end
  end

  defp recheck_authoritative_success(attempt) do
    with {:ok, application_status} <- cancellation_payment_application_status(attempt) do
      resolve_rechecked_authoritative_success(attempt, application_status)
    end
  end

  defp resolve_rechecked_authoritative_success(attempt, application_status) do
    case find_authoritative_success_handoff(attempt) do
      {:success, handoff} ->
        serialize_authoritative_success(attempt, handoff)

      :success_pending ->
        :success_pending

      :none when application_status == :applied ->
        :success_pending

      :none ->
        :none
    end
  end

  defp find_authoritative_success_handoff(attempt) do
    case RenewalCollectionAttempt.list_for_renewal_attempt(attempt.id,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, collections} ->
        Enum.reduce_while(
          collections,
          :none,
          &collect_authoritative_success_handoff(&1, &2, attempt)
        )

      {:error, _reason} ->
        :success_pending
    end
  end

  defp collect_authoritative_success_handoff(
         %RenewalCollectionAttempt{financial_outcome: :verified_success} = collection,
         :none,
         attempt
       ) do
    validate_authoritative_success_handoff(collection.id, attempt)
  end

  defp collect_authoritative_success_handoff(_collection, :none, _attempt), do: {:cont, :none}

  defp collect_authoritative_success_handoff(_collection, result, _attempt), do: {:halt, result}

  defp validate_authoritative_success_handoff(collection_id, attempt) do
    case RenewalCollectionAttempts.success_handoff_for_system(collection_id) do
      {:ok, handoff}
      when handoff.order_id == attempt.order_id and handoff.renewal_attempt_id == attempt.id ->
        {:halt, {:success, handoff}}

      {:error, _reason} ->
        {:halt, :success_pending}

      _ ->
        {:cont, :none}
    end
  end

  defp serialize_authoritative_success(attempt, handoff) do
    case PaymentsFacade.serialize_renewal_payment_application_for_system(
           %RenewalPaymentApplicationInput{
             order_id: handoff.order_id,
             payment_intent_id: handoff.payment_intent_id
           }
         ) do
      {:ok, :applied} ->
        case find_authoritative_success_handoff(attempt) do
          {:success, current_handoff} -> {:success, current_handoff}
          _ -> :success_pending
        end

      {:ok, :unapplied} ->
        :success_pending

      {:error, _reason} ->
        :success_pending
    end
  end

  defp commit_failed_payment_suspension(subscription) do
    with {:ok, suspended, notifications} <-
           mark_subscription_suspended_in_transaction(subscription, %{}),
         {:ok, _effect} <-
           establish_suspension_access_effect(suspended) do
      {:suspended, suspended, notifications}
    else
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp establish_suspension_access_effect(%Subscription{} = subscription) do
    with {:ok, input} <-
           EstablishAccessEffectInput.new(%{
             subscription_id: subscription.id,
             source_version: subscription.aggregate_version,
             disposition: :non_effective,
             entitlement_kind: nil,
             entitlement_scope_key: nil,
             valid_from_at: nil,
             valid_until_at: nil,
             source_order_line_item_id: subscription.source_order_line_item_id,
             contract_change_id: subscription.current_contract_change_id,
             plan_revision_id: subscription.current_plan_revision_id
           }) do
      establish_access_effect_for_system(input)
    end
  end

  defp mark_subscription_suspended_in_transaction(subscription, attrs) do
    subscription
    |> Ash.Changeset.for_update(
      :mark_suspended_transition,
      Map.take(attrs, [:billing_status_reason, :past_due_since_at, :dunning_attempt_count]),
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, suspended, notifications} when is_list(notifications) ->
        {:ok, suspended, notifications}

      {:ok, suspended} ->
        {:ok, suspended, []}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp mark_attempt_succeeded(attempt, order_id, payment_intent_id) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_succeeded,
      %{order_id: order_id, payment_intent_id: payment_intent_id},
      context: %{system?: true}
    )
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp retry_policy_max_attempts(%{max_retry_attempts: max_retry_attempts})
       when is_integer(max_retry_attempts) and max_retry_attempts >= 0,
       do: {:ok, max_retry_attempts}

  defp retry_policy_max_attempts(_retry_policy) do
    {:error, Error.new("VALIDATION_ERROR", "renewal attempt retry policy is incomplete")}
  end

  defp retry_failure_attrs(
         retry_policy,
         message,
         now,
         past_due_since_at,
         attempt_count,
         max_retry_attempts,
         failed_payment_boundary_at
       ) do
    hard_blocked? = hard_retry_suppressed_reason?(message)

    scheduled_retry =
      scheduled_retry_after_failure(
        past_due_since_at,
        attempt_count,
        max_retry_attempts,
        hard_blocked?,
        retry_policy
      )

    retry_suppressed? =
      retry_failure_suppressed?(
        attempt_count,
        max_retry_attempts,
        hard_blocked? or is_nil(failed_payment_boundary_at),
        scheduled_retry
      )

    %{
      billing_status_reason: message,
      past_due_since_at: past_due_since_at,
      failed_payment_boundary_at: failed_payment_boundary_at,
      dunning_attempt_count: attempt_count,
      next_retry_at: if(retry_suppressed?, do: nil, else: scheduled_retry),
      retry_suppressed_at: if(retry_suppressed?, do: now, else: nil)
    }
  end

  defp failed_payment_boundary_for_first_failure(
         %Subscription{failed_payment_boundary_at: %DateTime{} = boundary_at},
         _retry_policy,
         _past_due_since_at
       ),
       do: boundary_at

  defp failed_payment_boundary_for_first_failure(
         %Subscription{past_due_since_at: nil},
         %{grace_period_days: grace_period_days},
         %DateTime{} = past_due_since_at
       )
       when is_integer(grace_period_days) and grace_period_days >= 0 do
    DateTime.add(past_due_since_at, grace_period_days * 24 * 60 * 60, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp failed_payment_boundary_for_first_failure(
         %Subscription{},
         _retry_policy,
         _past_due_since_at
       ),
       do: nil

  defp scheduled_retry_after_failure(
         _past_due_since_at,
         attempt_count,
         max_retry_attempts,
         _hard_blocked?,
         _retry_policy
       )
       when attempt_count > max_retry_attempts,
       do: :exhausted

  defp scheduled_retry_after_failure(
         _past_due_since_at,
         _attempt_count,
         _max_retry_attempts,
         true,
         _retry_policy
       ),
       do: :exhausted

  defp scheduled_retry_after_failure(
         past_due_since_at,
         attempt_count,
         _max_retry_attempts,
         false,
         retry_policy
       ) do
    Scheduler.next_retry_at(past_due_since_at, attempt_count - 1, retry_policy)
  end

  defp retry_failure_suppressed?(
         attempt_count,
         max_retry_attempts,
         hard_blocked?,
         scheduled_retry
       ) do
    attempt_count > max_retry_attempts or hard_blocked? or scheduled_retry == :exhausted
  end

  defp dunning_anchor(%Subscription{past_due_since_at: nil}, now), do: now
  defp dunning_anchor(%Subscription{past_due_since_at: anchor}, _now), do: anchor

  defp mark_subscription_past_due(subscription, reason) do
    message =
      case reason do
        %Error{code: code} -> code
        other -> inspect(other)
      end

    subscription
    |> Ash.Changeset.for_update(
      :mark_past_due_transition,
      %{
        billing_status_reason: message,
        next_retry_at: nil,
        retry_suppressed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: Subscriptions, authorize?: false, context: %{system?: true})
    |> normalize_subscription_update_result(subscription)
    |> case do
      {:error, %Error{code: "STALE_RECORD"} = error} ->
        {:error, error}

      _ ->
        emit_subscription_dunning_telemetry(
          subscription,
          :past_due,
          subscription.dunning_attempt_count || 0
        )

        :ok
    end
  end

  defp emit_subscription_tick_telemetry(started_at, due_count, result) do
    :telemetry.execute(
      [:store, :subscriptions, :tick],
      %{
        duration: System.monotonic_time() - started_at,
        due_count: due_count,
        success_count: result.success,
        failed_count: result.failed
      },
      %{due_count: due_count}
    )
  end

  defp emit_subscription_renewal_attempt_telemetry(subscription, result, started_at) do
    :telemetry.execute(
      [:store, :subscriptions, :renewal_attempt],
      %{duration: System.monotonic_time() - started_at},
      %{subscription_id: subscription.id, outcome: renewal_attempt_outcome(result)}
    )
  end

  defp renewal_attempt_outcome(:ok), do: :ok
  defp renewal_attempt_outcome({:error, _reason}), do: :error
  defp renewal_attempt_outcome(_result), do: :unknown

  defp emit_subscription_dunning_telemetry(subscription, status, attempt_no) do
    :telemetry.execute(
      [:store, :subscriptions, :dunning],
      %{count: 1},
      %{subscription_id: subscription.id, status: status, attempt_no: attempt_no}
    )
  end

  defp membership_keys_for_plan_ids([]), do: {:ok, []}

  defp membership_keys_for_plan_ids(plan_ids) do
    membership_keys =
      SubscriptionPlan
      |> where(
        [plan],
        plan.id in ^plan_ids and
          plan.entitlement_kind == ^:membership_access and
          not is_nil(plan.entitlement_scope_key)
      )
      |> select([plan], plan.entitlement_scope_key)
      |> Repo.all()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    {:ok, membership_keys}
  end

  defp ensure_membership_user(_user_id, []), do: :ok

  defp ensure_membership_user(user_id, _membership_keys) when is_binary(user_id), do: :ok

  defp ensure_membership_user(_user_id, _membership_keys) do
    {:error, Error.new("VALIDATION_ERROR", "memberships require an authenticated user")}
  end

  defp ensure_no_open_membership_subscription(_user_id, []), do: :ok

  defp ensure_no_open_membership_subscription(user_id, membership_keys) do
    exists? =
      Subscription
      |> where(
        [subscription],
        subscription.user_id == ^user_id and
          subscription.membership_key in ^membership_keys and
          is_nil(subscription.ended_at) and
          subscription.status in ^[:pending, :active, :past_due, :suspended]
      )
      |> select([subscription], subscription.id)
      |> limit(1)
      |> Repo.exists?()

    if exists? do
      {:error,
       Error.new(
         "SUBSCRIPTION_DUPLICATE",
         "you already have an active or pending membership for this access tier"
       )}
    else
      :ok
    end
  end

  defp ensure_no_pending_membership_order(_user_id, []), do: :ok

  defp ensure_no_pending_membership_order(user_id, membership_keys) do
    exists? =
      from(draft in CheckoutDraft,
        join: order in Order,
        on: order.id == draft.order_id,
        join: item in CartItem,
        on: item.cart_id == draft.cart_id,
        join: plan in SubscriptionPlan,
        on: plan.id == item.subscription_plan_id,
        where:
          draft.user_id == ^user_id and
            draft.status == ^:open and
            order.state == ^:pending_payment and
            plan.entitlement_kind == ^:membership_access and
            plan.entitlement_scope_key in ^membership_keys,
        select: draft.id,
        limit: 1
      )
      |> Repo.exists?()

    if exists? do
      {:error,
       Error.new(
         "SUBSCRIPTION_DUPLICATE",
         "you already have a membership checkout awaiting payment for this access tier"
       )}
    else
      :ok
    end
  end

  defp membership_key_for_plan(plan) do
    case {Map.get(plan, :entitlement_kind), Map.get(plan, :entitlement_scope_key)} do
      {:membership_access, scope_key} when is_binary(scope_key) and scope_key != "" ->
        scope_key

      _ ->
        nil
    end
  end

  defp maybe_filter_subscription_status(query, nil), do: query

  defp maybe_filter_subscription_status(query, status),
    do: Ash.Query.filter(query, expr(status == ^status))

  defp maybe_filter_subscription_user(query, nil), do: query

  defp maybe_filter_subscription_user(query, user_id),
    do: Ash.Query.filter(query, expr(user_id == ^user_id))

  defp maybe_filter_subscription_plan_key(subscriptions, nil), do: subscriptions

  defp maybe_filter_subscription_plan_key(subscriptions, plan_key) do
    Enum.filter(subscriptions, fn subscription ->
      case Map.get(subscription, :subscription_plan) do
        %{key: key} when is_binary(key) -> key == plan_key
        _ -> false
      end
    end)
  end

  defp normalize_subscription_update_result({:ok, _} = result, _subscription), do: result

  defp normalize_subscription_update_result({:error, reason} = result, subscription) do
    if StaleWrite.stale_record_error?(reason) do
      _ = reload_subscription_after_stale_update(subscription.id)
    end

    StaleWrite.normalize_update_result(result)
  end

  defp stale_result_or({:error, %Error{code: "STALE_RECORD"} = error}, _fallback),
    do: {:error, error}

  defp stale_result_or(_result, fallback), do: fallback

  defp reload_subscription_after_stale_update(subscription_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(id == ^subscription_id))

    case Ash.read_one(query,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %Subscription{} = subscription} -> subscription
      _ -> nil
    end
  end

  defp execute_effective_access_effect_in_transaction(effect_id) do
    case AccessEffectCurrentnessFence.prove(effect_id) do
      {:ok, evidence} ->
        effect = evidence.access_effect

        if effect.disposition == :effective do
          execute_locked_effective_access_effect(evidence)
        else
          Repo.rollback(
            {:effective_proof_failure,
             Error.new(
               "INVALID_STATE_TRANSITION",
               "EFFECTIVE executor requires an EFFECTIVE AccessEffect"
             )}
          )
        end

      {:error, reason} ->
        Repo.rollback({:effective_proof_failure, reason})
    end
  end

  defp execute_locked_effective_access_effect(
         %{access_effect: %AccessEffect{} = effect} = evidence
       ) do
    cond do
      effect.status in [:applied, :superseded] ->
        :noop

      evidence.status == :stale ->
        supersede_effective_access_effect(effect)

      evidence.status == :current ->
        converge_current_effective_access_effect(evidence)

      true ->
        Repo.rollback(
          {:effective_proof_failure,
           Error.new(
             "INTERNAL_ERROR",
             "AccessEffect currentness proof returned an invalid state"
           )}
        )
    end
  catch
    :throw, {DBConnection, _connection_ref, reason} ->
      Repo.rollback({:effective_execution_failure, reason})
  end

  defp supersede_effective_access_effect(effect) do
    case supersede_older_access_effect(effect) do
      :ok -> {:superseded, effect}
      {:error, reason} -> Repo.rollback({:effective_execution_failure, reason})
    end
  end

  defp converge_current_effective_access_effect(%{
         source: %{subscription_id: subscription_id, user_id: user_id},
         access_effect: %AccessEffect{} = effect
       }) do
    with {:ok, pending_effect} <- access_effect_to_pending(effect),
         {:ok, input} <- effective_source_convergence_input(subscription_id, user_id, effect),
         {:ok, convergence} <- converge_effective_access_source(input),
         {:ok, applied_effect} <-
           mark_effective_access_effect_applied(pending_effect, convergence) do
      {:applied, applied_effect, convergence.projection_user_ids}
    else
      {:error, {:effective_execution_failure, reason}} ->
        Repo.rollback({:effective_execution_failure, reason})

      {:error, reason} ->
        Repo.rollback({:effective_proof_failure, reason})
    end
  end

  defp converge_effective_access_source(input) do
    case safely_converge_subscription_source(input) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:effective_execution_failure, reason}}
    end
  end

  defp mark_effective_access_effect_applied(effect, convergence) do
    case transition_access_effect_with_attrs(
           effect,
           :pending,
           :applied,
           :mark_applied,
           %{projection_user_ids: convergence.projection_user_ids}
         ) do
      {:ok, applied_effect} -> {:ok, applied_effect}
      {:error, reason} -> {:error, {:effective_execution_failure, reason}}
    end
  end

  defp safely_converge_subscription_source(input) do
    EntitlementsFacade.converge_subscription_source_grants_for_system(input)
  rescue
    exception -> {:error, exception}
  catch
    :throw, {DBConnection, _connection_ref, reason} -> {:error, reason}
  end

  defp effective_source_convergence_input(subscription_id, user_id, effect) do
    attrs = %{
      subscription_id: subscription_id,
      user_id: user_id,
      disposition: :effective,
      entitlement_kind: effect.entitlement_kind,
      entitlement_scope_key: effect.entitlement_scope_key,
      valid_from_at: effect.valid_from_at,
      valid_until_at: effect.valid_until_at,
      reason: @effective_access_effect_projection_reason,
      access_effect_id: effect.id,
      source_version: effect.source_version,
      target_fingerprint: effect.target_fingerprint
    }

    case SubscriptionSourceConvergenceInput.new(attrs) do
      {:ok, input} -> {:ok, input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_effective_access_effect_failure(effect_id) do
    case Repo.transaction(fn ->
           record_effective_access_effect_failure_in_transaction(effect_id)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp record_effective_access_effect_failure_in_transaction(effect_id) do
    case AccessEffectCurrentnessFence.prove(effect_id) do
      {:ok, %{access_effect: %AccessEffect{disposition: :effective} = effect} = evidence} ->
        record_effective_access_effect_failure_for_proof(evidence, effect)

      {:ok, _evidence} ->
        Repo.rollback(
          Error.new("INVALID_STATE_TRANSITION", "failure recording requires an EFFECTIVE effect")
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp record_effective_access_effect_failure_for_proof(%{status: :stale}, effect) do
    case supersede_older_access_effect(effect) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_effective_access_effect_failure_for_proof(%{status: :current}, effect) do
    case mark_access_effect_retryable_after_failure(effect) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp execute_non_effective_access_effect_in_transaction(effect_id) do
    case AccessEffectCurrentnessFence.prove(effect_id) do
      {:ok, %{access_effect: %AccessEffect{disposition: :non_effective} = effect} = evidence} ->
        execute_locked_non_effective_access_effect(evidence, effect)

      {:ok, _evidence} ->
        Repo.rollback(
          {:non_effective_proof_failure,
           Error.new(
             "INVALID_STATE_TRANSITION",
             "NON_EFFECTIVE executor requires a NON_EFFECTIVE AccessEffect"
           )}
        )

      {:error, reason} ->
        Repo.rollback({:non_effective_proof_failure, reason})
    end
  end

  defp execute_locked_non_effective_access_effect(evidence, effect) do
    cond do
      effect.status in [:applied, :superseded] ->
        :noop

      effect.status not in [:required, :pending, :failed_retryable] ->
        Repo.rollback(
          {:non_effective_proof_failure,
           invalid_access_effect_transition(effect.status, :pending)}
        )

      evidence.status == :stale ->
        supersede_stale_non_effective_access_effect(effect)

      evidence.status == :current ->
        execute_current_non_effective_access_effect(evidence)

      true ->
        Repo.rollback(
          {:non_effective_proof_failure,
           Error.new("INTERNAL_ERROR", "F0 returned an invalid AccessEffect currentness state")}
        )
    end
  end

  defp supersede_stale_non_effective_access_effect(effect) do
    case supersede_older_access_effect(effect) do
      :ok -> {:superseded, effect}
      {:error, reason} -> Repo.rollback({:non_effective_execution_failure, reason})
    end
  end

  defp execute_current_non_effective_access_effect(%{
         source: %{subscription_id: subscription_id, user_id: user_id},
         access_effect: %AccessEffect{} = effect
       }) do
    with {:ok, subscription} <- fetch_subscription_for_renewal(subscription_id),
         reason when is_binary(reason) <- non_effective_access_effect_reason(subscription),
         {:ok, input} <-
           non_effective_source_convergence_input(subscription_id, user_id, effect, reason) do
      execute_current_non_effective_with_input(effect, input)
    else
      {:error, reason} ->
        Repo.rollback({:non_effective_proof_failure, reason})

      _reason ->
        Repo.rollback(
          {:non_effective_proof_failure,
           Error.new(
             "INVALID_STATE_TRANSITION",
             "current NON_EFFECTIVE AccessEffect lacks persisted revocation-reason evidence"
           )}
        )
    end
  end

  defp execute_current_non_effective_with_input(effect, input) do
    case access_effect_to_pending(effect) do
      {:ok, pending_effect} ->
        converge_and_apply_non_effective_access_effect(input, pending_effect)

      {:error, reason} ->
        Repo.rollback({:non_effective_execution_failure, reason})
    end
  end

  defp converge_and_apply_non_effective_access_effect(input, pending_effect) do
    case safely_converge_subscription_source(input) do
      {:ok, convergence} ->
        finish_non_effective_access_effect(pending_effect, convergence)

      {:error, reason} ->
        Repo.rollback({:non_effective_execution_failure, reason})
    end
  end

  defp finish_non_effective_access_effect(pending_effect, convergence) do
    case mark_non_effective_access_effect_applied(pending_effect, convergence) do
      {:ok, applied_effect} ->
        {:applied, applied_effect, convergence.projection_user_ids}

      {:error, reason} ->
        Repo.rollback({:non_effective_execution_failure, reason})
    end
  end

  defp non_effective_source_convergence_input(subscription_id, user_id, effect, reason) do
    attrs = %{
      subscription_id: subscription_id,
      user_id: user_id,
      disposition: :non_effective,
      entitlement_kind: effect.entitlement_kind,
      entitlement_scope_key: effect.entitlement_scope_key,
      valid_from_at: effect.valid_from_at,
      valid_until_at: effect.valid_until_at,
      reason: reason,
      access_effect_id: effect.id,
      source_version: effect.source_version,
      target_fingerprint: effect.target_fingerprint
    }

    case SubscriptionSourceConvergenceInput.new(attrs) do
      {:ok, input} -> {:ok, input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_non_effective_access_effect_applied(effect, convergence) do
    transition_access_effect_with_attrs(
      effect,
      :pending,
      :applied,
      :mark_applied,
      %{projection_user_ids: convergence.projection_user_ids}
    )
  end

  defp access_effect_to_pending(%AccessEffect{status: :required} = effect),
    do: transition_access_effect(effect, :required, :pending, :mark_pending_from_required)

  defp access_effect_to_pending(%AccessEffect{status: :failed_retryable} = effect),
    do: transition_access_effect(effect, :failed_retryable, :pending, :retry_to_pending)

  defp access_effect_to_pending(%AccessEffect{status: :pending} = effect), do: {:ok, effect}

  defp access_effect_to_pending(%AccessEffect{status: status}) do
    {:error, invalid_access_effect_transition(status, :pending)}
  end

  defp deliver_access_effect_projection(%AccessEffect{} = effect, user_ids, reason)
       when is_list(user_ids) do
    case EntitlementsFacade.invalidate_subscription_source_users_after_commit_for_system(
           user_ids,
           reason
         ) do
      :ok -> mark_access_effect_projection_delivered(effect.id, user_ids)
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_effective_access_effect_reason(%Subscription{status: :past_due}),
    do: "past_due_remove_immediately"

  defp non_effective_access_effect_reason(%Subscription{status: :suspended}),
    do: "grace_expired"

  defp non_effective_access_effect_reason(%Subscription{
         status: :canceled,
         canceled_reason: "canceled_period_end"
       }),
       do: "canceled_period_end"

  defp non_effective_access_effect_reason(%Subscription{
         status: :canceled,
         canceled_reason: "user_request"
       }),
       do: "canceled_now"

  defp non_effective_access_effect_reason(_subscription), do: nil

  defp access_effect_projection_reason(%AccessEffect{disposition: :effective}),
    do: @effective_access_effect_projection_reason

  defp access_effect_projection_reason(%AccessEffect{disposition: :non_effective}),
    do: @non_effective_access_effect_projection_reason

  defp record_non_effective_access_effect_failure(effect_id) do
    case Repo.transaction(fn ->
           record_non_effective_access_effect_failure_in_transaction(effect_id)
         end) do
      {:ok, :ok} -> :ok
      {:ok, :noop} -> :ok
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp record_non_effective_access_effect_failure_in_transaction(effect_id) do
    case AccessEffectCurrentnessFence.prove(effect_id) do
      {:ok, %{access_effect: %AccessEffect{disposition: :non_effective} = effect} = evidence} ->
        record_non_effective_access_effect_failure_for_proof(evidence, effect)

      {:ok, _evidence} ->
        Repo.rollback(
          Error.new(
            "INVALID_STATE_TRANSITION",
            "failure recording requires a NON_EFFECTIVE effect"
          )
        )

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp record_non_effective_access_effect_failure_for_proof(%{status: :stale}, effect) do
    case supersede_older_access_effect(effect) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_non_effective_access_effect_failure_for_proof(%{status: :current}, effect) do
    case mark_access_effect_retryable_after_failure(effect) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_non_effective_access_effect_failure_for_proof(_evidence, _effect), do: :noop

  defp mark_access_effect_projection_delivered(effect_id, expected_user_ids) do
    case Repo.transaction(fn ->
           mark_access_effect_projection_delivered_in_transaction(
             effect_id,
             expected_user_ids
           )
         end) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp mark_access_effect_projection_delivered_in_transaction(effect_id, expected_user_ids) do
    case fetch_access_effect_locked(effect_id) do
      {:ok, effect} -> mark_access_effect_projection_delivered_locked(effect, expected_user_ids)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp mark_access_effect_projection_delivered_locked(effect, expected_user_ids) do
    cond do
      effect.status != :applied or effect.projection_user_ids != expected_user_ids ->
        Repo.rollback(Error.new("STALE_RECORD", "AccessEffect projection evidence changed"))

      match?(%DateTime{}, effect.projection_delivered_at) ->
        :ok

      true ->
        persist_access_effect_projection_delivery(effect)
    end
  end

  defp persist_access_effect_projection_delivery(effect) do
    case database_wall_clock_now() do
      {:ok, delivered_at} ->
        case update_access_effect(effect, :mark_projection_delivered, %{
               projection_delivered_at: delivered_at
             }) do
          {:ok, _updated_effect} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp mark_access_effect_retryable_after_failure(%AccessEffect{status: :required} = effect) do
    with {:ok, pending} <-
           transition_access_effect(effect, :required, :pending, :mark_pending_from_required),
         {:ok, _failed} <-
           transition_access_effect(pending, :pending, :failed_retryable, :mark_failed_retryable) do
      :ok
    end
  end

  defp mark_access_effect_retryable_after_failure(%AccessEffect{status: :pending} = effect) do
    effect
    |> transition_access_effect(:pending, :failed_retryable, :mark_failed_retryable)
    |> result_to_ok()
  end

  defp mark_access_effect_retryable_after_failure(%AccessEffect{status: :failed_retryable}),
    do: :ok

  defp mark_access_effect_retryable_after_failure(_effect), do: :ok

  defp fetch_access_effect(effect_id) do
    query = AccessEffect |> Ash.Query.filter(expr(id == ^effect_id))

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %AccessEffect{} = effect} -> {:ok, effect}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "AccessEffect was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_access_effect_locked(effect_id) do
    query =
      AccessEffect
      |> Ash.Query.filter(expr(id == ^effect_id))
      |> Ash.Query.lock("FOR UPDATE")

    case Ash.read_one(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, %AccessEffect{} = effect} -> {:ok, effect}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "AccessEffect was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp update_access_effect(effect, action, attrs) do
    effect
    |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})
    |> Ash.update(
      domain: Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %AccessEffect{} = updated, notifications} ->
        with :ok <- ensure_no_access_effect_notifiers(notifications), do: {:ok, updated}

      {:ok, %AccessEffect{} = updated} ->
        {:ok, updated}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp list_access_effects_for_system(action, args) do
    query = AccessEffect |> Ash.Query.for_read(action, args)

    case Ash.read(query, domain: Subscriptions, authorize?: false, context: %{system?: true}) do
      {:ok, effects} -> {:ok, effects}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp recovery_effects(opts, stream, as_of, limit) do
    skip_key =
      case stream do
        :execution -> :skip_execution
        :effective_execution -> :skip_effective_execution
        :projection -> :skip_projection
      end

    skip? = Keyword.get(opts, skip_key, false)

    if skip? do
      {:ok, []}
    else
      {action, args} =
        case stream do
          :execution ->
            {:read_recoverable_non_effective_for_system,
             execution_recovery_args(opts, as_of, limit)}

          :effective_execution ->
            {:read_recoverable_effective_for_system,
             effective_execution_recovery_args(opts, as_of, limit)}

          :projection ->
            {:read_pending_projection_repair_for_system,
             projection_recovery_args(opts, as_of, limit)}
        end

      list_access_effects_for_system(action, args)
    end
  end

  defp recovery_as_of(opts) do
    case Keyword.get(opts, :as_of) do
      %DateTime{} = as_of -> {:ok, as_of}
      nil -> database_wall_clock_now()
      _ -> {:error, Error.new("VALIDATION_ERROR", "AccessEffect sweep time is invalid")}
    end
  end

  defp execution_recovery_args(opts, as_of, limit) do
    %{
      through_updated_at: as_of,
      after_updated_at: Keyword.get(opts, :execution_after_updated_at),
      after_id: Keyword.get(opts, :execution_after_id),
      limit: limit
    }
  end

  defp effective_execution_recovery_args(opts, as_of, limit) do
    %{
      through_updated_at: as_of,
      after_updated_at: Keyword.get(opts, :effective_execution_after_updated_at),
      after_id: Keyword.get(opts, :effective_execution_after_id),
      limit: limit
    }
  end

  defp projection_recovery_args(opts, as_of, limit) do
    %{
      through_inserted_at: as_of,
      after_inserted_at: Keyword.get(opts, :projection_after_inserted_at),
      after_id: Keyword.get(opts, :projection_after_id),
      limit: limit
    }
  end

  defp recovery_cursor(effects, limit, timestamp_field) when length(effects) == limit do
    last_effect = List.last(effects)
    %{timestamp: Map.fetch!(last_effect, timestamp_field), id: last_effect.id}
  end

  defp recovery_cursor(_effects, _limit, _timestamp_field), do: nil

  defp validate_target_order_cursor(opts) do
    case {Keyword.get(opts, :after_inserted_at), Keyword.get(opts, :after_id)} do
      {nil, nil} -> :ok
      {%DateTime{}, id} when is_binary(id) -> :ok
      _ -> {:error, Error.new("VALIDATION_ERROR", "AccessEffect target-order cursor is invalid")}
    end
  end

  defp validate_effective_execution_cursor(opts) do
    case {
      Keyword.get(opts, :effective_execution_after_updated_at),
      Keyword.get(opts, :effective_execution_after_id)
    } do
      {nil, nil} ->
        :ok

      {%DateTime{}, id} when is_binary(id) ->
        :ok

      _ ->
        {:error,
         Error.new("VALIDATION_ERROR", "EFFECTIVE AccessEffect recovery cursor is invalid")}
    end
  end

  defp target_order_candidates(opts, as_of, limit) do
    list_access_effects_for_system(:read_target_order_candidates_for_system, %{
      through_inserted_at: as_of,
      after_inserted_at: Keyword.get(opts, :after_inserted_at),
      after_id: Keyword.get(opts, :after_id),
      limit: limit
    })
  end

  defp target_order_cursor(effects, limit) when length(effects) == limit do
    last_effect = List.last(effects)
    %{inserted_at: last_effect.inserted_at, id: last_effect.id}
  end

  defp target_order_cursor(_effects, _limit), do: nil

  defp reconcile_target_order_page(effects) do
    Enum.reduce_while(effects, {:ok, %{repaired: 0, noop: 0, already_covered: 0}}, fn effect,
                                                                                      {:ok,
                                                                                       counts} ->
      case reconcile_target_order_candidate(effect.id) do
        {:ok, :repaired} ->
          {:cont, {:ok, %{counts | repaired: counts.repaired + 1}}}

        {:ok, :newer_effect_present} ->
          {:cont, {:ok, %{counts | noop: counts.noop + 1}}}

        {:ok, :legacy_policy_unprovable} ->
          {:cont, {:ok, %{counts | noop: counts.noop + 1}}}

        {:ok, :terminal_candidate} ->
          {:cont, {:ok, %{counts | noop: counts.noop + 1}}}

        {:ok, :already_covered} ->
          {:cont, {:ok, %{counts | already_covered: counts.already_covered + 1}}}

        {:error, reason} ->
          {:halt, {:error, target_order_page_error(effect, reason)}}
      end
    end)
  end

  defp reconcile_target_order_candidate(effect_id) do
    case Repo.transaction(fn -> reconcile_target_order_candidate_in_transaction(effect_id) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp reconcile_target_order_candidate_in_transaction(effect_id) do
    with {:ok, discovered_candidate} <- fetch_access_effect(effect_id),
         {:ok, subscription} <-
           fetch_subscription_for_renewal_locked(discovered_candidate.subscription_id),
         {:ok, locked_candidate} <- fetch_access_effect_locked(effect_id),
         {:ok, current} <- read_current_access_effect(subscription.id),
         {:ok, derived_or_signal} <- derive_reconciliation_target(subscription) do
      case derived_or_signal do
        :legacy_policy_unprovable ->
          :legacy_policy_unprovable

        derived when is_map(derived) ->
          reconcile_locked_target_order_candidate(
            subscription,
            locked_candidate,
            current,
            derived
          )
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp derive_reconciliation_target(%Subscription{status: :past_due} = subscription) do
    derive_past_due_reconciliation_target(subscription)
  end

  defp derive_reconciliation_target(
         %Subscription{status: :canceled, canceled_reason: "user_request"} = subscription
       ) do
    with {:ok, %PlanRevision{} = revision} <-
           fetch_plan_revision_for_target_order_reconciliation(subscription) do
      AccessEffectTargetOrder.derive_current_target(subscription, revision)
    end
  end

  defp derive_reconciliation_target(%Subscription{} = subscription) do
    with {:ok, revision} <- plan_revision_for_target_order_reconciliation(subscription) do
      AccessEffectTargetOrder.derive_current_target(subscription, revision)
    end
  end

  defp derive_past_due_reconciliation_target(%Subscription{
         current_dunning_renewal_attempt_id: nil
       }) do
    {:ok, :legacy_policy_unprovable}
  end

  defp derive_past_due_reconciliation_target(%Subscription{} = subscription) do
    with {:ok, attempt} <-
           fetch_bound_dunning_renewal_attempt(
             subscription,
             subscription.current_dunning_renewal_attempt_id
           ),
         :ok <- ensure_complete_bound_renewal_attempt(attempt) do
      case renewal_policy_from_attempt(attempt) do
        %{access_on_past_due: :remove_immediately} ->
          AccessEffectTargetOrder.derive_remove_immediately_target(subscription, attempt)

        %{access_on_past_due: :keep_during_grace} ->
          derive_keep_grace_reconciliation_target(subscription, attempt)

        _ ->
          {:error,
           Error.new(
             "TARGET_ORDER_UNPROVABLE",
             "renewal attempt charged-contract past_due policy is incomplete"
           )}
      end
    end
  end

  defp derive_keep_grace_reconciliation_target(subscription, attempt) do
    with {:ok, %PlanRevision{} = revision} <-
           fetch_plan_revision_for_target_order_reconciliation(subscription) do
      AccessEffectTargetOrder.derive_keep_during_grace_target(subscription, attempt, revision)
    end
  end

  defp fetch_bound_dunning_renewal_attempt(%Subscription{id: subscription_id}, attempt_id)
       when is_binary(attempt_id) do
    with {:ok, %RenewalAttempt{subscription_id: attempt_subscription_id} = attempt} <-
           fetch_renewal_attempt_by_id(attempt_id),
         true <- attempt_subscription_id == subscription_id do
      {:ok, attempt}
    else
      false ->
        {:error,
         Error.new(
           "TARGET_ORDER_UNPROVABLE",
           "bound dunning RenewalAttempt does not belong to the locked Subscription"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp reconcile_locked_target_order_candidate(subscription, candidate, current, derived) do
    cond do
      candidate.status in [:applied, :superseded] ->
        :terminal_candidate

      not match?(%AccessEffect{id: id} when id == candidate.id, current) ->
        :newer_effect_present

      AccessEffectTargetOrder.covered?(candidate, derived) ->
        :already_covered

      true ->
        establish_reconciled_target_order_effect(subscription, derived)
    end
  end

  defp establish_reconciled_target_order_effect(subscription, derived) do
    attrs =
      Map.merge(derived, %{
        subscription_id: subscription.id,
        source_version: subscription.aggregate_version
      })

    with {:ok, input} <- EstablishAccessEffectInput.new(attrs),
         {:ok, _effect} <- establish_access_effect_for_system(input) do
      :repaired
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp plan_revision_for_target_order_reconciliation(%Subscription{status: status} = subscription)
       when status in [:active, :past_due],
       do: fetch_plan_revision_for_target_order_reconciliation(subscription)

  defp plan_revision_for_target_order_reconciliation(%Subscription{}), do: {:ok, nil}

  defp fetch_plan_revision_for_target_order_reconciliation(%Subscription{
         current_plan_revision_id: nil
       }),
       do: {:error, Error.new("TARGET_ORDER_UNPROVABLE", "subscription plan revision is missing")}

  defp fetch_plan_revision_for_target_order_reconciliation(%Subscription{} = subscription),
    do: fetch_plan_revision(subscription.current_plan_revision_id)

  defp target_order_page_error(%AccessEffect{} = effect, reason) do
    meta =
      Map.merge(error_meta(reason), %{
        access_effect_id: effect.id,
        subscription_id: effect.subscription_id
      })

    case reason do
      %Error{code: code, message: message, meta: existing} ->
        Error.new(code, message, Map.merge(existing, meta))

      other ->
        Error.new("TARGET_ORDER_BLOCKED", inspect(other), meta)
    end
  end

  defp error_meta(%Error{meta: meta}) when is_map(meta), do: meta
  defp error_meta(_), do: %{}

  defp boundary_cursor(subscriptions, limit) when length(subscriptions) == limit do
    subscription = List.last(subscriptions)

    %{
      timestamp: subscription.failed_payment_boundary_at,
      id: subscription.id
    }
  end

  defp boundary_cursor(_subscriptions, _limit), do: nil

  defp scheduled_cancellation_cursor(subscriptions, limit) when length(subscriptions) == limit do
    subscription = List.last(subscriptions)

    %{timestamp: subscription.cancel_at_period_end_at, id: subscription.id}
  end

  defp scheduled_cancellation_cursor(_subscriptions, _limit), do: nil

  defp execute_effect_result(effect, counts) do
    result =
      case effect.disposition do
        :effective -> execute_effective_access_effect_for_system(effect.id)
        :non_effective -> execute_suspension_access_effect_for_system(effect.id)
      end

    case result do
      {:ok, _result} -> %{counts | completed: counts.completed + 1}
      {:error, _reason} -> %{counts | failed: counts.failed + 1}
    end
  end

  defp repair_effect_projection_result(effect, counts) do
    case repair_suspension_access_effect_projection_for_system(effect.id) do
      :ok -> %{counts | completed: counts.completed + 1}
      {:error, _reason} -> %{counts | failed: counts.failed + 1}
    end
  end

  defp with_access_effect_transaction(fun) do
    case Repo.in_transaction?() do
      true -> fun.()
      false -> run_owned_access_effect_transaction(fun)
    end
  end

  defp run_owned_access_effect_transaction(fun) do
    case Repo.transaction(fn -> transactional_access_effect_result(fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp transactional_access_effect_result(fun) do
    case fun.() do
      {:ok, _value} = result -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp establish_access_effect_in_transaction(input) do
    with {:ok, current_provenance} <- lock_access_effect_subscription(input.subscription_id),
         {:ok, existing} <-
           get_access_effect_for_source_version(input.subscription_id, input.source_version) do
      reuse_or_establish_access_effect(input, current_provenance, existing)
    end
  end

  defp reuse_or_establish_access_effect(input, _current_provenance, %AccessEffect{} = effect) do
    if effect.target_fingerprint == AccessEffect.target_fingerprint(input) do
      {:ok, effect}
    else
      reuse_legacy_v1_access_effect(input, effect)
    end
  end

  defp reuse_or_establish_access_effect(input, current_provenance, nil) do
    with :ok <- validate_access_effect_source_version(input, current_provenance),
         :ok <- validate_access_effect_provenance(input, current_provenance),
         :ok <- validate_access_effect_target_entitlement(input, current_provenance) do
      establish_new_access_effect(input)
    end
  end

  defp reuse_legacy_v1_access_effect(%{valid_from_at: nil} = input, %AccessEffect{} = effect) do
    if effect.target_fingerprint == AccessEffect.legacy_target_fingerprint_v1(input) do
      {:ok, effect}
    else
      access_effect_target_mismatch()
    end
  end

  defp reuse_legacy_v1_access_effect(_input, _effect), do: access_effect_target_mismatch()

  defp access_effect_target_mismatch do
    {:error,
     Error.new(
       "IDEMPOTENCY_KEY_REUSE_MISMATCH",
       "AccessEffect source version was reused with different target evidence"
     )}
  end

  defp validate_access_effect_source_version(input, current_provenance) do
    if input.source_version <= current_provenance.aggregate_version do
      :ok
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "AccessEffect source version cannot exceed the locked Subscription aggregate version"
       )}
    end
  end

  defp establish_new_access_effect(input) do
    with {:ok, current} <- get_current_access_effect_for_subscription(input.subscription_id),
         :ok <- reject_stale_access_effect_version(input, current),
         :ok <- validate_access_effect_temporal_target(input),
         {:ok, created} <- create_access_effect_record(input),
         :ok <- supersede_older_access_effect(current) do
      {:ok, created}
    end
  end

  defp validate_access_effect_temporal_target(
         %{disposition: :effective, entitlement_kind: kind, entitlement_scope_key: scope} = input
       )
       when not is_nil(kind) and not is_nil(scope) do
    validate_effective_access_effect_interval(input)
  end

  defp validate_access_effect_temporal_target(%{valid_from_at: nil}), do: :ok

  defp validate_access_effect_temporal_target(_input) do
    access_effect_temporal_validation_error(
      "start-less AccessEffect targets must have nil valid_from_at"
    )
  end

  defp validate_effective_access_effect_interval(%{valid_from_at: nil}) do
    access_effect_temporal_validation_error(
      "effective AccessEffect targets require valid_from_at"
    )
  end

  defp validate_effective_access_effect_interval(%{valid_until_at: nil}), do: :ok

  defp validate_effective_access_effect_interval(input) do
    if DateTime.compare(input.valid_from_at, input.valid_until_at) == :lt do
      :ok
    else
      access_effect_temporal_validation_error(
        "AccessEffect valid_from_at must be before valid_until_at"
      )
    end
  end

  defp access_effect_temporal_validation_error(message) do
    {:error, Error.new("VALIDATION_ERROR", message)}
  end

  defp lock_access_effect_subscription(subscription_id) do
    case Ecto.UUID.dump(subscription_id) do
      {:ok, dumped_id} ->
        case Repo.query(
               """
               SELECT subscriptions.source_order_line_item_id::text,
                      subscriptions.current_contract_change_id::text,
                      subscriptions.current_plan_revision_id::text,
                      subscriptions.aggregate_version,
                      plan_revisions.entitlement_kind,
                      plan_revisions.entitlement_scope_key
               FROM subscriptions
               LEFT JOIN plan_revisions
                 ON plan_revisions.id = subscriptions.current_plan_revision_id
               WHERE subscriptions.id = $1
               FOR UPDATE OF subscriptions
               """,
               [dumped_id]
             ) do
          {:ok,
           %{
             rows: [
               [
                 line_item_id,
                 contract_change_id,
                 plan_revision_id,
                 aggregate_version,
                 revision_entitlement_kind,
                 revision_entitlement_scope_key
               ]
             ]
           }} ->
            {:ok,
             %{
               source_order_line_item_id: line_item_id,
               contract_change_id: contract_change_id,
               plan_revision_id: plan_revision_id,
               aggregate_version: aggregate_version,
               revision_entitlement_kind: revision_entitlement_kind,
               revision_entitlement_scope_key: revision_entitlement_scope_key
             }}

          {:ok, %{rows: []}} ->
            {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      :error ->
        {:error, Error.new("VALIDATION_ERROR", "subscription id must be a UUID")}
    end
  end

  defp validate_access_effect_provenance(input, current_provenance) do
    target_provenance = %{
      source_order_line_item_id: input.source_order_line_item_id,
      contract_change_id: input.contract_change_id,
      plan_revision_id: input.plan_revision_id
    }

    if target_provenance == Map.take(current_provenance, Map.keys(target_provenance)) do
      :ok
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "AccessEffect provenance must match the Subscription's immutable source evidence"
       )}
    end
  end

  defp validate_access_effect_target_entitlement(input, current_provenance) do
    revision_pair = {
      current_provenance.revision_entitlement_kind,
      current_provenance.revision_entitlement_scope_key
    }

    target_pair = {
      input.entitlement_kind && Atom.to_string(input.entitlement_kind),
      input.entitlement_scope_key
    }

    valid_target? =
      case input.disposition do
        :effective -> target_pair == revision_pair
        :non_effective -> target_pair == {nil, nil} or target_pair == revision_pair
      end

    if valid_target? do
      :ok
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "AccessEffect entitlement target must match its immutable PlanRevision evidence"
       )}
    end
  end

  defp get_access_effect_for_source_version(subscription_id, source_version) do
    query =
      AccessEffect
      |> Ash.Query.for_read(:read_for_subscription_source_version, %{
        subscription_id: subscription_id,
        source_version: source_version
      })

    case Ash.read_one(query,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %AccessEffect{} = effect} -> {:ok, effect}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp get_current_access_effect_for_subscription(subscription_id) do
    query =
      AccessEffect
      |> Ash.Query.for_read(:read_current_for_subscription, %{subscription_id: subscription_id})
      |> Ash.Query.limit(1)

    case Ash.read_one(query,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %AccessEffect{} = effect} -> {:ok, effect}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp read_current_access_effect(subscription_id) do
    get_current_access_effect_for_subscription(subscription_id)
  end

  defp reject_stale_access_effect_version(_input, nil), do: :ok

  defp reject_stale_access_effect_version(input, %AccessEffect{source_version: latest_version})
       when input.source_version < latest_version do
    {:error,
     Error.new(
       "STALE_RECORD",
       "an older AccessEffect source version cannot replace the current target"
     )}
  end

  defp reject_stale_access_effect_version(_input, _current), do: :ok

  defp create_access_effect_record(input) do
    changeset =
      AccessEffect
      |> Ash.Changeset.for_create(:establish, Map.from_struct(input), context: %{system?: true})

    case Ash.create(changeset,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %AccessEffect{} = effect, notifications} ->
        with :ok <- ensure_no_access_effect_notifiers(notifications), do: {:ok, effect}

      {:ok, %AccessEffect{} = effect} ->
        {:ok, effect}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_no_access_effect_notifiers(notifications) when is_list(notifications) do
    if Enum.all?(notifications, fn notification -> notification.for == [] end) do
      :ok
    else
      {:error,
       Error.new(
         "INTERNAL_ERROR",
         "AccessEffect actions must not publish notifications"
       )}
    end
  end

  defp supersede_older_access_effect(nil), do: :ok

  defp supersede_older_access_effect(%AccessEffect{} = effect) do
    with {:ok, status} <- lock_access_effect_status(effect.id) do
      supersede_access_effect_at_status(effect, status)
    end
  end

  defp supersede_access_effect_at_status(_effect, status)
       when status in [:applied, :superseded],
       do: :ok

  defp supersede_access_effect_at_status(effect, :pending) do
    effect
    |> transition_access_effect(:pending, :superseded, :supersede)
    |> result_to_ok()
  end

  defp supersede_access_effect_at_status(effect, :required) do
    transition_access_effect_through_pending(effect, :required, :mark_pending_from_required)
  end

  defp supersede_access_effect_at_status(effect, :failed_retryable) do
    transition_access_effect_through_pending(effect, :failed_retryable, :retry_to_pending)
  end

  defp transition_access_effect_through_pending(effect, from, pending_action) do
    with {:ok, pending} <- transition_access_effect(effect, from, :pending, pending_action),
         {:ok, _superseded} <-
           transition_access_effect(pending, :pending, :superseded, :supersede) do
      :ok
    end
  end

  defp transition_access_effect(%AccessEffect{} = effect, from, to, action) do
    transition_access_effect_with_attrs(effect, from, to, action, %{})
  end

  defp transition_access_effect_with_attrs(%AccessEffect{} = effect, from, to, action, attrs) do
    with {:ok, current_status} <- lock_access_effect_status(effect.id),
         :ok <- ensure_access_effect_transition_status(current_status, from) do
      perform_access_effect_update(effect, action, from, to, attrs)
    end
  end

  defp perform_access_effect_update(effect, action, from, to, attrs) do
    changeset = Ash.Changeset.for_update(effect, action, attrs, context: %{system?: true})

    case Ash.update(changeset,
           domain: Subscriptions,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %AccessEffect{status: ^to} = updated, notifications} ->
        with :ok <- ensure_no_access_effect_notifiers(notifications), do: {:ok, updated}

      {:ok, %AccessEffect{status: ^to} = updated} ->
        {:ok, updated}

      {:ok, _updated, _notifications} ->
        {:error, invalid_access_effect_transition(from, to)}

      {:ok, _updated} ->
        {:error, invalid_access_effect_transition(from, to)}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp lock_access_effect_status(effect_id) do
    case Ecto.UUID.dump(effect_id) do
      {:ok, dumped_id} ->
        case Repo.query("SELECT status FROM access_effects WHERE id = $1 FOR UPDATE", [dumped_id]) do
          {:ok, %{rows: [[status]]}} -> {:ok, access_effect_status(status)}
          {:ok, %{rows: []}} -> {:error, Error.new("NOT_FOUND", "AccessEffect not found")}
          {:error, reason} -> {:error, Normalize.normalize(reason)}
        end

      :error ->
        {:error, Error.new("VALIDATION_ERROR", "AccessEffect id must be a UUID")}
    end
  end

  defp access_effect_status(status) when is_atom(status), do: status
  defp access_effect_status("required"), do: :required
  defp access_effect_status("pending"), do: :pending
  defp access_effect_status("applied"), do: :applied
  defp access_effect_status("failed_retryable"), do: :failed_retryable
  defp access_effect_status("superseded"), do: :superseded

  defp ensure_access_effect_transition_status(status, status), do: :ok

  defp ensure_access_effect_transition_status(current, target) do
    {:error, invalid_access_effect_transition(current, target)}
  end

  defp invalid_access_effect_transition(from, to) do
    Error.new(
      "INVALID_STATE_TRANSITION",
      "AccessEffect cannot transition from #{from} to #{to}"
    )
  end

  defp result_to_ok({:ok, _effect}), do: :ok
  defp result_to_ok({:error, _reason} = error), do: error
end
