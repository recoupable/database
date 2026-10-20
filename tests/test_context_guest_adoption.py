"""Guest adoption lands in the verified workspace only and never implies roster membership."""
import json
import research_roster_fixture as fixture

ACTOR, ORG = fixture.onboarding.ACTOR, fixture.onboarding.ORG
NEW = '10000000-0000-4000-8000-000000000004'
SECOND_ORG = '10000000-0000-4000-8000-000000000005'
HASH, OTHER, FRESH = 'b' * 64, 'd' * 64, 'e' * 64
# The API normalizes guest input to the metadata-only topics before start_context_guest.
INPUT = json.dumps({'trackId': fixture.TRACK, 'url': f'https://open.spotify.com/track/{fixture.TRACK}',
                    'topics': ['release_metadata', 'artist_metadata']})


class GuestAdoption(fixture.ResearchFixture):
    def rpc(self, call, fails=False):
        result = self.sql(f"SET ROLE service_role; SELECT {call};", fails=fails)
        return result if fails else result.splitlines()[-1]

    def start(self, hash=HASH, run=True):
        value = json.loads(self.rpc(f"start_context_guest('{hash}','{INPUT}',repeat('c',64),100)"))
        if run:
            self.rpc(f"claim_context_guest_worker('{value['id']}','{fixture.TOKEN}')")
        return value['id']

    def ready(self):
        guest = self.start()
        self.complete_guest(guest)
        return guest

    def adopt_as(self, actor, owner, hash=HASH, fails=False):
        result = self.rpc(f"adopt_context_guest('{hash}','{actor}','{owner}')", fails=fails)
        return result if fails else json.loads(result)

    def expire(self, *hashes):
        quoted = ','.join(f"'{h}'" for h in hashes or (HASH,))
        self.sql(f"UPDATE context_guest_workspaces SET expires_at=now()-interval '1 minute' WHERE token_hash IN ({quoted})")

    def routing(self, request):
        return self.sql(f"SELECT owner_id||'|'||created_by||'|'||coalesce(input->>'organization_id','none')||'|'||status"
                        f" FROM context_requests WHERE id='{request}'")

    def readable_by(self, owner, request):
        return self.rpc(f"read_context_request('{owner}','{request}') IS NOT NULL") == 't'

    def receipt(self):
        return self.sql(f"SELECT claimed_by||'|'||claimed_owner||'|'||request_id FROM context_guest_workspaces WHERE token_hash='{HASH}'")

    def assert_no_roster(self):
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '0')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '0')

    def test_ready_work_adopts_into_personal_workspace(self):
        self.ready()
        adopted = self.adopt_as(ACTOR, ACTOR)
        self.assertFalse(adopted['reused'])
        self.assertEqual(self.routing(adopted['requestId']), f'{ACTOR}|{ACTOR}|none|completed')
        self.assertTrue(self.readable_by(ACTOR, adopted['requestId']))
        self.assertFalse(self.readable_by(ORG, adopted['requestId']))
        self.assert_research_only(adopted['requestId'])

    def test_running_work_completes_into_personal_workspace(self):
        guest = self.start()
        adopted = self.adopt_as(ACTOR, ACTOR)
        self.assertEqual(self.routing(adopted['requestId']), f'{ACTOR}|{ACTOR}|none|queued')
        self.complete_guest(guest)
        self.assertEqual(self.routing(adopted['requestId']), f'{ACTOR}|{ACTOR}|none|completed')
        self.assertFalse(self.readable_by(ORG, adopted['requestId']))
        self.assert_research_only(adopted['requestId'])

    def test_organization_adoption_keeps_actor_and_destination_separate(self):
        self.ready()
        adopted = self.adopt_as(ACTOR, ORG)
        self.assertEqual(self.routing(adopted['requestId']), f'{ORG}|{ACTOR}|{ORG}|completed')
        self.assertTrue(self.readable_by(ORG, adopted['requestId']))
        self.assertFalse(self.readable_by(ACTOR, adopted['requestId']))
        self.assert_research_only(adopted['requestId'])

    def test_adopted_work_cannot_move_to_another_workspace(self):
        self.sql(f"INSERT INTO accounts(id,name) VALUES ('{SECOND_ORG}','Second label');"
                 f"INSERT INTO account_organization_ids VALUES ('{ACTOR}','{SECOND_ORG}');")
        self.ready()
        first = self.adopt_as(ACTOR, ORG)
        for owner in (ACTOR, SECOND_ORG):
            self.assertIn('Guest work already claimed', self.adopt_as(ACTOR, owner, fails=True))
        self.assertEqual(self.receipt(), f"{ACTOR}|{ORG}|{first['requestId']}")
        self.assertEqual(self.sql('SELECT count(*) FROM context_requests'), '1')
        self.assert_research_only(first['requestId'])

    def test_account_created_after_guest_start_adopts_personally(self):
        guest = self.start()
        self.sql(f"INSERT INTO accounts(id,name) VALUES ('{NEW}','Newcomer')")
        self.complete_guest(guest)
        adopted = self.adopt_as(NEW, NEW)
        self.assertEqual(self.routing(adopted['requestId']), f'{NEW}|{NEW}|none|completed')
        self.assertTrue(self.readable_by(NEW, adopted['requestId']))
        self.assertFalse(self.readable_by(ACTOR, adopted['requestId']))
        self.assertEqual(self.sql(f"SELECT count(*) FROM account_organization_ids WHERE account_id='{NEW}'"), '0')
        self.assert_research_only(adopted['requestId'])

    def test_another_account_cannot_claim_adopted_work(self):
        self.ready()
        first = self.adopt_as(ACTOR, ORG)
        self.sql(f"INSERT INTO accounts(id,name) VALUES ('{NEW}','Newcomer')")
        for owner in (NEW, ORG):
            self.assertIn('Guest work already claimed', self.adopt_as(NEW, owner, fails=True))
        self.assertEqual(self.receipt(), f"{ACTOR}|{ORG}|{first['requestId']}")
        self.assertEqual(self.sql('SELECT count(*) FROM context_requests'), '1')

    def test_existing_account_adoption_reuses_explicit_roster_identity(self):
        artist = self.call().split('|')[0]
        self.ready()
        adopted = self.adopt_as(ACTOR, ORG)
        self.assertEqual(self.sql(f"SELECT s.artist_id FROM context_subjects s JOIN context_resource_links l ON l.subject_id=s.id "
                                  f"JOIN context_resources r ON r.id=l.resource_id WHERE r.provider='spotify' AND r.resource_kind='artist' "
                                  f"AND r.provider_id='{fixture.onboarding.SPOTIFY}' AND l.relation='identity'"), artist)
        self.assertEqual(self.sql(f"SELECT count(*) FROM account_socials a JOIN socials s ON s.id=a.social_id "
                                  f"WHERE s.profile_url LIKE '%artist/{fixture.onboarding.SPOTIFY}%'"), '1')
        self.assertEqual(self.sql(f"SELECT count(*) FROM account_artist_ids WHERE account_id='{ACTOR}' AND artist_id='{artist}'"), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM account_artist_ids'), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM artist_organization_ids'), '1')
        self.assertEqual(self.sql("SELECT count(*) FROM context_resource_links WHERE relation='credited_artist'"), '2')
        self.assertEqual(self.routing(adopted['requestId']), f'{ORG}|{ACTOR}|{ORG}|completed')

    def test_expired_unclaimed_session_is_unavailable_everywhere(self):
        guest = self.start()
        self.expire()
        self.assertEqual(self.rpc(f"read_context_guest('{HASH}') IS NULL"), 't')
        self.assertIn('Guest session expired', self.adopt_as(ACTOR, ACTOR, fails=True))
        self.assertIn('Guest session unavailable', self.rpc(f"start_context_guest('{HASH}','{INPUT}',repeat('c',64),100)", fails=True))
        self.assertIn('Guest session expired', self.rpc(f"complete_context_guest('{guest}','{fixture.TOKEN}','{json.dumps(fixture.PAYLOAD)}')", fails=True))
        self.assertEqual(self.rpc(f"claim_context_guest_worker('{guest}','{fixture.TOKEN}') IS NULL"), 't')
        self.assertEqual(self.sql('SELECT count(*) FROM context_requests'), '0')
        self.assert_no_roster()

    def test_repeated_adoption_is_idempotent_before_and_after_expiry(self):
        self.ready()
        first = self.adopt_as(ACTOR, ORG)
        again = self.adopt_as(ACTOR, ORG)
        self.assertEqual((again['reused'], again['requestId'], again['guestId']), (True, first['requestId'], first['guestId']))
        self.assertEqual(self.rpc(f"read_context_guest('{HASH}') IS NULL"), 't')
        self.assertIn('Guest session unavailable', self.rpc(f"start_context_guest('{HASH}','{INPUT}',repeat('c',64),100)", fails=True))
        self.expire()
        later = self.adopt_as(ACTOR, ORG)
        self.assertEqual((later['reused'], later['requestId']), (True, first['requestId']))
        self.assertEqual(self.sql('SELECT count(*) FROM context_requests'), '1')
        self.assert_research_only(first['requestId'])

    def test_purge_keeps_claimed_receipt_and_removes_unclaimed_work(self):
        self.ready()
        first = self.adopt_as(ACTOR, ORG)
        self.start(OTHER, run=False)
        self.start(FRESH, run=False)
        self.expire(HASH, OTHER)
        self.assertEqual(self.rpc('purge_expired_context_guests()'), '1')
        self.assertEqual(self.sql("SELECT string_agg(left(token_hash,1),',' ORDER BY token_hash) FROM context_guest_workspaces"), 'b,e')
        self.assertEqual(self.sql(f"SELECT payload IS NULL FROM context_guest_workspaces WHERE token_hash='{HASH}'"), 't')
        self.assertEqual(self.receipt(), f"{ACTOR}|{ORG}|{first['requestId']}")
        later = self.adopt_as(ACTOR, ORG)
        self.assertEqual((later['reused'], later['requestId']), (True, first['requestId']))
        self.assertEqual(self.rpc(f"read_context_guest('{OTHER}') IS NULL"), 't')
        self.assertEqual(self.rpc(f"read_context_guest('{FRESH}')->>'status'"), 'queued')
        self.assert_research_only(first['requestId'])

    def test_browser_roles_cannot_touch_guest_work(self):
        self.ready()
        calls = [f"adopt_context_guest('{HASH}','{ACTOR}','{ORG}')", f"read_context_guest('{HASH}')",
                 f"start_context_guest('{OTHER}','{INPUT}',repeat('c',64),100)", 'purge_expired_context_guests()',
                 'count(*) FROM context_guest_workspaces']
        for role in ('anon', 'authenticated'):
            for call in calls:
                self.assertIn('permission denied', self.sql(f"SET ROLE {role}; SELECT {call};", fails=True))
        self.assertEqual(self.sql('SELECT count(*) FROM context_requests'), '0')
        self.assertEqual(self.sql(f"SELECT claimed_by IS NULL FROM context_guest_workspaces WHERE token_hash='{HASH}'"), 't')
