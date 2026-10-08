"""Disposable PostgreSQL fixture tests; no hosted database or credentials used.
Run: python3 -m unittest discover -s tests -p 'test_spotify_onboarding.py'
Requires PostgreSQL initdb, pg_ctl and psql on PATH.
"""
import concurrent.futures
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = ROOT / 'supabase/migrations/20261008020000_onboard_artists_atomically.sql'
ACTOR = '10000000-0000-4000-8000-000000000001'
ORG = '10000000-0000-4000-8000-000000000002'
ARTIST = '10000000-0000-4000-8000-000000000003'
SPOTIFY = 'AbCdEfGhIjKlMnOpQrStUv'

class SpotifyOnboarding(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-onboarding-')
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', str(pathlib.Path(cls.tmp.name) / 'pg.log'),
                        '-o', f"-k {cls.tmp.name} -p 55439 -c listen_addresses=''", '-w', 'start'], check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql('''
        CREATE ROLE service_role; CREATE ROLE anon; CREATE ROLE authenticated;
        CREATE TABLE accounts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, timestamp bigint DEFAULT extract(epoch from now()));
        CREATE TABLE account_info (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid REFERENCES accounts(id),
          updated_at timestamptz NOT NULL DEFAULT now(), image text, knowledges jsonb DEFAULT '[]'::jsonb,
          label text, instruction text, organization text, job_title text, role_type text, company_name text
        );
        CREATE TABLE account_organization_ids (account_id uuid REFERENCES accounts(id), organization_id uuid REFERENCES accounts(id));
        CREATE TABLE socials (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), username text NOT NULL, profile_url text NOT NULL UNIQUE);
        CREATE TABLE account_socials (account_id uuid REFERENCES accounts(id), social_id uuid REFERENCES socials(id), UNIQUE(account_id, social_id));
        CREATE TABLE account_artist_ids (account_id uuid REFERENCES accounts(id), artist_id uuid REFERENCES accounts(id), UNIQUE(account_id, artist_id));
        CREATE TABLE artist_organization_ids (artist_id uuid REFERENCES accounts(id), organization_id uuid REFERENCES accounts(id), UNIQUE(artist_id, organization_id));
        GRANT USAGE ON SCHEMA public TO service_role;
        GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
        ''')
        cls.sql((ROOT / 'supabase/migrations/20250528095512_socials_profile_url_clean_trigger.sql').read_text())
        cls.sql((ROOT / 'supabase/migrations/20260805190000_preserve_youtube_channel_url_case.sql').read_text())
        cls.sql((ROOT / 'supabase/migrations/20261008010000_onboard_spotify_artist.sql').read_text())
        cls.sql(MIGRATION.read_text())

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
        self.sql(f"TRUNCATE accounts, socials CASCADE; INSERT INTO accounts(id,name) VALUES ('{ACTOR}','Operator'), ('{ORG}','Label'); INSERT INTO account_organization_ids VALUES ('{ACTOR}','{ORG}');")

    def call(self, spotify=SPOTIFY, fails=False):
        result = self.sql(f"SET ROLE service_role; SELECT artist_id, created FROM onboard_spotify_artist('{ACTOR}', '{ORG}', 'Same name', '{spotify}');", fails=fails)
        return result if fails else result.splitlines()[-1]

    def test_new_existing_and_retries(self):
        first = self.call().split('|')
        self.assertEqual(first[1], 't')
        self.assertEqual(self.call(), first[0] + '|f')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '1')

    def test_existing_exact_identity(self):
        self.sql(f"INSERT INTO accounts VALUES ('{ARTIST}','Original name'); INSERT INTO socials(username,profile_url) VALUES ('{SPOTIFY}','https://open.spotify.com/artist/{SPOTIFY}?si=fixture'); INSERT INTO account_socials SELECT '{ARTIST}',id FROM socials;")
        self.assertEqual(self.call(), ARTIST + '|f')
        self.assertEqual(self.sql(f"SELECT name FROM accounts WHERE id='{ARTIST}'"), 'Original name')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')

    def test_same_name_case_distinct_provider_ids(self):
        one = self.call().split('|')[0]
        two = self.call(SPOTIFY.lower()).split('|')[0]
        self.assertNotEqual(one, two)

    def test_concurrent_new_submissions(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.call(), range(16)))
        self.assertEqual(len({r.split('|')[0] for r in results}), 1)
        self.assertEqual(sum(r.endswith('|t') for r in results), 1)
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')

    def test_revoked_and_unauthorized(self):
        self.sql('DELETE FROM account_organization_ids')
        self.assertIn('Access denied', self.call(fails=True))
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')

    def test_ambiguous_mapping_fails_without_mutation(self):
        self.call()
        self.sql(f"INSERT INTO accounts VALUES ('{ARTIST}','Same name'); INSERT INTO account_socials SELECT '{ARTIST}', id FROM socials;")
        self.assertIn('ambiguous', self.call(fails=True))
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '1')

    def test_attachment_failure_rolls_back_then_retry(self):
        self.sql("ALTER TABLE artist_organization_ids ADD CONSTRAINT fixture_failure CHECK (false) NOT VALID")
        try:
            self.assertIn('fixture_failure', self.call(fails=True))
            self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')
            self.assertEqual(self.sql('SELECT count(*) FROM socials'), '0')
        finally:
            self.sql('ALTER TABLE artist_organization_ids DROP CONSTRAINT fixture_failure')
        self.assertTrue(self.call().endswith('|t'))

    def test_untrusted_database_roles_cannot_execute(self):
        for role in ('anon', 'authenticated'):
            error = self.sql(f"SET ROLE {role}; SELECT * FROM onboard_spotify_artist('{ACTOR}', '{ORG}', 'Same name', '{SPOTIFY}');", fails=True)
            self.assertIn('permission denied', error)

    def test_lookup_failure_never_creates(self):
        self.sql('REVOKE SELECT ON account_socials FROM service_role')
        try:
            self.assertIn('permission denied', self.call(fails=True))
            self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')
        finally:
            self.sql('GRANT SELECT ON account_socials TO service_role')

    def test_personal_then_organization_retry_reuses_identity(self):
        result = self.sql(f"SET ROLE service_role; SELECT artist_id FROM onboard_spotify_artist('{ACTOR}', NULL, 'Same name', '{SPOTIFY}');").splitlines()[-1]
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '0')
        self.assertEqual(self.call(), result + '|f')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')

    def test_spotify_uri_reuses_verified_resource(self):
        self.sql(f"INSERT INTO accounts VALUES ('{ARTIST}','Original name'); ALTER TABLE socials DISABLE TRIGGER trigger_clean_socials_profile_url; INSERT INTO socials(username,profile_url) VALUES ('{SPOTIFY}','spotify:artist:{SPOTIFY}'); ALTER TABLE socials ENABLE TRIGGER trigger_clean_socials_profile_url; INSERT INTO account_socials SELECT '{ARTIST}',id FROM socials;")
        self.assertEqual(self.call(), ARTIST + '|f')

    def test_non_spotify_host_is_not_identity_evidence(self):
        self.sql(f"INSERT INTO accounts VALUES ('{ARTIST}','Same name'); INSERT INTO socials(username,profile_url) VALUES ('{SPOTIFY}','https://example.invalid/artist/{SPOTIFY}'); INSERT INTO account_socials SELECT '{ARTIST}',id FROM socials;")
        self.assertNotEqual(self.call().split('|')[0], ARTIST)

    def test_committed_spotify_social_is_persisted(self):
        artist = self.call().split('|')[0]
        self.assertEqual(self.sql(f"SELECT s.profile_url FROM socials s JOIN account_socials a ON a.social_id=s.id WHERE a.account_id='{artist}'"), f'open.spotify.com/artist/{SPOTIFY}')

    def test_name_only_creation_rolls_back_on_attachment_failure(self):
        self.sql("ALTER TABLE artist_organization_ids ADD CONSTRAINT fixture_failure CHECK (false) NOT VALID")
        try:
            self.sql(f"SET ROLE service_role; SELECT create_artist_with_roster('{ACTOR}', '{ORG}', 'Manual Artist');", fails=True)
            self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')
        finally:
            self.sql('ALTER TABLE artist_organization_ids DROP CONSTRAINT fixture_failure')
        self.sql(f"SET ROLE service_role; SELECT create_artist_with_roster('{ACTOR}', '{ORG}', 'Manual Artist');")
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')

    def test_name_only_creation_rejects_nonmember(self):
        self.sql('DELETE FROM account_organization_ids')
        error = self.sql(f"SET ROLE service_role; SELECT create_artist_with_roster('{ACTOR}', '{ORG}', 'Manual Artist');", fails=True)
        self.assertIn('Access denied', error)
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')

    def test_name_only_response_preserves_profile_shape(self):
        response = self.sql(f"SET ROLE service_role; SELECT create_artist_with_roster('{ACTOR}', '{ORG}', 'Manual Artist');").splitlines()[-1]
        artist = json.loads(response)
        self.assertEqual(artist['account_id'], artist['id'])
        self.assertEqual(artist['name'], 'Manual Artist')
        self.assertIsInstance(artist['timestamp'], int)
        self.assertEqual(artist['account_socials'], [])
        info = artist['account_info'][0]
        self.assertIsInstance(info['id'], str)
        self.assertEqual(info['account_id'], artist['id'])
        self.assertIsInstance(info['updated_at'], str)
        self.assertEqual(info['knowledges'], [])
        self.assertEqual(self.sql(f"SELECT count(*) FROM artist_organization_ids WHERE artist_id='{artist['id']}' AND organization_id='{ORG}'"), '1')
