"""MVP assessment save/read through the existing immutable brief store; disposable PG only."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT


class CompanyAssessment(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((ROOT / 'supabase/migrations/20260926170000_context_brief_snapshots.sql').read_text())
        migration = ROOT / 'supabase/migrations/20261010010000_context_company_assessment.sql'
        if migration.exists():
            cls.sql(migration.read_text())

    def test_existing_brief_compatibility(self):
        self.sql((ROOT / 'supabase/tests/context_brief_snapshots.sql').read_text())

    def test_company_assessment_save_read_replay_and_source_withdrawal(self):
        fixture = (ROOT / 'supabase/tests/context_brief_snapshots.sql').read_text()
        fixture = fixture.replace("'playlist_pitch'", "'company_onboarding'")
        fixture = fixture.replace('Playlist-pitch fixture', 'Company-onboarding assessment fixture')
        self.sql(fixture)
