# Runs in a fresh BEAM with the existing disposable runtime login only.
# This is database/legacy API compatibility, not OS credential isolation.
defmodule Store.CI.ModelBRuntimeCompatibility do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias Store.Orders.{Order, OrderAdjustment, SnapshotWriter, TaxShippingSnapshotWriter}
  alias Store.Pricing.{Contract, TaxShippingContract}

  def run do
    unless System.get_env("GITHUB_ACTIONS") == "true" and
             System.get_env("MODEL_B_CI_DISPOSABLE") == "true" and
             System.get_env("PGUSER") == "model_b_runtime" and
             System.get_env("PGDATABASE") == "model_b_role_proof" do
      raise "disposable restricted runtime target required"
    end

    {:ok, _} = Application.ensure_all_started(:ash_postgres)
    Logger.configure(level: :warning)

    config = [
      username: System.fetch_env!("PGUSER"),
      password: System.fetch_env!("PGPASSWORD"),
      hostname: "127.0.0.1",
      port: System.fetch_env!("PGPORT") |> String.to_integer(),
      database: "model_b_role_proof",
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      parameters: [application_name: "jc382_runtime_compatibility"],
      show_sensitive_data_on_connection_error: false
    ]

    repos = [Store.Repo, Store.DirectRepo]

    pids =
      for repo <- repos do
        repo_config =
          if repo == Store.DirectRepo,
            do:
              Keyword.merge(config,
                username: System.fetch_env!("MODEL_B_DIRECT_RUNTIME_USER"),
                password: System.fetch_env!("MODEL_B_DIRECT_RUNTIME_PASSWORD")
              ),
            else: config

        Application.put_env(:store, repo, repo_config)
        {:ok, pid} = repo.start_link()
        pid
      end

    try do
      fixtures = Jason.decode!(System.fetch_env!("MODEL_B_ACCEPTED_FIXTURES"))

      for {repo, index} <- Enum.with_index(repos) do
        original = Store.Repo.put_dynamic_repo(repo)
        assert Store.Repo.get_dynamic_repo() == repo

        try do
          role =
            if repo == Store.DirectRepo,
              do: System.fetch_env!("MODEL_B_DIRECT_RUNTIME_USER"),
              else: "model_b_runtime"

          assert %{rows: [[^role, ^role]]} =
                   query!("SELECT current_user::text, session_user::text", [])

          for repetition <- 1..2 do
            started = System.monotonic_time(:microsecond)
            legacy()
            accepted(Enum.at(fixtures, index * 2 + repetition - 1))

            IO.puts(
              "PASS actual_runtime_repo=#{inspect(repo)} repetition=#{repetition} database_role=#{role} legacy_snapshot_shipping_finalization_lifecycle_replay elapsed_us=#{System.monotonic_time(:microsecond) - started} memory_bytes=#{:erlang.memory(:total)} processes=#{:erlang.system_info(:process_count)}"
            )
          end
        after
          Store.Repo.put_dynamic_repo(original)
        end
      end
    after
      Enum.each(pids, &Supervisor.stop(&1, :normal, 5_000))
    end
  end

  defp output do
    %Contract.Output{
      currency: "USD",
      subtotal_minor: 100,
      discount_total_minor: 1,
      total_minor: 99,
      line_allocations: [],
      lines: [
        %Contract.LineEvaluation{
          line_id: nil,
          line_no: 1,
          sku_snapshot: "CI",
          product_title_snapshot: "Legacy",
          quantity: 1,
          unit_price_minor: 100,
          line_total_minor: 100,
          discount_allocated_minor: 1,
          net_line_total_minor: 99
        }
      ],
      applied_adjustments: [
        %Contract.AppliedAdjustment{
          source_kind: :promotion,
          source_id: Ash.UUIDv7.generate(),
          source_code: "CI",
          discount_minor: 1,
          precedence_rank: 1,
          inserted_at: DateTime.utc_now()
        }
      ]
    }
  end

  defp legacy do
    order =
      Order
      |> Ash.Changeset.for_create(
        :create,
        %{order_ref: "CI#{Ash.UUIDv7.generate()}"},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Orders, authorize?: true)

    assert {:ok, %{idempotent?: false}} = SnapshotWriter.write_priced_snapshot(order.id, output())

    assert {:ok, %{idempotent?: true, line_items: [_], adjustments: [_]}} =
             SnapshotWriter.write_priced_snapshot(order.id, output())

    # Same Ash/Ecto schema, columns and partial conflict target as Checkout's
    # private insert_shipping_adjustment/3. This does not run full Checkout or
    # grant Cart/Inventory/Checkout writes to the proof principal.
    attrs = %{
      order_id: order.id,
      sequence_no: 2,
      currency: "USD",
      kind: "shipping",
      amount_minor: 5,
      reason: "shipping:CI",
      source_kind: "shipping_quote",
      source_code: "CI",
      source_id: nil,
      precedence_rank: 0
    }

    for _ <- 1..2 do
      assert {:ok, _} =
               Store.Repo.insert(Ecto.Changeset.change(%OrderAdjustment{}, attrs),
                 on_conflict: :nothing,
                 conflict_target: {:unsafe_fragment, "(order_id) WHERE kind = 'shipping'"}
               )
    end

    assert %{rows: [[1]]} =
             query!(
               "SELECT count(*) FROM public.order_adjustments WHERE order_id=$1 AND kind='shipping'",
               [Ecto.UUID.dump!(order.id)]
             )

    tax = %TaxShippingContract.Output{
      currency: "USD",
      destination_country_code: "US",
      subtotal_minor: 99,
      shipping_cost_minor_original: 5,
      shipping_cost_minor_effective: 5,
      free_shipping_applied: false,
      shipping_tax_minor: 0,
      tax_total_minor: 0,
      order_total_minor: 104,
      line_taxes: [],
      tax_as_of: DateTime.utc_now()
    }

    assert {:ok, %{idempotent?: false}} =
             TaxShippingSnapshotWriter.write_tax_shipping_snapshot(order.id, tax)

    assert {:ok, %{idempotent?: true}} =
             TaxShippingSnapshotWriter.write_tax_shipping_snapshot(order.id, tax)

    order = Ash.get!(Order, order.id, authorize?: false)

    finalized =
      update(order, :finalize_checkout_totals, %{
        currency_code: "USD",
        items_subtotal_minor: 99,
        shipping_total_minor: 5,
        grand_total_minor: 104
      })

    assert finalized.grand_total_minor == 104

    assert update(finalized, :finalize_checkout_totals, %{
             currency_code: "USD",
             items_subtotal_minor: 99,
             shipping_total_minor: 5,
             grand_total_minor: 104
           }).grand_total_minor == 104

    lifecycle(finalized, [
      :begin_provider_setup,
      :refresh_provider_setup,
      :provider_setup_ready,
      :mark_paid,
      :mark_refunded
    ])
  end

  defp accepted(batch) do
    for {key, sequence} <- [
          {"paid",
           [
             :begin_provider_setup,
             :refresh_provider_setup,
             :provider_setup_ready,
             :mark_paid,
             :mark_refunded
           ]},
          {"failed", [:begin_provider_setup, :mark_payment_failed]},
          {"cancelled", [:begin_provider_setup, :cancel]}
        ] do
      id = batch[key]["order"]

      original =
        query!(
          "SELECT to_jsonb(o)-ARRAY['state','version','provider_setup_started_at','updated_at'] FROM public.orders o WHERE id=$1",
          [Ecto.UUID.dump!(id)]
        ).rows

      assert {:ok, %{idempotent?: true}} = SnapshotWriter.write_priced_snapshot(id, output())
      order = Ash.get!(Order, id, authorize?: false)
      lifecycle(order, sequence)

      assert query!(
               "SELECT to_jsonb(o)-ARRAY['state','version','provider_setup_started_at','updated_at'] FROM public.orders o WHERE id=$1",
               [Ecto.UUID.dump!(id)]
             ).rows == original
    end
  end

  defp lifecycle(order, actions) do
    Enum.reduce(actions, order, fn action, current ->
      updated = update(current, action, %{})
      replay = update(updated, action, %{})
      assert replay.state == updated.state
      assert replay.version == updated.version
      replay
    end)
  end

  defp query!(statement, params) do
    SQL.query!(Store.Repo.get_dynamic_repo(), statement, params)
  end

  defp update(order, action, attrs) do
    order
    |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: true)
  end
end

try do
  Store.CI.ModelBRuntimeCompatibility.run()
rescue
  error ->
    # The trusted parent records only the exception class, never connection data.
    IO.puts(
      :stderr,
      "FAIL restricted_runtime_compatibility exception=#{inspect(error.__struct__)}"
    )

    for {module, function, arity, location} <- __STACKTRACE__ do
      IO.puts(
        :stderr,
        "at #{inspect(module)}.#{function}/#{if is_list(arity), do: length(arity), else: arity} line=#{location[:line]}"
      )
    end

    System.halt(1)
end
