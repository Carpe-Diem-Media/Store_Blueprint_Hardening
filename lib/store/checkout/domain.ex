defmodule Store.Checkout do
  @moduledoc """
  Order-backed checkout orchestration domain.
  """

  use Ash.Domain

  import Ash.Expr
  import Ecto.Query

  require Ash.Query

  alias Ecto.Changeset
  alias Store.Carts.Cart
  alias Store.Carts.CartItem
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Catalog.{Product, ProductOption, Variant, VariantOptionSelection}
  alias Store.Checkout.CheckoutDraft
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Orders.{Order, OrderAdjustment, OrderLineItem}
  alias Store.Pricing.{TaxRate, TaxShippingContract, TaxShippingEvaluator}
  alias Store.Shipping
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.QuoteHash
  alias Store.Shipping.Types.QuoteEvidence
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.{PlanRevision, SubscriptionPlan, VariantSubscriptionPlan}

  alias Store.Repo
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.Telemetry.RepoStats

  resources do
    resource(Store.Checkout.CheckoutDraft)
  end

  @spec start_from_cart(map() | nil, String.t(), CheckoutStartInput.t()) ::
          {:ok,
           %{
             checkout_key: String.t(),
             draft_id: Ecto.UUID.t(),
             cart_id: Ecto.UUID.t(),
             cart_version: pos_integer(),
             order_id: Ecto.UUID.t(),
             order_ref: String.t(),
             duplicate?: boolean()
           }}
          | {:error, Error.t()}
  def start_from_cart(actor, token, %CheckoutStartInput{} = _input) when is_binary(token) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, cart} <-
               CartsFacade.get_cart_for_user(actor, token) |> with_checkout_stage(:cart_load),
             {:ok, draft, order, duplicate?} <- get_or_create_checkout(cart) do
          {:ok,
           %{
             checkout_key: draft.checkout_key,
             draft_id: draft.id,
             cart_id: draft.cart_id,
             cart_version: draft.cart_version,
             order_id: order.id,
             order_ref: order.order_ref,
             duplicate?: duplicate?
           }}
        end
      end)

    :telemetry.execute(
      [:store, :checkout, :start_from_cart],
      %{duration: System.monotonic_time() - started_at},
      %{result: telemetry_result(result)}
    )

    emit_step_telemetry(:start_from_cart, started_at, result, repo_stats)

    normalize_result(result)
  end

  def start_from_cart(_actor, _token, _input) do
    {:error, Error.new("VALIDATION_ERROR", "token must be a string")}
  end

  @spec set_shipping(map() | nil, String.t(), CheckoutShippingInput.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def set_shipping(actor, checkout_key, %CheckoutShippingInput{} = input)
      when is_binary(checkout_key) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, checkout} <-
               traced_set_shipping_checkout_context(actor, checkout_key),
             {:ok, quote_result} <-
               traced_set_shipping_quote_options(checkout, input),
             {:ok, selected_option} <-
               traced_set_shipping_selection(quote_result.options, input),
             {:ok, updated_order} <-
               traced_set_shipping_persist_details(checkout.order, input, selected_option) do
          checkout
          |> Map.put(:order, updated_order)
          |> Map.put(:shipping_quote_options, quote_result.options)
          |> Map.put(:shipping_quote_request, quote_result.request_attrs)
          |> Map.put(:shipping_weight_grams, quote_result.shipping_weight_grams)
          |> checkout_summary_from_context([])
        end
      end)

    emit_step_telemetry(:set_shipping, started_at, result, repo_stats)
    normalize_result(result)
  end

  def set_shipping(_actor, _checkout_key, _input) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key and shipping input are required")}
  end

  @spec finalize_totals(map() | nil, String.t(), CheckoutFinalizeInput.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def finalize_totals(actor, checkout_key, %CheckoutFinalizeInput{} = input)
      when is_binary(checkout_key) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, checkout} <- traced_finalize_checkout_context(actor, checkout_key) do
          do_finalize_totals(actor, checkout_key, checkout, input)
        end
      end)

    emit_step_telemetry(:finalize_totals, started_at, result, repo_stats)
    normalize_result(result)
  end

  def finalize_totals(_actor, _checkout_key, _input) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key and finalize input are required")}
  end

  defp do_finalize_totals(
         actor,
         checkout_key,
         %{order: %Order{totals_finalized_at: %DateTime{}}},
         _input
       ) do
    get_checkout_for_user(actor, checkout_key)
  end

  defp do_finalize_totals(_actor, _checkout_key, checkout, input) do
    case ensure_priced_snapshot_and_reservations(checkout, input) do
      {:ok, %{already_finalized?: true} = finalized_checkout} ->
        checkout_summary_from_context(finalized_checkout)

      {:ok, checkout} ->
        line_items = Map.get(checkout, :line_items, [])

        with :ok <- ensure_line_items_present(line_items),
             {:ok, updated_order} <-
               finalize_order_for_line_items(
                 checkout.order,
                 line_items,
                 Map.get(checkout, :pricing_adjustment_count, 0)
               ) do
          checkout
          |> Map.put(:order, updated_order)
          |> checkout_summary_from_context(line_items)
        end

      {:error, _} = error ->
        error
    end
  end

  @spec get_checkout_for_user(map() | nil, String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_checkout_for_user(actor, checkout_key) when is_binary(checkout_key) do
    checkout_key
    |> checkout_summary_for_user(actor)
    |> normalize_result()
  end

  def get_checkout_for_user(_actor, _checkout_key) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key must be a string")}
  end

  @spec get_payment_context_for_user(map() | nil, String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_payment_context_for_user(actor, checkout_key) when is_binary(checkout_key) do
    with {:ok, checkout} <- checkout_context_for_user(actor, checkout_key) do
      {:ok, payment_context_from_checkout(checkout)}
    end
    |> normalize_result()
  end

  def get_payment_context_for_user(_actor, _checkout_key) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key must be a string")}
  end

  defp checkout_summary_for_user(checkout_key, actor) do
    with {:ok, checkout} <- checkout_context_for_user(actor, checkout_key) do
      checkout_summary_from_context(checkout)
    end
  end

  defp payment_context_from_checkout(%{draft: draft, order: order}) do
    %{
      draft_id: draft.id,
      checkout_key: draft.checkout_key,
      cart_id: draft.cart_id,
      cart_version: draft.cart_version,
      user_id: draft.user_id,
      order_id: order.id,
      order_ref: order.order_ref,
      state: order.state,
      provider_setup_started_at: order.provider_setup_started_at,
      grand_total_minor: non_neg_int(order.grand_total_minor, 0),
      currency_code: order.currency_code || "USD",
      totals_finalized_at: order.totals_finalized_at,
      totals_finalized?: not is_nil(order.totals_finalized_at)
    }
  end

  defp checkout_summary_from_context(checkout, line_items_or_default \\ :fetch) do
    line_items_result =
      case line_items_or_default do
        :fetch ->
          case Map.get(checkout, :line_items) do
            line_items when is_list(line_items) -> {:ok, line_items}
            _ -> fetch_order_line_items(checkout.order.id)
          end

        line_items when is_list(line_items) ->
          {:ok, line_items}
      end

    with {:ok, line_items} <- line_items_result,
         {:ok, summary_line_items} <- fallback_line_items_from_cart(checkout, line_items) do
      build_checkout_summary(checkout, summary_line_items)
    end
  end

  defp fallback_line_items_from_cart(_checkout, [_ | _] = line_items) do
    {:ok, line_items}
  end

  defp fallback_line_items_from_cart(%{draft: %CheckoutDraft{} = draft}, []) do
    with {:ok, cart_items} <- cart_items_by_checkout_draft(draft),
         {variants_by_id, products_by_id} <- catalog_maps(cart_items),
         {:ok, plans_by_item_id} <- resolve_subscription_plans_for_items(cart_items) do
      {:ok,
       build_checkout_line_items_from_cart(
         cart_items,
         variants_by_id,
         products_by_id,
         plans_by_item_id
       )}
    else
      {:error, _reason} -> {:ok, []}
    end
  end

  defp fallback_line_items_from_cart(_checkout, _line_items), do: {:ok, []}

  defp build_checkout_line_items_from_cart(
         cart_items,
         variants_by_id,
         products_by_id,
         plans_by_item_id
       ) do
    cart_items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, line_no} ->
      variant = Map.get(variants_by_id, item.variant_id)
      product = variant && Map.get(products_by_id, variant.product_id)
      plan = Map.get(plans_by_item_id, item.id)
      unit_price = line_unit_price_for_item(item, variant, plan)
      quantity = item.qty || 0
      line_total = unit_price * quantity
      currency = line_currency_for_item(item, variant, plan) || "USD"

      %{
        id: item.id,
        line_no: line_no,
        sku_snapshot: variant && variant.sku,
        product_title_snapshot: product && product.title,
        variant_title_snapshot: variant && variant.title,
        digital_only_snapshot: match?(%Product{product_kind: :digital}, product),
        quantity: quantity,
        unit_price_minor: unit_price,
        net_line_total_minor: line_total,
        tax_minor: 0,
        tax_category_snapshot: "STANDARD",
        currency: String.upcase(currency)
      }
    end)
  end

  defp cart_items_by_checkout_draft(%CheckoutDraft{cart_id: cart_id, cart_version: cart_version}) do
    case Cart
         |> where([c], c.id == ^cart_id and c.status == :active and c.version == ^cart_version)
         |> limit(1)
         |> Repo.one() do
      %Cart{} = cart -> {:ok, list_cart_items(cart.id, lock?: false)}
      nil -> {:error, Error.new("STALE_RECORD", "checkout cart changed; restart checkout")}
    end
  end

  @spec get_draft_for_user(map() | nil, String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_draft_for_user(actor, checkout_key) when is_binary(checkout_key) do
    with {:ok, summary} <- get_checkout_for_user(actor, checkout_key) do
      {:ok,
       %{
         draft_id: summary.draft_id,
         checkout_key: summary.checkout_key,
         cart_id: summary.cart_id,
         cart_version: summary.cart_version,
         status: summary.state,
         user_id: summary.user_id,
         item_count: summary.item_count,
         subtotal_minor: summary.items_subtotal_minor,
         items: summary.items,
         order_id: summary.order_id,
         order_ref: summary.order_ref,
         grand_total_minor: summary.grand_total_minor,
         currency_code: summary.currency_code
       }}
    end
    |> normalize_result()
  end

  def get_draft_for_user(_actor, _checkout_key) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key must be a string")}
  end

  defp get_or_create_checkout(%Cart{} = cart) do
    cart_id = cart.id

    cart_id
    |> create_or_reuse_checkout_in_transaction()
    |> handle_checkout_transaction_result(cart_id)
  end

  defp create_or_reuse_checkout_in_transaction(cart_id) do
    Repo.transaction(fn ->
      locked_cart = lock_active_cart_for_checkout_start!(cart_id)
      locked_items = lock_cart_items(locked_cart.id)

      :ok = ensure_cart_not_empty!(locked_items)
      {variants_by_id, products_by_id} = catalog_maps(locked_items)
      :ok = ensure_published_sellables!(locked_items, variants_by_id, products_by_id)

      case resolve_checkout_for_cart(locked_cart, locked_items, variants_by_id) do
        {:error, %Error{} = error} -> Repo.rollback(error)
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
  end

  defp resolve_checkout_for_cart(locked_cart, locked_items, variants_by_id) do
    case Repo.get_by(CheckoutDraft, cart_id: locked_cart.id, cart_version: locked_cart.version) do
      %CheckoutDraft{} = draft ->
        resolve_checkout_from_draft(draft, locked_cart, locked_items, variants_by_id)

      nil ->
        create_checkout!(locked_cart, locked_items, variants_by_id)
    end
  end

  defp resolve_checkout_from_draft(
         %CheckoutDraft{order_id: order_id} = draft,
         locked_cart,
         locked_items,
         variants_by_id
       )
       when is_binary(order_id) do
    case Repo.get(Order, order_id) do
      %Order{} = order ->
        {draft, order, true, []}

      nil ->
        create_checkout!(locked_cart, locked_items, variants_by_id)
    end
  end

  defp resolve_checkout_from_draft(
         %CheckoutDraft{} = draft,
         locked_cart,
         locked_items,
         variants_by_id
       ) do
    case order_by_checkout_key(draft.checkout_key) do
      %Order{} = order ->
        with {:ok, updated_draft} <- attach_order_to_draft(draft, order.id) do
          {updated_draft, order, true, []}
        end

      nil ->
        create_checkout!(locked_cart, locked_items, variants_by_id)
    end
  end

  defp handle_checkout_transaction_result(
         {:ok, {draft, order, duplicate?, notifications}},
         cart_id
       ) do
    with :ok <-
           AshNotifications.notify_post_commit(
             notifications,
             context: %{flow: :checkout_start_from_cart, order_id: order.id, cart_id: cart_id}
           )
           |> normalize_post_commit_result() do
      {:ok, draft, order, duplicate?}
    end
  end

  defp handle_checkout_transaction_result({:error, %Error{} = error}, _cart_id) do
    {:error, error}
  end

  defp handle_checkout_transaction_result({:error, other}, _cart_id) do
    {:error, normalize_db_error(other)}
  end

  defp create_checkout!(locked_cart, locked_items, variants_by_id) do
    plans_by_item_id = resolve_subscription_plans_for_items!(locked_items)
    currency = extract_single_currency!(locked_items, variants_by_id, plans_by_item_id)
    as_of = locked_cart.updated_at || DateTime.utc_now() |> DateTime.truncate(:microsecond)

    plan_ids =
      locked_items |> Enum.map(&resolved_plan_id_for_item(&1, plans_by_item_id)) |> Enum.uniq()

    begin_attrs = %{
      user_id: locked_cart.user_id,
      checkout_scope: checkout_scope_for_cart(locked_cart),
      currency: currency,
      as_of: as_of,
      pricing_contract_version: "phase-21-v1",
      tax_shipping_inputs: %{},
      line_items:
        Enum.map(locked_items, fn item ->
          %{
            variant_id: item.variant_id,
            subscription_plan_id: resolved_plan_id_for_item(item, plans_by_item_id),
            quantity: item.qty
          }
        end)
    }

    with :ok <-
           SubscriptionsFacade.ensure_membership_purchase_allowed_for_system(
             locked_cart.user_id,
             plan_ids
           ),
         {:ok, begin_checkout} <-
           Store.Orders.begin_checkout(begin_attrs, return_notifications?: true)
           |> with_checkout_stage(:order_begin),
         {:ok, draft, duplicate?} <-
           create_or_reuse_checkout_draft(locked_cart, begin_checkout.order) do
      {draft, begin_checkout.order, duplicate?, begin_checkout.notifications || []}
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_or_reuse_checkout_draft(%Cart{} = cart, %Order{} = order) do
    case Repo.get_by(CheckoutDraft, cart_id: cart.id, cart_version: cart.version) do
      %CheckoutDraft{} = draft ->
        with {:ok, updated_draft} <- attach_order_to_draft(draft, order.id) do
          {:ok, updated_draft, true}
        end

      nil ->
        insert_checkout_draft(cart, order)
    end
  end

  defp insert_checkout_draft(%Cart{} = cart, %Order{} = order) do
    %CheckoutDraft{}
    |> Changeset.change(checkout_draft_attrs(cart, order))
    |> insert_checkout_draft_changeset(cart, order)
  end

  defp checkout_draft_attrs(%Cart{} = cart, %Order{} = order) do
    %{
      checkout_key: order.checkout_key,
      cart_id: cart.id,
      cart_version: cart.version,
      user_id: cart.user_id,
      status: :open,
      order_id: order.id
    }
  end

  defp handle_checkout_draft_insert_result({:ok, draft}, cart, _order) do
    {:ok, maybe_reload_checkout_draft(draft, cart), false}
  end

  defp handle_checkout_draft_insert_result(
         {:error, %Ecto.Changeset{} = changeset},
         cart,
         order
       ) do
    cond do
      unique_cart_version_conflict?(changeset) ->
        load_checkout_draft_after_conflict(cart, order.id)

      unique_checkout_key_conflict?(changeset) ->
        load_checkout_draft_after_checkout_key_conflict(cart, order)

      true ->
        {:error, normalize_db_error(changeset) |> put_checkout_stage(:draft_insert)}
    end
  end

  defp insert_checkout_draft_changeset(changeset, %Cart{} = cart, %Order{} = order) do
    changeset
    |> Repo.insert()
    |> handle_checkout_draft_insert_result(cart, order)
  rescue
    error in Ecto.ConstraintError ->
      handle_checkout_draft_constraint_error(error, cart, order)
  end

  defp handle_checkout_draft_constraint_error(%Ecto.ConstraintError{} = error, cart, order) do
    cond do
      constraint_error?(error, "checkout_drafts_unique_cart_id_cart_version_index") ->
        load_checkout_draft_after_conflict(cart, order.id)

      constraint_error?(error, "checkout_drafts_unique_checkout_key_index") ->
        load_checkout_draft_after_checkout_key_conflict(cart, order)

      true ->
        {:error, normalize_db_error(error) |> put_checkout_stage(:draft_insert)}
    end
  end

  defp load_checkout_draft_after_conflict(%Cart{} = cart, order_id) when is_binary(order_id) do
    case Repo.get_by(CheckoutDraft, cart_id: cart.id, cart_version: cart.version) do
      %CheckoutDraft{} = draft ->
        with {:ok, updated_draft} <- attach_order_to_draft(draft, order_id) do
          {:ok, updated_draft, true}
        end

      nil ->
        {:error,
         Error.new("STALE_RECORD", "checkout draft conflict retry failed")
         |> put_checkout_stage(:draft_insert)}
    end
  end

  defp load_checkout_draft_after_checkout_key_conflict(%Cart{} = cart, %Order{} = order) do
    case Repo.get_by(CheckoutDraft, checkout_key: order.checkout_key) do
      %CheckoutDraft{cart_id: cart_id, cart_version: cart_version} = draft
      when cart_id == cart.id and cart_version == cart.version ->
        with {:ok, updated_draft} <- attach_order_to_draft(draft, order.id) do
          {:ok, updated_draft, true}
        end

      %CheckoutDraft{} ->
        {:error,
         Error.new("CHECKOUT_DUPLICATE", "checkout draft already exists for a different cart")
         |> put_checkout_stage(:draft_insert)}

      nil ->
        {:error,
         Error.new("STALE_RECORD", "checkout draft checkout key conflict retry failed")
         |> put_checkout_stage(:draft_insert)}
    end
  end

  defp attach_order_to_draft(%CheckoutDraft{order_id: order_id} = draft, order_id),
    do: {:ok, draft}

  defp attach_order_to_draft(%CheckoutDraft{} = draft, order_id) do
    draft
    |> Changeset.change(order_id: order_id, checkout_key: draft.checkout_key)
    |> Repo.update()
    |> case do
      {:ok, updated_draft} ->
        {:ok, updated_draft}

      {:error, error} ->
        {:error, normalize_db_error(error) |> put_checkout_stage(:draft_attach)}
    end
  end

  defp priced_snapshot_output(
         locked_items,
         variants_by_id,
         products_by_id,
         plans_by_item_id,
         revisions_by_plan_id,
         currency
       ) do
    lines =
      locked_items
      |> Enum.sort_by(fn item -> BinaryUuidSort.normalize_raw16!(item.variant_id) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {item, line_no} ->
        variant = Map.fetch!(variants_by_id, item.variant_id)
        product = Map.fetch!(products_by_id, variant.product_id)
        plan = Map.get(plans_by_item_id, item.id)
        revision = revision_for_plan(plan, revisions_by_plan_id)
        commercial_contract = revision || plan
        unit_price_minor = line_unit_price_for_item(item, variant, commercial_contract)
        line_total = unit_price_minor * item.qty

        %{
          line_id: item.variant_id,
          line_no: line_no,
          sku_snapshot: variant.sku,
          product_title_snapshot: product.title,
          variant_title_snapshot: variant.title,
          digital_only_snapshot: product.product_kind == :digital,
          quantity: item.qty,
          unit_price_minor: unit_price_minor,
          line_total_minor: line_total,
          subscription_plan_id_snapshot: plan && plan.id,
          subscription_plan_revision_id_snapshot: revision && revision.id,
          subscription_plan_key_snapshot: plan && plan.key,
          subscription_interval_unit_snapshot:
            commercial_contract && Atom.to_string(commercial_contract.interval_unit),
          subscription_interval_count_snapshot:
            commercial_contract && commercial_contract.interval_count,
          discount_allocated_minor: 0,
          net_line_total_minor: line_total,
          tax_category_snapshot: "STANDARD",
          tax_minor: 0
        }
      end)

    subtotal_minor = Enum.reduce(lines, 0, &(&1.line_total_minor + &2))

    %{
      currency: currency,
      subtotal_minor: subtotal_minor,
      discount_total_minor: 0,
      total_minor: subtotal_minor,
      lines: lines,
      line_allocations: Enum.map(lines, &%{line_id: &1.line_id, discount_minor: 0}),
      applied_adjustments: []
    }
  end

  defp quote_request_attrs(country_code, region_code, postal_code, currency, weight_grams) do
    %{
      destination_country_code: country_code,
      destination_region_code: region_code,
      destination_postal_code: postal_code,
      currency_code: currency,
      shipping_weight_grams: weight_grams
    }
  end

  defp reserve_items(line_items) do
    for item <- line_items, not item.digital_only_snapshot do
      %{variant_id: item.variant_id_snapshot, quantity: item.quantity}
    end
  end

  defp ensure_priced_snapshot_and_reservations(
         %{
           draft: %CheckoutDraft{} = draft,
           order: %Order{} = order
         },
         input
       ) do
    Repo.transaction(fn ->
      locked_cart = lock_checkout_cart!(draft.cart_id, draft.cart_version)
      locked_items = lock_cart_items(locked_cart.id)
      locked_order = lock_checkout_order!(order.id)

      :ok = ensure_cart_not_empty!(locked_items)

      if is_nil(locked_order.totals_finalized_at) do
        build_checkout_finalize_context(draft, locked_order, locked_cart, locked_items, input)
      else
        load_already_finalized_checkout(draft, locked_order)
      end
    end)
    |> case do
      {:ok, checkout} -> {:ok, checkout}
      {:error, %Error{} = error} -> {:error, error}
      {:error, other} -> {:error, normalize_db_error(other)}
    end
  end

  defp ensure_priced_snapshot_and_reservations(_checkout, _input) do
    {:error, Error.new("VALIDATION_ERROR", "checkout context is required")}
  end

  defp load_already_finalized_checkout(draft, locked_order) do
    case fetch_order_line_items(locked_order.id) do
      {:ok, line_items} ->
        %{
          draft: draft,
          order: locked_order,
          already_finalized?: true,
          line_items: line_items
        }

      {:error, %Error{} = error} ->
        Repo.rollback(error)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp build_checkout_finalize_context(draft, locked_order, locked_cart, locked_items, input) do
    {variants_by_id, products_by_id} = catalog_maps(locked_items)
    :ok = ensure_published_sellables!(locked_items, variants_by_id, products_by_id)
    plans_by_item_id = resolve_subscription_plans_for_items!(locked_items)
    revisions_by_plan_id = resolve_subscription_revisions_for_plans!(plans_by_item_id)

    currency =
      extract_single_currency!(
        locked_items,
        variants_by_id,
        plans_by_item_id,
        revisions_by_plan_id
      )

    priced =
      priced_snapshot_output(
        locked_items,
        variants_by_id,
        products_by_id,
        plans_by_item_id,
        revisions_by_plan_id,
        currency
      )

    if digital_only?(priced.lines) do
      finalize_digital_checkout(draft, locked_order, priced, input)
    else
      build_shipping_finalize_context(draft, locked_order, locked_cart, locked_items, %{
        variants: variants_by_id,
        products: products_by_id,
        plans: plans_by_item_id,
        priced: priced
      })
    end
  end

  defp build_shipping_finalize_context(draft, locked_order, locked_cart, locked_items, catalog) do
    %{variants: variants_by_id, products: products_by_id, plans: plans_by_item_id, priced: priced} =
      catalog

    currency = priced.currency

    shipping_weight_grams =
      shipping_weight_grams_for_items(locked_items, variants_by_id, products_by_id)

    shipping_quote_request =
      quote_request_attrs(
        locked_order.shipping_country_code,
        locked_order.shipping_region_code,
        locked_order.shipping_postal_code,
        String.upcase(currency),
        shipping_weight_grams
      )

    case write_finalize_snapshot_and_reservations(locked_order.id, priced) do
      {:ok, snapshot, reservation_result} ->
        %{
          draft: draft,
          order: locked_order,
          cart: locked_cart,
          cart_items: locked_items,
          variants_by_id: variants_by_id,
          products_by_id: products_by_id,
          plans_by_item_id: plans_by_item_id,
          line_items: snapshot.line_items,
          pricing_adjustment_count: length(snapshot.adjustments),
          reserved_rows: reservation_result.reserved_rows,
          currency_code: String.upcase(currency),
          shipping_weight_grams: shipping_weight_grams,
          shipping_quote_request: shipping_quote_request
        }

      {:error, %Error{} = error} ->
        Repo.rollback(error)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp write_finalize_snapshot_and_reservations(order_id, priced) do
    with {:ok, snapshot} <-
           Store.Orders.write_priced_snapshot(order_id, priced),
         {:ok, reservation_result} <-
           Store.Orders.reserve_inventory_for_checkout(
             order_id,
             reserve_items(snapshot.line_items)
           ) do
      {:ok, snapshot, reservation_result}
    end
  end

  defp digital_only?(items), do: items != [] and Enum.all?(items, & &1.digital_only_snapshot)

  defp finalize_digital_checkout(draft, order, priced, input) do
    with {:ok, tax} <- evaluate_digital_tax(priced, input),
         {:ok, %{idempotent?: false, line_items: lines}} <-
           Store.Orders.write_priced_snapshot(order.id, with_line_tax(priced, tax)),
         {:ok, %{order: order, idempotent?: false}} <-
           Store.Orders.write_tax_shipping_snapshot(order.id, tax, location: :billing),
         {:ok, order} <- finalize_order_totals(order, tax) do
      %{draft: draft, order: order, line_items: lines, already_finalized?: true}
    else
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %{idempotent?: true}} ->
        Repo.rollback(Error.new("STALE_RECORD", "checkout delivery changed; restart checkout"))
    end
  end

  defp evaluate_digital_tax(priced, %CheckoutFinalizeInput{
         billing_country_code: country,
         billing_region_code: region
       })
       when is_binary(country) and is_binary(region) do
    with {:ok, rates} <- traced_fetch_tax_rates(country) do
      TaxShippingEvaluator.evaluate(%{
        as_of: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        currency: priced.currency,
        destination_country_code: country,
        destination_region_code: region,
        subtotal_minor: priced.subtotal_minor,
        shipping_weight_grams: 0,
        lines:
          Enum.map(
            priced.lines,
            &Map.take(&1, [:line_id, :line_no, :net_line_total_minor, :tax_category_snapshot])
          ),
        shipping_rates: [],
        tax_rates: Enum.map(rates, &tax_rate_candidate/1),
        shipping_enabled?: false,
        tax_enabled?: true
      })
    end
  end

  defp evaluate_digital_tax(_priced, _input),
    do: {:error, Error.new("INVALID_ADDRESS", "billing country and region are required")}

  defp with_line_tax(priced, tax) do
    tax_by_line = Map.new(tax.line_taxes, &{&1.line_no, &1})

    lines =
      Enum.map(priced.lines, fn line ->
        tax_line = Map.fetch!(tax_by_line, line.line_no)

        Map.merge(line, %{
          tax_minor: tax_line.tax_minor,
          tax_rate_id_snapshot: tax_line.tax_rate_id,
          tax_rate_code_snapshot: tax_line.tax_rate_code,
          tax_rate_bps_snapshot: tax_line.tax_rate_bps
        })
      end)

    %{priced | lines: lines}
  end

  defp checkout_context_for_user(actor, checkout_key) do
    with {:ok, draft} <- read_draft_by_checkout_key(checkout_key),
         {:ok, order} <- read_order_for_checkout(draft, checkout_key),
         :ok <- authorize_checkout_access(actor, draft, order) do
      {:ok, %{draft: draft, order: order}}
    end
  end

  defp read_draft_by_checkout_key(checkout_key) do
    case Repo.get_by(CheckoutDraft, checkout_key: checkout_key) do
      %CheckoutDraft{} = draft -> {:ok, draft}
      nil -> {:error, Error.new("NOT_FOUND", "checkout not found")}
    end
  end

  defp read_order_for_checkout(%CheckoutDraft{order_id: order_id}, _checkout_key)
       when is_binary(order_id) do
    case Repo.get(Order, order_id) do
      %Order{} = order -> {:ok, order}
      nil -> {:error, Error.new("NOT_FOUND", "checkout order not found")}
    end
  end

  defp read_order_for_checkout(_draft, checkout_key) do
    case order_by_checkout_key(checkout_key) do
      %Order{} = order -> {:ok, order}
      nil -> {:error, Error.new("NOT_FOUND", "checkout order not found")}
    end
  end

  defp order_by_checkout_key(checkout_key) do
    Order
    |> where([o], o.checkout_key == ^checkout_key)
    |> limit(1)
    |> Repo.one()
  end

  defp authorize_checkout_access(%{id: actor_id}, _draft, %Order{user_id: user_id})
       when is_binary(actor_id) and is_binary(user_id) and actor_id == user_id,
       do: :ok

  defp authorize_checkout_access(
         %{cart_token: token},
         %CheckoutDraft{user_id: nil, cart_id: cart_id},
         _order
       )
       when is_binary(token) do
    case active_cart_id_by_token(token) do
      ^cart_id -> :ok
      _ -> {:error, Error.new("NOT_FOUND", "checkout not found")}
    end
  end

  defp authorize_checkout_access(_actor, _draft, _order),
    do: {:error, Error.new("NOT_FOUND", "checkout not found")}

  defp build_checkout_summary(%{draft: draft, order: order} = checkout, line_items) do
    item_count = Enum.reduce(line_items, 0, &(&1.quantity + &2))
    items_subtotal = Enum.reduce(line_items, 0, &(&1.net_line_total_minor + &2))
    shipping_required? = not digital_only?(line_items)

    shipping_quote_options =
      if shipping_required?, do: shipping_quote_options_for_summary(checkout), else: []

    {:ok,
     %{
       draft_id: draft.id,
       checkout_key: draft.checkout_key,
       cart_id: draft.cart_id,
       cart_version: draft.cart_version,
       user_id: draft.user_id,
       order_id: order.id,
       order_ref: order.order_ref,
       state: order.state,
       shipping_required?: shipping_required?,
       billing_country_code: order.billing_country_code,
       billing_region_code: order.billing_region_code,
       shipping_rate_code: order.shipping_rate_code,
       shipping_method_code: order.shipping_method_code,
       shipping_quote_hash: order.shipping_quote_hash,
       shipping_quote_currency_code: order.shipping_quote_currency_code,
       shipping_quote_amount_minor: non_neg_int(order.shipping_quote_amount_minor, 0),
       shipping_weight_grams: non_neg_int(order.shipping_weight_grams, 0),
       shipping_country_code: order.shipping_country_code,
       shipping_region_code: order.shipping_region_code,
       shipping_postal_code: order.shipping_postal_code,
       shipping_recipient_name: order.shipping_recipient_name,
       shipping_address_line1: order.shipping_address_line1,
       shipping_address_line2: order.shipping_address_line2,
       shipping_city: order.shipping_city,
       shipping_phone: order.shipping_phone,
       item_count: item_count,
       items_subtotal_minor: non_neg_int(order.items_subtotal_minor, items_subtotal),
       tax_total_minor: non_neg_int(order.tax_total_minor, 0),
       shipping_total_minor: non_neg_int(order.shipping_total_minor, 0),
       grand_total_minor: non_neg_int(order.grand_total_minor, items_subtotal),
       currency_code: order.currency_code || line_currency(line_items) || "USD",
       totals_finalized_at: order.totals_finalized_at,
       totals_finalized?: not is_nil(order.totals_finalized_at),
       shipping_quote_options: Enum.map(shipping_quote_options, &quote_option_summary/1),
       items: Enum.map(line_items, &line_item_summary/1)
     }}
  end

  defp shipping_quote_options_for_summary(%{shipping_quote_options: [_ | _]} = checkout) do
    Map.get(checkout, :shipping_quote_options, [])
  end

  defp shipping_quote_options_for_summary(%{
         order: %Order{totals_finalized_at: %DateTime{}} = order
       }) do
    case quote_option_from_order(order) do
      nil -> []
      option -> [option]
    end
  end

  defp shipping_quote_options_for_summary(checkout), do: available_quote_options(checkout)

  defp quote_option_summary(option) do
    %{
      quote_hash: option.quote_hash,
      shipping_method_code: option.shipping_method_code,
      amount_minor: option.amount_minor,
      currency_code: option.currency_code,
      label: option.label
    }
  end

  defp line_item_summary(line_item) do
    %{
      line_no: line_item.line_no,
      sku: line_item.sku_snapshot,
      product_title: line_item.product_title_snapshot,
      variant_title: line_item.variant_title_snapshot,
      qty: line_item.quantity,
      unit_price_minor: line_item.unit_price_minor,
      net_line_total_minor: line_item.net_line_total_minor,
      tax_minor: line_item.tax_minor,
      currency_code: line_item.currency
    }
  end

  defp checkout_currency(%{order: order, draft: draft}) do
    currency =
      order.currency_code || checkout_snapshot_currency(order, draft)

    case currency do
      value when is_binary(value) and value != "" -> {:ok, String.upcase(value)}
      _ -> {:error, Error.new("VALIDATION_ERROR", "unable to infer checkout currency")}
    end
  end

  defp checkout_currency(_checkout),
    do: {:error, Error.new("VALIDATION_ERROR", "checkout context is required")}

  defp cart_currency_by_draft(%CheckoutDraft{} = draft) do
    with {:ok, cart_items} <- cart_items_by_checkout_draft(draft),
         {variants_by_id, _products_by_id} <- catalog_maps(cart_items),
         {:ok, plans_by_item_id} <- resolve_subscription_plans_for_items(cart_items) do
      infer_single_currency(cart_items, variants_by_id, plans_by_item_id)
    else
      _ -> nil
    end
  end

  defp cart_currency_by_draft(_draft), do: nil

  defp checkout_snapshot_currency(%Order{totals_finalized_at: %DateTime{}, id: order_id}, draft) do
    line_items_currency(order_id) || cart_currency_by_draft(draft)
  end

  defp checkout_snapshot_currency(_order, draft), do: cart_currency_by_draft(draft)

  defp fetch_tax_rates(country_code) when is_binary(country_code) do
    query = TaxRate |> Ash.Query.filter(expr(country_code == ^country_code and active == true))

    case Ash.read(query, domain: Store.Pricing, authorize?: false, context: %{system?: true}) do
      {:ok, rates} -> {:ok, rates}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_tax_rates(_country_code) do
    {:error, Error.new("INVALID_ADDRESS", "shipping country is required")}
  end

  defp quote_options_for_checkout(checkout, input) do
    with {:ok, weight_grams} <- checkout_shipping_weight(checkout),
         {:ok, currency} <- checkout_currency(checkout),
         request_attrs =
           quote_request_attrs(
             input.country_code,
             input.region_code,
             input.postal_code,
             currency,
             weight_grams
           ),
         {:ok, request} <- QuoteRequest.new(request_attrs),
         {:ok, options} <- Shipping.quote_options(request),
         :ok <- ensure_quote_options_present(options) do
      {:ok,
       %{
         options: options,
         request_attrs: request_attrs,
         shipping_weight_grams: weight_grams
       }}
    end
  end

  defp checkout_shipping_weight(%{order: %Order{billing_country_code: country}})
       when is_binary(country),
       do: shipping_not_applicable()

  defp checkout_shipping_weight(%{draft: draft}) do
    with {:ok, items} <- cart_items_by_checkout_draft(draft) do
      {variants, products} = catalog_maps(items)

      if items != [] and Enum.all?(items, &digital_cart_item?(&1, variants, products)) do
        shipping_not_applicable()
      else
        {:ok, shipping_weight_grams_for_items(items, variants, products)}
      end
    end
  end

  defp shipping_not_applicable,
    do: {:error, Error.new("VALIDATION_ERROR", "Digital-only checkout does not require shipping")}

  defp ensure_quote_options_present([_ | _]), do: :ok

  defp ensure_quote_options_present([]) do
    {:error, Error.new("SHIPPING_RATE_NOT_FOUND", "no eligible shipping quotes found")}
  end

  defp select_quote_option(options, input) do
    method_code = String.upcase(input.shipping_method_code)
    quote_hash = input.quote_hash

    case Enum.find(
           options,
           &(&1.quote_hash == quote_hash and &1.shipping_method_code == method_code)
         ) do
      nil ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "selected shipping quote does not match server-generated options"
         )}

      option ->
        {:ok, option}
    end
  end

  defp update_order_shipping_details(order, input, selected_option) do
    attrs = %{
      shipping_country_code: input.country_code,
      shipping_region_code: input.region_code,
      shipping_postal_code: input.postal_code,
      shipping_recipient_name: input.recipient_name,
      shipping_address_line1: input.address_line1,
      shipping_address_line2: input.address_line2,
      shipping_city: input.city,
      shipping_phone: input.phone,
      shipping_rate_id: selected_option.shipping_rule_id,
      shipping_rate_code: selected_option.shipping_method_code,
      shipping_quote_hash: selected_option.quote_hash,
      shipping_quote_currency_code: selected_option.currency_code,
      shipping_quote_amount_minor: selected_option.amount_minor,
      shipping_weight_grams: selected_option.shipping_weight_grams,
      shipping_method_code: selected_option.shipping_method_code,
      shipping_rule_id: selected_option.shipping_rule_id,
      shipping_zone_id: selected_option.zone_id,
      shipping_effective_from: selected_option.effective_from,
      shipping_effective_to: selected_option.effective_to
    }

    order
    |> Ash.Changeset.for_update(:set_shipping_details, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp quote_evidence_from_order(%Order{} = order) do
    if is_binary(order.shipping_quote_hash) and is_binary(order.shipping_quote_currency_code) and
         is_binary(order.shipping_method_code) and is_binary(order.shipping_country_code) do
      {:ok,
       %QuoteEvidence{
         quote_hash: order.shipping_quote_hash,
         currency_code: order.shipping_quote_currency_code,
         amount_minor: non_neg_int(order.shipping_quote_amount_minor, 0),
         shipping_weight_grams: non_neg_int(order.shipping_weight_grams, 0),
         destination_country_code: order.shipping_country_code,
         destination_region_code: order.shipping_region_code,
         destination_postal_code: order.shipping_postal_code,
         shipping_method_code: order.shipping_method_code,
         shipping_rule_id: order.shipping_rule_id,
         zone_id: order.shipping_zone_id,
         effective_from: order.shipping_effective_from,
         effective_to: order.shipping_effective_to
       }}
    else
      {:error, Error.new("SHIPPING_RATE_NOT_FOUND", "shipping quote evidence is required")}
    end
  end

  defp validate_quote_integrity(%QuoteEvidence{} = evidence) do
    expected_quote_hash = QuoteHash.hash_evidence(evidence)

    if evidence.quote_hash == expected_quote_hash do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "shipping quote integrity check failed")}
    end
  end

  defp available_quote_options(%{order: %Order{} = order} = checkout) do
    request_attrs =
      Map.get(
        checkout,
        :shipping_quote_request,
        quote_request_attrs(
          order.shipping_country_code,
          order.shipping_region_code,
          order.shipping_postal_code,
          checkout_currency_value(checkout),
          shipping_weight_grams_for_checkout(checkout)
        )
      )

    with true <- is_binary(order.shipping_country_code),
         {:ok, request} <- QuoteRequest.new(request_attrs),
         {:ok, options} <- Shipping.quote_options(request) do
      options
    else
      _ -> []
    end
  end

  defp available_quote_options(_checkout), do: []

  defp quote_option_from_order(%Order{} = order) do
    if is_binary(order.shipping_quote_hash) and is_binary(order.shipping_method_code) and
         is_binary(order.shipping_quote_currency_code) do
      %{
        quote_hash: order.shipping_quote_hash,
        shipping_method_code: order.shipping_method_code,
        amount_minor: non_neg_int(order.shipping_quote_amount_minor, 0),
        currency_code: order.shipping_quote_currency_code,
        label: order.shipping_rate_code || order.shipping_method_code
      }
    end
  end

  defp shipping_weight_grams_for_checkout(%{shipping_weight_grams: weight_grams})
       when is_integer(weight_grams) and weight_grams >= 0,
       do: weight_grams

  defp shipping_weight_grams_for_checkout(%{order: %Order{} = order})
       when is_integer(order.shipping_weight_grams) and order.shipping_weight_grams >= 0 and
              is_binary(order.shipping_country_code),
       do: order.shipping_weight_grams

  defp shipping_weight_grams_for_checkout(%{draft: %CheckoutDraft{} = draft}) do
    with {:ok, cart_items} <- cart_items_by_checkout_draft(draft),
         {variants_by_id, products_by_id} <- catalog_maps(cart_items) do
      shipping_weight_grams_for_items(cart_items, variants_by_id, products_by_id)
    else
      _ -> 0
    end
  end

  defp shipping_weight_grams_for_checkout(_checkout), do: 0

  defp shipping_weight_grams_for_items(cart_items, variants_by_id, products_by_id) do
    Enum.reduce(cart_items, 0, fn item, acc ->
      if digital_cart_item?(item, variants_by_id, products_by_id),
        do: acc,
        else: acc + cart_item_shipping_weight(item, variants_by_id)
    end)
  end

  defp digital_cart_item?(item, variants, products) do
    case Map.get(variants, item.variant_id) do
      %Variant{product_id: product_id} ->
        match?(%Product{product_kind: :digital}, Map.get(products, product_id))

      nil ->
        false
    end
  end

  defp cart_item_shipping_weight(item, variants_by_id) do
    case Map.get(variants_by_id, item.variant_id) do
      %Variant{} = variant ->
        non_negative_quantity(item.qty) * non_negative_weight_grams(variant.weight_grams)

      _ ->
        0
    end
  end

  defp non_negative_quantity(value) when is_integer(value) and value > 0, do: value
  defp non_negative_quantity(_value), do: 0

  defp non_negative_weight_grams(value) when is_integer(value) and value > 0, do: value
  defp non_negative_weight_grams(_value), do: 0

  defp evaluate_tax_shipping_from_quote_evidence(line_items, order, quote_evidence, tax_rates) do
    subtotal_minor = Enum.reduce(line_items, 0, &(&1.net_line_total_minor + &2))

    shipping_candidates = [shipping_candidate_from_quote_evidence(quote_evidence)]
    tax_candidates = Enum.map(tax_rates, &tax_rate_candidate/1)

    input =
      TaxShippingContract.to_input!(%{
        as_of: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        currency: line_currency(line_items) || order.currency_code || "USD",
        destination_country_code: order.shipping_country_code,
        destination_region_code: order.shipping_region_code,
        destination_postal_code: order.shipping_postal_code,
        subtotal_minor: subtotal_minor,
        shipping_weight_grams: quote_evidence.shipping_weight_grams,
        lines: Enum.map(line_items, &tax_shipping_line/1),
        shipping_rates: shipping_candidates,
        tax_rates: tax_candidates,
        free_shipping_coupon?: false,
        shipping_enabled?: true,
        tax_enabled?: true
      })

    TaxShippingEvaluator.evaluate(input)
  end

  defp tax_shipping_line(line_item) do
    %{
      line_id: line_item.id,
      line_no: line_item.line_no,
      net_line_total_minor: line_item.net_line_total_minor,
      tax_category_snapshot: line_item.tax_category_snapshot
    }
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

  defp ensure_shipping_adjustment(order, quote_evidence, base_sequence_no) do
    case existing_shipping_adjustment(order.id) do
      {:ok, %OrderAdjustment{} = adjustment} ->
        {:ok, adjustment, true}

      {:ok, nil} ->
        insert_shipping_adjustment(order, quote_evidence, base_sequence_no)

      {:error, error} ->
        {:error, error}
    end
  end

  defp insert_shipping_adjustment(order, quote_evidence, base_sequence_no) do
    attrs = %{
      order_id: order.id,
      sequence_no: base_sequence_no + 1,
      currency: quote_evidence.currency_code,
      kind: "shipping",
      amount_minor: quote_evidence.amount_minor,
      reason: "shipping:#{quote_evidence.shipping_method_code}",
      source_kind: "shipping_quote",
      source_code: quote_evidence.shipping_method_code,
      source_id: quote_evidence.shipping_rule_id,
      precedence_rank: 0
    }

    %OrderAdjustment{}
    |> Changeset.change(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(order_id) WHERE kind = 'shipping'"}
    )
    |> case do
      {:ok, %OrderAdjustment{} = adjustment} ->
        {:ok, adjustment, false}

      {:error, _changeset} ->
        case existing_shipping_adjustment(order.id) do
          {:ok, %OrderAdjustment{} = adjustment} ->
            {:ok, adjustment, true}

          {:ok, nil} ->
            {:error, Error.new("INTERNAL_ERROR", "unable to persist shipping adjustment")}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp existing_shipping_adjustment(order_id) do
    query =
      OrderAdjustment |> Ash.Query.filter(expr(order_id == ^order_id and kind == "shipping"))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [adjustment | _]} ->
        {:ok, adjustment}

      {:ok, []} ->
        {:ok, nil}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read shipping adjustment")}
    end
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

  defp finalize_order_for_line_items(order, line_items, pricing_adjustment_count) do
    if subscription_only_line_items?(line_items) do
      output = subscription_only_totals_output(line_items, order)
      finalize_order_totals(order, output)
    else
      with {:ok, quote_evidence} <- traced_quote_evidence(order),
           :ok <- traced_quote_integrity(quote_evidence),
           {:ok, tax_rates} <- traced_fetch_tax_rates(order.shipping_country_code),
           {:ok, output} <-
             traced_tax_shipping_evaluation(line_items, order, quote_evidence, tax_rates),
           {:ok, _adjustment, _idempotent?} <-
             traced_shipping_adjustment(order, quote_evidence, pricing_adjustment_count),
           {:ok, _snapshot} <- traced_write_tax_shipping_snapshot(order.id, output) do
        finalize_order_totals(order, output)
      end
    end
  end

  defp subscription_only_line_items?(line_items) when is_list(line_items) do
    line_items != [] and
      Enum.all?(line_items, fn line_item ->
        is_binary(Map.get(line_item, :subscription_plan_id_snapshot))
      end)
  end

  defp subscription_only_totals_output(line_items, order) do
    subtotal_minor = Enum.reduce(line_items, 0, &(&1.net_line_total_minor + &2))
    currency = line_currency(line_items) || order.currency_code || "USD"

    %{
      currency: String.upcase(currency),
      subtotal_minor: subtotal_minor,
      shipping_cost_minor_effective: 0,
      order_total_minor: subtotal_minor
    }
  end

  defp finalize_order_totals(order, output) do
    attrs = %{
      currency_code: output.currency,
      items_subtotal_minor: output.subtotal_minor,
      shipping_total_minor: output.shipping_cost_minor_effective,
      grand_total_minor: output.order_total_minor
    }

    order
    |> Ash.Changeset.for_update(:finalize_checkout_totals, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.sort(line_no: :asc)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_line_items_present([]),
    do: {:error, Error.new("VALIDATION_ERROR", "order snapshot line items are required")}

  defp ensure_line_items_present(_line_items), do: :ok

  defp line_currency([%{currency: currency} | _]) when is_binary(currency), do: currency
  defp line_currency(_), do: nil

  defp line_items_currency(order_id) do
    case fetch_order_line_items(order_id) do
      {:ok, line_items} -> line_currency(line_items)
      _ -> nil
    end
  end

  defp lock_active_cart_for_checkout_start!(nil) do
    Repo.rollback(
      Error.new("NOT_FOUND", "active cart not found")
      |> put_checkout_stage(:cart_lock)
    )
  end

  defp lock_active_cart_for_checkout_start!(cart_id) do
    case Cart
         |> where([c], c.id == ^cart_id and c.status == :active)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %Cart{} = cart ->
        cart

      nil ->
        Repo.rollback(
          Error.new("NOT_FOUND", "active cart not found")
          |> put_checkout_stage(:cart_lock)
        )
    end
  end

  defp lock_checkout_cart!(cart_id, cart_version) do
    case Cart
         |> where([c], c.id == ^cart_id and c.status == :active and c.version == ^cart_version)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %Cart{} = cart ->
        cart

      nil ->
        Repo.rollback(Error.new("STALE_RECORD", "checkout cart changed; restart checkout"))
    end
  end

  defp lock_checkout_order!(order_id) do
    case Order
         |> where([order], order.id == ^order_id)
         |> lock("FOR UPDATE")
         |> Repo.one() do
      %Order{} = order ->
        order

      nil ->
        Repo.rollback(Error.new("NOT_FOUND", "checkout order not found"))
    end
  end

  defp lock_cart_items(cart_id), do: list_cart_items(cart_id, lock?: true)

  defp ensure_cart_not_empty!([]),
    do: Repo.rollback(Error.new("VALIDATION_ERROR", "cart must not be empty"))

  defp ensure_cart_not_empty!(_items), do: :ok

  defp ensure_published_sellables!(items, variants_by_id, products_by_id) when is_list(items) do
    required_complete_by_variant_id = required_complete_by_variant_id(items, variants_by_id)

    Enum.each(items, fn item ->
      variant = Map.get(variants_by_id, item.variant_id)
      product = variant && Map.get(products_by_id, variant.product_id)

      cond do
        is_nil(variant) ->
          Repo.rollback(Error.new("NOT_FOUND", "variant not found for cart item"))

        variant.status != :active ->
          Repo.rollback(Error.new("VALIDATION_ERROR", "cart contains inactive variant"))

        not Map.get(required_complete_by_variant_id, variant.id, false) ->
          Repo.rollback(
            Error.new("VALIDATION_ERROR", "cart contains incomplete variant selection")
          )

        is_nil(product) ->
          Repo.rollback(Error.new("NOT_FOUND", "product not found for cart item"))

        product.status != :published or is_nil(product.published_at) ->
          Repo.rollback(Error.new("VALIDATION_ERROR", "cart contains unpublished product"))

        true ->
          :ok
      end
    end)

    :ok
  end

  defp extract_single_currency!(
         items,
         variants_by_id,
         plans_by_item_id,
         revisions_by_plan_id \\ %{}
       ) do
    currencies =
      items
      |> Enum.map(fn item ->
        line_currency_for_item(
          item,
          Map.get(variants_by_id, item.variant_id),
          revision_for_plan(Map.get(plans_by_item_id, item.id), revisions_by_plan_id) ||
            Map.get(plans_by_item_id, item.id)
        )
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case currencies do
      [currency] -> currency
      [] -> Repo.rollback(Error.new("VALIDATION_ERROR", "unable to infer cart currency"))
      _ -> Repo.rollback(Error.new("VALIDATION_ERROR", "cart currency mismatch"))
    end
  end

  defp infer_single_currency(items, variants_by_id, plans_by_item_id) do
    currencies =
      items
      |> Enum.map(fn item ->
        line_currency_for_item(
          item,
          Map.get(variants_by_id, item.variant_id),
          Map.get(plans_by_item_id, item.id)
        )
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case currencies do
      [currency] -> currency
      _ -> nil
    end
  end

  defp list_cart_items(cart_id, opts) do
    base_query =
      CartItem
      |> where([i], i.cart_id == ^cart_id)
      |> order_by([i], asc: i.inserted_at, asc: i.id)

    query =
      if Keyword.get(opts, :lock?, false) do
        lock(base_query, "FOR UPDATE")
      else
        base_query
      end

    Repo.all(query)
  end

  defp active_cart_id_by_token(token) do
    Cart
    |> where([c], c.token == ^token and c.status == :active)
    |> select([c], c.id)
    |> limit(1)
    |> Repo.one()
  end

  defp catalog_maps(items) do
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
          |> Repo.all()
      end

    {Map.new(variants, &{&1.id, &1}), Map.new(products, &{&1.id, &1})}
  end

  defp required_complete_by_variant_id(items, variants_by_id) when is_list(items) do
    variant_ids =
      items
      |> Enum.map(& &1.variant_id)
      |> Enum.uniq()

    product_id_by_variant = product_id_by_variant(variant_ids, variants_by_id)
    product_ids = product_id_by_variant |> Map.values() |> Enum.uniq()

    required_option_ids_by_product =
      ProductOption
      |> where([option], option.product_id in ^product_ids and option.selection_required == true)
      |> select([option], {option.product_id, option.id})
      |> Repo.all()
      |> Enum.group_by(fn {product_id, _option_id} -> product_id end, fn {_product_id, option_id} ->
        option_id
      end)

    required_option_ids =
      required_option_ids_by_product
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    selected_required_count_by_variant =
      if required_option_ids == [] or variant_ids == [] do
        %{}
      else
        VariantOptionSelection
        |> where(
          [selection],
          selection.variant_id in ^variant_ids and
            selection.product_option_id in ^required_option_ids
        )
        |> group_by([selection], selection.variant_id)
        |> select(
          [selection],
          {selection.variant_id, count(fragment("DISTINCT ?", selection.product_option_id))}
        )
        |> Repo.all()
        |> Map.new()
      end

    Map.new(variant_ids, fn variant_id ->
      required_count =
        required_option_count(variant_id, product_id_by_variant, required_option_ids_by_product)

      selected_count = Map.get(selected_required_count_by_variant, variant_id, 0)
      {variant_id, required_count == 0 or selected_count == required_count}
    end)
  end

  defp product_id_by_variant(variant_ids, variants_by_id) do
    variant_ids
    |> Enum.reduce(%{}, fn variant_id, acc ->
      case Map.get(variants_by_id, variant_id) do
        %Variant{product_id: product_id} -> Map.put(acc, variant_id, product_id)
        _ -> acc
      end
    end)
  end

  defp required_option_count(variant_id, product_id_by_variant, required_option_ids_by_product) do
    case Map.get(product_id_by_variant, variant_id) do
      nil ->
        0

      product_id ->
        required_option_ids_by_product
        |> Map.get(product_id, [])
        |> length()
    end
  end

  defp maybe_reload_checkout_draft(%CheckoutDraft{id: nil}, %Cart{} = cart) do
    case Repo.get_by(CheckoutDraft, cart_id: cart.id, cart_version: cart.version) do
      %CheckoutDraft{} = draft ->
        draft

      nil ->
        Repo.rollback(Error.new("INTERNAL_ERROR", "unable to load checkout draft after create"))
    end
  end

  defp maybe_reload_checkout_draft(%CheckoutDraft{} = draft, _cart), do: draft

  defp unique_cart_version_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        to_string(opts[:constraint_name] || "") ==
          "checkout_drafts_unique_cart_id_cart_version_index"

      _ ->
        false
    end)
  end

  defp unique_checkout_key_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        to_string(opts[:constraint_name] || "") ==
          "checkout_drafts_unique_checkout_key_index"

      _ ->
        false
    end)
  end

  defp constraint_error?(%Ecto.ConstraintError{} = error, constraint_name) do
    Exception.message(error)
    |> String.contains?(constraint_name)
  end

  defp checkout_scope_for_cart(%Cart{user_id: nil, id: cart_id}) when is_binary(cart_id),
    do: "guest_cart:#{cart_id}"

  defp checkout_scope_for_cart(_cart), do: nil

  defp resolve_subscription_plans_for_items(items) when is_list(items) do
    variant_ids =
      items
      |> Enum.map(& &1.variant_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    plans_by_variant =
      VariantSubscriptionPlan
      |> where([attachment], attachment.variant_id in ^variant_ids and attachment.active == true)
      |> join(:inner, [attachment], plan in SubscriptionPlan,
        on: plan.id == attachment.subscription_plan_id
      )
      |> select(
        [attachment, plan],
        {attachment.variant_id, attachment.subscription_plan_id, plan}
      )
      |> Repo.all()
      |> Enum.group_by(fn {variant_id, _plan_id, _plan} -> variant_id end, fn {_variant_id,
                                                                               plan_id, plan} ->
        {plan_id, plan}
      end)

    Enum.reduce_while(items, {:ok, %{}}, fn item, {:ok, acc} ->
      explicit_plan_id = Map.get(item, :subscription_plan_id)
      variant_plans = Map.get(plans_by_variant, item.variant_id, [])

      case pick_subscription_plan_for_item(item.variant_id, explicit_plan_id, variant_plans) do
        {:ok, plan} ->
          {:cont, {:ok, Map.put(acc, item.id, plan)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp pick_subscription_plan_for_item(_variant_id, explicit_plan_id, variant_plans)
       when is_binary(explicit_plan_id) do
    case Enum.find(variant_plans, fn {plan_id, _plan} -> plan_id == explicit_plan_id end) do
      {_plan_id, plan} ->
        {:ok, plan}

      nil ->
        {:error,
         Error.new(
           "VALIDATION_ERROR",
           "subscription_plan_id is not active for the selected variant"
         )}
    end
  end

  defp pick_subscription_plan_for_item(_variant_id, _explicit_plan_id, []), do: {:ok, nil}

  defp pick_subscription_plan_for_item(_variant_id, _explicit_plan_id, [{_plan_id, plan}]),
    do: {:ok, plan}

  defp pick_subscription_plan_for_item(_variant_id, _explicit_plan_id, _variant_plans) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "variant has multiple active subscription plans; explicit subscription_plan_id is required"
     )}
  end

  defp resolve_subscription_plans_for_items!([]), do: %{}

  defp resolve_subscription_plans_for_items!(items) do
    case resolve_subscription_plans_for_items(items) do
      {:ok, plans_by_item_id} ->
        plans_by_item_id

      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp resolve_subscription_revisions_for_plans!(plans_by_item_id)
       when is_map(plans_by_item_id) do
    plans_by_item_id
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while(%{}, fn plan, acc ->
      case PlanRevision.get_effective_for_plan(plan.id,
             authorize?: false,
             context: %{system?: true}
           ) do
        {:ok, %PlanRevision{} = revision} ->
          {:cont, Map.put(acc, plan.id, revision)}

        {:ok, nil} ->
          {:halt,
           Repo.rollback(
             Error.new("VALIDATION_ERROR", "subscription plan has no effective revision")
           )}

        {:error, _reason} ->
          {:halt,
           Repo.rollback(
             Error.new("VALIDATION_ERROR", "subscription plan has no effective revision")
           )}
      end
    end)
  end

  defp revision_for_plan(%SubscriptionPlan{id: plan_id}, revisions_by_plan_id),
    do: Map.get(revisions_by_plan_id, plan_id)

  defp revision_for_plan(_plan, _revisions_by_plan_id), do: nil

  defp line_unit_price_for_item(_item, _variant, %{amount_minor: amount_minor})
       when is_integer(amount_minor),
       do: amount_minor

  defp line_unit_price_for_item(_item, %Variant{price_minor: price_minor}, _plan)
       when is_integer(price_minor),
       do: price_minor

  defp line_unit_price_for_item(_item, _variant, _plan), do: 0

  defp line_currency_for_item(_item, _variant, %{currency: currency}) when is_binary(currency),
    do: String.upcase(currency)

  defp line_currency_for_item(_item, %Variant{currency_code: code}, _plan) when is_binary(code),
    do: String.upcase(code)

  defp line_currency_for_item(_item, _variant, _plan), do: nil

  defp resolved_plan_id_for_item(item, plans_by_item_id) do
    case Map.get(plans_by_item_id, item.id) do
      %{id: plan_id} -> plan_id
      _ -> nil
    end
  end

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp checkout_currency_value(checkout) do
    case checkout_currency(checkout) do
      {:ok, currency} -> currency
      _ -> "USD"
    end
  end

  defp normalize_db_error(%Error{} = error), do: error

  defp normalize_db_error(%Ecto.StaleEntryError{}) do
    Error.new("STALE_RECORD", "checkout state changed during write")
  end

  defp normalize_db_error(%Ecto.ConstraintError{} = error) do
    message = Exception.message(error)

    cond do
      is_binary(message) and
          String.contains?(message, "checkout_drafts_unique_cart_id_cart_version_index") ->
        Error.new("STALE_RECORD", "checkout draft already exists")

      is_binary(message) and
          String.contains?(message, "checkout_drafts_unique_checkout_key_index") ->
        Error.new("CHECKOUT_DUPLICATE", "checkout draft already exists for checkout key")

      is_binary(message) and String.contains?(message, "orders_unique_checkout_key_index") ->
        Error.new("CHECKOUT_DUPLICATE", "checkout key already exists")

      true ->
        Error.new("VALIDATION_ERROR", "invalid checkout data")
    end
  end

  defp normalize_db_error(%Ecto.Changeset{} = changeset) do
    case first_constraint(changeset) do
      "checkout_drafts_unique_cart_id_cart_version_index" ->
        Error.new("STALE_RECORD", "checkout draft already exists")

      "checkout_drafts_unique_checkout_key_index" ->
        Error.new("CHECKOUT_DUPLICATE", "checkout draft already exists for checkout key")

      "orders_unique_checkout_key_index" ->
        Error.new("CHECKOUT_DUPLICATE", "checkout key already exists")

      _ ->
        Error.new("VALIDATION_ERROR", "invalid checkout data")
    end
  end

  defp normalize_db_error(%DBConnection.ConnectionError{} = error) do
    message = Exception.message(error) |> String.downcase()

    cond do
      String.contains?(message, "deadlock") ->
        Error.new("RESERVATION_CONFLICT", "checkout write conflict; retry checkout")

      String.contains?(message, "timeout") ->
        Error.new("RESERVATION_CONFLICT", "checkout write timed out; retry checkout")

      true ->
        Error.new("INTERNAL_ERROR", "checkout operation failed")
    end
  end

  defp normalize_db_error(%Postgrex.Error{} = error) do
    message = Exception.message(error)

    cond do
      String.contains?(message, "deadlock") ->
        Error.new("RESERVATION_CONFLICT", "checkout write conflict; retry checkout")

      String.contains?(message, "could not serialize") ->
        Error.new("STALE_RECORD", "checkout state changed during write")

      true ->
        Error.new("INTERNAL_ERROR", "checkout operation failed")
    end
  end

  defp normalize_db_error(%Ash.Error.Invalid{} = error) do
    normalized = Normalize.normalize(error)
    message = Exception.message(error)

    cond do
      is_binary(message) and String.contains?(message, "order_ref") and
          String.contains?(message, "already been taken") ->
        Error.new("CHECKOUT_DUPLICATE", "checkout order reference conflict")

      is_binary(message) and String.contains?(message, "checkout_key") and
          String.contains?(message, "already been taken") ->
        Error.new("CHECKOUT_DUPLICATE", "checkout key already exists")

      true ->
        normalized
    end
  end

  defp normalize_db_error(other) do
    other
    |> Normalize.normalize()
    |> case do
      %Error{code: "INTERNAL_ERROR"} -> Error.new("INTERNAL_ERROR", "checkout operation failed")
      %Error{} = error -> error
    end
  end

  defp telemetry_result({:ok, %{duplicate?: true}}), do: :duplicate
  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result({:error, _}), do: :error
  defp telemetry_result(:ok), do: :ok
  defp telemetry_result(_), do: :ok

  defp emit_step_telemetry(step, started_at, result, repo_stats) when is_atom(step) do
    :telemetry.execute(
      [:store, :checkout, :step],
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

  defp traced_checkout_step(step, substep, fun)
       when is_atom(step) and is_atom(substep) and is_function(fun, 0) do
    if checkout_trace_enabled?() do
      started_at = System.monotonic_time()
      result = fun.()

      :telemetry.execute(
        [:store, :checkout, :trace],
        %{duration: System.monotonic_time() - started_at},
        %{step: step, substep: substep, result: telemetry_result(result)}
      )

      result
    else
      fun.()
    end
  end

  defp traced_set_shipping_checkout_context(actor, checkout_key) do
    traced_checkout_step(:set_shipping, :checkout_context, fn ->
      checkout_context_for_user(actor, checkout_key)
    end)
  end

  defp traced_set_shipping_quote_options(checkout, input) do
    traced_checkout_step(:set_shipping, :quote_options, fn ->
      quote_options_for_checkout(checkout, input)
    end)
  end

  defp traced_set_shipping_selection(options, input) do
    traced_checkout_step(:set_shipping, :select_quote_option, fn ->
      select_quote_option(options, input)
    end)
  end

  defp traced_set_shipping_persist_details(order, input, selected_option) do
    traced_checkout_step(:set_shipping, :persist_shipping_details, fn ->
      update_order_shipping_details(order, input, selected_option)
    end)
  end

  defp traced_finalize_checkout_context(actor, checkout_key) do
    traced_checkout_step(:finalize_totals, :checkout_context, fn ->
      checkout_context_for_user(actor, checkout_key)
    end)
  end

  defp traced_quote_evidence(order) do
    traced_checkout_step(:finalize_totals, :quote_evidence, fn ->
      quote_evidence_from_order(order)
    end)
  end

  defp traced_quote_integrity(quote_evidence) do
    traced_checkout_step(:finalize_totals, :quote_integrity, fn ->
      validate_quote_integrity(quote_evidence)
    end)
  end

  defp traced_fetch_tax_rates(country_code) do
    traced_checkout_step(:finalize_totals, :fetch_tax_rates, fn ->
      fetch_tax_rates(country_code)
    end)
  end

  defp traced_tax_shipping_evaluation(line_items, order, quote_evidence, tax_rates) do
    traced_checkout_step(:finalize_totals, :evaluate_tax_shipping, fn ->
      evaluate_tax_shipping_from_quote_evidence(line_items, order, quote_evidence, tax_rates)
    end)
  end

  defp traced_shipping_adjustment(order, quote_evidence, pricing_adjustment_count) do
    traced_checkout_step(:finalize_totals, :ensure_shipping_adjustment, fn ->
      ensure_shipping_adjustment(order, quote_evidence, pricing_adjustment_count)
    end)
  end

  defp traced_write_tax_shipping_snapshot(order_id, output) do
    traced_checkout_step(:finalize_totals, :write_tax_shipping_snapshot, fn ->
      Store.Orders.write_tax_shipping_snapshot(order_id, output)
    end)
  end

  defp non_neg_int(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, fallback) when is_integer(fallback) and fallback >= 0, do: fallback
  defp non_neg_int(_value, _fallback), do: 0

  defp with_checkout_stage({:error, error}, stage) do
    {:error, error |> normalize_db_error() |> put_checkout_stage(stage)}
  end

  defp with_checkout_stage(result, _stage), do: result

  defp normalize_post_commit_result(:ok), do: :ok

  defp normalize_post_commit_result(other) do
    {:error, other |> normalize_db_error() |> put_checkout_stage(:post_commit_notification)}
  end

  defp put_checkout_stage(%Error{} = error, stage) when is_atom(stage) do
    meta =
      error.meta
      |> Map.new()
      |> Map.put_new(:checkout_stage, Atom.to_string(stage))

    %Error{error | meta: meta}
  end

  defp put_checkout_stage(other, stage),
    do: normalize_db_error(other) |> put_checkout_stage(stage)

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

  defp checkout_trace_enabled? do
    System.get_env("STORE_CHECKOUT_TRACE", "false") == "true" or
      Application.get_env(:store, :checkout_trace_enabled, false)
  end
end
