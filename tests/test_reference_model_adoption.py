"""Check the public adoption map against main migrations on disposable PostgreSQL.

This validates which reference-model distinctions current migration files enforce.
It is not a production schema audit and it is not the reference model itself.
"""
import json
import os
import pathlib
import re
import subprocess

import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATIONS_DIR = ROOT / 'supabase/migrations'
MAP_PATH = pathlib.Path(__file__).with_name('reference_model_adoption.json')
# A change that edits any of these must match every migration, including older ones.
MAP_FILES = ('tests/reference_model_adoption.json', 'tests/test_reference_model_adoption.py',
             'tests/test_release_cases.py')

STATUSES = {'main_migration', 'open_pr', 'not_adopted'}
RELATIONSHIPS = {'identity', 'recording_composition_release', 'roster_catalog', 'scoped_evidence'}
DYNAMIC_CHECKS = {'check', 'column', 'foreign_key', 'references_only', 'no_unique_on', 'server_only'}
ABSENCE_CHECKS = {'absent_table', 'absent_function', 'absent_column', 'absent_literal'}
CHECKS_BY_STATUS = {
    'main_migration': DYNAMIC_CHECKS | {'behaviour', 'suite'},
    'open_pr': ABSENCE_CHECKS,
    'not_adopted': ABSENCE_CHECKS | {'behaviour'},
}
TICKET = re.compile(r'^recoupable/app#\d+$')
OPEN_PR = re.compile(r'^recoupable/database#\d+$')
SQL_NAME = re.compile(r'^[a-z][a-z0-9_]*$')

# Applied after the release-case harness, oldest first. Only the five subject-entry
# migrations redefine the subject/resource kind checks, so applying them after the
# harness migrations yields the same constraints as chronological replay. Any other
# migration that changes a mapped table must be added here (see
# test_unapplied_migrations_leave_mapped_tables_alone).
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

# Pull-request CI sets this to the base commit; pushes to main set it to HEAD. A
# mismatch caused by a migration that is already on that base merged before this
# suite saw it, so it is printed as a GitHub warning instead of turning main or an
# unrelated pull request red; fix it with a map-only change. When unset (local
# runs), or when the change edits MAP_FILES, every mismatch fails.
BASE_REF = os.environ.get('ADOPTION_MAP_BASE_REF')

COLUMN_TYPES = (r'text|varchar|character|citext|uuid|jsonb?|smallint|integer|int[248]?|bigint|numeric|decimal|'
                r'real|double|boolean|bool|date|time|timestamp|timestamptz|interval|bytea|inet|bigserial|serial')
DEFINITIONS = {
    'absent_table': [r'create\s+table\s+(?:if\s+not\s+exists\s+)?(?:"?public"?\.)?"?([a-z0-9_]+)'],
    'absent_function': [r'create\s+(?:or\s+replace\s+)?function\s+(?:"?public"?\.)?"?([a-z0-9_]+)'],
    'absent_column': [r'add\s+column\s+(?:if\s+not\s+exists\s+)?"?([a-z0-9_]+)',
                      rf'"?([a-z0-9_]+)"?\s+(?:{COLUMN_TYPES})\b'],
    'absent_literal': [r"'([^']*)'"],
}

ORG = '21470000-0000-4000-8000-000000000001'
ACTOR = '21470000-0000-4000-8000-000000000002'
RESOURCE = '21470000-0000-4000-8000-000000000003'


def load_map():
    return json.loads(MAP_PATH.read_text())


def migration_texts():
    """Lower-cased migration text without SQL comments, oldest first."""
    return {path.name: re.sub(r'/\*.*?\*/|--[^\n]*', ' ', path.read_text().lower(), flags=re.S)
            for path in sorted(MIGRATIONS_DIR.glob('*.sql'))}


def definitions(texts, patterns):
    """Return {object name: [defining migrations, oldest first]}."""
    found = {}
    for migration, text in texts.items():
        for name in {name for pattern in patterns for name in re.findall(pattern, text)}:
            found.setdefault(name, []).append(migration)
    return found


