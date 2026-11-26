defmodule StoreWeb.AdminLiveTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Store.Catalog.Product
  alias Store.Repo
  alias Store.TestFixtures

  test "redirects unauthenticated users to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/subscriptions")
  end

  test "redirects authenticated customer away from admin route", %{conn: conn} do
    user = signed_in_user(TestFixtures.unique_email("customer"))

    conn =
      conn
      |> init_test_session(%{})
      |> Helpers.store_in_session(user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/subscriptions")
  end

  test "allows super_admin to access admin route", %{conn: conn} do
    super_admin = signed_in_user(TestFixtures.unique_email("super_admin"))
    _role = TestFixtures.assign_role!(super_admin, :super_admin)

    conn =
      conn
      |> init_test_session(%{})
      |> Helpers.store_in_session(super_admin)

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Admin Console"
    assert {:ok, _view, _html} = live(conn, ~p"/admin/subscriptions")
  end

  test "allows support into subscriptions route but not admin dashboard", %{conn: conn} do
    support_user = signed_in_user(TestFixtures.unique_email("support"))
    _role = TestFixtures.assign_role!(support_user, :support)

    conn =
      conn
      |> init_test_session(%{})
      |> Helpers.store_in_session(support_user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    assert {:ok, _view, _html} = live(conn, ~p"/admin/subscriptions")
  end

  test "an admin can create a digital download product", %{conn: conn} do
    admin = signed_in_user(TestFixtures.unique_email("digital_catalog_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)
    conn = conn |> init_test_session(%{}) |> Helpers.store_in_session(admin)
    assert {:ok, view, _html} = live(conn, ~p"/admin/products/new")
    slug = "newyou-download-#{System.unique_integer([:positive])}"

    assert has_element?(
             view,
             "#product-form select[name='product[product_kind]'] option[value=digital]"
           )

    view
    |> form("#product-form", %{
      "product" => %{
        "slug" => slug,
        "title" => "NewYou download",
        "product_kind" => "digital",
        "base_variant_sku" => slug,
        "base_variant_currency_code" => "ZAR",
        "base_variant_price_minor" => "2000",
        "base_variant_stock_on_hand" => "0"
      }
    })
    |> render_submit()

    assert %Product{product_kind: :digital, status: :draft} = Repo.get_by!(Product, slug: slug)
  end

  defp signed_in_user(email) do
    _registered_user = TestFixtures.register_user!(email: email)
    TestFixtures.sign_in_user!(email)
  end
end
