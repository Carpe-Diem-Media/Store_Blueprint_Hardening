defmodule Store.Pricing do
  @moduledoc """
  Pricing domain for persisted discount definitions and deterministic evaluation.
  """

  use Ash.Domain

  import Ash.Expr
  require Ash.Query

  alias Store.Pricing.{
    Contract,
    Coupon,
    Evaluator,
    MembershipOfferRevision,
    MembershipOfferRevisionComponent,
    Promotion,
    Queries.AdminTaxRatesQuery,
    TaxRate,
    TaxShippingContract,
    TaxShippingEvaluator
  }

  alias Store.Shipping
  alias Store.Shipping.{ShippingRateRule, ShippingZone}

  alias Store.Repo
  alias Store.Support.Errors.Error

  resources do
    resource(Store.Pricing.Coupon)
    resource(Store.Pricing.Promotion)
    resource(Store.Pricing.MembershipOfferRevision)
    resource(Store.Pricing.MembershipOfferRevisionComponent)
    resource(Store.Pricing.TaxRate)
  end

  @type evaluate_quote_opts :: [authorize?: boolean(), actor: term(), context: map()]

  @doc """
  Atomically accepts a complete draft Membership offer manifest.

  The revision row lock serializes acceptance with every child mutation. Replaying
  an accepted revision returns the same immutable evidence. This operation does not
  select an offer for a customer or create Commerce, Subscription, or access state.
  """
  @spec accept_membership_offer_revision_for_system(Ecto.UUID.t()) ::
          {:ok, MembershipOfferRevision.t()} | {:error, term()}
  def accept_membership_offer_revision_for_system(revision_id) when is_binary(revision_id) do
    case Ecto.UUID.dump(revision_id) do
      {:ok, encoded_id} -> accept_membership_offer_revision_transaction(revision_id, encoded_id)
      :error -> invalid_membership_offer_revision_id()
    end
  end

  def accept_membership_offer_revision_for_system(_revision_id) do
    invalid_membership_offer_revision_id()
  end

  @spec list_tax_rates_for_admin(AdminTaxRatesQuery.t(), map()) ::
          {:ok, [TaxRate.t()]} | {:error, term()}
  def list_tax_rates_for_admin(%AdminTaxRatesQuery{limit: limit}, actor) when is_map(actor) do
    query =
      TaxRate
      |> Ash.Query.for_read(:admin_index, %{limit: limit}, actor: actor)

    Ash.read(query, domain: __MODULE__, actor: actor)
  end

  @spec get_tax_rate_for_admin(Ecto.UUID.t(), map()) ::
          {:ok, TaxRate.t() | nil} | {:error, term()}
  def get_tax_rate_for_admin(id, actor) when is_binary(id) and is_map(actor) do
    query =
      TaxRate
      |> Ash.Query.for_read(:admin_get, %{id: id}, actor: actor)

    Ash.read_one(query, domain: __MODULE__, actor: actor)
  end

  @spec evaluate_quote(map(), evaluate_quote_opts()) ::
          {:ok, %{input: Contract.Input.t(), output: Contract.Output.t()}} | {:error, Error.t()}
  def evaluate_quote(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, input} <- build_input(attrs, opts),
         {:ok, output} <- Evaluator.evaluate(input) do
      {:ok, %{input: input, output: output}}
    end
  end

  @spec evaluate_tax_shipping_quote(map(), evaluate_quote_opts()) ::
          {:ok,
           %{
             input: TaxShippingContract.Input.t(),
             output: TaxShippingContract.Output.t()
           }}
          | {:error, Error.t()}
  def evaluate_tax_shipping_quote(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, input} <- build_tax_shipping_input(attrs, opts),
         {:ok, output} <- TaxShippingEvaluator.evaluate(input) do
      {:ok, %{input: input, output: output}}
    end
  end

  @spec build_input(map(), evaluate_quote_opts()) ::
          {:ok, Contract.Input.t()} | {:error, Error.t()}
  def build_input(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, as_of} <- fetch_datetime(attrs, :as_of),
         {:ok, currency} <- fetch_string(attrs, :currency),
         {:ok, lines} <- fetch_lines(attrs),
         {:ok, promotions} <- fetch_promotions(attrs, opts),
         {:ok, coupon} <- fetch_coupon(attrs, opts) do
      eligibility = Map.get(attrs, :eligibility, %{})

      input =
        Contract.to_input!(%{
          as_of: as_of,
          currency: currency,
          lines: lines,
          promotions: promotions,
          coupon: coupon,
          eligibility: eligibility
        })

      {:ok, input}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Missing required pricing input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid pricing input")}
  end

  @spec build_tax_shipping_input(map(), evaluate_quote_opts()) ::
          {:ok, TaxShippingContract.Input.t()} | {:error, Error.t()}
  def build_tax_shipping_input(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, as_of} <- fetch_datetime(attrs, :as_of),
         {:ok, currency} <- fetch_string(attrs, :currency),
         {:ok, country_code} <- fetch_string(attrs, :destination_country_code),
         {:ok, region_code} <- fetch_optional_string(attrs, :destination_region_code),
         {:ok, postal_code} <- fetch_optional_string(attrs, :destination_postal_code),
         {:ok, subtotal_minor} <- fetch_non_negative_integer(attrs, :subtotal_minor),
         {:ok, shipping_weight_grams} <- fetch_non_negative_integer(attrs, :shipping_weight_grams),
         {:ok, lines} <- fetch_tax_shipping_lines(attrs),
         {:ok, shipping_rates} <- fetch_shipping_rate_candidates(currency, opts),
         {:ok, tax_rates} <- fetch_tax_rate_candidates(country_code, opts) do
      input =
        TaxShippingContract.to_input!(%{
          as_of: as_of,
          currency: currency,
          destination_country_code: String.upcase(country_code),
          destination_region_code: to_upcase_or_nil(region_code),
          destination_postal_code: postal_code,
          subtotal_minor: subtotal_minor,
          shipping_weight_grams: shipping_weight_grams,
          lines: lines,
          shipping_rates: shipping_rates,
          tax_rates: tax_rates,
          free_shipping_coupon?: Map.get(attrs, :free_shipping_coupon?, false),
          shipping_enabled?: Map.get(attrs, :shipping_enabled?, true),
          tax_enabled?: Map.get(attrs, :tax_enabled?, true)
        })

      {:ok, input}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Missing required tax/shipping input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping input")}
  end

  @spec candidate_from_coupon(Coupon.t()) :: Contract.Candidate.t()
  def candidate_from_coupon(%Coupon{} = coupon) do
    %Contract.Candidate{
      id: coupon.id,
      source_kind: :coupon,
      code: coupon.code,
      discount_minor: coupon.discount_minor,
      starts_at: coupon.starts_at,
      ends_at: coupon.ends_at,
      active?: coupon.active,
      exclusive?: false,
      combinable?: coupon.combinable_with_promotions,
      allow_with_exclusive?: coupon.allow_with_exclusive,
      exclusive_priority: 0,
      precedence_rank: coupon.precedence_rank,
      inserted_at: coupon.inserted_at,
      eligibility_key: coupon.eligibility_key
    }
  end

  @spec candidate_from_promotion(Promotion.t()) :: Contract.Candidate.t()
  def candidate_from_promotion(%Promotion{} = promotion) do
    %Contract.Candidate{
      id: promotion.id,
      source_kind: :promotion,
      code: promotion.code,
      discount_minor: promotion.discount_minor,
      starts_at: promotion.starts_at,
      ends_at: promotion.ends_at,
      active?: promotion.active,
      exclusive?: promotion.exclusive,
      combinable?: promotion.combinable,
      allow_with_exclusive?: false,
      exclusive_priority: promotion.exclusive_priority,
      precedence_rank: promotion.precedence_rank,
      inserted_at: promotion.inserted_at,
      eligibility_key: promotion.eligibility_key
    }
  end

  defp fetch_lines(attrs) do
    lines = Map.get(attrs, :lines, [])

    if is_list(lines) and lines != [] do
      {:ok, lines}
    else
      {:error, Error.new("VALIDATION_ERROR", "Pricing lines are required")}
    end
  end

  defp fetch_tax_shipping_lines(attrs) do
    lines = Map.get(attrs, :lines, [])

    if is_list(lines) and lines != [] do
      {:ok, Enum.map(lines, &TaxShippingContract.to_line!/1)}
    else
      {:error, Error.new("VALIDATION_ERROR", "Tax/shipping lines are required")}
    end
  rescue
    KeyError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping line input")}

    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid tax/shipping line input")}
  end

  defp fetch_promotions(attrs, opts) do
    promotion_ids = Map.get(attrs, :promotion_ids, [])

    query =
      case promotion_ids do
        [] -> Promotion
        ids when is_list(ids) -> Ash.Query.filter(Promotion, expr(id in ^ids))
      end

    case Ash.read(query, domain: __MODULE__, authorize?: Keyword.get(opts, :authorize?, false)) do
      {:ok, promotions} -> {:ok, Enum.map(promotions, &candidate_from_promotion/1)}
      {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "Unable to read promotions")}
    end
  end

  defp fetch_coupon(attrs, opts) do
    case Map.get(attrs, :coupon_code) do
      nil ->
        {:ok, nil}

      code when is_binary(code) ->
        normalized_code = String.upcase(String.trim(code))

        query = Ash.Query.filter(Coupon, expr(code == ^normalized_code))

        case Ash.read(query,
               domain: __MODULE__,
               authorize?: Keyword.get(opts, :authorize?, false)
             ) do
          {:ok, [coupon]} -> {:ok, candidate_from_coupon(coupon)}
          {:ok, []} -> {:error, Error.new("INVALID_COUPON", "Coupon not found")}
          {:ok, _many} -> {:error, Error.new("INTERNAL_ERROR", "Coupon code is not unique")}
          {:error, _error} -> {:error, Error.new("INTERNAL_ERROR", "Unable to read coupon")}
        end

      _other ->
        {:error, Error.new("VALIDATION_ERROR", "Coupon code must be a string")}
    end
  end

  defp fetch_datetime(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, %DateTime{} = datetime} -> {:ok, datetime}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a DateTime")}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-empty string")}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a string or nil")}
    end
  end

  defp fetch_non_negative_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-negative integer")}
    end
  end

  defp fetch_shipping_rate_candidates(currency, opts) do
    query = Ash.Query.filter(ShippingRateRule, expr(currency == ^currency and active == true))

    with {:ok, rates} <-
           Ash.read(query,
             domain: Shipping,
             authorize?: Keyword.get(opts, :authorize?, false),
             context: %{system?: true}
           ),
         {:ok, zones_by_id} <- fetch_shipping_zones_by_id(rates, opts) do
      rates
      |> Enum.map(&shipping_candidate_from_rate(&1, zones_by_id))
      |> Enum.reject(&is_nil/1)
      |> then(&{:ok, &1})
    else
      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read shipping rates")}
    end
  end

  defp fetch_shipping_zones_by_id(rates, opts) do
    zone_ids =
      rates
      |> Enum.map(& &1.shipping_zone_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case zone_ids do
      [] ->
        {:ok, %{}}

      ids ->
        query = Ash.Query.filter(ShippingZone, expr(id in ^ids and active == true))

        case Ash.read(query,
               domain: Shipping,
               authorize?: Keyword.get(opts, :authorize?, false),
               context: %{system?: true}
             ) do
          {:ok, zones} -> {:ok, Map.new(zones, &{&1.id, &1})}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp shipping_candidate_from_rate(rate, zones_by_id) do
    zone = Map.get(zones_by_id, rate.shipping_zone_id)

    if rate.shipping_zone_id != nil and zone == nil do
      nil
    else
      %TaxShippingContract.ShippingRateCandidate{
        id: rate.id,
        code: rate.code,
        shipping_cost_minor: rate.shipping_cost_minor,
        country_code: zone && zone.country_code,
        region_code: zone && zone.region_code,
        weight_min_grams: rate.weight_min_grams,
        weight_max_grams: rate.weight_max_grams,
        free_over_subtotal_minor: rate.free_over_subtotal_minor,
        allow_free_shipping_coupon: rate.allow_free_shipping_coupon,
        starts_at: rate.starts_at,
        ends_at: rate.ends_at,
        active?: rate.active,
        precedence_rank: rate.precedence_rank
      }
    end
  end

  defp fetch_tax_rate_candidates(country_code, opts) do
    normalized_country = String.upcase(country_code)
    query = Ash.Query.filter(TaxRate, expr(country_code == ^normalized_country))

    case Ash.read(query, domain: __MODULE__, authorize?: Keyword.get(opts, :authorize?, false)) do
      {:ok, rates} ->
        {:ok,
         Enum.map(rates, fn rate ->
           %TaxShippingContract.TaxRateCandidate{
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
         end)}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read tax rates")}
    end
  end

  defp to_upcase_or_nil(nil), do: nil
  defp to_upcase_or_nil(value), do: value |> String.trim() |> String.upcase()

  defp accept_locked_membership_offer_revision(revision_id) do
    case Ash.get(MembershipOfferRevision, revision_id,
           domain: __MODULE__,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %MembershipOfferRevision{status: "accepted"} = revision} ->
        revision

      {:ok, %MembershipOfferRevision{status: "draft"} = revision} ->
        accept_draft_membership_offer_revision(revision)

      {:ok, %MembershipOfferRevision{status: "rejected"}} ->
        Repo.rollback(Error.new("VALIDATION_ERROR", "Rejected offer revisions are terminal"))

      {:ok, nil} ->
        Repo.rollback(Error.new("NOT_FOUND", "Membership offer revision not found"))

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp accept_membership_offer_revision_transaction(revision_id, encoded_id) do
    case Repo.transaction(fn ->
           lock_and_accept_membership_offer_revision(revision_id, encoded_id)
         end) do
      {:ok, revision} -> {:ok, revision}
      {:error, error} -> {:error, error}
    end
  end

  defp lock_and_accept_membership_offer_revision(revision_id, encoded_id) do
    case Repo.query!(
           "SELECT id FROM membership_offer_revisions WHERE id = $1 FOR UPDATE",
           [encoded_id]
         ) do
      %{num_rows: 1} ->
        accept_locked_membership_offer_revision(revision_id)

      %{num_rows: 0} ->
        Repo.rollback(Error.new("NOT_FOUND", "Membership offer revision not found"))
    end
  end

  defp invalid_membership_offer_revision_id do
    {:error, Error.new("VALIDATION_ERROR", "Invalid membership offer revision id")}
  end

  defp accept_draft_membership_offer_revision(revision) do
    revision_id = revision.id

    query =
      MembershipOfferRevisionComponent
      |> Ash.Query.filter(expr(revision_id == ^revision_id))
      |> Ash.Query.limit(17)

    case Ash.read(query,
           domain: __MODULE__,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, components} when length(components) == 17 ->
        Repo.rollback(invalid_offer_manifest_error())

      {:ok, components} ->
        case offer_manifest_fingerprint(revision, components) do
          {:ok, fingerprint} -> persist_accepted_offer_revision(revision, fingerprint)
          :error -> Repo.rollback(invalid_offer_manifest_error())
        end

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp offer_manifest_fingerprint(revision, components) do
    if valid_offer_manifest?(revision, components) do
      {:ok,
       MembershipOfferRevision.Fingerprint.compute(
         revision.offer_key,
         revision.revision,
         revision.currency,
         components
       )}
    else
      :error
    end
  end

  defp persist_accepted_offer_revision(revision, fingerprint) do
    changeset =
      Ash.Changeset.for_update(
        revision,
        :accept,
        %{
          fingerprint: fingerprint,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        },
        context: %{system?: true}
      )

    case Ash.update(changeset,
           domain: __MODULE__,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, accepted} -> accepted
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp invalid_offer_manifest_error do
    Error.new(
      "VALIDATION_ERROR",
      "Membership offer revision must contain one to sixteen valid component definitions"
    )
  end

  defp valid_offer_manifest?(%MembershipOfferRevision{} = revision, components) do
    definition_keys = Enum.map(components, & &1.definition_key)

    length(components) in 1..16 and
      length(Enum.uniq(definition_keys)) == length(definition_keys) and
      Regex.match?(~r/\A[A-Z]{3}\z/, revision.currency) and
      Enum.all?(components, fn component ->
        is_integer(component.gross_minor) and component.gross_minor >= 0 and
          valid_manifest_key?(component.discount_eligibility_key) and
          valid_manifest_key?(component.tax_treatment_key) and
          match?({:ok, _binary}, Ecto.UUID.dump(component.definition_key))
      end)
  end

  defp valid_manifest_key?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value)

  defp valid_manifest_key?(_value), do: false
end
