"""scheduled_posts shape, per-platform copy rules and browser-role denial on real PostgreSQL."""
import pathlib
import subprocess
import tempfile
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = '20261015230000_create_scheduled_posts.sql'
VIDEO = "'https://cdn.example.test/clip.mp4'"


class ScheduledPosts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-posts-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', f'{cls.tmp.name}/pg.log',
                        '-o', f"-k {cls.tmp.name} -p 55483 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql("""
            CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
            CREATE TABLE public.accounts(id uuid PRIMARY KEY);
            GRANT ALL ON SCHEMA public TO anon, authenticated, service_role;
            CREATE FUNCTION trigger_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS
              $$ BEGIN NEW.updated_at = clock_timestamp(); RETURN NEW; END $$;
        """)
        migration = (ROOT / 'supabase/migrations' / MIGRATION).read_text()
        cls.sql(migration)
        cls.sql(migration)  # re-applying is safe

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def sql(cls, statement, succeeds=True):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55483', '-d', 'postgres',
                                 '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                input=statement, text=True, capture_output=True)
        if succeeds and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def setUp(self):
        self.account = str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{self.account}')")

    def insert(self, columns, succeeds=True, role='service_role'):
        names = ','.join(['account_id', 'video_url'] + list(columns))
        values = ','.join([f"'{self.account}'", VIDEO] + list(columns.values()))
        return self.sql(f"SET ROLE {role}; INSERT INTO scheduled_posts({names}) VALUES({values}) RETURNING id",
                        succeeds=succeeds)

    def rejected(self, columns):
        self.assertIn('violates check constraint', self.insert(columns, succeeds=False).stderr, columns)

    def test_publish_now_row_per_platform(self):
        rows = [
            {'platform': "'instagram'", 'description': "'caption'", 'cover_url': "'https://cdn.example.test/c.jpg'", 'status': "'publishing'"},
            {'platform': "'x'", 'description': "'post text'", 'status': "'publishing'"},
            {'platform': "'linkedin'", 'title': "'t'", 'description': "'commentary'", 'sub_account_id': "'urn:li:organization:101127186'", 'status': "'publishing'"},
            {'platform': "'youtube'", 'title': "'Shorts title'", 'privacy': "'public'", 'tags': "ARRAY['music','rights']", 'status': "'publishing'"},
        ]
        for row in rows:
            post = self.insert(row).stdout.strip()
            self.assertEqual(len(post), 36)
        self.assertEqual(self.sql(f"SELECT count(*) FROM scheduled_posts WHERE account_id='{self.account}'").stdout.strip(), '4')

    def test_required_copy_per_platform(self):
        self.rejected({'platform': "'youtube'", 'status': "'publishing'"})
        self.rejected({'platform': "'youtube'", 'title': "'  '", 'status': "'publishing'"})
        for platform in ['instagram', 'x', 'linkedin']:
            self.rejected({'platform': f"'{platform}'", 'title': "'only a title'", 'status': "'publishing'"})

    def test_platform_specific_fields_are_bounded(self):
        self.rejected({'platform': "'tiktok'", 'description': "'d'", 'status': "'publishing'"})
        self.rejected({'platform': "'instagram'", 'description': "'d'", 'sub_account_id': "'urn:li:organization:1'", 'status': "'publishing'"})
        self.rejected({'platform': "'x'", 'description': "'d'", 'privacy': "'public'", 'status': "'publishing'"})
        self.rejected({'platform': "'instagram'", 'description': "'d'", 'tags': "ARRAY['a']", 'status': "'publishing'"})
        self.rejected({'platform': "'youtube'", 'title': "'t'", 'cover_url': "'https://cdn.example.test/c.jpg'", 'status': "'publishing'"})
        self.rejected({'platform': "'youtube'", 'title': "'t'", 'privacy': "'friends'", 'status': "'publishing'"})

    def test_status_lifecycle_invariants(self):
        self.rejected({'platform': "'x'", 'description': "'d'", 'status': "'scheduled'"})
        self.rejected({'platform': "'x'", 'description': "'d'", 'status': "'drafted'"})
        post = self.insert({'platform': "'x'", 'description': "'d'", 'status': "'scheduled'", 'publish_at': "now() + interval '10 minutes'"}).stdout.strip()
        self.assertIn('scheduled_posts_posted_has_url', self.sql(f"UPDATE scheduled_posts SET status='posted' WHERE id='{post}'", succeeds=False).stderr)
        self.assertIn('scheduled_posts_failed_has_reason', self.sql(f"UPDATE scheduled_posts SET status='failed' WHERE id='{post}'", succeeds=False).stderr)
        self.sql(f"UPDATE scheduled_posts SET status='posted', post_url='https://x.com/recoupai/status/1', text_verified=true WHERE id='{post}'")
        self.assertEqual(self.sql(f"SELECT status, text_verified, updated_at > created_at FROM scheduled_posts WHERE id='{post}'").stdout.strip(), 'posted|t|t')
        failed = self.insert({'platform': "'youtube'", 'title': "'t'", 'status': "'publishing'"}).stdout.strip()
        self.sql(f"UPDATE scheduled_posts SET status='failed', error_message='quotaExceeded: Video Uploads per day' WHERE id='{failed}'")

    def test_account_delete_cascades_and_creator_delete_keeps_post(self):
        creator = str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{creator}')")
        post = self.insert({'platform': "'x'", 'description': "'d'", 'status': "'publishing'", 'created_by_account_id': f"'{creator}'"}).stdout.strip()
        self.sql(f"DELETE FROM accounts WHERE id='{creator}'")
        self.assertEqual(self.sql(f"SELECT created_by_account_id IS NULL FROM scheduled_posts WHERE id='{post}'").stdout.strip(), 't')
        self.sql(f"DELETE FROM accounts WHERE id='{self.account}'")
        self.assertEqual(self.sql(f"SELECT count(*) FROM scheduled_posts WHERE id='{post}'").stdout.strip(), '0')

    def test_browser_roles_are_denied(self):
        self.insert({'platform': "'x'", 'description': "'d'", 'status': "'publishing'"})
        for role in ['anon', 'authenticated']:
            for statement in ['SELECT * FROM scheduled_posts',
                              f"INSERT INTO scheduled_posts(account_id,platform,video_url,description,status) VALUES('{self.account}','x',{VIDEO},'d','publishing')",
                              "UPDATE scheduled_posts SET status='cancelled'",
                              'DELETE FROM scheduled_posts']:
                self.assertIn('permission denied', self.sql(f'SET ROLE {role}; {statement}', succeeds=False).stderr)
        self.assertEqual(self.sql('SELECT relrowsecurity FROM pg_class WHERE relname=\'scheduled_posts\'').stdout.strip(), 't')


if __name__ == '__main__':
    unittest.main()
