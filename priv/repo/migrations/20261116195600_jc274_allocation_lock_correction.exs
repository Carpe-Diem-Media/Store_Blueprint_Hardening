defmodule Store.Repo.Migrations.Jc274AllocationLockCorrection do
  @moduledoc false
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
        SELECT order_id INTO oid FROM public.order_line_component_allocation_sets WHERE id = NEW.allocation_set_id;
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
    CREATE OR REPLACE FUNCTION public.membership_allocation_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    DECLARE destination_order uuid;
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
        PERFORM public.membership_allocation_lock_orders(ARRAY[OLD.order_id, destination_order]);
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
  end

  def down, do: :ok
end
