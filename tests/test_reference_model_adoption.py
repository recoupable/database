"""Check the public adoption map against main migrations on disposable PostgreSQL.

This validates which reference-model distinctions current migration files enforce.
It is not a production schema audit and it is not the reference model itself.
"""
import json
import pathlib
import re

import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATIONS_DIR = ROOT / 'supabase/migrations'
MAP_PATH = pathlib.Path(__file__).with_name('reference_model_adoption.json')

STATUSES = {'main_migration', 'open_pr', 'not_adopted'}
RELATIONSHIPS = {'identity', 'recording_composition_release', 'roster_catalog', 'scoped_evidence'}
DYNAMIC_CHECKS = {'check', 'column', 'foreign_key', 'references_only', 'no_unique_on', 'server_only'}
STATIC_CHECKS = {'absent_table', 'absent_function', 'absent_column', 'suite'}
CHECKS_BY_STATUS = {
    'main_migration': DYNAMIC_CHECKS | {'behaviour', 'suite'},
    'open_pr': {'absent_table', 'absent_function'},
    'not_adopted': {'absent_table', 'absent_function', 'absent_column', 'behaviour'},
}
TICKET = re.compile(r'^recoupable/app#\d+$')
OPEN_PR = re.compile(r'^recoupable/database#\d+$')
SQL_NAME = re.compile(r'^[a-z][a-z0-9_]*$')

# Applied after the release-case harness, oldest first. Only the five subject-entry
# migrations redefine the subject/resource kind checks, so applying them after the
# harness migrations yields the same constraints as chronological replay.
EXTRA_MIGRATIONS = [
    '20260922070000_context_catalog_entry.sql',
    '20260923080000_context_execution_records.sql',
    '20260925100000_context_songwriter_name_entry.sql',
    '20260925110000_context_company_name_entry.sql',
    '20260925120000_context_campaign_brief_entry.sql',
    '20260925130000_context_supporting_text_entry.sql',
    '20261008050000_professional_roster.sql',
    '20261008050100_confirm_professional_roster.sql',
    '20261008050200_list_professional_roster.sql',
    '20261008050300_professional_roster_validation.sql',
]
APPLIED = set(release_cases.MIGRATIONS) | set(EXTRA_MIGRATIONS)

ORG = '21470000-0000-4000-8000-000000000001'
ACTOR = '21470000-0000-4000-8000-000000000002'
RESOURCE = '21470000-0000-4000-8000-000000000003'


def load_map():
    return json.loads(MAP_PATH.read_text())


def migration_texts():
    return {path.name: path.read_text().lower() for path in sorted(MIGRATIONS_DIR.glob('*.sql'))}


def defined_tables(text):
    return set(re.findall(r'create\s+table\s+(?:if\s+not\s+exists\s+)?(?:"?public"?\.)?"?([a-z0-9_]+)', text))


def defined_functions(text):
    return set(re.findall(r'create\s+(?:or\s+replace\s+)?function\s+(?:"?public"?\.)?"?([a-z0-9_]+)', text))


def declared_columns(text):
    return set(re.findall(r'"?([a-z0-9_]+)"?\s+(?:text|varchar|character|citext|uuid|jsonb|integer|bigint)\b', text))


