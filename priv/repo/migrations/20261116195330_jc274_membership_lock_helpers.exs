defmodule Store.Repo.Migrations.Jc274MembershipLockHelpers do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION public.lock_membership_acceptance_sources(p_order_id uuid, p_offer_revision_id uuid)
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    BEGIN
      IF p_order_id IS NULL OR p_offer_revision_id IS NULL THEN
        RAISE EXCEPTION 'exact order and offer required for acceptance locks' USING ERRCODE = 'check_violation';
      END IF;
      PERFORM set_config('lock_timeout', '1s', true);
      PERFORM set_config('statement_timeout', '5s', true);
      PERFORM set_config('idle_in_transaction_session_timeout', '5s', true);
      PERFORM set_config('transaction_timeout', '10s', true);
      LOCK TABLE public.tax_rates IN SHARE MODE;
      LOCK TABLE public.promotions IN SHARE MODE;
      LOCK TABLE public.coupons IN SHARE MODE;
      PERFORM 1 FROM public.membership_offer_revisions
        WHERE id = p_offer_revision_id AND status = 'accepted' FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'accepted offer missing for acceptance locks' USING ERRCODE = 'check_violation';
      END IF;
      PERFORM 1 FROM public.orders WHERE id = p_order_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'order missing for acceptance locks' USING ERRCODE = 'check_violation';
      END IF;
      PERFORM 1 FROM public.order_line_items WHERE order_id = p_order_id AND membership_offer_revision_id_snapshot = p_offer_revision_id ORDER BY id FOR UPDATE;
    END $$
    """

    execute "REVOKE ALL ON FUNCTION public.lock_membership_acceptance_sources(uuid, uuid) FROM PUBLIC"

    # This invoker router preserves ordinary legacy writes under their existing
    # column UPDATE grants. The restricted writer must use the definer helper.
    execute """
    CREATE FUNCTION public.membership_allocation_lock_orders(p_orders uuid[], p_revision uuid DEFAULT NULL)
    RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
    DECLARE oid uuid; revision uuid; n integer;
    BEGIN
      IF p_revision IS NULL AND has_any_column_privilege(current_user, 'public.orders', 'UPDATE') THEN
        PERFORM 1 FROM public.orders WHERE id = ANY(p_orders) ORDER BY id FOR UPDATE;
        RETURN;
      END IF;
      SELECT count(DISTINCT id), (array_agg(DISTINCT id ORDER BY id))[1] INTO n, oid FROM unnest(p_orders) id;
      IF n <> 1 THEN
        RAISE EXCEPTION 'acceptance locks require exactly one order' USING ERRCODE = 'check_violation';
      END IF;
      revision := p_revision;
      IF revision IS NULL THEN
        SELECT count(DISTINCT id), (array_agg(DISTINCT id ORDER BY id))[1] INTO n, revision FROM (
          SELECT offer_revision_id AS id FROM public.order_line_component_allocation_sets WHERE order_id = oid
          UNION
          SELECT membership_offer_revision_id_snapshot AS id FROM public.order_line_items
            WHERE order_id = oid AND membership_offer_revision_id_snapshot IS NOT NULL
        ) evidence;
        IF n <> 1 THEN
          RAISE EXCEPTION 'exact offer required for acceptance locks' USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      PERFORM public.lock_membership_acceptance_sources(oid, revision);
    END $$
    """

    execute "REVOKE ALL ON FUNCTION public.membership_allocation_lock_orders(uuid[], uuid) FROM PUBLIC"
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets LIMIT 1) THEN
        RAISE EXCEPTION 'cannot remove acceptance lock protection with existing evidence';
      END IF;
    END $$
    """

    execute "DROP FUNCTION public.membership_allocation_lock_orders(uuid[], uuid)"
    execute "DROP FUNCTION public.lock_membership_acceptance_sources(uuid, uuid)"
  end
end
