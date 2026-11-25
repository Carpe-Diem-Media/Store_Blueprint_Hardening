defmodule StoreWeb.CartCheckoutLiveTest do
  use StoreWeb.ConnCase, async: false

  import Ash.Expr
  require Ash.Query
  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Catalog.InventoryItem
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutShippingInput, CheckoutStartInput}
  alias Store.Orders
  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Pricing.TaxRate
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup do
    previous = Application.get_env(:store, :live_warm_load_jitter_ms)
    Application.put_env(:store, :live_warm_load_jitter_ms, {0, 0})

    on_exit(fn ->
      Application.put_env(:store, :live_warm_load_jitter_ms, previous)
    end)

    :ok
  end

  test "guest can view/update/remove cart lines", %{conn: conn} do
    %{title: title, variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    {:ok, cart_view, _html} = live(conn, ~p"/cart")
    html = render_until(cart_view, title)
    assert html =~ title

    cart_view
    |> element("form[phx-submit='update_qty']")
    |> render_submit(%{"variant_id" => variant_id, "qty" => "4"})

    assert {:ok, query} = CartLoadQuery.new(%{"include_items" => true})
    assert {:ok, cart_view_after_update} = CartsFacade.get_cart_view_for_user(nil, token, query)
    assert [%{qty: 4}] = Enum.filter(cart_view_after_update.items, &(&1.variant_id == variant_id))

    cart_view
    |> element("#remove-#{variant_id}")
    |> render_click()

    assert render(cart_view) =~ "Your cart is empty."
  end

  test "start checkout redirects to checkout page with checkout_key", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    {:ok, cart_view, _html} = live(conn, ~p"/cart")
    _ = render_until(cart_view, "Start Checkout")
    cart_view |> element("#start-checkout") |> render_click()

    {redirect_path, _flash} = assert_redirect(cart_view)
    assert String.starts_with?(redirect_path, "/checkout?checkout_key=")

    %URI{query: query} = URI.parse(redirect_path)
    %{"checkout_key" => checkout_key} = URI.decode_query(query || "")
    assert {:error, denied} = Checkout.get_draft_for_user(nil, checkout_key)
    assert denied.code == "NOT_FOUND"
    assert {:ok, _draft} = Checkout.get_draft_for_user(%{cart_token: token}, checkout_key)
  end

  test "/cart static pass emits zero-query mount telemetry", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)
    parent = self()
    handler = {__MODULE__, :cart_mount, System.unique_integer([:positive])}

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    :telemetry.attach(
      handler,
      [:store, :cart_live, :mount],
      fn _event, measurements, metadata, pid ->
        send(pid, {:cart_mount, measurements, metadata})
      end,
      parent
    )

    try do
      {:ok, view, _html} = live(conn, ~p"/cart")
      _ = render_until(view, "Start Checkout")

      assert_receive {:cart_mount, measurements, %{phase: :static} = metadata}
      assert measurements.query_count == 0
      assert metadata.result == :ok

      assert_receive {:cart_mount, measurements, %{phase: :live} = metadata}
      assert is_integer(measurements.query_count)
      assert metadata.result == :ok
    after
      :telemetry.detach(handler)
    end
  end

  test "/checkout renders phase 21 flow keyed by checkout_key", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{start_result.checkout_key}")
    html = render_until(view, "Continue To Payment")

    assert html =~ "Review shipping, finalize totals, then continue to payment."
    assert html =~ "Save Shipping"
    assert html =~ "Finalize Totals"
    assert html =~ "Continue To Payment"
  end

  test "PAY-INV-005: a forged Paystack return cannot start or settle payment", %{conn: conn} do
    %{variant_id: variant_id} = published_product_fixture()
    token = Ash.UUIDv7.generate()
    conn = with_cart_token(conn, token)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)

    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    configure_purchase_provider!(:paystack, [:paystack])
    reference = "checkout-" <> String.replace(start_result.order_id, "-", "")

    {:ok, view, _html} =
      live(
        conn,
        "/checkout/return?checkout_key=#{start_result.checkout_key}&reference=#{reference}&status=success"
      )

    html = render_until(view, "Payment return received.")

    assert html =~ "Payment return received. This page is read-only"
    refute has_element?(view, "#pay-now")

    assert render_click(view, "create_payment_intent", %{"provider" => "paystack"}) =~
             "Payment return received. This page is read-only"

    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^start_result.order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    assert order.state == :pending_payment
    assert Repo.get_by(PaymentIntent, order_id: start_result.order_id) == nil
  end

  test "checkout live shows explicit out-of-stock message on finalize failure", %{conn: conn} do
    checkout = setup_checkout_with_shipping!()
    conn = with_cart_token(conn, checkout.token)

    inventory = Repo.get_by!(InventoryItem, variant_id: checkout.variant_id)

    assert {:ok, _updated_inventory} =
             inventory
             |> Ash.Changeset.for_update(
               :set_on_hand,
               %{stock_on_hand: 0, allow_oversell: false},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
    _html = render_until(view, "Finalize Totals")

    view
    |> element("#finalize-totals")
    |> render_click()

    assert render(view) =~
             "One or more items are no longer available. Review your cart and try again."
  end

  test "two checkout tabs use the configured Paystack gateway and reuse the redirect", %{
    conn: conn
  } do
    buyer = TestFixtures.register_user!(email: TestFixtures.unique_email("paystack_live_buyer"))
    checkout = setup_checkout_with_shipping!(buyer, {"ZA", "WC", "8001", "ZAR"})
    reference = "checkout-" <> String.replace(checkout.order_id, "-", "")
    url = "https://checkout.paystack.com/test-liveview"
    test_pid = self()

    plug = fn %{method: "POST", request_path: "/transaction/initialize"} = conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"currency" => "ZAR", "reference" => ^reference} = Jason.decode!(body)
      send(test_pid, {:paystack_initialized, reference})

      Plug.Conn.send_resp(
        Plug.Conn.put_resp_content_type(conn, "application/json"),
        200,
        Jason.encode!(%{
          "status" => true,
          "data" => %{
            "reference" => reference,
            "authorization_url" => url,
            "access_code" => "test-liveview"
          }
        })
      )
    end

    configure_purchase_provider!(:paystack, [:stripe, :paystack],
      paystack: [restricted_key: "rk_test_fixture", request_options: [plug: plug]]
    )

    conn = conn |> with_cart_token(checkout.token) |> Helpers.store_in_session(buyer)
    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
    _html = render_until(view, "Finalize Totals")
    assert view |> element("#finalize-totals") |> render_click() =~ "Totals finalized"

    {:ok, other_tab, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
    _html = render_until(other_tab, "Continue To Payment")

    assert {:error, {:redirect, %{to: ^url}}} =
             view |> element("#pay-now") |> render_click(%{"provider" => "stripe"})

    assert_receive {:paystack_initialized, ^reference}

    assert {:error, {:redirect, %{to: ^url}}} =
             other_tab |> element("#pay-now") |> render_click()

    refute_received {:paystack_initialized, _}

    assert %PaymentIntent{provider: :paystack, provider_request_reference: ^reference} =
             Repo.get_by!(PaymentIntent, order_id: checkout.order_id)
  end

  test "checkout Pay still starts Stripe checkout when Stripe is configured",
       %{conn: conn} = context do
    StripeAPIStub.setup_default(context)
    configure_purchase_provider!(:stripe, [:stripe])
    checkout = setup_checkout_with_shipping!()
    conn = with_cart_token(conn, checkout.token)
    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
    _html = render_until(view, "Finalize Totals")
    assert view |> element("#finalize-totals") |> render_click() =~ "Totals finalized"

    assert {:error, {:redirect, %{to: "https://checkout.stripe.test/session/" <> _}}} =
             view |> element("#pay-now") |> render_click()

    assert %PaymentIntent{provider: :stripe} =
             Repo.get_by!(PaymentIntent, order_id: checkout.order_id)
  end

  test "digital checkout collects billing location and never renders shipping controls", %{
    conn: conn
  } do
    buyer = TestFixtures.register_user!(email: TestFixtures.unique_email("digital_buyer"))
    %{variant_id: variant_id} = published_product_fixture("ZAR", :digital)
    create_pricing_rules!("ZA", "WC", "ZAR")
    token = Ash.UUIDv7.generate()
    {:ok, add} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _} = CartsFacade.add_item_for_user(buyer, token, add)
    {:ok, start} = CheckoutStartInput.new(%{})
    assert {:ok, checkout} = Checkout.start_from_cart(buyer, token, start)

    conn = conn |> with_cart_token(token) |> Helpers.store_in_session(buyer)
    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
    _html = render_until(view, "Finalize Totals")

    refute has_element?(view, "form[phx-submit=set_shipping]")
    refute has_element?(view, "#checkout-shipping-total")
    assert has_element?(view, "#pay-now[disabled]")

    assert view
           |> form("#digital-billing", %{
             "billing_country_code" => "ZA",
             "billing_region_code" => "WC"
           })
           |> render_submit() =~ "ZAR 21.60"

    refute has_element?(view, "form[phx-submit=set_shipping]")
    refute has_element?(view, "#pay-now[disabled]")
  end

  test "checkout cannot start payment using a disabled default gateway", %{conn: conn} do
    checkout = setup_checkout_with_shipping!()
    configure_purchase_provider!(:paystack, [:stripe])
    conn = with_cart_token(conn, checkout.token)
    {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
    _html = render_until(view, "Finalize Totals")
    assert view |> element("#finalize-totals") |> render_click() =~ "Totals finalized"
    assert has_element?(view, "#pay-now[disabled]")

    assert render_click(view, "create_payment_intent", %{"provider" => "stripe"}) =~
             "Payment is currently unavailable."

    assert Repo.get_by(PaymentIntent, order_id: checkout.order_id) == nil
  end

  test "/checkout static pass emits zero-query mount telemetry and expired pending checkout updates live",
       %{conn: conn} do
    parent = self()
    handler = {__MODULE__, :checkout_mount, System.unique_integer([:positive])}
    checkout = setup_checkout_with_shipping!()
    conn = with_cart_token(conn, checkout.token)

    order =
      Repo.get!(Order, checkout.order_id)
      |> Ash.Changeset.for_update(
        :begin_provider_setup,
        %{provider_setup_started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    :telemetry.attach(
      handler,
      [:store, :checkout_live, :mount],
      fn _event, measurements, metadata, pid ->
        send(pid, {:checkout_mount, measurements, metadata})
      end,
      parent
    )

    try do
      {:ok, view, _html} = live(conn, "/checkout?checkout_key=#{checkout.checkout_key}")
      html = render_until(view, "Payment setup is already in progress for this order.")

      assert html =~ "Payment setup is already in progress for this order."

      assert_receive {:checkout_mount, measurements, %{phase: :static} = metadata}
      assert measurements.query_count == 0
      assert metadata.result == :ok

      assert_receive {:checkout_mount, measurements, %{phase: :live} = metadata}
      assert is_integer(measurements.query_count)
      assert metadata.result == :ok

      Phoenix.PubSub.broadcast(
        Store.PubSub,
        Orders.order_topic(order.id),
        {:order_state_changed, order.id, :cancelled, :pending_provider_setup_expired,
         DateTime.utc_now() |> DateTime.truncate(:microsecond)}
      )

      assert render_until(view, "This checkout expired before payment setup completed.") =~
               "This checkout expired before payment setup completed."

      assert has_element?(view, "a[href='/cart']", "Restart Checkout")
    after
      :telemetry.detach(handler)
    end
  end

  defp with_cart_token(conn, token) do
    conn
    |> init_test_session(%{})
    |> Plug.Test.put_req_cookie("cart_token", token)
  end

  defp published_product_fixture(currency \\ "USD", kind \\ :simple) do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("phase20_live_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    slug = "phase20-live-#{System.unique_integer([:positive])}"

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: slug,
          title: "Phase 20 Live Product",
          product_kind: kind,
          base_variant_sku: "P20-LIVE-#{System.unique_integer([:positive])}",
          base_variant_currency_code: currency,
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 25
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    %{slug: published.slug, title: published.title, variant_id: published.default_variant_id}
  end

  defp setup_checkout_with_shipping!(
         buyer \\ nil,
         {country, region, postal, currency} \\ {"US", "CA", "94105", "USD"}
       ) do
    %{variant_id: variant_id} = published_product_fixture(currency)
    token = Ash.UUIDv7.generate()
    actor = buyer || %{cart_token: token}
    _shipping_setup = create_pricing_rules!(country, region, currency)

    assert {:ok, add_input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(buyer, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, start_result} = Checkout.start_from_cart(buyer, token, start_input)

    selection =
      quote_selection!(%{
        destination_country_code: country,
        destination_region_code: region,
        destination_postal_code: postal,
        currency_code: currency,
        shipping_weight_grams: 0
      })

    assert {:ok, shipping_input} =
             CheckoutShippingInput.new(%{
               "recipient_name" => "Jane Customer",
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => country,
               "region_code" => region,
               "postal_code" => postal,
               "phone" => "555-555-1212",
               "quote_hash" => selection.quote_hash,
               "shipping_method_code" => selection.shipping_method_code
             })

    assert {:ok, _checkout} =
             Checkout.set_shipping(actor, start_result.checkout_key, shipping_input)

    %{
      token: token,
      checkout_key: start_result.checkout_key,
      order_id: start_result.order_id,
      variant_id: variant_id
    }
  end

  defp configure_purchase_provider!(provider, enabled, extra \\ []) do
    previous = Application.get_env(:store, :payments, [])

    config =
      Keyword.merge(extra, default_purchase_provider_for_ui: provider, enabled_providers: enabled)

    Application.put_env(:store, :payments, Keyword.merge(previous, config))
    on_exit(fn -> Application.put_env(:store, :payments, previous) end)
  end

  defp create_pricing_rules!(country, region, currency) do
    unique = System.unique_integer([:positive])
    method_code = "GROUND-#{unique}"

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: method_code, name: "Ground #{unique}", active: true, sort_order: 100},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "#{country}-#{region}-#{unique}",
          country_code: country,
          region_code: region,
          active: true
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _rate =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND_RULE_#{unique}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: currency,
          shipping_cost_minor: 500,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "#{region}-STANDARD-#{unique}",
          country_code: country,
          region_code: region,
          product_tax_category: "STANDARD",
          rate_basis_points: 800,
          shipping_taxable: true,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})
  end

  defp quote_selection!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

    %{
      quote_hash: option.quote_hash,
      shipping_method_code: option.shipping_method_code
    }
  end

  defp render_until(view, needle, attempts \\ 20)

  defp render_until(view, needle, attempts) when attempts > 0 do
    html = render(view)

    if html =~ needle do
      html
    else
      Process.sleep(20)
      render_until(view, needle, attempts - 1)
    end
  end

  defp render_until(view, _needle, 0), do: render(view)
end
