defmodule Store.MembershipAllocationCommitTestRepo do
  use Ecto.Repo, otp_app: :store, adapter: Ecto.Adapters.Postgres
end

defmodule Store.Orders.MembershipAllocationCommitTest do
  use ExUnit.Case, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias Store.Orders.{OrderLineComponentAllocation, OrderLineComponentAllocationSet}
  alias Store.Pricing.TaxShippingEvaluator
  alias Store.Support.ID.UUIDv7
  alias Store.TestSupport.IsolatedMigrationDatabase

  @moduletag :real_connections

  setup_all do
    db =
      IsolatedMigrationDatabase.start!(
        "jc274_allocation_commit",
        Store.MembershipAllocationCommitTestRepo,
        pool_size: 4
      )

    on_exit(fn -> IsolatedMigrationDatabase.stop!(db) end)
    {:ok, db}
  end

  test "complete transaction commits and accepted records resist later mutation", %{repo: repo} do
    fixture = fixture!(repo)
    assert {:ok, _} = construct(repo, fixture, :complete)

    for {query, params} <- [
          {"UPDATE public.order_line_component_allocation_sets SET accepted_at = NULL WHERE id=$1",
           [fixture.set]},
          {"DELETE FROM public.order_line_component_allocation_sets WHERE id=$1", [fixture.set]},
          {"UPDATE public.order_line_component_allocations SET tax_minor=1 WHERE allocation_set_id=$1",
           [fixture.set]},
          {"DELETE FROM public.order_line_items WHERE id=$1", [fixture.line]},
          {"UPDATE public.orders SET grand_total_minor=1000 WHERE id=$1", [fixture.order]}
        ] do
      assert {:error, %Postgrex.Error{}} = SQL.query(repo, query, params)
    end

    assert {:error, %Postgrex.Error{}} = insert_row(repo, fixture)
  end

  test "complete transaction with savepoint commits", %{repo: repo} do
    fixture = fixture!(repo)
    assert {:ok, _} = construct(repo, fixture, :savepoint)
  end

  test "empty tax context cannot be accepted", %{repo: repo} do
    fixture = fixture!(repo) |> Map.put(:empty_tax_context, true)
    assert {:error, %Postgrex.Error{}} = construct(repo, fixture, :complete)
  end

  test "complete source-backed positive-rate evidence commits", %{repo: repo} do
    f = fixture!(repo, 1500)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    assert %{rows: [[15]]} =
             SQL.query!(repo, "SELECT tax_minor FROM public.order_line_items WHERE id=$1", [
               f.line
             ])
  end

  test "malformed and inconsistent frozen evidence is rejected at real COMMIT", %{repo: repo} do
    changes =
      [
        fn _ -> %{} end,
        &Map.delete(&1, "version"),
        &Map.put(&1, "version", "unknown"),
        &Map.put(&1, "tax_enabled", false),
        &Map.put(&1, "tax_enabled", "true"),
        &Map.put(&1, "country", "GB"),
        &Map.put(&1, "region", "CA"),
        &Map.put(&1, "as_of", "2000-01-01T00:00:00Z"),
        &Map.put(&1, "order_id", UUIDv7.generate()),
        &Map.put(&1, "occurrence_key", UUIDv7.generate()),
        &Map.put(&1, "lines", %{}),
        &Map.put(&1, "lines", []),
        fn c -> Map.update!(c, "lines", &(&1 ++ &1)) end
      ] ++
        for {key, value} <- [
              {"line_id", UUIDv7.generate()},
              {"category", "OTHER"},
              {"rate_id", UUIDv7.generate()},
              {"rate_code", "FORGED"},
              {"rate_bps", 1},
              {"rate_bps", "0"},
              {"tax_minor", 1},
              {"net_minor", 99},
              {"source", %{}},
              {"source", nil}
            ] do
          fn c -> update_in(c, ["lines"], fn [line] -> [Map.put(line, key, value)] end) end
        end

    changes =
      changes ++
        for key <- ~w(line_id category rate_id rate_code rate_bps tax_minor net_minor source) do
          fn c -> update_in(c, ["lines"], fn [line] -> [Map.delete(line, key)] end) end
        end

    for change <- changes do
      f = fixture!(repo) |> Map.put(:context_change, change)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               construct(repo, f, :complete)

      assert_received {:commit_attempt, set_id} when set_id == f.set

      assert %{rows: [[0]]} =
               SQL.query!(
                 repo,
                 "SELECT count(*) FROM public.order_line_component_allocation_sets WHERE id=$1",
                 [f.set]
               )
    end
  end

  test "missing, inactive, inapplicable and stale source rates cannot commit", %{repo: repo} do
    for mutation <- [
          "DELETE FROM public.tax_rates WHERE id=$1",
          "UPDATE public.tax_rates SET active=false WHERE id=$1",
          "UPDATE public.tax_rates SET country_code='GB' WHERE id=$1",
          "UPDATE public.tax_rates SET region_code='CA' WHERE id=$1",
          "UPDATE public.tax_rates SET product_tax_category='OTHER' WHERE id=$1",
          "UPDATE public.tax_rates SET rate_basis_points=1500 WHERE id=$1",
          "UPDATE public.tax_rates SET starts_at=now()+interval '1 day' WHERE id=$1",
          "UPDATE public.tax_rates SET ends_at=now()-interval '1 day' WHERE id=$1"
        ] do
      f = fixture!(repo) |> Map.put(:source_mutation, mutation)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               construct(repo, f, :complete)

      assert_received {:commit_attempt, set_id} when set_id == f.set
    end
  end

  test "inconsistent accepted line tax cannot commit even with matching allocations and context",
       %{repo: repo} do
    f = fixture!(repo) |> Map.put(:tax, 1)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             construct(repo, f, :complete)
  end

  test "later source edits preserve frozen accepted evidence", %{repo: repo} do
    f = fixture!(repo)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    before =
      SQL.query!(
        repo,
        "SELECT tax_context FROM public.order_line_component_allocation_sets WHERE id=$1",
        [f.set]
      ).rows

    SQL.query!(
      repo,
      "UPDATE public.tax_rates SET rate_basis_points=1500,active=false WHERE id=$1",
      [
        f.rate
      ]
    )

    assert SQL.query!(
             repo,
             "SELECT tax_context FROM public.order_line_component_allocation_sets WHERE id=$1",
             [f.set]
           ).rows == before

    assert {:error, %Postgrex.Error{}} =
             SQL.query(
               repo,
               "UPDATE public.order_line_component_allocation_sets SET tax_context='{}' WHERE id=$1",
               [f.set]
             )
  end

  test "marked line without set cannot commit", %{repo: repo} do
    assert {:error, %Postgrex.Error{}} = construct(repo, fixture!(repo), :missing_set)
  end

  test "constructing set cannot commit", %{repo: repo} do
    assert {:error, %Postgrex.Error{}} = construct(repo, fixture!(repo), :unaccepted)
  end

  test "incomplete set cannot be accepted", %{repo: repo} do
    assert {:error, %Postgrex.Error{}} = construct(repo, fixture!(repo), :incomplete)
  end

  test "unmarked legacy lines can be inserted and updated", %{repo: repo} do
    f = fixture!(repo)

    assert {:ok, _} =
             SQL.query(
               repo,
               "INSERT INTO public.order_line_items (id,order_id,line_no,currency,quantity,unit_price_minor,line_total_minor,sku_snapshot,product_title_snapshot,discount_allocated_minor,net_line_total_minor,inserted_at,updated_at) VALUES ($1,$2,1,'USD',1,100,100,'S','Legacy',0,100,now(),now())",
               [f.line, f.order]
             )

    assert {:ok, %{num_rows: 1}} =
             SQL.query(
               repo,
               "UPDATE public.order_line_items SET sku_snapshot='changed' WHERE id=$1",
               [
                 f.line
               ]
             )

    assert %{rows: [["changed"]]} =
             SQL.query!(repo, "SELECT sku_snapshot FROM public.order_line_items WHERE id=$1", [
               f.line
             ])
  end

  test "a competing connection cannot append to a committed accepted set", %{repo: repo} do
    f = fixture!(repo)
    parent = self()

    first =
      Task.async(fn ->
        repo.checkout(fn ->
          SQL.query!(repo, "BEGIN", [])
          %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
          insert_line!(repo, f)
          insert_set!(repo, f)
          assert {:ok, _} = insert_row(repo, f)
          send(parent, {:constructed, pid})

          receive do
            :accept -> :ok
          after
            10_000 -> raise "timeout"
          end

          SQL.query!(
            repo,
            "UPDATE public.order_line_component_allocation_sets SET accepted_at=now() WHERE id=$1",
            [f.set]
          )

          SQL.query!(repo, "COMMIT", [])
        end)
      end)

    assert_receive {:constructed, pid1}, 10_000

    second =
      Task.async(fn ->
        repo.checkout(fn ->
          %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
          send(parent, {:second_ready, pid})
          insert_row(repo, f)
        end)
      end)

    assert_receive {:second_ready, pid2}, 10_000
    assert pid1 != pid2
    send(first.pid, :accept)
    assert %{command: :commit} = Task.await(first, 10_000)
    assert {:error, %Postgrex.Error{}} = Task.await(second, 10_000)
  end

  @tag :correction
  test "authorized Order lifecycle actions work after allocation acceptance", %{repo: repo} do
    original_repo = Store.Repo.get_dynamic_repo()
    Store.Repo.put_dynamic_repo(repo)

    try do
      for sequence <- [
            [
              begin_provider_setup: :pending_provider_setup,
              refresh_provider_setup: :pending_provider_setup,
              provider_setup_ready: :pending_payment,
              mark_paid: :paid,
              mark_refunded: :refunded
            ],
            [begin_provider_setup: :pending_provider_setup, mark_payment_failed: :payment_failed],
            [begin_provider_setup: :pending_provider_setup, cancel: :cancelled]
          ] do
        f = fixture!(repo)
        assert {:ok, %{command: :commit}} = construct(repo, f, :complete)
        order = Ash.get!(Store.Orders.Order, Ecto.UUID.load!(f.order), authorize?: false)

        Enum.reduce(sequence, order, fn {action, state}, order ->
          updated =
            order
            |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
            |> Ash.update!(domain: Store.Orders, authorize?: true)

          assert updated.state == state
          if action != :refresh_provider_setup, do: assert(updated.version == order.version + 1)

          if state != :pending_provider_setup,
            do: assert(is_nil(updated.provider_setup_started_at))

          updated
        end)
      end
    after
      Store.Repo.put_dynamic_repo(original_repo)
    end
  end

  @tag :correction
  test "accepted Order cannot gain an unmarked line", %{repo: repo} do
    f = fixture!(repo)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert_legacy_line(repo, f)
  end

  @tag :correction
  test "accepted Order cannot gain an adjustment", %{repo: repo} do
    f = fixture!(repo)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             insert_adjustment(repo, f)
  end

  @tag :correction
  test "caller temporary tables cannot hide accepted Order evidence", %{repo: repo} do
    f = fixture!(repo)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    repo.checkout(fn ->
      SQL.query!(repo, "BEGIN", [])

      try do
        hostile_path!(repo)

        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 SQL.query(repo, "UPDATE public.orders SET grand_total_minor=999 WHERE id=$1", [
                   f.order
                 ])
      after
        SQL.query!(repo, "ROLLBACK", [])
      end
    end)
  end

  test "accepted financial and tax fields remain protected", %{repo: repo} do
    f = fixture!(repo)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    for assignment <- [
          "grand_total_minor=grand_total_minor+1",
          "items_subtotal_minor=1",
          "shipping_total_minor=1",
          "tax_total_minor=1",
          "shipping_tax_minor=1",
          "currency_code='EUR'",
          "shipping_country_code='GB'",
          "shipping_region_code='CA'",
          "tax_as_of=tax_as_of+interval '1 day'",
          "totals_finalized_at=NULL",
          "order_ref='changed'"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(repo, "UPDATE public.orders SET #{assignment} WHERE id=$1", [f.order])
    end

    assert {:error, %Postgrex.Error{}} =
             SQL.query(repo, "DELETE FROM public.orders WHERE id=$1", [f.order])
  end

  test "accepted mixed Order freezes earlier legacy lines and adjustments", %{repo: repo} do
    f = fixture!(repo) |> Map.put(:existing_content, true)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)
    other = fixture!(repo)

    for statement <- [
          "UPDATE public.order_line_items SET sku_snapshot='changed' WHERE order_id=$1 AND line_no=2",
          "DELETE FROM public.order_line_items WHERE order_id=$1 AND line_no=2",
          "UPDATE public.order_adjustments SET amount_minor=-2 WHERE order_id=$1",
          "DELETE FROM public.order_adjustments WHERE order_id=$1"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(repo, statement, [f.order])
    end

    for table <- ~w(order_line_items order_adjustments) do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(repo, "UPDATE public.#{table} SET order_id=$2 WHERE order_id=$1", [
                 f.order,
                 other.order
               ])
    end

    assert {:ok, _} = insert_legacy_line(repo, other)
    assert {:ok, _} = insert_adjustment(repo, other)

    for table <- ~w(order_line_items order_adjustments) do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(repo, "UPDATE public.#{table} SET order_id=$2 WHERE order_id=$1", [
                 other.order,
                 f.order
               ])
    end
  end

  test "legacy adjustments remain writable without accepted allocations", %{repo: repo} do
    f = fixture!(repo)
    assert {:ok, _} = insert_adjustment(repo, f)

    assert {:ok, %{num_rows: 1}} =
             SQL.query(
               repo,
               "UPDATE public.order_adjustments SET amount_minor=-2 WHERE order_id=$1",
               [f.order]
             )

    assert {:ok, %{num_rows: 1}} =
             SQL.query(repo, "DELETE FROM public.order_adjustments WHERE order_id=$1", [f.order])
  end

  test "complete evidence validates despite caller schema and temporary shadows", %{repo: repo} do
    f = fixture!(repo) |> Map.put(:hostile, true)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)
    f = fixture!(repo) |> Map.merge(%{hostile: true, empty_tax_context: true})

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             construct(repo, f, :complete)

    assert_received {:commit_attempt, set_id} when set_id == f.set

    assert %{rows: [[false]]} =
             SQL.query!(
               repo,
               "SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname=current_user",
               []
             )
  end

  test "all allocation guard functions pin their search paths without security definer", %{
    repo: repo
  } do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
          SELECT p.proname, p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'], p.prosecdef
          FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname LIKE 'membership_allocation_%'
          ORDER BY p.proname
        """,
        []
      )

    assert length(rows) == 8

    assert %{rows: [[0]]} =
             SQL.query!(
               repo,
               """
               SELECT count(*) FROM pg_catalog.pg_proc p,
                 LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               WHERE p.pronamespace='public'::regnamespace
                 AND (p.proname LIKE 'membership_allocation_%' OR p.proname LIKE 'lock_membership_acceptance_%')
                 AND a.grantee=0 AND a.privilege_type='EXECUTE'
               """,
               []
             )

    for [_name, fixed_path, definer] <- rows do
      assert fixed_path == true
      assert definer == false
    end
  end

  test "late content insertion waits for acceptance and then rejects on another connection", %{
    repo: repo
  } do
    for insert <- [&insert_legacy_line/2, &insert_adjustment/2] do
      f = fixture!(repo)
      parent = self()

      first =
        Task.async(fn ->
          repo.checkout(fn ->
            SQL.query!(repo, "BEGIN", [])

            try do
              insert_line!(repo, f)
              insert_set!(repo, f)
              assert {:ok, _} = insert_row(repo, f)
              send(parent, :content_constructed)

              receive do
                :accept -> :ok
              after
                10_000 -> raise "acceptance timeout"
              end

              SQL.query!(
                repo,
                "UPDATE public.order_line_component_allocation_sets SET accepted_at=now() WHERE id=$1",
                [f.set]
              )

              SQL.query!(repo, "COMMIT", [])
            after
              SQL.query(repo, "ROLLBACK", [])
            end
          end)
        end)

      assert_receive :content_constructed, 10_000

      second =
        Task.async(fn ->
          repo.checkout(fn ->
            %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
            send(parent, {:content_inserter, pid})
            insert.(repo, f)
          end)
        end)

      assert_receive {:content_inserter, pid}, 10_000

      try do
        assert_lock_wait!(repo, pid, System.monotonic_time(:millisecond) + 5000)
      after
        send(first.pid, :accept)
      end

      assert %{command: :commit} = Task.await(first, 10_000)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Task.await(second, 10_000)
    end
  end

  test "blank persisted rate region follows existing Pricing applicability", %{repo: repo} do
    alias Store.Pricing.TaxShippingContract.{Input, Line, TaxRateCandidate}
    f = fixture!(repo)
    SQL.query!(repo, "UPDATE public.tax_rates SET region_code='' WHERE id=$1", [f.rate])

    input = %Input{
      as_of: DateTime.utc_now(),
      currency: "USD",
      destination_country_code: "US",
      subtotal_minor: 100,
      shipping_weight_grams: 0,
      shipping_rates: [],
      shipping_enabled?: false,
      lines: [%Line{line_id: Ecto.UUID.load!(f.line), line_no: 1, net_line_total_minor: 100}],
      tax_rates: [
        %TaxRateCandidate{
          id: Ecto.UUID.load!(f.rate),
          code: "BLANK",
          country_code: "US",
          region_code: "",
          rate_basis_points: 0
        }
      ]
    }

    assert {:error, %{code: "TAX_RATE_NOT_FOUND"}} =
             TaxShippingEvaluator.evaluate(input)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             construct(repo, f, :complete)

    assert_received {:commit_attempt, id} when id == f.set

    assert {:ok, _} =
             TaxShippingEvaluator.evaluate(%{input | destination_region_code: ""})

    SQL.query!(repo, "UPDATE public.orders SET shipping_region_code='' WHERE id=$1", [f.order])
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)
  end

  @tag :foundation_hardening
  test "raw SQL rejects explicit non-v7 allocation identities", %{repo: repo} do
    for field <- [:set, :row_id, :instance, :evaluation] do
      f = fixture!(repo) |> Map.put(field, Ecto.UUID.dump!(Ecto.UUID.generate()))

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               construct(repo, f, :complete)
    end
  end

  @tag :foundation_hardening
  test "every allocation migration refuses rollback before removing accepted protection", %{
    repo: repo
  } do
    f = fixture!(repo)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    migrations = [
      {20_261_117_120_000, Store.Repo.Migrations.Jc274TaxEvidenceIntegrity},
      {20_261_116_204_642, Store.Repo.Migrations.Jc274AllocationConstruction},
      {20_261_116_195_600, Store.Repo.Migrations.Jc274AllocationLockCorrection},
      {20_261_116_195_500, Store.Repo.Migrations.Jc274AllocationTriggerCorrection},
      {20_261_116_195_400, Store.Repo.Migrations.Jc274AllocationIntegrity},
      {20_261_116_195_330, Store.Repo.Migrations.Jc274MembershipLockHelpers},
      {20_261_116_195_306, Store.Repo.Migrations.Jc274SourceFields},
      {20_261_116_195_248, Store.Repo.Migrations.Jc274MembershipAllocations},
      {20_261_116_193_824, Store.Repo.Migrations.Jc274MembershipLineEvidence}
    ]

    before = protection_inventory(repo)

    for {version, module} <- migrations do
      assert_raise Postgrex.Error,
                   ~r/cannot remove allocation protection with accepted evidence/,
                   fn ->
                     Ecto.Migrator.down(repo, version, module, log: false)
                   end

      assert protection_inventory(repo) == before
    end
  end

  @tag :foundation_hardening
  test "allocation read policies isolate customers and admit approved support and system", %{
    repo: repo
  } do
    original = Store.Repo.put_dynamic_repo(repo)

    try do
      actors =
        for role <- [:owner, :other, :admin, :support, :super_admin], into: %{} do
          id = UUIDv7.generate()

          SQL.query!(repo, "INSERT INTO public.users(id,email) VALUES($1,$2)", [
            Ecto.UUID.dump!(id),
            "#{id}@example.com"
          ])

          if role in [:admin, :support, :super_admin] do
            SQL.query!(
              repo,
              "INSERT INTO public.role_assignments(id,user_id,role,inserted_at,updated_at) VALUES($1,$2,$3,now(),now())",
              [Ecto.UUID.dump!(UUIDv7.generate()), Ecto.UUID.dump!(id), to_string(role)]
            )
          end

          {role, %{id: id}}
        end

      f = fixture!(repo)

      SQL.query!(repo, "UPDATE public.orders SET user_id=$2 WHERE id=$1", [
        f.order,
        Ecto.UUID.dump!(actors.owner.id)
      ])

      assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

      %{rows: [[row_id]]} =
        SQL.query!(
          repo,
          "SELECT id FROM public.order_line_component_allocations WHERE allocation_set_id=$1",
          [f.set]
        )

      guest = fixture!(repo)
      assert {:ok, %{command: :commit}} = construct(repo, guest, :complete)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.get(OrderLineComponentAllocationSet, Ecto.UUID.load!(guest.set),
                 actor: nil,
                 authorize?: true,
                 not_found_error?: false
               )

      %{rows: [[guest_row]]} =
        SQL.query!(
          repo,
          "SELECT id FROM public.order_line_component_allocations WHERE allocation_set_id=$1",
          [guest.set]
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.get(OrderLineComponentAllocation, Ecto.UUID.load!(guest_row),
                 actor: nil,
                 authorize?: true,
                 not_found_error?: false
               )

      for {resource, id} <- [
            {OrderLineComponentAllocationSet, Ecto.UUID.load!(f.set)},
            {OrderLineComponentAllocation, Ecto.UUID.load!(row_id)}
          ] do
        assert Enum.map(Info.actions(resource), & &1.type) == [:read]

        for role <- [:owner, :admin, :support, :super_admin] do
          assert {:ok, %{id: ^id}} = Ash.get(resource, id, actor: actors[role], authorize?: true)
        end

        for actor <- [actors.other, nil] do
          case Ash.get(resource, id, actor: actor, authorize?: true, not_found_error?: false) do
            {:ok, nil} -> :ok
            {:error, %Ash.Error.Forbidden{}} -> :ok
            result -> flunk("unauthorized allocation read: #{inspect(result)}")
          end
        end

        assert {:ok, %{id: ^id}} =
                 Ash.get(resource, id, context: %{system?: true}, authorize?: true)
      end
    after
      Store.Repo.put_dynamic_repo(original)
    end
  end

  @tag :foundation_hardening
  test "accepted legacy conflict replays remain no-op without admitting late content", %{
    repo: repo
  } do
    f = fixture!(repo) |> Map.put(:existing_content, true)
    assert {:ok, %{command: :commit}} = construct(repo, f, :complete)

    for table <- ~w(order_line_items order_adjustments) do
      assert {:ok, %{num_rows: 0}} =
               SQL.query(
                 repo,
                 """
                 INSERT INTO public.#{table}
                 SELECT (jsonb_populate_record(NULL::public.#{table}, to_jsonb(t) ||
                   jsonb_build_object('id', public.uuid_generate_v7()))).*
                 FROM public.#{table} t WHERE order_id=$1
                 ON CONFLICT DO NOTHING
                 """,
                 [f.order]
               )
    end

    for {table, keys, assignment} <- [
          {"order_line_items", "order_id,line_no", "tax_minor=999"},
          {"order_adjustments", "order_id,sequence_no", "amount_minor=-999"}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(
                 repo,
                 """
                 INSERT INTO public.#{table}
                 SELECT (jsonb_populate_record(NULL::public.#{table}, to_jsonb(t) ||
                   jsonb_build_object('id', public.uuid_generate_v7()))).*
                 FROM public.#{table} t WHERE order_id=$1
                 ON CONFLICT (#{keys}) DO UPDATE SET #{assignment}
                 """,
                 [f.order]
               )
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               repo,
               "INSERT INTO public.order_line_items(id,order_id,line_no,currency,quantity,unit_price_minor,line_total_minor,inserted_at,updated_at) VALUES($1,$2,99,\'USD\',1,100,100,now(),now())",
               [Ecto.UUID.dump!(UUIDv7.generate()), f.order]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               repo,
               "INSERT INTO public.order_adjustments(id,order_id,sequence_no,currency,kind,amount_minor,inserted_at,updated_at) VALUES($1,$2,99,\'USD\',\'discount\',-1,now(),now())",
               [Ecto.UUID.dump!(UUIDv7.generate()), f.order]
             )
  end

  defp protection_inventory(repo) do
    SQL.query!(
      repo,
      """
      SELECT tgname, pg_get_triggerdef(oid) FROM pg_catalog.pg_trigger
      WHERE tgrelid IN ('public.orders'::regclass, 'public.order_line_items'::regclass,
        'public.order_adjustments'::regclass, 'public.order_line_component_allocation_sets'::regclass,
        'public.order_line_component_allocations'::regclass) ORDER BY tgname
      """,
      []
    ).rows
  end

  defp assert_lock_wait!(repo, pid, deadline) do
    %{rows: [[waiting]]} = SQL.query!(repo, "SELECT cardinality(pg_blocking_pids($1)) > 0", [pid])

    cond do
      waiting ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no observable Order lock wait")

      true ->
        Process.sleep(10)
        assert_lock_wait!(repo, pid, deadline)
    end
  end

  defp insert_legacy_line(repo, f) do
    SQL.query(
      repo,
      "INSERT INTO public.order_line_items (id,order_id,line_no,currency,quantity,unit_price_minor,line_total_minor,sku_snapshot,product_title_snapshot,discount_allocated_minor,net_line_total_minor,inserted_at,updated_at) VALUES ($1,$2,2,'USD',1,100,100,'L','Legacy',0,100,now(),now())",
      [Ecto.UUID.dump!(UUIDv7.generate()), f.order]
    )
  end

  defp insert_adjustment(repo, f) do
    SQL.query(
      repo,
      "INSERT INTO public.order_adjustments (id,order_id,sequence_no,currency,kind,amount_minor,inserted_at,updated_at) VALUES ($1,$2,1,'USD','discount',-1,now(),now())",
      [Ecto.UUID.dump!(UUIDv7.generate()), f.order]
    )
  end

  defp hostile_path!(repo) do
    for table <-
          ~w(orders order_line_items order_adjustments order_line_component_allocation_sets order_line_component_allocations membership_offer_revisions membership_offer_revision_components tax_rates) do
      SQL.query!(
        repo,
        "CREATE TEMP TABLE #{table} ON COMMIT DROP AS SELECT * FROM public.#{table} WITH NO DATA",
        []
      )
    end

    SQL.query!(repo, "CREATE SCHEMA IF NOT EXISTS membership_untrusted", [])

    SQL.query!(
      repo,
      "CREATE OR REPLACE FUNCTION membership_untrusted.membership_allocation_validate_order(uuid) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'untrusted validator invoked'; END $$",
      []
    )

    SQL.query!(
      repo,
      "SET LOCAL search_path = membership_untrusted, pg_temp, public, pg_catalog",
      []
    )
  end

  defp fixture!(repo, bps \\ 0) do
    ids = for _ <- 1..8, do: Ecto.UUID.dump!(UUIDv7.generate())
    [order, revision, component, definition, line, set, occurrence, rate] = ids

    SQL.query!(
      repo,
      "INSERT INTO public.orders (id,order_ref,currency_code,totals_finalized_at,shipping_country_code,tax_as_of) VALUES ($1,$2,'USD',now(),'US',now())",
      [order, "ORD#{UUIDv7.generate()}"]
    )

    SQL.query!(
      repo,
      "INSERT INTO public.tax_rates (id,code,country_code,product_tax_category,rate_basis_points,active,shipping_taxable,precedence_rank,inserted_at,updated_at) VALUES ($1,$2,'US','STANDARD',$3,true,true,100,now(),now())",
      [rate, "RATE#{UUIDv7.generate()}", bps]
    )

    SQL.query!(
      repo,
      "INSERT INTO public.membership_offer_revisions (id,offer_key,revision,currency) VALUES ($1,$2,1,'USD')",
      [revision, "offer.#{UUIDv7.generate()}"]
    )

    SQL.query!(
      repo,
      "INSERT INTO public.membership_offer_revision_components (id,revision_id,definition_key,gross_minor,discount_eligibility_key,tax_treatment_key) VALUES ($1,$2,$3,100,'member','STANDARD')",
      [component, revision, definition]
    )

    SQL.query!(
      repo,
      "UPDATE public.membership_offer_revisions SET status='accepted', accepted_at=now(), fingerprint=membership_offer_revision_manifest_fingerprint(id) WHERE id=$1",
      [revision]
    )

    %{
      order: order,
      revision: revision,
      component: component,
      line: line,
      set: set,
      occurrence: occurrence,
      rate: rate,
      bps: bps,
      tax: div(100 * bps + 5000, 10_000)
    }
  end

  defp construct(repo, f, mode) do
    repo.checkout(fn ->
      SQL.query!(repo, "BEGIN", [])

      try do
        if Map.get(f, :hostile), do: hostile_path!(repo)

        construct_content(repo, f, mode)

        if mutation = Map.get(f, :source_mutation), do: SQL.query!(repo, mutation, [f.rate])
        send(self(), {:commit_attempt, f.set})
        SQL.query(repo, "COMMIT", [])
      rescue
        e in Postgrex.Error ->
          SQL.query(repo, "ROLLBACK", [])
          {:error, e}
      end
    end)
  end

  defp construct_content(repo, f, mode) do
    if Map.get(f, :existing_content) do
      assert {:ok, _} = insert_legacy_line(repo, f)
      assert {:ok, _} = insert_adjustment(repo, f)
    end

    insert_line!(repo, f)
    if mode != :missing_set, do: insert_set!(repo, f)
    construct_children(repo, f, mode)
    accept_constructed_set(repo, f, mode)
  end

  defp construct_children(repo, f, mode) when mode in [:complete, :savepoint, :unaccepted] do
    if mode == :savepoint, do: SQL.query!(repo, "SAVEPOINT child_write", [])

    case insert_row(repo, f) do
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end

    if mode == :savepoint, do: SQL.query!(repo, "RELEASE SAVEPOINT child_write", [])
  end

  defp construct_children(_repo, _f, _mode), do: :ok

  defp accept_constructed_set(repo, f, mode) when mode in [:complete, :savepoint, :incomplete] do
    SQL.query!(
      repo,
      "UPDATE public.order_line_component_allocation_sets SET accepted_at=now() WHERE id=$1",
      [f.set]
    )
  end

  defp accept_constructed_set(_repo, _f, _mode), do: :ok

  defp insert_line!(repo, f) do
    SQL.query!(
      repo,
      "INSERT INTO public.order_line_items (id,order_id,line_no,currency,quantity,unit_price_minor,line_total_minor,sku_snapshot,product_title_snapshot,discount_allocated_minor,net_line_total_minor,tax_category_snapshot,tax_rate_id_snapshot,tax_rate_code_snapshot,tax_rate_bps_snapshot,tax_minor,membership_offer_revision_id_snapshot,membership_occurrence_key_snapshot,inserted_at,updated_at) VALUES ($1,$2,1,'USD',1,100,100,'S','Membership',0,100,'STANDARD',$3,(SELECT code FROM public.tax_rates WHERE id=$3),$6,$7,$4,$5,now(),now())",
      [f.line, f.order, Map.get(f, :line_rate, f.rate), f.revision, f.occurrence, f.bps, f.tax]
    )
  end

  defp insert_set!(repo, f) do
    %{rows: [[context]]} =
      SQL.query!(
        repo,
        """
        SELECT jsonb_build_object(
          'version','membership-tax-v1','tax_enabled',true,
          'order_id',o.id,'occurrence_key',$2::uuid,'currency','USD',
          'country','US','region',upper(btrim(o.shipping_region_code)),'as_of',o.tax_as_of,
          'lines',jsonb_build_array(jsonb_build_object(
            'line_id',l.id,'category',l.tax_category_snapshot,
            'rate_id',l.tax_rate_id_snapshot,'rate_code',l.tax_rate_code_snapshot,
            'rate_bps',l.tax_rate_bps_snapshot,'tax_minor',l.tax_minor,
            'net_minor',l.net_line_total_minor,
            'source',to_jsonb(r)-'inserted_at'-'updated_at'))
        ) FROM public.orders o JOIN public.order_line_items l ON l.order_id=o.id
          JOIN public.tax_rates r ON r.id=$4 WHERE o.id=$1 AND l.id=$3
        """,
        [f.order, f.occurrence, f.line, f.rate]
      )

    context = if Map.get(f, :empty_tax_context), do: %{}, else: context
    context = Map.get(f, :context_change, &Function.identity/1).(context)

    SQL.query!(
      repo,
      "INSERT INTO public.order_line_component_allocation_sets (id,order_id,offer_revision_id,occurrence_key,target_fingerprint,allocation_fingerprint,pricing_fingerprint,allocation_rule_version,currency,tax_context,accepted_at) VALUES ($1,$2,$3,$4,'target','allocation','pricing','v1','USD',$5,NULL)",
      [f.set, f.order, f.revision, f.occurrence, context]
    )
  end

  defp insert_row(repo, f) do
    SQL.query(
      repo,
      "INSERT INTO public.order_line_component_allocations (id,allocation_set_id,order_line_item_id,offer_component_id,component_instance_id,evaluation_line_id,gross_minor,discount_minor,net_minor,tax_minor) VALUES ($1,$2,$3,$4,$5,$6,100,0,100,$7)",
      [
        Map.get_lazy(f, :row_id, fn -> Ecto.UUID.dump!(UUIDv7.generate()) end),
        f.set,
        f.line,
        f.component,
        Map.get_lazy(f, :instance, fn -> Ecto.UUID.dump!(UUIDv7.generate()) end),
        Map.get_lazy(f, :evaluation, fn -> Ecto.UUID.dump!(UUIDv7.generate()) end),
        f.tax
      ]
    )
  end
end
