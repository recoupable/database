"""Organization baseline reads use synthetic local records and real migrations."""
import json
import uuid
import test_release_cases as release_fixture

ROOT = release_fixture.ROOT

MIGRATION = ROOT / 'supabase/migrations/20261009160000_context_company_baseline.sql'


class CompanyBaseline(release_fixture.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('''CREATE TABLE artist_organization_ids(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          artist_id uuid REFERENCES accounts(id),organization_id uuid REFERENCES accounts(id));
          GRANT SELECT ON accounts,artist_organization_ids TO service_role;''')
        cls.sql((ROOT / 'supabase/migrations/20261008050000_professional_roster.sql').read_text())
        cls.sql(MIGRATION.read_text())

    def setUp(self):
        self.actor, self.org, self.other = [str(uuid.uuid4()) for _ in range(3)]
        self.sql(f"""INSERT INTO accounts VALUES ('{self.actor}','Operator'),('{self.org}','Label fixture'),('{self.other}','Other label');
          INSERT INTO account_organization_ids(account_id,organization_id) VALUES ('{self.actor}','{self.org}');""")

    def statement(self, org=None, cursors='NULL,NULL,NULL'):
        return f"SET ROLE service_role; SELECT read_context_company_baseline('{self.actor}','{org or self.org}',{cursors});"

    def baseline(self, **kwargs):
        return json.loads(self.sql(self.statement(**kwargs)).stdout.strip().splitlines()[-1])

    def test_empty_baseline_is_partial_not_complete_company(self):
        data = self.baseline()
        self.assertEqual(data['organization_id'], self.org)
        self.assertEqual(data['artists'], {'items': [], 'next_id': None})
        self.assertEqual(data['professionals'], {'items': [], 'next_id': None})
        self.assertEqual(data['sources'], {'items': [], 'next_id': None})
        self.assertEqual(data['coverage'], 'registered_roster_and_context_sources_only')
        self.assertIn('company_relationships_not_linked', data['gaps'])
        self.assertIn('rights_and_mandates_not_assessed', data['gaps'])

    def test_combines_existing_ids_without_merging_same_name_or_leaking_other_scope(self):
        artist, professional = str(uuid.uuid4()), str(uuid.uuid4())
        self.sql(f"""INSERT INTO accounts VALUES ('{artist}','Same name');
          INSERT INTO artist_organization_ids(artist_id,organization_id) VALUES ('{artist}','{self.org}');
          INSERT INTO organization_professionals(id,organization_id,name,roles,confirmed_by) VALUES
           ('{professional}','{self.org}','Same name',ARRAY['songwriter','producer'],'{self.actor}'),
           (gen_random_uuid(),'{self.other}','Private other',ARRAY['producer'],'{self.other}');""")
        data = self.baseline()
        self.assertEqual(data['artists']['items'][0]['artist_id'], artist)
        self.assertEqual(data['professionals']['items'][0]['professional_id'], professional)
        self.assertEqual(data['professionals']['items'][0]['roles'], ['songwriter', 'producer'])
        self.assertNotIn('Private other', json.dumps(data))

    def test_source_register_excludes_withdrawn_sources_and_removed_versions(self):
        source, hidden = str(uuid.uuid4()), str(uuid.uuid4())
        self.sql(f"""INSERT INTO context_sources(id,owner_id,kind,source_url) VALUES
          ('{source}','{self.org}','customer','https://private.example/source'),
          ('{hidden}','{self.other}','customer','https://private.example/other');
          INSERT INTO context_source_versions(owner_id,source_id,fingerprint,content,removed_at) VALUES
          ('{self.org}','{source}',repeat('a',64),'{{"secret":"raw document"}}',NULL),
          ('{self.org}','{source}',repeat('b',64),'{{}}',now());""")
        data = self.baseline()
        self.assertEqual(data['sources']['items'][0]['retained_version_count'], 1)
        self.assertNotIn('raw document', json.dumps(data))
        self.assertNotIn('private.example', json.dumps(data))
        self.sql(f"UPDATE context_sources SET withdrawn_at=now() WHERE id='{source}'")
        self.assertEqual(self.baseline()['sources']['items'], [])

    def test_denies_nonmember_and_revoked_member(self):
        for org in [self.other, self.org]:
            if org == self.org:
                self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
            with self.assertRaisesRegex(AssertionError, 'Case access denied'):
                self.baseline(org=org)

    def test_browser_roles_cannot_invoke(self):
        for role in ['anon', 'authenticated']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(self.statement().replace('service_role', role))

    def test_pagination_is_independent_and_never_silently_truncates(self):
        self.sql(f"""INSERT INTO organization_professionals(organization_id,name,roles,confirmed_by)
          SELECT '{self.org}','Person '||n,ARRAY['songwriter'],'{self.actor}' FROM generate_series(1,51) n;
          INSERT INTO context_sources(owner_id,kind) SELECT '{self.org}','customer' FROM generate_series(1,51);
          WITH new_artists AS (INSERT INTO accounts SELECT gen_random_uuid(),'Artist '||n
            FROM generate_series(1,51) n RETURNING id)
          INSERT INTO artist_organization_ids(artist_id,organization_id) SELECT id,'{self.org}' FROM new_artists;""")
        first = self.baseline()
        self.assertEqual(len(first['artists']['items']), 50)
        self.assertEqual(len(first['professionals']['items']), 50)
        self.assertEqual(len(first['sources']['items']), 50)
        second = self.baseline(cursors=f"'{first['artists']['next_id']}','{first['professionals']['next_id']}','{first['sources']['next_id']}'")
        self.assertEqual(len(second['artists']['items']), 1)
        self.assertIsNone(second['artists']['next_id'])
        self.assertEqual(len({p['artist_id'] for p in first['artists']['items']+second['artists']['items']}),51)
        self.assertEqual(len(second['professionals']['items']), 1)
        self.assertEqual(len(second['sources']['items']), 1)
        self.assertIsNone(second['professionals']['next_id'])
        self.assertIsNone(second['sources']['next_id'])
        self.assertEqual(len({p['professional_id'] for p in first['professionals']['items']+second['professionals']['items']}),51)
