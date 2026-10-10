"""Release format observation projected from saved Spotify evidence; disposable PG only."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATION = ROOT / 'supabase/migrations/20261010213900_context_release_format_observation.sql'


class ReleaseFormat(release_cases.ReleaseCases):
    """Re-runs the sibling review fixture against the replaced read function, then the format fixture."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql(MIGRATION.read_text())

    def test_release_format_observation(self):
        result = self.sql((ROOT / 'supabase/tests/context_release_format.sql').read_text())
        self.assertIn('PASS:', result.stderr)
