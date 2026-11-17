"""Conflicting track-to-recording evidence is quarantined, visible and excluded; nothing is accepted.
Run: python3 -m unittest discover -s tests -p 'test_identity_conflicts.py'
Disposable local PostgreSQL only; synthetic identifiers, no provider calls or hosted credentials.
The research-roster and onboarding regressions are inherited so they also run with this migration.
"""
import json
import research_roster_fixture as fixture
import test_research_roster as roster

ROOT = fixture.ROOT
MIGRATION = ROOT / 'supabase/migrations/20261010211900_context_identity_conflict_quarantine.sql'
LEGACY_ISRC = 'USABC2500009'
OBSERVED_ISRC = fixture.PAYLOAD['isrc']


class IdentityConflicts(roster.ResearchRoster):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if MIGRATION.exists():
            cls.sql(MIGRATION.read_text())

    def setUp(self):
        super().setUp()
        self.sql('TRUNCATE songs CASCADE')

    def seed_legacy_mapping(self):
        self.sql(f"INSERT INTO songs(isrc,name,album) VALUES ('{LEGACY_ISRC}','Legacy recording','Legacy release');"
                 f"INSERT INTO song_identifiers VALUES ('{LEGACY_ISRC}','spotify','track_id','{fixture.TRACK}');")

    def seed_accepted_identity(self):
        self.sql(f"INSERT INTO songs(isrc,name,album) VALUES ('{LEGACY_ISRC}','Legacy recording','Legacy release');"
                 f"INSERT INTO context_resources(provider,resource_kind,provider_id,canonical_url)"
                 f" VALUES ('spotify','track','{fixture.TRACK}','https://open.spotify.com/track/{fixture.TRACK}');"
                 f"INSERT INTO context_subjects(kind,song_isrc) VALUES ('recording','{LEGACY_ISRC}');"
                 "INSERT INTO context_resource_links(resource_id,subject_id,relation,status,evidence)"
                 " SELECT r.id,s.id,'identity','accepted','{\"isrc\":\"" + LEGACY_ISRC + "\"}' FROM context_resources r, context_subjects s;")
        return json.loads(self.sql("SELECT to_jsonb(l) FROM context_resource_links l"))

    def read(self, owner, request):
        return json.loads(self.sql(f"SET ROLE service_role; SELECT read_context_request('{owner}','{request}');").splitlines()[-1])

    def documents(self, owner, request):
        return json.loads(self.sql(f"SET ROLE service_role; SELECT read_context_documents('{owner}','{request}');").splitlines()[-1])

    def reclaim(self, owner, request):
        self.assertEqual(self.sql(f"SET ROLE service_role; SELECT claim_context_request('{owner}','{request}','{fixture.TOKEN}');").splitlines()[-1], 't')

    def conflict_row(self):
        rows = self.sql("SELECT to_jsonb(l) FROM context_resource_links l WHERE relation='identity' AND status='conflict'").splitlines()
        self.assertEqual(len(rows), 1)
        return json.loads(rows[0])

    def link(self, link_id):
        return json.loads(self.sql(f"SELECT to_jsonb(l) FROM context_resource_links l WHERE id='{link_id}'"))

    def commit_isrc(self, owner, request, isrc, fails=False):
        payload = json.dumps(dict(fixture.PAYLOAD, isrc=isrc))
        return self.sql(f"SET ROLE service_role; SELECT commit_spotify_context('{owner}','{request}','{fixture.TOKEN}','{payload}');",
                        fails=fails)

    def assert_quarantined(self, saved):
        self.assertEqual(saved['status'], 'failed')
        self.assertTrue(saved['error'].startswith('identity_conflict: '), saved['error'])
        self.assertEqual(saved['output']['identityConflicts'][0]['existingIsrcs'], [LEGACY_ISRC])

    def assert_nothing_accepted(self, owner, request):
        self.assertEqual(self.sql(f"SELECT count(*) FROM songs WHERE isrc='{OBSERVED_ISRC}'"), '0')
        self.assertEqual(self.sql(f"SELECT count(*) FROM song_identifiers WHERE song='{OBSERVED_ISRC}'"), '0')
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE status='accepted'"), '0')
        self.assertEqual(self.sql("SELECT count(*) FROM context_subjects WHERE kind IN ('artist','release')"), '0')
        self.assertEqual(self.sql("SELECT count(*) FROM context_resources WHERE resource_kind IN ('artist','release')"), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM context_results'), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '0')
        self.assertEqual(self.documents(owner, request), [])

    def test_conflicting_legacy_mapping_is_quarantined_not_accepted(self):
        self.seed_legacy_mapping()
        owner, request = self.research()
        self.commit(owner, request)
        saved = self.read(owner, request)
        self.assert_quarantined(saved)
        self.assertIsNone(saved['lease_expires_at'])
        conflicts = saved['output']['identityConflicts']
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0]['providerId'], fixture.TRACK)
        self.assertEqual(conflicts[0]['observedIsrc'], OBSERVED_ISRC)
        self.assertEqual(conflicts[0]['existingIsrcs'], [LEGACY_ISRC])
        self.assertEqual(saved['output']['subjectIds'], [])
        self.assertEqual(saved['output']['artists'], [])
        self.assertEqual(saved['output']['gaps'], [])
        self.assertEqual(saved['output']['providerCostMicros'], 0)
        self.assertIsNone(saved['output']['model'])
        link = self.conflict_row()
        self.assertEqual(self.sql('SELECT count(*) FROM context_resource_links'), '1')
        self.assertEqual(conflicts[0]['linkIds'], [link['id']])
        self.assertEqual(link['evidence']['observedIsrc'], OBSERVED_ISRC)
        self.assertEqual(link['evidence']['existingIsrc'], LEGACY_ISRC)
        self.assertEqual(link['evidence']['providerId'], fixture.TRACK)
        self.assertNotIn('requestId', link['evidence'])
        self.assertEqual(link['evidence']['sourceUrl'], f'https://open.spotify.com/track/{fixture.TRACK}')
        self.assertEqual(link['evidence']['observedTitle'], fixture.PAYLOAD['title'])
        self.assertIn('retrievedAt', link['evidence'])
        self.assertEqual(self.sql(f"SELECT kind||'|'||song_isrc FROM context_subjects WHERE id='{link['subject_id']}'"),
                         f'recording|{LEGACY_ISRC}')
        self.assertEqual(self.sql('SELECT count(*) FROM context_subjects'), '1')
        self.assert_nothing_accepted(owner, request)

    def test_retry_refreshes_the_same_quarantine_row(self):
        self.seed_legacy_mapping()
        owner, request = self.research()
        self.commit(owner, request)
        first = self.conflict_row()
        self.reclaim(owner, request)
        payload = dict(fixture.PAYLOAD, retrievedAt='2026-10-10T12:34:56Z')
        self.sql(f"SET ROLE service_role; SELECT commit_spotify_context('{owner}','{request}','{fixture.TOKEN}','{json.dumps(payload)}');")
        second = self.conflict_row()
        self.assertEqual(self.sql('SELECT count(*) FROM context_resource_links'), '1')
        self.assertEqual(second['id'], first['id'])
        self.assertNotEqual(second['evidence']['retrievedAt'], first['evidence']['retrievedAt'])
        self.assertEqual(self.sql("SELECT (evidence->>'retrievedAt')::timestamptz = '2026-10-10T12:34:56Z'::timestamptz"
                                  f" FROM context_resource_links WHERE id='{second['id']}'"), 't')
        self.assertEqual(second['evidence']['existingIsrc'], LEGACY_ISRC)
        saved = self.read(owner, request)
        self.assertEqual(saved['status'], 'failed')
        self.assertEqual(saved['output']['identityConflicts'][0]['linkIds'], [first['id']])
        self.assert_nothing_accepted(owner, request)

    def test_resolved_legacy_mapping_commits_and_closes_the_superseded_conflict(self):
        self.seed_legacy_mapping()
        owner, request = self.research()
        self.commit(owner, request)
        conflict = self.conflict_row()
        self.sql(f"DELETE FROM song_identifiers WHERE song='{LEGACY_ISRC}'")
        self.reclaim(owner, request)
        self.commit(owner, request)
        saved = self.read(owner, request)
        self.assertEqual(saved['status'], 'completed')
        self.assertIsNone(saved['error'])
        self.assertNotIn('identityConflicts', saved['output'])
        self.assertEqual(len(saved['output']['subjectIds']), 4)
        self.assert_research_only(request)
        self.assertEqual(self.sql(f"SELECT count(*) FROM song_identifiers WHERE song='{OBSERVED_ISRC}' AND value='{fixture.TRACK}'"), '1')
        self.assertEqual(self.sql(f"SELECT s.song_isrc FROM context_resource_links l JOIN context_subjects s ON s.id=l.subject_id"
                                  f" WHERE l.resource_id='{conflict['resource_id']}' AND l.relation='identity' AND l.status='accepted'"), OBSERVED_ISRC)
        closed = self.link(conflict['id'])
        self.assertEqual(closed['status'], 'rejected')
        self.assertEqual(closed['subject_id'], conflict['subject_id'])
        for key, value in conflict['evidence'].items():
            self.assertEqual(closed['evidence'][key], value)
        self.assertEqual(closed['evidence']['resolution'], 'superseded_by_accepted_identity')
        self.assertEqual(closed['evidence']['acceptedIsrc'], OBSERVED_ISRC)
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE status='conflict'"), '0')
        self.assertEqual(len(self.documents(owner, request)), 4)

    def test_later_observation_of_the_quarantined_isrc_promotes_the_link(self):
        self.seed_legacy_mapping()
        owner, request = self.research()
        self.commit(owner, request)
        conflict = self.conflict_row()
        self.reclaim(owner, request)
        self.commit_isrc(owner, request, LEGACY_ISRC)
        saved = self.read(owner, request)
        self.assertEqual(saved['status'], 'completed')
        self.assertIsNone(saved['error'])
        self.assertNotIn('identityConflicts', saved['output'])
        accepted = self.link(conflict['id'])
        self.assertEqual(accepted['status'], 'accepted')
        self.assertEqual(accepted['subject_id'], conflict['subject_id'])
        self.assertEqual(accepted['evidence'], {'isrc': LEGACY_ISRC, 'resolvedConflict': conflict['evidence']})
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_resource_links WHERE resource_id='{conflict['resource_id']}'"
                                  " AND relation='identity'"), '1')
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE status='conflict'"), '0')
        self.assertEqual(self.sql(f"SELECT count(*) FROM songs WHERE isrc='{OBSERVED_ISRC}'"), '0')
        self.assertEqual(self.sql(f"SELECT count(*) FROM song_identifiers WHERE value='{fixture.TRACK}'"), '1')
        self.assert_research_only(request)
        self.assertEqual(len(self.documents(owner, request)), 4)

    def test_reviewed_link_blocking_acceptance_raises_instead_of_completing(self):
        self.sql(f"INSERT INTO songs(isrc,name,album) VALUES ('{OBSERVED_ISRC}','Fixture recording','Fixture release');"
                 f"INSERT INTO context_resources(provider,resource_kind,provider_id,canonical_url)"
                 f" VALUES ('spotify','track','{fixture.TRACK}','https://open.spotify.com/track/{fixture.TRACK}');"
                 f"INSERT INTO context_subjects(kind,song_isrc) VALUES ('recording','{OBSERVED_ISRC}');"
                 "INSERT INTO context_resource_links(resource_id,subject_id,relation,status)"
                 " SELECT r.id,s.id,'identity','rejected' FROM context_resources r, context_subjects s;")
        owner, request = self.research()
        self.assertIn('Conflicting recording identity', self.commit(owner, request, fails=True))
        self.assertEqual(self.read(owner, request)['status'], 'running')
        self.assertEqual(self.sql("SELECT string_agg(status,',') FROM context_resource_links"), 'rejected')
        self.assertEqual(self.sql('SELECT count(*) FROM song_identifiers'), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM context_results'), '0')

    def test_accepted_identity_to_another_recording_is_never_downgraded(self):
        accepted = self.seed_accepted_identity()
        owner, request = self.research()
        self.commit(owner, request)
        saved = self.read(owner, request)
        self.assert_quarantined(saved)
        conflicts = saved['output']['identityConflicts']
        self.assertEqual(conflicts[0]['linkIds'], [accepted['id']])
        self.assertEqual(json.loads(self.sql("SELECT to_jsonb(l) FROM context_resource_links l")), accepted)
        self.assertEqual(self.sql('SELECT count(*) FROM context_resource_links'), '1')
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE status='accepted'"), '1')
        self.assertEqual(self.sql(f"SELECT count(*) FROM songs WHERE isrc='{OBSERVED_ISRC}'"), '0')
        self.assertEqual(self.sql(f"SELECT count(*) FROM song_identifiers"), '0')
        self.assertEqual(self.sql("SELECT count(*) FROM context_subjects"), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM context_results'), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM accounts'), '2')
        self.assertEqual(self.documents(owner, request), [])

    def test_claimed_guest_completion_reports_the_quarantined_request(self):
        self.seed_legacy_mapping()
        guest = self.guest()
        adopted = self.adopt()
        self.complete_guest(guest)
        self.assertEqual(self.sql(f"SELECT status FROM context_guest_workspaces WHERE id='{guest}'"), 'ready')
        saved = self.read(fixture.onboarding.ORG, adopted['requestId'])
        self.assert_quarantined(saved)
        self.assertEqual(saved['output']['identityConflicts'][0]['linkIds'], [self.conflict_row()['id']])
        self.assert_nothing_accepted(fixture.onboarding.ORG, adopted['requestId'])

    def test_ready_guest_adoption_reports_the_quarantined_request(self):
        self.seed_legacy_mapping()
        guest = self.guest()
        self.complete_guest(guest)
        adopted = self.adopt()
        self.assertEqual(adopted['status'], 'claimed')
        saved = self.read(fixture.onboarding.ORG, adopted['requestId'])
        self.assert_quarantined(saved)
        self.assert_nothing_accepted(fixture.onboarding.ORG, adopted['requestId'])
        self.assertEqual(self.adopt()['requestId'], adopted['requestId'])

    def test_non_conflicting_research_is_unchanged(self):
        owner, request = self.research()
        self.commit(owner, request)
        saved = self.read(owner, request)
        self.assertEqual(saved['status'], 'completed')
        self.assertNotIn('identityConflicts', saved['output'])
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE status='conflict'"), '0')
        self.assert_research_only(request)

    def test_browser_roles_cannot_quarantine(self):
        self.seed_legacy_mapping()
        owner, request = self.research()
        for role in ['anon', 'authenticated']:
            self.assertIn('permission denied', self.sql(f"SET ROLE {role}; SELECT commit_spotify_context("
                f"'{owner}','{request}','{fixture.TOKEN}','{json.dumps(fixture.PAYLOAD)}');", fails=True))
        self.assertEqual(self.sql('SELECT count(*) FROM context_resource_links'), '0')
        self.assertEqual(self.read(owner, request)['status'], 'running')
