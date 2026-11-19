defmodule Store.Repo.Migrations.Jc274AllocationIntegrity do
  @moduledoc """
  Adds deferred, occurrence-level reconciliation and immutable evidence guards.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION public.membership_allocation_lock_order() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    DECLARE oid uuid; revision uuid;
    BEGIN
      IF TG_TABLE_NAME IN ('order_line_items', 'order_adjustments') THEN
        oid := NEW.order_id;
        IF TG_TABLE_NAME = 'order_line_items' THEN
          IF TG_OP = 'UPDATE' THEN
            IF OLD.membership_occurrence_key_snapshot IS NOT NULL OR NEW.membership_occurrence_key_snapshot IS NOT NULL THEN
              RAISE EXCEPTION 'membership line snapshots cannot be updated' USING ERRCODE = 'check_violation';
            END IF;
          END IF;
        END IF;
      ELSIF TG_TABLE_NAME = 'order_line_component_allocation_sets' THEN
        oid := NEW.order_id;
        IF NEW.accepted_at IS NOT NULL THEN
          RAISE EXCEPTION 'allocation must be constructed before acceptance' USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        SELECT order_id, offer_revision_id INTO oid, revision FROM public.order_line_component_allocation_sets WHERE id = NEW.allocation_set_id;
        IF oid IS NULL THEN RAISE EXCEPTION 'allocation set missing' USING ERRCODE = 'foreign_key_violation'; END IF;
      END IF;
      IF TG_TABLE_NAME = 'order_line_items' THEN
        revision := NEW.membership_offer_revision_id_snapshot;
      ELSIF TG_TABLE_NAME = 'order_line_component_allocation_sets' THEN
        revision := NEW.offer_revision_id;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        PERFORM public.membership_allocation_lock_orders(ARRAY[OLD.order_id, oid], revision);
      ELSE
        PERFORM public.membership_allocation_lock_orders(ARRAY[oid], revision);
      END IF;
      IF TG_TABLE_NAME IN ('order_line_items', 'order_adjustments') THEN
        -- BEFORE INSERT also runs for ON CONFLICT DO NOTHING. Existing unique
        -- keys cannot append a row; an ON CONFLICT UPDATE still encounters the
        -- immutable UPDATE guard. Preserve the legacy create-only replay path.
        IF TG_OP = 'INSERT' THEN
          IF TG_TABLE_NAME = 'order_line_items' THEN
            IF NEW.membership_occurrence_key_snapshot IS NULL AND NEW.membership_offer_revision_id_snapshot IS NULL AND
               EXISTS (SELECT 1 FROM public.order_line_items WHERE order_id = oid AND line_no = NEW.line_no) THEN RETURN NEW; END IF;
          ELSE
            IF EXISTS (SELECT 1 FROM public.order_adjustments WHERE order_id = oid AND
              (sequence_no = NEW.sequence_no OR (kind = 'shipping' AND NEW.kind = 'shipping'))) THEN RETURN NEW; END IF;
          END IF;
        END IF;
        IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets WHERE order_id = oid AND accepted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'accepted order cannot gain or change content' USING ERRCODE = 'check_violation';
        END IF;
        IF TG_TABLE_NAME = 'order_line_items' THEN
          IF NEW.membership_occurrence_key_snapshot IS NOT NULL THEN
            IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets WHERE order_id = oid AND occurrence_key = NEW.membership_occurrence_key_snapshot) THEN
              RAISE EXCEPTION 'accepted occurrence cannot gain lines' USING ERRCODE = 'check_violation';
            END IF;
          END IF;
        END IF;
      ELSIF TG_TABLE_NAME = 'order_line_component_allocations' THEN
        IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets WHERE id = NEW.allocation_set_id AND accepted_at IS NOT NULL FOR UPDATE) THEN
          RAISE EXCEPTION 'accepted occurrence cannot gain allocations' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      RETURN NEW;
    END $$
    """

    execute """
    CREATE FUNCTION public.membership_allocation_deferred_check() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    DECLARE oid uuid;
    BEGIN
      IF TG_TABLE_NAME = 'order_line_items' OR TG_TABLE_NAME = 'order_line_component_allocation_sets' THEN
        oid := CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END;
      ELSE
        SELECT order_id INTO oid FROM public.order_line_component_allocation_sets WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.allocation_set_id ELSE NEW.allocation_set_id END;
      END IF;
      IF oid IS NOT NULL THEN PERFORM public.membership_allocation_validate_order(oid); END IF;
      RETURN NULL;
    END $$
    """

    execute """
    CREATE OR REPLACE FUNCTION public.membership_allocation_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    DECLARE destination_order uuid; revision uuid;
    BEGIN
      IF TG_TABLE_NAME = 'order_line_component_allocation_sets' THEN
        PERFORM public.membership_allocation_lock_orders(ARRAY[OLD.order_id], OLD.offer_revision_id);
        IF TG_OP = 'UPDATE' AND OLD.accepted_at IS NULL AND NEW.accepted_at IS NOT NULL AND
           (to_jsonb(NEW) - 'accepted_at') = (to_jsonb(OLD) - 'accepted_at') THEN RETURN NEW; END IF;
        RAISE EXCEPTION 'allocation set is immutable' USING ERRCODE = 'check_violation';
      ELSIF TG_TABLE_NAME = 'order_line_component_allocations' THEN
        RAISE EXCEPTION 'allocation row is immutable' USING ERRCODE = 'check_violation';
      ELSIF TG_TABLE_NAME = 'orders' THEN
        IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets WHERE order_id = OLD.id) THEN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'accepted order cannot be deleted' USING ERRCODE = 'check_violation';
          END IF;
          IF (to_jsonb(NEW) - ARRAY['state','version','provider_setup_started_at','updated_at']) IS DISTINCT FROM
             (to_jsonb(OLD) - ARRAY['state','version','provider_setup_started_at','updated_at']) THEN
            RAISE EXCEPTION 'accepted order financial and snapshot evidence is immutable' USING ERRCODE = 'check_violation';
          END IF;
        END IF;
      ELSE
        destination_order := OLD.order_id;
        IF TG_OP = 'UPDATE' THEN destination_order := NEW.order_id; END IF;
        IF TG_TABLE_NAME = 'order_line_items' THEN
          revision := OLD.membership_offer_revision_id_snapshot;
        END IF;
        PERFORM public.membership_allocation_lock_orders(ARRAY[OLD.order_id, destination_order], revision);
        IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets WHERE order_id IN (OLD.order_id, destination_order)) THEN
          RAISE EXCEPTION 'accepted order content is immutable' USING ERRCODE = 'check_violation';
        END IF;
        IF TG_TABLE_NAME = 'order_line_items' THEN
          IF OLD.membership_occurrence_key_snapshot IS NOT NULL THEN
            RAISE EXCEPTION 'membership line is immutable' USING ERRCODE = 'check_violation';
          END IF;
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN RETURN NEW; END IF;
      RETURN OLD;
    END $$
    """

    execute """
    CREATE FUNCTION public.membership_allocation_after_accept() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    BEGIN
      PERFORM public.membership_allocation_validate_order(NEW.order_id);
      RETURN NULL;
    END $$
    """

    execute "CREATE TRIGGER membership_allocation_validate_accept AFTER UPDATE ON public.order_line_component_allocation_sets FOR EACH ROW EXECUTE FUNCTION public.membership_allocation_after_accept()"

    execute """
    CREATE FUNCTION public.membership_allocation_no_truncate() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets LIMIT 1) THEN
        RAISE EXCEPTION 'accepted allocation evidence cannot be truncated' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NULL;
    END $$
    """

    for table <- [
          "order_line_items",
          "order_line_component_allocation_sets",
          "order_line_component_allocations"
        ] do
      execute "CREATE TRIGGER #{table}_membership_lock BEFORE INSERT ON public.#{table} FOR EACH ROW EXECUTE FUNCTION public.membership_allocation_lock_order()"

      execute "CREATE CONSTRAINT TRIGGER #{table}_membership_complete AFTER INSERT OR UPDATE OR DELETE ON public.#{table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.membership_allocation_deferred_check()"
    end

    execute "CREATE TRIGGER order_adjustments_membership_insert_lock BEFORE INSERT ON public.order_adjustments FOR EACH ROW EXECUTE FUNCTION public.membership_allocation_lock_order()"

    execute "CREATE TRIGGER membership_line_update_lock BEFORE UPDATE ON public.order_line_items FOR EACH ROW EXECUTE FUNCTION public.membership_allocation_lock_order()"

    for table <- [
          "order_line_items",
          "order_line_component_allocation_sets",
          "order_line_component_allocations",
          "orders",
          "order_adjustments"
        ] do
      execute "CREATE TRIGGER #{table}_membership_immutable BEFORE UPDATE OR DELETE ON public.#{table} FOR EACH ROW EXECUTE FUNCTION public.membership_allocation_immutable()"

      execute "CREATE TRIGGER #{table}_membership_truncate BEFORE TRUNCATE ON public.#{table} FOR EACH STATEMENT EXECUTE FUNCTION public.membership_allocation_no_truncate()"
    end

    for signature <- [
          "membership_allocation_lock_order()",
          "membership_allocation_validate_order(uuid)",
          "membership_allocation_deferred_check()",
          "membership_allocation_immutable()",
          "membership_allocation_after_accept()",
          "membership_allocation_no_truncate()"
        ] do
      execute "REVOKE ALL ON FUNCTION public.#{signature} FROM PUBLIC"
    end
  end

  def down do
    execute """
    DO $$ BEGIN
      IF to_regclass('public.order_line_component_allocation_sets') IS NOT NULL THEN
        LOCK TABLE public.order_line_component_allocation_sets IN ACCESS EXCLUSIVE MODE;
        IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets WHERE accepted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'cannot remove allocation protection with accepted evidence';
        END IF;
      END IF;
    END $$
    """

    for table <- [
          "order_line_items",
          "order_line_component_allocation_sets",
          "order_line_component_allocations",
          "orders",
          "order_adjustments"
        ] do
      execute "DROP TRIGGER IF EXISTS #{table}_membership_truncate ON public.#{table}"
      execute "DROP TRIGGER IF EXISTS #{table}_membership_immutable ON public.#{table}"
    end

    execute "DROP TRIGGER IF EXISTS order_adjustments_membership_insert_lock ON public.order_adjustments"

    execute "DROP TRIGGER IF EXISTS membership_line_update_lock ON public.order_line_items"

    for table <- [
          "order_line_items",
          "order_line_component_allocation_sets",
          "order_line_component_allocations"
        ] do
      execute "DROP TRIGGER IF EXISTS #{table}_membership_complete ON public.#{table}"
      execute "DROP TRIGGER IF EXISTS #{table}_membership_lock ON public.#{table}"
    end

    execute "DROP TRIGGER IF EXISTS membership_allocation_validate_accept ON public.order_line_component_allocation_sets"

    execute "DROP FUNCTION public.membership_allocation_after_accept()"
    execute "DROP FUNCTION public.membership_allocation_no_truncate()"
    execute "DROP FUNCTION public.membership_allocation_immutable()"
    execute "DROP FUNCTION public.membership_allocation_deferred_check()"
    execute "DROP FUNCTION public.membership_allocation_lock_order()"
  end
end
