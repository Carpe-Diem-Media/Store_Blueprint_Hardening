defmodule Store.Entitlements.Facade do
  @moduledoc """
  Entitlement read/write surfaces used by subscription orchestration.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements
  alias Store.Entitlements.Cache, as: EntitlementsCache
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Entitlements.Queries.SubscriptionSourceVerificationQuery
  alias Store.Entitlements.Queries.UserEntitlementIndexQuery
  alias Store.Entitlements.SourceConvergence
  alias Store.Entitlements.Types.EntitlementSet
  alias Store.Entitlements.Types.SourceConvergenceResult
  alias Store.Repo
  alias Store.Support.Errors.{Error, Normalize}

  @source_convergence_fields [
    :id,
    :user_id,
    :kind,
    :scope_key,
    :source_kind,
    :source_id,
    :status,
    :valid_from_at,
    :valid_to_at,
    :revoked_at,
    :revoked_reason
  ]

  @doc "Reads up to two active Subscription-source grants for each requested source in one query."
  @spec list_active_subscription_source_grants_for_system(SubscriptionSourceVerificationQuery.t()) ::
          {:ok, %{optional(Ecto.UUID.t()) => [map()]}} | {:error, term()}
  def list_active_subscription_source_grants_for_system(
        %SubscriptionSourceVerificationQuery{} = query
      ) do
    with {:ok, canonical_query} <- SubscriptionSourceVerificationQuery.new(Map.from_struct(query)) do
      EntitlementGrant
      |> Ash.ActionInput.for_action(
        :read_active_subscription_sources_for_system,
        Map.from_struct(canonical_query),
        domain: Entitlements,
        context: %{system?: true}
      )
      |> Ash.run_action(domain: Entitlements, authorize?: true)
      |> case do
        {:ok, grants_by_source} -> {:ok, grants_by_source}
        {:error, reason} -> {:error, Normalize.normalize(reason)}
      end
    end
  end

  def list_active_subscription_source_grants_for_system(_query) do
    {:error,
     Error.new("VALIDATION_ERROR", "typed subscription source verification query is required")}
  end

  @spec list_entitlements_for_user(map(), UserEntitlementIndexQuery.t()) ::
          {:ok, [EntitlementGrant.t()]} | {:error, term()}
  def list_entitlements_for_user(actor, %UserEntitlementIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      EntitlementGrant
      |> Ash.Query.for_read(:read_for_user, %{}, actor: actor)
      |> maybe_filter_status(query.status)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Entitlements, actor: actor) do
      {:ok, grants} -> {:ok, grants}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  def list_entitlements_for_user(_actor, _query) do
    {:error, Error.new("VALIDATION_ERROR", "actor and user entitlement query are required")}
  end

  @spec entitlement_set_for_user(map()) :: {:ok, EntitlementSet.t()} | {:error, term()}
  def entitlement_set_for_user(%{id: user_id} = actor) when is_binary(user_id) do
    EntitlementsCache.fetch(user_id, fn ->
      case fetch_active_grants_for_user(actor) do
        {:ok, grants} -> {:commit, build_entitlement_set(user_id, grants)}
        {:error, reason} -> {:ignore, reason}
      end
    end)
    |> normalize_entitlement_set_result()
  end

  def entitlement_set_for_user(_actor) do
    {:error, Error.new("VALIDATION_ERROR", "actor with id is required")}
  end

  @spec issue_subscription_entitlement_for_system(map(), map()) ::
          {:ok, EntitlementGrant.t()} | {:error, term()}
  def issue_subscription_entitlement_for_system(subscription, plan)
      when is_map(subscription) and is_map(plan) do
    entitlement_kind = Map.get(plan, :entitlement_kind)
    entitlement_scope_key = Map.get(plan, :entitlement_scope_key)

    if is_nil(entitlement_kind) or not is_binary(entitlement_scope_key) do
      {:error,
       Error.new("VALIDATION_ERROR", "subscription plan entitlement configuration is missing")}
    else
      valid_to_at = Map.get(subscription, :current_period_end_at)

      attrs = %{
        user_id: Map.get(subscription, :user_id),
        kind: entitlement_kind,
        scope_key: entitlement_scope_key,
        source_kind: :subscription,
        source_id: Map.get(subscription, :id),
        status: :active,
        valid_from_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        valid_to_at: valid_to_at,
        revoked_at: nil,
        revoked_reason: nil
      }

      EntitlementGrant
      |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
      |> Ash.create(domain: Entitlements, authorize?: false, context: %{system?: true})
      |> case do
        {:ok, grant} ->
          _ = maybe_invalidate_user(subscription.user_id, "entitlement_issued")
          {:ok, grant}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def issue_subscription_entitlement_for_system(_subscription, _plan) do
    {:error, Error.new("VALIDATION_ERROR", "subscription and plan are required")}
  end

  @spec issue_subscription_source_grant_strict_for_system(map(), map()) ::
          {:ok,
           %{
             grant: EntitlementGrant.t(),
             notifications: [Ash.Notifier.Notification.t()],
             user_ids: [Ecto.UUID.t()]
           }}
          | {:error, term()}
  @doc """
  Upserts one Subscription-source grant inside the caller's transaction.

  The caller must hold a lock on the current Subscription authority for the full
  transaction. This function returns Ash notifications and user IDs for delivery
  and cache invalidation after commit.
  """
  def issue_subscription_source_grant_strict_for_system(subscription, plan)
      when is_map(subscription) and is_map(plan) do
    if Repo.in_transaction?() do
      entitlement_kind = Map.get(plan, :entitlement_kind)
      entitlement_scope_key = Map.get(plan, :entitlement_scope_key)
      user_id = Map.get(subscription, :user_id)
      subscription_id = Map.get(subscription, :id)

      if is_nil(entitlement_kind) or not is_binary(entitlement_scope_key) do
        {:error,
         Error.new("VALIDATION_ERROR", "subscription plan entitlement configuration is missing")}
      else
        attrs = %{
          user_id: user_id,
          kind: entitlement_kind,
          scope_key: entitlement_scope_key,
          source_kind: :subscription,
          source_id: subscription_id,
          status: :active,
          valid_from_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          valid_to_at: Map.get(subscription, :current_period_end_at),
          revoked_at: nil,
          revoked_reason: nil
        }

        EntitlementGrant
        |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
        |> Ash.create(
          domain: Entitlements,
          authorize?: false,
          context: %{system?: true},
          return_notifications?: true
        )
        |> strict_subscription_grant_issue_result(attrs)
      end
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "subscription grant restoration requires a caller-owned transaction"
       )}
    end
  end

  def issue_subscription_source_grant_strict_for_system(_subscription, _plan) do
    {:error, Error.new("VALIDATION_ERROR", "subscription and plan are required")}
  end

  @spec revoke_subscription_entitlements_for_system(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_subscription_entitlements_for_system(subscription_id, reason \\ nil)

  def revoke_subscription_entitlements_for_system(subscription_id, reason)
      when is_binary(subscription_id) do
    query =
      EntitlementGrant
      |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))

    case Ash.read(query, domain: Entitlements, authorize?: false, context: %{system?: true}) do
      {:ok, grants} ->
        revoked_count =
          Enum.count(grants, fn grant ->
            revoke_grant(grant, reason)
          end)

        if revoked_count > 0 do
          user_ids =
            grants
            |> Enum.map(& &1.user_id)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          Enum.each(user_ids, &maybe_invalidate_user(&1, reason || "entitlement_revoked"))
        end

        {:ok, revoked_count}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def revoke_subscription_entitlements_for_system(_subscription_id, _reason) do
    {:error, Error.new("VALIDATION_ERROR", "subscription_id must be a UUID")}
  end

  @spec revoke_subscription_source_grants_strict_for_system(Ecto.UUID.t(), String.t()) ::
          {:ok, %{notifications: [Ash.Notifier.Notification.t()], user_ids: [Ecto.UUID.t()]}}
          | {:error, term()}
  def revoke_subscription_source_grants_strict_for_system(subscription_id, reason)
      when is_binary(subscription_id) and is_binary(reason) do
    if Repo.in_transaction?() do
      query =
        EntitlementGrant
        |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
        |> Ash.Query.sort(id: :asc)

      case Ash.read(query, domain: Entitlements, authorize?: false, context: %{system?: true}) do
        {:ok, grants} -> revoke_suspension_source_grants(grants, reason)
        {:error, read_error} -> {:error, Normalize.normalize(read_error)}
      end
    else
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "suspension grant revocation requires a caller-owned transaction"
       )}
    end
  end

  def revoke_subscription_source_grants_strict_for_system(_subscription_id, _reason) do
    {:error, Error.new("VALIDATION_ERROR", "subscription_id and reason are required")}
  end

  @spec converge_subscription_source_grants_for_system(SubscriptionSourceConvergenceInput.t()) ::
          {:ok, SourceConvergenceResult.t()} | {:error, term()}
  @doc """
  Converges exact-source grants inside the caller-owned transaction.

  The caller must hold the Subscription source lock for the full transaction and roll it back if
  this function returns an error after a write.
  """
  def converge_subscription_source_grants_for_system(input) do
    if Repo.in_transaction?() do
      validate_and_converge_source_input(input)
    else
      source_convergence_validation_error()
    end
  end

  @spec reconcile_subscription_source_grants_for_system(SubscriptionSourceConvergenceInput.t()) ::
          {:ok, {:repaired | :already_converged, SourceConvergenceResult.t()}} | {:error, term()}
  @doc """
  Repairs exact-source grants inside a caller-owned transaction, skipping writes when the locked
  source rows already match the requested target. The caller must hold the Subscription source
  lock for the full transaction and roll back the transaction if this function returns an error
  after a write.
  """
  def reconcile_subscription_source_grants_for_system(input) do
    if Repo.in_transaction?() do
      validate_and_reconcile_source_input(input)
    else
      source_convergence_validation_error()
    end
  end

  defp validate_and_reconcile_source_input(%SubscriptionSourceConvergenceInput{} = input) do
    case SubscriptionSourceConvergenceInput.new(Map.from_struct(input)) do
      {:ok, validated_input} ->
        reconcile_subscription_source_grants_in_transaction(validated_input)

      {:error, %Error{code: "VALIDATION_ERROR"} = error} ->
        {:error, error}
    end
  end

  defp validate_and_reconcile_source_input(_input), do: source_convergence_validation_error()

  defp reconcile_subscription_source_grants_in_transaction(input) do
    with {:ok, locked_rows} <- lock_subscription_source_grants(input),
         {:ok, source_state} <-
           SourceConvergence.derive_locked_source_state(input, locked_rows) do
      reconcile_locked_source_state(input, source_state, locked_rows)
    end
  end

  defp reconcile_locked_source_state(input, source_state, locked_rows) do
    active_rows = Enum.filter(locked_rows, &(&1.status == :active))

    case SourceConvergence.validate_final_active_set(
           input,
           source_state.matching_target_id,
           active_rows
         ) do
      :ok ->
        result =
          build_source_convergence_result(
            input,
            source_state,
            source_state.matching_target_id
          )

        {:ok, {:already_converged, result}}

      {:error, _reason} ->
        with {:ok, result} <-
               converge_locked_subscription_source(input, source_state, locked_rows) do
          {:ok, {:repaired, result}}
        end
    end
  end

  defp validate_and_converge_source_input(%SubscriptionSourceConvergenceInput{} = input) do
    case SubscriptionSourceConvergenceInput.new(Map.from_struct(input)) do
      {:ok, validated_input} ->
        converge_subscription_source_grants_in_transaction(validated_input)

      {:error, %Error{code: "VALIDATION_ERROR"} = error} ->
        {:error, error}
    end
  end

  defp validate_and_converge_source_input(_input), do: source_convergence_validation_error()

  defp converge_subscription_source_grants_in_transaction(input) do
    with {:ok, locked_rows} <- lock_subscription_source_grants(input),
         {:ok, source_state} <-
           SourceConvergence.derive_locked_source_state(input, locked_rows) do
      converge_locked_subscription_source(input, source_state, locked_rows)
    end
  end

  defp converge_locked_subscription_source(input, source_state, locked_rows) do
    with {:ok, target_grant_id} <- converge_source_target(input, source_state),
         :ok <-
           revoke_active_non_targets(input, source_state, target_grant_id, locked_rows),
         {:ok, active_rows} <- read_final_active_subscription_grants(input),
         :ok <-
           SourceConvergence.validate_final_active_set(input, target_grant_id, active_rows) do
      {:ok, build_source_convergence_result(input, source_state, target_grant_id)}
    end
  end

  defp build_source_convergence_result(input, source_state, target_grant_id) do
    %SourceConvergenceResult{
      mode: source_state.mode,
      subscription_id: input.subscription_id,
      target_grant_id: target_grant_id,
      revoked_grant_ids: source_state.active_non_target_ids,
      projection_user_ids: source_state.projection_user_ids
    }
  end

  defp lock_subscription_source_grants(input) do
    query =
      EntitlementGrant
      |> Ash.Query.filter(
        expr(source_kind == :subscription and source_id == ^input.subscription_id)
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.select(@source_convergence_fields)
      |> Ash.Query.lock(:for_update)

    case Ash.read(query,
           domain: Entitlements,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
      _result -> source_convergence_internal_error()
    end
  end

  defp converge_source_target(_input, %{mode: :empty, matching_target_id: nil}),
    do: {:ok, nil}

  defp converge_source_target(
         input,
         %{mode: :pair, matching_target_id: matching_target_id}
       ) do
    attrs = %{
      user_id: input.user_id,
      kind: input.entitlement_kind,
      scope_key: input.entitlement_scope_key,
      source_id: input.subscription_id,
      valid_from_at: input.valid_from_at,
      valid_to_at: input.valid_until_at
    }

    changeset =
      EntitlementGrant
      |> Ash.Changeset.for_create(:converge_source_target, attrs, context: %{system?: true})

    case Ash.create(changeset,
           domain: Entitlements,
           authorize?: false,
           return_notifications?: true,
           context: %{system?: true}
         ) do
      {:ok, %EntitlementGrant{} = target, notifications} when is_list(notifications) ->
        source_convergence_target_result(input, target, matching_target_id, notifications)

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}

      _result ->
        source_convergence_internal_error()
    end
  end

  defp converge_source_target(_input, _source_state),
    do: source_convergence_internal_error()

  defp source_convergence_target_result(input, target, matching_target_id, notifications) do
    with :ok <- ensure_no_source_convergence_notifications(notifications),
         true <- is_nil(matching_target_id) or target.id == matching_target_id,
         :ok <- SourceConvergence.validate_final_active_set(input, target.id, [target]) do
      {:ok, target.id}
    else
      {:error, _error} = error -> error
      _result -> source_convergence_internal_error()
    end
  end

  defp ensure_no_source_convergence_notifications(notifications) do
    if Enum.all?(notifications, &(&1.for == [])) do
      :ok
    else
      source_convergence_internal_error()
    end
  end

  defp revoke_active_non_targets(_input, %{active_non_target_ids: []}, _target_grant_id, _rows),
    do: :ok

  defp revoke_active_non_targets(
         input,
         %{mode: mode, active_non_target_ids: [first_grant_id | _rest]},
         target_grant_id,
         locked_rows
       ) do
    with {:ok, precheck_data} <- find_atomic_revoke_precheck_data(first_grant_id, locked_rows),
         :ok <- atomic_revoke_precheck(input.reason, precheck_data),
         {:ok, query} <- active_source_revoke_query(input, mode, target_grant_id) do
      execute_atomic_source_revoke(query, input.reason)
    end
  end

  defp find_atomic_revoke_precheck_data(grant_id, locked_rows) do
    case Enum.find(locked_rows, &(&1.id == grant_id)) do
      %EntitlementGrant{} = grant -> {:ok, grant}
      _grant -> source_convergence_internal_error()
    end
  end

  defp atomic_revoke_precheck(reason, data) do
    result =
      Ash.Changeset.fully_atomic_changeset(
        EntitlementGrant,
        :revoke_for_source_convergence,
        %{revoked_reason: reason},
        data: data,
        domain: Entitlements,
        authorize?: false,
        context: %{system?: true}
      )

    case result do
      %Ash.Changeset{
        valid?: true,
        atomics: atomics,
        attributes: attributes
      }
      when is_list(atomics) and is_map(attributes) ->
        if Keyword.has_key?(atomics, :revoked_at) and
             Map.get(attributes, :status) == :revoked and
             Map.get(attributes, :revoked_reason) == reason do
          :ok
        else
          source_convergence_internal_error()
        end

      _not_fully_atomic ->
        source_convergence_internal_error()
    end
  end

  defp active_source_revoke_query(input, :empty, nil) do
    {:ok, active_subscription_source_query(input)}
  end

  defp active_source_revoke_query(input, :pair, target_grant_id)
       when is_binary(target_grant_id) do
    query =
      input
      |> active_subscription_source_query()
      |> Ash.Query.filter(expr(id != ^target_grant_id))

    {:ok, query}
  end

  defp active_source_revoke_query(_input, _mode, _target_grant_id),
    do: source_convergence_internal_error()

  defp active_subscription_source_query(input) do
    EntitlementGrant
    |> Ash.Query.filter(
      expr(
        source_kind == :subscription and source_id == ^input.subscription_id and status == :active
      )
    )
  end

  defp execute_atomic_source_revoke(query, reason) do
    result =
      Ash.bulk_update(query, :revoke_for_source_convergence, %{revoked_reason: reason},
        strategy: [:atomic],
        return_records?: false,
        return_errors?: true,
        notify?: false,
        authorize?: false,
        domain: Entitlements,
        context: %{system?: true}
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: status} ->
        {:error,
         Error.new(
           "INTERNAL_ERROR",
           "subscription source revoke did not complete atomically",
           %{bulk_status: status}
         )}
    end
  end

  defp read_final_active_subscription_grants(input) do
    query =
      input
      |> active_subscription_source_query()
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(2)
      |> Ash.Query.select(@source_convergence_fields)

    case Ash.read(query,
           domain: Entitlements,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
      _result -> source_convergence_internal_error()
    end
  end

  defp source_convergence_validation_error do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "subscription source convergence requires a caller-owned transaction and typed input"
     )}
  end

  defp source_convergence_internal_error do
    {:error, Error.new("INTERNAL_ERROR", "subscription source convergence failed closed")}
  end

  @spec invalidate_subscription_source_users_after_commit_for_system(
          [Ecto.UUID.t()],
          String.t()
        ) ::
          :ok
          | {:error, Error.t() | %{user_id: Ecto.UUID.t(), step: atom(), reason: term()}}
  def invalidate_subscription_source_users_after_commit_for_system(user_ids, reason)
      when is_list(user_ids) and is_binary(reason) do
    if Repo.in_transaction?() do
      {:error,
       Error.new(
         "VALIDATION_ERROR",
         "subscription source projection invalidation requires a post-commit call"
       )}
    else
      invalidate_subscription_source_users(user_ids, reason)
    end
  end

  defp invalidate_subscription_source_users(user_ids, reason) do
    user_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn user_id, :ok ->
      maybe_invalidate_user(user_id, reason)
      |> reduce_invalidation_result()
    end)
  end

  defp reduce_invalidation_result(:ok), do: {:cont, :ok}
  defp reduce_invalidation_result({:error, _reason} = error), do: {:halt, error}

  defp revoke_suspension_source_grants(grants, reason) do
    user_ids =
      grants
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(grants, {:ok, []}, fn grant, {:ok, notifications} ->
      case revoke_suspension_source_grant(grant, reason) do
        {:ok, grant_notifications} ->
          {:cont, {:ok, notifications ++ grant_notifications}}

        {:error, mutation_error} ->
          {:halt, {:error, Normalize.normalize(mutation_error)}}
      end
    end)
    |> case do
      {:ok, notifications} -> {:ok, %{notifications: notifications, user_ids: user_ids}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp strict_subscription_grant_issue_result(
         {:ok, %EntitlementGrant{} = grant, notifications},
         attrs
       )
       when is_list(notifications) do
    strict_subscription_grant_issue_result({:ok, grant}, attrs, notifications)
  end

  defp strict_subscription_grant_issue_result({:ok, %EntitlementGrant{} = grant}, attrs) do
    strict_subscription_grant_issue_result({:ok, grant}, attrs, [])
  end

  defp strict_subscription_grant_issue_result({:error, reason}, _attrs) do
    {:error, Normalize.normalize(reason)}
  end

  defp strict_subscription_grant_issue_result(
         {:ok, %EntitlementGrant{} = grant},
         attrs,
         notifications
       ) do
    if subscription_grant_matches_issue?(grant, attrs) do
      {:ok, %{grant: grant, notifications: notifications, user_ids: [grant.user_id]}}
    else
      {:error,
       Error.new(
         "INTERNAL_ERROR",
         "subscription entitlement did not converge to the requested active grant",
         %{grant_id: grant.id, status: grant.status}
       )}
    end
  end

  defp subscription_grant_matches_issue?(%EntitlementGrant{} = grant, attrs) do
    grant.user_id == attrs.user_id and
      grant.kind == attrs.kind and
      grant.scope_key == attrs.scope_key and
      grant.source_kind == :subscription and
      grant.source_id == attrs.source_id and
      grant.status == :active
  end

  defp revoke_suspension_source_grant(%EntitlementGrant{status: :active} = grant, reason) do
    attrs = if reason == "", do: %{}, else: %{revoked_reason: reason}

    grant
    |> Ash.Changeset.for_update(:revoke, attrs, context: %{system?: true})
    |> Ash.update(
      domain: Entitlements,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %EntitlementGrant{status: :revoked}, notifications} when is_list(notifications) ->
        {:ok, notifications}

      {:ok, %EntitlementGrant{status: :revoked}} ->
        {:ok, []}

      {:ok, updated, _notifications} ->
        {:error, suspension_grant_convergence_error(updated)}

      {:ok, updated} ->
        {:error, suspension_grant_convergence_error(updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revoke_suspension_source_grant(%EntitlementGrant{}, _reason), do: {:ok, []}

  defp suspension_grant_convergence_error(%EntitlementGrant{} = grant) do
    Error.new(
      "INTERNAL_ERROR",
      "subscription grant did not converge to revoked",
      %{grant_id: grant.id, status: grant.status}
    )
  end

  defp revoke_grant(grant, reason) do
    attrs =
      if is_binary(reason) and reason != "" do
        %{revoked_reason: reason}
      else
        %{}
      end

    case grant
         |> Ash.Changeset.for_update(:revoke, attrs, context: %{system?: true})
         |> Ash.update(domain: Entitlements, authorize?: false, context: %{system?: true}) do
      {:ok, _updated} -> true
      {:error, _reason} -> false
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: Ash.Query.filter(query, expr(status == ^status))

  defp fetch_active_grants_for_user(%{id: user_id}) do
    query =
      EntitlementGrant
      |> Ash.Query.filter(expr(user_id == ^user_id and status == :active))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)

    case Ash.read(query, domain: Entitlements, authorize?: false, context: %{system?: true}) do
      {:ok, grants} -> {:ok, grants}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp build_entitlement_set(user_id, grants) do
    fetched_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %EntitlementSet{
      user_id: user_id,
      grants: grants,
      fetched_at: fetched_at,
      expires_at: DateTime.add(fetched_at, div(EntitlementsCache.ttl_ms(), 1_000), :second)
    }
  end

  defp normalize_entitlement_set_result({:ok, %EntitlementSet{} = set}), do: {:ok, set}
  defp normalize_entitlement_set_result({:ok, reason}), do: {:error, Normalize.normalize(reason)}

  defp normalize_entitlement_set_result({:error, reason}),
    do: {:error, Normalize.normalize(reason)}

  defp maybe_invalidate_user(user_id, reason) when is_binary(user_id) do
    EntitlementsCache.invalidate_and_broadcast_post_commit(user_id, reason)
  end

  defp maybe_invalidate_user(_user_id, _reason), do: :ok
end
