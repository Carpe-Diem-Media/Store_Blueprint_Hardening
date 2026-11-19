#!/usr/bin/env python3
"""Prove Model B role capabilities in a job-owned PostgreSQL 18 service only.

This creates a representative ACL schema, not the incomplete Store financial
schema. It does not prove financial acceptance, authentication, OS credential
isolation, production grants, or application compatibility. Keep this proof in
normal PR CI; remove the feature-branch push trigger before PR review.

The trusted harness provisions with the service administrator, then opens actual
restricted-principal connections for every permission assertion. It never uses
SET ROLE as a substitute for those independent login identities. Generated
passwords stay in subprocess environments/stdin and are never printed.
"""

import os
import secrets
import subprocess
import sys

OWNER = "model_b_owner"
MIGRATOR = "model_b_migrator"
RUNTIME = "model_b_runtime"
DIRECT_RUNTIME = "model_b_direct_runtime"
WRITER = "model_b_allocation_writer"
MAINTAINER = "model_b_pricing_maintainer"
LOGINS = (MIGRATOR, RUNTIME, WRITER, MAINTAINER)
PASSWORDS = {role: secrets.token_urlsafe(32) for role in LOGINS + (DIRECT_RUNTIME,)}
ADMIN = os.environ.get("PGUSER", "")
ADMIN_PASSWORD = os.environ.get("PGPASSWORD", "")
ASSERTIONS = 0


def sql(role, statement, denied=False):
    """Execute on a new real login connection, reporting no SQL or credentials."""
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith("PG"):
            env.pop(key)
    env.update(
        PGHOST=os.environ["PGHOST"],
        PGPORT=os.environ["PGPORT"],
        PGDATABASE="model_b_role_proof",
        PGUSER=role,
        PGPASSWORD=ADMIN_PASSWORD if role == ADMIN else PASSWORDS[role],
        PGCONNECT_TIMEOUT="5",
    )
    result = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
         "-v", "VERBOSITY=sqlstate"],
        input=statement,
        text=True,
        capture_output=True,
        env=env,
        timeout=20,
        check=False,
    )
    if denied:
        if result.returncode == 0 or "42501" not in result.stderr:
            raise RuntimeError(f"expected insufficient_privilege for principal {role}")
    elif result.returncode != 0:
        # psql's sqlstate verbosity omits statements and bound password values.
        state = next((s for s in result.stderr.split() if len(s) == 5 and s.isalnum()), "unknown")
        raise RuntimeError(f"SQL failed for principal {role}, SQLSTATE {state}")
    return result.stdout.strip()


def equal(role, statement, expected, label):
    global ASSERTIONS
    if sql(role, statement) != expected:
        raise RuntimeError(f"assertion failed: {label}, principal {role}")
    ASSERTIONS += 1
    print(f"PASS principal={role} {label}", flush=True)


def deny(role, statement, label):
    global ASSERTIONS
    sql(role, statement, denied=True)
    ASSERTIONS += 1
    print(f"PASS principal={role} denied={label}", flush=True)


def bootstrap():
    # Only this disposable bootstrap operation uses the service administrator.
    statements = [f"CREATE ROLE {OWNER} NOLOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS;"]
    for role in LOGINS + (DIRECT_RUNTIME,):
        statements.append(
            f"CREATE ROLE {role} LOGIN NOINHERIT NOSUPERUSER NOCREATEROLE "
            f"NOCREATEDB NOREPLICATION NOBYPASSRLS PASSWORD '{PASSWORDS[role]}';"
        )
    statements += [
        f"GRANT {OWNER} TO {MIGRATOR};",
        f"ALTER DATABASE model_b_role_proof OWNER TO {OWNER};",
        "REVOKE ALL ON DATABASE model_b_role_proof FROM PUBLIC;",
        "REVOKE ALL ON SCHEMA public FROM PUBLIC;",
        f"GRANT CONNECT ON DATABASE model_b_role_proof TO {', '.join(LOGINS + (DIRECT_RUNTIME,))};",
    ]
    sql(ADMIN, "\n".join(statements))