def mapped_tables(rows):
    tables = set()
    for row in rows:
        if row['status'] == 'main_migration':
            for check in row['checks']:
                if 'table' in check:
                    tables.add(check['table'])
                if check['kind'] == 'server_only':
                    tables.update(check['tables'])
    return tables


def touched_tables(text, tables):
    """Mapped tables whose columns, constraints, indexes, triggers, policies or grants a migration changes."""
    name = r'(?:"?public"?\.)?"?(' + '|'.join(sorted(tables)) + r')"?\b'
    statements = (
        rf'alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?{name}',
        rf'drop\s+table\s+(?:if\s+exists\s+)?(?:[^;]*?,\s*)?{name}',
        rf'create\s+(?:unique\s+)?index\s[^;]*?\bon\s+(?:only\s+)?{name}',
        rf'(?:create\s+(?:or\s+replace\s+)?(?:constraint\s+)?|drop\s+)trigger\s[^;]*?\bon\s+{name}',
        rf'(?:create|alter|drop)\s+policy\s[^;]*?\bon\s+{name}',
        rf'(?:grant|revoke)\s[^;]*?\bon\s+(?:table\s+)?(?:[^;]*?,\s*)?{name}',
    )
    touched = {table for statement in statements for table in re.findall(statement, text)}
    if re.search(r'(?:grant|revoke)\s[^;]*?\bon\s+all\s+tables\s+in\s+schema\s+public\b', text):
        touched |= set(tables)
    return touched


def comparison_base():
    """Return (migrations already on BASE_REF, whether every mismatch fails)."""
    if not BASE_REF:
        return set(), True
    git = ['git', '-C', str(ROOT)]
    listed = subprocess.run(git + ['ls-tree', '--name-only', BASE_REF, 'supabase/migrations/'],
                            capture_output=True, text=True)
    if listed.returncode:
        raise RuntimeError(f'cannot list migrations at {BASE_REF}: {listed.stderr}')
    edited = subprocess.run(git + ['diff', '--quiet', BASE_REF, '--', *MAP_FILES]).returncode != 0
    return {pathlib.PurePosixPath(line).name for line in listed.stdout.splitlines()}, edited


