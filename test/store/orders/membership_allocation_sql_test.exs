defmodule Store.MembershipAllocationSqlTestRepo do
  use Ecto.Repo, otp_app: :store, adapter: Ecto.Adapters.Postgres
end

defmodule Store.Orders.MembershipAllocationSqlTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Store.TestSupport.IsolatedMigrationDatabase
  @repo Store.MembershipAllocationSqlTestRepo

  setup_all do
    db = IsolatedMigrationDatabase.start!("jc274_allocation_sql", @repo)
    on_exit(fn -> IsolatedMigrationDatabase.stop!(db) end)
    {:ok, db}
  end

  setup do
    Store.Repo.put_dynamic_repo(@repo)
    :ok
  end

  alias Store.Orders.Order
  alias Store.Pricing.{MembershipOfferRevision, MembershipOfferRevisionComponent}
  alias Store.Support.ID.UUIDv7

  @system %{system?: true}

  test "complete allocation reconciles under deferred database constraints" do
    with_transaction(fn ->
      {order, revision, component, rate} = evidence!()
      line = UUIDv7.generate()
      occurrence = UUIDv7.generate()
      set = UUIDv7.generate()
      insert_line!(order, revision, line, occurrence, rate)
      insert_set!(order, revision, set, occurrence, line)

      sql!(
        """
        INSERT INTO order_line_component_allocations
          (id, allocation_set_id, order_line_item_id, offer_component_id, component_instance_id,
           evaluation_line_id, gross_minor, discount_minor, net_minor, tax_minor)
        VALUES ($1,$2,$3,$4,$5,$6,100,0,100,0)
        """,
        [UUIDv7.generate(), set, line, component.id, UUIDv7.generate(), UUIDv7.generate()]
      )

      sql!("UPDATE order_line_component_allocation_sets SET accepted_at = now() WHERE id = $1", [
        set
      ])

      assert {:ok, _} = Ecto.Adapters.SQL.query(@repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
    end)
  end

  test "a marked line without an allocation cannot pass deferred constraints" do
    with_transaction(fn ->
      {order, revision, _component, rate} = evidence!()
      insert_line!(order, revision, UUIDv7.generate(), UUIDv7.generate(), rate)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Ecto.Adapters.SQL.query(@repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
    end)
  end

  defp with_transaction(fun) do
    @repo.transaction(fn ->
      fun.()
      @repo.rollback(:fixture_cleanup)
    end)
  end

  defp evidence! do
    revision =
      MembershipOfferRevision
      |> Ash.Changeset.for_create(
        :create_draft,
        %{offer_key: "sql.#{UUIDv7.generate()}", revision: 1, currency: "USD"},
        context: @system
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: @system)

    component =
      MembershipOfferRevisionComponent
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          revision_id: revision.id,
          definition_key: UUIDv7.generate(),
          gross_minor: 100,
          discount_eligibility_key: "member",
          tax_treatment_key: "STANDARD"
        },
        context: @system
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: @system)

    {:ok, revision} = Store.Pricing.accept_membership_offer_revision_for_system(revision.id)

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{
        order_ref: "ORDSQL#{System.unique_integer([:positive])}"
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    sql!(
      "UPDATE public.orders SET currency_code = 'USD', totals_finalized_at = now(), shipping_country_code = 'US', tax_as_of = now() WHERE id = $1",
      [order.id]
    )

    rate =
      Store.Pricing.TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "ZERO#{UUIDv7.generate()}",
          country_code: "US",
          product_tax_category: "STANDARD",
          rate_basis_points: 0
        },
        context: @system
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: @system)

    {order, revision, component, rate}
  end

  defp insert_line!(order, revision, id, occurrence, rate) do
    sql!(
      """
      INSERT INTO order_line_items
        (id, order_id, line_no, currency, quantity, unit_price_minor, line_total_minor, sku_snapshot,
         product_title_snapshot, discount_allocated_minor, net_line_total_minor, tax_category_snapshot,
         tax_rate_id_snapshot, tax_rate_code_snapshot, tax_rate_bps_snapshot, tax_minor,
         membership_offer_revision_id_snapshot, membership_occurrence_key_snapshot, inserted_at, updated_at)
      VALUES ($1,$2,1,'USD',1,100,100,'SKU','Membership',0,100,'STANDARD',$3,(SELECT code FROM public.tax_rates WHERE id=$3),0,0,$4,$5,now(),now())
      """,
      [id, order.id, rate.id, revision.id, occurrence]
    )
  end

  defp insert_set!(order, revision, id, occurrence, line) do
    sql!(
      """
      INSERT INTO order_line_component_allocation_sets
        (id, order_id, offer_revision_id, occurrence_key, target_fingerprint, allocation_fingerprint,
         pricing_fingerprint, allocation_rule_version, currency, tax_context, accepted_at)
      VALUES ($1,$2,$3,$4,'target','allocation','pricing','v1','USD',(
        SELECT jsonb_build_object(
          'version','membership-tax-v1','tax_enabled',true,
          'order_id',o.id,'occurrence_key',$4::uuid,'currency','USD',
          'country','US','region',NULL,'as_of',o.tax_as_of,
          'lines',jsonb_build_array(jsonb_build_object(
            'line_id',l.id,'category',l.tax_category_snapshot,
            'rate_id',l.tax_rate_id_snapshot,'rate_code',l.tax_rate_code_snapshot,
            'rate_bps',l.tax_rate_bps_snapshot,'tax_minor',l.tax_minor,
            'net_minor',l.net_line_total_minor,
            'source',to_jsonb(r)-'inserted_at'-'updated_at')))
          FROM public.orders o JOIN public.order_line_items l ON l.order_id=o.id
          JOIN public.tax_rates r ON r.id=l.tax_rate_id_snapshot WHERE l.id=$5
        ),NULL)
      """,
      [id, order.id, revision.id, occurrence, line]
    )
  end

  defp sql!(statement, ids) do
    Ecto.Adapters.SQL.query!(@repo, statement, Enum.map(ids, &Ecto.UUID.dump!/1))
  end
end