class ReferenceModelAdoption(release_cases.ReleaseCases):
    """Inherits the release-case cluster, so its lifecycle test also runs on this schema."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('''
            CREATE TABLE public.catalogs(id uuid PRIMARY KEY,name text,updated_at timestamptz DEFAULT now());
            CREATE TABLE public.account_catalogs(account uuid,catalog uuid);
            CREATE TABLE public.catalog_songs(catalog uuid,song text);
        ''')
        # Same partial bootstrap as test_professional_roster: only the shared trigger function.
        cls.sql((MIGRATIONS_DIR / '20250129222308_updated_at_trigger_function.sql').read_text().split('alter table')[0])
        for migration in EXTRA_MIGRATIONS:
            cls.sql((MIGRATIONS_DIR / migration).read_text())

    def scalar(self, query):
        return self.sql(query).stdout.strip()

    def assertSqlFails(self, sql, expected):
        with self.assertRaises(AssertionError) as caught:
            self.sql(sql)
        self.assertIn(expected, str(caught.exception))

    # Map shape -----------------------------------------------------------------

    def test_map_rows_are_well_formed(self):
        rows = load_map()
        self.assertIsInstance(rows, list)
        self.assertTrue(rows, 'the adoption map must not be empty')
        ids = [row.get('id') for row in rows]
        self.assertEqual(len(ids), len(set(ids)), 'row ids must be unique')
        self.assertEqual({row['relationship'] for row in rows}, RELATIONSHIPS,
                         'every relationship group needs at least one row')
        for row in rows:
            with self.subTest(row=row.get('id')):
                self.assertIn(row['status'], STATUSES)
                self.assertIn(row['relationship'], RELATIONSHIPS)
                self.assertTrue(row['concept'].strip())
                self.assertTrue(row['tickets'])
                for ticket in row['tickets']:
                    self.assertRegex(ticket, TICKET)
                self.assertTrue(row['checks'])
                for check in row['checks']:
                    self.assertIn(check['kind'], CHECKS_BY_STATUS[row['status']])
                    # Names are interpolated into disposable-database SQL; keep them plain.
                    for key in ('table', 'column', 'constraint', 'references'):
                        if key in check:
                            self.assertRegex(check[key], SQL_NAME)
                    for key in ('tables', 'columns', 'names'):
                        for name in check.get(key, []):
                            self.assertRegex(name, SQL_NAME)
                    if check['kind'] == 'behaviour':
                        self.assertTrue(callable(getattr(self, check['test'], None)), check['test'])
                    if check['kind'] == 'suite':
                        self.assertTrue((ROOT / check['file']).is_file(), check['file'])
                if row['status'] == 'main_migration':
                    self.assertTrue(row['defined_by'])
                    for migration in row['defined_by']:
                        self.assertTrue((MIGRATIONS_DIR / migration).is_file(), migration)
                    if any(check['kind'] in DYNAMIC_CHECKS for check in row['checks']):
                        self.assertLessEqual(set(row['defined_by']), APPLIED,
                                             'dynamic rows must be applied by this harness')
                else:
                    self.assertNotIn('defined_by', row)
                if row['status'] == 'open_pr':
                    self.assertRegex(row['pr'], OPEN_PR)
                else:
                    self.assertNotIn('pr', row)

    # Deployed-in-main rows -------------------------------------------------------

    def test_main_migration_rows_hold_on_disposable_schema(self):
        rows = [row for row in load_map() if row['status'] == 'main_migration']
        self.assertTrue(rows)
        for row in rows:
            for check in row['checks']:
                if check['kind'] in DYNAMIC_CHECKS:
                    with self.subTest(row=row['id'], check=check['kind']):
                        getattr(self, f"verify_{check['kind']}")(check)

    def test_constraint_rows_name_the_latest_defining_migration(self):
        texts = migration_texts()
        checks = [check for row in load_map() for check in row['checks'] if check['kind'] == 'check']
        self.assertTrue(checks)
        for check in checks:
            with self.subTest(constraint=check['constraint']):
                pattern = re.compile(r'add\s+constraint\s+' + re.escape(check['constraint']) + r'\b')
                definers = [name for name, text in texts.items() if pattern.search(text)]
                self.assertTrue(definers, 'no main migration defines this constraint')
                self.assertEqual(definers[-1], check['defined_in'],
                                 'a newer migration changed a mapped constraint; update the map in the same PR')

    def verify_check(self, check):
        definition = self.scalar(
            f"SELECT pg_get_constraintdef(oid) FROM pg_constraint "
            f"WHERE conrelid='public.{check['table']}'::regclass AND conname='{check['constraint']}'")
        self.assertTrue(definition, f"{check['constraint']} missing")
        literals = set(re.findall(r"'([^']*)'", definition))
        self.assertLessEqual(set(check.get('literals', [])), literals)
        for column in check.get('columns', []):
            self.assertRegex(definition, rf'\b{column}\b')

    def verify_column(self, check):
        nullable = self.scalar(
            f"SELECT is_nullable FROM information_schema.columns WHERE table_schema='public' "
            f"AND table_name='{check['table']}' AND column_name='{check['column']}'")
        self.assertIn(nullable, {'YES', 'NO'}, f"{check['table']}.{check['column']} missing")
        if 'not_null' in check:
            self.assertEqual(nullable, 'NO' if check['not_null'] else 'YES')

    def referenced_tables(self, table, column=None):
        column_filter = ''
        if column:
            column_filter = (f" AND conkey=ARRAY[(SELECT attnum FROM pg_attribute "
                             f"WHERE attrelid=c.conrelid AND attname='{column}')]::smallint[]")
        result = self.scalar(
            f"SELECT string_agg(DISTINCT r.relname,',') FROM pg_constraint c JOIN pg_class r ON r.oid=c.confrelid "
            f"WHERE c.conrelid='public.{table}'::regclass AND c.contype='f'{column_filter}")
        return set(filter(None, result.split(',')))

    def verify_foreign_key(self, check):
        self.assertIn(check['references'], self.referenced_tables(check['table'], check['column']))

    def verify_references_only(self, check):
        self.assertEqual(self.referenced_tables(check['table']), set(check['tables']))

    def verify_no_unique_on(self, check):
        count = self.scalar(
            f"SELECT count(*) FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid "
            f"AND a.attnum=ANY(i.indkey) WHERE i.indrelid='public.{check['table']}'::regclass "
            f"AND i.indisunique AND a.attname='{check['column']}'")
        self.assertEqual(count, '0')

    def verify_server_only(self, check):
        for table in check['tables']:
            self.assertEqual(self.scalar(f"SELECT relrowsecurity FROM pg_class WHERE oid='public.{table}'::regclass"),
                             't', f'{table} needs row level security')
            for role in ('anon', 'authenticated'):
                granted = self.scalar(
                    f"SELECT has_table_privilege('{role}','public.{table}','SELECT,INSERT,UPDATE,DELETE')")
                self.assertEqual(granted, 'f', f'{role} has access to {table}')

    # Proposed or open rows ------------------------------------------------------

    def test_open_pr_and_not_adopted_rows_are_absent_from_main_migrations(self):
        texts = migration_texts()
        tables = set().union(*(defined_tables(text) for text in texts.values()))
        functions = set().union(*(defined_functions(text) for text in texts.values()))
        columns = set().union(*(declared_columns(text) for text in texts.values()))
        rows = [row for row in load_map() if row['status'] != 'main_migration']
        self.assertTrue(rows)
        for row in rows:
            for check in row['checks']:
                with self.subTest(row=row['id'], check=check['kind']):
                    if check['kind'] == 'absent_table':
                        self.assert_absent(check, tables)
                    elif check['kind'] == 'absent_function':
                        self.assert_absent(check, functions)
                    elif check['kind'] == 'absent_column':
                        self.assert_absent(check, columns)

    def assert_absent(self, check, defined):
        if 'names' in check:
            self.assertFalse(set(check['names']) & defined, 'object already defined on main')
        if 'pattern' in check:
            matched = sorted(name for name in defined if re.search(check['pattern'], name))
            self.assertFalse(matched, 'object matching an unadopted concept is defined on main')

    # Behaviour referenced by map rows ---------------------------------------------

    def test_company_subject_cannot_reuse_artist_account(self):
        setup = f'''BEGIN;
            INSERT INTO public.accounts(id,name) VALUES ('{ACTOR}','Fixture artist account');
            INSERT INTO public.context_resources(id,provider,resource_kind,provider_id,canonical_url)
            VALUES ('{RESOURCE}','recoup','company_input','fixture-company','urn:recoup:company-input:fixture');'''
        self.sql(setup + f"INSERT INTO public.context_subjects(kind,resource_id) VALUES ('company','{RESOURCE}'); ROLLBACK;")
        self.assertSqlFails(
            setup + f"INSERT INTO public.context_subjects(kind,resource_id,artist_id) VALUES ('company','{RESOURCE}','{ACTOR}');",
            'context_subjects_check')
        self.assertSqlFails(
            setup + f"INSERT INTO public.context_subjects(kind,artist_id) VALUES ('company','{ACTOR}');",
            'context_subjects_check')

    def test_recording_subject_requires_isrc(self):
        self.assertSqlFails("BEGIN; INSERT INTO public.context_subjects(kind) VALUES ('recording');",
                            'context_subjects_check')
        self.assertSqlFails(
            f'''BEGIN; INSERT INTO public.context_resources(id,provider,resource_kind,provider_id,canonical_url)
            VALUES ('{RESOURCE}','spotify','track','fixture-track','https://open.spotify.com/track/fixture-track');
            INSERT INTO public.context_subjects(kind,resource_id) VALUES ('recording','{RESOURCE}');''',
            'context_subjects_check')

    def test_same_name_professionals_remain_separate_records(self):
        result = self.sql(f'''BEGIN;
            INSERT INTO public.accounts(id,name) VALUES ('{ORG}','Fixture organization'),('{ACTOR}','Fixture operator');
            INSERT INTO public.organization_professionals(organization_id,name,roles,confirmed_by)
            VALUES ('{ORG}','Same Name',ARRAY['songwriter'],'{ACTOR}'),('{ORG}','Same Name',ARRAY['producer'],'{ACTOR}');
            SELECT count(DISTINCT id) FROM public.organization_professionals WHERE organization_id='{ORG}';
            SELECT count(*) FROM public.accounts;
            ROLLBACK;''').stdout.splitlines()
        counts = [line for line in result if line.isdigit()]
        self.assertEqual(counts, ['2', '2'], 'namesakes stay separate and create no login accounts')

    def test_browser_roles_cannot_read_scoped_evidence(self):
        for role in ('anon', 'authenticated'):
            for table in ('context_sources', 'context_source_versions', 'organization_professionals'):
                with self.subTest(role=role, table=table):
                    self.assertSqlFails(f'SET ROLE {role}; SELECT count(*) FROM public.{table};',
                                        'permission denied')
