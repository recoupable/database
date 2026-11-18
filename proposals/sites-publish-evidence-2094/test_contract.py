"""Synthetic Sites proposal on the existing disposable Unix-socket PostgreSQL harness."""
import concurrent.futures
import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
if os.environ.get('PG_BIN'):
    os.environ['PATH'] = os.environ['PG_BIN'] + os.pathsep + os.environ['PATH']
sys.path.insert(0, str(ROOT / 'tests'))
import test_release_cases as harness


def uid(n):
    return f'00000000-0000-0000-0000-{n:012d}'


def literal(value):
    return 'NULL' if value is None else "'" + str(value).replace("'", "''") + "'"


def canonical(value):
    # Fixtures use ASCII keys and safe integer values; checked against pinned API vectors.
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def candidate():
    return {'name': 'Synthetic preview', 'releaseUrl': '', 'assets': [], 'design': {
        'experience': {'html': '<button>Start</button>', 'css': '', 'javascript': 'void 0'}},
        'production': {'version': 1, 'context': {}, 'direction': {}, 'reviews': [], 'status': 'reviewed'}}


def projection(value):
    value = copy.deepcopy(value)
    if 'production' in value:
        value['production'].pop('reviews', None)
        value['production'].pop('status', None)
    return value


def report():
    return {'verdict': 'pass', 'issues': [], 'summary': 'Synthetic; no browser ran', 'verification': {
        'scope': 'generated-experience', 'humanApproval': 'not-recorded',
        'nativeShareDelivery': 'not-tested', 'spotifyAuthentication': 'not-tested',
        'evidence': {'sourceSha256': 'a' * 64, 'journeySha256': 'b' * 64, 'runnerSha256': 'c' * 64},
        'journey': {'releaseConnection': 'A concrete release connection', 'evidence': ['Synthetic'],
                    'motivation': 'A concrete motivation for participation', 'payoff': 'A concrete payoff from participation',
                    'capabilities': ['browser-interaction'], 'steps': [
                        {'action': 'click', 'target': 'Start', 'value': '', 'expected': '', 'checkpoint': checkpoint}
                        for checkpoint in ['participate', 'result', 'delivery']]},
        'viewports': [{'name': name, 'journeyPassed': True, 'errors': [], 'overflow': False}
                      for name in ['mobile', 'desktop']]}}


