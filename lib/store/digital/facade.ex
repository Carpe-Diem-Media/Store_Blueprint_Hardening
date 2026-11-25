defmodule Store.Digital.Facade do
  @moduledoc """
  Admin, user, and system-facing digital fulfillment surfaces.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.Variant
  alias Store.Digital

  alias Store.Digital.{
    DigitalAsset,
    DownloadGrant,
    ProductDigitalLink,
    RedirectGuard,
    RevocationPolicy
  }

  alias Store.Digital.Queries.{
    AdminDigitalAssetIndexQuery,
    AdminProductDigitalLinkIndexQuery,
    DownloadGrantIndexQuery
  }

  alias Store.Digital.StorageProviders
  alias Store.Digital.Workers.IssueGrantsForPaidOrderWorker
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.Refund
  alias Store.Repo
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.RateLimit

  @seconds_per_day 86_400

  @type grant_entry :: %{
          link: ProductDigitalLink.t(),
          asset: DigitalAsset.t()
        }

  @spec list_digital_assets_for_admin(map(), AdminDigitalAssetIndexQuery.t()) ::
          {:ok, [DigitalAsset.t()]} | {:error, term()}
  def list_digital_assets_for_admin(actor, %AdminDigitalAssetIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      DigitalAsset
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> maybe_filter_asset_status(query.status)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Digital, actor: actor) do
      {:ok, assets} -> {:ok, assets}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_digital_asset_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, DigitalAsset.t() | nil} | {:error, term()}
  def get_digital_asset_for_admin(actor, digital_asset_id)
      when is_map(actor) and is_binary(digital_asset_id) do
    ash_query =
      DigitalAsset
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> Ash.Query.filter(expr(id == ^digital_asset_id))

    case Ash.read_one(ash_query, domain: Digital, actor: actor) do
      {:ok, asset} -> {:ok, asset}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec list_product_digital_links_for_admin(map(), AdminProductDigitalLinkIndexQuery.t()) ::
          {:ok, [ProductDigitalLink.t()]} | {:error, term()}
  def list_product_digital_links_for_admin(actor, %AdminProductDigitalLinkIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      ProductDigitalLink
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> maybe_filter_link_product(query.product_id)
      |> maybe_filter_link_variant(query.variant_id)
      |> maybe_filter_link_asset(query.digital_asset_id)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)
      |> Ash.Query.load([:digital_asset, :product, :variant])

    case Ash.read(ash_query, domain: Digital, actor: actor) do
      {:ok, links} -> {:ok, links}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_product_digital_link_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ProductDigitalLink.t() | nil} | {:error, term()}
  def get_product_digital_link_for_admin(actor, link_id)
      when is_map(actor) and is_binary(link_id) do
    ash_query =
      ProductDigitalLink
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> Ash.Query.filter(expr(id == ^link_id))
      |> Ash.Query.load([:digital_asset, :product, :variant])

    case Ash.read_one(ash_query, domain: Digital, actor: actor) do
      {:ok, link} -> {:ok, link}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec list_download_grants_for_user(map(), DownloadGrantIndexQuery.t()) ::
          {:ok, [DownloadGrant.t()]} | {:error, term()}
  def list_download_grants_for_user(actor, %DownloadGrantIndexQuery{} = query)
      when is_map(actor) do
    with {:ok, actor_id} <- extract_actor_id(actor) do
      ash_query =
        DownloadGrant
        |> Ash.Query.filter(expr(actor_user_id == ^actor_id))
        |> maybe_filter_grant_status(query.status)
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(query.limit)
        |> Ash.Query.offset(query.offset)
        |> Ash.Query.load([:digital_asset])

      case Ash.read(ash_query, domain: Digital, authorize?: false, context: %{system?: true}) do
        {:ok, grants} -> {:ok, grants}
        {:error, error} -> {:error, Normalize.normalize(error)}
      end
    end
  end

  @spec issue_signed_download_url_for_user(map(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{grant: DownloadGrant.t(), signed_url: String.t()}}
          | {:error, Error.t() | term()}
  def issue_signed_download_url_for_user(actor, grant_id, opts \\ [])
      when is_map(actor) and is_binary(grant_id) and is_list(opts) do
    started_at = System.monotonic_time()

    result =
      with {:ok, actor_id} <- extract_actor_id(actor),
           {:ok, grant} <- fetch_download_grant_for_user(actor, grant_id),
           :ok <- ensure_downloadable(grant),
           :ok <- enforce_signed_url_rate_limit(grant.id, actor_id),
           {:ok, asset} <- fetch_active_asset(grant.digital_asset_id),
           {:ok, signed_url} <- sign_asset_url(asset, opts),
           :ok <- RedirectGuard.validate_signed_url(signed_url) do
        {:ok, %{grant: grant, signed_url: signed_url}}
      end

    :telemetry.execute(
      [:store, :digital, :signed_url],
      %{duration: System.monotonic_time() - started_at},
      %{outcome: signed_url_outcome(result)}
    )

    result
  end

  @spec ensure_paid_order_download_grants_for_system(Ecto.UUID.t()) ::
          {:ok,
           %{
             order_id: Ecto.UUID.t(),
             line_count: non_neg_integer(),
             processed_count: non_neg_integer()
           }}
          | {:error, term()}
  def ensure_paid_order_download_grants_for_system(order_id) when is_binary(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         :ok <- ensure_order_state_paid(order),
         :ok <- ensure_order_has_user(order),
         {:ok, line_items} <- fetch_order_line_items(order_id),
         {:ok, plan} <- resolve_grant_plan(line_items),
         {:ok, processed_count} <- persist_grants(order, plan) do
      {:ok,
       %{
         order_id: order_id,
         line_count: length(line_items),
         processed_count: processed_count
       }}
    end
  end

  @doc "Queues grant issuance on Store.Repo so it commits with the payment application when called in that transaction."
  @spec enqueue_paid_order_download_grants_for_system(Ecto.UUID.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_paid_order_download_grants_for_system(order_id) when is_binary(order_id) do
    changeset = IssueGrantsForPaidOrderWorker.new(%{"order_id" => order_id})
    multi = Oban.insert(Ecto.Multi.new(), :grant_job, changeset)

    case Repo.transaction(multi) do
      {:ok, %{grant_job: job}} -> {:ok, job}
      {:error, :grant_job, reason, _changes} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec order_has_digital_assets_for_system(Ecto.UUID.t()) :: {:ok, boolean()} | {:error, term()}
  def order_has_digital_assets_for_system(order_id) when is_binary(order_id) do
    with {:ok, _order} <- fetch_order(order_id),
         {:ok, line_items} <- fetch_order_line_items(order_id),
         {:ok, plan} <- resolve_grant_plan(line_items) do
      {:ok, Enum.any?(plan, fn {_line_id, entries} -> entries != [] end)}
    end
  end

  @spec ensure_checkout_actor_allowed_for_system(map() | nil, Ecto.UUID.t()) ::
          :ok | {:error, Error.t() | term()}
  def ensure_checkout_actor_allowed_for_system(actor, order_id) when is_binary(order_id) do
    with {:ok, has_digital_assets?} <- order_has_digital_assets_for_system(order_id) do
      if has_digital_assets? and match?({:error, _}, extract_actor_id(actor || %{})) do
        {:error,
         Error.new(
           "DIGITAL_GRANT_DENIED",
           "digital products require a signed-in user before payment"
         )}
      else
        :ok
      end
    end
  end

  @spec apply_refund_revocation_for_system(Refund.t()) ::
          {:ok, %{policy: RevocationPolicy.t(), revoked_count: non_neg_integer()}}
          | {:error, term()}
  def apply_refund_revocation_for_system(%Refund{} = refund) do
    with {:ok, order} <- fetch_order(refund.order_id),
         policy <- RevocationPolicy.current(),
         {:ok, revoked_count} <- apply_revocation_by_policy(policy, refund, order) do
      {:ok, %{policy: policy, revoked_count: revoked_count}}
    end
  end

  defp apply_revocation_by_policy(policy, %Refund{} = refund, %Order{} = order) do
    if refund_scope_kind(refund) == :shipping_refund do
      {:ok, 0}
    else
      apply_revocation_by_policy_non_shipping(policy, refund, order)
    end
  end

  defp apply_revocation_by_policy_non_shipping(
         :strict_line_scoped,
         %Refund{} = refund,
         %Order{} = order
       ) do
    cond do
      full_refund?(refund, order) ->
        revoke_all_grants_for_order(order.id, refund.id)

      refund_line_item_ids(refund) == [] ->
        {:ok, 0}

      true ->
        revoke_line_item_grants(order.id, refund_line_item_ids(refund), refund.id)
    end
  end

  defp apply_revocation_by_policy_non_shipping(
         :strict_order_scoped,
         %Refund{} = refund,
         %Order{} = order
       ) do
    if full_refund?(refund, order) or order_scoped_refund?(refund) do
      revoke_all_grants_for_order(order.id, refund.id)
    else
      {:ok, 0}
    end
  end

  defp apply_revocation_by_policy_non_shipping(:threshold, %Refund{} = refund, %Order{} = order) do
    cond do
      full_refund?(refund, order) ->
        revoke_all_grants_for_order(order.id, refund.id)

      refund_line_item_ids(refund) == [] ->
        {:ok, 0}

      true ->
        apply_threshold_revocation(refund, order)
    end
  end

  defp apply_revocation_by_policy_non_shipping(_policy, %Refund{} = refund, %Order{} = order) do
    apply_revocation_by_policy_non_shipping(:strict_line_scoped, refund, order)
  end

  defp apply_threshold_revocation(%Refund{} = refund, %Order{} = order) do
    line_item_ids = refund_line_item_ids(refund)

    with {:ok, digital_total_minor} <- digital_value_minor_for_line_items(order.id, line_item_ids) do
      maybe_revoke_threshold_lines(
        digital_total_minor,
        refund.requested_amount_minor,
        order.id,
        line_item_ids,
        refund.id
      )
    end
  end

  defp maybe_revoke_threshold_lines(
         digital_total_minor,
         requested_amount_minor,
         order_id,
         line_item_ids,
         refund_id
       ) do
    if digital_total_minor > 0 and requested_amount_minor >= digital_total_minor do
      revoke_line_item_grants(order_id, line_item_ids, refund_id)
    else
      {:ok, 0}
    end
  end

  defp revoke_all_grants_for_order(order_id, refund_id) do
    query =
      DownloadGrant
      |> Ash.Query.filter(expr(order_id == ^order_id and status == :active))

    revoke_matching_grants(query, refund_id)
  end

  defp revoke_line_item_grants(order_id, line_item_ids, refund_id) when is_list(line_item_ids) do
    query =
      DownloadGrant
      |> Ash.Query.filter(
        expr(order_id == ^order_id and status == :active and order_line_item_id in ^line_item_ids)
      )

    revoke_matching_grants(query, refund_id)
  end

  defp revoke_matching_grants(query, refund_id) do
    with {:ok, grants} <-
           Ash.read(query, domain: Digital, authorize?: false, context: %{system?: true}) do
      revoke_grants(grants, refund_id)
    end
  end

  defp revoke_grants(grants, refund_id) when is_list(grants) do
    Enum.reduce_while(grants, {:ok, 0}, fn grant, {:ok, count} ->
      case revoke_grant(grant, refund_id) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp revoke_grant(%DownloadGrant{} = grant, refund_id) do
    grant
    |> Ash.Changeset.for_update(
      :revoke,
      %{revoked_reason: "refund:#{refund_id}"},
      context: %{system?: true}
    )
    |> Ash.update(domain: Digital, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp digital_value_minor_for_line_items(order_id, line_item_ids) do
    query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order_id and id in ^line_item_ids))

    with {:ok, line_items} <-
           Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}),
         {:ok, plan} <- resolve_grant_plan(line_items) do
      digital_line_ids = digital_line_ids_from_plan(plan)
      {:ok, sum_digital_line_total(line_items, digital_line_ids)}
    end
  end

  defp digital_line_ids_from_plan(plan) when is_list(plan) do
    plan
    |> Enum.filter(fn {_line_item_id, entries} -> entries != [] end)
    |> Enum.map(fn {line_item_id, _entries} -> line_item_id end)
    |> MapSet.new()
  end

  defp sum_digital_line_total(line_items, digital_line_ids) when is_list(line_items) do
    Enum.reduce(line_items, 0, fn line_item, acc ->
      if MapSet.member?(digital_line_ids, line_item.id) do
        acc + (line_item.net_line_total_minor || 0)
      else
        acc
      end
    end)
  end

  defp full_refund?(%Refund{} = refund, %Order{} = order) do
    refund_scope_kind(refund) == :full_refund or order.state == :refunded
  end

  defp order_scoped_refund?(%Refund{} = refund) do
    refund_line_item_ids(refund) == [] and refund_scope_kind(refund) != :shipping_refund
  end

  defp refund_scope_kind(%Refund{scope_kind: scope_kind}) do
    case scope_kind do
      :full_refund -> :full_refund
      :partial_refund -> :partial_refund
      :shipping_refund -> :shipping_refund
      "full_refund" -> :full_refund
      "partial_refund" -> :partial_refund
      "shipping_refund" -> :shipping_refund
      _ -> :partial_refund
    end
  end

  defp refund_line_item_ids(%Refund{line_item_ids: line_item_ids}) when is_list(line_item_ids),
    do: Enum.uniq(line_item_ids)

  defp refund_line_item_ids(_refund), do: []

  defp persist_grants(%Order{} = order, plan) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    default_ttl_days = Keyword.get(digital_config(), :default_grant_ttl_days, 30)
    default_max_downloads = Keyword.get(digital_config(), :default_max_downloads)

    grant_context = %{
      now: now,
      default_ttl_days: default_ttl_days,
      default_max_downloads: default_max_downloads
    }

    Enum.reduce_while(plan, {:ok, 0}, fn {line_item_id, entries}, {:ok, count} ->
      case persist_line_item_grants(order, line_item_id, entries, grant_context) do
        {:ok, line_count} -> {:cont, {:ok, count + line_count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_line_item_grants(order, line_item_id, entries, grant_context) do
    Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, count} ->
      case persist_single_grant(order, line_item_id, entry, grant_context) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_single_grant(
         %Order{} = order,
         line_item_id,
         %{link: link, asset: asset},
         %{
           now: now,
           default_ttl_days: default_ttl_days,
           default_max_downloads: default_max_downloads
         }
       ) do
    attrs = %{
      order_id: order.id,
      order_line_item_id: line_item_id,
      digital_asset_id: asset.id,
      actor_user_id: order.user_id,
      status: :active,
      issued_at: now,
      expires_at: grant_expires_at(link, default_ttl_days, now),
      max_downloads: grant_max_downloads(link, default_max_downloads),
      idempotency_key: grant_idempotency_key(line_item_id, asset.id)
    }

    DownloadGrant
    |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
    |> Ash.create(domain: Digital, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, grant} ->
        maybe_emit_grant_issued_telemetry(grant, order.id, now)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grant_idempotency_key(line_item_id, asset_id),
    do: "grant:line_item:#{line_item_id}:asset:#{asset_id}"

  defp maybe_emit_grant_issued_telemetry(%DownloadGrant{} = grant, order_id, expected_issued_at) do
    if Ash.Resource.get_metadata(grant, :upsert_skipped) == true or
         DateTime.compare(grant.issued_at, expected_issued_at) != :eq do
      :ok
    else
      emit_grant_issued_telemetry(grant, order_id)
    end
  end

  defp emit_grant_issued_telemetry(%DownloadGrant{} = grant, order_id) do
    :telemetry.execute(
      [:store, :digital, :grant_issued],
      %{count: 1},
      %{asset_id: grant.digital_asset_id, order_id: order_id, grant_id: grant.id}
    )
  end

  defp grant_expires_at(%ProductDigitalLink{} = link, default_ttl_days, now) do
    expires_in_days =
      case link.grant_expires_in_days do
        value when is_integer(value) and value > 0 -> value
        _ -> default_ttl_days
      end

    if is_integer(expires_in_days) and expires_in_days > 0 do
      DateTime.add(now, expires_in_days * @seconds_per_day, :second)
    else
      nil
    end
  end

  defp grant_max_downloads(%ProductDigitalLink{} = link, default_max_downloads) do
    case link.grant_max_downloads do
      value when is_integer(value) and value > 0 -> value
      _ -> normalize_max_downloads(default_max_downloads)
    end
  end

  defp normalize_max_downloads(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_downloads(_value), do: nil

  defp resolve_grant_plan(line_items) when is_list(line_items) do
    variant_ids =
      line_items
      |> Enum.map(& &1.variant_id_snapshot)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    with {:ok, variants_by_id} <- fetch_variants_by_id(variant_ids),
         {:ok, {links_by_variant_id, links_by_product_id}} <-
           fetch_links_by_targets(variant_ids, Map.values(variants_by_id)),
         {:ok, assets_by_id} <- fetch_assets_by_links(links_by_variant_id, links_by_product_id) do
      {:ok,
       Enum.map(line_items, fn line_item ->
         {line_item.id,
          resolve_line_entries(
            line_item,
            variants_by_id,
            links_by_variant_id,
            links_by_product_id,
            assets_by_id
          )}
       end)}
    end
  end

  defp resolve_line_entries(
         %OrderLineItem{} = line_item,
         variants_by_id,
         links_by_variant_id,
         links_by_product_id,
         assets_by_id
       ) do
    with variant_id when is_binary(variant_id) <- line_item.variant_id_snapshot,
         %Variant{} = variant <- Map.get(variants_by_id, variant_id) do
      variant_candidates =
        links_by_variant_id
        |> Map.get(variant.id, [])
        |> Enum.map(&candidate_from_link(&1, :variant, assets_by_id))

      product_candidates =
        links_by_product_id
        |> Map.get(variant.product_id, [])
        |> Enum.map(&candidate_from_link(&1, :product, assets_by_id))

      (variant_candidates ++ product_candidates)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn candidate ->
        {candidate.source_rank, candidate.position, candidate.asset_sort_key, candidate.asset.id}
      end)
      |> Enum.uniq_by(fn candidate -> candidate.asset.id end)
      |> Enum.sort_by(fn candidate ->
        {candidate.position, candidate.asset_sort_key, candidate.asset.id}
      end)
      |> Enum.map(fn candidate -> %{link: candidate.link, asset: candidate.asset} end)
    else
      _ -> []
    end
  end

  defp candidate_from_link(%ProductDigitalLink{} = link, source, assets_by_id) do
    with %DigitalAsset{} = asset <- Map.get(assets_by_id, link.digital_asset_id) do
      %{
        link: link,
        asset: asset,
        source_rank: source_rank(source),
        position: link.position || 0,
        asset_sort_key: asset_sort_key(asset)
      }
    end
  end

  defp source_rank(:variant), do: 0
  defp source_rank(:product), do: 1

  defp asset_sort_key(%DigitalAsset{key: key}) when is_binary(key) and key != "", do: key
  defp asset_sort_key(%DigitalAsset{id: id}), do: id

  defp fetch_variants_by_id([]), do: {:ok, %{}}

  defp fetch_variants_by_id(variant_ids) do
    query = Variant |> Ash.Query.filter(expr(id in ^variant_ids))

    with {:ok, variants} <-
           Ash.read(query, domain: Store.Catalog, authorize?: false, context: %{system?: true}) do
      {:ok, Map.new(variants, &{&1.id, &1})}
    end
  end

  defp fetch_links_by_targets(variant_ids, variants) do
    product_ids =
      variants
      |> Enum.map(& &1.product_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if variant_ids == [] and product_ids == [] do
      {:ok, {%{}, %{}}}
    else
      query =
        ProductDigitalLink
        |> Ash.Query.filter(expr(variant_id in ^variant_ids or product_id in ^product_ids))

      with {:ok, links} <-
             Ash.read(query, domain: Digital, authorize?: false, context: %{system?: true}) do
        links_by_variant_id =
          links
          |> Enum.filter(&is_binary(&1.variant_id))
          |> Enum.group_by(& &1.variant_id)

        links_by_product_id =
          links
          |> Enum.filter(&is_binary(&1.product_id))
          |> Enum.group_by(& &1.product_id)

        {:ok, {links_by_variant_id, links_by_product_id}}
      end
    end
  end

  defp fetch_assets_by_links(links_by_variant_id, links_by_product_id) do
    asset_ids =
      (Map.values(links_by_variant_id) ++ Map.values(links_by_product_id))
      |> List.flatten()
      |> Enum.map(& &1.digital_asset_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if asset_ids == [] do
      {:ok, %{}}
    else
      query = DigitalAsset |> Ash.Query.filter(expr(id in ^asset_ids and status == :active))

      with {:ok, assets} <-
             Ash.read(query, domain: Digital, authorize?: false, context: %{system?: true}) do
        {:ok, Map.new(assets, &{&1.id, &1})}
      end
    end
  end

  defp fetch_download_grant_for_user(actor, grant_id) do
    with {:ok, actor_id} <- extract_actor_id(actor) do
      query =
        DownloadGrant
        |> Ash.Query.filter(expr(id == ^grant_id and actor_user_id == ^actor_id))
        |> Ash.Query.limit(1)

      case Ash.read(query, domain: Digital, authorize?: false, context: %{system?: true}) do
        {:ok, [grant]} ->
          {:ok, grant}

        {:ok, []} ->
          {:error, Error.new("DIGITAL_GRANT_NOT_FOUND", "download grant not found")}

        {:error, error} ->
          {:error, Normalize.normalize(error)}
      end
    end
  end

  defp ensure_downloadable(%DownloadGrant{status: :revoked}) do
    {:error, Error.new("DIGITAL_GRANT_REVOKED", "download grant is revoked")}
  end

  defp ensure_downloadable(%DownloadGrant{status: :expired}) do
    {:error, Error.new("DIGITAL_GRANT_EXPIRED", "download grant is expired")}
  end

  defp ensure_downloadable(%DownloadGrant{} = grant) do
    cond do
      grant.status != :active ->
        {:error, Error.new("DIGITAL_GRANT_DENIED", "download grant is not active")}

      expired_at_runtime?(grant.expires_at) ->
        {:error, Error.new("DIGITAL_GRANT_EXPIRED", "download grant is expired")}

      true ->
        :ok
    end
  end

  defp expired_at_runtime?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp expired_at_runtime?(_expires_at), do: false

  defp fetch_active_asset(digital_asset_id) when is_binary(digital_asset_id) do
    query = DigitalAsset |> Ash.Query.filter(expr(id == ^digital_asset_id and status == :active))

    case Ash.read(query, domain: Digital, authorize?: false, context: %{system?: true}) do
      {:ok, [asset | _]} ->
        {:ok, asset}

      {:ok, []} ->
        {:error, Error.new("DIGITAL_GRANT_DENIED", "digital asset is unavailable")}

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  defp sign_asset_url(asset, opts) do
    ttl_seconds =
      opts
      |> Keyword.get(:ttl_seconds, Keyword.get(digital_config(), :signed_url_ttl_seconds, 120))

    StorageProviders.sign_download_url(asset, ttl_seconds: ttl_seconds)
  end

  defp enforce_signed_url_rate_limit(grant_id, actor_id) do
    limit = rate_limit_limit()
    window_seconds = rate_limit_window_seconds()
    scope_key = "grant:#{grant_id}:user:#{actor_id}"

    case RateLimit.allow?(:digital_signed_url, scope_key, limit, window_seconds) do
      {:ok, :allow} ->
        :ok

      {:ok, :deny} ->
        {:error,
         Error.new(
           "DIGITAL_DOWNLOAD_RATE_LIMITED",
           "download link issuance is temporarily rate limited"
         )}

      {:error, reason} ->
        {:error,
         Error.new("INTERNAL_ERROR", "unable to apply download rate limit", %{
           reason: inspect(reason)
         })}
    end
  end

  defp extract_actor_id(actor) when is_map(actor) do
    case Map.get(actor, :id) do
      actor_id when is_binary(actor_id) -> {:ok, actor_id}
      _ -> {:error, Error.new("DIGITAL_GRANT_DENIED", "authenticated user is required")}
    end
  end

  defp extract_actor_id(_actor),
    do: {:error, Error.new("DIGITAL_GRANT_DENIED", "authenticated user is required")}

  defp fetch_order(order_id) when is_binary(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_order_state_paid(%Order{state: :paid}), do: :ok

  defp ensure_order_state_paid(%Order{}) do
    {:error, Error.new("DIGITAL_GRANT_DENIED", "download grants require paid order state")}
  end

  defp ensure_order_has_user(%Order{user_id: user_id}) when is_binary(user_id), do: :ok

  defp ensure_order_has_user(%Order{}) do
    {:error,
     Error.new(
       "DIGITAL_GRANT_DENIED",
       "download grants require an order with an authenticated user"
     )}
  end

  defp fetch_order_line_items(order_id) do
    query = OrderLineItem |> Ash.Query.filter(expr(order_id == ^order_id))

    Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp maybe_filter_asset_status(query, nil), do: query

  defp maybe_filter_asset_status(query, status),
    do: Ash.Query.filter(query, expr(status == ^status))

  defp maybe_filter_link_product(query, nil), do: query

  defp maybe_filter_link_product(query, product_id),
    do: Ash.Query.filter(query, expr(product_id == ^product_id))

  defp maybe_filter_link_variant(query, nil), do: query

  defp maybe_filter_link_variant(query, variant_id),
    do: Ash.Query.filter(query, expr(variant_id == ^variant_id))

  defp maybe_filter_link_asset(query, nil), do: query

  defp maybe_filter_link_asset(query, digital_asset_id),
    do: Ash.Query.filter(query, expr(digital_asset_id == ^digital_asset_id))

  defp maybe_filter_grant_status(query, nil), do: query

  defp maybe_filter_grant_status(query, status),
    do: Ash.Query.filter(query, expr(status == ^status))

  defp rate_limit_limit do
    case Keyword.get(rate_limit_config(), :signed_download_limit, 10) do
      value when is_integer(value) and value > 0 -> value
      _ -> 10
    end
  end

  defp rate_limit_window_seconds do
    case Keyword.get(rate_limit_config(), :signed_download_window_seconds, 60) do
      value when is_integer(value) and value > 0 -> value
      _ -> 60
    end
  end

  defp rate_limit_config do
    Application.get_env(:store, :rate_limit, [])
  end

  defp digital_config do
    Application.get_env(:store, :digital, [])
  end

  defp signed_url_outcome({:ok, _result}), do: :ok

  defp signed_url_outcome({:error, %Error{code: "DIGITAL_DOWNLOAD_RATE_LIMITED"}}),
    do: :denied

  defp signed_url_outcome({:error, %Error{code: "DIGITAL_GRANT_EXPIRED"}}), do: :expired
  defp signed_url_outcome({:error, %Error{code: "DIGITAL_GRANT_REVOKED"}}), do: :denied
  defp signed_url_outcome({:error, _reason}), do: :error
end
