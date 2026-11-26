defmodule StoreWeb.CheckoutLive.Placeholder do
  @moduledoc """
  Phase 21 checkout flow with shipping capture, totals finalization, and payment intent start.
  """

  use StoreWeb, :live_view

  alias Store.Checkout
  alias Store.Orders
  alias Store.Payments
  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Support.Errors.Normalize
  alias Store.Support.Telemetry.RepoStats
  alias StoreWeb.Live.StaticToLive
  alias StoreWeb.Params.Checkout.{CheckoutFinalizeParams, CheckoutShippingParams}
  alias StoreWeb.Params.Payments.CreateIntentForOrderParams

  @mount_event [:store, :checkout_live, :mount]

  @impl true
  def mount(_params, session, socket) do
    started_at = System.monotonic_time()

    socket =
      socket
      |> assign(:checkout, nil)
      |> assign(:cart_token, Map.get(session, "cart_token"))
      |> assign(:checkout_key, nil)
      |> assign(:payment_intent, nil)
      |> assign(:purchase_provider, PaymentsFacade.purchase_provider_for_public())
      |> assign(:hydrating?, true)
      |> assign(:resume_state, :loading)
      |> assign(:order_topic, nil)
      |> assign(:warm_load_ref, nil)

    if connected?(socket) do
      {:ok, socket}
    else
      StaticToLive.emit_mount_telemetry(
        @mount_event,
        started_at,
        %{jitter_delay_ms: 0},
        %{phase: :static, result: :ok, live_action: socket.assigns.live_action}
      )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"checkout_key" => checkout_key}, _uri, socket) do
    started_at = System.monotonic_time()
    socket = assign(socket, :checkout_key, checkout_key)

    if connected?(socket) do
      ref = make_ref()

      {socket, jitter_ms} =
        StaticToLive.schedule_warm_load(
          assign(socket, :warm_load_ref, ref),
          {:load_warm_checkout, checkout_key, ref, started_at},
          jitter?: false
        )

      {:noreply, assign(socket, :warm_load_jitter_ms, jitter_ms)}
    else
      StaticToLive.emit_mount_telemetry(
        @mount_event,
        started_at,
        %{jitter_delay_ms: 0},
        %{phase: :static, result: :ok, live_action: socket.assigns.live_action}
      )

      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "checkout_key is required")
     |> push_navigate(to: ~p"/cart")}
  end

  @impl true
  def handle_event("set_shipping", params, socket) do
    if return_mode?(socket) or expired_resume?(socket) do
      {:noreply, socket}
    else
      actor = checkout_actor(socket)

      with {:ok, input} <- CheckoutShippingParams.input(params),
           {:ok, checkout} <- Checkout.set_shipping(actor, socket.assigns.checkout_key, input) do
        {:noreply,
         socket
         |> assign(:checkout, checkout)
         |> put_flash(:info, "Shipping details saved")}
      else
        {:error, error} ->
          {:noreply, put_flash(socket, :error, checkout_error_message(error, :shipping))}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to save shipping details")}
      end
    end
  end

  @impl true
  def handle_event("finalize_totals", params, socket) do
    if return_mode?(socket) or expired_resume?(socket) do
      {:noreply, socket}
    else
      actor = checkout_actor(socket)

      billing = Map.take(params, ["billing_country_code", "billing_region_code"])

      with {:ok, input} <- CheckoutFinalizeParams.input(billing),
           {:ok, checkout} <- Checkout.finalize_totals(actor, socket.assigns.checkout_key, input) do
        {:noreply,
         socket
         |> assign(:checkout, checkout)
         |> put_flash(:info, "Totals finalized")}
      else
        {:error, error} ->
          {:noreply, put_flash(socket, :error, checkout_error_message(error, :finalize))}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to finalize totals")}
      end
    end
  end

  @impl true
  def handle_event("create_payment_intent", _params, socket) do
    if return_mode?(socket) or expired_resume?(socket) do
      {:noreply, socket}
    else
      actor = checkout_actor(socket)

      with provider when not is_nil(provider) <-
             PaymentsFacade.purchase_provider_for_public(),
           {:ok, input} <- CreateIntentForOrderParams.input(%{provider: provider}),
           {:ok, intent} <-
             Payments.create_intent_for_order(actor, socket.assigns.checkout_key, input),
           {:ok, checkout} <- Checkout.get_checkout_for_user(actor, socket.assigns.checkout_key) do
        socket =
          socket
          |> assign(:payment_intent, intent)
          |> assign(:checkout, checkout)

        {:noreply, maybe_redirect_to_payment(socket, intent)}
      else
        nil ->
          {:noreply,
           socket
           |> assign(:purchase_provider, nil)
           |> put_flash(:error, "Payment is currently unavailable.")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, checkout_error_message(error, :payment_intent))}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to create payment intent")}
      end
    end
  end

  @impl true
  def handle_info(
        {:load_warm_checkout, checkout_key, ref, started_at},
        %{assigns: %{warm_load_ref: ref}} = socket
      ) do
    actor = checkout_actor(socket)

    {{updated_socket, result}, repo_stats} =
      RepoStats.capture(fn ->
        case Checkout.get_checkout_for_user(actor, checkout_key) do
          {:ok, checkout} ->
            socket =
              socket
              |> assign(:checkout, checkout)
              |> assign(:hydrating?, false)
              |> assign(:resume_state, resume_state_for_checkout(checkout))
              |> subscribe_order_topic(checkout.order_id)

            {socket, :ok}

          {:error, _error} ->
            {not_found_socket(socket), :error}
        end
      end)

    StaticToLive.emit_mount_telemetry(
      @mount_event,
      started_at,
      Map.merge(repo_stats, %{jitter_delay_ms: Map.get(socket.assigns, :warm_load_jitter_ms, 0)}),
      %{phase: :live, result: result, live_action: socket.assigns.live_action}
    )

    {:noreply, updated_socket}
  end

  def handle_info(
        {:order_state_changed, order_id, :paid, _reason, _occurred_at},
        %{assigns: %{checkout: %{order_id: order_id, checkout_key: checkout_key}}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:resume_state, :ready)
     |> put_flash(:info, "Payment completed. Showing the latest order state.")
     |> push_navigate(to: ~p"/checkout/return?checkout_key=#{checkout_key}")}
  end

  def handle_info(
        {:order_state_changed, order_id, :pending_provider_setup, _reason, _occurred_at},
        %{assigns: %{checkout: %{order_id: order_id}}} = socket
      ) do
    {:noreply, assign(socket, :resume_state, :pending_provider_setup)}
  end

  def handle_info(
        {:order_state_changed, order_id, :pending_payment, _reason, _occurred_at},
        %{assigns: %{checkout: %{order_id: order_id}}} = socket
      ) do
    {:noreply, assign(socket, :resume_state, :ready)}
  end

  def handle_info(
        {:order_state_changed, order_id, :cancelled, :pending_provider_setup_expired,
         _occurred_at},
        %{assigns: %{checkout: %{order_id: order_id}}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:resume_state, :expired_restart_required)
     |> put_flash(
       :error,
       "This checkout expired while waiting for payment setup. Please restart checkout."
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="checkout-live" class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">Checkout</h1>
          <p :if={@checkout && @checkout.shipping_required?} class="text-sm text-base-content/70">
            Review shipping, finalize totals, then continue to payment.
          </p>
        </header>

        <div
          :if={@live_action in [:return, :cancel]}
          class="rounded-xl border border-base-300 bg-base-200/50 p-4 text-sm"
        >
          <p :if={@live_action == :return} class="font-semibold">
            Payment return received. This page is read-only and reflects the latest order state.
          </p>
          <p :if={@live_action == :cancel} class="font-semibold">
            Payment was canceled. This page is read-only and no payment state was applied from URL params.
          </p>
        </div>

        <div
          :if={@resume_state == :expired_restart_required}
          class="rounded-xl border border-warning bg-warning/10 p-4 text-sm"
        >
          <p class="font-semibold">
            This checkout expired before payment setup completed.
          </p>
          <.link
            navigate={~p"/cart"}
            class="mt-3 inline-flex rounded-lg border border-base-content/30 px-3 py-2 text-sm font-medium hover:bg-base-300"
          >
            Restart Checkout
          </.link>
        </div>

        <div
          :if={@resume_state == :pending_provider_setup and @live_action == :index}
          class="rounded-xl border border-info bg-info/10 p-4 text-sm"
        >
          Payment setup is already in progress for this order. Use the button below to resume safely.
        </div>

        <div
          :if={@hydrating? and is_nil(@checkout)}
          class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
        >
          Loading checkout...
        </div>

        <div :if={@checkout} class="grid gap-4 lg:grid-cols-2">
          <article
            :if={@checkout.shipping_required?}
            class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4"
          >
            <h2 class="text-base font-semibold">Shipping</h2>

            <form :if={@live_action == :index} phx-submit="set_shipping" class="grid gap-3">
              <input
                name="recipient_name"
                value={@checkout.shipping_recipient_name || ""}
                placeholder="Recipient name"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <input
                name="address_line1"
                value={@checkout.shipping_address_line1 || ""}
                placeholder="Address line 1"
                required
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <input
                name="address_line2"
                value={@checkout.shipping_address_line2 || ""}
                placeholder="Address line 2"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <input
                name="city"
                value={@checkout.shipping_city || ""}
                placeholder="City"
                required
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <div class="grid gap-3 sm:grid-cols-3">
                <input
                  name="country_code"
                  value={@checkout.shipping_country_code || "US"}
                  placeholder="Country"
                  required
                  class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                />

                <input
                  name="region_code"
                  value={@checkout.shipping_region_code || ""}
                  placeholder="Region"
                  required
                  class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                />

                <input
                  name="postal_code"
                  value={@checkout.shipping_postal_code || ""}
                  placeholder="Postal"
                  required
                  class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                />
              </div>

              <input
                name="phone"
                value={@checkout.shipping_phone || ""}
                placeholder="Phone"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <select
                name="shipping_method_code"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                required
              >
                <option value="">Select shipping method</option>
                <option
                  :for={option <- @checkout.shipping_quote_options || []}
                  value={option.shipping_method_code}
                  selected={option.shipping_method_code == @checkout.shipping_method_code}
                >
                  {option.shipping_method_code}
                </option>
              </select>

              <select
                name="quote_hash"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                required
              >
                <option value="">Select shipping quote</option>
                <option
                  :for={option <- @checkout.shipping_quote_options || []}
                  value={option.quote_hash}
                  selected={option.quote_hash == @checkout.shipping_quote_hash}
                >
                  {quote_label(option)}
                </option>
              </select>

              <p
                :if={Enum.empty?(@checkout.shipping_quote_options || [])}
                class="text-xs text-warning"
              >
                No eligible shipping quotes yet. Check destination fields.
              </p>

              <.button id="save-shipping" type="submit">Save Shipping</.button>
            </form>

            <div :if={@live_action != :index} class="space-y-1 text-sm">
              <p>{@checkout.shipping_recipient_name || "Recipient pending"}</p>
              <p>{@checkout.shipping_address_line1 || "Address pending"}</p>
              <p>{@checkout.shipping_city || "City pending"}</p>
            </div>
          </article>

          <article
            :if={!@checkout.shipping_required?}
            class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4"
          >
            <h2 class="text-base font-semibold">Billing location</h2>
            <form
              :if={@live_action == :index && !@checkout.totals_finalized?}
              id="digital-billing"
              phx-submit="finalize_totals"
              class="grid gap-3"
            >
              <.input
                id="billing-country-code"
                name="billing_country_code"
                type="text"
                value={@checkout.billing_country_code || ""}
                label="Country code"
                placeholder="ZA"
                maxlength="2"
                required
              />
              <.input
                id="billing-region-code"
                name="billing_region_code"
                type="text"
                value={@checkout.billing_region_code || ""}
                label="Region code"
                placeholder="WC"
                maxlength="12"
                required
              />
              <.button type="submit">Finalize Totals</.button>
            </form>
            <p :if={@checkout.billing_country_code} class="text-sm">
              {@checkout.billing_country_code}, {@checkout.billing_region_code}
            </p>
          </article>

          <article class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4">
            <h2 class="text-base font-semibold">Summary</h2>

            <div class="space-y-2 text-sm">
              <div class="flex items-center justify-between">
                <span>Order</span>
                <span class="font-semibold">{@checkout.order_ref}</span>
              </div>

              <div class="flex items-center justify-between">
                <span>Items</span>
                <span class="font-semibold">{@checkout.item_count}</span>
              </div>

              <div class="flex items-center justify-between">
                <span>Items subtotal</span>
                <span class="font-semibold">
                  {format_money(@checkout.items_subtotal_minor, @checkout.currency_code)}
                </span>
              </div>

              <div
                :if={@checkout.shipping_required?}
                id="checkout-shipping-total"
                class="flex items-center justify-between"
              >
                <span>Shipping</span>
                <span class="font-semibold">
                  {format_money(@checkout.shipping_total_minor, @checkout.currency_code)}
                </span>
              </div>

              <div class="flex items-center justify-between">
                <span>Tax</span>
                <span class="font-semibold">
                  {format_money(@checkout.tax_total_minor, @checkout.currency_code)}
                </span>
              </div>

              <div class="mt-2 flex items-center justify-between border-t border-base-300 pt-2 text-base">
                <span class="font-semibold">Grand total</span>
                <span class="font-semibold">
                  {format_money(@checkout.grand_total_minor, @checkout.currency_code)}
                </span>
              </div>
            </div>

            <div :if={@live_action == :index} class="space-y-2">
              <.button
                :if={@checkout.shipping_required?}
                id="finalize-totals"
                phx-click="finalize_totals"
                class="w-full"
              >
                Finalize Totals
              </.button>

              <.button
                id="pay-now"
                phx-click="create_payment_intent"
                class="w-full"
                disabled={
                  is_nil(@purchase_provider) or !@checkout.totals_finalized? or
                    @resume_state == :expired_restart_required
                }
              >
                {payment_button_label(@resume_state)}
              </.button>
            </div>

            <div
              :if={@payment_intent}
              class="rounded-lg border border-base-300 bg-base-100/70 p-3 text-xs"
            >
              <p>Payment intent: {@payment_intent.payment_intent_id}</p>
              <p>State: {@payment_intent.state}</p>
            </div>

            <.link
              :if={@live_action in [:return, :cancel]}
              navigate={~p"/checkout?checkout_key=#{@checkout.checkout_key}"}
              class="inline-flex rounded-lg border border-base-content/30 px-3 py-2 text-sm font-medium hover:bg-base-300"
            >
              Back to Checkout
            </.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp format_money(minor, currency) when is_integer(minor) do
    code = if is_binary(currency) and currency != "", do: String.upcase(currency), else: "USD"
    "#{code} #{:erlang.float_to_binary(minor / 100, decimals: 2)}"
  end

  defp format_money(_minor, _currency), do: "USD 0.00"

  defp quote_label(option) do
    method = option.label || option.shipping_method_code
    "#{method} - #{format_money(option.amount_minor, option.currency_code)}"
  end

  defp checkout_actor(socket) do
    user = socket.assigns[:current_user]
    token = socket.assigns[:cart_token]

    cond do
      is_map(user) and is_binary(token) ->
        Map.put(user, :cart_token, token)

      is_map(user) ->
        user

      is_binary(token) ->
        %{cart_token: token}

      true ->
        nil
    end
  end

  defp return_mode?(socket) do
    socket.assigns.live_action in [:return, :cancel]
  end

  defp expired_resume?(socket), do: socket.assigns.resume_state == :expired_restart_required

  defp resume_state_for_checkout(%{state: :pending_provider_setup}), do: :pending_provider_setup
  defp resume_state_for_checkout(%{state: :cancelled}), do: :expired_restart_required
  defp resume_state_for_checkout(_checkout), do: :ready

  defp subscribe_order_topic(socket, order_id) when is_binary(order_id) do
    topic = Orders.order_topic(order_id)

    if connected?(socket) and socket.assigns.order_topic != topic do
      Phoenix.PubSub.subscribe(Store.PubSub, topic)
    end

    assign(socket, :order_topic, topic)
  end

  defp subscribe_order_topic(socket, _order_id), do: socket

  defp payment_button_label(:pending_provider_setup), do: "Resume Payment"
  defp payment_button_label(_resume_state), do: "Continue To Payment"

  defp not_found_socket(socket) do
    socket
    |> put_flash(:error, "Checkout not found")
    |> push_navigate(to: ~p"/cart")
  end

  defp checkout_error_message(error, context) do
    case Normalize.normalize(error).code do
      "STALE_RECORD" ->
        "Your checkout changed while processing. Please retry."

      "CHECKOUT_DUPLICATE" ->
        "This checkout is already in progress. Please refresh and retry."

      "RESERVATION_CONFLICT" ->
        reservation_conflict_message(context)

      "OUT_OF_STOCK" ->
        "One or more items are no longer available. Review your cart and try again."

      "INVALID_ADDRESS" when context == :finalize ->
        "Enter a valid billing country and region."

      "TAX_RATE_NOT_FOUND" when context == :finalize ->
        "Tax could not be calculated for this location."

      _ ->
        fallback_checkout_error_message(context)
    end
  end

  defp reservation_conflict_message(:payment_intent),
    do: "Checkout is busy right now. Please retry payment in a moment."

  defp reservation_conflict_message(_context),
    do: "Checkout is busy right now. Please retry in a moment."

  defp fallback_checkout_error_message(:shipping), do: "Unable to save shipping details"
  defp fallback_checkout_error_message(:finalize), do: "Unable to finalize totals"
  defp fallback_checkout_error_message(:payment_intent), do: "Unable to create payment intent"

  defp maybe_redirect_to_payment(socket, %{redirect_url: url})
       when is_binary(url) and url != "" do
    redirect(socket, external: url)
  end

  defp maybe_redirect_to_payment(socket, _intent) do
    put_flash(socket, :info, "Payment intent created")
  end
end
