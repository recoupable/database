"""Read-only identity-conflict audit on disposable PostgreSQL; no hosted database or credentials.
Run: python3 -m unittest discover -s tests -p 'test_identity_conflict_inventory.py'
Requires PostgreSQL initdb, pg_ctl and psql on PATH from one installation.

The audit is a standalone script (supabase/audits/identity_conflict_inventory.sql), not a migration:
the tests run it with psql exactly as an operator would. Every identifier below is synthetic. The
audit must return aggregate counts only, so the assertions also check that none of these values
leak into its output.
"""
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / 'supabase/migrations'
AUDIT = ROOT / 'supabase/audits/identity_conflict_inventory.sql'

ACTOR = '10000000-0000-4000-8000-000000000001'  # organization member
ORG = '10000000-0000-4000-8000-000000000002'
USER_WITHOUT_ORG = '10000000-0000-4000-8000-000000000003'
ARTISTS = {name: f'10000000-0000-4000-8000-0000000000{index:02d}' for index, name in enumerate(
    ['primary', 'primary_copy', 'primary_query', 'primary_lowercase', 'multi_social',
     'namesake_one', 'namesake_two', 'namesake_unrostered', 'org_only', 'context_only',
     'swapped_social'], start=11)}
SPOTIFY_ONE = 'AbCdEfGhIjKlMnOpQrStUv'
SPOTIFY_TWO = 'ZyXwVuTsRqPoNmLkJiHgFe'
SPOTIFY_THREE = 'QwErTyUiOpAsDfGhJkLzXc'
SPOTIFY_FOUR = 'MnBvCxZlKjHgFdSaPoIuYt'
SPOTIFY_FIVE = 'PlOkMiJnUhBygVtFcRdXeS'
SPOTIFY_SIX = 'LkJhGfDsApOiUyTrEwQmNb'
SPOTIFY_SEVEN = 'XcVbNmAsDfGhJkLqWeRtYu'
TRACK = '1111111111111111111111'
ALBUM = '2222222222222222222222'
RESEARCH_TRACK = '4444444444444444444444'
RESEARCH_ALBUM = '5555555555555555555555'
ISRC_ONE = 'USABC2600001'
ISRC_TWO = 'USABC2600002'
ISRC_THREE = 'USABC2600003'
TOKEN = '10000000-0000-4000-8000-000000000009'
RESOURCES = {name: f'20000000-0000-4000-8000-0000000000{index:02d}' for index, name in enumerate(
    ['one', 'two', 'four', 'five', 'seven', 'research_track'], start=1)}
SUBJECTS = {name: f'30000000-0000-4000-8000-0000000000{index:02d}' for index, name in enumerate(
    ['primary', 'primary_copy', 'multi_social', 'context_only', 'swapped_social'], start=1)}
CLASSES = 12

LEGACY_SCHEMA = '''
CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
CREATE TABLE public.accounts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, timestamp bigint DEFAULT extract(epoch from now()));
CREATE TABLE public.account_info(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid REFERENCES public.accounts(id), updated_at timestamptz NOT NULL DEFAULT now(), knowledges jsonb DEFAULT '[]'::jsonb);
CREATE TABLE public.account_organization_ids(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid REFERENCES public.accounts(id), organization_id uuid REFERENCES public.accounts(id), updated_at timestamptz DEFAULT now());
CREATE TABLE public.socials(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), username text NOT NULL, profile_url text NOT NULL UNIQUE, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.account_socials(account_id uuid REFERENCES public.accounts(id), social_id uuid REFERENCES public.socials(id), UNIQUE(account_id, social_id));
CREATE TABLE public.account_artist_ids(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id uuid REFERENCES public.accounts(id), artist_id uuid REFERENCES public.accounts(id), UNIQUE(account_id, artist_id));
CREATE TABLE public.artist_organization_ids(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), artist_id uuid REFERENCES public.accounts(id), organization_id uuid REFERENCES public.accounts(id), UNIQUE(artist_id, organization_id));
GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO service_role;
'''

