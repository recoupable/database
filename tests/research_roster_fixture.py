"""Real legacy/Context fixture; no hosted database or provider calls."""
import json
import pathlib
import test_spotify_onboarding as onboarding

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORRECTION = ROOT / 'supabase/migrations/20261009190000_context_research_without_roster.sql'
TRACK = '1111111111111111111111'
ALBUM = '2222222222222222222222'
TOKEN = '10000000-0000-4000-8000-000000000009'
PAYLOAD = {'trackId': TRACK, 'isrc': 'USABC2600001', 'title': 'Fixture recording',
           'release': {'id': ALBUM, 'title': 'Fixture release'},
           'artists': [{'id': onboarding.SPOTIFY, 'name': 'Primary'},
                       {'id': '3333333333333333333333', 'name': 'Guest'}]}


class ResearchFixture(onboarding.SpotifyOnboarding):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('''ALTER ROLE service_role BYPASSRLS;
        CREATE SCHEMA storage;
        CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint);
        CREATE TABLE storage.objects(id uuid PRIMARY KEY,bucket_id text);
        CREATE TABLE songs(isrc text PRIMARY KEY,name text,album text);
        CREATE TABLE song_identifiers(song text REFERENCES songs(isrc),platform text,identifier_type text,value text);
        GRANT SELECT,INSERT ON songs,song_identifiers TO service_role;''')
        for name in ['20260920010000_context_foundation.sql',
                     '20260920020000_context_spotify_pipeline.sql',
                     '20260920040000_context_guests.sql',
                     '20260922160000_context_canonical_spotify_releases.sql']:
            cls.sql((ROOT / 'supabase/migrations' / name).read_text())
        if CORRECTION.exists():
            cls.sql(CORRECTION.read_text())

    def setUp(self):
        super().setUp()
        self.sql('TRUNCATE context_guest_workspaces,context_resources CASCADE')

    def research(self, org=True):
        owner = onboarding.ORG if org else onboarding.ACTOR
        args = {'url': f'https://open.spotify.com/track/{TRACK}',
                'topics': ['release_metadata', 'artist_metadata']}
        if org:
            args['organization_id'] = owner
        request = json.loads(self.sql(f"SET ROLE service_role; SELECT create_context_request('{owner}',"
                                     f"'{onboarding.ACTOR}','fixture',repeat('a',64),'{json.dumps(args)}','{TRACK}');").splitlines()[-1])
        self.sql(f"SET ROLE service_role; SELECT claim_context_request('{owner}','{request['id']}','{TOKEN}');")
        return owner, request['id']

    def commit(self, owner, request, fails=False):
        return self.sql(f"SET ROLE service_role; SELECT commit_spotify_context('{owner}','{request}',"
                        f"'{TOKEN}','{json.dumps(PAYLOAD)}');", fails=fails)

    def guest(self):
        value = json.loads(self.sql(f"SET ROLE service_role; SELECT start_context_guest(repeat('b',64),"
                                    f"'{{\"trackId\":\"{TRACK}\",\"url\":\"https://open.spotify.com/track/{TRACK}\"}}',"
                                    "repeat('c',64),100);").splitlines()[-1])
        self.sql(f"SET ROLE service_role; SELECT claim_context_guest_worker('{value['id']}','{TOKEN}');")
        return value['id']

    def adopt(self):
        return json.loads(self.sql(f"SET ROLE service_role; SELECT adopt_context_guest(repeat('b',64),"
                                   f"'{onboarding.ACTOR}','{onboarding.ORG}');").splitlines()[-1])

    def complete_guest(self, guest):
        self.sql(f"SET ROLE service_role; SELECT complete_context_guest('{guest}','{TOKEN}','{json.dumps(PAYLOAD)}');")

    def assert_research_only(self, request):
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '0')
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE relation='credited_artist'"), '2')
        self.assertEqual(self.sql(f"SELECT jsonb_array_length(output->'artists') FROM context_requests WHERE id='{request}'"), '2')
        self.assertEqual(self.sql("SELECT count(*) FROM context_result_sources"), '4')
