"""Operator-asserted company relationships on disposable PostgreSQL; no hosted database or providers."""
import concurrent.futures
import json
import uuid
import test_release_cases as release_cases

ROOT = release_cases.ROOT
PREREQUISITES = [
    '20260922070000_context_catalog_entry.sql',
    '20260925100000_context_songwriter_name_entry.sql',
    '20260925110000_context_company_name_entry.sql',
    '20261008050000_professional_roster.sql',
]
MIGRATION = ROOT / 'supabase/migrations/20261010213700_context_company_relationships.sql'
GAPS = ['operator_assertion_not_verified', 'no_ownership_rights_or_mandate_implied', 'no_access_granted']


def quoted(value):
    return 'NULL' if value is None else "'" + str(value).replace("'", "''") + "'"


class CompanyRelationships(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('''CREATE TABLE public.catalogs(id uuid PRIMARY KEY);
          CREATE TABLE public.artist_organization_ids(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            artist_id uuid REFERENCES public.accounts(id),organization_id uuid REFERENCES public.accounts(id));
          CREATE TABLE public.account_artist_ids(account_id uuid REFERENCES public.accounts(id),artist_id uuid REFERENCES public.accounts(id));
          GRANT SELECT ON public.accounts,public.artist_organization_ids,public.account_artist_ids TO service_role;''')
        for name in PREREQUISITES:
            cls.sql((ROOT / 'supabase/migrations' / name).read_text())
        cls.sql(MIGRATION.read_text())

    def setUp(self):
        ids = [str(uuid.uuid4()) for _ in range(6)]
        self.actor, self.org, self.other_actor, self.other_org, self.artist, self.other_artist = ids
        self.sql(f"""INSERT INTO accounts VALUES ('{self.actor}','Operator'),('{self.org}','Label workspace'),
          ('{self.other_actor}','Other operator'),('{self.other_org}','Other workspace'),
          ('{self.artist}','Roster artist'),('{self.other_artist}','Other roster artist');
          INSERT INTO account_organization_ids(account_id,organization_id)
          VALUES ('{self.actor}','{self.org}'),('{self.other_actor}','{self.other_org}');
          INSERT INTO artist_organization_ids(artist_id,organization_id)
          VALUES ('{self.artist}','{self.org}'),('{self.other_artist}','{self.other_org}');""")
        self.professional = self.insert_professional(self.org, self.actor)
        self.other_professional = self.insert_professional(self.other_org, self.other_actor)
        self.company = self.company_subject(self.org, self.actor, 'Third-party label', 'company-fixture')

    def insert_professional(self, org, actor):
        return self.sql(f"""INSERT INTO organization_professionals(organization_id,name,roles,confirmed_by)
          VALUES ('{org}','Workspace writer',ARRAY['songwriter'],'{actor}') RETURNING id""").stdout.splitlines()[0]

    def call(self, statement, role='service_role'):
        return json.loads(self.sql(f'SET ROLE {role}; {statement}').stdout.strip().splitlines()[-1])

    def company_subject(self, owner, actor, name, key):
        request = self.call(f"SELECT create_context_company_name_request('{owner}','{actor}','{name}','{key}');")
        self.assertIs(request['input']['identityConfirmed'], False)
        return request['output']['subjectIds'][0]

    def record_statement(self, counterparty, kind='frontline_roster', status='current', started=None, ended=None,
                         note='', key=None, actor=None, owner=None, company=None, supersedes=None):
        return (f"SELECT record_context_company_relationship({quoted(actor or self.actor)},{quoted(owner or self.org)},"
                f"{quoted(company or self.company)},{quoted(json.dumps(counterparty))},{quoted(kind)},{quoted(status)},"
                f"{quoted(started)},{quoted(ended)},{quoted(note)},{quoted(key or uuid.uuid4())}"
                + (f",{quoted(supersedes)}" if supersedes else '') + ');')

    def record(self, counterparty, **kwargs):
        return self.call(self.record_statement(counterparty, **kwargs))

    def listing(self, after=None, actor=None, owner=None, company=None, role='service_role'):
        return self.call(f"SELECT list_context_company_relationships({quoted(actor or self.actor)},"
                         f"{quoted(owner or self.org)},{quoted(company or self.company)},{quoted(after)});", role)

    def withdraw_company_source(self, owner, company):
        source = self.sql(f"""SELECT DISTINCT v.source_id FROM context_documents d
          JOIN context_result_sources rs ON rs.result_id=d.current_result_id AND rs.owner_id=d.owner_id
          JOIN context_source_versions v ON v.id=rs.source_version_id AND v.owner_id=rs.owner_id
          WHERE d.owner_id='{owner}' AND d.subject_id='{company}' AND d.topic='company_input'""").stdout.split()
        self.assertEqual(len(source), 1)
        # The real lifecycle primitive: it withdraws the results and clears current_result_id.
        self.assertEqual(self.sql(f"SET ROLE service_role; SELECT withdraw_context_source('{owner}','{source[0]}')")
                         .stdout.strip().splitlines()[-1], 't')
        self.assertEqual(self.sql(f"""SELECT count(*) FROM context_documents WHERE owner_id='{owner}'
          AND subject_id='{company}' AND topic='company_input' AND current_result_id IS NULL""").stdout.strip(), '1')

    def count(self, table, column, owner=None):
        return int(self.sql(f"SELECT count(*) FROM {table} WHERE {column}='{owner or self.org}'").stdout.strip())

    def scope_counts(self):
        return {'relationships': self.count('context_company_relationships', 'owner_id'),
                'roster': self.count('artist_organization_ids', 'organization_id'),
                'members': self.count('account_organization_ids', 'organization_id'),
                'personal_artists': self.count('account_artist_ids', 'account_id', self.actor)}

    def test_third_party_company_research_creates_no_relationship_or_membership(self):
        before = self.scope_counts()
        subject = self.company_subject(self.org, self.actor, 'Researched publisher', 'company-research')
        self.assertEqual(self.sql(f"SELECT kind FROM context_subjects WHERE id='{subject}'").stdout.strip(), 'company')
        self.assertEqual(self.sql("SELECT count(*) FROM accounts WHERE name='Researched publisher'").stdout.strip(), '0')
        self.assertEqual(self.scope_counts(), before)
        page = self.listing(company=subject)
        self.assertEqual(page['items'], [])
        self.assertEqual(page['state'], 'available')
        self.assertEqual(page['coverage'], 'operator_asserted_relationships_only')
        self.assertEqual(page['gaps'], GAPS)

    def test_frontline_roster_is_distinct_from_catalog_interest_including_former(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        before = self.scope_counts()
        current = self.record(artist, kind='frontline_roster', status='current', started='2021-01-15', key='roster-current')
        interest = self.record(artist, kind='catalog_interest', status='current', key='catalog-interest')
        former = self.record(artist, kind='frontline_roster', status='former', started='2018-03-01', ended='2020-12-31',
                             note=' Left after second album ', key='roster-former')
        self.assertEqual(len({current['relationship']['id'], interest['relationship']['id'], former['relationship']['id']}), 3)
        self.assertEqual(former['relationship']['note'], 'Left after second album')
        self.assertIs(former['replayed'], False)
        self.assertIsNone(current['relationship']['ended_on'])
        self.assertIsNone(interest['relationship']['started_on'])
        self.assertEqual(current['gaps'], GAPS)
        page = self.listing()
        self.assertEqual(sorted((item['relationship_kind'], item['status']) for item in page['items']),
                         [('catalog_interest', 'current'), ('frontline_roster', 'current'), ('frontline_roster', 'former')])
        self.assertTrue(all(item['counterparty'] == artist and item['basis'] == 'operator_assertion'
                            and item['asserted_by'] == self.actor and item['supersedes_id'] is None
                            and item['superseded_by'] is None for item in page['items']))
        self.assertIsNone(page['next_id'])
        # Assertions grant nothing: roster, membership and personal artist links are untouched.
        self.assertEqual(self.scope_counts(), {**before, 'relationships': 3})
        self.assertNotIn('ownership', json.dumps(page['items']))

    def test_leaving_the_roster_supersedes_the_current_row_without_rewriting_it(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        current = self.record(artist, started='2021-01-15', key='roster-current')['relationship']
        interest = self.record(artist, kind='catalog_interest', key='catalog-interest')['relationship']
        left = self.record(artist, status='former', started='2021-01-15', ended='2024-06-30', note='Left the roster',
                           key='roster-left', supersedes=current['id'])
        self.assertEqual(left['relationship']['supersedes_id'], current['id'])
        self.assertIsNone(left['relationship']['superseded_by'])
        items = {item['id']: item for item in self.listing()['items']}
        # The earlier row stays as history, unchanged, and now names the row that replaced it.
        self.assertEqual(items[current['id']], {**current, 'superseded_by': left['relationship']['id']})
        self.assertEqual(items[interest['id']], interest)
        in_force = sorted((item['relationship_kind'], item['status']) for item in items.values()
                          if item['superseded_by'] is None)
        self.assertEqual(in_force, [('catalog_interest', 'current'), ('frontline_roster', 'former')])
        again = self.record(artist, status='former', started='2021-01-15', ended='2024-06-30', note='Left the roster',
                            key='roster-left', supersedes=current['id'])
        self.assertIs(again['replayed'], True)
        self.assertEqual(again['relationship'], left['relationship'])
        with self.assertRaisesRegex(AssertionError, 'Idempotency key already used for different input'):
            self.record(artist, status='former', started='2021-01-15', ended='2024-06-30', note='Left the roster',
                        key='roster-left')
        with self.assertRaisesRegex(AssertionError, 'Company relationship already superseded'):
            self.record(artist, status='former', ended='2024-07-01', key='roster-left-again', supersedes=current['id'])
        foreign_company = self.company_subject(self.other_org, self.other_actor, 'Other label', 'company-supersede')
        foreign = self.record({'kind': 'workspace'}, actor=self.other_actor, owner=self.other_org,
                              company=foreign_company, key='foreign')['relationship']['id']
        other_company = self.company_subject(self.org, self.actor, 'Second label', 'company-second')
        elsewhere = self.record(artist, company=other_company, key='elsewhere')['relationship']['id']
        # Unknown, foreign, other-company, other-counterparty and other-kind rows share one rejection.
        for target, changes in [(str(uuid.uuid4()), {}), (foreign, {}), (elsewhere, {}),
                                (interest['id'], {}), (current['id'], {'kind': 'catalog_interest'}),
                                (interest['id'], {'counterparty': {'kind': 'workspace'}})]:
            with self.assertRaisesRegex(AssertionError, 'Invalid superseded relationship'):
                self.record(changes.get('counterparty', artist), kind=changes.get('kind', 'frontline_roster'),
                            status='former', supersedes=target)
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 4)

    def test_parallel_supersessions_of_one_row_keep_a_single_successor(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        current = self.record(artist, key='roster-current')['relationship']['id']

        def supersede(n):
            try:
                return self.record(artist, status='former', key=f'left-{n}', supersedes=current)
            except AssertionError as error:
                self.assertIn('Company relationship already superseded', str(error))
                return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = [result for result in pool.map(supersede, range(8)) if result]
        self.assertEqual(len(results), 1)
        successors = self.sql(f"""SELECT count(*) FROM context_company_relationships
          WHERE supersedes_id='{current}'""").stdout.strip()
        self.assertEqual(successors, '1')

    def test_workspace_and_professional_counterparties_stay_inside_the_workspace(self):
        own = self.record({'kind': 'workspace'}, kind='distribution', key='distribution')
        writer = self.record({'kind': 'professional', 'professional_id': self.professional}, kind='publishing', key='publishing')
        self.assertEqual(own['relationship']['counterparty'], {'kind': 'workspace'})
        self.assertEqual(writer['relationship']['counterparty'], {'kind': 'professional', 'professional_id': self.professional})
        self.assertEqual(self.count('organization_professionals', 'organization_id'), 1)
        self.assertEqual(self.count('organization_professionals', 'organization_id', self.other_org), 1)
        self.assertEqual(len(self.listing()['items']), 2)

    def test_exact_replay_returns_saved_row_and_changed_input_conflicts(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        base = dict(status='former', ended='2020-12-31', note='Left', key='replay')
        first = self.record(artist, **base)
        again = self.record(artist, **{**base, 'note': '  Left '})
        self.assertEqual(again['relationship'], first['relationship'])
        self.assertIs(again['replayed'], True)
        for changes in [dict(status='current', ended=None), dict(ended='2021-01-01'), dict(note='Different'),
                        dict(kind='catalog_interest'), dict(started='2018-01-01')]:
            with self.assertRaisesRegex(AssertionError, 'Idempotency key already used for different input'):
                self.record(artist, **{**base, **changes})
        with self.assertRaisesRegex(AssertionError, 'Idempotency key already used for different input'):
            self.record({'kind': 'workspace'}, **base)
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 1)

    def test_parallel_retries_store_one_relationship(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.record(artist, kind='catalog_interest', key='parallel'), range(16)))
        self.assertEqual({result['relationship']['id'] for result in results}, {results[0]['relationship']['id']})
        self.assertEqual(sum(not result['replayed'] for result in results), 1)
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 1)

    def test_foreign_actor_subject_artist_and_professional_are_denied_without_hints(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        foreign_company = self.company_subject(self.other_org, self.other_actor, 'Private other company', 'company-other')
        with self.assertRaisesRegex(AssertionError, 'Case access denied'):
            self.record(artist, actor=self.other_actor)
        messages = []
        for company in (foreign_company, str(uuid.uuid4())):
            with self.assertRaisesRegex(AssertionError, 'Company relationship denied') as denied:
                self.record({'kind': 'workspace'}, company=company)
            messages.append(str(denied.exception))
        self.assertEqual(messages[0], messages[1])
        self.assertNotIn('Private other company', messages[0])
        for counterparty in ({'kind': 'artist_account', 'artist_id': self.other_artist},
                             {'kind': 'artist_account', 'artist_id': str(uuid.uuid4())},
                             {'kind': 'professional', 'professional_id': self.other_professional},
                             {'kind': 'professional', 'professional_id': str(uuid.uuid4())}):
            with self.assertRaisesRegex(AssertionError, 'Company relationship denied'):
                self.record(counterparty)
        with self.assertRaisesRegex(AssertionError, 'Company relationship denied'):
            self.listing(company=foreign_company)
        with self.assertRaisesRegex(AssertionError, 'Case access denied'):
            self.listing(actor=self.other_actor)
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
        with self.assertRaisesRegex(AssertionError, 'Case access denied'):
            self.record({'kind': 'workspace'})
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 0)
        self.assertEqual(self.count('context_company_relationships', 'owner_id', self.other_org), 0)

    def test_personal_workspace_uses_its_own_artist_access(self):
        company = self.company_subject(self.actor, self.actor, 'Personal company', 'company-personal')
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        with self.assertRaisesRegex(AssertionError, 'Company relationship denied'):
            self.record(artist, owner=self.actor, company=company)
        self.sql(f"INSERT INTO account_artist_ids VALUES ('{self.actor}','{self.artist}')")
        saved = self.record(artist, owner=self.actor, company=company, kind='management', key='personal')
        self.assertEqual(saved['relationship']['counterparty'], artist)
        with self.assertRaisesRegex(AssertionError, 'Company relationship denied'):
            self.listing(company=company)
        self.assertEqual(len(self.listing(owner=self.actor, company=company)['items']), 1)

    def test_withdrawn_company_source_withholds_list_and_blocks_new_assertions(self):
        self.record({'kind': 'workspace'}, key='before-withdrawal')
        self.assertEqual(len(self.listing()['items']), 1)
        self.withdraw_company_source(self.org, self.company)
        page = self.listing()
        self.assertEqual(page['state'], 'unavailable')
        self.assertEqual(page['items'], [])
        self.assertIsNone(page['next_id'])
        self.assertEqual(page['gaps'], GAPS)
        with self.assertRaisesRegex(AssertionError, 'Company source withdrawn'):
            self.record({'kind': 'workspace'}, key='after-withdrawal')
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 1)
        # Another workspace's withdrawn company stays indistinguishable from an unknown one.
        foreign_company = self.company_subject(self.other_org, self.other_actor, 'Withdrawn other', 'company-gone')
        self.withdraw_company_source(self.other_org, foreign_company)
        for company in (foreign_company, str(uuid.uuid4())):
            with self.assertRaisesRegex(AssertionError, 'Company relationship denied'):
                self.listing(company=company)
            with self.assertRaisesRegex(AssertionError, 'Company relationship denied'):
                self.record({'kind': 'workspace'}, company=company)

    def test_invalid_input_is_rejected_before_storage(self):
        artist = {'kind': 'artist_account', 'artist_id': self.artist}
        for kwargs in [dict(kind='owner'), dict(status='active'), dict(status='current', ended='2020-01-01'),
                       dict(status='former', started='2021-01-01', ended='2020-01-01'), dict(note='x' * 2001),
                       dict(key='bad key')]:
            with self.assertRaisesRegex(AssertionError, 'Invalid company relationship'):
                self.record(artist, **kwargs)
        for counterparty in ({'kind': 'artist_account'}, {'kind': 'label'}, {'kind': 'workspace', 'artist_id': self.artist},
                             {'kind': 'artist_account', 'artist_id': self.artist, 'professional_id': self.professional}):
            with self.assertRaisesRegex(AssertionError, 'Invalid company relationship'):
                self.record(counterparty)
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 0)

    def test_pagination_by_id_never_silently_truncates_and_rejects_foreign_cursors(self):
        self.sql(f"""INSERT INTO context_company_relationships(owner_id,company_subject_id,counterparty_kind,
          relationship_kind,status,asserted_by,idempotency_key)
          SELECT '{self.org}','{self.company}','workspace','services','current','{self.actor}','bulk-'||n
          FROM generate_series(1,51) n""")
        first = self.listing()
        self.assertEqual(len(first['items']), 50)
        self.assertEqual(first['next_id'], first['items'][-1]['id'])
        second = self.listing(after=first['next_id'])
        self.assertEqual(len(second['items']), 1)
        self.assertIsNone(second['next_id'])
        self.assertEqual(len({item['id'] for item in first['items'] + second['items']}), 51)
        foreign_company = self.company_subject(self.other_org, self.other_actor, 'Other company', 'company-cursor')
        foreign_row = self.record({'kind': 'workspace'}, actor=self.other_actor, owner=self.other_org,
                                  company=foreign_company, key='foreign-row')['relationship']['id']
        for cursor in (foreign_row, str(uuid.uuid4())):
            with self.assertRaisesRegex(AssertionError, 'Invalid relationship cursor'):
                self.listing(after=cursor)
        self.assertNotIn(foreign_row, json.dumps(first) + json.dumps(second))

    def test_browser_roles_cannot_execute_or_read(self):
        for role in ('anon', 'authenticated'):
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.call(self.record_statement({'kind': 'workspace'}), role)
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.listing(role=role)
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(f'SET ROLE {role}; SELECT count(*) FROM context_company_relationships')
        self.assertEqual(self.count('context_company_relationships', 'owner_id'), 0)
