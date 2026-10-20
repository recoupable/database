"""Posts media retention columns on disposable PostgreSQL, without hosted credentials."""
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / 'supabase/migrations'
RETENTION = MIGRATIONS / '20261010213200_posts_media_retention.sql'
VALIDATE = MIGRATIONS / '20261010213201_posts_media_retention_validate.sql'
PORT = '55474'
COLUMNS_SQL = '''
    SELECT column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '-')
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'posts'
    ORDER BY ordinal_position
'''
CONSTRAINTS_SQL = '''
    SELECT conname || ':' || pg_get_constraintdef(oid) || ':' || convalidated::text
    FROM pg_constraint WHERE conrelid = 'public.posts'::regclass ORDER BY conname
'''
COLUMN_TYPES = {
    'post_url': 'text', 'updated_at': 'timestamptz', 'likes': 'integer', 'comments': 'integer',
    'caption': 'text', 'published_at': 'timestamptz', 'media': 'jsonb', 'media_observed_at': 'timestamptz',
}
CAROUSEL = {
    'post_url': 'https://www.instagram.com/p/alice-carousel', 'updated_at': '2026-09-01T12:00:00Z', 'likes': 3,
    'caption': 'tour recap', 'published_at': '2026-09-01T12:00:00Z',
    'media': [{'position': 0, 'kind': 'image', 'provider_url': 'https://cdn.example/c0.jpg',
               'width': None, 'height': None, 'alt': None, 'source': 'apify_instagram'}],
    'media_observed_at': '2026-10-10T12:00:00Z',
}
LEGACY = {'post_url': 'https://www.instagram.com/p/alice-legacy', 'updated_at': '2026-07-01T00:00:00Z',
          'published_at': '2026-07-01T00:00:00Z', 'likes': 1}


def postgrest_upsert(rows):
    """The statement PostgREST runs for supabase-js `upsert(rows, {onConflict: 'post_url'})`.

    postgrest-js names the union of all rows' keys as `columns`; PostgREST
    reads each row through json_to_recordset with that column list, so a key a
    row omits arrives as NULL, and the ON CONFLICT update sets every named
    column from EXCLUDED.
    """
    columns = list(dict.fromkeys(key for row in rows for key in row))
    names = ', '.join(columns)
    record = ', '.join(f'{c} {COLUMN_TYPES[c]}' for c in columns)
    updates = ', '.join(f'{c} = EXCLUDED.{c}' for c in columns)
    return f'''
        INSERT INTO public.posts({names})
        SELECT {names} FROM json_to_recordset($json${json.dumps(rows)}$json$) AS b({record})
        ON CONFLICT (post_url) DO UPDATE SET {updates}
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
        cls.sql(VALIDATE.read_text())

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

    def retain_legacy_caption_and_media(self):
        self.sql('''
            INSERT INTO public.posts(post_url, updated_at, likes, caption, media, media_observed_at)
            VALUES ('https://www.instagram.com/p/alice-legacy', '2026-07-01T00:00:00Z', 0, 'kept caption',
                    '[{"position":0,"kind":"image","provider_url":"https://cdn.example/k.jpg","source":"apify_instagram"}]'::jsonb,
                    '2026-10-01T12:00:00Z')
        ''')

    def post_summary(self):
        return self.sql('''
            SELECT string_agg(post_url || '|' || coalesce(caption, '<null>') || '|' || jsonb_array_length(media)::text
                              || '|' || likes::text, E'\n' ORDER BY post_url)
            FROM public.posts
        ''')

    def test_rescrape_that_omits_caption_and_media_keeps_the_retained_values(self):
        # The api strips nullish fields, so a run that reported no caption or
        # media sends a row without those keys; PostgREST then names only the
        # reported columns in the ON CONFLICT update.
        self.retain_legacy_caption_and_media()
        self.sql(postgrest_upsert([LEGACY]))
        self.assertEqual(self.post_summary(), 'https://www.instagram.com/p/alice-legacy|kept caption|1|1')

    def test_one_upsert_mixing_rows_with_and_without_media_is_refused(self):
        # Why the api writes each column set in its own call: unioned columns
        # would NULL-fill the legacy row's media (and caption). NOT NULL
        # refuses the whole statement instead of erasing retained evidence.
        self.retain_legacy_caption_and_media()
        stderr = self.rejected(postgrest_upsert([CAROUSEL, LEGACY]))
        self.assertIn('null value in column "media"', stderr)
        self.assertEqual(self.post_summary(), 'https://www.instagram.com/p/alice-legacy|kept caption|1|0')

    def test_upserts_grouped_by_column_set_retain_new_media_and_keep_old(self):
        self.retain_legacy_caption_and_media()
        brand_new = {'post_url': 'https://www.instagram.com/p/alice-new', 'updated_at': '2026-10-01T00:00:00Z',
                     'published_at': '2026-10-01T00:00:00Z', 'likes': 7}
        self.sql(postgrest_upsert([CAROUSEL]))
        self.sql(postgrest_upsert([LEGACY, brand_new]))
        self.assertEqual(self.post_summary(), '\n'.join([
            'https://www.instagram.com/p/alice-carousel|tour recap|1|3',
            'https://www.instagram.com/p/alice-legacy|kept caption|1|1',
            'https://www.instagram.com/p/alice-new|<null>|0|7',
        ]))

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

    def test_reapplying_the_migrations_is_a_noop_and_leaves_the_check_validated(self):
        columns, constraints = self.sql(COLUMNS_SQL), self.sql(CONSTRAINTS_SQL)
        self.assertIn('media:jsonb:NO:\'[]\'::jsonb', columns)
        self.assertIn('posts_media_is_array:CHECK ((jsonb_typeof(media) = \'array\'::text)):true', constraints)
        self.sql(RETENTION.read_text())
        self.sql(VALIDATE.read_text())
        self.assertEqual(self.sql(COLUMNS_SQL), columns)
        self.assertEqual(self.sql(CONSTRAINTS_SQL), constraints)

    def test_check_is_added_not_valid_and_validated_by_the_second_file(self):
        # The first file must not scan existing posts under its ACCESS
        # EXCLUSIVE lock; the second validates under SHARE UPDATE EXCLUSIVE.
        validated = "SELECT convalidated::text FROM pg_constraint WHERE conname = 'posts_media_is_array'"
        self.sql('INSERT INTO public.posts(post_url) VALUES (\'https://www.instagram.com/p/existing\')')
        self.sql('ALTER TABLE public.posts DROP CONSTRAINT posts_media_is_array')
        self.addCleanup(lambda: self.sql(RETENTION.read_text() + VALIDATE.read_text()))
        self.sql(RETENTION.read_text())
        self.assertEqual(self.sql(validated), 'false')
        self.assertIn('posts_media_is_array', self.rejected(
            "INSERT INTO public.posts(post_url, media) VALUES ('https://www.instagram.com/p/new', '{}'::jsonb)"))
        self.sql(VALIDATE.read_text())
        self.assertEqual(self.sql(validated), 'true')

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
