"""Organization-private professional onboarding on disposable PostgreSQL."""
import concurrent.futures
import json
import pathlib
import subprocess
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
ACTOR = '10000000-0000-4000-8000-000000000001'
ORG = '10000000-0000-4000-8000-000000000002'
OTHER = '10000000-0000-4000-8000-000000000003'
KEY = '20000000-0000-4000-8000-000000000001'

class ProfessionalRoster(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-professionals-')
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb','-D',str(cls.cluster),'-A','trust'],check=True,capture_output=True)
        subprocess.run(['pg_ctl','-D',str(cls.cluster),'-l',str(pathlib.Path(cls.tmp.name)/'pg.log'),'-o',f"-k {cls.tmp.name} -p 55439 -c listen_addresses=''",'-w','start'],check=True,capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql("CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated; CREATE TABLE accounts(id uuid PRIMARY KEY); CREATE TABLE account_organization_ids(account_id uuid,organization_id uuid,updated_at timestamptz); GRANT USAGE ON SCHEMA public TO service_role; GRANT SELECT ON account_organization_ids TO service_role;")
        cls.sql((ROOT/'supabase/migrations/20261008030000_onboarding_membership_lock_privilege.sql').read_text())
        for migration in sorted((ROOT/'supabase/migrations').glob('20261008050*.sql')):
            cls.sql(migration.read_text())
    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'], check=True, capture_output=True)
        cls.tmp.cleanup()

    @classmethod
    def sql(cls, sql, fails=False):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55439', '-d', 'postgres', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', sql], text=True, capture_output=True)
        if fails:
            if result.returncode == 0:
                raise AssertionError('Expected SQL failure')
            return result.stderr
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.sql(f"TRUNCATE accounts,account_organization_ids CASCADE; INSERT INTO accounts VALUES ('{ACTOR}'),('{ORG}'),('{OTHER}'); INSERT INTO account_organization_ids VALUES ('{ACTOR}','{ORG}',now());")

    def command(self, patch=None, key=KEY, actor=ACTOR, org=ORG, fails=False):
        data={'mode':'new','name':'Same Name','roles':['songwriter','producer'],'roster_intent':'add','confirmed':True}
        data.update(patch or {})
        encoded=json.dumps(data).replace("'","''")
        result=self.sql(f"SET ROLE service_role; SELECT confirm_professional_roster('{actor}','{org}','{key}','{encoded}'::jsonb);",fails=fails)
        return result if fails else json.loads(result.splitlines()[-1])

    def listing(self, org=ORG, after=None, actor=ACTOR, fails=False):
        cursor=f"'{after}'" if after else 'NULL'
        result=self.sql(f"SET ROLE service_role; SELECT list_professional_roster('{actor}','{org}',{cursor});",fails=fails)
        return result if fails else json.loads(result.splitlines()[-1])

    def test_new_roles_scope_confirmation_and_no_login(self):
        person=self.command()['professional']
        self.assertEqual(person['roles'],['producer','songwriter'])
        self.assertEqual(person['organization_id'],ORG)
        self.assertEqual(person['confirmed_by'],ACTOR)
        self.assertEqual(person['confirmation_basis'],'operator_confirmed')
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'3')
        self.assertEqual(self.listing()['professionals'][0]['id'],person['id'])

    def test_retries_and_parallel_requests_return_one_record(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(lambda _: self.command(),range(16)))
        self.assertTrue(all(r==results[0] for r in results))
        self.assertEqual(self.sql('SELECT count(*) FROM organization_professionals'),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM professional_roster_requests'),'1')
        self.assertIn('different input',self.command({'name':'Different'},fails=True))

    def test_existing_adds_roles_without_renaming(self):
        person=self.command({'roles':['songwriter']})['professional']
        result=self.command({'mode':'existing','professional_id':person['id'],'roles':['producer'],'name':'Ignored'},key=OTHER)
        self.assertFalse(result['created'])
        self.assertEqual(result['professional']['name'],'Same Name')
        self.assertEqual(result['professional']['roles'],['producer','songwriter'])

    def test_same_names_are_candidates_not_automatic_identity(self):
        one=self.command()['professional']['id']
        two=self.command(key=OTHER)['professional']['id']
        self.assertNotEqual(one,two)
        self.assertEqual(len(self.listing()['professionals']),2)
        self.assertIn('Select an existing',self.command({'mode':'existing'},key=ORG,fails=True))

    def test_explicit_intent_confirmation_and_valid_roles_required(self):
        for patch in [{'confirmed':False},{'roster_intent':'research'},{'roles':[]},{'roles':['owner']},{'roles':[None]},{'name':' '},{'name':'a'}]:
            self.command(patch,key=OTHER,fails=True)
        self.assertEqual(self.sql('SELECT count(*) FROM organization_professionals'),'0')

    def test_denied_revoked_and_cross_workspace_identity(self):
        person=self.command()['professional']
        self.assertIn('access denied',self.listing(org=OTHER,fails=True))
        self.sql(f"INSERT INTO account_organization_ids VALUES ('{ACTOR}','{OTHER}',now())")
        self.assertEqual(self.listing(org=OTHER)['professionals'],[])
        self.assertIn('not in this organization',self.command({'mode':'existing','professional_id':person['id']},org=OTHER,fails=True))
        self.sql('DELETE FROM account_organization_ids')
        self.assertIn('access denied',self.command(fails=True))
        self.assertIn('access denied',self.listing(fails=True))

    def test_request_failure_rolls_back_profile(self):
        self.sql('ALTER TABLE professional_roster_requests ADD CONSTRAINT fixture_fail CHECK(false) NOT VALID')
        try:
            self.assertIn('fixture_fail',self.command(fails=True))
            self.assertEqual(self.sql('SELECT count(*) FROM organization_professionals'),'0')
        finally:
            self.sql('ALTER TABLE professional_roster_requests DROP CONSTRAINT fixture_fail')

    def test_client_roles_cannot_read_or_execute(self):
        for role in ['anon','authenticated']:
            for statement in ['SELECT * FROM organization_professionals','SELECT * FROM professional_roster_requests',f"SELECT list_professional_roster('{ACTOR}','{ORG}')",f"SELECT confirm_professional_roster('{ACTOR}','{ORG}','{KEY}','{{}}')"]:
                self.assertIn('permission denied',self.sql(f'SET ROLE {role}; {statement};',fails=True))

    def test_cursor_pagination_has_no_missing_records(self):
        self.sql(f"INSERT INTO organization_professionals(organization_id,name,roles,confirmed_by) SELECT '{ORG}','Synthetic '||n,ARRAY['songwriter'],'{ACTOR}' FROM generate_series(1,102) n")
        page1=self.listing();page2=self.listing(after=page1['next_cursor'])
        self.assertEqual(len(page1['professionals']),100)
        self.assertEqual(len(page2['professionals']),2)
        self.assertIsNone(page2['next_cursor'])
        self.assertEqual(len({p['id'] for p in page1['professionals']+page2['professionals']}),102)
