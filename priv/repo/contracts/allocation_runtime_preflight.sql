WITH runtimes AS (
  SELECT name, r.* FROM unnest($1::text[]) AS n(name)
  LEFT JOIN pg_roles r ON r.rolname=n.name
), target_tables AS (
  SELECT name,to_regclass('public.' || name) AS id FROM unnest(ARRAY[
    'orders','order_line_items','order_adjustments','order_line_component_allocation_sets',
    'order_line_component_allocations','membership_offer_revisions',
    'membership_offer_revision_components','tax_rates','promotions','coupons']) AS n(name)
), new_tables AS (
  SELECT * FROM target_tables WHERE name IN
    ('order_line_component_allocation_sets','order_line_component_allocations')
), functions AS (
  SELECT name, to_regprocedure('public.' || name) AS id,
    name IN ('membership_allocation_lock_orders(uuid[],uuid)',
             'membership_allocation_validate_order(uuid)') AS allowed,
    name LIKE 'lock_membership_acceptance_%' AS definer
  FROM unnest(ARRAY['membership_allocation_lock_orders(uuid[],uuid)',
    'membership_allocation_validate_order(uuid)',
    'lock_membership_acceptance_sources(uuid,uuid)',
    'lock_membership_acceptance_manifest(uuid,uuid[])',
    'membership_allocation_lock_order()','membership_allocation_immutable()',
    'membership_allocation_deferred_check()','membership_allocation_after_accept()',
    'membership_allocation_no_truncate()','membership_allocation_tax_evidence_commit()']) AS n(name)
), checks AS (
  SELECT 'known_restricted_logins' AS name,
    cardinality($1::text[])=2 AND bool_and(oid IS NOT NULL AND rolcanlogin AND
      NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)
      AND rolname<>current_user) AS ok FROM runtimes
  UNION ALL SELECT 'separate_no_login_owner', NOT rolcanlogin AND
    NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)
    FROM pg_roles WHERE rolname=current_user
  UNION ALL SELECT 'restricted_migration_login', NOT rolinherit AND rolcanlogin AND
    NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls) AND
    session_user<>current_user AND pg_has_role(session_user,current_user,'MEMBER')
    FROM pg_roles WHERE rolname=session_user
  UNION ALL SELECT 'no_runtime_memberships', NOT EXISTS (
    SELECT 1 FROM pg_auth_members m JOIN runtimes r ON r.oid=m.member)
  UNION ALL SELECT 'schema_usage_without_create', bool_and(
    has_schema_privilege(r.oid,'public','USAGE') AND
    NOT has_schema_privilege(r.oid,'public','CREATE') AND
    NOT has_database_privilege(r.oid,current_database(),'CREATE')) FROM runtimes r
  UNION ALL SELECT 'all_tables_owned_by_migration_owner', bool_and(t.id IS NOT NULL AND
    c.relowner=(SELECT oid FROM pg_roles WHERE rolname=current_user))
    FROM target_tables t LEFT JOIN pg_class c ON c.oid=t.id
  UNION ALL SELECT 'existing_read_dependencies', bool_and(has_table_privilege(r.oid,t.id,'SELECT'))
    FROM runtimes r CROSS JOIN target_tables t
  UNION ALL SELECT 'allocation_select_only', bool_and(has_table_privilege(r.oid,t.id,'SELECT') AND
    NOT has_any_column_privilege(r.oid,t.id,'INSERT,UPDATE,REFERENCES') AND
    NOT has_table_privilege(r.oid,t.id,'DELETE,TRUNCATE,TRIGGER,SELECT WITH GRANT OPTION'))
    FROM runtimes r CROSS JOIN new_tables t
  UNION ALL SELECT 'only_two_invoker_executes', bool_and(CASE
    WHEN f.id IS NULL THEN NOT f.allowed AND NOT f.definer
    ELSE has_function_privilege(r.oid,f.id,'EXECUTE')=f.allowed AND
      NOT has_function_privilege(r.oid,f.id,'EXECUTE WITH GRANT OPTION') END)
    FROM runtimes r CROSS JOIN functions f
  UNION ALL SELECT 'function_owner_and_modes', bool_and(CASE WHEN f.id IS NULL THEN
    NOT f.allowed AND NOT f.definer ELSE
    p.proowner=(SELECT oid FROM pg_roles WHERE rolname=current_user) AND
    p.prosecdef=f.definer AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'] END)
    FROM functions f LEFT JOIN pg_proc p ON p.oid=f.id
  UNION ALL SELECT 'no_public_allocation_acl', NOT EXISTS (
    SELECT 1 FROM new_tables t JOIN pg_class c ON c.oid=t.id,
      LATERAL aclexplode(COALESCE(c.relacl,acldefault('r',c.relowner))) a
    WHERE a.grantee=0
    UNION ALL SELECT 1 FROM new_tables t JOIN pg_attribute c ON c.attrelid=t.id,
      LATERAL aclexplode(c.attacl) a WHERE a.grantee=0)
  UNION ALL SELECT 'no_public_function_execute', NOT EXISTS (
    SELECT 1 FROM functions f JOIN pg_proc p ON p.oid=f.id,
      LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
    WHERE a.grantee=0 AND a.privilege_type='EXECUTE')
  UNION ALL SELECT 'no_unapproved_default_acl', NOT EXISTS (
    SELECT 1 FROM pg_default_acl d, LATERAL aclexplode(d.defaclacl) a
    WHERE d.defaclrole=(SELECT oid FROM pg_roles WHERE rolname=current_user)
      AND d.defaclnamespace IN (0,'public'::regnamespace)
      AND a.grantee<>d.defaclrole)
  UNION ALL SELECT 'exact_legacy_column_grants', bool_and(
    has_column_privilege(r.oid,t.id,a.attname,'INSERT') =
      ((($2::jsonb -> t.name) -> 'insert') ? a.attname::text) AND
    has_column_privilege(r.oid,t.id,a.attname,'UPDATE') =
      ((($2::jsonb -> t.name) -> 'update') ? a.attname::text) AND
    NOT has_table_privilege(r.oid,t.id,'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER,REFERENCES'))
    FROM runtimes r CROSS JOIN target_tables t
    JOIN pg_attribute a ON a.attrelid=t.id AND a.attnum>0 AND NOT a.attisdropped
    WHERE $2::jsonb ? t.name
)
SELECT name, COALESCE(ok,false) FROM checks ORDER BY name;
