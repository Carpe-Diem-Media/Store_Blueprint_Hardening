defmodule Store.Catalog.FacadePublicProductTest do
  use Store.DataCase, async: false

  use Oban.Testing, repo: Store.DirectRepo

  alias Store.Catalog.Facade, as: CatalogFacade
  alias Store.Catalog.Product
  alias Store.Catalog.Queries.{ProductDetailQuery, ProductIndexQuery}
  alias Store.Catalog.Types.ProductDetail
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestFixtures

  test "get_product_for_public returns a published product by slug" do
    %{slug: slug} = published_product_fixture()

    assert {:ok, product} = CatalogFacade.get_product_for_public(nil, slug)
    assert %Product{} = product
    assert product.slug == slug
    assert product.status == :published
  end

  test "get_product_detail_for_public returns the ProductDetail contract" do
    %{slug: slug} = published_product_fixture()

    assert {:ok, query} = ProductDetailQuery.new(%{slug: slug, selection: %{}})
    assert {:ok, detail} = CatalogFacade.get_product_detail_for_public(nil, query)
    assert %ProductDetail{} = detail
    assert %Product{} = detail.product
    assert is_list(detail.options)
    assert is_map(detail.selected)
    assert %ProductDetail.Resolution{} = detail.resolution
    assert is_list(detail.availability_matrix)
  end

  test "published digital variations remain purchasable with zero physical stock" do
    digital = published_product_fixture(:digital, 0)
    physical = published_product_fixture(:simple, 0)

    for {product, status, reason} <- [{digital, :ok, nil}, {physical, :error, :out_of_stock}] do
      {:ok, query} = ProductDetailQuery.new(%{slug: product.slug, selection: %{}})

      assert {:ok, %{resolution: %{status: ^status, reason: ^reason}}} =
               CatalogFacade.get_product_detail_for_public(nil, query)
    end
  end

  test "get_product_detail_for_public emits catalog detail telemetry with repo and payload diagnostics" do
    %{slug: slug} = published_product_fixture()
    parent = self()
    handler_id = {__MODULE__, :catalog_detail, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:store, :catalog, :product_detail, :public],
      fn _event, measurements, metadata, pid ->
        send(pid, {:catalog_detail, measurements, metadata})
      end,
      parent
    )

    try do
      assert {:ok, query} = ProductDetailQuery.new(%{slug: slug, selection: %{}})
      assert {:ok, %ProductDetail{}} = CatalogFacade.get_product_detail_for_public(nil, query)

      assert_receive {:catalog_detail, measurements, metadata}
      assert metadata.slug == slug
      assert metadata.selection_count == 0
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)
      assert measurements.query_count > 0
      assert is_integer(measurements.encoded_payload_bytes)
      assert measurements.encoded_payload_bytes > 0
      assert is_integer(measurements.option_count)
      assert is_integer(measurements.option_value_count)
      assert is_integer(measurements.variant_row_count)
      assert is_integer(measurements.availability_cell_count)
      assert is_integer(measurements.availability_value_count)
    after
      :telemetry.detach(handler_id)
    end
  end

  test "get_product_detail_for_public keeps subscription plan option loading query count bounded" do
    %{product: product, variant: variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_price_minor: 1_000
      })

    monthly_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "perf-monthly",
        name: "Perf Monthly",
        amount_minor: 1_999
      })

    yearly_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "perf-yearly",
        name: "Perf Yearly",
        amount_minor: 19_999
      })

    _monthly_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, monthly_plan.id)
    _yearly_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, yearly_plan.id)

    assert {:ok, query} =
             ProductDetailQuery.new(%{
               slug: product.slug,
               selection: %{},
               subscription_plan_key: yearly_plan.key
             })

    {result, stats} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        RepoStats.capture(fn ->
          CatalogFacade.get_product_detail_for_public(nil, query)
        end)
      end)

    assert {:ok, detail} = result
    assert detail.subscription_plan_required?
    assert length(detail.subscription_plan_options) == 2
    assert detail.selected_subscription_plan_id == yearly_plan.id
    assert stats.query_count <= 8
  end

  test "list_products_for_public emits cold then hot cache telemetry" do
    %{title: title} = published_product_fixture()
    parent = self()
    handler_id = {__MODULE__, :catalog_product_list, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:store, :catalog, :product_list],
      fn _event, measurements, metadata, pid ->
        send(pid, {:catalog_product_list, measurements, metadata})
      end,
      parent
    )

    try do
      assert {:ok, query} = ProductIndexQuery.new(%{"q" => title, "page_size" => "10"})
      assert {:ok, [_product | _]} = CatalogFacade.list_products_for_public(nil, query)
      assert {:ok, [_product | _]} = CatalogFacade.list_products_for_public(nil, query)

      assert_receive {:catalog_product_list, first_measurements, first_metadata}
      assert_receive {:catalog_product_list, second_measurements, second_metadata}

      assert first_metadata.cache == "miss"
      assert first_metadata.layer == "cold"
      assert first_metadata.result == :ok
      assert is_binary(first_metadata.cache_key)
      assert first_measurements.result_count >= 1

      assert second_metadata.cache == "hit"
      assert second_metadata.layer == "hot"
      assert second_metadata.result == :ok
      assert second_metadata.cache_key == first_metadata.cache_key
      assert second_measurements.result_count == first_measurements.result_count
    after
      :telemetry.detach(handler_id)
    end
  end

  test "list_product_cards_for_public returns plain map view models" do
    %{title: title} = published_product_fixture()

    assert {:ok, query} = ProductIndexQuery.new(%{"q" => title, "page_size" => "10"})
    assert {:ok, [product | _]} = CatalogFacade.list_product_cards_for_public(nil, query)

    assert is_map(product)
    refute match?(%Product{}, product)
    assert is_binary(product.slug)
    assert is_binary(product.title)
    assert is_map(product.default_variant)
    assert Map.has_key?(product.default_variant, :price_minor)
  end

  defp published_product_fixture(kind \\ :simple, stock \\ 10) do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("shop_public_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)
    slug = "shop-public-#{System.unique_integer([:positive])}"

    title = "Shop Public Product #{System.unique_integer([:positive])}"

    product =
      Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: slug,
          title: title,
          product_kind: kind,
          base_variant_sku: "SHOP-PUBLIC-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: stock
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    Map.put(published, :title, title)
  end
end
