defmodule Store.Repo.Migrations.Jc248AccessRepairDeliveries do
  @moduledoc """
  Adds durable sender-side delivery obligations for APPLIED access repairs.

  Rollback refuses to discard pending generations. Its table lock serializes
  that check with new requests until the transactional drop completes.
  """

  use Ecto.Migration

  def up do
    create table(:access_repair_deliveries, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :recipient_user_ids, {:array, :uuid}, null: false
      add :generation, :bigint, null: false
      add :delivered_generation, :bigint, null: false, default: 0
      add :delivered_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :access_effect_id,
          references(:access_effects,
            column: :id,
            name: "access_repair_deliveries_access_effect_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:access_repair_deliveries, [:access_effect_id],
             name: "access_repair_deliveries_unique_access_effect_index"
           )

    create constraint(:access_repair_deliveries, :access_repair_deliveries_generation_check,
             check: """
               generation >= 1
             """
           )

    create constraint(:access_repair_deliveries, :access_repair_deliveries_generation_order_check,
             check: """
               delivered_generation >= 0 AND delivered_generation <= generation
             """
           )

    create constraint(:access_repair_deliveries, :access_repair_deliveries_delivery_time_check,
             check: """
               (delivered_generation = 0 AND delivered_at IS NULL) OR (delivered_generation > 0 AND delivered_at IS NOT NULL)
             """
           )

    create constraint(:access_repair_deliveries, :access_repair_deliveries_recipient_count_check,
             check: """
               cardinality(recipient_user_ids) > 0
             """
           )

    create index(:access_repair_deliveries, [:inserted_at, :id],
             name: "access_repair_deliveries_pending_index",
             where: "delivered_generation < generation"
           )
  end

  def down do
    execute("LOCK TABLE access_repair_deliveries IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM access_repair_deliveries
        WHERE delivered_generation < generation
      ) THEN
        RAISE EXCEPTION 'cannot roll back pending access repair deliveries';
      END IF;
    END
    $$;
    """)

    drop_if_exists index(:access_repair_deliveries, [:inserted_at, :id],
                     name: "access_repair_deliveries_pending_index"
                   )

    drop_if_exists constraint(
                     :access_repair_deliveries,
                     :access_repair_deliveries_recipient_count_check
                   )

    drop_if_exists constraint(
                     :access_repair_deliveries,
                     :access_repair_deliveries_delivery_time_check
                   )

    drop_if_exists constraint(
                     :access_repair_deliveries,
                     :access_repair_deliveries_generation_order_check
                   )

    drop_if_exists constraint(
                     :access_repair_deliveries,
                     :access_repair_deliveries_generation_check
                   )

    drop constraint(:access_repair_deliveries, "access_repair_deliveries_access_effect_id_fkey")

    drop_if_exists unique_index(:access_repair_deliveries, [:access_effect_id],
                     name: "access_repair_deliveries_unique_access_effect_index"
                   )

    drop table(:access_repair_deliveries)
  end
end
