"""Private access, cross-release fan identity and idempotent listening on real PostgreSQL."""
import concurrent.futures
import json
import uuid
from release_player_fixture import ReleasePlayerFixture

SCOPES = "ARRAY['streaming','user-read-email','user-read-private','user-modify-playback-state','user-read-playback-state']"

class ReleasePlayers(ReleasePlayerFixture):
    def setUp(self):
        self.owner, self.artist, self.player, self.session = [str(uuid.uuid4()) for _ in range(4)]
        self.sql(f"INSERT INTO accounts VALUES ('{self.owner}'),('{self.artist}')")
        self.add_player(self.player)
        self.add_session(self.session, self.player)

    def add_player(self, player, artist=None):
        self.sql(f"INSERT INTO release_players(id,owner_id,artist_id,created_by,name,spotify_url,enabled) VALUES('{player}','{self.owner}','{artist or self.artist}','{self.owner}','Fixture','https://open.spotify.com/track/abc',true)")

    def add_session(self, session, player, provider='spotify'):
        self.sql(f"INSERT INTO player_sessions(id,player_id,revision,provider,expires_at) VALUES('{session}','{player}',1,'{provider}',now()+interval '1 hour')")

    def connect(self, session=None, email="'verified@example.test'", scopes=SCOPES, succeeds=True):
        return self.sql(f"SET ROLE service_role; SELECT connect_player_fan('{session or self.session}',1,'provider-id',{email},'Fan',{scopes})", succeeds=succeeds)

    def event(self, event_id=None, listened=0, provider='spotify', succeeds=True):
        return self.sql(f"SET ROLE service_role; SELECT record_player_listening('{self.session}',1,'{provider}','{event_id or uuid.uuid4()}','playing','track1',100,{listened})", succeeds=succeeds)

    def test_cross_release_identity_preserves_available_email(self):
        first = self.connect().stdout.strip()
        player, session = str(uuid.uuid4()), str(uuid.uuid4())
        self.add_player(player)
        self.add_session(session, player)
        self.assertEqual(first, self.connect(session=session,email='NULL').stdout.strip())
        self.assertEqual(self.sql(f"SELECT email FROM player_fans WHERE id='{first}'").stdout.strip(), 'verified@example.test')
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_sessions WHERE fan_id='{first}'").stdout.strip(), '2')

    def test_different_artist_does_not_share_fan_record(self):
        first = self.connect().stdout.strip()
        artist, player, session = [str(uuid.uuid4()) for _ in range(3)]
        self.sql(f"INSERT INTO accounts VALUES('{artist}')")
        self.add_player(player, artist)
        self.add_session(session, player)
        self.assertNotEqual(first, self.connect(session=session).stdout.strip())

    def test_permissions_and_duplicate_auth_do_not_create_false_grants(self):
        self.assertNotEqual(self.connect(scopes="ARRAY['streaming']",succeeds=False).returncode,0)
        self.connect()
        self.assertNotEqual(self.connect(succeeds=False).returncode,0)
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_fans WHERE owner_id='{self.owner}'").stdout.strip(),'1')

    def test_concurrent_event_retries_count_once(self):
        event_id = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.event(event_id=event_id), range(6)))
        self.assertEqual(sum(r.stdout.strip()=='t' for r in results),1)
        self.assertEqual(self.sql(f"SELECT count(*) FROM player_listening_events WHERE session_id='{self.session}'").stdout.strip(),'1')

    def test_duration_and_provider_are_bounded(self):
        self.assertNotEqual(self.event(listened=30000,succeeds=False).returncode,0)
        self.assertNotEqual(self.event(provider='apple_music',succeeds=False).returncode,0)
        self.sql(f"UPDATE player_sessions SET created_at=now()-interval '5 seconds',last_event_at=now()-interval '5 seconds' WHERE id='{self.session}'")
        self.event(listened=4000)
        report=json.loads(self.sql(f"SET ROLE service_role; SELECT read_player_report('{self.owner}','{self.player}',0)").stdout)
        self.assertEqual(report['reportedListeningMs'],4000)
        self.assertEqual(report['activity'][0]['track_id'],'track1')
        self.assertNotEqual(self.event(listened=4000,succeeds=False).returncode,0)

    def test_disabled_revised_and_expired_sessions_fail_closed(self):
        self.sql(f"UPDATE release_players SET enabled=false WHERE id='{self.player}'")
        self.assertNotEqual(self.event(succeeds=False).returncode,0)
        self.sql(f"UPDATE release_players SET enabled=true,revision=2 WHERE id='{self.player}'")
        self.assertNotEqual(self.event(succeeds=False).returncode,0)
        self.assertNotEqual(self.connect(succeeds=False).returncode,0)

    def test_expired_session_rejects_event_and_connection(self):
        self.sql(f"UPDATE player_sessions SET created_at=now()-interval '2 hours',expires_at=now()-interval '1 second' WHERE id='{self.session}'")
        self.assertNotEqual(self.event(succeeds=False).returncode,0)
        self.assertNotEqual(self.connect(succeeds=False).returncode,0)

    def test_browser_roles_cannot_read_fans_or_write_events(self):
        for role in ['anon','authenticated']:
            for statement in ['SELECT * FROM player_fans', f"SELECT read_player_report('{self.owner}','{self.player}',0)", f"SELECT record_player_listening('{self.session}',1,'spotify','{uuid.uuid4()}','playing',NULL,0,0)"]:
                self.assertIn('permission denied',self.sql(f'SET ROLE {role}; {statement}',succeeds=False).stderr)

    def test_report_does_not_cross_workspace_boundary(self):
        self.assertNotEqual(self.sql(f"SET ROLE service_role; SELECT read_player_report('{uuid.uuid4()}','{self.player}',0)",succeeds=False).returncode,0)

    def test_timing_allowance_is_cumulative(self):
        self.event(listened=2000)
        self.assertNotEqual(self.event(listened=2000,succeeds=False).returncode,0)

    def test_event_id_retry_across_sessions_returns_false(self):
        event_id=str(uuid.uuid4())
        self.event(event_id=event_id)
        second=str(uuid.uuid4())
        self.add_session(second,self.player)
        self.session=second
        self.assertEqual(self.event(event_id=event_id).stdout.strip(),'f')

    def test_event_window_uses_event_time(self):
        self.event()
        self.sql(f"UPDATE player_sessions SET created_at=now()-interval '30 days 1 hour',expires_at=now()-interval '30 days' WHERE id='{self.session}'")
        report=json.loads(self.sql(f"SET ROLE service_role; SELECT read_player_report('{self.owner}','{self.player}',0)").stdout)
        self.assertEqual(report['sessions'],0)
        self.assertEqual(report['playEvents'],1)

    def test_free_playback_defaults_and_audio_requirement(self):
        result = self.sql(f"SELECT free_playback, audio_url IS NULL FROM release_players WHERE id='{self.player}'")
        self.assertEqual(result.stdout.strip(), 'spotify|t')
        result = self.sql(f"UPDATE release_players SET free_playback='audio' WHERE id='{self.player}'", succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.sql(f"UPDATE release_players SET free_playback='audio', audio_url='https://storage.test/song.mp3' WHERE id='{self.player}'")
        result = self.sql(f"UPDATE release_players SET audio_url=NULL WHERE id='{self.player}'", succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        result = self.sql(f"UPDATE release_players SET free_playback='other' WHERE id='{self.player}'", succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.sql(f"UPDATE release_players SET free_playback='spotify',audio_url=NULL WHERE id='{self.player}'")
