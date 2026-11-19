-- Owner-authorized new-install contract only. Supply authenticated principal names
-- as psql repo_role/direct_repo_role variables. This does not provision roles or
-- change baseline Orders grants. Run only after staging and explicit approval.
\set ON_ERROR_STOP on
BEGIN;
GRANT SELECT ON public.order_line_component_allocation_sets,
  public.order_line_component_allocations TO :"repo_role", :"direct_repo_role";
GRANT EXECUTE ON FUNCTION public.membership_allocation_lock_orders(uuid[],uuid),
  public.membership_allocation_validate_order(uuid) TO :"repo_role", :"direct_repo_role";
COMMIT;