class ReferenceModelAdoption(release_cases.ReleaseCases):
    """Inherits the release-case cluster, so its lifecycle test also runs on this schema."""

    @classmethod
    def setUpClass(cls):
        cls.base_migrations, cls.strict = comparison_base()
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

    def assertMapCurrent(self, mismatches):
        """Fail on mismatches this change introduces; only warn about ones merged before it."""
        failures = []
        for migration, problem in sorted(set(mismatches), key=str):
            if self.strict or migration is None or migration not in self.base_migrations:
                failures.append(f'{migration or "map"}: {problem}')
            else:
                # Leading newline: a workflow command must start its own line.
                print(f'\n::warning title=Stale reference model adoption map::{migration}: {problem}', flush=True)
        self.assertFalse(failures, 'update tests/reference_model_adoption.json in the same change:\n  '
                         + '\n  '.join(failures))

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
                    if 'pattern' in check:
                        re.compile(check['pattern'])
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

    def test_unapplied_migrations_leave_mapped_tables_alone(self):
        """Structural checks only see the migrations this runner applies."""
        tables = mapped_tables(load_map())
        self.assertTrue(tables)
        self.assertMapCurrent([
            (migration, f'changes mapped table {table}; add it to EXTRA_MIGRATIONS and recheck the rows')
            for migration, text in migration_texts().items() if migration not in APPLIED
            for table in sorted(touched_tables(text, tables))])

    def test_constraint_rows_name_the_latest_defining_migration(self):
        texts = migration_texts()
        checks = [check for row in load_map() for check in row['checks'] if check['kind'] == 'check']
        self.assertTrue(checks)
        mismatches = []
        for check in checks:
            pattern = re.compile(r'add\s+constraint\s+' + re.escape(check['constraint']) + r'\b')
            definers = [name for name, text in texts.items() if pattern.search(text)]
            if check['defined_in'] not in definers:
                mismatches.append((None, f"{check['defined_in']} does not define {check['constraint']}"))
            elif definers[-1] != check['defined_in']:
                mismatches.append((definers[-1], f"redefines {check['constraint']}; recheck the row and its defined_in"))
        self.assertMapCurrent(mismatches)

    def verify_check(self, check):
        definition = self.scalar(
            f"SELECT pg_get_constraintdef(oid) FROM pg_constraint "
            f"WHERE conrelid='public.{check['table']}'::regclass AND conname='{check['constraint']}'")
        self.assertTrue(definition, f"{check['constraint']} missing")
        literals = set(re.findall(r"'([^']*)'", definition))
        if check.get('exact'):
            self.assertEqual(literals, set(check['literals']), f"{check['constraint']} allows unmapped values")
        else:
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

    def foreign_keys(self, table):
        """Return {(ordered referencing columns, referenced table)} for one table."""
        result = self.scalar(
            f"SELECT string_agg((SELECT string_agg(a.attname,',' ORDER BY k.n) FROM unnest(c.conkey) "
            f"WITH ORDINALITY k(attnum,n) JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum)"
            f"||'>'||r.relname,' ') FROM pg_constraint c JOIN pg_class r ON r.oid=c.confrelid "
            f"WHERE c.conrelid='public.{table}'::regclass AND c.contype='f'")
        return {(tuple(columns.split(',')), target)
                for columns, target in (key.split('>') for key in result.split())}

    def verify_foreign_key(self, check):
        # Exact column list, so a composite owner-scoped key cannot weaken to one column.
        self.assertIn((tuple(check['columns']), check['references']), self.foreign_keys(check['table']))

    def verify_references_only(self, check):
        self.assertEqual({target for _, target in self.foreign_keys(check['table'])}, set(check['tables']))

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
                    f"SELECT has_table_privilege('{role}','public.{table}','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')")
                self.assertEqual(granted, 'f', f'{role} has access to {table}')

    # Proposed or open rows ------------------------------------------------------

    def test_open_pr_and_not_adopted_rows_are_absent_from_main_migrations(self):
        texts = migration_texts()
        defined = {kind: definitions(texts, patterns) for kind, patterns in DEFINITIONS.items()}
        rows = [row for row in load_map() if row['status'] != 'main_migration']
        self.assertTrue(rows)
        mismatches = []
        for row in rows:
            for check in row['checks']:
                for name, migrations in defined.get(check['kind'], {}).items():
                    if name in check.get('names', []) or re.search(check.get('pattern', r'(?!)'), name):
                        mismatches += [(migration, f"defines {name} but row {row['id']} is {row['status']}; update the row")
                                       for migration in migrations]
        self.assertMapCurrent(mismatches)

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

    def test_release_subject_is_anchored_to_a_resource(self):
        setup = f'''BEGIN;
            INSERT INTO public.accounts(id,name) VALUES ('{ACTOR}','Fixture artist account');
            INSERT INTO public.songs(isrc) VALUES ('fixture-song-key');
            INSERT INTO public.context_resources(id,provider,resource_kind,provider_id,canonical_url)
            VALUES ('{RESOURCE}','spotify','release','fixture-release','https://open.spotify.com/album/fixture-release');'''
        self.sql(setup + f"INSERT INTO public.context_subjects(kind,resource_id) VALUES ('release','{RESOURCE}'); ROLLBACK;")
        for anchor, value in (('song_isrc', 'fixture-song-key'), ('artist_id', ACTOR)):
            with self.subTest(anchor=anchor):
                self.assertSqlFails(
                    setup + f"INSERT INTO public.context_subjects(kind,{anchor}) VALUES ('release','{value}');",
                    'context_subjects_check')
                self.assertSqlFails(
                    setup + f"INSERT INTO public.context_subjects(kind,resource_id,{anchor}) "
                            f"VALUES ('release','{RESOURCE}','{value}');",
                    'context_subjects_check')
        self.assertSqlFails("BEGIN; INSERT INTO public.context_subjects(kind) VALUES ('release');",
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