CATALOG_AND_CONTEXT_SCHEMA = '''
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text PRIMARY KEY, name text, public boolean, file_size_limit bigint);
CREATE TABLE storage.objects(id uuid PRIMARY KEY, bucket_id text);
CREATE TABLE public.songs(isrc text PRIMARY KEY, name text, album text);
CREATE TABLE public.song_identifiers(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), song text REFERENCES public.songs(isrc), platform text, identifier_type text, value text, UNIQUE(song, platform, identifier_type, value));
CREATE TABLE public.song_artists(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), song text REFERENCES public.songs(isrc), artist uuid REFERENCES public.accounts(id), UNIQUE(song, artist));
CREATE SCHEMA supabase_migrations;
CREATE TABLE supabase_migrations.schema_migrations(version text PRIMARY KEY, name text);
GRANT USAGE ON SCHEMA supabase_migrations TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public, supabase_migrations TO service_role;
'''

# A role that can read every table but does not bypass row-level security.
READER_WITHOUT_BYPASS = '''
CREATE ROLE inventory_reader;
GRANT USAGE ON SCHEMA public TO inventory_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO inventory_reader;
'''

COUNTED_TABLES = ['accounts', 'account_info', 'account_organization_ids', 'socials', 'account_socials',
                  'account_artist_ids', 'artist_organization_ids', 'songs', 'song_identifiers', 'song_artists',
                  'context_resources', 'context_subjects', 'context_resource_links', 'context_requests']


class InventoryCluster(unittest.TestCase):
    """Disposable Unix-socket-only cluster; subclasses choose the schema."""
    port = '55517'
    schema_sql = ''
    migrations = ()
    after_migrations_sql = ''

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-identity-inventory-')
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', str(pathlib.Path(cls.tmp.name) / 'pg.log'),
                        '-o', f"-k {cls.tmp.name} -p {cls.port} -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql(cls.schema_sql)
        for name in cls.migrations:
            cls.sql((MIGRATIONS / name).read_text())
        if cls.after_migrations_sql:
            cls.sql(cls.after_migrations_sql)

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'], check=True, capture_output=True)
        cls.tmp.cleanup()

    @classmethod
    def psql(cls, *args):
        return subprocess.run(['psql', '-h', cls.tmp.name, '-p', cls.port, '-d', 'postgres', '-X', '-q', '-A', '-t',
                               '-v', 'ON_ERROR_STOP=1', *args], text=True, capture_output=True)

    @classmethod
    def sql(cls, sql, fails=False):
        result = cls.psql('-c', sql)
        if fails:
            if result.returncode == 0:
                raise AssertionError('Expected SQL failure')
            return result.stderr
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def audit(self, role='service_role', fails=False):
        """Run the script file the way the operator instructions do, optionally after SET ROLE."""
        result = self.psql(*(['-c', f'SET ROLE {role}'] if role else []), '-f', str(AUDIT))
        if fails:
            self.assertNotEqual(result.returncode, 0, 'Expected the audit to fail')
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(len(lines), 1, 'The audit must print exactly one row')
        return json.loads(lines[0])

    def assert_class(self, classes, name, count, affected_rows, status='measured', **details):
        entry = classes[name]
        self.assertEqual(entry['status'], status, name)
        self.assertEqual(entry['count'], count, name)
        self.assertEqual(entry['affected_rows'], affected_rows, name)
        self.assertIsInstance(entry['rule'], str, name)
        self.assertIn('recoupable/app#2119', entry['rule'], name)
        for key, value in details.items():
            self.assertEqual(entry[key], value, f'{name}.{key}')


