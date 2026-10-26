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
        cls.sql("CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated; CREATE TABLE accounts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, timestamp bigint); CREATE TABLE account_organization_ids(account_id uuid,organization_id uuid,updated_at timestamptz); GRANT USAGE ON SCHEMA public TO service_role; GRANT SELECT ON account_organization_ids TO service_role;")
        cls.sql('''CREATE TABLE account_info(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid REFERENCES accounts(id), updated_at timestamptz DEFAULT now());
        CREATE TABLE account_artist_ids(account_id uuid REFERENCES accounts(id), artist_id uuid REFERENCES accounts(id), UNIQUE(account_id,artist_id));
        CREATE TABLE artist_organization_ids(artist_id uuid REFERENCES accounts(id), organization_id uuid REFERENCES accounts(id), UNIQUE(artist_id,organization_id));
        GRANT SELECT,INSERT ON accounts,account_info,account_artist_ids,artist_organization_ids TO service_role;''')
        cls.sql((ROOT/'supabase/migrations/20261008020000_onboard_artists_atomically.sql').read_text())
        cls.sql(next((ROOT/'supabase/migrations').glob('20250129222308*')).read_text().split('alter table')[0])
        cls.sql((ROOT/'supabase/migrations/20261008030000_onboarding_membership_lock_privilege.sql').read_text())
        for migration in sorted((ROOT/'supabase/migrations').glob('20261008050*.sql')):
            cls.sql(migration.read_text())
        migration = ROOT/'supabase/migrations/20261024002432_professional_artist_accounts.sql'
        if migration.exists() and getattr(cls, "apply_account_migration", True):
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
        self.sql(f"TRUNCATE accounts,account_organization_ids CASCADE; INSERT INTO accounts(id) VALUES ('{ACTOR}'),('{ORG}'),('{OTHER}'); INSERT INTO account_organization_ids VALUES ('{ACTOR}','{ORG}',now());")

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

    def test_new_roles_create_artist_account_and_picker_relationship(self):
        person=self.command()['professional']
        self.assertEqual(person['roles'],['producer','songwriter'])
        self.assertEqual(person['organization_id'],ORG)
        self.assertEqual(person['confirmed_by'],ACTOR)
        self.assertEqual(person['confirmation_basis'],'operator_confirmed')
        artist = person['artist_id']
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'4')
        self.assertEqual(self.sql(f"SELECT name FROM accounts WHERE id='{artist}'"),'Same Name')
        self.assertEqual(self.sql(f"SELECT count(*) FROM account_info WHERE account_id='{artist}'"),'1')
        self.assertEqual(self.sql(f"SELECT count(*) FROM account_artist_ids WHERE account_id='{ACTOR}' AND artist_id='{artist}'"),'1')
        self.assertEqual(self.sql(f"SELECT a.name FROM artist_organization_ids r JOIN accounts a ON a.id=r.artist_id WHERE r.organization_id='{ORG}'"),'Same Name')
        self.assertEqual(self.listing()['professionals'][0]['id'],person['id'])

    def test_retries_and_parallel_requests_return_one_record(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(lambda _: self.command(),range(16)))
        self.assertTrue(all(r==results[0] for r in results))
        self.assertEqual(self.sql('SELECT count(*) FROM organization_professionals'),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM professional_roster_requests'),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'4')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'),'1')
        self.assertIn('different input',self.command({'name':'Different'},fails=True))

    def test_existing_adds_roles_without_renaming(self):
        person=self.command({'roles':['songwriter']})['professional']
        result=self.command({'mode':'existing','professional_id':person['id'],'roles':['producer'],'name':'Ignored'},key=OTHER)
        self.assertFalse(result['created'])
        self.assertEqual(result['professional']['artist_id'],person['artist_id'])
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'4')
        self.assertEqual(result['professional']['name'],'Same Name')
        self.assertEqual(result['professional']['roles'],['producer','songwriter'])

    def test_existing_professional_restores_artist_roster_membership(self):
        person=self.command()['professional']
        self.sql('DELETE FROM artist_organization_ids; DELETE FROM account_artist_ids')
        result=self.command({'mode':'existing','professional_id':person['id']},key=OTHER)
        self.assertEqual(result['professional']['artist_id'],person['artist_id'])
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'4')

    def test_same_names_are_candidates_not_automatic_identity(self):
        one=self.command()['professional']['id']
        two=self.command(key=OTHER)['professional']['id']
        self.assertNotEqual(one,two)
        self.assertEqual(len(self.listing()['professionals']),2)
        self.assertIn('Select an existing',self.command({'mode':'existing'},key=ORG,fails=True))

    def test_explicit_intent_confirmation_and_valid_roles_required(self):
        for patch in [{'confirmed':False},{'roster_intent':'research'},{'roles':[]},{'roles':['owner']},{'roles':[None]},{'name':' '},{'name':'a'},{'name':123},{'name':{'text':'Name'}}]:
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
            self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'3')
            self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'),'0')
        finally:
            self.sql('ALTER TABLE professional_roster_requests DROP CONSTRAINT fixture_fail')

    def test_client_roles_cannot_read_or_execute(self):
        for role in ['anon','authenticated']:
            for statement in ['SELECT * FROM organization_professionals','SELECT * FROM professional_roster_requests',f"SELECT list_professional_roster('{ACTOR}','{ORG}')",f"SELECT confirm_professional_roster('{ACTOR}','{ORG}','{KEY}','{{}}')"]:
                self.assertIn('permission denied',self.sql(f'SET ROLE {role}; {statement};',fails=True))

    def test_cursor_pagination_has_no_missing_records(self):
        self.sql(f"SELECT confirm_professional_roster('{ACTOR}','{ORG}',gen_random_uuid(),jsonb_build_object('mode','new','name','Synthetic '||n,'roles',jsonb_build_array('songwriter'),'roster_intent','add','confirmed',true)) FROM generate_series(1,102) n")
        page1=self.listing();page2=self.listing(after=page1['next_cursor'])
        self.assertEqual(len(page1['professionals']),100)
        self.assertEqual(len(page2['professionals']),2)
        self.assertIsNone(page2['next_cursor'])
        self.assertEqual(len({p['id'] for p in page1['professionals']+page2['professionals']}),102)

    def test_table_rejects_invalid_names_and_duplicate_roles(self):
        for name,roles in [("  ","ARRAY['songwriter']"),("Valid", "ARRAY['songwriter','songwriter']")]:
            self.sql(f"SET ROLE service_role; INSERT INTO organization_professionals(organization_id,name,roles,confirmed_by,artist_id) VALUES ('{ORG}','{name}',{roles},'{ACTOR}','{OTHER}')",fails=True)

    def test_direct_update_refreshes_timestamp(self):
        person=self.command()['professional']
        self.sql(f"SET ROLE service_role; UPDATE organization_professionals SET updated_at='2000-01-01' WHERE id='{person['id']}'")
        self.assertEqual(self.sql("SELECT count(*) FROM organization_professionals WHERE updated_at > '2026-01-01'"),'1')


