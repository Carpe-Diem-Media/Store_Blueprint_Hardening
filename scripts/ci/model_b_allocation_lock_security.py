"""Actual Store schema/trigger integration under the disposable Model B logins.

Fixture source consistency is tested, not trusted evaluator invocation or OS
credential isolation. All provisioning remains inside the job-owned PG18 service.
"""
import json
import os
import secrets
import subprocess
import time


def verify_allocations(h):
    env = os.environ.copy()
    env.update(PGUSER=h.MIGRATOR, PGPASSWORD=h.PASSWORDS[h.MIGRATOR])
    migration = subprocess.run(
        ["mix", "run", "--no-start", "scripts/ci/model_b_migrate.exs"],
        env=env, capture_output=True, text=True, timeout=600, check=False,
    )
    if migration.returncode:
        diagnostic = migration.stderr + migration.stdout
        for secret in list(h.PASSWORDS.values()) + [h.ADMIN_PASSWORD]:
            if secret:
                diagnostic = diagnostic.replace(secret, "[REDACTED]")
        print(diagnostic[-6000:], flush=True)
        raise RuntimeError("actual Store migration failed under isolated migrator")
    print("PASS actual Store schema migrated under owner by migrator login", flush=True)

    def owner(statement):
        return h.sql(h.MIGRATOR, f"SET ROLE {h.OWNER};\n" + statement)

    owner(f"""
      GRANT USAGE ON SCHEMA public TO {h.RUNTIME}, {h.WRITER}, {h.MAINTAINER};
      GRANT SELECT ON public.orders, public.order_line_items, public.order_adjustments,
        public.order_line_component_allocation_sets, public.order_line_component_allocations,
        public.membership_offer_revisions, public.membership_offer_revision_components,
        public.tax_rates, public.promotions, public.coupons TO {h.RUNTIME}, {h.WRITER};
      GRANT UPDATE(state,version,provider_setup_started_at,updated_at) ON public.orders TO {h.RUNTIME};
      GRANT INSERT(id,order_id,line_no,currency,quantity,unit_price_minor,line_total_minor,
        sku_snapshot,product_title_snapshot,discount_allocated_minor,net_line_total_minor,
        tax_category_snapshot,tax_rate_id_snapshot,tax_rate_code_snapshot,tax_rate_bps_snapshot,
        tax_minor,membership_offer_revision_id_snapshot,membership_occurrence_key_snapshot,
        inserted_at,updated_at) ON public.order_line_items TO {h.WRITER};
      GRANT INSERT(id,order_id,sequence_no,currency,kind,amount_minor,inserted_at,updated_at)
        ON public.order_adjustments TO {h.WRITER};
      GRANT INSERT(id,order_id,offer_revision_id,occurrence_key,target_fingerprint,
        allocation_fingerprint,pricing_fingerprint,allocation_rule_version,currency,tax_context,accepted_at)
        ON public.order_line_component_allocation_sets TO {h.WRITER};
      GRANT UPDATE(accepted_at) ON public.order_line_component_allocation_sets TO {h.WRITER};
      GRANT INSERT(id,allocation_set_id,order_line_item_id,offer_component_id,component_instance_id,
        evaluation_line_id,gross_minor,discount_minor,net_minor,tax_minor)
        ON public.order_line_component_allocations TO {h.WRITER};
      GRANT SELECT, UPDATE(code,rate_basis_points,active) ON public.tax_rates TO {h.MAINTAINER};
      GRANT EXECUTE ON FUNCTION public.lock_membership_acceptance_sources(uuid,uuid) TO {h.WRITER};
      DO $$ DECLARE p record; BEGIN
        FOR p IN SELECT oid::regprocedure AS signature FROM pg_catalog.pg_proc
          WHERE pronamespace='public'::regnamespace AND proname LIKE 'membership_allocation_%'
        LOOP
          EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', p.signature);
          EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO {h.RUNTIME}, {h.WRITER}', p.signature);
        END LOOP;
      END $$;
    """)

    def fixture(bps=0, region=None):
        f = json.loads(owner("SELECT json_build_object(" + ",".join(
            f"'{key}',public.uuid_generate_v7()" for key in
            ("order", "revision", "component", "definition", "line", "set", "occurrence", "rate", "instance", "evaluation")
        ) + ");"))
        f.update(bps=bps, tax=(100*bps+5000)//10000)
        source_region = "NULL" if region is None else "''"
        owner(f"""
          BEGIN;
          INSERT INTO public.orders(id,order_ref,currency_code,totals_finalized_at,shipping_country_code,tax_as_of,
            items_subtotal_minor,grand_total_minor,tax_total_minor)
            VALUES('{f['order']}','CI{f['order']}','USD',now(),'US',now(),100,{100+f['tax']},{f['tax']});
          INSERT INTO public.tax_rates(id,code,country_code,region_code,product_tax_category,rate_basis_points,
            active,shipping_taxable,precedence_rank,inserted_at,updated_at)
            VALUES('{f['rate']}','R{f['rate']}','US',{source_region},'STANDARD',{bps},true,true,100,now(),now());
          INSERT INTO public.membership_offer_revisions(id,offer_key,revision,currency)
            VALUES('{f['revision']}','CI{f['revision']}',1,'USD');
          INSERT INTO public.membership_offer_revision_components(id,revision_id,definition_key,gross_minor,
            discount_eligibility_key,tax_treatment_key)
            VALUES('{f['component']}','{f['revision']}','{f['definition']}',100,'member','STANDARD');
          UPDATE public.membership_offer_revisions SET status='accepted',accepted_at=now(),
            fingerprint=public.membership_offer_revision_manifest_fingerprint(id) WHERE id='{f['revision']}';
          COMMIT;
        """)
        return f

    def construction(f, empty=False, accept=True):
        context = "'{}'::jsonb" if empty else f"""(
          SELECT jsonb_build_object('version','membership-tax-v1','tax_enabled',true,
            'order_id',o.id,'occurrence_key','{f['occurrence']}'::uuid,'currency','USD',
            'country','US','region',upper(btrim(o.shipping_region_code)),'as_of',o.tax_as_of,
            'lines',jsonb_build_array(jsonb_build_object('line_id',l.id,'category','STANDARD',
              'rate_id',r.id,'rate_code',r.code,'rate_bps',r.rate_basis_points,
              'tax_minor',l.tax_minor,'net_minor',100,'source',to_jsonb(r)-'inserted_at'-'updated_at')))
          FROM public.orders o JOIN public.order_line_items l ON l.order_id=o.id
          JOIN public.tax_rates r ON r.id=l.tax_rate_id_snapshot WHERE l.id='{f['line']}'
        )"""
        return f"""
          INSERT INTO public.order_line_items(id,order_id,line_no,currency,quantity,unit_price_minor,line_total_minor,
            sku_snapshot,product_title_snapshot,discount_allocated_minor,net_line_total_minor,tax_category_snapshot,
            tax_rate_id_snapshot,tax_rate_code_snapshot,tax_rate_bps_snapshot,tax_minor,
            membership_offer_revision_id_snapshot,membership_occurrence_key_snapshot,inserted_at,updated_at)
          VALUES('{f['line']}','{f['order']}',1,'USD',1,100,100,'CI','Membership',0,100,'STANDARD',
            '{f['rate']}','R{f['rate']}',{f['bps']},{f['tax']},'{f['revision']}','{f['occurrence']}',now(),now());
          INSERT INTO public.order_line_component_allocation_sets(id,order_id,offer_revision_id,occurrence_key,
            target_fingerprint,allocation_fingerprint,pricing_fingerprint,allocation_rule_version,currency,tax_context,accepted_at)
          VALUES('{f['set']}','{f['order']}','{f['revision']}','{f['occurrence']}',
            'target','allocation','pricing','v1','USD',{context},NULL);
          SAVEPOINT child;
          INSERT INTO public.order_line_component_allocations(id,allocation_set_id,order_line_item_id,offer_component_id,
            component_instance_id,evaluation_line_id,gross_minor,discount_minor,net_minor,tax_minor)
          VALUES(public.uuid_generate_v7(),'{f['set']}','{f['line']}','{f['component']}',
            '{f['instance']}','{f['evaluation']}',100,0,100,{f['tax']});
          RELEASE SAVEPOINT child;
        """ + (f"UPDATE public.order_line_component_allocation_sets SET accepted_at=now() WHERE id='{f['set']}';" if accept else "")

    def connection_env(role):
        result = {k:v for k,v in os.environ.items() if not k.startswith('PG')}
        result.update(PGHOST='127.0.0.1', PGPORT=os.environ['PGPORT'], PGDATABASE='model_b_role_proof',
                      PGUSER=role, PGPASSWORD=h.PASSWORDS[role], PGCONNECT_TIMEOUT='5')
        return result

    def rejection(statement, label):
        result = subprocess.run(['psql','-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate'],
            input=statement, text=True, capture_output=True, env=connection_env(h.WRITER), timeout=20)
        if result.returncode == 0 or '23514' not in result.stderr:
            raise RuntimeError(f"expected writer COMMIT check_violation: {label}")
        print(f"PASS principal={h.WRITER} rejected_COMMIT={label}", flush=True)

    f = fixture()
    for role in (h.RUNTIME, h.MAINTAINER):
        h.deny(role, f"SELECT public.lock_membership_acceptance_sources('{f['order']}','{f['revision']}');", "actual_acceptance_helper")
    for table in ('orders','tax_rates'):
        h.equal(h.WRITER, f"SELECT NOT has_any_column_privilege(current_user,'public.{table}','UPDATE');", 't', f"no_{table}_update_columns")
        h.deny(h.WRITER, f"SELECT * FROM public.{table} FOR UPDATE;", f"direct_{table}_update_lock")
        h.deny(h.WRITER, f"SELECT * FROM public.{table} FOR SHARE;", f"direct_{table}_share_lock")
    h.deny(h.WRITER, "UPDATE public.orders SET grand_total_minor=0;", 'actual_financial_update')
    h.deny(h.WRITER, "UPDATE public.tax_rates SET rate_basis_points=0;", 'actual_source_update')
    h.equal(h.WRITER, f"SELECT pg_get_userbyid(proowner)='{h.OWNER}' AND prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp'] FROM pg_proc WHERE oid='public.lock_membership_acceptance_sources(uuid,uuid)'::regprocedure;", 't', 'fixed_helper_owner_and_path')
    h.equal(h.WRITER, "SELECT bool_and(NOT prosecdef) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'membership_allocation_%';", 't', 'integrity_guards_remain_invokers')
    for bps in (0,1500):
        f=fixture(bps)
        h.equal(h.WRITER, 'BEGIN;'+construction(f)+f"COMMIT; SELECT count(*) FROM public.order_line_component_allocation_sets WHERE id='{f['set']}' AND accepted_at IS NOT NULL;", '1', f'actual_writer_complete_COMMIT_bps_{bps}')
    for empty, accept, label in ((True,True,'empty_tax_context'),(False,False,'unaccepted_set')):
        f=fixture()
        rejection('BEGIN;'+construction(f,empty=empty,accept=accept)+'COMMIT;',label)
        h.equal(h.RUNTIME, f"SELECT count(*) FROM public.order_line_items WHERE order_id='{f['order']}';", '0', f'rollback_{label}')
    f=fixture(region='')
    rejection('BEGIN;'+construction(f)+'COMMIT;','blank_rate_region_with_NULL_destination')
    owner(f"UPDATE public.orders SET shipping_region_code='' WHERE id='{f['order']}';")
    h.equal(h.WRITER,'BEGIN;'+construction(f)+f"COMMIT; SELECT count(*) FROM public.order_line_component_allocation_sets WHERE id='{f['set']}';",'1','blank_region_matches_blank_destination')

    def live(role):
        p = subprocess.Popen(['psql','-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=connection_env(role))
        return p

    def send(p, text):
        p.stdin.write(text+'\n');p.stdin.flush()

    def wait_line(p, expected):
        # Each session has server-enforced statement/idle bounds, plus final
        # communicate timeouts. No unbounded server-side lock wait is admitted.
        for _ in range(5):
            line=p.stdout.readline().strip()
            if line==expected:return
            if p.poll() is not None:break
        raise RuntimeError('restricted connection synchronization failed')

    f=fixture()
    holder=live(h.WRITER)
    try:
        send(holder, f"BEGIN; SELECT public.lock_membership_acceptance_sources('{f['order']}','{f['revision']}'); SELECT 'READY';")
        wait_line(holder,'READY')
        for role, statement in (
            (h.MAINTAINER,f"UPDATE public.tax_rates SET code=code WHERE id='{f['rate']}';"),
            (h.RUNTIME,f"UPDATE public.orders SET version=version+1 WHERE id='{f['order']}';"),
        ):
            waiter=live(role)
            try:
                send(waiter,"SET statement_timeout='3s'; SELECT pg_backend_pid();")
                pid=waiter.stdout.readline().strip()
                if not pid.isdigit():raise RuntimeError('missing waiter backend identity')
                send(waiter, statement)
                deadline=time.monotonic()+2
                while time.monotonic()<deadline:
                    if h.sql(h.RUNTIME,f'SELECT cardinality(pg_blocking_pids({pid}))>0;')=='t':break
                    time.sleep(.02)
                else:raise RuntimeError('no observable restricted-principal lock wait')
                print(f'PASS principal={role} observable_helper_lock_wait',flush=True)
                # Rollback releases every source/Order lock and lets the blocked
                # maintenance/runtime write complete on its own connection.
                send(holder,"ROLLBACK; SELECT 'RELEASED';")
                wait_line(holder,'RELEASED')
                send(waiter,'\\q')
                _,err=waiter.communicate(timeout=5)
                if waiter.returncode:raise RuntimeError('waiting mutation failed after lock release')
                send(holder,f"BEGIN; SELECT public.lock_membership_acceptance_sources('{f['order']}','{f['revision']}'); SELECT 'READY';")
                wait_line(holder,'READY')
            finally:
                if waiter.poll() is None:waiter.kill();waiter.communicate()
        send(holder,"ROLLBACK; SELECT 'RELEASED';")
        wait_line(holder,'RELEASED')
        h.equal(h.WRITER,f"BEGIN;SELECT public.lock_membership_acceptance_sources('{f['order']}','{f['revision']}'); SELECT current_setting('lock_timeout')||','||current_setting('statement_timeout')||','||current_setting('idle_in_transaction_session_timeout')||','||current_setting('transaction_timeout');ROLLBACK;", '1s,5s,5s,10s','bounded_transaction_timeouts')
    finally:
        if holder.poll() is None:
            send(holder,'ROLLBACK;\\q');holder.communicate(timeout=5)
    maintenance=live(h.MAINTAINER)
    try:
        send(maintenance, f"BEGIN; SET idle_in_transaction_session_timeout='5s'; UPDATE public.tax_rates SET code=code WHERE id='{f['rate']}'; SELECT 'READY';")
        wait_line(maintenance,'READY')
        result=subprocess.run(['psql','-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate'],
            input=f"BEGIN; SELECT public.lock_membership_acceptance_sources('{f['order']}','{f['revision']}'); COMMIT;",
            text=True,capture_output=True,env=connection_env(h.WRITER),timeout=5)
        if result.returncode==0 or '55P03' not in result.stderr:
            raise RuntimeError('expected bounded helper source lock_timeout')
        print(f'PASS principal={h.WRITER} source_lock_timeout_rolls_back',flush=True)
    finally:
        if maintenance.poll() is None:
            send(maintenance,'ROLLBACK;\\q');maintenance.communicate(timeout=5)
    print('PASS actual_restricted_writer_SQL_COMMIT_and_lock_integration; trusted_evaluator_invocation=NOT_TESTED; process_isolation=NOT_TESTED',flush=True)


def verify_fixture_regressions(h):
    # A trusted CI fixture harness is distinct from every Model B principal.
    # It owns only disposable test databases and cannot assume the protected owner.
    role = "model_b_fixture_harness"
    password = secrets.token_urlsafe(32)
    h.PASSWORDS[role] = password
    h.sql(h.ADMIN, f"""
      CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEROLE CREATEDB NOREPLICATION NOBYPASSRLS PASSWORD '{password}';
      CREATE DATABASE model_b_fixture_tests OWNER {role};
      REVOKE ALL ON DATABASE model_b_fixture_tests FROM PUBLIC;
    """)
    env = os.environ.copy()
    env.update(PGUSER=role, PGPASSWORD=password, PGDATABASE="model_b_fixture_tests",
        STORE_TEST_DATABASE_USERNAME=role, STORE_TEST_DATABASE_PASSWORD=password,
        STORE_TEST_DATABASE_NAME="model_b_fixture_tests", STORE_TEST_DATABASE_HOST="127.0.0.1",
        STORE_TEST_DATABASE_PORT="55433")
    commands = [
        ["mix", "run", "--no-start", "scripts/ci/model_b_migrate.exs"],
        ["mix", "run", "-e", 'Mix.Tasks.Test.run(["test/store/orders/membership_allocation_sql_test.exs", "test/store/orders/membership_allocation_commit_test.exs", "--include", "real_connections"])'],
    ]
    for command in commands:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180, check=False)
        output = result.stdout + result.stderr
        for secret in list(h.PASSWORDS.values()) + [h.ADMIN_PASSWORD]:
            if secret:
                output = output.replace(secret, "[REDACTED]")
        print(output, flush=True)
        if result.returncode:
            raise RuntimeError("non-superuser disposable fixture regression gate failed")
    print("PASS existing_SQL_COMMIT_lifecycle_and_blank_region_suite_under_non_superuser_fixture_harness", flush=True)
