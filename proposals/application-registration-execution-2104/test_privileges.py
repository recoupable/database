"""Owned disposable PG only; unchanged D supervisor and transaction bodies are imported.

The explicit dispatch substitution changes only D.supervise's child script path. Its
lease, clean environment, process group, timeouts and cleanup functions stay intact.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
S = 'application_registration_proposal'
E = 'application_registration_execution_proposal'
OWNER = 'qualification_registration_data_owner'
EXECUTOR = 'qualification_registration_executor'
RUNTIME = 'qualification_registration_runtime'
CLIENT = 'qualification_registration_client'
BROWSER = 'qualification_registration_browser'
A = '00000000-0000-0000-0000-000000000001'
B = '00000000-0000-0000-0000-000000000002'


def load_supervisor():
    manifest = json.loads((HERE/'sources.json').read_text())
    for item in manifest['database_files']:
        if hashlib.sha256((ROOT/item['path']).read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('Pinned D source mismatch: '+item['path'])
    spec = importlib.util.spec_from_file_location('pinned_registration', ROOT/manifest['supervisor'])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


D = load_supervisor()
quote = D.quote
payload = D.payload


class Privileges(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.socket, cls.bin = D.verify_worker_lease()
        cls.env = {**D.fixture_environment(Path(cls.socket).parent, cls.bin),
                   'PGHOST': cls.socket, 'PGPORT': '55473', 'PGDATABASE': 'postgres',
                   'PGOPTIONS': '-c statement_timeout=10000 -c lock_timeout=8000'}
        for name in ['qualification-bootstrap.sql', 'parents.sql', 'registration.sql']:
            cls.admin((D.HERE/name).read_text())
        # Bootstrap defines a fake auth helper, but it is never invoked/composed.
        # The installation marker is an accidental-use guard, not authentication.
        cls.admin("SET qualification.registration_fixture='owned-disposable-only';"+
                  (HERE/'qualification-roles.sql').read_text()+(HERE/'execution.sql').read_text())
        print('RUNTIME '+cls.admin("SELECT json_build_object('postgres',version(),'server_version_num',current_setting('server_version_num'),'controller',current_user)::text"), flush=True)
        print('PYTHON '+sys.version, flush=True)
        print('SOURCE_HASHES '+json.dumps(json.loads((HERE/'sources.json').read_text())['database_files']), flush=True)

    @classmethod
    def args(cls, login=None):
        return [str(cls.bin/'psql'), '-XqAt', '-v', 'ON_ERROR_STOP=1'] + (['-U',login] if login else [])

    @classmethod
    def run_sql(cls, sql, login=None, role=None, name='privilege-test'):
        command = (f'SET ROLE {role};' if role else '')+sql
        result = subprocess.run(cls.args(login), input=command,
            env={**cls.env, 'PGAPPNAME':name}, capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    @classmethod
    def admin(cls, sql):
        return cls.run_sql(sql)

    def runtime(self, sql):
        return self.run_sql(sql, CLIENT, RUNTIME)

    def state(self):
        return {t:self.admin(f"SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb) FROM {S}.{t} t")
                for t in ['applications','environments','origins','receipts','requests']}

    def setUp(self):
        self.admin(f'TRUNCATE {S}.personal_principals CASCADE;'+
            f"INSERT INTO {S}.personal_principals(account_id) VALUES ('{A}'),('{B}');"+
            f"INSERT INTO {S}.create_entitlements(actor,workspace_id,environment) SELECT account_id,account_id,e FROM {S}.personal_principals CROSS JOIN unnest(ARRAY['production','development']) e;")

    def statement(self, **kw):
        return D.Registration.statement(self, **kw).replace(S+'.register_application',E+'.create_registration')

    def read_statement(self, receipt, **kw):
        return D.Registration.read_receipt(self, receipt, **kw).replace(S+'.read_registration',E+'.read_registration')

    def receipt(self, raw):
        value=json.loads(raw)
        self.assertIsInstance(value,dict)
        for flag in ['origins_verified','bootstrap_enabled','access_activated','runtime_enabled','production_persisted']:
            self.assertIs(value[flag],False)
        self.assertEqual(value['policy_status'],'proposed_unadopted')
        self.assertEqual(value['evidence_kind'],'disposable_parent_assertion')
        for key in ['receipt_id','application_id','recorded_at','actor','workspace_id','snapshot']:
            self.assertIn(key,value)
        return value

    def create(self, **kw):
        return self.receipt(self.runtime(self.statement(**kw)))

    def grant_read(self, receipt, actor=A, environment='production'):
        self.admin(f"INSERT INTO {S}.management_entitlements(actor,workspace_id,application_id,environment,operation) VALUES ('{actor}','{actor}',{quote(receipt['application_id'])},{quote(environment)},'read_registration');")

    def assert_state(self, statement, expected, login=CLIENT, role=RUNTIME):
        # The anonymous block executes in the actual unprivileged client session.
        command=statement.strip().removesuffix(';')
        self.run_sql(f"""DO $check$ DECLARE observed text;
        BEGIN BEGIN EXECUTE {quote(command)};
        EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS observed=RETURNED_SQLSTATE; END;
        IF observed IS DISTINCT FROM {quote(expected)} THEN RAISE EXCEPTION 'Expected %, observed %',{quote(expected)},coalesce(observed,'SUCCESS'); END IF;
        END $check$;""",login,role)

    def test_01_runtime_create_read_and_isolation(self):
        self.assertEqual(self.runtime('SELECT session_user,current_user'),CLIENT+'|'+RUNTIME)
        receipt=self.create()
        self.assertEqual(receipt['actor'],A)
        self.assertEqual(self.admin(f'SELECT count(*) FROM {S}.management_entitlements'),'0')
        self.assert_state(self.read_statement(receipt),'42501')
        self.grant_read(receipt)
        self.assertEqual(self.receipt(self.runtime(self.read_statement(receipt))),receipt)
        other=self.create(actor=B,workspace=B)
        dev=self.create(env='development',key='dev')
        self.assertEqual(len({r['application_id'] for r in [receipt,other,dev]}),3)
        saved=self.state()
        for kw in [{'actor':B},{'workspace':B},{'env':'development'},{'app':other['application_id']}]:
            self.assert_state(self.read_statement(receipt,**kw),'42501')
            self.assertEqual(self.state(),saved)

    def test_02_malicious_runtime_actor_assertion_is_NOT_authentication(self):
        # Intentional positive limitation: the same session can assert either enrolled actor.
        first=self.create()
        other=self.create(actor=B,workspace=B)
        self.assertEqual((first['actor'],other['actor']),(A,B))
        print('TRUST_LIMIT same runtime login successfully asserted both enrolled actors; UUID is not authentication',flush=True)
        saved=self.state()
        self.assert_state(self.statement(actor=B,workspace=A),'42501')
        self.admin(f"UPDATE {S}.personal_principals SET enabled=false WHERE account_id='{B}'")
        self.assert_state(self.statement(actor=B,workspace=B),'42501')
        self.assertEqual(self.state(),saved)

    def test_03_conflict_replay_authority_and_history(self):
        empty=self.state()
        self.assert_state(self.statement(rev=2),'P2101')
        self.assertEqual(self.state(),empty)
        original=self.create(); saved=self.state()
        changed=[{'rev':2},{'env':'development'},{'body':{**payload(),'name':'Changed'}}]
        for kw in changed:
            self.assert_state(self.statement(**kw),'P2101'); self.assertEqual(self.state(),saved)
        self.admin(f"UPDATE {S}.create_entitlements SET revision=2 WHERE actor='{A}'")
        self.assertEqual(self.create(),original)
        self.assert_state(self.statement(key='new'),'P2101')
        for mutation in [f"UPDATE {S}.create_entitlements SET enabled=false WHERE actor='{A}'",
                         f"DELETE FROM {S}.create_entitlements WHERE actor='{A}'"]:
            self.admin(mutation)
            for kw in [{}]+changed+[{'key':'new'}]:
                self.assert_state(self.statement(**kw),'42501'); self.assertEqual(self.state(),saved)
        for table in ['receipts','requests']:
            self.assert_state(f'DELETE FROM {S}.{table}','P0001',login=None,role=None)
        self.assertEqual(self.state(),saved)

    def test_04_read_and_enrollment_revocation(self):
        receipt=self.create(); self.grant_read(receipt); saved=self.state()
        self.admin(f'UPDATE {S}.management_entitlements SET enabled=false')
        self.assert_state(self.read_statement(receipt),'42501')
        self.admin(f'UPDATE {S}.management_entitlements SET enabled=true; UPDATE {S}.personal_principals SET enabled=false')
        self.assert_state(self.read_statement(receipt),'42501')
        self.assert_state(self.statement(),'42501'); self.assertEqual(self.state(),saved)

    def test_05_rollback_mid_insert_and_real_commit_response_loss(self):
        before=self.state()
        self.runtime('BEGIN;'+self.statement()+'ROLLBACK;'); self.assertEqual(self.state(),before)
        self.admin(f"CREATE FUNCTION {E}.fail_origin() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.origin='https://preview.example' THEN RAISE EXCEPTION 'forced second origin failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER fail_second BEFORE INSERT ON {S}.origins FOR EACH ROW EXECUTE FUNCTION {E}.fail_origin();")
        try:
            self.assert_state(self.statement(),'P0001'); self.assertEqual(self.state(),before)
        finally:
            self.admin(f'DROP TRIGGER fail_second ON {S}.origins; DROP FUNCTION {E}.fail_origin();')
        # psql completes a real COMMIT; discard its receipt to model transport loss.
        self.runtime('BEGIN;'+self.statement()+'COMMIT;')
        committed=self.state(); replay=self.create()
        self.assertEqual(self.state(),committed)
        stored=json.loads(self.admin(f'SELECT result FROM {S}.receipts'))
        self.assertEqual(replay,stored)

    def test_06_roles_memberships_owners_and_database_defaults(self):
        facts=json.loads(self.admin("SELECT json_agg(json_build_object('role',rolname,'super',rolsuper,'bypass',rolbypassrls,'inherit',rolinherit,'create_role',rolcreaterole,'create_db',rolcreatedb,'replicate',rolreplication,'login',rolcanlogin) ORDER BY rolname) FROM pg_roles WHERE rolname LIKE 'qualification_registration_%'"))
        self.assertEqual(len(facts),5)
        for fact in facts:
            for flag in ['super','bypass','inherit','create_role','create_db','replicate']:
                self.assertFalse(fact[flag])
            self.assertEqual(fact['login'],fact['role'] in [CLIENT,BROWSER])
        self.assertEqual(self.admin("SELECT r.rolname||':'||m.rolname||':'||a.admin_option FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member WHERE m.rolname LIKE 'qualification_registration_%'"),RUNTIME+':'+CLIENT+':false')
        for role in [RUNTIME,CLIENT,BROWSER,EXECUTOR]:
            self.assertEqual(self.admin(f"SELECT has_database_privilege('{role}','postgres','CREATE'),has_database_privilege('{role}','postgres','TEMP')"),'f|f')
        self.assertEqual(self.runtime('RESET ROLE; SELECT session_user,current_user'),CLIENT+'|'+CLIENT)
        self.assertEqual(self.runtime('SET SESSION AUTHORIZATION DEFAULT; SELECT session_user,current_user'),CLIENT+'|'+CLIENT)
        for role in [OWNER,EXECUTOR]:
            self.assert_state('SET ROLE '+role,'42501')
            self.assert_state('SET SESSION AUTHORIZATION '+role,'42501')
        self.assert_state('SET ROLE '+quote(self.admin('SELECT current_user')),'42501')
        self.assertEqual(self.admin(f"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE ((n.nspname='{S}' AND c.relkind='r') OR (n.nspname='public' AND c.relname='accounts')) AND c.relowner='{OWNER}'::regrole AND c.relrowsecurity AND c.relforcerowsecurity"),'9')
        print('ROLE_FACTS '+json.dumps(facts,sort_keys=True),flush=True)
        print('DATABASE_ACL '+self.admin("SELECT datacl::text FROM pg_database WHERE datname='postgres'"),flush=True)

    def test_07_no_direct_DML_DDL_or_escalation(self):
        receipt=self.create(); saved=self.state()
        statements=[f'SELECT * FROM {S}.receipts',f"INSERT INTO {S}.personal_principals(account_id) VALUES ('{A}')",
            f'UPDATE {S}.receipts SET result=result',f'DELETE FROM {S}.requests',f'TRUNCATE {S}.applications CASCADE',
            f'ALTER TABLE {S}.receipts ADD COLUMN evil text',f'DROP TABLE {S}.receipts CASCADE',
            'CREATE SCHEMA attacker','CREATE TEMP TABLE accounts(id uuid)', 'CREATE TABLE public.attacker(id int)',
            f'CREATE TABLE {E}.attacker(id int)',f'GRANT {EXECUTOR} TO {CLIENT}',
            'CREATE ROLE attacker',f'ALTER ROLE {RUNTIME} SUPERUSER',
            f"CREATE OR REPLACE FUNCTION {E}.read_registration(uuid,uuid,uuid,text,uuid) RETURNS jsonb LANGUAGE sql AS 'SELECT null::jsonb'",
            f"SELECT {S}.authorize_principal('{A}','{A}')",
            self.statement().replace(E+'.create_registration',S+'.register_application'),
            self.read_statement(receipt).replace(E+'.read_registration',S+'.read_registration'),
            "SELECT qualification_auth.original_actor('current-key')"]
        for command in statements:
            with self.subTest(command=command):
                self.assert_state(command,'42501'); self.assertEqual(self.state(),saved)
        # These schemas are absent; no proof/configuration composition was loaded.
        self.assertEqual(self.admin("SELECT to_regnamespace('application_proof_proposal') IS NULL"),'t')
        self.assert_state("SELECT application_proof_proposal.transact()",'3F000')

    def test_08_entry_ACLs_independent_of_schema_usage_and_default_execute(self):
        for schema,expected in [(E,2),(S,0),('qualification_auth',0)]:
            self.assertEqual(self.admin(f"SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='{schema}' AND has_function_privilege('{RUNTIME}',p.oid,'EXECUTE')"),str(expected))
        self.assertEqual(self.admin(f"SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='{E}' AND p.prosecdef AND p.proowner='{EXECUTOR}'::regrole AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp','row_security=on']"),'2')
        self.assert_state(self.statement(),'42501',BROWSER,None)
        self.admin(f'GRANT USAGE ON SCHEMA {E},{S},qualification_auth TO {BROWSER}; GRANT USAGE ON SCHEMA {S} TO {RUNTIME}')
        try:
            self.assert_state(self.statement(),'42501',BROWSER,None)
            self.assert_state(self.statement().replace(E+'.create_registration',S+'.register_application'),'42501')
            self.assert_state(f"SELECT {S}.authorize_create('{A}','{A}','production')",'42501')
        finally:
            self.admin(f'REVOKE USAGE ON SCHEMA {E},{S},qualification_auth FROM {BROWSER}; REVOKE USAGE ON SCHEMA {S} FROM {RUNTIME}')
        # Actual creator-specific defaults, including fixture installer, not owner-transfer guesses.
        for creator in [self.admin('SELECT current_user'),OWNER,EXECUTOR]:
            self.admin(f'GRANT CREATE ON SCHEMA {E} TO {quote_identifier(creator)}; SET ROLE {quote_identifier(creator)}; CREATE FUNCTION {E}.default_probe() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$; RESET ROLE;')
            try:
                self.assertEqual(self.admin(f"SELECT has_function_privilege('{RUNTIME}','{E}.default_probe()','EXECUTE'),has_function_privilege('{BROWSER}','{E}.default_probe()','EXECUTE')"),'f|f')
                self.assert_state(f'SELECT {E}.default_probe()','42501')
            finally:
                self.admin(f'DROP FUNCTION {E}.default_probe(); REVOKE CREATE ON SCHEMA {E} FROM {quote_identifier(creator)}')
        self.assertEqual(self.admin(f"SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE n.nspname IN ('{E}','{S}','qualification_auth') AND a.grantee=0 AND a.privilege_type='EXECUTE'"),'0')

    def test_09_lock_column_privilege_and_using_are_each_required(self):
        receipt=self.create(); self.grant_read(receipt); saved=self.state()
        for table,column in [('public.accounts','id'),(S+'.personal_principals','account_id'),(S+'.create_entitlements','actor'),(S+'.management_entitlements','actor')]:
            command=self.read_statement(receipt) if 'management' in table else self.statement()
            self.admin(f'REVOKE UPDATE({column}) ON {table} FROM {EXECUTOR}')
            try: self.assert_state(command,'42501'); self.assertEqual(self.state(),saved)
            finally: self.admin(f'GRANT UPDATE({column}) ON {table} TO {EXECUTOR}')
            self.admin(f'ALTER POLICY executor_lock ON {table} USING (false)')
            try: self.assert_state(command,'42501'); self.assertEqual(self.state(),saved)
            finally: self.admin(f'ALTER POLICY executor_lock ON {table} USING (true)')
            before=self.admin(f"SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM {table} t")
            # Explicit fixture-controller SET ROLE to probe executor; never a runtime proof.
            self.assert_state(f'UPDATE {table} SET {column}={column}','42501',None,EXECUTOR)
            self.assertEqual(self.admin(f"SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM {table} t"),before)
        self.assertEqual(self.create(),receipt)
        self.assertEqual(self.receipt(self.runtime(self.read_statement(receipt))),receipt)

    def test_10_rls_controls_do_not_count_null_as_receipt(self):
        receipt=self.create(); self.grant_read(receipt); saved=self.state()
        self.admin(f'ALTER POLICY executor_select ON {S}.receipts USING (false)')
        try:
            raw=self.runtime(self.statement())
            self.assertEqual(raw,'')  # unchanged D replay can return SQL NULL when receipt hidden
            with self.assertRaises((ValueError,AssertionError)): self.receipt(raw)
            self.assert_state(self.read_statement(receipt),'42501')
            self.assertEqual(self.state(),saved)
        finally: self.admin(f'ALTER POLICY executor_select ON {S}.receipts USING (true)')
        self.admin(f'ALTER POLICY executor_insert ON {S}.origins WITH CHECK (false)')
        try:
            self.assert_state(self.statement(key='blocked'),'42501'); self.assertEqual(self.state(),saved)
        finally: self.admin(f'ALTER POLICY executor_insert ON {S}.origins WITH CHECK (true)')
        self.assertEqual(self.receipt(self.runtime('SET row_security=off;'+self.statement())),receipt)
        # Entry fixes row_security=on. Direct RLS is separately probed with temporary SELECT ACL.
        self.admin(f'GRANT USAGE ON SCHEMA {S} TO {RUNTIME}; GRANT SELECT ON {S}.receipts TO {RUNTIME}')
        try:
            self.assertEqual(self.runtime(f'SELECT count(*) FROM {S}.receipts'),'0')
            self.assert_state(f"SELECT set_config('row_security','off',false); SELECT * FROM {S}.receipts",'42501')
        finally: self.admin(f'REVOKE SELECT ON {S}.receipts FROM {RUNTIME}; REVOKE USAGE ON SCHEMA {S} FROM {RUNTIME}')

    def test_11_shadow_objects_use_separate_reversible_TEMP_profile(self):
        self.assert_state('CREATE TEMP TABLE accounts(id uuid)','42501')
        self.admin(f'GRANT TEMPORARY ON DATABASE postgres TO {RUNTIME}')
        try:
            raw=self.runtime("CREATE TEMP TABLE accounts(id uuid); CREATE FUNCTION pg_temp.authorize_principal(uuid,uuid) RETURNS void LANGUAGE sql AS $$ SELECT $$; SET search_path=pg_temp,public;"+self.statement())
            self.receipt(raw)
            self.assert_state("CREATE TEMP TABLE personal_principals(account_id uuid); SET search_path=pg_temp,public;"+self.statement(actor=B),'42501')
        finally: self.admin(f'REVOKE TEMPORARY ON DATABASE postgres FROM {RUNTIME}')
        self.assert_state('CREATE TEMP TABLE accounts(id uuid)','42501')

    def holder(self, statement, runtime=False):
        process=subprocess.Popen(self.args(CLIENT if runtime else None),env={**self.env,'PGAPPNAME':'privilege-holder'},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        process.stdin.write((f'SET ROLE {RUNTIME};' if runtime else '')+'BEGIN;'+statement+"SELECT 'held';\n"); process.stdin.flush()
        deadline=time.monotonic()+12; output=''
        while time.monotonic()<deadline:
            if select.select([process.stdout],[],[],.1)[0]:
                output+=os.read(process.stdout.fileno(),65536).decode()
                if 'held' in output.splitlines(): return process
                if process.poll() is not None: break
        process.kill(); _,err=process.communicate(timeout=5)
        raise AssertionError('Holder failed: '+output+err)

    def race(self, held, waiting, holder_runtime=False, waiter_runtime=True, before_release=None):
        process=self.holder(held,holder_runtime)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future=pool.submit(self.run_sql,waiting,CLIENT if waiter_runtime else None,RUNTIME if waiter_runtime else None,'privilege-waiter')
            try:
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    # pg_blocking_pids ties the lock observation to our actual holder.
                    if self.admin("SELECT count(*) FROM pg_stat_activity w WHERE w.application_name='privilege-waiter' AND w.wait_event_type='Lock' AND EXISTS (SELECT 1 FROM pg_stat_activity h WHERE h.application_name='privilege-holder' AND h.pid=ANY(pg_blocking_pids(w.pid)))")=='1': break
                    time.sleep(.02)
                else: self.fail('No actual holder/waiter lock observed')
                print('OBSERVED_LOCK '+self.admin("SELECT json_build_object('waiter_user',usename,'wait_event',wait_event,'blocking_pids',pg_blocking_pids(pid)) FROM pg_stat_activity WHERE application_name='privilege-waiter'"),flush=True)
                if before_release: before_release()
            finally:
                process.stdin.write('COMMIT;\n'); process.stdin.flush(); process.stdin.close(); process.stdin=None
                _,err=process.communicate(timeout=12); self.assertEqual(process.returncode,0,err)
            return future.result(timeout=12)

    def revoke(self, suffix="enabled=false,revision=revision+1"):
        return f"SELECT id FROM public.accounts WHERE id='{A}' FOR UPDATE; SELECT account_id FROM {S}.personal_principals WHERE account_id='{A}' FOR UPDATE; UPDATE {S}.create_entitlements SET {suffix} WHERE actor='{A}';"

    def test_12_concurrent_runtime_replay_once(self):
        result=self.receipt(self.race(self.statement(),self.statement(),True))
        self.assertEqual(result,self.create()); self.assertEqual(self.admin(f'SELECT count(*) FROM {S}.applications'),'1')

    def test_13_revocation_first_denies_waiting_runtime(self):
        saved=self.state()
        with self.assertRaisesRegex(AssertionError,'authority unavailable'):
            self.race(self.revoke(),self.statement())
        self.assertEqual(self.state(),saved)

    def test_14_runtime_first_revocation_waits_then_denies_replay(self):
        self.race(self.statement(),self.revoke(),True,False)
        self.assertEqual(self.admin(f'SELECT count(*) FROM {S}.applications'),'1')
        saved=self.state(); self.assert_state(self.statement(),'42501'); self.assertEqual(self.state(),saved)

    def test_15_expiry_after_observed_authority_wait(self):
        saved=self.state()
        with self.assertRaisesRegex(AssertionError,'authority unavailable'):
            self.race(self.revoke("expires_at=clock_timestamp()+interval '350 milliseconds'"),self.statement(),before_release=lambda:time.sleep(.5))
        self.assertEqual(self.state(),saved)

    def test_16_expiry_after_observed_advisory_wait(self):
        saved=self.state()
        self.admin(f"UPDATE {S}.create_entitlements SET expires_at=clock_timestamp()+interval '700 milliseconds' WHERE actor='{A}'")
        held=f"SELECT pg_advisory_xact_lock(hashtextextended(jsonb_build_array('{A}'::uuid,'{A}'::uuid,'create_application'::text,'create'::text)::text,0));"
        with self.assertRaisesRegex(AssertionError,'authority unavailable'):
            self.race(held,self.statement(),before_release=lambda:time.sleep(.8))
        self.assertEqual(self.state(),saved)


    def permission_matrix(self):
        return {
            'public.accounts': {'SELECT':['id'],'UPDATE':['id']},
            S+'.personal_principals': {'SELECT':['account_id','enabled','policy_version'],'UPDATE':['account_id']},
            S+'.create_entitlements': {'SELECT':['actor','workspace_id','environment','revision','enabled','expires_at','policy_version'],'UPDATE':['actor']},
            S+'.management_entitlements': {'SELECT':['actor','workspace_id','application_id','environment','operation','enabled','revision','policy_version'],'UPDATE':['actor']},
            S+'.requests': {'SELECT':['actor','workspace_id','key','input','receipt_id'],'INSERT':['actor','workspace_id','key','input','receipt_id']},
            S+'.receipts': {'SELECT':['id','result','workspace_id','application_id','environment'],'INSERT':['id','actor','workspace_id','application_id','environment','recorded_at','result']},
            S+'.applications': {'INSERT':['workspace_id','id','billing_owner_id','name']},
            S+'.environments': {'INSERT':['workspace_id','application_id','environment']},
            S+'.origins': {'INSERT':['workspace_id','application_id','environment','origin','hostname','return_urls']}}

    def test_17_exact_catalog_grants_policies_and_trigger_context(self):
        for table,matrix in self.permission_matrix().items():
            for privilege in ['SELECT','INSERT','UPDATE','REFERENCES']:
                actual=self.admin(f"SELECT string_agg(attname,',' ORDER BY attname) FROM pg_attribute WHERE attrelid='{table}'::regclass AND attnum>0 AND NOT attisdropped AND has_column_privilege('{EXECUTOR}',attrelid,attnum,'{privilege}')")
                self.assertEqual(actual,','.join(sorted(matrix.get(privilege,[]))),table+' '+privilege)
                for role in [RUNTIME,CLIENT,BROWSER]:
                    self.assertEqual(self.admin(f"SELECT has_any_column_privilege('{role}','{table}','{privilege}')"),'f')
            self.assertEqual(self.admin(f"SELECT has_table_privilege('{EXECUTOR}','{table}','DELETE,TRUNCATE,REFERENCES,TRIGGER')"),'f')
        empty_path = quote('search_path=""')
        self.assertEqual(self.admin(f"SELECT count(*) FROM pg_proc WHERE pronamespace='{S}'::regnamespace AND has_function_privilege('{EXECUTOR}',oid,'EXECUTE')"),'5')
        self.assertEqual(self.admin(f"SELECT count(*) FROM pg_proc WHERE pronamespace='{S}'::regnamespace AND (prosecdef OR proowner<>'{OWNER}'::regrole OR NOT proconfig @> ARRAY[{empty_path}])"),'0')
        self.assertEqual(self.admin(f"SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgfoid='{S}.immutable_history()'::regprocedure"),'2')
        self.assertEqual(self.admin(f"SELECT has_function_privilege('{EXECUTOR}','{S}.immutable_history()','EXECUTE')"),'f')
        for role in [RUNTIME,CLIENT,BROWSER,EXECUTOR]:
            for schema in ['public',S,E,'qualification_auth']:
                self.assertEqual(self.admin(f"SELECT has_schema_privilege('{role}','{schema}','CREATE')"),'f')
        policies=json.loads(self.admin(f"SELECT json_agg(json_build_object('table',schemaname||'.'||tablename,'command',cmd,'roles',roles,'using',qual,'check',with_check,'permissive',permissive) ORDER BY schemaname,tablename,policyname) FROM pg_policies WHERE schemaname='{S}' OR (schemaname='public' AND tablename='accounts')"))
        self.assertEqual(len(policies),15)
        for policy in policies:
            self.assertEqual(policy['roles'],[EXECUTOR])
            self.assertIn(policy['command'],['SELECT','UPDATE','INSERT'])
            if policy['command']=='UPDATE':
                self.assertEqual((policy['using'],policy['check']),('true','false'))
        print('EXACT_COLUMN_GRANTS '+json.dumps(self.permission_matrix(),sort_keys=True),flush=True)
        print('RLS_POLICIES '+json.dumps(policies,sort_keys=True),flush=True)
        print('FUNCTION_CATALOG '+self.admin(f"SELECT json_agg(json_build_object('signature',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,'definer',p.prosecdef,'config',p.proconfig,'acl',p.proacl)) FROM pg_proc p WHERE pronamespace IN ('{E}'::regnamespace,'{S}'::regnamespace)"),flush=True)

    def test_18_each_select_insert_column_has_an_observed_dependency(self):
        receipt=self.create(); self.grant_read(receipt); saved=self.state()
        measured=[]
        for table,matrix in self.permission_matrix().items():
            for privilege in ['SELECT','INSERT']:
                for column in matrix.get(privilege,[]):
                    command=self.read_statement(receipt) if table in [S+'.management_entitlements',S+'.receipts'] and privilege=='SELECT' else self.statement(key='new') if privilege=='INSERT' else self.statement()
                    self.admin(f'REVOKE {privilege}({column}) ON {table} FROM {EXECUTOR}')
                    try:
                        self.assert_state(command,'42501'); self.assertEqual(self.state(),saved)
                        measured.append(table+':'+privilege+':'+column)
                    finally: self.admin(f'GRANT {privilege}({column}) ON {table} TO {EXECUTOR}')
        self.assertEqual(self.create(),receipt)
        print('MEASURED_COLUMN_DEPENDENCIES '+json.dumps(measured),flush=True)


def quote_identifier(value):
    return '"'+value.replace('"','""')+'"'


def main():
    if sys.argv[1:]==['--worker']:
        socket,pg_bin=D.prepare_worker_environment()
        fault=os.environ.get('REGISTRATION_QUALIFICATION_FAULT')
        if fault=='timeout': time.sleep(30)
        if fault=='worker-exit':
            subprocess.Popen([str(pg_bin/'psql'),'-XqAt','-h',socket,'-p','55473','-d','postgres','-c','SELECT pg_sleep(30)'],env=D.fixture_environment(Path(socket).parent,pg_bin))
            time.sleep(.1); return 86
        suite=unittest.defaultTestLoader.loadTestsFromTestCase(Privileges)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if len(sys.argv)!=1: raise SystemExit('No connection strings or external targets accepted')
    # Only redirect the existing supervisor's worker dispatch; no lifecycle copy.
    D.__file__=str(Path(__file__).resolve())
    return D.supervise()


if __name__=='__main__':
    raise SystemExit(main())
