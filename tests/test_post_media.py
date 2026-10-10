"""Posts media retention columns on disposable PostgreSQL, without hosted credentials."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / 'supabase/migrations'
RETENTION = MIGRATIONS / '20261010213200_posts_media_retention.sql'
PORT = '55474'
COLUMNS_SQL = '''
    SELECT column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '-')
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'posts'
    ORDER BY ordinal_position
'''
CONSTRAINTS_SQL = '''
    SELECT conname || ':' || pg_get_constraintdef(oid)
    FROM pg_constraint WHERE conrelid = 'public.posts'::regclass ORDER BY conname
'''


class PostMediaRetention(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-post-media-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', str(pathlib.Path(cls.tmp.name) / 'pg.log'),
                        '-o', f"-k {cls.tmp.name} -p {PORT} -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        # Minimal public.posts mirroring the columns and keys of
        # 20250130161836_posts_table.sql. That migration also alters
        # social_posts and installs the set_updated_at trigger which
        # 20260827120100 drops; neither is exercised by this slice.
        cls.sql('''
            CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
            CREATE TABLE public.posts(
                id uuid NOT NULL DEFAULT gen_random_uuid(),
                updated_at timestamptz NOT NULL DEFAULT now(),
                post_url text NOT NULL
            );
            ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
            CREATE UNIQUE INDEX posts_pkey ON public.posts USING btree (id);
            CREATE UNIQUE INDEX posts_post_url_key ON public.posts USING btree (post_url);
            ALTER TABLE public.posts ADD CONSTRAINT posts_pkey PRIMARY KEY USING INDEX posts_pkey;
            ALTER TABLE public.posts ADD CONSTRAINT posts_post_url_key UNIQUE USING INDEX posts_post_url_key;
            GRANT SELECT, INSERT, UPDATE ON public.posts TO service_role;
        ''')
        cls.sql((MIGRATIONS / '20260827120100_posts_engagement_columns.sql').read_text())
        cls.sql(RETENTION.read_text())

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def run_sql(cls, sql):
        return subprocess.run(['psql', '-h', cls.tmp.name, '-p', PORT, '-d', 'postgres',
                               '-XAt', '-v', 'ON_ERROR_STOP=1'],
                              input=sql, text=True, capture_output=True)

    @classmethod
    def sql(cls, sql):
        result = cls.run_sql(sql)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def rejected(self, sql):
        result = self.run_sql(sql)
        self.assertNotEqual(result.returncode, 0, 'statement unexpectedly succeeded')
        return result.stderr

    def setUp(self):
        self.sql('DELETE FROM public.posts')

    def test_legacy_insert_without_new_columns_defaults_media_to_empty_array(self):
        self.sql('''
            INSERT INTO public.posts(post_url, updated_at, likes)
            VALUES ('https://www.instagram.com/p/legacy1', '2026-08-20T00:00:00Z', 10)
        ''')
        row = self.sql('''
            SELECT (caption IS NULL)::text || ' ' || (published_at IS NULL)::text || ' '
                || media::text || ' ' || jsonb_typeof(media) || ' ' || (media_observed_at IS NULL)::text
                || ' ' || likes::text
            FROM public.posts WHERE post_url = 'https://www.instagram.com/p/legacy1'
        ''')
        self.assertEqual(row, 'true true [] array true 10')

    def test_upsert_on_post_url_sets_caption_media_and_publish_date_in_place(self):
        before = self.sql('''
            INSERT INTO public.posts(post_url, updated_at, likes)
            VALUES ('https://www.instagram.com/p/era1', '2026-08-20T00:00:00Z', 10)
            RETURNING id
        ''')
        after = self.sql('''
            INSERT INTO public.posts(post_url, updated_at, likes, caption, published_at, media, media_observed_at)
            VALUES (
                'https://www.instagram.com/p/era1', '2026-08-20T00:00:00Z', 12,
                'studio week two @collab #era', '2026-08-20T00:00:00Z',
                '[{"position":0,"kind":"image","provider_url":"https://cdn.example/a.jpg","width":1080,"height":1350,"alt":null,"source":"apify_instagram"},
                  {"position":1,"kind":"video","provider_url":"https://cdn.example/b.mp4","width":null,"height":null,"alt":null,"source":"apify_instagram"}]'::jsonb,
                '2026-10-10T12:00:00Z'
            )
            ON CONFLICT (post_url) DO UPDATE SET
                likes = EXCLUDED.likes, caption = EXCLUDED.caption, published_at = EXCLUDED.published_at,
                media = EXCLUDED.media, media_observed_at = EXCLUDED.media_observed_at
            RETURNING id
        ''')
        self.assertEqual(before, after, 'upsert must refresh the existing row, not create a second one')
        row = self.sql('''
            SELECT caption || '|' || (published_at = '2026-08-20T00:00:00Z'::timestamptz)::text
                || '|' || jsonb_array_length(media)::text || '|' || (media->1->>'kind')
                || '|' || likes::text || '|' || (media_observed_at IS NOT NULL)::text
            FROM public.posts WHERE post_url = 'https://www.instagram.com/p/era1'
        ''')
        self.assertEqual(row, 'studio week two @collab #era|true|2|video|12|true')
        self.assertEqual(self.sql('SELECT count(*) FROM public.posts'), '1')

    def test_rescrape_that_omits_caption_and_media_keeps_the_retained_values(self):
        # Mirrors the api upsert: nullish fields are stripped before the write,
        # so the ON CONFLICT update names only the columns the run reported.
        self.sql('''
            INSERT INTO public.posts(post_url, updated_at, likes, caption, media, media_observed_at)
            VALUES ('https://www.instagram.com/p/keep1', '2026-08-20T00:00:00Z', 1, 'kept caption',
                    '[{"position":0,"kind":"image","provider_url":"https://cdn.example/k.jpg","source":"apify_instagram"}]'::jsonb,
                    '2026-10-10T12:00:00Z');
            INSERT INTO public.posts(post_url, updated_at, likes)
            VALUES ('https://www.instagram.com/p/keep1', '2026-08-20T00:00:00Z', 5)
            ON CONFLICT (post_url) DO UPDATE SET likes = EXCLUDED.likes;
        ''')
        row = self.sql('''
            SELECT caption || '|' || jsonb_array_length(media)::text || '|' || likes::text
            FROM public.posts WHERE post_url = 'https://www.instagram.com/p/keep1'
        ''')
        self.assertEqual(row, 'kept caption|1|5')

    def test_empty_caption_stays_distinct_from_not_captured(self):
        self.sql('''
            INSERT INTO public.posts(post_url, caption) VALUES
                ('https://www.instagram.com/p/blank1', ''),
                ('https://www.instagram.com/p/unknown1', NULL)
        ''')
        self.assertEqual(self.sql("SELECT count(*) FROM public.posts WHERE caption IS NULL"), '1')
        self.assertEqual(self.sql("SELECT count(*) FROM public.posts WHERE caption = ''"), '1')

    def test_non_array_media_is_rejected(self):
        for value in ("'{\"provider_url\":\"https://cdn.example/x.jpg\"}'::jsonb", "'\"https://cdn.example/x.jpg\"'::jsonb",
                      "'null'::jsonb", "NULL"):
            stderr = self.rejected(f'''
                INSERT INTO public.posts(post_url, media)
                VALUES ('https://www.instagram.com/p/bad', {value})
            ''')
            self.assertTrue('posts_media_is_array' in stderr or 'null value in column "media"' in stderr, stderr)
        self.assertEqual(self.sql('SELECT count(*) FROM public.posts'), '0')

    def test_reapplying_the_migration_is_a_noop(self):
        columns, constraints = self.sql(COLUMNS_SQL), self.sql(CONSTRAINTS_SQL)
        self.assertIn('media:jsonb:NO:\'[]\'::jsonb', columns)
        self.assertIn('posts_media_is_array:CHECK ((jsonb_typeof(media) = \'array\'::text))', constraints)
        self.sql(RETENTION.read_text())
        self.assertEqual(self.sql(COLUMNS_SQL), columns)
        self.assertEqual(self.sql(CONSTRAINTS_SQL), constraints)

    def test_existing_engagement_columns_and_service_role_access_are_unchanged(self):
        self.sql('''
            INSERT INTO public.posts(post_url, views, likes, comments, reposts)
            VALUES ('https://www.instagram.com/p/metrics1', 100, 10, 2, 1)
        ''')
        self.rejected("UPDATE public.posts SET likes = -1 WHERE post_url = 'https://www.instagram.com/p/metrics1'")
        row = self.sql('''
            SELECT views::text || '|' || likes::text || '|' || comments::text || '|' || reposts::text || '|' || media::text
                || '|' || has_column_privilege('service_role', 'public.posts', 'media', 'SELECT')::text
                || '|' || has_column_privilege('service_role', 'public.posts', 'caption', 'UPDATE')::text
            FROM public.posts WHERE post_url = 'https://www.instagram.com/p/metrics1'
        ''')
        self.assertEqual(row, '100|10|2|1|[]|true|true')


if __name__ == '__main__':
    unittest.main()
