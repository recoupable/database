"""Campaign brief channels and promoted-subject candidate links on disposable PostgreSQL only."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATIONS = [
    '20260922070000_context_catalog_entry.sql',
    '20260925100000_context_songwriter_name_entry.sql',
    '20260925110000_context_company_name_entry.sql',
    '20260925120000_context_campaign_brief_entry.sql',
    '20260925130000_context_supporting_text_entry.sql',
]
LINKS_MIGRATION = '20261010213800_context_campaign_brief_promoted_links.sql'


class CampaignBriefLinks(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # The catalog entry migration references the legacy catalog tables; model only their shape.
        cls.sql('''
            CREATE TABLE public.catalogs(id uuid PRIMARY KEY, name text, updated_at timestamptz DEFAULT now());
            CREATE TABLE public.account_catalogs(account uuid, catalog uuid);
        ''')
        for migration in MIGRATIONS:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())
        migration = ROOT / 'supabase/migrations' / LINKS_MIGRATION
        if migration.exists():
            cls.sql(migration.read_text())

    def test_existing_campaign_brief_entry_compatibility(self):
        self.sql((ROOT / 'supabase/tests/context_campaign_brief_entry.sql').read_text())

    def test_campaign_brief_channels_and_promoted_candidate_links(self):
        result = self.sql((ROOT / 'supabase/tests/context_campaign_brief_links.sql').read_text())
        self.assertIn('PASS: campaign brief links', result.stderr)
