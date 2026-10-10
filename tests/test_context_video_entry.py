"""Single-video YouTube locator transactions on disposable PostgreSQL, without hosted credentials or provider calls."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# The actual Context entry chain, so the video subject is checked against the current
# constraint set rather than only the original foundation.
MIGRATIONS = [
    '20260920010000_context_foundation.sql',
    '20260920020000_context_spotify_pipeline.sql',
    '20260922070000_context_catalog_entry.sql',
    '20260924040000_context_release_entry.sql',
    '20260925100000_context_songwriter_name_entry.sql',
    '20260925110000_context_company_name_entry.sql',
    '20260925120000_context_campaign_brief_entry.sql',
    '20260925130000_context_supporting_text_entry.sql',
    '20261010213100_context_video_entry.sql',
]
PORT = '52131'
FUNCTION = 'public.create_context_video_request(uuid,uuid,text,text)'


class ContextVideoEntry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-video-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', str(pathlib.Path(cls.tmp.name) / 'pg.log'),
                        '-o', f"-k {cls.tmp.name} -p {PORT} -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql('''
            CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
            CREATE SCHEMA storage;
            CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint);
            CREATE TABLE storage.objects(id uuid PRIMARY KEY,bucket_id text);
            CREATE TABLE public.accounts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text);
            CREATE TABLE public.songs(isrc text PRIMARY KEY,name text,album text);
            CREATE TABLE public.song_identifiers(song text,platform text,identifier_type text,value text);
            CREATE TABLE public.account_artist_ids(account_id uuid,artist_id uuid);
            CREATE TABLE public.catalogs(id uuid PRIMARY KEY,name text,updated_at timestamptz DEFAULT now());
            CREATE TABLE public.account_catalogs(account uuid,catalog uuid);
            GRANT USAGE ON SCHEMA public TO service_role;
        ''')
        for migration in MIGRATIONS:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def sql(cls, sql):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', PORT, '-d', 'postgres',
                                 '-XAt', '-v', 'ON_ERROR_STOP=1'],
                                input=sql, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result

    def test_video_locator_lifecycle_scope_and_side_effects(self):
        fixture = (ROOT / 'supabase/tests/context_video_entry.sql').read_text()
        result = self.sql('begin;\n' + fixture + '\nrollback;')
        self.assertIn('PASS: context_video_entry', result.stderr)
        # Checked after the fixture in the same test, so the rollback is actually exercised.
        remaining = self.sql('''
            select (select count(*) from public.context_resources)
                 + (select count(*) from public.context_requests)
                 + (select count(*) from public.context_subjects)
                 + (select count(*) from public.context_sources)
                 + (select count(*) from public.context_results)
                 + (select count(*) from public.context_documents)
                 + (select count(*) from public.accounts)
                 + (select count(*) from public.account_artist_ids)
                 + (select count(*) from public.songs)
                 + (select count(*) from public.song_identifiers);
        ''')
        self.assertEqual(remaining.stdout.strip(), '0')

    def test_browser_roles_cannot_execute(self):
        result = self.sql(f'''
            select pg_catalog.has_function_privilege('anon','{FUNCTION}','EXECUTE')::text
                || ',' || pg_catalog.has_function_privilege('authenticated','{FUNCTION}','EXECUTE')::text
                || ',' || pg_catalog.has_function_privilege('service_role','{FUNCTION}','EXECUTE')::text;
        ''')
        self.assertEqual(result.stdout.strip(), 'false,false,true')

    def test_video_kind_survives_current_subject_constraints(self):
        result = self.sql('''
            select count(*) from pg_catalog.pg_constraint
            where conname in ('context_subjects_kind_check','context_subjects_check')
              and pg_catalog.pg_get_constraintdef(oid) like '%video%';
        ''')
        self.assertEqual(result.stdout.strip(), '2')