class ProfessionalUpgrade(unittest.TestCase):
    """Apply the forward migration to old records and replay old receipts."""
    apply_account_migration = False
    setUpClass = classmethod(ProfessionalRoster.setUpClass.__func__)
    stop = classmethod(ProfessionalRoster.stop.__func__)
    sql = classmethod(ProfessionalRoster.sql.__func__)
    setUp = ProfessionalRoster.setUp
    command = ProfessionalRoster.command
    listing = ProfessionalRoster.listing

    def test_backfill_preserves_confirmed_identity_and_old_receipts(self):
        first = self.command()['professional']
        second = self.command(key=OTHER)['professional']
        sidney_actor = '1ca89eeb-14ab-4a4a-a1c5-2dd41663c039'
        sidney_org = '14524163-fd59-4d49-b58f-bd739b1bc0b5'
        sidney_artist = '9b16358d-6d2d-4f3c-a69f-625dbd7bf74a'
        sidney_professional = 'c73c1ca6-971f-44e9-ad7a-b00e5e57a35f'
        # Fixed identifiers exercise the explicit repair; all records are synthetic.
        self.sql(f"""
          INSERT INTO accounts(id,name) VALUES
            ('{sidney_actor}','Fixture operator'),('{sidney_org}','Fixture label'),
            ('{sidney_artist}','Fixture existing artist');
          INSERT INTO account_info(account_id) VALUES ('{sidney_artist}');
          INSERT INTO organization_professionals(id,organization_id,name,roles,confirmed_by)
            VALUES ('{sidney_professional}','{sidney_org}','Fixture professional',ARRAY['songwriter','producer'],'{sidney_actor}');
        """)
        migration = (ROOT/'supabase/migrations/20261024002432_professional_artist_accounts.sql').read_text()
        self.assertIn('prerequisites changed',self.sql('BEGIN;'+migration+'COMMIT;',fails=True))
        self.assertEqual(self.sql("SELECT count(*) FROM information_schema.columns WHERE table_name='organization_professionals' AND column_name='artist_id'"),'0')
        self.sql(f"INSERT INTO account_artist_ids VALUES ('{sidney_actor}','{sidney_artist}')")
        # A revoked confirmer must not block organization-owned legacy backfill.
        self.sql('DELETE FROM account_organization_ids')
        self.sql('BEGIN;'+migration+'COMMIT;')
        self.assertEqual(self.sql(f"SELECT artist_id FROM organization_professionals WHERE id='{sidney_professional}'"),sidney_artist)
        self.assertEqual(self.sql(f"SELECT count(*) FROM artist_organization_ids WHERE artist_id='{sidney_artist}' AND organization_id='{sidney_org}'"),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'8')
        self.assertEqual(self.sql(f"SELECT count(*) FROM account_artist_ids WHERE account_id='{ACTOR}'"),'0')
        self.sql(f"INSERT INTO account_organization_ids VALUES ('{ACTOR}','{ORG}',now())")
        replay = self.command()['professional']
        self.assertEqual(replay['id'],first['id'])
        self.assertEqual(replay['roles'],first['roles'])
        self.assertEqual(self.sql(f"SELECT artist_id FROM organization_professionals WHERE id='{first['id']}'"),replay['artist_id'])
        other_artist = self.sql(f"SELECT artist_id FROM organization_professionals WHERE id='{second['id']}'")
        self.assertNotEqual(other_artist,replay['artist_id'])
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'),'8')
        self.assertEqual(len(self.listing()['professionals']),2)
