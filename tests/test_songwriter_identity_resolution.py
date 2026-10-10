"""Operator-confirmed songwriter identity resolution on disposable PostgreSQL; no hosted credentials."""
import concurrent.futures
import json
import uuid

import test_release_cases as release_cases

ROOT = release_cases.ROOT
ACTOR = '30000000-0000-4000-8000-000000000001'
ORG = '30000000-0000-4000-8000-000000000002'
OTHER_ORG = '30000000-0000-4000-8000-000000000003'
OUTSIDER = '30000000-0000-4000-8000-000000000004'
MEMBER = '30000000-0000-4000-8000-000000000005'
GAP = 'Songwriter identity not confirmed'
MIGRATION = ROOT / 'supabase/migrations/20261010213600_context_songwriter_identity_resolution.sql'
COUNTS = ("SELECT count(*)||':'||(SELECT count(*) FROM public.organization_professionals)"
          "||':'||(SELECT count(*) FROM public.accounts) FROM public.context_results;")


class SongwriterIdentityResolution(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # The songwriter entry constraint chain references the catalog subject column.
        cls.sql('CREATE TABLE public.catalogs(id uuid PRIMARY KEY,name text,updated_at timestamptz DEFAULT now());'
                'CREATE TABLE public.account_catalogs(account uuid,catalog uuid);')
        for migration in ['20260922070000_context_catalog_entry.sql',
                          '20260925100000_context_songwriter_name_entry.sql',
                          '20261008050000_professional_roster.sql',
                          '20261008050100_confirm_professional_roster.sql']:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())
        if MIGRATION.exists():
            cls.sql(MIGRATION.read_text())
        cls.sql(f"INSERT INTO public.accounts(id,name) VALUES ('{ACTOR}','Operator'),('{ORG}','Workspace'),"
                f"('{OTHER_ORG}','Other workspace'),('{OUTSIDER}','Outsider'),('{MEMBER}','Second member')")

    def setUp(self):
        self.sql('DELETE FROM public.context_songwriter_identity_resolutions;' if MIGRATION.exists() else 'SELECT 1;')
        self.sql('DELETE FROM public.account_organization_ids;'
                 f"INSERT INTO public.account_organization_ids(account_id,organization_id) VALUES ('{ACTOR}','{ORG}'),('{MEMBER}','{ORG}')")

    def run_sql(self, statement):
        return self.sql(f'SET ROLE service_role; {statement}').stdout.strip().splitlines()[-1]

    def admin_sql(self, statement):
        return self.sql(statement).stdout.strip().splitlines()[-1]

    def failing(self, statement):
        with self.assertRaises(AssertionError) as raised:
            self.sql(f'\\set VERBOSITY verbose\nSET ROLE service_role; {statement}')
        return str(raised.exception)

    def songwriter_request(self, name='Writer Example', owner=ORG, actor=ACTOR):
        key = f'writer-{uuid.uuid4()}'
        return json.loads(self.run_sql(
            f"SELECT public.create_context_songwriter_name_request('{owner}','{actor}','{name}','{key}');"))

    def professional(self, name='Writer Example', org=ORG, actor=ACTOR):
        command = json.dumps({'mode': 'new', 'name': name, 'roles': ['songwriter'], 'roster_intent': 'add', 'confirmed': True})
        return json.loads(self.run_sql(
            f"SELECT public.confirm_professional_roster('{actor}','{org}','{uuid.uuid4()}','{command}'::jsonb);"))['professional']

    def resolve(self, request, professional, key=None, actor=ACTOR, owner=ORG, fails=False):
        if key is None:
            key = f'resolve-{uuid.uuid4()}'
        statement = (f"SELECT public.resolve_context_songwriter_identity('{actor}','{owner}','{request}',"
                     f"'{professional}','{key}');")
        return self.failing(statement) if fails else json.loads(self.run_sql(statement))

    def target(self, request, owner=ORG):
        return json.loads(self.run_sql(f"SELECT public.list_context_songwriter_request_target('{owner}','{request}');"))

    def read(self, request, owner=ORG):
        return json.loads(self.run_sql(f"SELECT public.read_context_request('{owner}','{request}');"))

    def count(self, where='true'):
        return int(self.run_sql(f'SELECT count(*) FROM public.context_songwriter_identity_resolutions WHERE {where};'))

    def test_resolution_links_request_to_selected_professional(self):
        request = self.songwriter_request()
        before = self.target(request['id'])
        self.assertFalse(before['identityConfirmed'])
        self.assertNotIn('professionalId', before)
        self.assertEqual(request['output']['gaps'], [GAP])
        person = self.professional()
        counts = self.admin_sql(COUNTS)
        key = 'resolve-writer-1'
        receipt = self.resolve(request['id'], person['id'], key=key)
        self.assertTrue(receipt['created'])
        resolution = receipt['resolution']
        self.assertEqual(resolution['request_id'], request['id'])
        self.assertEqual(resolution['subject_id'], before['subjectId'])
        self.assertEqual(resolution['professional_id'], person['id'])
        self.assertEqual(resolution['resolved_by'], ACTOR)
        self.assertEqual(resolution['resolution_basis'], 'operator_confirmed')
        self.assertNotIn('request_key', resolution)
        after = self.target(request['id'])
        self.assertTrue(after['identityConfirmed'])
        self.assertEqual(after['professionalId'], person['id'])
        self.assertEqual(after['subjectId'], before['subjectId'])
        self.assertEqual(after['availableFields'], ['submitted_name'])
        saved = self.read(request['id'])
        self.assertEqual(saved['output']['resolvedProfessionalId'], person['id'])
        self.assertEqual(saved['output']['gaps'], [])
        self.assertEqual(saved['output']['subjectIds'], request['output']['subjectIds'])
        self.assertEqual(saved['input'], request['input'])
        self.assertEqual(saved['status'], 'partial')
        # Resolution adds no evidence, no roster member and no login account.
        self.assertEqual(self.admin_sql(COUNTS), counts)

    def test_exact_replay_and_parallel_calls_create_one_resolution(self):
        request = self.songwriter_request()
        person = self.professional()
        key = 'resolve-parallel'
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            receipts = list(pool.map(lambda _: self.resolve(request['id'], person['id'], key=key), range(16)))
        self.assertEqual(len({json.dumps(r['resolution'], sort_keys=True) for r in receipts}), 1)
        self.assertEqual(sum(1 for r in receipts if r['created']), 1)
        self.assertEqual(self.count(), 1)
        replay = self.resolve(request['id'], person['id'], key=key)
        self.assertFalse(replay['created'])
        self.assertEqual(replay['resolution'], receipts[0]['resolution'])
        self.assertEqual(self.count(), 1)

    def test_same_key_cannot_name_a_different_request_professional_or_actor(self):
        first = self.songwriter_request()
        second = self.songwriter_request(name='Other Writer')
        person = self.professional()
        other = self.professional(name='Other Writer')
        key = 'resolve-shared-key'
        self.resolve(first['id'], person['id'], key=key)
        for request, professional, actor in [(second['id'], person['id'], ACTOR),
                                             (second['id'], other['id'], ACTOR),
                                             (first['id'], other['id'], ACTOR),
                                             (first['id'], person['id'], MEMBER)]:
            error = self.resolve(request, professional, key=key, actor=actor, fails=True)
            self.assertIn('23505', error)
        self.assertEqual(self.count(), 1)
        self.assertFalse(self.target(second['id'])['identityConfirmed'])

    def test_second_professional_for_a_resolved_request_is_rejected_not_overwritten(self):
        request = self.songwriter_request()
        person = self.professional()
        other = self.professional()
        self.resolve(request['id'], person['id'])
        error = self.resolve(request['id'], other['id'], fails=True)
        self.assertIn('23505', error)
        self.assertEqual(self.target(request['id'])['professionalId'], person['id'])
        self.assertEqual(self.read(request['id'])['output']['resolvedProfessionalId'], person['id'])
        self.assertEqual(self.count(), 1)

    def test_professional_from_another_organization_is_denied(self):
        request = self.songwriter_request()
        foreign = self.professional(org=OTHER_ORG, actor=OTHER_ORG)
        error = self.resolve(request['id'], foreign['id'], fails=True)
        self.assertIn('42501', error)
        self.assertIn('42501', self.resolve(request['id'], str(uuid.uuid4()), fails=True))
        self.assertEqual(self.count(), 0)
        self.assertFalse(self.target(request['id'])['identityConfirmed'])
        self.assertEqual(self.read(request['id'])['output']['gaps'], [GAP])
        # The other workspace cannot resolve this workspace's request either.
        self.assertIn('22023', self.resolve(request['id'], foreign['id'], actor=OTHER_ORG, owner=OTHER_ORG, fails=True))

    def test_revoked_or_missing_membership_is_denied_including_replay(self):
        request = self.songwriter_request()
        person = self.professional()
        self.assertIn('42501', self.resolve(request['id'], person['id'], actor=OUTSIDER, fails=True))
        self.assertEqual(self.count(), 0)
        key = 'resolve-revoked'
        self.resolve(request['id'], person['id'], key=key)
        self.sql(f"DELETE FROM public.account_organization_ids WHERE account_id='{ACTOR}'")
        self.assertIn('42501', self.resolve(request['id'], person['id'], key=key, fails=True))
        other = self.songwriter_request(name='Second Writer')
        self.assertIn('42501', self.resolve(other['id'], person['id'], fails=True))
        self.assertEqual(self.count(), 1)
        self.assertFalse(self.target(other['id'])['identityConfirmed'])

    def test_same_name_professionals_are_candidates_until_an_id_is_selected(self):
        request = self.songwriter_request(name='Same Name')
        first = self.professional(name='Same Name')
        second = self.professional(name='Same Name')
        self.assertFalse(self.target(request['id'])['identityConfirmed'])
        receipt = self.resolve(request['id'], second['id'])
        self.assertEqual(receipt['resolution']['professional_id'], second['id'])
        self.assertNotEqual(receipt['resolution']['professional_id'], first['id'])
        self.assertEqual(self.target(request['id'])['professionalId'], second['id'])

    def test_unready_or_withdrawn_requests_and_invalid_keys_are_rejected(self):
        person = self.professional()
        self.assertIn('22023', self.resolve(str(uuid.uuid4()), person['id'], fails=True))
        request = self.songwriter_request()
        self.assertIn('22023', self.resolve(request['id'], person['id'], key='', fails=True))
        self.assertIn('22023', self.resolve(request['id'], person['id'], key='k' * 201, fails=True))
        self.run_sql(f"SELECT public.withdraw_context_source('{ORG}',s.id) FROM public.context_sources s "
                     f"JOIN public.context_resources r ON r.canonical_url=s.source_url AND r.id='{request['resource_id']}' "
                     f"WHERE s.owner_id='{ORG}' AND s.kind='customer';")
        self.assertIn('22023', self.resolve(request['id'], person['id'], fails=True))
        self.assertEqual(self.count(), 0)

    def test_client_roles_cannot_read_or_execute(self):
        request = self.songwriter_request()
        person = self.professional()
        for role in ['anon', 'authenticated']:
            for statement in ['SELECT * FROM public.context_songwriter_identity_resolutions',
                              f"SELECT public.resolve_context_songwriter_identity('{ACTOR}','{ORG}','{request['id']}','{person['id']}','k')",
                              f"SELECT public.list_context_songwriter_request_target('{ORG}','{request['id']}')"]:
                with self.assertRaises(AssertionError) as raised:
                    self.sql(f'SET ROLE {role}; {statement};')
                self.assertIn('permission denied', str(raised.exception))

    def test_receipt_failure_rolls_back_request_output(self):
        request = self.songwriter_request()
        person = self.professional()
        self.sql('ALTER TABLE public.context_songwriter_identity_resolutions ADD CONSTRAINT fixture_fail CHECK(false) NOT VALID')
        try:
            self.assertIn('fixture_fail', self.resolve(request['id'], person['id'], fails=True))
        finally:
            self.sql('ALTER TABLE public.context_songwriter_identity_resolutions DROP CONSTRAINT fixture_fail')
        saved = self.read(request['id'])
        self.assertEqual(saved['output']['gaps'], [GAP])
        self.assertNotIn('resolvedProfessionalId', saved['output'])
        self.assertFalse(self.target(request['id'])['identityConfirmed'])
        self.assertEqual(self.count(), 0)
