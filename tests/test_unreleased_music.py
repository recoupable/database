"""Unreleased recording and planned release intake on disposable PostgreSQL; no identifier is invented."""
import subprocess

import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATIONS = [
    '20260922070000_context_catalog_entry.sql',
    '20260925100000_context_songwriter_name_entry.sql',
    '20260925110000_context_company_name_entry.sql',
    '20260925120000_context_campaign_brief_entry.sql',
    '20260925130000_context_supporting_text_entry.sql',
    '20261010214100_context_unreleased_music_entry.sql',
]


class UnreleasedMusic(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # The catalog entry migration (which introduces the `recoup` provider) references these tables.
        cls.sql('''
            CREATE TABLE public.catalogs(id uuid PRIMARY KEY,name text,updated_at timestamptz DEFAULT now());
            CREATE TABLE public.account_catalogs(account uuid,catalog uuid);
        ''')
        for migration in MIGRATIONS:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())

    def test_internal_identities_without_external_ids(self):
        result = self.sql((ROOT / 'supabase/tests/context_unreleased_music_entry.sql').read_text())
        self.assertIn('PASS:', result.stderr)

    def test_withdrawal_waits_for_planned_release_save(self):
        """A recording's source cannot be withdrawn between the reference check and acceptance."""
        owner = '00000000-0000-4000-8000-0000000000c1'
        subject = self.sql(f"""
            insert into public.accounts(id,name) values('{owner}','Lock fixture');
            select public.create_context_unreleased_recording_request('{owner}','{owner}',
              '{{"title":"Lock song"}}'::jsonb,'lock-recording')->'output'->'subjectIds'->>0;
        """).stdout.split()[-1]
        source = self.sql(f"""
            select s.id from public.context_sources s
            join public.context_source_versions v on v.source_id=s.id
            join public.context_result_sources rs on rs.source_version_id=v.id
            join public.context_results r on r.id=rs.result_id and r.subject_id='{subject}';
        """).stdout.strip()
        saver = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55473', '-d', 'postgres',
                                  '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            saver.stdin.write(f"""begin;
                select public.create_context_planned_release_request('{owner}','{owner}',
                  jsonb_build_object('title','Lock EP','recording_subject_ids',jsonb_build_array('{subject}'::uuid)),
                  'lock-release') is not null;
            """)
            saver.stdin.flush()
            self.assertEqual(saver.stdout.readline().strip(), 't')
            with self.assertRaisesRegex(AssertionError, 'lock timeout'):
                self.sql(f"set lock_timeout='300ms'; select public.withdraw_context_source('{owner}','{source}');")
        finally:
            saver.communicate('rollback;\n', timeout=30)
        self.assertIn('t', self.sql(f"select public.withdraw_context_source('{owner}','{source}');").stdout)
