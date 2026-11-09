defmodule StoreWeb.Admin.Subscriptions.ShowLive do
  @moduledoc """
  Admin subscription detail with inline boundary-change controls.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  alias StoreWeb.Params.Subscriptions.{
    QueueSubscriptionPlanChangeParams,
    QueueSubscriptionVariantChangeParams,
    StartSubscriptionPaymentMethodUpdateParams
  }

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin, :support]) do
      {:ok,
       socket
       |> assign(:detail, nil)
       |> assign(:subscription_id, nil)
       |> assign(
         :can_start_payment_method_update?,
         Authorization.has_any_role?(actor, [:super_admin, :admin])
       )
       |> assign(:payment_update_modal_open?, false)
       |> assign(:payment_update_client_secret, nil)
       |> assign(:payment_update_publishable_key, nil)
       |> assign(:plan_change_form, to_form(%{}, as: :queue_subscription_plan_change))
       |> assign(:variant_change_form, to_form(%{}, as: :queue_subscription_variant_change))}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    actor = socket.assigns.current_user

    case SubscriptionsFacade.get_subscription_detail_for_admin(actor, id) do
      {:ok, nil} ->
        {:noreply,
         socket
         |> put_flash(:error, "Subscription not found")
         |> push_navigate(to: ~p"/admin/subscriptions")}

      {:ok, detail} ->
        {:noreply,
         socket
         |> assign(:subscription_id, id)
         |> assign(:detail, detail)
         |> assign(:payment_update_modal_open?, false)
         |> assign(:payment_update_client_secret, nil)
         |> assign(:payment_update_publishable_key, nil)
         |> assign(:plan_change_form, plan_change_form(detail))
         |> assign(:variant_change_form, variant_change_form(detail))}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load subscription")
         |> push_navigate(to: ~p"/admin/subscriptions")}
    end
  end

  @impl true
  def handle_event("queue_plan_change", %{"queue_subscription_plan_change" => params}, socket) do
    actor = socket.assigns.current_user
    subscription_id = socket.assigns.subscription_id
    params = Map.put(params, "subscription_id", subscription_id)

    case QueueSubscriptionPlanChangeParams.input(params) do
      {:ok, input} ->
        case SubscriptionsFacade.queue_subscription_plan_change_for_admin(
               actor,
               subscription_id,
               input
             ) do
          {:ok, _subscription} ->
            {:noreply,
             socket
             |> put_flash(:info, "Plan change queued for the next successful renewal")
             |> reload_detail()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unable to queue plan change")}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invalid plan change request")}
    end
  end

  @impl true
  def handle_event(
        "queue_variant_change",
        %{"queue_subscription_variant_change" => params},
        socket
      ) do
    actor = socket.assigns.current_user
    subscription_id = socket.assigns.subscription_id
    params = Map.put(params, "subscription_id", subscription_id)

    case QueueSubscriptionVariantChangeParams.input(params) do
      {:ok, input} ->
        case SubscriptionsFacade.queue_subscription_variant_change_for_admin(
               actor,
               subscription_id,
               input
             ) do
          {:ok, _subscription} ->
            {:noreply,
             socket
             |> put_flash(:info, "Variant change queued for the next successful renewal")
             |> reload_detail()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unable to queue variant change")}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invalid variant change request")}
    end
  end

  @impl true
  def handle_event("cancel_now", _params, socket) do
    actor = socket.assigns.current_user

    case SubscriptionsFacade.cancel_subscription_for_admin(
           actor,
           socket.assigns.subscription_id,
           :now
         ) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscription canceled")
         |> reload_detail()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to cancel subscription")}
    end
  end

  @impl true
  def handle_event("cancel_at_period_end", _params, socket) do
    actor = socket.assigns.current_user

    case SubscriptionsFacade.cancel_subscription_for_admin(
           actor,
           socket.assigns.subscription_id,
           :period_end
         ) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> put_flash(:info, "Subscription will cancel at period end")
         |> reload_detail()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to update cancellation")}
    end
  end

  @impl true
  def handle_event("start_payment_method_update", _params, socket) do
    actor = socket.assigns.current_user
    params = %{"subscription_id" => socket.assigns.subscription_id}

    case StartSubscriptionPaymentMethodUpdateParams.input(params) do
      {:ok, input} ->
        case SubscriptionsFacade.start_subscription_payment_method_update_for_admin(
               actor,
               socket.assigns.subscription_id,
               input
             ) do
          {:ok, result} ->
            {:noreply,
             socket
             |> assign(:payment_update_modal_open?, true)
             |> assign(:payment_update_client_secret, result.client_secret)
             |> assign(:payment_update_publishable_key, result.publishable_key)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unable to start payment method update")}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invalid payment method update request")}
    end
  end

  @impl true
  def handle_event("close_payment_method_modal", _params, socket) do
    {:noreply, clear_payment_method_modal(socket)}
  end

  @impl true
  def handle_event("stripe_setup_succeeded", _params, socket) do
    {:noreply,
     socket
     |> clear_payment_method_modal()
     |> put_flash(
       :info,
       "Card update submitted. Billing state will refresh after Stripe confirms it."
     )
     |> reload_detail()}
  end

  @impl true
  def handle_event("stripe_setup_failed", %{"message" => message}, socket)
      when is_binary(message) do
    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_event("stripe_setup_failed", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unable to confirm card update")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        :if={@detail}
        id="admin-subscription-detail"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <header class="space-y-1">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h1 class="text-2xl font-semibold">
                Subscription {plan_label(@detail.subscription)}
              </h1>
              <p class="text-sm text-base-content/70">User: {@detail.subscription.user_id}</p>
            </div>
            <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-semibold uppercase tracking-wide">
              {@detail.subscription.status}
            </span>
          </div>
        </header>

        <dl class="grid gap-3 text-sm md:grid-cols-2 xl:grid-cols-3">
          <div>
            <dt class="text-base-content/70">Provider</dt>
            <dd class="font-medium">{@detail.subscription.provider}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Billing Mode</dt>
            <dd class="font-medium">{@detail.subscription.billing_mode}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Current Renewal Price</dt>
            <dd>
              {format_money(
                @detail.subscription.renewal_currency,
                @detail.subscription.renewal_amount_minor
              )}
            </dd>
          </div>
          <div>
            <dt class="text-base-content/70">Pending Renewal Price</dt>
            <dd>
              {format_money(
                @detail.subscription.pending_renewal_currency,
                @detail.subscription.pending_renewal_amount_minor
              )}
            </dd>
          </div>
          <div>
            <dt class="text-base-content/70">Current Period End</dt>
            <dd>{format_datetime(@detail.subscription.current_period_end_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Next Renewal</dt>
            <dd>{format_datetime(@detail.subscription.next_renewal_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Next Retry</dt>
            <dd>{format_datetime(@detail.subscription.next_retry_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Dunning Attempts</dt>
            <dd>{@detail.subscription.dunning_attempt_count}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Stored Payment Method</dt>
            <dd>{stored_payment_method_status(@detail.subscription)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Queued Change</dt>
            <dd>{queued_change_summary(@detail.subscription)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Provider Customer Ref</dt>
            <dd class="font-mono text-xs">{@detail.subscription.provider_customer_ref || "-"}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Provider Billing Ref</dt>
            <dd class="font-mono text-xs">{@detail.subscription.provider_billing_ref || "-"}</dd>
          </div>
        </dl>

        <section class="grid gap-4 lg:grid-cols-2">
          <section class="space-y-3 rounded-lg border border-base-300 bg-base-100 p-4">
            <h2 class="text-lg font-semibold">Queue Plan Change</h2>
            <p class="text-sm text-base-content/70">
              The queued plan and price snapshot take effect after the next successful renewal.
            </p>

            <.form
              :if={@detail.plan_targets != []}
              for={@plan_change_form}
              phx-submit="queue_plan_change"
            >
              <.input
                field={@plan_change_form[:subscription_plan_id]}
                type="select"
                label="Target plan"
                options={Enum.map(@detail.plan_targets, &{target_label(&1), &1.id})}
              />
              <.button
                type="submit"
                class="mt-3"
                disabled={!@detail.action_capabilities.can_queue_plan_change?}
              >
                Queue Plan Change
              </.button>
            </.form>

            <p :if={@detail.plan_targets == []} class="text-sm text-base-content/70">
              No alternative plans are available for this variant.
            </p>
          </section>

          <section class="space-y-3 rounded-lg border border-base-300 bg-base-100 p-4">
            <h2 class="text-lg font-semibold">Queue Variant Change</h2>
            <p class="text-sm text-base-content/70">
              Variant changes use the current or already-pending plan when computing the next locked price.
            </p>

            <.form
              :if={@detail.variant_targets != []}
              for={@variant_change_form}
              phx-submit="queue_variant_change"
            >
              <.input
                field={@variant_change_form[:variant_id]}
                type="select"
                label="Target variant"
                options={Enum.map(@detail.variant_targets, &{target_label(&1), &1.id})}
              />
              <.button
                type="submit"
                class="mt-3"
                disabled={!@detail.action_capabilities.can_queue_variant_change?}
              >
                Queue Variant Change
              </.button>
            </.form>

            <p :if={@detail.variant_targets == []} class="text-sm text-base-content/70">
              No alternative variants are available for this plan.
            </p>
          </section>
        </section>

        <section class="grid gap-4 lg:grid-cols-2">
          <section
            :if={@can_start_payment_method_update?}
            class="space-y-3 rounded-lg border border-base-300 bg-base-100 p-4"
          >
            <h2 class="text-lg font-semibold">Payment Method</h2>
            <p class="text-sm text-base-content/70">
              Launch the inline Stripe card-update modal for this subscription.
            </p>
            <.button
              phx-click="start_payment_method_update"
              disabled={!@detail.action_capabilities.can_update_payment_method?}
            >
              Update Card
            </.button>
          </section>

          <section class="space-y-3 rounded-lg border border-base-300 bg-base-100 p-4">
            <h2 class="text-lg font-semibold">Cancellation</h2>
            <div class="flex flex-wrap gap-3">
              <.button
                phx-click="cancel_at_period_end"
                disabled={!@detail.action_capabilities.can_cancel_at_period_end?}
              >
                Cancel At Period End
              </.button>
              <.button
                phx-click="cancel_now"
                class="btn-error"
                disabled={!@detail.action_capabilities.can_cancel_now?}
              >
                Cancel Now
              </.button>
            </div>
          </section>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Recent Renewal Attempts</h2>
          <div
            :if={@detail.renewal_attempts == []}
            class="rounded border border-base-300 bg-base-100 p-3 text-sm"
          >
            No renewal attempts yet.
          </div>
          <ul :if={@detail.renewal_attempts != []} class="space-y-2 text-sm">
            <li
              :for={attempt <- @detail.renewal_attempts}
              class="rounded border border-base-300 bg-base-100 p-3"
            >
              <div class="font-medium">{attempt.status}</div>
              <div>Renewal key: {attempt.renewal_key}</div>
              <div>Failure: {attempt.failure_code || "-"}</div>
              <div>Created: {format_datetime(attempt.inserted_at)}</div>
            </li>
          </ul>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Items</h2>
          <div
            :if={@detail.subscription.items == []}
            class="rounded border border-base-300 bg-base-100 p-3 text-sm"
          >
            No subscription items.
          </div>
          <ul :if={@detail.subscription.items != []} class="space-y-2 text-sm">
            <li
              :for={item <- @detail.subscription.items}
              class="rounded border border-base-300 bg-base-100 p-3"
            >
              <div>Variant: {item.variant_id}</div>
              <div>Qty: {item.quantity}</div>
              <div>
                Price snapshot: {format_money(item.currency_snapshot, item.amount_minor_snapshot)}
              </div>
            </li>
          </ul>
        </section>

        <div
          :if={@payment_update_modal_open?}
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div class="w-full max-w-lg space-y-4 rounded-xl border border-base-300 bg-base-100 p-6 shadow-2xl">
            <div class="flex items-center justify-between gap-4">
              <h2 class="text-xl font-semibold">Update Card</h2>
              <button type="button" phx-click="close_payment_method_modal" class="btn btn-sm">
                Close
              </button>
            </div>

            <div
              id="admin-subscription-payment-method-elements"
              phx-hook="StripeElements"
              data-client-secret={@payment_update_client_secret}
              data-publishable-key={@payment_update_publishable_key}
              class="space-y-3"
            >
              <div data-stripe-element class="rounded-lg border border-base-300 bg-base-200 p-3">
              </div>
              <button data-stripe-confirm type="button" class="btn">
                Save Card
              </button>
              <p class="text-xs text-base-content/60">
                The modal closes after Stripe accepts the setup submission. Durable billing updates remain webhook-driven.
              </p>
            </div>
          </div>
        </div>

        <.link navigate={~p"/admin/subscriptions"} class="btn btn-sm">Back</.link>
      </section>
    </Layouts.app>
    """
  end

  defp reload_detail(socket) do
    case SubscriptionsFacade.get_subscription_detail_for_admin(
           socket.assigns.current_user,
           socket.assigns.subscription_id
         ) do
      {:ok, detail} ->
        socket
        |> assign(:detail, detail)
        |> assign(:plan_change_form, plan_change_form(detail))
        |> assign(:variant_change_form, variant_change_form(detail))

      {:error, _reason} ->
        socket
    end
  end

  defp clear_payment_method_modal(socket) do
    socket
    |> assign(:payment_update_modal_open?, false)
    |> assign(:payment_update_client_secret, nil)
    |> assign(:payment_update_publishable_key, nil)
  end

  defp plan_change_form(detail) do
    selected_id =
      detail.plan_targets
      |> Enum.find_value(fn target ->
        if target.selected?, do: target.id, else: nil
      end)

    to_form(%{"subscription_plan_id" => selected_id || ""}, as: :queue_subscription_plan_change)
  end

  defp variant_change_form(detail) do
    selected_id =
      detail.variant_targets
      |> Enum.find_value(fn target ->
        if target.selected?, do: target.id, else: nil
      end)

    to_form(%{"variant_id" => selected_id || ""}, as: :queue_subscription_variant_change)
  end

  defp plan_label(subscription) do
    case subscription.subscription_plan do
      %{name: name} when is_binary(name) and name != "" -> name
      %{key: key} when is_binary(key) and key != "" -> key
      _ -> subscription.id
    end
  end

  defp stored_payment_method_status(%{stored_payment_method: %{status: status}}), do: status
  defp stored_payment_method_status(_subscription), do: "missing"

  defp queued_change_summary(subscription) do
    cond do
      is_binary(subscription.pending_subscription_plan_id) and
          is_binary(subscription.pending_variant_id) ->
        "plan and variant queued"

      is_binary(subscription.pending_subscription_plan_id) ->
        "plan queued"

      is_binary(subscription.pending_variant_id) ->
        "variant queued"

      true ->
        "none"
    end
  end

  defp target_label(target) do
    "#{target.label} (#{format_money(target.currency, target.price_minor)})"
  end

  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_), do: "-"

  defp format_money(currency, minor) when is_binary(currency) and is_integer(minor) do
    "#{String.upcase(currency)} #{:erlang.float_to_binary(minor / 100, decimals: 2)}"
  end

  defp format_money(_currency, _minor), do: "-"
end