class SitesEvidence(harness.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('ALTER TABLE storage.buckets ADD COLUMN allowed_mime_types text[];')
        cls.sql((ROOT / 'supabase/migrations/20260918010000_sites.sql').read_text())
        cls.sql('ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO anon,authenticated,service_role; ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO service_role;')
        cls.sql((HERE / 'proposal.sql').read_text())
        cls.sql((HERE / 'fixture-grants.sql').read_text())

    def setUp(self):
        self.sql('TRUNCATE public.sites CASCADE; DELETE FROM public.account_organization_ids;')
        self.sql(f"""INSERT INTO accounts(id) VALUES ('{uid(1)}'),('{uid(2)}'),('{uid(3)}'),('{uid(4)}') ON CONFLICT DO NOTHING;
        INSERT INTO account_organization_ids(account_id,organization_id) VALUES ('{uid(2)}','{uid(1)}'),('{uid(3)}','{uid(1)}');
        INSERT INTO sites(id,owner_id,created_by,name,revision,draft) VALUES ('{uid(10)}','{uid(1)}','{uid(2)}','Fixture',2,{literal(json.dumps(candidate()))});""")

    def execute(self, statement, role='service_role'):
        return '\n'.join(line for line in self.sql(f'SET ROLE {role}; ' + statement).stdout.strip().splitlines() if line != 'SET')

    def record_sql(self, key='capture', actor=2, owner=1, revision=2, value=None, review=None, override=False, candidate_hash=None, report_hash=None, override_reason='Explicit synthetic choice'):
        value = candidate() if value is None else value
        ctext = canonical(projection(value))
        r = report() if review is None else review
        rtext = None if override else canonical(r)
        decision = {'kind': 'override', 'intent': 'publish-without-passed-review', 'reason': override_reason} if override else {
            'kind': 'review', 'review': r, 'reviewSha256': report_hash or digest(rtext)}
        args = [uid(actor), uid(owner), uid(10), revision, key, json.dumps(value), ctext,
                candidate_hash or digest(ctext), json.dumps(decision), rtext]
        return 'SELECT sites_evidence_proposal.record_evidence(' + ','.join(literal(v) for v in args) + ');'

    def record(self, **kwargs):
        return json.loads(self.execute(self.record_sql(**kwargs)))

    def publish_sql(self, record, actor=2, owner=1, revision=2, expected_pointer=None, expected_digest=None, expected_artist=None):
        args = [uid(actor), uid(owner), uid(10), revision, record['id'],
                expected_digest or record['candidateSha256'], expected_pointer, expected_artist]
        return 'SELECT sites_evidence_proposal.publish_candidate(' + ','.join(literal(v) for v in args) + ');'

    def state(self):
        return self.sql(f"SELECT row_to_json(s) FROM sites s WHERE id='{uid(10)}'").stdout.strip()

    def test_original_identity_time_and_payload_retry(self):
        first = self.record()
        self.assertEqual(first, self.record())
        self.assertEqual(first['recordedByAccountId'], uid(2))
        self.assertEqual(first['review'], report())
        self.assertEqual(self.sql('SELECT count(*) FROM sites_evidence_proposal.records').stdout.strip(), '1')
        for changes in [{'actor': 3}, {'review': {**report(), 'summary': 'changed'}}, {'value': {**candidate(), 'name': 'changed'}}]:
            with self.assertRaisesRegex(AssertionError, 'conflict'):
                self.record(**changes)

    def test_parallel_capture_returns_one_original_record(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            rows = list(pool.map(lambda _: self.record(), range(8)))
        self.assertTrue(all(row == rows[0] for row in rows))

    def test_roles_owner_and_scoped_read(self):
        row = self.record()
        statement = f"SELECT sites_evidence_proposal.read_evidence('{uid(2)}','{uid(1)}','{uid(10)}','{row['id']}');"
        self.assertEqual(json.loads(self.execute(statement)), row)
        for role in ['anon', 'authenticated']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.execute(statement, role)
        for kwargs in [{'actor': 4}, {'owner': 4}]:
            with self.assertRaisesRegex(AssertionError, 'denied|unavailable'):
                self.record(**kwargs)
        with self.assertRaisesRegex(AssertionError, 'denied|unavailable'):
            self.execute(statement.replace(uid(1), uid(4)))
        for operation in ['SELECT * FROM', 'DELETE FROM', 'TRUNCATE']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.execute(operation + ' sites_evidence_proposal.records;')
        with self.assertRaisesRegex(AssertionError, 'permission denied'):
            self.execute("UPDATE sites_evidence_proposal.records SET recorded_at=now();")

    def test_revocation_blocks_capture_retry_read_and_publish(self):
        row = self.record()
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{uid(2)}';")
        for statement in [self.record_sql(), self.publish_sql(row), f"SELECT sites_evidence_proposal.read_evidence('{uid(2)}','{uid(1)}','{uid(10)}','{row['id']}');"]:
            with self.assertRaisesRegex(AssertionError, 'denied'):
                self.execute(statement)

    def test_execute_privilege_revocation(self):
        signature = 'sites_evidence_proposal.publish_candidate(uuid,uuid,uuid,integer,uuid,text,uuid,uuid)'
        row = self.record()
        self.sql('REVOKE EXECUTE ON FUNCTION ' + signature + ' FROM service_role;')
        try:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.execute(self.publish_sql(row))
        finally:
            self.sql('GRANT EXECUTE ON FUNCTION ' + signature + ' TO service_role;')

    def test_publication_uses_stored_candidate_without_advancing_revision(self):
        row = self.record()
        # Same-revision draft movement cannot substitute a new snapshot for the selected record.
        self.sql(f"UPDATE sites SET draft='{{\"different\":true}}' WHERE id='{uid(10)}';")
        self.execute(self.publish_sql(row))
        state = json.loads(self.state())
        self.assertEqual(state['published'], candidate())
        self.assertEqual(state['published_evidence_id'], row['id'])
        self.assertEqual(state['revision'], 2)
        self.assertEqual(self.record(), row)

    def test_conflicts_leave_publication_unchanged(self):
        row = self.record()
        before = self.state()
        for kwargs in [{'revision': 1}, {'expected_digest': 'd' * 64}, {'expected_pointer': uid(88)}, {'owner': 4}]:
            with self.assertRaises(AssertionError):
                self.execute(self.publish_sql(row, **kwargs))
            self.assertEqual(self.state(), before)
        self.sql('UPDATE sites SET revision=3;')
        before = self.state()
        with self.assertRaisesRegex(AssertionError, 'conflict'):
            self.execute(self.publish_sql(row))
        self.assertEqual(self.state(), before)

    def test_concurrent_publications_have_one_pointer_winner(self):
        a = self.record(key='a')
        b = self.record(key='b', value={**candidate(), 'name': 'Another'})
        def attempt(row):
            try:
                self.execute(self.publish_sql(row))
                return row
            except AssertionError as error:
                self.assertIn('conflict', str(error))
                return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, [a, b]))
        winner = [r for r in results if r]
        self.assertEqual(len(winner), 1)
        self.assertEqual(json.loads(self.state())['published_evidence_id'], winner[0]['id'])

    def test_failed_or_malformed_reports_cannot_publish_even_direct_sql(self):
        mutations = [lambda r: r.update(verdict='revise'), lambda r: r.update(blocked='credits'),
            lambda r: r.update(issues=[{'severity': 'blocking', 'module': 'implementation', 'detail': 'bad', 'fix': 'fix'}]),
            lambda r: r.update(issues=[{'severity': 'minor', 'module': 'direction', 'detail': 'bad', 'fix': 'fix'}]),
            lambda r: r['verification'].pop('humanApproval'),
            lambda r: r['verification']['viewports'].pop(),
            lambda r: r['verification']['viewports'][1].update(name='mobile'),
            lambda r: r['verification']['viewports'][0].update(journeyPassed=False),
            lambda r: r['verification']['viewports'][0].update(errors=['failure']),
            lambda r: r['verification']['viewports'][0].update(overflow=True),
            lambda r: r['verification'].update(opening={'verdict': 'pass', 'issues': []}),
            lambda r: r['verification'].update(journey={}),
            lambda r: r['verification'].update(evidence={}),
            lambda r: r['verification'].update(viewports='malformed'),
            lambda r: r.update(issues=None)]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                r = report(); mutate(r)
                row = self.record(key=f'bad-{index}', review=r)
                before = self.state()
                with self.assertRaisesRegex(AssertionError, 'not eligible'):
                    self.execute(self.publish_sql(row))
                self.assertEqual(self.state(), before)

    def test_override_requires_explicit_intent_and_same_actor(self):
        row = self.record(override=True)
        with self.assertRaisesRegex(AssertionError, 'not eligible'):
            self.execute(self.publish_sql(row, actor=3))
        self.execute(self.publish_sql(row))
        self.assertEqual(json.loads(self.state())['published_evidence_id'], row['id'])
        for statement in [self.record_sql(key='bad', override=True).replace('publish-without-passed-review', 'publish'),
                          self.record_sql(key='bad', override=True).replace('Explicit synthetic choice', ' ')]:
            with self.assertRaises(AssertionError):
                self.execute(statement)

    def test_digest_mismatch_and_original_report_are_not_rewritten(self):
        for kwargs in [{'candidate_hash': '0' * 64}, {'report_hash': '0' * 64}]:
            with self.assertRaisesRegex(AssertionError, 'digest'):
                self.record(**kwargs)
        original = report()
        row = self.record(review=original)
        self.assertEqual(row['review']['verification']['evidence'], original['verification']['evidence'])

    def test_legacy_clear_unpublish_and_pointer_forgery(self):
        row = self.record()
        self.execute(self.publish_sql(row))
        self.execute("UPDATE sites SET published='{\"legacy\":true}', published_at=clock_timestamp();")
        state = json.loads(self.state())
        self.assertIsNone(state['published_evidence_id'])
        self.assertEqual(state['revision'], 2)
        with self.assertRaisesRegex(AssertionError, 'pointer'):
            self.execute(f"UPDATE sites SET published_evidence_id='{row['id']}';")
        self.execute(self.publish_sql(row))
        self.execute('UPDATE sites SET published=NULL,published_at=NULL;')
        self.assertIsNone(json.loads(self.state())['published_evidence_id'])
        self.assertEqual(json.loads(self.state())['revision'], 2)

    def test_delete_retention_and_immutable_guards(self):
        row = self.record()
        self.execute(self.publish_sql(row))
        for statement in ['UPDATE sites_evidence_proposal.records SET recorded_at=now();', 'DELETE FROM sites_evidence_proposal.records;']:
            with self.assertRaisesRegex(AssertionError, 'immutable'):
                self.sql(statement)
        self.execute(f"DELETE FROM sites WHERE id='{uid(10)}';")
        self.assertEqual(self.sql('SELECT count(*) FROM sites_evidence_proposal.records').stdout.strip(), '0')
        with self.assertRaisesRegex(AssertionError, 'unavailable'):
            self.execute(f"SELECT sites_evidence_proposal.read_evidence('{uid(2)}','{uid(1)}','{uid(10)}','{row['id']}');")

    def test_broad_defaults_do_not_leak_table_column_or_helper_access(self):
        self.assertEqual(self.sql("""SELECT bool_and(NOT has_table_privilege(role,'sites_evidence_proposal.records',privilege))
          FROM unnest(ARRAY['anon','authenticated','service_role']) role,
               unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) privilege;""").stdout.strip(), 't')
        self.assertEqual(self.sql("""SELECT bool_and(NOT has_column_privilege(role,'sites_evidence_proposal.records',column_name,privilege))
          FROM information_schema.columns, unnest(ARRAY['anon','authenticated','service_role']) role,
               unnest(ARRAY['SELECT','INSERT','UPDATE','REFERENCES']) privilege
          WHERE table_schema='sites_evidence_proposal' AND table_name='records';""").stdout.strip(), 't')
        self.assertEqual(self.sql("""SELECT bool_and(NOT has_function_privilege(role,p.oid,'EXECUTE')) FROM pg_proc p
          JOIN pg_namespace n ON n.oid=p.pronamespace, unnest(ARRAY['anon','authenticated']) role
          WHERE n.nspname='sites_evidence_proposal';""").stdout.strip(), 't')
        with self.assertRaisesRegex(AssertionError, 'permission denied'):
            self.execute("SELECT sites_evidence_proposal.review_passes('{}');")
        self.assertEqual(self.sql("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='sites_evidence_proposal' AND p.prosecdef
          AND p.proowner=n.nspowner AND p.proconfig=ARRAY['search_path=\"\"'];""").stdout.strip(), '4')

    def test_shadow_objects_do_not_redirect_definers(self):
        self.sql('CREATE SCHEMA sites_shadow; GRANT ALL ON SCHEMA sites_shadow TO service_role;')
        try:
            self.execute("CREATE TABLE sites_shadow.sites(id text); CREATE TABLE sites_shadow.records(id text); SET search_path=sites_shadow,public; " + self.record_sql())
            self.assertEqual(self.sql('SELECT count(*) FROM sites_evidence_proposal.records').stdout.strip(), '1')
            self.assertEqual(self.sql('SELECT count(*) FROM sites_shadow.records').stdout.strip(), '0')
            row = self.record()
            self.execute("CREATE TEMP TABLE pg_namespace(nspname text,nspowner oid); INSERT INTO pg_namespace SELECT 'sites_evidence_proposal',oid FROM pg_roles WHERE rolname='service_role'; " + self.publish_sql(row))
            self.assertEqual(json.loads(self.state())['published_evidence_id'], row['id'])
        finally:
            self.sql('DROP SCHEMA sites_shadow CASCADE;')

    def test_actor_null_missing_site_and_advanced_revision_retry(self):
        row = self.record()
        for statement in [self.record_sql().replace(literal(uid(2)), 'NULL', 1), self.record_sql().replace(uid(10), uid(99))]:
            with self.assertRaisesRegex(AssertionError, 'denied|unavailable'):
                self.execute(statement)
        self.sql('UPDATE sites SET revision=3;')
        with self.assertRaisesRegex(AssertionError, 'conflict'):
            self.record()
        self.assertEqual(json.loads(self.execute(f"SELECT sites_evidence_proposal.read_evidence('{uid(2)}','{uid(1)}','{uid(10)}','{row['id']}');")), row)

    def test_parallel_different_payload_same_key_has_one_winner(self):
        def attempt(name):
            try:
                return self.record(value={**candidate(), 'name': name})
            except AssertionError as error:
                self.assertIn('conflict', str(error))
                return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, ['A', 'B']))
        self.assertEqual(sum(row is not None for row in results), 1)
        self.assertEqual(self.sql('SELECT count(*) FROM sites_evidence_proposal.records').stdout.strip(), '1')

    def test_legacy_same_bytes_artist_timestamp_and_insert_pointer_guards(self):
        row = self.record()
        for statement in ['UPDATE sites SET published=published;', 'UPDATE sites SET published_at=clock_timestamp();',
                          f"UPDATE sites SET artist_id='{uid(4)}';"]:
            self.execute(self.publish_sql(row))
            self.execute(statement)
            self.assertIsNone(json.loads(self.state())['published_evidence_id'])
        self.execute(self.publish_sql(row, expected_artist=uid(4)))
        self.execute('UPDATE sites SET draft=draft,revision=revision+1,artist_id=artist_id;')
        self.assertEqual(json.loads(self.state())['published_evidence_id'], row['id'])
        with self.assertRaisesRegex(AssertionError, 'pointer'):
            self.execute(f"INSERT INTO sites(id,owner_id,created_by,name,published,published_evidence_id) VALUES ('{uid(11)}','{uid(1)}','{uid(2)}','Forgery','{{}}','{row['id']}');")
        before = self.state()
        with self.assertRaisesRegex(AssertionError, 'permission denied'):
            self.execute('TRUNCATE sites CASCADE;')
        self.assertEqual(self.state(), before)

    def test_failed_write_is_atomic_and_other_sites_survive_retention(self):
        self.sql("""CREATE FUNCTION sites_evidence_proposal.synthetic_fail() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN RAISE EXCEPTION 'synthetic storage failure'; END $$;
          CREATE TRIGGER synthetic_insert_failure BEFORE INSERT ON sites_evidence_proposal.records
          FOR EACH ROW EXECUTE FUNCTION sites_evidence_proposal.synthetic_fail();""")
        before = self.state()
        try:
            with self.assertRaisesRegex(AssertionError, 'synthetic storage failure'):
                self.record()
        finally:
            self.sql('DROP TRIGGER synthetic_insert_failure ON sites_evidence_proposal.records;')
        self.assertEqual(self.state(), before)
        self.assertEqual(self.sql('SELECT count(*) FROM sites_evidence_proposal.records').stdout.strip(), '0')
        row = self.record()
        self.sql('CREATE TRIGGER synthetic_publish_failure BEFORE UPDATE ON sites FOR EACH ROW EXECUTE FUNCTION sites_evidence_proposal.synthetic_fail();')
        try:
            with self.assertRaisesRegex(AssertionError, 'synthetic storage failure'):
                self.execute(self.publish_sql(row))
        finally:
            self.sql('DROP TRIGGER synthetic_publish_failure ON sites; DROP FUNCTION sites_evidence_proposal.synthetic_fail();')
        self.assertEqual(self.state(), before)
        self.sql(f"INSERT INTO sites(id,owner_id,created_by,name,revision) VALUES ('{uid(11)}','{uid(1)}','{uid(2)}','Other',2);")
        other = json.loads(self.execute(self.record_sql().replace(uid(10), uid(11))))
        self.execute(self.publish_sql(row))
        self.execute(f"DELETE FROM sites WHERE id='{uid(10)}';")
        self.assertEqual(self.sql('SELECT count(*) FROM sites_evidence_proposal.records').stdout.strip(), '1')
        self.assertEqual(json.loads(self.execute(f"SELECT sites_evidence_proposal.read_evidence('{uid(2)}','{uid(1)}','{uid(11)}','{other['id']}');")), other)

    def test_membership_revocation_waits_for_authorized_transaction(self):
        def capture():
            return self.sql("SET application_name='sites-capture-lock'; BEGIN; SET ROLE service_role; " + self.record_sql() + " SELECT pg_sleep(1.2); COMMIT;")
        def revoke():
            return self.sql(f"SET application_name='sites-revoke-lock'; DELETE FROM account_organization_ids WHERE account_id='{uid(2)}';")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(capture)
            deadline = time.monotonic() + 5
            while self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='sites-capture-lock' AND wait_event='PgSleep';").stdout.strip() != '1':
                if time.monotonic() > deadline:
                    self.fail('Capture did not reach held-lock checkpoint')
                time.sleep(0.02)
            second = pool.submit(revoke)
            while self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='sites-revoke-lock' AND cardinality(pg_blocking_pids(pid))>0;").stdout.strip() != '1':
                if time.monotonic() > deadline:
                    self.fail('Revocation was not observed waiting on membership lock')
                time.sleep(0.02)
            first.result(timeout=8); second.result(timeout=8)
        with self.assertRaisesRegex(AssertionError, 'denied'):
            self.record()

    def test_actual_api_digest_vectors_survive_jsonb_storage(self):
        vectors = json.loads((HERE / 'api-digest-vectors.json').read_text())
        for vector in vectors['vectors']:
            decision = {'kind': 'review', 'review': vector['review'], 'reviewSha256': vector['reviewSha256']}
            args = [uid(2), uid(1), uid(10), 2, vector['name'], json.dumps(vector['candidate']),
                    vector['candidateCanonical'], vector['candidateSha256'], json.dumps(decision), vector['reviewCanonical']]
            row = json.loads(self.execute('SELECT sites_evidence_proposal.record_evidence(' + ','.join(literal(v) for v in args) + ');'))
            self.assertEqual(row['candidateSha256'], vector['candidateSha256'])
            self.assertEqual(row['reviewSha256'], vector['reviewSha256'])
            self.assertEqual(row['review']['verification']['evidence'], vector['review']['verification']['evidence'])
            state = json.loads(self.state())
            self.execute(self.publish_sql(row, expected_pointer=state['published_evidence_id']))
            self.assertEqual(json.loads(self.state())['published'], vector['candidate'])

    def test_capture_binds_returned_final_save_revision_not_claim_revision(self):
        self.sql('UPDATE sites SET revision=1;')
        self.execute('UPDATE sites SET revision=revision+1;')  # Existing generation claim: now 2.
        final = candidate()
        final['production']['context'] = {'source': 'Synthetic assembled context'}
        self.execute(f"UPDATE sites SET draft={literal(json.dumps(final))},revision=revision+1;")
        saved = json.loads(self.state())
        self.assertEqual(saved['revision'], 3)
        with self.assertRaisesRegex(AssertionError, 'conflict'):
            self.record(revision=2, value=final)
        row = self.record(revision=saved['revision'], value=saved['draft'])
        self.assertEqual(row['revision'], 3)
        self.execute(self.publish_sql(row, revision=3))
        self.assertEqual(json.loads(self.state())['published'], final)

    def test_draft_write_waiting_after_publish_preserves_live_pointer(self):
        row = self.record()
        def publish():
            return self.sql("SET application_name='sites-publish-lock'; BEGIN; SET ROLE service_role; " + self.publish_sql(row) + " SELECT pg_sleep(1.2); COMMIT;")
        def edit():
            return self.sql("SET application_name='sites-draft-lock'; SET ROLE service_role; UPDATE sites SET revision=revision+1,draft='{\"newDraft\":true}',artist_id=artist_id;")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(publish)
            deadline = time.monotonic() + 5
            while self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='sites-publish-lock' AND wait_event='PgSleep';").stdout.strip() != '1':
                if time.monotonic() > deadline:
                    self.fail('Publisher did not hold site lock')
                time.sleep(0.02)
            second = pool.submit(edit)
            while self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='sites-draft-lock' AND cardinality(pg_blocking_pids(pid))>0;").stdout.strip() != '1':
                if time.monotonic() > deadline:
                    self.fail('Draft update was not observed waiting')
                time.sleep(0.02)
            first.result(timeout=8); second.result(timeout=8)
        saved = json.loads(self.state())
        self.assertEqual(saved['revision'], 3)
        self.assertEqual(saved['published'], candidate())
        self.assertEqual(saved['published_evidence_id'], row['id'])

    def test_owner_transition_cannot_orphan_retained_evidence(self):
        row = self.record()
        for published in [False, True]:
            if published:
                self.execute(self.publish_sql(row))
            before = self.state()
            with self.assertRaisesRegex(AssertionError, 'Evidence owner'):
                self.execute(f"UPDATE sites SET owner_id='{uid(4)}';")
            self.assertEqual(self.state(), before)

    def test_artist_selection_conflict_after_final_api_read(self):
        row = self.record()
        for selected, current in [(uid(3), uid(4)), (uid(3), None), (None, uid(4))]:
            with self.subTest(selected=selected, current=current):
                self.execute("UPDATE sites SET published=NULL,published_at=NULL;")
                self.execute(f"UPDATE sites SET artist_id={literal(selected)},published='{{\"legacy\":true}}',published_at='2026-01-01T00:00:00Z';")
                # The selected artist was observed by the final API read. A legacy writer
                # then changes it without advancing revision or the null evidence pointer.
                self.execute(f"UPDATE sites SET artist_id={literal(current)};")
                before = self.state()
                with self.assertRaisesRegex(AssertionError, 'Publication conflict'):
                    self.execute(self.publish_sql(row, expected_artist=selected))
                self.assertEqual(self.state(), before)

    def test_artist_selection_stable_and_null_match(self):
        row = self.record()
        for artist in [uid(3), None]:
            self.execute(f"UPDATE sites SET artist_id={literal(artist)};")
            before = json.loads(self.state())
            self.execute(self.publish_sql(row, expected_pointer=before['published_evidence_id'], expected_artist=artist))
            after = json.loads(self.state())
            self.assertEqual(after['artist_id'], artist)
            self.assertEqual(after['published'], candidate())
            self.assertEqual(after['published_evidence_id'], row['id'])
            self.assertEqual(after['revision'], 2)

    def test_artist_writer_lock_serializes_publication_fence(self):
        row = self.record()
        self.execute(f"UPDATE sites SET artist_id='{uid(3)}',published='{{\"legacy\":true}}',published_at='2026-01-01T00:00:00Z';")
        def change_artist():
            return self.sql(f"SET application_name='sites-artist-change'; BEGIN; SET ROLE service_role; UPDATE sites SET artist_id='{uid(4)}'; SELECT pg_sleep(1.2); COMMIT;")
        def publish():
            return self.sql("SET application_name='sites-artist-publish'; SET ROLE service_role; " + self.publish_sql(row, expected_artist=uid(3)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(change_artist)
            deadline = time.monotonic() + 5
            while self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='sites-artist-change' AND wait_event='PgSleep';").stdout.strip() != '1':
                if time.monotonic() > deadline:
                    self.fail('Artist writer did not hold site lock')
                time.sleep(0.02)
            before = json.loads(self.state())
            second = pool.submit(publish)
            while self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='sites-artist-publish' AND cardinality(pg_blocking_pids(pid))>0;").stdout.strip() != '1':
                if time.monotonic() > deadline:
                    self.fail('Publisher did not wait behind artist writer')
                time.sleep(0.02)
            first.result(timeout=8)
            with self.assertRaisesRegex(AssertionError, 'Publication conflict'):
                second.result(timeout=8)
        expected = {**before, 'artist_id': uid(4)}
        self.assertEqual(json.loads(self.state()), expected)

    def test_nonspace_whitespace_is_not_explicit_override_reason(self):
        for reason in ['\t', '\n', '\u00a0', '\ufeff']:
            with self.subTest(reason=repr(reason)):
                with self.assertRaisesRegex(AssertionError, 'Explicit override required'):
                    self.record(key=f'blank-{ord(reason)}', override=True, override_reason=reason)

    def test_corrupt_record_kind_is_not_eligible_for_direct_publication(self):
        row = self.record()
        # Privileged fixture-only corrupt seed stresses the publisher independently of its writer.
        self.sql(f"""INSERT INTO sites_evidence_proposal.records(id,site_id,owner_id,revision,operation_key,
          recorded_by_account_id,candidate,candidate_canonical,candidate_sha256,decision,review_canonical)
          SELECT '{uid(90)}',site_id,owner_id,revision,'corrupt',recorded_by_account_id,candidate,
          candidate_canonical,candidate_sha256,'{{"kind":"unknown"}}',NULL FROM sites_evidence_proposal.records;""")
        before = self.state()
        with self.assertRaisesRegex(AssertionError, 'not eligible'):
            self.execute(self.publish_sql({**row, 'id': uid(90)}))
        self.assertEqual(self.state(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
