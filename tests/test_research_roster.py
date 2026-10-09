"""Research preserves evidence and credits without implying roster enrollment."""
import json
import research_roster_fixture as fixture


class ResearchRoster(fixture.ResearchFixture):
    def test_organization_research_does_not_enroll_contributors(self):
        owner, request = self.research()
        self.commit(owner, request)
        self.assert_research_only(request)

    def test_personal_research_does_not_enroll_contributors(self):
        owner, request = self.research(org=False)
        self.commit(owner, request)
        self.assert_research_only(request)

    def test_existing_roster_is_preserved_and_guest_is_not_added(self):
        artist = self.call().split('|')[0]
        owner, request = self.research()
        self.commit(owner, request)
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')
        self.assertEqual(self.sql('SELECT artist_id FROM artist_organization_ids'), artist)
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE relation='credited_artist'"), '2')

    def test_ready_guest_adoption_does_not_enroll(self):
        guest = self.guest()
        self.complete_guest(guest)
        adopted = self.adopt()
        self.assert_research_only(adopted['requestId'])
        self.assertEqual(self.adopt()['requestId'], adopted['requestId'])
        self.assert_research_only(adopted['requestId'])

    def test_running_guest_adoption_does_not_enroll(self):
        guest = self.guest()
        adopted = self.adopt()
        self.complete_guest(guest)
        self.assert_research_only(adopted['requestId'])

    def test_stale_delivery_cannot_change_saved_evidence(self):
        owner, request = self.research()
        self.commit(owner, request)
        ids = self.sql('SELECT string_agg(id::text,\',\' ORDER BY id) FROM context_results')
        self.assertIn('Worker no longer owns request', self.commit(owner, request, fails=True))
        self.assertEqual(self.sql('SELECT string_agg(id::text,\',\' ORDER BY id) FROM context_results'), ids)
        self.assert_research_only(request)

    def test_explicit_onboarding_after_research_reuses_identity(self):
        owner, request = self.research()
        self.commit(owner, request)
        self.assert_research_only(request)
        result = self.call().split('|')
        self.assertEqual(result[1], 'f')
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')
        self.assertEqual(self.call(), result[0] + '|f')

    def test_fresh_connection_can_read_saved_request_and_source_lineage(self):
        owner, request = self.research()
        self.commit(owner, request)
        saved = json.loads(self.sql(f"SET ROLE service_role; SELECT read_context_request('{owner}','{request}');").splitlines()[-1])
        self.assertEqual(saved['owner_id'], owner)
        self.assertEqual(len(saved['output']['subjectIds']), 4)
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_results r JOIN context_attempts a ON a.id=r.attempt_id "
                                 f"JOIN context_result_sources s ON s.result_id=r.id WHERE a.request_id='{request}' "
                                 "AND r.status='accepted'"), '4')
        self.assert_research_only(request)

    def test_browser_roles_cannot_commit_research(self):
        owner, request = self.research()
        for role in ['anon', 'authenticated']:
            self.assertIn('permission denied', self.sql(f"SET ROLE {role}; SELECT commit_spotify_context("
                f"'{owner}','{request}','{fixture.TOKEN}','{json.dumps(fixture.PAYLOAD)}');", fails=True))
        self.assertEqual(self.sql('SELECT count(*) FROM context_results'), '0')
