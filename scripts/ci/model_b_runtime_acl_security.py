"""Supported deployment ACL contract and missing-grant regressions on job-owned PG18."""
import json
import os
from pathlib import Path
import subprocess


def prepare_contract(h, owner, env):
    """Stage schema without triggers, reject missing ACLs, then apply the documented delta."""
    env = dict(env)
    env.update(MODEL_B_RUNTIME_USER=h.RUNTIME, MODEL_B_RUNTIME_PASSWORD=h.PASSWORDS[h.RUNTIME],
               MODEL_B_DIRECT_RUNTIME_USER=h.DIRECT_RUNTIME,
               MODEL_B_DIRECT_RUNTIME_PASSWORD=h.PASSWORDS[h.DIRECT_RUNTIME])

    def migrate(success):
        result = subprocess.run(['mix', 'run', '--no-start', 'scripts/ci/model_b_contract_migrate.exs'],
                                env=env, text=True, capture_output=True, timeout=180, check=False)
        if (result.returncode == 0) != success:
            raise RuntimeError('supported migration preflight disposition mismatch')
        print('PASS supported_migration_preflight_' + ('accepted' if success else 'rejected_before_triggers'), flush=True)
        h.equal(h.ADMIN, "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('jc382_allocation_migration','jc382_allocation_identity');",
                '0', 'preflight_identity_and_migration_connection_cleanup')

    migrate(False)
    if owner("SELECT NOT EXISTS(SELECT 1 FROM schema_migrations WHERE version=20261116195400);") != 't':
        raise RuntimeError('failed preflight applied trigger migration')
    print('PASS failed_preflight_left_trigger_migration_unapplied', flush=True)
    h.equal(h.RUNTIME, "SELECT count(*) FROM pg_trigger WHERE tgname='order_adjustments_membership_insert_lock';",
            '0', 'failed_preflight_installed_no_allocation_triggers')
    # Use exactly the deployment grant file, not a second CI-only grant model.
    grants = Path('scripts/deployment/allocation_runtime_grants.sql').resolve()
    owner(f'\\set repo_role {h.RUNTIME}\n\\set direct_repo_role {h.DIRECT_RUNTIME}\n\\i {grants}\n')
    for role in (h.RUNTIME, h.DIRECT_RUNTIME):
        for permission, target in (
            ('SELECT', 'TABLE public.order_line_component_allocation_sets'),
            ('SELECT', 'TABLE public.order_line_component_allocations'),
            ('EXECUTE', 'FUNCTION public.membership_allocation_lock_orders(uuid[],uuid)'),
            ('EXECUTE', 'FUNCTION public.membership_allocation_validate_order(uuid)'),
        ):
            owner(f'REVOKE {permission} ON {target} FROM {role};')
            migrate(False)
            owner(f'GRANT {permission} ON {target} TO {role};')
    migrate(True)

    for role in (h.RUNTIME, h.DIRECT_RUNTIME):
        h.equal(role, "SELECT current_user=session_user;", 't', 'independent_runtime_login')
        for target in (h.OWNER, h.WRITER, h.MIGRATOR):
            h.deny(role, f'SET ROLE {target};', 'runtime_cannot_assume_' + target)
        for signature in ('lock_membership_acceptance_sources(uuid,uuid)',
                          'lock_membership_acceptance_manifest(uuid,uuid[])'):
            h.equal(role, f"SELECT has_function_privilege(current_user,'public.{signature}','EXECUTE');",
                    'f', 'private_definer_execute_denied')
            args = 'NULL::uuid,ARRAY[]::uuid[]' if 'manifest' in signature else 'NULL::uuid,NULL::uuid'
            h.deny(role, f"SELECT public.{signature.split('(')[0]}({args});", 'private_definer_call_42501')
        h.equal(role, "SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'membership_allocation_%' AND has_function_privilege(current_user,oid,'EXECUTE');",
                '2', 'only_router_and_validator_execute')
        order = owner("INSERT INTO orders(id,order_ref,currency_code) VALUES(uuid_generate_v7(),'ACL'||uuid_generate_v7(),'USD') RETURNING id;")
        # Deferred COMMIT checks must see an unmarked legacy line and no allocations.
        line = ("INSERT INTO public.order_line_items(id,order_id,line_no,currency,quantity,"
                "unit_price_minor,line_total_minor,sku_snapshot,product_title_snapshot,inserted_at,updated_at) "
                f"VALUES(uuid_generate_v7(),'{order}',{{number}},'USD',1,100,100,'ACL','legacy',now(),now());")
        owner(f'REVOKE EXECUTE ON FUNCTION membership_allocation_lock_orders(uuid[],uuid) FROM {role};')
        h.deny(role, 'BEGIN;' + line.format(number=1) + 'COMMIT;', 'missing_router_execute_42501')
        owner(f'GRANT EXECUTE ON FUNCTION membership_allocation_lock_orders(uuid[],uuid) TO {role};')
        owner(f'REVOKE EXECUTE ON FUNCTION membership_allocation_validate_order(uuid) FROM {role};')
        h.deny(role, 'BEGIN;' + line.format(number=1) + 'COMMIT;', 'missing_validator_execute_at_commit_42501')
        owner(f'GRANT EXECUTE ON FUNCTION membership_allocation_validate_order(uuid) TO {role};')
        h.equal(role, f"SELECT count(*) FROM order_line_items WHERE order_id='{order}';", '0', 'failed_commit_leaves_no_line')
        owner(f'REVOKE SELECT ON order_line_component_allocation_sets FROM {role};')
        h.deny(role, f"UPDATE orders SET version=version+1 WHERE id='{order}';", 'missing_header_select_42501')
        owner(f'GRANT SELECT ON order_line_component_allocation_sets TO {role};')
        owner(f'REVOKE SELECT ON order_line_component_allocations FROM {role};')
        h.deny(role, 'SELECT * FROM order_line_component_allocations LIMIT 0;', 'missing_child_select_42501')
        owner(f'GRANT SELECT ON order_line_component_allocations TO {role};')
        h.equal(role, 'BEGIN;' + line.format(number=1) + 'COMMIT;SELECT 1;', '1', 'narrow_grants_restore_legacy_commit')
        for table in ('order_line_component_allocation_sets', 'order_line_component_allocations'):
            h.equal(role, f'SELECT count(*) FROM {table};', '0', 'allocation_read_' + table)
            for operation in (f'INSERT INTO {table} DEFAULT VALUES;', f'UPDATE {table} SET id=id WHERE false;',
                              f'DELETE FROM {table} WHERE false;', f'TRUNCATE {table};',
                              f'ALTER TABLE {table} DISABLE TRIGGER ALL;'):
                h.deny(role, operation, 'allocation_dml_or_trigger_control_denied')
        h.deny(role, 'INSERT INTO order_line_items(membership_occurrence_key_snapshot) VALUES(uuid_generate_v7());', 'membership_marker_insert_denied')
        matrix = json.loads(h.sql(role, """SELECT json_build_object('principal',current_user,
          'allocation_tables', (SELECT json_object_agg(name, json_build_object(
            'select',has_table_privilege(current_user,name,'SELECT'),
            'column_write',has_any_column_privilege(current_user,name,'INSERT,UPDATE'),
            'delete_truncate',has_table_privilege(current_user,name,'DELETE,TRUNCATE')))
            FROM unnest(ARRAY['order_line_component_allocation_sets','order_line_component_allocations']) name),
          'functions', (SELECT json_object_agg(oid::regprocedure::text,has_function_privilege(current_user,oid,'EXECUTE'))
            FROM pg_proc WHERE pronamespace='public'::regnamespace AND
              (proname LIKE 'membership_allocation_%' OR proname LIKE 'lock_membership_acceptance_%')));"""))
        print('PASS effective_runtime_matrix=' + json.dumps(matrix, sort_keys=True), flush=True)


def legacy_write_cost(owner, phase):
    """Two rollback-only equivalent owner transactions, including deferred checks."""
    for repetition in (1, 2):
        result = owner("""BEGIN;
          DO $$ BEGIN PERFORM set_config('jc382.started',clock_timestamp()::text,true); END $$;
          INSERT INTO orders(id,order_ref,currency_code)
            VALUES(uuid_generate_v7(),'BENCH'||uuid_generate_v7(),'USD');
          INSERT INTO order_line_items(id,order_id,line_no,currency,quantity,unit_price_minor,
            line_total_minor,sku_snapshot,product_title_snapshot,inserted_at,updated_at)
            SELECT uuid_generate_v7(),o.id,n,'USD',1,100,100,'BENCH','legacy',now(),now()
            FROM orders o CROSS JOIN generate_series(1,20) n
            WHERE order_ref LIKE 'BENCH%' AND inserted_at >= transaction_timestamp();
          SET CONSTRAINTS ALL IMMEDIATE;
          SELECT extract(epoch FROM clock_timestamp()-current_setting('jc382.started')::timestamptz)*1000;
          ROLLBACK;""")
        print(f'PASS bounded_legacy_cost phase={phase} repetition={repetition} lines=20 elapsed_ms={result}', flush=True)
