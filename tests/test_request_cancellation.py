"""Owner-scoped Context request cancellation on disposable PostgreSQL, without hosted credentials."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT


class RequestCancellation(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        migration = ROOT / 'supabase/migrations/20261010212200_context_request_cancellation.sql'
        if migration.exists():
            cls.sql(migration.read_text())

    def test_cancellation_outcomes_scope_and_grants(self):
        result = self.sql((ROOT / 'supabase/tests/context_request_cancellation.sql').read_text())
        self.assertIn('PASS:', result.stderr)
