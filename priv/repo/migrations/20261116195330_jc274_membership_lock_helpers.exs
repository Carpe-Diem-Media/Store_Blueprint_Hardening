defmodule Store.Repo.Migrations.Jc274MembershipLockHelpers do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION public.lock_membership_acceptance_manifest(p_order_id uuid, p_offer_revision_ids uuid[])
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    DECLARE n integer; locked integer;
    BEGIN
      PERFORM set_config('lock_timeout', '1s', true);
      PERFORM set_config('statement_timeout', '5s', true);
      PERFORM set_config('idle_in_transaction_session_timeout', '5s', true);
      PERFORM set_config('transaction_timeout', '10s', true);
      n := cardinality(p_offer_revision_ids);
      IF p_order_id IS NULL OR n IS NULL OR n < 1 OR
         array_position(p_offer_revision_ids, NULL) IS NOT NULL OR
         n <> (SELECT count(DISTINCT id) FROM unnest(p_offer_revision_ids) id) THEN
        RAISE EXCEPTION 'exact bounded order and offers required for acceptance locks' USING ERRCODE = 'check_violation';
      END IF;
      LOCK TABLE public.tax_rates IN SHARE MODE;
      LOCK TABLE public.promotions IN SHARE MODE;
      LOCK TABLE public.coupons IN SHARE MODE;
      PERFORM 1 FROM public.membership_offer_revisions
        WHERE id = ANY(p_offer_revision_ids) AND status = 'accepted' ORDER BY id FOR UPDATE;
      GET DIAGNOSTICS locked = ROW_COUNT;
      IF locked <> n THEN
        RAISE EXCEPTION 'accepted offer missing for acceptance locks' USING ERRCODE = 'check_violation';
      END IF;
      PERFORM 1 FROM public.orders WHERE id = p_order_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'order missing for acceptance locks' USING ERRCODE = 'check_violation';
      END IF;
      PERFORM 1 FROM public.order_line_items WHERE order_id = p_order_id AND membership_offer_revision_id_snapshot = ANY(p_offer_revision_ids) ORDER BY id FOR UPDATE;
    END $$
    """

    execute "REVOKE ALL ON FUNCTION public.lock_membership_acceptance_manifest(uuid, uuid[]) FROM PUBLIC"

    # A transaction accepting multiple occurrences prelocks its complete bounded
    # revision manifest through the manifest helper before constructing any line.
    # Later exact-revision trigger calls reacquire locks already held by that tx.
    execute """
    CREATE FUNCTION public.lock_membership_acceptance_sources(p_order_id uuid, p_offer_revision_id uuid)
    RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    BEGIN
      PERFORM public.lock_membership_acceptance_manifest(p_order_id, ARRAY[p_offer_revision_id]);
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
        -- Only unscoped legacy/adjustment routing reaches this branch. An
        -- adjustment has no occurrence FK, so multiple possible revisions must
        -- reject; component children always supply their set's exact revision.
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

    execute """
    CREATE FUNCTION public.membership_allocation_validate_order(p_order_id uuid) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    DECLARE s record; n integer;
    BEGIN
      IF EXISTS (
        SELECT 1 FROM public.order_line_items l
        LEFT JOIN public.order_line_component_allocation_sets a ON a.order_id = l.order_id AND a.occurrence_key = l.membership_occurrence_key_snapshot
        WHERE l.order_id = p_order_id AND l.membership_occurrence_key_snapshot IS NOT NULL AND a.id IS NULL
      ) THEN RAISE EXCEPTION 'marked line has no accepted allocation' USING ERRCODE = 'check_violation'; END IF;
      FOR s IN SELECT * FROM public.order_line_component_allocation_sets WHERE order_id = p_order_id LOOP
        IF s.accepted_at IS NULL THEN RAISE EXCEPTION 'allocation set not accepted' USING ERRCODE = 'check_violation'; END IF;
        IF NOT EXISTS (SELECT 1 FROM public.membership_offer_revisions r WHERE r.id = s.offer_revision_id AND r.status = 'accepted' AND r.currency = s.currency) THEN
          RAISE EXCEPTION 'accepted offer revision or currency mismatch' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = s.order_id AND o.currency_code = s.currency AND o.totals_finalized_at IS NOT NULL) THEN
          RAISE EXCEPTION 'order is not finalized in allocation currency' USING ERRCODE = 'check_violation';
        END IF;
        SELECT count(*) INTO n FROM public.order_line_component_allocations a WHERE a.allocation_set_id = s.id;
        IF n < 1 OR n > 16 OR n <> (SELECT count(*) FROM public.membership_offer_revision_components c WHERE c.revision_id = s.offer_revision_id) THEN
          RAISE EXCEPTION 'allocation manifest incomplete' USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (
          SELECT 1 FROM public.order_line_component_allocations a
          JOIN public.order_line_items l ON l.id = a.order_line_item_id
          JOIN public.membership_offer_revision_components c ON c.id = a.offer_component_id
          WHERE a.allocation_set_id = s.id AND
            (l.order_id <> s.order_id OR l.membership_occurrence_key_snapshot IS DISTINCT FROM s.occurrence_key OR
             l.membership_offer_revision_id_snapshot IS DISTINCT FROM s.offer_revision_id OR c.revision_id <> s.offer_revision_id OR
             c.gross_minor <> a.gross_minor OR l.currency <> s.currency OR
             upper(trim(c.tax_treatment_key)) <> upper(trim(l.tax_category_snapshot)) OR
             (a.discount_minor > 0 AND (s.source_eligibility_key IS NULL OR c.discount_eligibility_key <> s.source_eligibility_key)))
        ) THEN RAISE EXCEPTION 'allocation identity, price, tax category or eligibility mismatch' USING ERRCODE = 'check_violation'; END IF;
        IF EXISTS (
          SELECT 1 FROM public.order_line_items l
          LEFT JOIN public.order_line_component_allocations a ON a.order_line_item_id = l.id AND a.allocation_set_id = s.id
          WHERE l.order_id = s.order_id AND l.membership_occurrence_key_snapshot = s.occurrence_key
          GROUP BY l.id
          HAVING count(a.id) = 0 OR coalesce(sum(a.gross_minor),0) <> l.line_total_minor OR
                 coalesce(sum(a.discount_minor),0) <> l.discount_allocated_minor OR
                 coalesce(sum(a.net_minor),0) <> l.net_line_total_minor OR
                 coalesce(sum(a.tax_minor),0) <> l.tax_minor OR
                 l.tax_rate_id_snapshot IS NULL OR l.tax_rate_code_snapshot IS NULL OR l.tax_rate_bps_snapshot IS NULL OR
                 (l.net_line_total_minor = 0 AND l.tax_minor <> 0)
        ) THEN RAISE EXCEPTION 'allocation line does not reconcile' USING ERRCODE = 'check_violation'; END IF;
        IF (s.source_adjustment_id IS NULL) <> (s.source_eligibility_key IS NULL) OR
           (s.source_adjustment_id IS NULL) <> (s.source_rule_version IS NULL) OR
           (s.source_adjustment_id IS NULL AND EXISTS (SELECT 1 FROM public.order_line_component_allocations a WHERE a.allocation_set_id = s.id AND a.discount_minor > 0)) OR
           (s.source_adjustment_id IS NOT NULL AND NOT EXISTS (
             SELECT 1 FROM public.order_adjustments d WHERE d.id = s.source_adjustment_id AND d.order_id = s.order_id AND d.currency = s.currency AND d.source_kind IN ('coupon','promotion') AND d.source_id IS NOT NULL AND d.amount_minor < 0
           )) THEN RAISE EXCEPTION 'discount source evidence invalid' USING ERRCODE = 'check_violation'; END IF;
      END LOOP;
    END $$
    """

    execute "REVOKE ALL ON FUNCTION public.membership_allocation_validate_order(uuid) FROM PUBLIC"
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

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM public.order_line_component_allocation_sets LIMIT 1) THEN
        RAISE EXCEPTION 'cannot remove acceptance lock protection with existing evidence';
      END IF;
    END $$
    """

    execute "DROP FUNCTION public.membership_allocation_validate_order(uuid)"
    execute "DROP FUNCTION public.membership_allocation_lock_orders(uuid[], uuid)"
    execute "DROP FUNCTION public.lock_membership_acceptance_sources(uuid, uuid)"
    execute "DROP FUNCTION public.lock_membership_acceptance_manifest(uuid, uuid[])"
  end
end