def migrate():
    # Schema creation and grants are made by the actual authorized migrator.
    result = sql(MIGRATOR, f"""
    SET ROLE {OWNER};
    CREATE SCHEMA model_b_proof AUTHORIZATION {OWNER};
    REVOKE ALL ON SCHEMA model_b_proof FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES IN SCHEMA model_b_proof REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
    CREATE TABLE model_b_proof.orders (id bigint PRIMARY KEY, state text NOT NULL, total_minor bigint NOT NULL);
    CREATE TABLE model_b_proof.lines (id bigint PRIMARY KEY, order_id bigint REFERENCES model_b_proof.orders, gross_minor bigint NOT NULL, occurrence_key uuid);
    CREATE TABLE model_b_proof.adjustments (id bigint PRIMARY KEY, order_id bigint REFERENCES model_b_proof.orders, amount_minor bigint NOT NULL);
    CREATE TABLE model_b_proof.allocation_sets (id bigint PRIMARY KEY, order_id bigint REFERENCES model_b_proof.orders, accepted_at timestamptz);
    CREATE TABLE model_b_proof.allocation_rows (id bigint PRIMARY KEY, set_id bigint REFERENCES model_b_proof.allocation_sets, gross_minor bigint NOT NULL);
    CREATE TABLE model_b_proof.tax_rates (id bigint PRIMARY KEY, bps integer NOT NULL CHECK (bps >= 0));
    CREATE FUNCTION model_b_proof.lock_order(target_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    BEGIN
      PERFORM 1 FROM model_b_proof.orders WHERE id=target_id FOR UPDATE;
    END $$;
    REVOKE ALL ON FUNCTION model_b_proof.lock_order(bigint) FROM PUBLIC;
    GRANT USAGE ON SCHEMA model_b_proof TO {RUNTIME}, {WRITER}, {MAINTAINER};
    GRANT SELECT ON model_b_proof.orders, model_b_proof.lines, model_b_proof.adjustments,
      model_b_proof.allocation_sets, model_b_proof.allocation_rows, model_b_proof.tax_rates TO {RUNTIME};
    GRANT INSERT(id,state,total_minor), UPDATE(state,total_minor) ON model_b_proof.orders TO {RUNTIME};
    GRANT INSERT(id,order_id,gross_minor) ON model_b_proof.lines TO {RUNTIME};
    GRANT INSERT(id,order_id,amount_minor) ON model_b_proof.adjustments TO {RUNTIME};
    GRANT SELECT ON model_b_proof.orders, model_b_proof.lines, model_b_proof.adjustments,
      model_b_proof.allocation_sets, model_b_proof.allocation_rows, model_b_proof.tax_rates TO {WRITER};
    GRANT INSERT(id,order_id,accepted_at), UPDATE(accepted_at) ON model_b_proof.allocation_sets TO {WRITER};
    GRANT INSERT(id,set_id,gross_minor) ON model_b_proof.allocation_rows TO {WRITER};
    GRANT INSERT(id,order_id,gross_minor,occurrence_key) ON model_b_proof.lines TO {WRITER};
    GRANT INSERT(id,order_id,amount_minor) ON model_b_proof.adjustments TO {WRITER};
    GRANT EXECUTE ON FUNCTION model_b_proof.lock_order(bigint) TO {WRITER};
    GRANT SELECT, INSERT(id,bps), UPDATE(bps) ON model_b_proof.tax_rates TO {MAINTAINER};
    SELECT current_user;
    """)
    if result != OWNER:
        raise RuntimeError("migrator failed to assume isolated object owner")
    print(f"PASS principal={MIGRATOR} migrated_as={OWNER}", flush=True)


