defmodule Store.Repo.Migrations.Jc379ShippingConfigRevision do
  @moduledoc """
  Adds transaction-coupled durable Shipping configuration revisions.

  This migration is intentionally forward-only. Removing its triggers would
  make the revision-fenced cache unsafe while the new application is running.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE shipping_config_revisions (
      singleton_id smallint PRIMARY KEY,
      revision bigint NOT NULL,
      CONSTRAINT shipping_config_revisions_singleton_id_check CHECK (singleton_id = 1),
      CONSTRAINT shipping_config_revisions_positive_check CHECK (revision > 0)
    )
    """)

    execute("INSERT INTO shipping_config_revisions (singleton_id, revision) VALUES (1, 1)")

    execute("""
    CREATE FUNCTION shipping_advance_config_revision()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $$
    DECLARE
      updated_rows integer;
    BEGIN
      UPDATE public.shipping_config_revisions
         SET revision = revision + 1
       WHERE singleton_id = 1;

      GET DIAGNOSTICS updated_rows = ROW_COUNT;

      IF updated_rows <> 1 THEN
        RAISE EXCEPTION 'Shipping configuration revision singleton is missing'
          USING ERRCODE = '55000';
      END IF;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION shipping_guard_config_revision()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'Shipping configuration revision singleton cannot be recreated'
          USING ERRCODE = '55000';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Shipping configuration revision singleton cannot be removed'
          USING ERRCODE = '55000';
      END IF;

      IF NEW.singleton_id <> OLD.singleton_id OR NEW.revision <= OLD.revision THEN
        RAISE EXCEPTION 'Shipping configuration revision must advance monotonically'
          USING ERRCODE = '55000';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION shipping_guard_config_revision_truncate()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $$
    BEGIN
      RAISE EXCEPTION 'Shipping configuration revision singleton cannot be truncated'
        USING ERRCODE = '55000';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER shipping_config_revisions_guard_row
    BEFORE INSERT OR UPDATE OR DELETE ON shipping_config_revisions
    FOR EACH ROW EXECUTE FUNCTION shipping_guard_config_revision()
    """)

    execute("""
    CREATE TRIGGER shipping_config_revisions_guard_truncate
    BEFORE TRUNCATE ON shipping_config_revisions
    FOR EACH STATEMENT EXECUTE FUNCTION shipping_guard_config_revision_truncate()
    """)

    for table <- ~w(shipping_zones shipping_methods shipping_rates) do
      execute("""
      CREATE TRIGGER #{table}_revision_dml
      BEFORE INSERT OR UPDATE OR DELETE ON #{table}
      FOR EACH STATEMENT EXECUTE FUNCTION shipping_advance_config_revision()
      """)

      execute("""
      CREATE TRIGGER #{table}_revision_truncate
      BEFORE TRUNCATE ON #{table}
      FOR EACH STATEMENT EXECUTE FUNCTION shipping_advance_config_revision()
      """)
    end
  end

  def down do
    raise "JC-379 Shipping revision migration is forward-only; downgrade would remove cache-coherence authority"
  end
end
