"""Organization contact deduplication without rewriting artist/session identity."""
import concurrent.futures
import json
import uuid
from release_player_fixture import ReleasePlayerFixture, ROOT
import test_release_players

SCOPES = "ARRAY['streaming','user-read-email','user-read-private','user-modify-playback-state','user-read-playback-state']"

class OrganizationFans(ReleasePlayerFixture):
    def setUp(self):
        self.sql('TRUNCATE player_listening_events, player_sessions, player_fans, release_players, accounts CASCADE')
        self.owner, self.other, self.artist, self.artist2 = [str(uuid.uuid4()) for _ in range(4)]
        self.sql(f"INSERT INTO accounts VALUES('{self.owner}'),('{self.other}'),('{self.artist}'),('{self.artist2}')")

    def session(self, owner, artist):
        player, session = str(uuid.uuid4()), str(uuid.uuid4())
        self.sql(f"INSERT INTO release_players(id,owner_id,artist_id,created_by,name,spotify_url,enabled) VALUES('{player}','{owner}','{artist}','{owner}','Fixture','https://open.spotify.com/playlist/abc',true); INSERT INTO player_sessions(id,player_id,revision,provider,expires_at) VALUES('{session}','{player}',1,'spotify',now()+interval '1 hour')")
        return session

    def connect(self, session, email="'verified@example.test'", identity='spotify-fan'):
        return self.sql(f"SET ROLE service_role; SELECT connect_player_fan('{session}',1,'{identity}',{email},'Fan',{SCOPES})").stdout.strip()

    def migrate(self):
        self.sql((ROOT / 'supabase/migrations/20261010100000_player_organization_contacts.sql').read_text())

    def test_backfill_preserves_fan_ids_sessions_and_latest_non_null_profile(self):
        sessions=[self.session(self.owner,a) for a in [self.artist,self.artist2]]
        fans=[self.connect(s) for s in sessions]
        self.sql(f"UPDATE player_fans SET email=NULL,last_connected_at=now()+interval '1 second' WHERE id='{fans[1]}'")
        self.migrate()
        self.assertEqual(self.sql(f"SELECT count(DISTINCT contact_id) FROM player_fans WHERE owner_id='{self.owner}'").stdout.strip(),'1')
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_sessions WHERE fan_id IN ('{fans[0]}','{fans[1]}')").stdout.strip(),'2')
        self.assertEqual(self.sql(f"SELECT email FROM player_fan_contacts WHERE owner_id='{self.owner}'").stdout.strip(),'verified@example.test')
        self.sql(f"SET ROLE service_role; SELECT record_player_listening('{sessions[0]}',1,'spotify','{uuid.uuid4()}','playing','track',0,0)")
        report=json.loads(self.sql(f"SELECT read_player_report('{self.owner}',(SELECT player_id FROM player_sessions WHERE id='{sessions[0]}'),0)").stdout)
        self.assertEqual(report['activity'][0]['fan_id'],fans[0])
        self.assertIsNotNone(report['activity'][0]['contact_id'])

    def test_same_owner_different_artists_share_contact_and_other_owner_is_separate(self):
        self.migrate()
        sessions=[self.session(o,a) for o,a in [(self.owner,self.artist),(self.owner,self.artist2),(self.other,self.artist)]]
        fans=[self.connect(s) for s in sessions]
        rows=json.loads(self.sql(f"SELECT json_agg(row_to_json(f)) FROM (SELECT id,owner_id,contact_id FROM player_fans ORDER BY owner_id,artist_id) f").stdout)
        mine=[r for r in rows if r['owner_id']==self.owner]
        other=[r for r in rows if r['owner_id']==self.other][0]
        self.assertEqual(mine[0]['contact_id'],mine[1]['contact_id'])
        self.assertNotEqual(mine[0]['contact_id'],other['contact_id'])
        self.assertEqual(len(set(fans)),3)
        self.assertNotEqual(self.sql(f"UPDATE player_fans SET contact_id='{other['contact_id']}' WHERE id='{fans[0]}'",succeeds=False).returncode,0)

    def test_concurrent_artists_create_one_contact_and_reconnect_updates_profile(self):
        self.migrate()
        sessions=[self.session(self.owner,self.artist if i%2 else self.artist2) for i in range(8)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(self.connect,sessions))
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_fan_contacts WHERE owner_id='{self.owner}'").stdout.strip(),'1')
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_fans WHERE owner_id='{self.owner}'").stdout.strip(),'2')
        session=self.session(self.owner,self.artist2)
        self.connect(session,email="'changed@example.test'")
        self.connect(self.session(self.owner,self.artist),email='NULL')
        self.assertEqual(self.sql(f"SELECT email FROM player_fan_contacts WHERE owner_id='{self.owner}'").stdout.strip(),'changed@example.test')

    def test_email_does_not_merge_distinct_spotify_identities_and_browser_access_denied(self):
        self.migrate()
        for identity in ['spotify-fan','another-fan']:
            self.connect(self.session(self.owner,self.artist),identity=identity)
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_fan_contacts WHERE owner_id='{self.owner}'").stdout.strip(),'2')
        for role in ['anon','authenticated']:
            self.assertIn('permission denied',self.sql(f'SET ROLE {role}; SELECT * FROM player_fan_contacts',succeeds=False).stderr)

    def tearDown(self):
        # Each case exercises the actual forward migration from the legacy schema.
        self.sql('DROP TRIGGER IF EXISTS player_fans_sync_contact ON player_fans; DROP FUNCTION IF EXISTS sync_player_fan_contact(); ALTER TABLE player_fans DROP COLUMN IF EXISTS contact_id CASCADE; DROP TABLE IF EXISTS player_fan_contacts CASCADE')

class OrganizationFanPlaybackCompatibility(test_release_players.ReleasePlayers):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((ROOT / 'supabase/migrations/20261010100000_player_organization_contacts.sql').read_text())