def verify():
    for role in LOGINS:
        equal(role, "SELECT current_user = session_user AND current_user = '" + role + "';", "t", "actual_login_identity")
        equal(role, "SELECT NOT (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname=current_user;", "t", "restricted_role_attributes")
    equal(RUNTIME, f"SELECT NOT rolcanlogin FROM pg_roles WHERE rolname='{OWNER}';", "t", "owner_cannot_login")
    equal(RUNTIME, f"SELECT bool_and(pg_get_userbyid(c.relowner)='{OWNER}') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='model_b_proof' AND c.relkind='r';", "t", "all_tables_owned_by_owner")
    equal(RUNTIME, f"SELECT pg_get_userbyid(proowner)='{OWNER}' FROM pg_proc WHERE oid='model_b_proof.lock_order(bigint)'::regprocedure;", "t", "helper_owned_by_owner")
    equal(MIGRATOR, f"SELECT pg_has_role(current_user,'{OWNER}','MEMBER') AND NOT pg_has_role(current_user,'{OWNER}','USAGE');", "t", "migrator_explicit_owner_assumption_only")
    for role in (RUNTIME, WRITER, MAINTAINER):
        equal(role, "SELECT count(*) FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=current_user);", "0", "no_memberships")
        for target in (OWNER,) + LOGINS:
            if target != role:
                deny(role, f"SET ROLE {target};", f"set_role_{target}")
        deny(role, "SET session_replication_role = replica;", "trigger_bypass_setting")
        deny(role, "CREATE SCHEMA forbidden;", "database_create")
        deny(role, "CREATE TABLE model_b_proof.forbidden (id integer);", "protected_schema_create")
        deny(role, "ALTER TABLE model_b_proof.allocation_sets DISABLE TRIGGER ALL;", "trigger_control")

    equal(RUNTIME, "INSERT INTO model_b_proof.orders VALUES (1,'draft',100) RETURNING state;", "draft", "legacy_order_insert")
    equal(RUNTIME, "UPDATE model_b_proof.orders SET state='pending' WHERE id=1 RETURNING state;", "pending", "legacy_state_update")
    equal(RUNTIME, "INSERT INTO model_b_proof.lines(id,order_id,gross_minor) VALUES(1,1,100) RETURNING id;", "1", "legacy_line_insert")
    equal(RUNTIME, "INSERT INTO model_b_proof.adjustments VALUES(1,1,0) RETURNING id;", "1", "legacy_adjustment_insert")
    equal(RUNTIME, "SELECT NOT has_table_privilege(current_user,'model_b_proof.lines','INSERT') AND has_column_privilege(current_user,'model_b_proof.lines','gross_minor','INSERT') AND NOT has_column_privilege(current_user,'model_b_proof.lines','occurrence_key','INSERT');", "t", "effective_column_acl")
    deny(RUNTIME, "INSERT INTO model_b_proof.lines VALUES(2,1,100,'01900000-0000-7000-8000-000000000001');", "marked_line_insert")
    deny(RUNTIME, "UPDATE model_b_proof.lines SET occurrence_key='01900000-0000-7000-8000-000000000001' WHERE id=1;", "line_retrofit")
    deny(RUNTIME, "INSERT INTO model_b_proof.allocation_sets VALUES(1,1,NULL);", "allocation_header_insert")
    deny(RUNTIME, "INSERT INTO model_b_proof.allocation_rows VALUES(1,1,100);", "allocation_child_insert")
    deny(RUNTIME, "SELECT model_b_proof.lock_order(1);", "privileged_helper_execute")
    deny(RUNTIME, "INSERT INTO model_b_proof.tax_rates VALUES(99,0);", "pricing_source_poisoning")
    deny(WRITER, "SELECT * FROM model_b_proof.orders WHERE id=1 FOR UPDATE;", "direct_order_row_lock_without_update_privilege")
    equal(WRITER, "BEGIN; SELECT model_b_proof.lock_order(1); SELECT current_user; COMMIT;", WRITER, "fixed_helper_lock_without_order_update_grant")
    equal(WRITER, "INSERT INTO model_b_proof.allocation_sets VALUES(1,1,NULL) RETURNING id;", "1", "writer_header_capability")
    equal(WRITER, "INSERT INTO model_b_proof.allocation_rows VALUES(1,1,100) RETURNING id;", "1", "writer_child_capability")
    equal(MAINTAINER, "INSERT INTO model_b_proof.tax_rates VALUES(1,100) RETURNING bps;", "100", "maintainer_source_insert")
    equal(MAINTAINER, "UPDATE model_b_proof.tax_rates SET bps=200 WHERE id=1 RETURNING bps;", "200", "maintainer_source_update")
    deny(MAINTAINER, "INSERT INTO model_b_proof.allocation_sets VALUES(2,1,NULL);", "maintainer_allocation_write")
    deny(MAINTAINER, "SELECT model_b_proof.lock_order(1);", "maintainer_acceptance_helper")
    deny(MAINTAINER, "DELETE FROM model_b_proof.tax_rates WHERE id=1;", "maintainer_source_delete")
    deny(WRITER, "UPDATE model_b_proof.tax_rates SET bps=0 WHERE id=1;", "writer_source_mutation")
    deny(WRITER, "UPDATE model_b_proof.orders SET total_minor=0 WHERE id=1;", "writer_order_mutation")
    deny(WRITER, "UPDATE model_b_proof.allocation_sets SET order_id=2 WHERE id=1;", "writer_reassignment")
    for role in (RUNTIME, WRITER, MAINTAINER):
        for table in ("allocation_sets", "allocation_rows"):
            deny(role, f"DELETE FROM model_b_proof.{table};", f"delete_{table}")
            deny(role, f"TRUNCATE model_b_proof.{table};", f"truncate_{table}")
    print(f"PASS role_capability_assertions={ASSERTIONS}; financial_acceptance=NOT_TESTED; process_isolation=NOT_TESTED", flush=True)


def main():
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("MODEL_B_CI_DISPOSABLE") != "true"
            or os.environ.get("PGHOST") != "127.0.0.1"
            or os.environ.get("PGDATABASE") != "model_b_role_proof"
            or ADMIN != "postgres" or not ADMIN_PASSWORD):
        raise RuntimeError("refusing to provision outside the explicitly job-owned CI service")
    version = int(sql(ADMIN, "SHOW server_version_num;"))
    if not 180000 <= version < 190000:
        raise RuntimeError("this proof requires PostgreSQL 18")
    print(f"PostgreSQL server_version_num={version}; isolated capability proof only", flush=True)
    bootstrap()
    migrate()
    verify()
    from model_b_allocation_lock_security import verify_allocations, verify_fixture_regressions
    verify_allocations(sys.modules[__name__])
    verify_fixture_regressions(sys.modules[__name__])
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(f"Model B role capability proof passed {ASSERTIONS} assertions on PostgreSQL 18.\n\n")
            output.write("Actual restricted logins and database SQL COMMIT/locks verified. OS/operator/credential isolation is deferred to JC-381 and is NOT verified by this database-only job. Trusted evaluator and financial acceptance invocation and production grants remain unverified.\n")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        # Print only controlled error messages; never subprocess input/env.
        print(f"FAIL {error if isinstance(error, RuntimeError) else 'database command timed out'}", file=sys.stderr)
        sys.exit(1)
