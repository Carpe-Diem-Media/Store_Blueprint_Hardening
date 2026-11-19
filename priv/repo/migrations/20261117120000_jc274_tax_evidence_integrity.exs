defmodule Store.Repo.Migrations.Jc274TaxEvidenceIntegrity do
  use Ecto.Migration

  def up do
    # Validate only newly constructed occurrences. Historical evidence must not
    # be reinterpreted when a mutable Pricing rate subsequently changes.
    execute """
    CREATE FUNCTION public.membership_allocation_tax_evidence_commit() RETURNS trigger
    LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
    DECLARE
      s public.order_line_component_allocation_sets%ROWTYPE;
      o public.orders%ROWTYPE;
      l public.order_line_items%ROWTYPE;
      r public.tax_rates%ROWTYPE;
      c jsonb;
      e jsonb;
      expected jsonb;
      source jsonb;
      n integer;
    BEGIN
      SELECT * INTO s FROM public.order_line_component_allocation_sets WHERE id = NEW.id;
      IF NOT FOUND THEN RETURN NULL; END IF;
      PERFORM public.lock_membership_acceptance_sources(s.order_id, s.offer_revision_id);
      SELECT * INTO o FROM public.orders WHERE id = s.order_id;
      c := s.tax_context;
      IF s.accepted_at IS NULL OR o.tax_as_of IS NULL OR
         o.shipping_country_code IS NULL OR
         jsonb_typeof(c) IS DISTINCT FROM 'object' OR
         jsonb_typeof(c->'lines') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'incomplete membership tax evidence' USING ERRCODE = 'check_violation';
      END IF;
      expected := jsonb_build_object(
        'version', 'membership-tax-v1', 'tax_enabled', true,
        'order_id', s.order_id, 'occurrence_key', s.occurrence_key,
        'currency', s.currency, 'country', upper(btrim(o.shipping_country_code)),
        'region', upper(btrim(o.shipping_region_code)),
        'as_of', o.tax_as_of);
      IF (c - 'lines') IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'unsupported or inconsistent membership tax context' USING ERRCODE = 'check_violation';
      END IF;
      SELECT count(*) INTO n FROM public.order_line_items
        WHERE order_id = s.order_id AND membership_occurrence_key_snapshot = s.occurrence_key;
      IF n NOT BETWEEN 1 AND 16 OR jsonb_array_length(c->'lines') <> n THEN
        RAISE EXCEPTION 'membership tax evidence must cover every marked line once' USING ERRCODE = 'check_violation';
      END IF;
      -- The owner-defined helper holds SHARE table locks on all Pricing
      -- sources through COMMIT, including protection against new candidates.
      FOR l IN SELECT * FROM public.order_line_items
        WHERE order_id = s.order_id AND membership_occurrence_key_snapshot = s.occurrence_key
        ORDER BY id
      LOOP
        SELECT count(*) INTO n FROM jsonb_array_elements(c->'lines') item
          WHERE item->'line_id' = to_jsonb(l.id);
        IF n <> 1 THEN
          RAISE EXCEPTION 'missing or duplicate membership line tax evidence' USING ERRCODE = 'check_violation';
        END IF;
        SELECT item INTO e FROM jsonb_array_elements(c->'lines') item
          WHERE item->'line_id' = to_jsonb(l.id);
        SELECT * INTO r FROM public.tax_rates WHERE id = l.tax_rate_id_snapshot;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'membership tax rate source missing' USING ERRCODE = 'check_violation';
        END IF;
        source := jsonb_build_object(
          'id', r.id, 'code', r.code, 'country_code', r.country_code,
          'region_code', r.region_code, 'product_tax_category', r.product_tax_category,
          'rate_basis_points', r.rate_basis_points, 'active', r.active,
          'starts_at', r.starts_at, 'ends_at', r.ends_at,
          'precedence_rank', r.precedence_rank, 'shipping_taxable', r.shipping_taxable);
        expected := jsonb_build_object(
          'line_id', l.id, 'category', l.tax_category_snapshot,
          'rate_id', l.tax_rate_id_snapshot, 'rate_code', l.tax_rate_code_snapshot,
          'rate_bps', l.tax_rate_bps_snapshot, 'tax_minor', l.tax_minor,
          'net_minor', l.net_line_total_minor, 'source', source);
        IF e IS DISTINCT FROM expected OR
           l.tax_category_snapshot IS NULL OR l.tax_category_snapshot = '' OR
           l.tax_category_snapshot <> upper(btrim(l.tax_category_snapshot)) OR
           r.active IS DISTINCT FROM true OR r.rate_basis_points < 0 OR
           r.code IS DISTINCT FROM l.tax_rate_code_snapshot OR
           r.rate_basis_points IS DISTINCT FROM l.tax_rate_bps_snapshot OR
           upper(btrim(r.country_code)) IS DISTINCT FROM c->>'country' OR
           (r.region_code IS NOT NULL AND upper(btrim(r.region_code)) IS DISTINCT FROM c->>'region') OR
           (r.product_tax_category IS NOT NULL AND upper(btrim(r.product_tax_category)) IS DISTINCT FROM l.tax_category_snapshot) OR
           (r.starts_at IS NOT NULL AND r.starts_at > o.tax_as_of) OR
           (r.ends_at IS NOT NULL AND r.ends_at < o.tax_as_of) OR
           l.tax_minor IS DISTINCT FROM floor((l.net_line_total_minor::numeric * r.rate_basis_points + 5000) / 10000) THEN
          RAISE EXCEPTION 'inconsistent membership line tax source evidence' USING ERRCODE = 'check_violation';
        END IF;
      END LOOP;
      -- This proves source applicability and accepted line arithmetic, not
      -- winning-candidate selection. The trusted Pricing writer proves selection.
      RETURN NULL;
    END $$
    """

    execute """
    CREATE CONSTRAINT TRIGGER membership_allocation_tax_evidence_complete
    AFTER INSERT OR UPDATE ON public.order_line_component_allocation_sets
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION public.membership_allocation_tax_evidence_commit()
    """

    execute "REVOKE ALL ON FUNCTION public.membership_allocation_tax_evidence_commit() FROM PUBLIC"
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

    execute "DROP TRIGGER membership_allocation_tax_evidence_complete ON public.order_line_component_allocation_sets"

    execute "DROP FUNCTION public.membership_allocation_tax_evidence_commit()"
  end
end
