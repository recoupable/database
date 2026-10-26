"""New disabled-only proposal tests. Disposable socket PG; no hosted calls/122 suite."""
import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor

HERE = pathlib.Path(__file__).resolve().parent
BIN = pathlib.Path(os.environ.get('PG_BINDIR', '/opt/homebrew/opt/postgresql@17/bin'))


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class DisabledStorage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='catalog-disabled-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run([str(BIN/'initdb'), '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run([str(BIN/'pg_ctl'), '-D', str(cls.cluster), '-l', cls.tmp.name+'/pg.log',
                        '-o', f"-k {cls.tmp.name} -p 55476 -c listen_addresses=''", '-w', 'start'], check=True, capture_output=True)
        cls.addClassCleanup(lambda: subprocess.run([str(BIN/'pg_ctl'), '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'], check=True, capture_output=True))
        cls.sql('''CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
        CREATE TABLE public.accounts(id uuid PRIMARY KEY);
        CREATE FUNCTION public.trigger_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at=now(); RETURN NEW; END $$;
        GRANT USAGE ON SCHEMA public TO service_role,anon,authenticated;
        ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;''')
        # Actual pinned dependency migrations, including their RLS/grants/FKs.
        # Accounts and timestamp helper are the only minimal legacy bootstrap.
        root = HERE.parents[1]
        for filename in ['20251005212508_create_catalogs_table.sql', '20251005214926_create_account_catalogs_table.sql', '20251204000000_create_account_organization_ids.sql']:
            content = subprocess.check_output(['git', '-C', str(root), 'show', '76bad6195b4bd1918284c5ebe49c91f408072ed2:supabase/migrations/'+filename], text=True)
            cls.sql(content)
        cls.sql((HERE/'disabled-storage.sql').read_text())

    @classmethod
    def sql(cls, sql, error=None):
        r = subprocess.run([str(BIN/'psql'), '-h', cls.tmp.name, '-p', '55476', '-d', 'postgres', '-XqAt', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose'], input=sql, text=True, capture_output=True)
        if error:
            if not r.returncode or error not in r.stderr:
                raise AssertionError((error, r.stdout, r.stderr))
        elif r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def setUp(self):
        self.actor, self.org, self.catalog = [str(uuid.uuid4()) for _ in range(3)]
        self.principal = {'mechanism':'recoup_api_key','key_id':str(uuid.uuid4())}
        self.sql(f"INSERT INTO accounts VALUES ('{self.actor}'),('{self.org}'); INSERT INTO catalogs(id,name) VALUES ('{self.catalog}','Synthetic catalog'); INSERT INTO account_catalogs(account,catalog) VALUES ('{self.actor}','{self.catalog}'),('{self.org}','{self.catalog}'); INSERT INTO account_organization_ids(account_id,organization_id) VALUES ('{self.actor}','{self.org}')")
        self.intent = {'action':'create','payload':{'catalog_id':self.catalog,'organization_id':None,'schedule':'0 9 * * 1','timezone':'America/New_York'}}

    def call(self, cmd, key=None, actor=None, principal=None, error=None, prefix='', suffix=''):
        sql = f"SET ROLE service_role; SELECT public.mutate_catalog_report_schedule('{actor or self.actor}',{quote(json.dumps(principal or self.principal))}::jsonb,'{key or uuid.uuid4()}',{quote(json.dumps(cmd))}::jsonb);"
        result = self.sql(prefix+sql+suffix, error)
        return None if error else json.loads(result.splitlines()[-1])

    def read(self, task, actor=None, principal=None, error=None):
        result = self.sql(f"SET ROLE service_role; SELECT public.read_catalog_report_schedule('{actor or self.actor}',{quote(json.dumps(principal or self.principal))}::jsonb,'{task}')",error)
        return None if error else json.loads(result)

    def mutate(self, action, task, revision, **patch):
        return {'action':action,'payload':{'id':task,'expected_revision':revision,**patch}}

    def test_create_edit_disabled_disable_archive_and_receipts(self):
        key=str(uuid.uuid4()); first=self.call(self.intent,key); task=first['id']
        self.assertFalse(first['enabled']);self.assertEqual(first['revision'],1)
        self.assertEqual(self.read(task)['catalog_id'],self.catalog)
        edited=self.call(self.mutate('edit_disabled',task,1,schedule='30 8 * * 2',timezone='UTC'))
        self.assertEqual(edited['revision'],2)
        replay=self.call(self.intent,key);self.assertTrue(replay['replayed']);self.assertEqual(replay['revision'],1)
        self.assertEqual(self.read(task)['revision'],2)
        disabled=self.call(self.mutate('disable',task,2));self.assertEqual(disabled['revision'],3)
        archived=self.call(self.mutate('archive',task,3));self.assertIsNotNone(archived['archived_at'])
        self.call(self.mutate('edit_disabled',task,4,schedule='0 9 * * 1',timezone='UTC'),error='40001')
        replacement=self.call(self.intent);self.assertNotEqual(replacement['id'],task)
        self.assertEqual(self.sql(f"SELECT count(*) FROM catalog_report_schedule_revisions WHERE schedule_id='{task}'"),'4')

    def test_strict_keys_nulls_principal_and_timezone(self):
        cases=[None,{}, {'action':'enable','payload':{}}, {**self.intent,'actor':self.actor}, {'action':'create','payload':{**self.intent['payload'],'enabled':False}}, {'action':'create','payload':{k:v for k,v in self.intent['payload'].items() if k!='organization_id'}}]
        for field,value in [('catalog_id',None),('catalog_id','bad'),('organization_id','bad'),('schedule','00 09 * * 1'),('schedule','* * * * *'),('timezone','EST'),('timezone','Invalid/Zone'),('schedule',None)]:
            cases.append({'action':'create','payload':{**self.intent['payload'],field:value}})
        for c in cases:
            with self.subTest(c=c):self.call(c,error='22023')
        for principal in [{}, {'mechanism':'recoup_api_key','key_id':None},{**self.principal,'token':'forbidden'},{'mechanism':'privy','app_id':'a','issuer':'i','subject':None}]:
            self.sql(f"SET ROLE service_role; SELECT mutate_catalog_report_schedule('{self.actor}',{quote(json.dumps(principal))},'{uuid.uuid4()}',{quote(json.dumps(self.intent))})",'22023')
        self.sql(f"SET ROLE service_role; SELECT mutate_catalog_report_schedule(NULL,{quote(json.dumps(self.principal))},'{uuid.uuid4()}',{quote(json.dumps(self.intent))})",'22023')

    def test_scope_and_original_principal_and_revocation(self):
        cmd={'action':'create','payload':{**self.intent['payload'],'organization_id':self.org}}
        r=self.call(cmd);task=r['id']
        self.assertEqual(r['organization_id'],self.org)
        self.read(task,principal={'mechanism':'recoup_api_key','key_id':str(uuid.uuid4())},error='42501')
        self.read(task,actor=self.org,error='42501')
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
        self.read(task,error='42501');self.call(self.mutate('disable',task,1),error='42501')
        self.sql(f"INSERT INTO account_organization_ids(account_id,organization_id) VALUES ('{self.actor}','{self.org}'); DELETE FROM account_catalogs WHERE account='{self.org}'")
        self.read(task,error='42501') # still personally visible must not substitute scope

    def test_deletion_preserves_history_and_does_not_block_parent_deletion(self):
        r=self.call(self.intent);task=r['id']
        self.sql(f"DELETE FROM catalogs WHERE id='{self.catalog}'; DELETE FROM accounts WHERE id='{self.actor}'")
        self.assertEqual(self.sql(f"SELECT count(*) FROM catalog_report_schedules WHERE id='{task}'"),'1')
        self.assertEqual(self.sql(f"SELECT count(*) FROM catalog_report_schedule_revisions WHERE schedule_id='{task}'"),'1')
        self.read(task,error='42501')

    def test_dedupe_stale_revision_changed_key_and_overflow(self):
        key=str(uuid.uuid4());r=self.call(self.intent,key);task=r['id']
        self.call(self.intent,error='40001')
        self.call({'action':'create','payload':{**self.intent['payload'],'timezone':'UTC'}},key,error='22023')
        self.call(self.mutate('disable',task,0),error='22023')
        self.call(self.mutate('disable',task,2),error='40001')
        self.call(self.mutate('disable',task,2147483648),error='22023')
        # Owner-only synthetic fixture at revision limit; not a supported mutation path.
        self.sql(f"BEGIN; ALTER TABLE catalog_report_schedules DISABLE TRIGGER catalog_report_immutable; INSERT INTO catalog_report_schedule_revisions SELECT schedule_id,2147483647,changed_by_account_id,'disable',schedule,timezone,enabled,archived_at,created_at FROM catalog_report_schedule_revisions WHERE schedule_id='{task}'; UPDATE catalog_report_schedules SET revision=2147483647 WHERE id='{task}'; SET CONSTRAINTS ALL IMMEDIATE; ALTER TABLE catalog_report_schedules ENABLE TRIGGER catalog_report_immutable; COMMIT")
        self.call(self.mutate('disable',task,2147483647),error='22003')

    def test_rollback_and_role_boundaries(self):
        key=str(uuid.uuid4());r=self.call(self.intent,key,prefix='BEGIN;',suffix='ROLLBACK;')
        self.assertEqual(self.sql(f"SELECT count(*) FROM catalog_report_schedules WHERE id='{r['id']}'"),'0')
        for role in ['anon','authenticated']:
            self.sql(f"SET ROLE {role}; SELECT read_catalog_report_schedule('{self.actor}',{quote(json.dumps(self.principal))},'{uuid.uuid4()}')",'42501')
        for statement in ['SELECT * FROM catalog_report_schedules','DELETE FROM catalog_report_mutation_receipts','TRUNCATE catalog_report_schedule_revisions','UPDATE catalog_report_schedules SET enabled=true']:
            self.sql('SET ROLE service_role;'+statement,'42501')
        r=self.call(self.intent);task=r['id']
        self.sql(f"UPDATE catalog_report_schedules SET enabled=true,revision=revision+1 WHERE id='{task}'",'23514')
        self.sql(f"UPDATE catalog_report_schedules SET actor_account_id='{self.org}' WHERE id='{task}'",'42501')
        self.sql(f"UPDATE catalog_report_schedule_revisions SET timezone='UTC' WHERE schedule_id='{task}'",'42501')

    def test_concurrent_receipt_and_business_keys(self):
        key=str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=2) as pool: rs=list(pool.map(lambda _:self.call(self.intent,key),range(2)))
        self.assertEqual(rs[0]['id'],rs[1]['id']);self.assertEqual(sorted(r['replayed'] for r in rs),[False,True])
        task=rs[0]['id']; key2=str(uuid.uuid4());cmd=self.mutate('disable',task,1)
        with ThreadPoolExecutor(max_workers=2) as pool: rs=list(pool.map(lambda _:self.call(cmd,key2),range(2)))
        self.assertEqual([r['revision'] for r in rs],[2,2])
        self.assertEqual(self.sql(f"SELECT count(*) FROM catalog_report_schedule_revisions WHERE schedule_id='{task}'"),'2')
        self.call(self.mutate('archive',task,2))
        def new(_):
            try:return self.call(self.intent)['id']
            except AssertionError as e:
                self.assertIn('40001',str(e));return 'conflict'
        with ThreadPoolExecutor(max_workers=2) as pool:rs=list(pool.map(new,range(2)))
        self.assertEqual(rs.count('conflict'),1)

    def test_dependency_rls_and_nologin_owner_cannot_write(self):
        self.assertEqual(self.sql("SELECT rolcanlogin OR rolbypassrls FROM pg_roles WHERE rolname='catalog_report_owner'"),'f')
        self.assertEqual(self.sql("SELECT count(*) FROM pg_class WHERE relname IN ('accounts','catalogs','account_catalogs','account_organization_ids') AND relrowsecurity"),'4')
        self.sql(f"SET ROLE catalog_report_owner; UPDATE accounts SET id=id WHERE id='{self.actor}'",'42501')
        self.sql(f"SET ROLE catalog_report_owner; UPDATE account_catalogs SET account=account WHERE account='{self.actor}'",'42501')
        self.sql('SET SESSION AUTHORIZATION service_role; SET ROLE catalog_report_owner','42501')
        self.sql(f"SET ROLE anon; SELECT * FROM account_catalogs",'42501')
        self.sql(f"SET ROLE service_role; SELECT catalog_report_response('{uuid.uuid4()}',1,false)",'42501')

    def test_changed_receipt_key_and_cas_concurrency(self):
        key=str(uuid.uuid4());other={'action':'create','payload':{**self.intent['payload'],'timezone':'UTC'}}
        def attempt(command):
            try:return self.call(command,key)
            except AssertionError as e:
                self.assertIn('22023',str(e));return None
        with ThreadPoolExecutor(max_workers=2) as pool: rs=list(pool.map(attempt,[self.intent,other]))
        self.assertEqual(sum(r is None for r in rs),1);task=next(r['id'] for r in rs if r)
        def cas(_):
            try:return self.call(self.mutate('disable',task,1))
            except AssertionError as e:
                self.assertIn('40001',str(e));return None
        with ThreadPoolExecutor(max_workers=2) as pool: rs=list(pool.map(cas,range(2)))
        self.assertEqual(sum(r is None for r in rs),1)
        self.assertEqual(self.read(task)['revision'],2)

    def test_receipt_replay_needs_current_access_and_isolation(self):
        key=str(uuid.uuid4());r=self.call(self.intent,key)
        self.sql(f"DELETE FROM account_catalogs WHERE account='{self.actor}'")
        self.call(self.intent,key,error='42501')
        self.sql(f"INSERT INTO account_catalogs(account,catalog) VALUES ('{self.actor}','{self.catalog}')")
        self.call(self.mutate('disable',r['id'],1),prefix='BEGIN ISOLATION LEVEL REPEATABLE READ;',error='25001')
        self.assertEqual(self.read(r['id'])['revision'],1)

    def test_membership_revocation_waits_for_admitted_transaction(self):
        cmd={'action':'create','payload':{**self.intent['payload'],'organization_id':self.org}}
        task=self.call(cmd)['id']
        args=[str(BIN/'psql'),'-h',self.tmp.name,'-p','55476','-d','postgres','-XqAt','-v','ON_ERROR_STOP=1']
        a=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        b=None
        try:
            a.stdin.write(f"BEGIN; SET ROLE service_role; SELECT read_catalog_report_schedule('{self.actor}',{quote(json.dumps(self.principal))},'{task}');\n");a.stdin.flush()
            self.assertEqual(json.loads(a.stdout.readline())['id'],task)
            label='catalog-revoke-'+str(uuid.uuid4())
            b=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'PGAPPNAME':label})
            b.stdin.write(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}';\n");b.stdin.close()
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                if self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{label}' AND wait_event_type='Lock'")=='1':break
                time.sleep(.01)
            else:self.fail('Revocation did not wait for admitted membership lock')
            a.stdin.write('COMMIT;\n');a.stdin.close();self.assertEqual(a.wait(timeout=5),0)
            self.assertEqual(b.wait(timeout=5),0)
            self.read(task,error='42501')
        finally:
            for proc in [a,b]:
                if proc and proc.poll() is None:proc.kill();proc.wait()
                if proc:
                    for stream in [proc.stdin,proc.stdout,proc.stderr]:
                        if stream and not stream.closed:stream.close()

    def test_permissive_policy_cannot_reenable_dependency_owner_writes(self):
        self.sql('CREATE POLICY synthetic_permissive ON accounts FOR UPDATE TO PUBLIC USING(true) WITH CHECK(true)')
        try:
            self.sql(f"SET ROLE catalog_report_owner; UPDATE accounts SET id=id WHERE id='{self.actor}'",'42501')
        finally:
            self.sql('DROP POLICY synthetic_permissive ON accounts')

    def test_archive_requires_disabled_state_not_prior_disable_command(self):
        r=self.call(self.intent)
        archived=self.call(self.mutate('archive',r['id'],1))
        self.assertEqual(archived['revision'],2)
        self.assertFalse(archived['enabled'])
        self.assertEqual(self.sql(f"SELECT string_agg(operation,',' ORDER BY revision) FROM catalog_report_schedule_revisions WHERE schedule_id='{r['id']}'"),'create,archive')

    def test_teardown_is_scoped_and_reinstallation_is_empty(self):
        original = self.sql("SELECT count(*) FROM accounts")
        self.call(self.intent)
        self.sql((HERE/'disabled-rollback.sql').read_text())
        self.assertEqual(self.sql("SELECT count(*) FROM accounts"), original)
        self.assertEqual(self.sql("SELECT count(*) FROM pg_roles WHERE rolname='catalog_report_owner'"),'0')
        self.assertEqual(self.sql("SELECT count(*) FROM pg_policies WHERE policyname LIKE 'catalog_report_owner_%'"),'0')
        self.sql((HERE/'disabled-storage.sql').read_text())
        self.assertEqual(self.sql('SELECT count(*) FROM catalog_report_schedules'),'0')

    def test_privy_is_management_observation_only_and_no_execution_functions(self):
        p={'mechanism':'privy','app_id':'synthetic-app','issuer':'synthetic-issuer','subject':'did:privy:synthetic'}
        r=self.call(self.intent,principal=p);self.assertFalse(self.read(r['id'],principal=p)['enabled'])
        funcs=self.sql("SELECT proname FROM pg_proc JOIN pg_namespace n ON n.oid=pronamespace WHERE n.nspname='public' AND proname LIKE '%catalog_report%' ORDER BY proname")
        self.assertNotIn('dispatch',funcs);self.assertNotIn('enable',funcs);self.assertNotIn('claim',funcs)
        self.assertEqual(self.sql("SELECT count(*) FROM information_schema.tables WHERE table_name='catalog_report_occurrences'"),'0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
