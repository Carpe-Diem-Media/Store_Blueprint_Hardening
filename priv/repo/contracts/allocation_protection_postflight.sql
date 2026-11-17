-- Fixed allocation protection manifest, checked only after all foundation migrations.
-- tgtype: ROW=1, BEFORE=2, INSERT=4, DELETE=8, UPDATE=16, TRUNCATE=32.
-- Require ordinary enablement (O), exact table/function/events and deferred semantics.
WITH expected(table_name, trigger_name, function_name, trigger_type, deferred) AS (
  VALUES
    ('order_line_items', 'order_line_items_membership_lock', 'membership_allocation_lock_order()', 7, false),
    ('order_line_items', 'order_line_items_membership_complete', 'membership_allocation_deferred_check()', 29, true),
    ('order_line_component_allocation_sets', 'order_line_component_allocation_sets_membership_lock', 'membership_allocation_lock_order()', 7, false),
    ('order_line_component_allocation_sets', 'order_line_component_allocation_sets_membership_complete', 'membership_allocation_deferred_check()', 29, true),
    ('order_line_component_allocations', 'order_line_component_allocations_membership_lock', 'membership_allocation_lock_order()', 7, false),
    ('order_line_component_allocations', 'order_line_component_allocations_membership_complete', 'membership_allocation_deferred_check()', 29, true),
    ('order_adjustments', 'order_adjustments_membership_insert_lock', 'membership_allocation_lock_order()', 7, false),
    ('order_line_items', 'membership_line_update_lock', 'membership_allocation_lock_order()', 19, false),
    ('order_line_items', 'order_line_items_membership_immutable', 'membership_allocation_immutable()', 27, false),
    ('order_line_items', 'order_line_items_membership_truncate', 'membership_allocation_no_truncate()', 34, false),
    ('order_line_component_allocation_sets', 'order_line_component_allocation_sets_membership_immutable', 'membership_allocation_immutable()', 27, false),
    ('order_line_component_allocation_sets', 'order_line_component_allocation_sets_membership_truncate', 'membership_allocation_no_truncate()', 34, false),
    ('order_line_component_allocations', 'order_line_component_allocations_membership_immutable', 'membership_allocation_immutable()', 27, false),
    ('order_line_component_allocations', 'order_line_component_allocations_membership_truncate', 'membership_allocation_no_truncate()', 34, false),
    ('orders', 'orders_membership_immutable', 'membership_allocation_immutable()', 27, false),
    ('orders', 'orders_membership_truncate', 'membership_allocation_no_truncate()', 34, false),
    ('order_adjustments', 'order_adjustments_membership_immutable', 'membership_allocation_immutable()', 27, false),
    ('order_adjustments', 'order_adjustments_membership_truncate', 'membership_allocation_no_truncate()', 34, false),
    ('order_line_component_allocation_sets', 'membership_allocation_validate_accept', 'membership_allocation_after_accept()', 17, false),
    ('order_line_component_allocation_sets', 'membership_allocation_tax_evidence_complete', 'membership_allocation_tax_evidence_commit()', 21, true)
)
SELECT e.table_name || '.' || e.trigger_name
FROM expected e
LEFT JOIN pg_catalog.pg_trigger t
  ON t.tgrelid = pg_catalog.to_regclass('public.' || e.table_name)
 AND t.tgname = e.trigger_name
WHERE NOT COALESCE(
  NOT t.tgisinternal AND t.tgenabled = 'O'
  AND t.tgfoid = pg_catalog.to_regprocedure('public.' || e.function_name)
  AND t.tgtype = e.trigger_type
  AND t.tgdeferrable = e.deferred AND t.tginitdeferred = e.deferred
  AND t.tgqual IS NULL AND t.tgnargs = 0,
  false
)
ORDER BY e.table_name, e.trigger_name
