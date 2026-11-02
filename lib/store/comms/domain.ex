defmodule Store.Comms do
  @moduledoc """
  Outbound communications domain for transactional email delivery.
  """

  import Ash.Expr
  import Ecto.Query

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Accounts.User
  alias Store.Comms.{EmailOutbox, Providers, Templates}
  alias Store.Orders.Order
  alias Store.Payments.Refund
  alias Store.Repo
  alias Store.Subscriptions.{Scheduler, Subscription, SubscriptionPlan}
  alias Store.Workers.DeliverEmailOutboxWorker

  use Ash.Domain

  @stale_processing_timeout_seconds 15 * 60
  @identity_recipient_email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  resources do
    resource(Store.Comms.EmailOutbox)
  end

  @spec enqueue_identity_link_confirmation_for_system(
          User.t(),
          term(),
          term(),
          atom() | String.t(),
          keyword()
        ) :: {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_identity_link_confirmation_for_system(
        %User{} = user,
        confirmation_url,
        confirmation_token,
        identity_provider,
        opts \\ []
      )
      when is_list(opts) do
    with {:ok, to_email} <- normalize_identity_recipient_email(user.email),
         {:ok, provider_key, provider_name} <- normalize_identity_provider(identity_provider),
         {:ok, url} <- normalize_confirmation_url(confirmation_url),
         {:ok, jti} <- identity_confirmation_jti(user, confirmation_token),
         {:ok, email_provider} <- resolve_provider(opts, :email_provider),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: nil,
             refund_id: nil,
             subscription_id: nil,
             template_kind: :identity_link_confirmation,
             to_email: to_email,
             subject: "Confirm linking your #{provider_key} login",
             idempotency_key: "identity_link_confirmation:#{provider_key}:#{jti}",
             provider: email_provider,
             template_assigns: %{
               "confirmation_url" => url,
               "identity_provider" => provider_name
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec enqueue_order_receipt_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_order_receipt_for_system(order_id, opts \\ []) when is_binary(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: nil,
             template_kind: :order_receipt,
             to_email: to_email,
             subject: "Order receipt #{order.order_ref}",
             idempotency_key: "order_receipt:order:#{order.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "amount_minor" => order.grand_total_minor || 0,
               "currency" => order.currency_code || "USD"
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec enqueue_refund_requested_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_refund_requested_for_system(refund_id, opts \\ []) when is_binary(refund_id) do
    with {:ok, refund} <- fetch_refund(refund_id),
         {:ok, order} <- fetch_order(refund.order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: refund.id,
             template_kind: :refund_requested,
             to_email: to_email,
             subject: "Refund requested for order #{order.order_ref}",
             idempotency_key: "refund_requested:refund:#{refund.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "refund_id" => refund.id,
               "amount_minor" => refund.requested_amount_minor,
               "currency" => refund.currency
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec enqueue_refund_processed_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_refund_processed_for_system(refund_id, opts \\ []) when is_binary(refund_id) do
    with {:ok, refund} <- fetch_refund(refund_id),
         {:ok, order} <- fetch_order(refund.order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: refund.id,
             template_kind: :refund_processed,
             to_email: to_email,
             subject: "Refund processed for order #{order.order_ref}",
             idempotency_key: "refund_processed:refund:#{refund.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "refund_id" => refund.id,
               "amount_minor" => refund.requested_amount_minor,
               "currency" => refund.currency
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec enqueue_payment_authentication_required_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_payment_authentication_required_for_system(order_id, opts \\ [])
      when is_binary(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         action_url when is_binary(action_url) and action_url != "" <-
           Keyword.get(opts, :action_url),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: nil,
             template_kind: :payment_authentication_required,
             to_email: to_email,
             subject: "Payment authentication required for order #{order.order_ref}",
             idempotency_key: "payment_authentication_required:order:#{order.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "action_url" => action_url,
               "provider_client_secret" => Keyword.get(opts, :provider_client_secret),
               "support_email" => support_email()
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    else
      nil -> {:error, :missing_action_url}
      "" -> {:error, :missing_action_url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_action_url}
    end
  end

  @spec enqueue_membership_renewal_reminder_for_system(
          String.t(),
          String.t(),
          pos_integer(),
          keyword()
        ) ::
          {:ok, EmailOutbox.t()} | {:ok, :skipped} | {:error, term()}
  def enqueue_membership_renewal_reminder_for_system(
        subscription_id,
        renewal_key,
        days_before,
        opts \\ []
      )
      when is_binary(subscription_id) and is_binary(renewal_key) and is_integer(days_before) and
             days_before > 0 do
    with {:ok, subscription} <- fetch_subscription(subscription_id),
         {:ok, plan} <- fetch_subscription_plan(subscription.subscription_plan_id),
         :ok <- ensure_membership_plan(plan),
         :ok <- ensure_active_membership_subscription(subscription),
         {:ok, to_email} <- resolve_subscription_recipient_email(subscription, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: nil,
             refund_id: nil,
             subscription_id: subscription.id,
             template_kind: :renewal_reminder,
             to_email: to_email,
             subject: "Membership renewal reminder for #{plan.name || plan.key}",
             idempotency_key:
               "membership_renewal_reminder:sub:#{subscription.id}:renewal:#{renewal_key}:days:#{days_before}",
             provider: provider,
             template_assigns: %{
               "subscription_id" => subscription.id,
               "subscription_plan_id" => plan.id,
               "days_before" => days_before,
               "next_renewal_at" => subscription.next_renewal_at,
               "renewal_amount_minor" => subscription.renewal_amount_minor,
               "renewal_currency" => subscription.renewal_currency,
               "support_email" => support_email()
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    else
      {:error, :membership_only} -> {:ok, :skipped}
      {:error, :inactive_membership} -> {:ok, :skipped}
      other -> other
    end
  end

  @spec enqueue_membership_access_ended_for_system(String.t(), String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:ok, :skipped} | {:error, term()}
  def enqueue_membership_access_ended_for_system(subscription_id, reason, opts \\ [])
      when is_binary(subscription_id) and is_binary(reason) do
    with {:ok, subscription} <- fetch_subscription(subscription_id),
         {:ok, plan} <- fetch_access_ended_plan(subscription, opts),
         :ok <- ensure_access_ended_membership(plan, opts),
         {:ok, to_email} <- resolve_subscription_recipient_email(subscription, opts),
         {:ok, provider} <- resolve_provider(opts),
         period_end_key <- access_ended_period_end_key(subscription.current_period_end_at),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: nil,
             refund_id: nil,
             subscription_id: subscription.id,
             template_kind: :access_ended,
             to_email: to_email,
             subject: access_ended_subject(plan, opts),
             idempotency_key:
               "membership_access_ended:sub:#{subscription.id}:reason:#{reason}:period_end:#{period_end_key}",
             provider: provider,
             template_assigns: %{
               "subscription_id" => subscription.id,
               "subscription_plan_id" => subscription.subscription_plan_id,
               "reason" => reason,
               "current_period_end_at" => subscription.current_period_end_at,
               "support_email" => support_email()
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    else
      {:error, :membership_only} -> {:ok, :skipped}
      other -> other
    end
  end

  defp fetch_access_ended_plan(subscription, opts) do
    if membership_access_proven?(opts) do
      {:ok, nil}
    else
      fetch_subscription_plan(subscription.subscription_plan_id)
    end
  end

  defp ensure_access_ended_membership(plan, opts) when is_list(opts) do
    if membership_access_proven?(opts), do: :ok, else: ensure_membership_plan(plan)
  end

  defp access_ended_subject(plan, opts) do
    if membership_access_proven?(opts) do
      "Membership access ended"
    else
      "Membership access ended for #{plan.name || plan.key}"
    end
  end

  defp membership_access_proven?(opts) when is_list(opts),
    do: Keyword.get(opts, :membership_access_proven?) == true

  @spec enqueue_due_membership_renewal_reminders_for_system(keyword()) ::
          {:ok, %{enqueued_count: non_neg_integer()}} | {:error, term()}
  def enqueue_due_membership_renewal_reminders_for_system(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    reminder_days = [7, 3, 1]

    reminder_days
    |> Enum.reduce_while({:ok, 0}, fn days_before, {:ok, count} ->
      case enqueue_membership_renewal_reminders_for_offset(now, days_before, opts) do
        {:ok, offset_count} -> {:cont, {:ok, count + offset_count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, enqueued_count} -> {:ok, %{enqueued_count: enqueued_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec deliver_outbox_email_for_system(String.t()) :: :ok | {:error, term()} | {:discard, term()}
  def deliver_outbox_email_for_system(outbox_id) when is_binary(outbox_id) do
    started_at = System.monotonic_time()

    with {:ok, :claimed} <- claim_for_delivery(outbox_id),
         {:ok, outbox} <- fetch_outbox(outbox_id),
         {:ok, message} <- Templates.build_message_for_delivery(outbox),
         result <- Providers.deliver_email(outbox.provider, message),
         :ok <- handle_delivery_result(outbox, result, started_at) do
      :ok
    else
      {:discard, reason} ->
        {:discard, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reclaim_stale_processing_for_system(keyword()) ::
          {:ok, %{reclaimed_count: non_neg_integer(), outbox_ids: [String.t()]}}
          | {:error, term()}
  def reclaim_stale_processing_for_system(opts \\ []) when is_list(opts) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, @stale_processing_timeout_seconds)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_before = DateTime.add(now, -timeout_seconds, :second)

    query = """
    UPDATE email_outboxes
    SET state = 'pending',
        processing_started_at = NULL,
        last_error = COALESCE(last_error, 'processing_timeout_reclaimed'),
        updated_at = $2
    WHERE state = 'processing'
      AND processing_started_at IS NOT NULL
      AND processing_started_at < $1
    RETURNING id::text
    """

    case SQL.query(Repo, query, [stale_before, now]) do
      {:ok, %{rows: rows}} ->
        outbox_ids = Enum.map(rows, fn [id] -> id end)
        Enum.each(outbox_ids, &maybe_enqueue_delivery_job/1)
        {:ok, %{reclaimed_count: length(outbox_ids), outbox_ids: outbox_ids}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_provider(opts, option \\ :provider) do
    provider_opt = Keyword.get(opts, option)
    Providers.normalize_provider(provider_opt || Providers.default_provider())
  end

  defp normalize_identity_recipient_email(email) do
    email = if is_nil(email), do: "", else: email |> to_string() |> String.trim()

    if Regex.match?(@identity_recipient_email_regex, email) do
      {:ok, email}
    else
      {:error, :invalid_recipient_email}
    end
  end

  defp normalize_identity_provider(provider) when is_atom(provider) or is_binary(provider) do
    provider_key = provider |> to_string() |> String.trim() |> String.downcase()

    case provider_key do
      "google" -> {:ok, "google", "Google"}
      _ -> {:error, :invalid_identity_provider}
    end
  end

  defp normalize_identity_provider(_provider), do: {:error, :invalid_identity_provider}

  defp normalize_confirmation_url(url) when is_binary(url) do
    url = String.trim(url)
    parsed = URI.parse(url)

    if url != "" and parsed.scheme in ["http", "https"] and is_binary(parsed.host) and
         parsed.host != "" and is_binary(parsed.path) and parsed.path != "" do
      {:ok, url}
    else
      {:error, :invalid_confirmation_url}
    end
  end

  defp normalize_confirmation_url(_url), do: {:error, :invalid_confirmation_url}

  defp identity_confirmation_jti(%User{} = user, token) when is_binary(token) do
    with {:ok, claims, _resource} <- AshAuthentication.Jwt.verify(token, User),
         %{"act" => action, "jti" => jti, "sub" => subject} <- claims,
         true <-
           action ==
             AshAuthentication.Info.strategy!(User, :confirm_new_user).confirm_action_name
             |> to_string(),
         true <- subject == AshAuthentication.user_to_subject(user),
         true <- is_binary(jti) and jti != "" do
      {:ok, jti}
    else
      _ -> {:error, :invalid_confirmation_token}
    end
  end

  defp identity_confirmation_jti(_user, _token), do: {:error, :invalid_confirmation_token}

  defp upsert_outbox(attrs) when is_map(attrs) do
    attrs =
      Map.merge(
        %{
          body_text: "",
          body_html: nil,
          attempt_count: 0,
          state: :pending
        },
        attrs
      )

    EmailOutbox
    |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
    |> Ash.create(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, {:order_not_found, order_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_refund(refund_id) do
    query = Refund |> Ash.Query.filter(expr(id == ^refund_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [refund | _]} -> {:ok, refund}
      {:ok, []} -> {:error, {:refund_not_found, refund_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_subscription(subscription_id) do
    query = Subscription |> Ash.Query.filter(expr(id == ^subscription_id))

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [%Subscription{} = subscription | _]} -> {:ok, subscription}
      {:ok, []} -> {:error, {:subscription_not_found, subscription_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_subscription_plan(plan_id) when is_binary(plan_id) do
    query = SubscriptionPlan |> Ash.Query.filter(expr(id == ^plan_id))

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [%SubscriptionPlan{} = plan | _]} -> {:ok, plan}
      {:ok, []} -> {:error, {:subscription_plan_not_found, plan_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_subscription_plan(_plan_id), do: {:error, :missing_subscription_plan}

  defp resolve_recipient_email(order, opts) do
    case Keyword.get(opts, :to_email) do
      to_email when is_binary(to_email) and to_email != "" ->
        {:ok, String.trim(to_email)}

      _ ->
        resolve_order_user_email(order, opts)
    end
  end

  defp resolve_order_user_email(order, opts) do
    user_id = order.user_id || Keyword.get(opts, :order_user_id)

    case user_id do
      user_id when is_binary(user_id) ->
        fetch_user_email(user_id)

      _ ->
        {:error, :missing_order_recipient}
    end
  end

  defp resolve_subscription_recipient_email(subscription, opts) do
    case Keyword.get(opts, :to_email) do
      to_email when is_binary(to_email) and to_email != "" ->
        {:ok, String.trim(to_email)}

      _ ->
        case subscription.user_id do
          user_id when is_binary(user_id) -> fetch_user_email(user_id)
          _ -> {:error, :missing_subscription_recipient}
        end
    end
  end

  defp fetch_user_email(user_id) do
    query = User |> Ash.Query.filter(expr(id == ^user_id))

    case Ash.read(query, domain: Store.Accounts, authorize?: false, context: %{system?: true}) do
      {:ok, [%User{email: email} | _]} ->
        normalize_user_email(email)

      {:ok, [_ | _]} ->
        {:error, :missing_order_recipient}

      {:ok, []} ->
        {:error, :missing_order_recipient}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_user_email(email) when is_binary(email) and email != "", do: {:ok, email}

  defp normalize_user_email(email) do
    email = to_string(email)

    if email != "" do
      {:ok, email}
    else
      {:error, :missing_order_recipient}
    end
  end

  defp enqueue_delivery_job(outbox_id) do
    %{"email_outbox_id" => outbox_id}
    |> DeliverEmailOutboxWorker.new()
    |> Oban.insert()
  end

  defp maybe_enqueue_delivery_job(outbox_id) do
    case enqueue_delivery_job(outbox_id) do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp fetch_outbox(outbox_id) do
    case EmailOutbox.get_for_system(outbox_id, context: %{system?: true}, authorize?: false) do
      {:ok, %EmailOutbox{} = outbox} -> {:ok, outbox}
      {:ok, nil} -> {:discard, :outbox_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp claim_for_delivery(outbox_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_before = DateTime.add(now, -@stale_processing_timeout_seconds, :second)

    claim_query = """
    UPDATE email_outboxes
    SET state = 'processing',
        attempt_count = attempt_count + 1,
        processing_started_at = $2,
        last_error = NULL,
        updated_at = $2
    WHERE id = $1::text::uuid
      AND (
        state = 'pending'
        OR (
          state = 'processing'
          AND processing_started_at IS NOT NULL
          AND processing_started_at < $3
        )
      )
    RETURNING id::text
    """

    case SQL.query(Repo, claim_query, [outbox_id, now, stale_before]) do
      {:ok, %{rows: [[_id]]}} ->
        {:ok, :claimed}

      {:ok, %{rows: []}} ->
        normalize_unclaimed_outbox(outbox_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_unclaimed_outbox(outbox_id) do
    with {:ok, outbox} <- fetch_outbox(outbox_id) do
      case outbox.state do
        :sent -> {:discard, :already_sent}
        :processing -> {:discard, :already_processing}
        :failed -> {:discard, :already_failed}
        _ -> {:discard, :not_claimable}
      end
    end
  end

  defp handle_delivery_result(outbox, {:ok, provider_message_id}, started_at) do
    outbox
    |> Ash.Changeset.for_update(
      :mark_sent,
      %{
        provider_message_id: provider_message_id,
        sent_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _updated} ->
        emit_delivery_attempt_telemetry(outbox, :sent, started_at)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_delivery_result(outbox, {:error, :transient, reason}, started_at) do
    with {:ok, _updated} <- mark_pending_retry(outbox, reason) do
      emit_delivery_attempt_telemetry(outbox, :transient_error, started_at)
      {:error, reason}
    end
  end

  defp handle_delivery_result(outbox, {:error, :permanent, reason}, started_at) do
    with {:ok, _updated} <- mark_failed(outbox, reason) do
      emit_delivery_attempt_telemetry(outbox, :permanent_error, started_at)
      {:discard, inspect(reason)}
    end
  end

  defp handle_delivery_result(outbox, {:error, reason}, started_at) do
    with {:ok, _updated} <- mark_pending_retry(outbox, reason) do
      emit_delivery_attempt_telemetry(outbox, :transient_error, started_at)
      {:error, reason}
    end
  end

  defp mark_pending_retry(outbox, reason) do
    message = inspect(reason)

    outbox
    |> Ash.Changeset.for_update(
      :mark_pending_retry,
      %{last_error: message},
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp mark_failed(outbox, reason) do
    message = inspect(reason)

    outbox
    |> Ash.Changeset.for_update(
      :mark_failed,
      %{last_error: message},
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp emit_outbox_insert_telemetry(outbox) do
    :telemetry.execute(
      [:store, :comms, :outbox_insert],
      %{count: 1},
      %{kind: outbox.template_kind, provider: outbox.provider, outbox_id: outbox.id}
    )
  end

  defp emit_delivery_attempt_telemetry(outbox, outcome, started_at) do
    :telemetry.execute(
      [:store, :comms, :delivery_attempt],
      %{duration: System.monotonic_time() - started_at},
      %{
        provider: outbox.provider,
        template: outbox.template_kind,
        outcome: outcome,
        outbox_id: outbox.id
      }
    )
  end

  defp support_email do
    Application.get_env(:store, :comms, [])
    |> Keyword.get(:support_email, "support@store.local")
  end

  defp enqueue_membership_renewal_reminders_for_offset(now, days_before, opts) do
    with {:ok, subscriptions} <- list_membership_reminder_candidates(now, days_before) do
      subscriptions
      |> Enum.reduce_while({:ok, 0}, fn subscription, acc ->
        enqueue_membership_renewal_reminder_reducer_result(
          acc,
          enqueue_membership_renewal_reminder_for_offset_subscription(
            subscription,
            days_before,
            opts
          )
        )
      end)
    end
  end

  defp enqueue_membership_renewal_reminder_for_offset_subscription(
         %Subscription{} = subscription,
         days_before,
         opts
       ) do
    enqueue_membership_renewal_reminder_for_system(
      subscription.id,
      reminder_renewal_key(subscription),
      days_before,
      opts
    )
  end

  defp enqueue_membership_renewal_reminder_reducer_result(
         {:ok, count},
         {:ok, %EmailOutbox{}}
       ),
       do: {:cont, {:ok, count + 1}}

  defp enqueue_membership_renewal_reminder_reducer_result({:ok, count}, {:ok, :skipped}),
    do: {:cont, {:ok, count}}

  defp enqueue_membership_renewal_reminder_reducer_result(_acc, {:error, reason}),
    do: {:halt, {:error, reason}}

  defp list_membership_reminder_candidates(now, days_before)
       when is_struct(now, DateTime) and is_integer(days_before) do
    window_start = DateTime.add(now, days_before * 86_400, :second)
    window_end = DateTime.add(window_start, 3_600, :second)

    query =
      from(subscription in Subscription,
        join: plan in SubscriptionPlan,
        on: plan.id == subscription.subscription_plan_id,
        where:
          subscription.status == :active and
            not is_nil(subscription.next_renewal_at) and
            subscription.next_renewal_at >= ^window_start and
            subscription.next_renewal_at < ^window_end and
            plan.entitlement_kind == ^:membership_access,
        order_by: [asc: subscription.next_renewal_at, asc: subscription.id]
      )

    {:ok, Repo.all(query)}
  rescue
    error -> {:error, error}
  end

  defp reminder_renewal_key(subscription) do
    period_end_at = subscription.current_period_end_at || subscription.next_renewal_at

    if match?(%DateTime{}, period_end_at) do
      Scheduler.renewal_key(subscription.id, period_end_at)
    else
      "renewal:#{subscription.id}:#{subscription.next_renewal_at}"
    end
  end

  defp access_ended_period_end_key(%DateTime{} = period_end_at),
    do: DateTime.to_iso8601(period_end_at)

  defp access_ended_period_end_key(_period_end_at), do: "none"

  defp ensure_membership_plan(%SubscriptionPlan{entitlement_kind: :membership_access}), do: :ok
  defp ensure_membership_plan(%SubscriptionPlan{}), do: {:error, :membership_only}

  defp ensure_active_membership_subscription(%Subscription{status: :active}), do: :ok
  defp ensure_active_membership_subscription(%Subscription{}), do: {:error, :inactive_membership}
end