class IdentityConflictInventory(InventoryCluster):
    schema_sql = LEGACY_SCHEMA + CATALOG_AND_CONTEXT_SCHEMA
    migrations = ('20250528095512_socials_profile_url_clean_trigger.sql',
                  '20260805190000_preserve_youtube_channel_url_case.sql',
                  '20260920010000_context_foundation.sql',
                  '20260920020000_context_spotify_pipeline.sql',
                  '20261009190000_context_research_without_roster.sql')
    after_migrations_sql = READER_WITHOUT_BYPASS

    def setUp(self):
        self.sql('TRUNCATE public.accounts, public.socials, public.songs, public.context_resources, '
                 'supabase_migrations.schema_migrations CASCADE')

    def seed_conflicts(self):
        a = ARTISTS
        accounts = [(ACTOR, 'Operator'), (ORG, 'Label'), (USER_WITHOUT_ORG, 'Solo operator'),
                    (a['primary'], 'Primary'), (a['primary_copy'], 'Primary'), (a['primary_query'], 'Primary'),
                    (a['primary_lowercase'], 'Primary'), (a['multi_social'], 'Two profiles'),
                    (a['namesake_one'], 'Namesake'), (a['namesake_two'], ' namesake '),
                    (a['namesake_unrostered'], 'Namesake'), (a['org_only'], 'Attached only'),
                    (a['context_only'], 'Context only'), (a['swapped_social'], 'Swapped profile')]
        socials = [('S1', f'https://open.spotify.com/artist/{SPOTIFY_ONE}'),
                   ('S1q', f'https://open.spotify.com/artist/{SPOTIFY_ONE}?si=fixture'),
                   ('S1l', f'https://open.spotify.com/artist/{SPOTIFY_ONE.lower()}'),
                   ('S2', f'https://open.spotify.com/artist/{SPOTIFY_TWO}'),
                   ('S3', f'https://open.spotify.com/intl-de/artist/{SPOTIFY_THREE}'),
                   ('S5', f'https://open.spotify.com/artist/{SPOTIFY_FIVE}'),
                   ('S6', f'https://open.spotify.com/artist/{SPOTIFY_SIX}'),
                   ('IG', 'https://instagram.com/primary')]
        links = [(a['primary'], 'S1'), (a['primary_copy'], 'S1'), (a['primary_query'], 'S1q'),
                 (a['primary_lowercase'], 'S1l'), (a['multi_social'], 'S2'), (a['multi_social'], 'S3'),
                 (a['multi_social'], 'S5'), (a['primary'], 'IG'), (a['swapped_social'], 'S6')]
        self.sql('INSERT INTO public.accounts(id, name) VALUES ' + ', '.join(f"('{i}', '{n}')" for i, n in accounts) + ';'
                 f"INSERT INTO public.account_organization_ids(account_id, organization_id) VALUES ('{ACTOR}', '{ORG}');"
                 'INSERT INTO public.socials(username, profile_url) VALUES ' + ', '.join(f"('{u}', '{p}')" for u, p in socials) + ';'
                 'INSERT INTO public.account_socials(account_id, social_id) SELECT v.account, s.id FROM (VALUES '
                 + ', '.join(f"('{acc}'::uuid, '{u}')" for acc, u in links) + ') v(account, username) JOIN public.socials s ON s.username = v.username;'
                 # Roster: the member rosters primary (attached to the organization) and both namesakes (attached nowhere).
                 'INSERT INTO public.account_artist_ids(account_id, artist_id) VALUES '
                 f"('{ACTOR}', '{a['primary']}'), ('{ACTOR}', '{a['namesake_one']}'), ('{ACTOR}', '{a['namesake_two']}'), "
                 f"('{USER_WITHOUT_ORG}', '{a['primary_copy']}');"
                 f"INSERT INTO public.artist_organization_ids(artist_id, organization_id) VALUES ('{a['primary']}', '{ORG}'), ('{a['org_only']}', '{ORG}');"
                 # Catalog: two graph owners for the duplicated Spotify id; one Spotify track id on two ISRCs; album ids legitimately shared.
                 f"INSERT INTO public.songs(isrc, name, album) VALUES ('{ISRC_ONE}', 'Fixture one', 'Fixture'), ('{ISRC_TWO}', 'Fixture two', 'Fixture');"
                 f"INSERT INTO public.song_artists(song, artist) VALUES ('{ISRC_ONE}', '{a['primary']}'), ('{ISRC_TWO}', '{a['primary_copy']}');"
                 'INSERT INTO public.song_identifiers(song, platform, identifier_type, value) VALUES '
                 f"('{ISRC_ONE}', 'spotify', 'track_id', '{TRACK}'), ('{ISRC_TWO}', 'spotify', 'track_id', '{TRACK}'), "
                 f"('{ISRC_ONE}', 'spotify', 'album_id', '{ALBUM}'), ('{ISRC_TWO}', 'spotify', 'album_id', '{ALBUM}');"
                 # Context: accepted identities that agree, disagree on the Spotify-id side (one) or on the account
                 # side (seven: the subject account's legacy social is a different id), lack any legacy social (four),
                 # share a subject (two and five), plus a recorded conflict.
                 'INSERT INTO public.context_resources(id, provider, resource_kind, provider_id, canonical_url) VALUES '
                 + ', '.join(f"('{RESOURCES[k]}', 'spotify', 'artist', '{sid}', 'https://open.spotify.com/artist/{sid}')"
                             for k, sid in [('one', SPOTIFY_ONE), ('two', SPOTIFY_TWO), ('four', SPOTIFY_FOUR),
                                            ('five', SPOTIFY_FIVE), ('seven', SPOTIFY_SEVEN)]) + ';'
                 'INSERT INTO public.context_subjects(id, kind, artist_id) VALUES '
                 + ', '.join(f"('{SUBJECTS[k]}', 'artist', '{a[k]}')"
                             for k in ['primary', 'primary_copy', 'multi_social', 'context_only', 'swapped_social']) + ';'
                 'INSERT INTO public.context_resource_links(resource_id, subject_id, relation, status) VALUES '
                 f"('{RESOURCES['one']}', '{SUBJECTS['primary']}', 'identity', 'accepted'), "
                 f"('{RESOURCES['one']}', '{SUBJECTS['primary_copy']}', 'identity', 'conflict'), "
                 f"('{RESOURCES['two']}', '{SUBJECTS['multi_social']}', 'identity', 'accepted'), "
                 f"('{RESOURCES['five']}', '{SUBJECTS['multi_social']}', 'identity', 'accepted'), "
                 f"('{RESOURCES['four']}', '{SUBJECTS['context_only']}', 'identity', 'accepted'), "
                 f"('{RESOURCES['four']}', '{SUBJECTS['primary']}', 'identity', 'candidate'), "
                 f"('{RESOURCES['seven']}', '{SUBJECTS['swapped_social']}', 'identity', 'accepted');"
                 "INSERT INTO supabase_migrations.schema_migrations(version, name) VALUES "
                 "('20260920010000', 'context_foundation'), ('20261010100000', 'player_organization_contacts');")

    def table_counts(self):
        return self.sql('SELECT ' + ', '.join(f'(SELECT count(*) FROM public.{t})' for t in COUNTED_TABLES))

    def catalog_objects(self):
        return self.sql("SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                        "WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')), "
                        "(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
                        "WHERE n.nspname NOT IN ('pg_catalog', 'information_schema'))")

    def test_empty_database_reports_zero_for_every_class(self):
        report = self.audit()
        self.assertEqual(report['inventory_version'], 'identity-inventory-v1')
        self.assertEqual(report['mutations'], 'none')
        self.assertEqual(report['transaction_read_only'], 'on')
        self.assertIs(report['bypasses_row_security'], True)
        self.assertIn('generated_at', report)
        self.assertEqual(report['migration_history'], {'status': 'present', 'applied': 0, 'latest_version': None})
        self.assertEqual(report['classes_with_findings'], 0)
        classes = report['classes']
        self.assertEqual(len(classes), CLASSES)
        self.assertNotIn('legacy_cleanup_manifest_rows', classes)
        for name, entry in classes.items():
            self.assertEqual(entry['status'], 'measured', name)
            self.assertEqual(entry['count'], 0, name)
            self.assertEqual(entry['affected_rows'], 0, name)
            self.assertIn('recoupable/app#2119', entry['rule'], name)
        self.assertEqual(classes['spotify_artist_ids_linked_to_multiple_accounts']['multiple_graph_owners'], 0)

    def test_seeded_conflicts_report_exact_counts(self):
        self.seed_conflicts()
        report = self.audit()
        classes = report['classes']
        self.assert_class(classes, 'spotify_artist_ids_linked_to_multiple_accounts', 1, 3, multiple_graph_owners=1)
        self.assert_class(classes, 'accounts_with_multiple_spotify_artist_socials', 1, 3)
        self.assert_class(classes, 'spotify_artist_id_case_variants', 1, 3)
        self.assert_class(classes, 'spotify_artist_socials_without_uppercase', 1, 1)
        self.assert_class(classes, 'context_identity_links_in_conflict_status', 1, 1)
        self.assert_class(classes, 'context_artist_subjects_with_multiple_accepted_resources', 1, 2)
        # Resource one disagrees on the Spotify-id side (3 legacy rows across 3 accounts); resource seven on the
        # account side (its subject account's only Spotify social is a different id: 1 row).
        self.assert_class(classes, 'context_accepted_artist_identities_disagreeing_with_legacy_socials', 2, 4,
                          spotify_id_side=1, account_side=1)
        # Only resource four is benign: neither its id nor its subject account has a legacy Spotify social.
        self.assert_class(classes, 'context_accepted_artist_identities_without_legacy_social', 1, 1)
        self.assert_class(classes, 'name_only_artist_accounts_sharing_a_name', 1, 2)
        self.assert_class(classes, 'rostered_artists_without_organization_attachment', 2, 2)
        self.assert_class(classes, 'organization_artists_without_member_roster', 1, 1)
        self.assert_class(classes, 'provider_track_values_mapped_to_multiple_songs', 1, 2)
        self.assertEqual(report['classes_with_findings'], CLASSES)
        self.assertEqual(report['migration_history'], {'status': 'present', 'applied': 2, 'latest_version': '20261010100000'})

    def test_output_contains_counts_only(self):
        self.seed_conflicts()
        text = json.dumps(self.audit())
        for secret in [ACTOR, ORG, USER_WITHOUT_ORG, *ARTISTS.values(), *RESOURCES.values(), *SUBJECTS.values(),
                       SPOTIFY_ONE, SPOTIFY_ONE.lower(), SPOTIFY_TWO, SPOTIFY_THREE, SPOTIFY_FOUR, SPOTIFY_FIVE,
                       SPOTIFY_SIX, SPOTIFY_SEVEN, TRACK, ALBUM, ISRC_ONE, ISRC_TWO, 'Namesake', 'namesake',
                       'Primary', 'Swapped', 'open.spotify.com', 'instagram']:
            self.assertNotIn(secret, text)

    def test_audit_is_one_read_only_transaction_that_changes_nothing(self):
        statements = [line for line in AUDIT.read_text().splitlines() if line.strip() and not line.startswith('--')]
        self.assertEqual(statements[0], 'begin read only;')
        self.assertEqual(statements[-1], 'rollback;')
        self.seed_conflicts()
        before = (self.table_counts(), self.catalog_objects())
        report = self.audit()
        self.assertEqual(report['transaction_read_only'], 'on')
        self.assertEqual((self.table_counts(), self.catalog_objects()), before)
        # Nothing is left behind for a later session: the setting was transaction-local.
        self.assertEqual(self.sql("SELECT coalesce(current_setting('recoup.identity_conflict_inventory', true), '')"), '')

    def test_role_without_rls_bypass_is_flagged_and_unreadable_roles_fail(self):
        self.seed_conflicts()
        report = self.audit('inventory_reader')
        self.assertIs(report['bypasses_row_security'], False)
        # Row-level security hides the Context rows from this role, which is why the flag exists.
        self.assertEqual(report['classes']['context_identity_links_in_conflict_status']['count'], 0)
        self.assertEqual(report['classes']['spotify_artist_ids_linked_to_multiple_accounts']['count'], 1)
        self.assertEqual(report['migration_history'], {'status': 'denied'})
        for role in ('anon', 'authenticated'):
            self.assertIn('permission denied', self.audit(role, fails=True))

    def test_research_refuses_the_duplicated_spotify_id_that_the_audit_counts(self):
        """Class a is the class commit_spotify_context refuses when no accepted identity exists."""
        a = ARTISTS
        self.sql(f"INSERT INTO public.accounts(id, name) VALUES ('{ACTOR}', 'Operator'), ('{a['primary']}', 'Primary'), "
                 f"('{a['primary_copy']}', 'Primary');"
                 f"INSERT INTO public.socials(username, profile_url) VALUES ('S1', 'https://open.spotify.com/artist/{SPOTIFY_ONE}');"
                 'INSERT INTO public.account_socials(account_id, social_id) SELECT v, id FROM public.socials, '
                 f"(VALUES ('{a['primary']}'::uuid), ('{a['primary_copy']}'::uuid)) x(v);"
                 'INSERT INTO public.context_resources(id, provider, resource_kind, provider_id, canonical_url) VALUES '
                 f"('{RESOURCES['research_track']}', 'spotify', 'track', '{RESEARCH_TRACK}', 'https://open.spotify.com/track/{RESEARCH_TRACK}');"
                 'INSERT INTO public.context_requests(owner_id, created_by, resource_id, idempotency_key, input_fingerprint, '
                 f"input, status, claim_token) SELECT '{ACTOR}', '{ACTOR}', '{RESOURCES['research_track']}', 'fixture', "
                 f"repeat('a', 64), '{{}}'::jsonb, 'running', '{TOKEN}' RETURNING id;")
        self.assertEqual(self.audit()['classes']['spotify_artist_ids_linked_to_multiple_accounts']['count'], 1)
        request = self.sql('SELECT id FROM public.context_requests')
        payload = json.dumps({'trackId': RESEARCH_TRACK, 'isrc': ISRC_THREE, 'title': 'Fixture recording',
                              'release': {'id': RESEARCH_ALBUM, 'title': 'Fixture release'},
                              'artists': [{'id': SPOTIFY_ONE, 'name': 'Primary'}]})
        before = self.table_counts()
        error = self.sql(f"SELECT public.commit_spotify_context('{ACTOR}', '{request}', '{TOKEN}', '{payload}'::jsonb);",
                         fails=True)
        self.assertIn('Conflicting artist identity', error)
        self.assertEqual(self.table_counts(), before)


