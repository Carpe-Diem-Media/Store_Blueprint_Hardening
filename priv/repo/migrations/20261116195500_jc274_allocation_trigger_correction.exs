defmodule Store.Repo.Migrations.Jc274AllocationTriggerCorrection do
  @moduledoc false
  use Ecto.Migration

  def up do
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
