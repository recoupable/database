"""Metadata-review transactions on disposable PostgreSQL, without hosted credentials."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = [
    '20260920010000_context_foundation.sql',
    '20260920020000_context_spotify_pipeline.sql',
    '20260924050000_context_release_verification_scope.sql',
    '20260924060000_context_release_track_slots.sql',
    '20260924070000_context_release_track_read.sql',
    '20260924110000_context_release_track_identity_review.sql',
    '20261008030000_onboarding_membership_lock_privilege.sql',
    '20261008160000_context_release_cases.sql',
    '20261008160100_context_release_case_cursor.sql',
]


class ReleaseCases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-cases-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', str(pathlib.Path(cls.tmp.name) / 'pg.log'),
                        '-o', f"-k {cls.tmp.name} -p 55473 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql('''
            CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
            CREATE SCHEMA storage;
            CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint);
            CREATE TABLE storage.objects(id uuid PRIMARY KEY,bucket_id text);
            CREATE TABLE public.accounts(id uuid PRIMARY KEY,name text);
            CREATE TABLE public.songs(isrc text PRIMARY KEY);
            CREATE TABLE public.account_organization_ids(account_id uuid,organization_id uuid,updated_at timestamptz DEFAULT now());
            GRANT USAGE ON SCHEMA public TO service_role;
            GRANT SELECT ON public.account_organization_ids TO service_role;
        ''')
        for migration in MIGRATIONS:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def sql(cls, sql):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55473', '-d', 'postgres',
                                 '-XAt', '-v', 'ON_ERROR_STOP=1'],
                                input=sql, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result

    def test_review_lifecycle_and_access(self):
        result = self.sql((ROOT / 'supabase/tests/context_release_cases.sql').read_text())
        self.assertIn('PASS:', result.stderr)
