"""Unreleased recording and planned release intake on disposable PostgreSQL; no identifier is invented."""
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