class IdentityConflictInventoryWithoutCatalogTables(InventoryCluster):
    """Fresh/preview environments: catalog, Context and migration-history tables may be absent or unreadable."""
    port = '55518'
    schema_sql = LEGACY_SCHEMA + '''
    CREATE SCHEMA supabase_migrations;
    CREATE TABLE supabase_migrations.schema_migrations(version text PRIMARY KEY, name text);
    '''
    migrations = ('20250528095512_socials_profile_url_clean_trigger.sql',
                  '20260805190000_preserve_youtube_channel_url_case.sql')

    def test_missing_tables_report_not_applicable(self):
        a = ARTISTS
        self.sql(f"INSERT INTO public.accounts(id, name) VALUES ('{a['primary']}', 'Primary'), ('{a['primary_copy']}', 'Primary');"
                 f"INSERT INTO public.socials(username, profile_url) VALUES ('S1', 'https://open.spotify.com/artist/{SPOTIFY_ONE}');"
                 f"INSERT INTO public.account_socials(account_id, social_id) SELECT v, id FROM public.socials, (VALUES ('{a['primary']}'::uuid), ('{a['primary_copy']}'::uuid)) x(v);")
        report = self.audit()
        classes = report['classes']
        self.assertEqual(len(classes), CLASSES)
        self.assert_class(classes, 'spotify_artist_ids_linked_to_multiple_accounts', 1, 2, multiple_graph_owners='not_applicable')
        self.assert_class(classes, 'accounts_with_multiple_spotify_artist_socials', 0, 0)
        self.assert_class(classes, 'name_only_artist_accounts_sharing_a_name', 0, 0)
        for name in ('context_identity_links_in_conflict_status', 'context_artist_subjects_with_multiple_accepted_resources',
                     'context_accepted_artist_identities_disagreeing_with_legacy_socials',
                     'context_accepted_artist_identities_without_legacy_social', 'provider_track_values_mapped_to_multiple_songs'):
            self.assert_class(classes, name, 0, 0, status='not_applicable')
        self.assertEqual(report['migration_history'], {'status': 'denied'})
        self.assertEqual(report['classes_with_findings'], 1)


if __name__ == '__main__':
    unittest.main()
