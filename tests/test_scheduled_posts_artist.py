"""scheduled_posts.artist_account_id: stored next to the charged account, cascades with the artist."""
import pathlib
import subprocess
import tempfile
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = ['20261015230000_create_scheduled_posts.sql', '20261019200000_scheduled_posts_artist_account_id.sql']
VIDEO = "'https://cdn.example.test/clip.mp4'"


class ScheduledPostsArtist(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-posts-artist-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', f'{cls.tmp.name}/pg.log',
                        '-o', f"-k {cls.tmp.name} -p 55484 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql("""
            CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
            CREATE TABLE public.accounts(id uuid PRIMARY KEY);
            GRANT ALL ON SCHEMA public TO anon, authenticated, service_role;
            CREATE FUNCTION trigger_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS
              $$ BEGIN NEW.updated_at = clock_timestamp(); RETURN NEW; END $$;
        """)
        for name in MIGRATIONS:
            migration = (ROOT / 'supabase/migrations' / name).read_text()
            cls.sql(migration)
            cls.sql(migration)  # re-applying is safe

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def sql(cls, statement, succeeds=True):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55484', '-d', 'postgres',
                                 '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                input=statement, text=True, capture_output=True)
        if succeeds and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def setUp(self):
        self.account, self.artist = str(uuid.uuid4()), str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{self.account}'), ('{self.artist}')")

    def insert(self, artist):
        return self.sql(f"""SET ROLE service_role; INSERT INTO scheduled_posts
            (account_id, artist_account_id, platform, video_url, description, status)
            VALUES ('{self.account}', {artist}, 'x', {VIDEO}, 'post text', 'publishing') RETURNING id""").stdout.strip()

    def test_artist_is_stored_beside_the_charged_account(self):
        post = self.insert(f"'{self.artist}'")
        row = self.sql(f"SELECT account_id, artist_account_id FROM scheduled_posts WHERE id='{post}'").stdout.strip()
        self.assertEqual(row, f'{self.account}|{self.artist}')

    def test_artist_is_optional(self):
        post = self.insert('NULL')
        self.assertEqual(self.sql(f"SELECT artist_account_id IS NULL FROM scheduled_posts WHERE id='{post}'").stdout.strip(), 't')

    def test_unknown_artist_is_rejected(self):
        result = self.sql(f"""INSERT INTO scheduled_posts (account_id, artist_account_id, platform, video_url, description, status)
            VALUES ('{self.account}', '{uuid.uuid4()}', 'x', {VIDEO}, 'post text', 'publishing')""", succeeds=False)
        self.assertIn('violates foreign key constraint', result.stderr)

    def test_deleting_the_artist_deletes_its_posts(self):
        post = self.insert(f"'{self.artist}'")
        self.sql(f"DELETE FROM accounts WHERE id='{self.artist}'")
        self.assertEqual(self.sql(f"SELECT count(*) FROM scheduled_posts WHERE id='{post}'").stdout.strip(), '0')


if __name__ == '__main__':
    unittest.main()
