defmodule Store.Carts.Facade do
  @moduledoc """
  Consumer-scoped cart surfaces for user/guest storefront flows.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Store.Carts.{Cart, CartItem}
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Catalog.{Product, ProductOption, StockFastPath, Variant, VariantOptionSelection}
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.ID.{BinaryUuidSort, UUIDv7}
  alias Store.Support.Telemetry.RepoStats

  @telemetry_prefix [:store, :carts]

  @spec get_cart_for_user(map() | nil, String.t()) :: {:ok, Cart.t()} | {:error, Error.t()}
  def get_cart_for_user(actor, token) when is_binary(token) do
    started_at = System.monotonic_time()

    result =
      with :ok <- validate_token(token) do
        fetch_or_create_cart(actor, token)
      end

    emit_get_telemetry(started_at, actor_scope(actor), result)
    normalize_result(result)
  end

  def get_cart_for_user(_actor, _token) do
    {:error, Error.new("VALIDATION_ERROR", "token must be a string")}
  end

  @spec get_cart_view_for_user(map() | nil, String.t(), CartLoadQuery.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_cart_view_for_user(actor, token, %CartLoadQuery{} = query) when is_binary(token) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, cart} <- get_cart_for_user(actor, token) do
          build_cart_view(cart, query)
        end
      end)

    emit_get_telemetry(started_at, actor_scope(actor), result)
    emit_step_telemetry(:load_view, started_at, result, repo_stats)
    normalize_result(result)
  end

  @spec add_item_for_user(map() | nil, String.t(), CartItemInput.t()) ::
          {:ok, Cart.t()} | {:error, Error.t()}
  def add_item_for_user(actor, token, %CartItemInput{} = input) when is_binary(token) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, cart} <- get_cart_for_user(actor, token),
             :ok <- ensure_variant_sellable(input),
             :ok <-
               SubscriptionsFacade.ensure_membership_purchase_allowed_for_system(
                 cart.user_id,
                 input.subscription_plan_id
               ) do
          add_item_transaction(cart, input)
        end
      end)

    emit_mutate_telemetry(started_at, :add, actor_scope(actor), result)
    emit_step_telemetry(:add_item, started_at, result, repo_stats)
    normalize_result(result)
  end

  @spec update_item_qty_for_user(map() | nil, String.t(), CartItemInput.t()) ::
          {:ok, Cart.t()} | {:error, Error.t()}
  def update_item_qty_for_user(actor, token, %CartItemInput{} = input) when is_binary(token) do
    started_at = System.monotonic_time()

    result =
      with {:ok, cart} <- get_cart_for_user(actor, token),
           :ok <- ensure_variant_sellable(input) do
        update_qty_transaction(cart, input)
      end

    emit_mutate_telemetry(started_at, :update, actor_scope(actor), result)
    normalize_result(result)
  end

  @spec remove_item_for_user(map() | nil, String.t(), Ecto.UUID.t()) ::
          {:ok, Cart.t()} | {:error, Error.t()}
  def remove_item_for_user(actor, token, variant_id)
      when is_binary(token) and is_binary(variant_id) do
    started_at = System.monotonic_time()

    result =
      with {:ok, cart} <- get_cart_for_user(actor, token),
           :ok <- validate_uuid(variant_id, "variant_id must be a valid UUID") do
        remove_item_transaction(cart, variant_id)
      end

    emit_mutate_telemetry(started_at, :remove, actor_scope(actor), result)
    normalize_result(result)
  end

  def remove_item_for_user(_actor, _token, _variant_id) do
    {:error, Error.new("VALIDATION_ERROR", "token and variant_id must be strings")}
  end

  @spec merge_token_into_user_for_user(map(), String.t()) ::
          {:ok, :merged | :noop} | {:error, Error.t()}
  def merge_token_into_user_for_user(%{id: user_id} = user, token)
      when is_binary(user_id) and is_binary(token) do
    started_at = System.monotonic_time()

    result =
      with :ok <- validate_token(token),
           :ok <- validate_uuid(user_id, "user id must be a valid UUID") do
        merge_token_into_user_transaction(user, token)
      end

    emit_merge_telemetry(started_at, result)
    normalize_result(result)
  end

  def merge_token_into_user_for_user(_user, _token) do
    {:error, Error.new("VALIDATION_ERROR", "user and token are required")}
  end

  defp fetch_or_create_cart(actor, token) do
    lookup = cart_lookup(actor, token)

    case lookup_active_cart(lookup) do
      {:ok, %Cart{} = cart} -> {:ok, cart}
      {:ok, nil} -> create_cart_for_lookup(lookup, token)
    end
  end

  defp cart_lookup(%{id: user_id}, _token) when is_binary(user_id), do: {:user, user_id}
  defp cart_lookup(_actor, token), do: {:token, token}

  defp lookup_active_cart({:user, user_id}) do
    cart =
      Cart
      |> where([c], c.status == :active and c.user_id == ^user_id)
      |> order_by([c], asc: c.inserted_at, asc: c.id)
      |> limit(1)
      |> Repo.one()

    {:ok, cart}
  end

  defp lookup_active_cart({:token, token}) do
    cart =
      Cart
      |> where([c], c.status == :active and c.token == ^token)
      |> order_by([c], asc: c.inserted_at, asc: c.id)
      |> limit(1)
      |> Repo.one()

    {:ok, cart}
  end

  defp create_cart_for_lookup({:user, user_id}, _token) do
    attrs = %{token: UUIDv7.generate(), user_id: user_id, status: :active, version: 1}

    case insert_cart(attrs) do
      {:ok, cart} -> {:ok, cart}
      {:error, %Error{code: "STALE_RECORD"}} -> lookup_active_cart({:user, user_id})
      {:error, _} = error -> error
    end
  end

  defp create_cart_for_lookup({:token, token}, _requested_token) do
    attrs = %{token: token, status: :active, version: 1}

    case insert_cart(attrs) do
      {:ok, cart} -> {:ok, cart}
      {:error, %Error{code: "STALE_RECORD"}} -> lookup_active_cart({:token, token})
      {:error, _} = error -> error
    end
  end

  defp insert_cart(attrs) do
    %Cart{}
    |> Changeset.change(attrs)
    |> Repo.insert()
    |> case do
      {:ok, cart} -> maybe_reload_cart(cart, attrs)
      {:error, %Ecto.Changeset{} = error} -> {:error, normalize_db_error(error)}
    end
  end

  defp maybe_reload_cart(%Cart{id: nil}, %{token: token}) when is_binary(token) do
    case lookup_active_cart({:token, token}) do
      {:ok, %Cart{} = cart} -> {:ok, cart}
      _ -> {:error, Error.new("INTERNAL_ERROR", "unable to load cart after create")}
    end
  end

  defp maybe_reload_cart(%Cart{} = cart, _attrs), do: {:ok, cart}

  defp build_cart_view(%Cart{} = cart, %CartLoadQuery{include_items: true}) do
    items = load_cart_items_for_view(cart.id)
    {variants_by_id, products_by_id} = catalog_maps_for_view(items)

    line_items =
      Enum.map(items, fn item ->
        variant = Map.get(variants_by_id, item.variant_id)
        product = variant && Map.get(products_by_id, variant.product_id)

        %{
          id: item.id,
          variant_id: item.variant_id,
          subscription_plan_id: item.subscription_plan_id,
          qty: item.qty,
          sku: variant && variant.sku,
          variant_title: variant && variant.title,
          product_title: product && product.title,
          product_slug: product && product.slug,
          price_minor: variant && variant.price_minor,
          currency_code: variant && variant.currency_code,
          line_total_minor: line_total(variant, item.qty)
        }
      end)

    subtotal_minor = Enum.reduce(line_items, 0, &(&1.line_total_minor + &2))
    item_count = Enum.reduce(line_items, 0, &(&1.qty + &2))

    {:ok,
     %{
       cart_id: cart.id,
       token: cart.token,
       user_id: cart.user_id,
       status: cart.status,
       version: cart.version,
       item_count: item_count,
       subtotal_minor: subtotal_minor,
       items: line_items
     }}
  end

  defp build_cart_view(%Cart{} = cart, %CartLoadQuery{include_items: false}) do
    {:ok,
     %{
       cart_id: cart.id,
       token: cart.token,
       user_id: cart.user_id,
       status: cart.status,
       version: cart.version,
       item_count: 0,
       subtotal_minor: 0,
       items: []
     }}
  end

  defp load_cart_items(cart_id) do
    CartItem
    |> where([i], i.cart_id == ^cart_id)
    |> order_by([i], asc: i.inserted_at, asc: i.id)
    |> Repo.all()
  end

  defp load_cart_items_for_view(cart_id) do
    CartItem
    |> where([i], i.cart_id == ^cart_id)
    |> order_by([i], asc: i.inserted_at, asc: i.id)
    |> select([i], %{
      id: i.id,
      cart_id: i.cart_id,
      variant_id: i.variant_id,
      subscription_plan_id: i.subscription_plan_id,
      qty: i.qty
    })
    |> Repo.all()
  end

  defp catalog_maps_for_view(items) do
    variant_ids =
      items
      |> Enum.map(& &1.variant_id)
      |> Enum.uniq()

    variants =
      if variant_ids == [] do
        []
      else
        Variant
        |> where([v], v.id in ^variant_ids)
        |> select([v], %{
          id: v.id,
          product_id: v.product_id,
          sku: v.sku,
          title: v.title,
          price_minor: v.price_minor,
          currency_code: v.currency_code
        })
        |> Repo.all()
      end

    products =
      variants
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()
      |> case do
        [] ->
          []

        product_ids ->
          Product
          |> where([p], p.id in ^product_ids)
          |> select([p], %{id: p.id, title: p.title, slug: p.slug})
          |> Repo.all()
      end

    {Map.new(variants, &{&1.id, &1}), Map.new(products, &{&1.id, &1})}
  end

  defp line_total(%Variant{price_minor: price_minor}, qty) when is_integer(price_minor),
    do: price_minor * qty

  defp line_total(%{price_minor: price_minor}, qty) when is_integer(price_minor),
    do: price_minor * qty

  defp line_total(_variant, _qty), do: 0

  defp add_item_transaction(%Cart{} = cart, %CartItemInput{} = input) do
    cart_id = cart.id

    Repo.transaction(fn ->
      locked_cart = lock_cart!(cart_id)
      locked_item = lock_cart_item(cart_id, input.variant_id, input.subscription_plan_id)
      desired_qty = desired_add_qty(locked_item, input.qty)
      :ok = ensure_fast_stock!(input.variant_id, desired_qty)

      mutation? = add_or_merge_item!(locked_cart.id, locked_item, input)

      bumped_cart = maybe_bump_version!(locked_cart, mutation?)
      load_cart_with_items!(bumped_cart)
    end)
    |> unwrap_transaction()
  end

  defp update_qty_transaction(%Cart{} = cart, %CartItemInput{} = input) do
    cart_id = cart.id

    Repo.transaction(fn ->
      locked_cart = lock_cart!(cart_id)

      case lock_cart_item(cart_id, input.variant_id, input.subscription_plan_id) do
        nil ->
          Repo.rollback(Error.new("NOT_FOUND", "cart item not found"))

        %CartItem{} = item ->
          :ok = ensure_fast_stock_for_update!(input.variant_id, item.qty, input.qty)
          mutation? = maybe_update_item_qty!(item.id, item.qty, input.qty)

          bumped_cart = maybe_bump_version!(locked_cart, mutation?)
          load_cart_with_items!(bumped_cart)
      end
    end)
    |> unwrap_transaction()
  end

  defp remove_item_transaction(%Cart{} = cart, variant_id) do
    cart_id = cart.id

    Repo.transaction(fn ->
      locked_cart = lock_cart!(cart_id)

      mutation? =
        case lock_cart_item_any_plan(cart_id, variant_id) do
          nil ->
            false

          %CartItem{} = item ->
            Repo.delete!(item)
            true
        end

      bumped_cart = maybe_bump_version!(locked_cart, mutation?)
      load_cart_with_items!(bumped_cart)
    end)
    |> unwrap_transaction()
  end

  defp merge_token_into_user_transaction(%{id: user_id}, token) do
    Repo.transaction(fn ->
      token
      |> lock_active_cart_by_token()
      |> maybe_merge_guest_into_user_cart!(user_id)
    end)
    |> unwrap_transaction()
  end

  defp maybe_merge_guest_into_user_cart!(nil, _user_id), do: :noop

  defp maybe_merge_guest_into_user_cart!(%Cart{merged_into_cart_id: merged_id}, _user_id)
       when is_binary(merged_id),
       do: :noop

  defp maybe_merge_guest_into_user_cart!(%Cart{user_id: user_id}, user_id), do: :noop

  defp maybe_merge_guest_into_user_cart!(%Cart{} = guest_cart, user_id) do
    user_cart = lock_or_create_user_cart!(user_id)

    if user_cart.id == guest_cart.id do
      :noop
    else
      merged? = merge_guest_items_into_user_cart!(guest_cart.id, user_cart.id)
      _ = maybe_bump_version!(user_cart, merged?)
      abandon_merged_guest_cart!(guest_cart, user_cart.id)
      :merged
    end
  end

  defp merge_guest_items_into_user_cart!(guest_cart_id, user_cart_id) do
    guest_items =
      CartItem
      |> where([i], i.cart_id == ^guest_cart_id)
      |> Repo.all()
      |> Enum.sort_by(fn item -> BinaryUuidSort.normalize_raw16!(item.variant_id) end)

    Enum.reduce(guest_items, false, fn guest_item, merged? ->
      merged? or merge_guest_item_into_user_cart!(guest_item, user_cart_id)
    end)
  end

  defp merge_guest_item_into_user_cart!(%CartItem{} = guest_item, user_cart_id) do
    case lock_cart_item(user_cart_id, guest_item.variant_id, guest_item.subscription_plan_id) do
      nil ->
        insert_cart_item!(
          user_cart_id,
          guest_item.variant_id,
          guest_item.subscription_plan_id,
          guest_item.qty
        )

        true

      %CartItem{} = user_item ->
        desired_qty = min(user_item.qty + guest_item.qty, CartItemInput.max_qty())
        maybe_update_item_qty!(user_item.id, user_item.qty, desired_qty)
    end
  end

  defp abandon_merged_guest_cart!(%Cart{} = guest_cart, merged_into_cart_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated, _} =
      Cart
      |> where([c], c.id == ^guest_cart.id and c.version == ^guest_cart.version)
      |> Repo.update_all(
        set: [
          status: :abandoned,
          merged_into_cart_id: merged_into_cart_id,
          version: guest_cart.version + 1,
          updated_at: now
        ]
      )

    if updated != 1 do
      Repo.rollback(Error.new("STALE_RECORD", "guest cart merge state changed during merge"))
    end
  end

  defp lock_or_create_user_cart!(user_id) do
    case lock_active_cart_by_user_id(user_id) do
      %Cart{} = cart ->
        cart

      nil ->
        case insert_cart(%{
               token: UUIDv7.generate(),
               user_id: user_id,
               status: :active,
               version: 1
             }) do
          {:ok, _} ->
            lock_active_cart_by_user_id(user_id) ||
              Repo.rollback(Error.new("INTERNAL_ERROR", "unable to load user cart after create"))

          {:error, %Error{code: "STALE_RECORD"}} ->
            lock_active_cart_by_user_id(user_id) ||
              Repo.rollback(
                Error.new("INTERNAL_ERROR", "unable to load user cart after conflict")
              )

          {:error, error} ->
            Repo.rollback(error)
        end
    end
  end

  defp lock_active_cart_by_token(token) do
    Cart
    |> where([c], c.token == ^token and c.status == :active)
    |> lock("FOR UPDATE")
    |> limit(1)
    |> Repo.one()
  end

  defp lock_active_cart_by_user_id(user_id) do
    Cart
    |> where([c], c.user_id == ^user_id and c.status == :active)
    |> lock("FOR UPDATE")
    |> limit(1)
    |> Repo.one()
  end

  defp lock_cart!(nil), do: Repo.rollback(Error.new("NOT_FOUND", "active cart not found"))

  defp lock_cart!(cart_id) do
    case Cart
         |> where([c], c.id == ^cart_id and c.status == :active)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %Cart{} = cart -> cart
      nil -> Repo.rollback(Error.new("NOT_FOUND", "active cart not found"))
    end
  end

  defp load_cart_with_items!(%Cart{} = cart) do
    %{cart | items: load_cart_items(cart.id)}
  end

  defp lock_cart_item(cart_id, variant_id, subscription_plan_id) do
    query =
      CartItem
      |> where([i], i.cart_id == ^cart_id and i.variant_id == ^variant_id)
      |> maybe_filter_subscription_plan(subscription_plan_id)
      |> lock("FOR UPDATE")

    Repo.one(query)
  end

  defp lock_cart_item_any_plan(cart_id, variant_id) do
    CartItem
    |> where([i], i.cart_id == ^cart_id and i.variant_id == ^variant_id)
    |> order_by([i], asc: i.inserted_at, asc: i.id)
    |> lock("FOR UPDATE")
    |> limit(1)
    |> Repo.one()
  end

  defp add_or_merge_item!(cart_id, nil, %CartItemInput{} = input) do
    insert_cart_item!(cart_id, input.variant_id, input.subscription_plan_id, input.qty)
    true
  end

  defp add_or_merge_item!(_cart_id, %CartItem{} = item, %CartItemInput{} = input) do
    desired_qty = min(item.qty + input.qty, CartItemInput.max_qty())
    maybe_update_item_qty!(item.id, item.qty, desired_qty)
  end

  defp insert_cart_item!(cart_id, variant_id, subscription_plan_id, qty) do
    %CartItem{}
    |> Changeset.change(%{
      cart_id: cart_id,
      variant_id: variant_id,
      subscription_plan_id: subscription_plan_id,
      qty: qty
    })
    |> Repo.insert!()
  rescue
    _ -> Repo.rollback(Error.new("RESERVATION_CONFLICT", "unable to insert cart item"))
  end

  defp update_cart_item_qty!(item_id, qty) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated, _} =
      CartItem
      |> where([i], i.id == ^item_id)
      |> Repo.update_all(set: [qty: qty, updated_at: now])

    if updated != 1 do
      Repo.rollback(Error.new("STALE_RECORD", "unable to update cart item qty"))
    end
  end

  defp maybe_update_item_qty!(_item_id, current_qty, desired_qty) when current_qty == desired_qty,
    do: false

  defp maybe_update_item_qty!(item_id, _current_qty, desired_qty) do
    update_cart_item_qty!(item_id, desired_qty)
    true
  end

  defp maybe_bump_version!(%Cart{} = cart, false), do: cart

  defp maybe_bump_version!(%Cart{} = cart, true) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated, _} =
      Cart
      |> where([c], c.id == ^cart.id and c.version == ^cart.version)
      |> Repo.update_all(set: [version: cart.version + 1, updated_at: now])

    if updated == 1 do
      %{cart | version: cart.version + 1, updated_at: now}
    else
      Repo.rollback(Error.new("STALE_RECORD", "cart changed while applying mutation"))
    end
  end

  defp ensure_variant_exists(%CartItemInput{
         variant_id: variant_id,
         subscription_plan_id: plan_id
       }) do
    query =
      from(variant in Variant,
        join: product in Product,
        on: product.id == variant.product_id,
        where: variant.id == ^variant_id,
        select: {
          variant.id,
          variant.product_id,
          variant.status,
          product.status,
          product.published_at,
          product.product_kind
        }
      )

    case Repo.one(query) do
      {variant_id, product_id, :active, :published, %DateTime{}, product_kind} ->
        with :ok <- ensure_required_complete(variant_id, product_id) do
          ensure_subscription_plan_compatibility(variant_id, product_kind, plan_id)
        end

      {_variant_id, _product_id, _variant_status, _product_status, _published_at, _product_kind} ->
        {:error, Error.new("NOT_FOUND", "variant not sellable")}

      nil ->
        {:error, Error.new("NOT_FOUND", "variant not found")}
    end
  end

  defp ensure_variant_sellable(%CartItemInput{} = input), do: ensure_variant_exists(input)

  defp ensure_fast_stock!(variant_id, desired_qty) do
    case StockFastPath.precheck_variant_qty(variant_id, desired_qty) do
      :ok -> :ok
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, _} -> Repo.rollback(Error.new("OUT_OF_STOCK", "Insufficient available inventory"))
    end
  end

  defp ensure_fast_stock_for_update!(_variant_id, current_qty, desired_qty)
       when desired_qty <= current_qty,
       do: :ok

  defp ensure_fast_stock_for_update!(variant_id, _current_qty, desired_qty),
    do: ensure_fast_stock!(variant_id, desired_qty)

  defp desired_add_qty(nil, add_qty), do: add_qty

  defp desired_add_qty(%CartItem{} = item, add_qty),
    do: min(item.qty + add_qty, CartItemInput.max_qty())

  defp required_complete?(variant_id, product_id) do
    required_option_ids =
      ProductOption
      |> where([option], option.product_id == ^product_id and option.selection_required == true)
      |> select([option], option.id)
      |> Repo.all()

    if required_option_ids == [] do
      true
    else
      selected_required_count =
        VariantOptionSelection
        |> where([selection], selection.variant_id == ^variant_id)
        |> where([selection], selection.product_option_id in ^required_option_ids)
        |> select([selection], count(fragment("DISTINCT ?", selection.product_option_id)))
        |> Repo.one() || 0

      selected_required_count == length(required_option_ids)
    end
  end

  defp validate_token(token) when is_binary(token) do
    if String.trim(token) == "" do
      {:error, Error.new("VALIDATION_ERROR", "token must not be empty")}
    else
      :ok
    end
  end

  defp validate_token(_token),
    do: {:error, Error.new("VALIDATION_ERROR", "token must be a string")}

  defp validate_uuid(value, message) do
    if UUIDv7.valid?(value), do: :ok, else: {:error, Error.new("VALIDATION_ERROR", message)}
  end

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, %Error{} = error}), do: {:error, error}
  defp unwrap_transaction({:error, error}), do: {:error, normalize_db_error(error)}

  defp normalize_db_error(%Ecto.Changeset{} = changeset) do
    case first_constraint(changeset) do
      "carts_unique_active_token_index" ->
        Error.new("STALE_RECORD", "active cart already exists for token")

      "carts_unique_active_user_id_index" ->
        Error.new("STALE_RECORD", "active cart already exists for user")

      "cart_items_unique_cart_variant_no_plan_index" ->
        Error.new("STALE_RECORD", "cart item already exists for cart and variant")

      "cart_items_unique_cart_variant_plan_index" ->
        Error.new(
          "STALE_RECORD",
          "cart item already exists for cart, variant, and subscription plan"
        )

      _ ->
        Error.new("VALIDATION_ERROR", "invalid cart mutation")
    end
  end

  defp normalize_db_error(_), do: Error.new("INTERNAL_ERROR", "cart operation failed")

  defp first_constraint(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.find_value(fn
      {_field, {_message, opts}} ->
        opts[:constraint_name] || opts[:constraint]

      _ ->
        nil
    end)
    |> to_string()
  end

  defp actor_scope(%{id: _id}), do: :user
  defp actor_scope(_), do: :guest

  defp emit_get_telemetry(started_at, actor_scope, result) do
    :telemetry.execute(
      @telemetry_prefix ++ [:get],
      %{duration: System.monotonic_time() - started_at},
      %{actor_scope: actor_scope, result: telemetry_result(result)}
    )
  end

  defp emit_mutate_telemetry(started_at, action, actor_scope, result) do
    :telemetry.execute(
      @telemetry_prefix ++ [:mutate],
      %{duration: System.monotonic_time() - started_at},
      %{action: action, actor_scope: actor_scope, result: telemetry_result(result)}
    )
  end

  defp emit_merge_telemetry(started_at, result) do
    :telemetry.execute(
      @telemetry_prefix ++ [:merge],
      %{duration: System.monotonic_time() - started_at},
      %{result: telemetry_result(result)}
    )
  end

  defp emit_step_telemetry(step, started_at, result, repo_stats) when is_atom(step) do
    :telemetry.execute(
      @telemetry_prefix ++ [:step],
      %{
        duration: System.monotonic_time() - started_at,
        query_count: repo_stats.query_count,
        queue_time: repo_stats.queue_time,
        query_time: repo_stats.query_time,
        decode_time: repo_stats.decode_time
      },
      %{step: step, result: telemetry_result(result)}
    )
  end

  defp telemetry_result({:ok, :noop}), do: :noop
  defp telemetry_result({:ok, :merged}), do: :merged
  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result({:error, _}), do: :error

  defp maybe_filter_subscription_plan(query, nil),
    do: where(query, [i], is_nil(i.subscription_plan_id))

  defp maybe_filter_subscription_plan(query, subscription_plan_id),
    do: where(query, [i], i.subscription_plan_id == ^subscription_plan_id)

  defp ensure_required_complete(variant_id, product_id) do
    if required_complete?(variant_id, product_id) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "variant is not fully configured")}
    end
  end

  defp ensure_subscription_plan_compatibility(_variant_id, kind, nil)
       when kind in [:simple, :digital],
       do: :ok

  defp ensure_subscription_plan_compatibility(_variant_id, kind, _plan_id)
       when kind in [:simple, :digital] do
    {:error,
     Error.new("VALIDATION_ERROR", "subscription_plan_id is only valid for subscription products")}
  end

  defp ensure_subscription_plan_compatibility(variant_id, :subscription, plan_id) do
    with :ok <- ensure_subscription_purchase_enabled() do
      case SubscriptionsFacade.resolve_variant_subscription_plan_for_system(variant_id, plan_id) do
        {:ok, %Store.Subscriptions.SubscriptionPlan{}} ->
          :ok

        {:ok, nil} ->
          {:error,
           Error.new("VALIDATION_ERROR", "variant does not have an active subscription plan")}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    end
  end

  defp ensure_subscription_purchase_enabled do
    if subscription_feature_enabled?(:expose_purchase?) do
      :ok
    else
      {:error,
       Error.new(
         "SUBSCRIPTION_PURCHASE_DISABLED",
         "subscription purchase is currently disabled"
       )}
    end
  end

  defp subscription_feature_enabled?(key) when is_atom(key) do
    :store
    |> Application.get_env(:subscription_features, [])
    |> Keyword.get(key, false)
  end
end
