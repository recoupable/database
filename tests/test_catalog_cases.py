"""Catalog artifact storage on a disposable PostgreSQL cluster, no hosted credentials."""
import pathlib
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
import test_release_cases as harness

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CatalogCases(harness.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((ROOT / 'supabase/migrations/20261022120000_context_catalog_cases.sql').read_text())

    def test_review_lifecycle_and_access(self):
        result = self.sql((ROOT / 'supabase/tests/context_catalog_cases.sql').read_text())
        self.assertIn('PASS:', result.stderr)

    def test_concurrent_first_writers_have_one_winner(self):
        owner, case_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.sql(f"insert into public.accounts(id,name) values ('{owner}','Concurrent synthetic workspace')")
        snapshot = {"schema_version": 1, "case_id": case_id, "workspace_id": owner,
                    "revision": 0, "scope": "Synthetic concurrency", **{key: {} for key in
                    ("sources", "assessments", "findings", "actions", "attempts", "outcomes")}}
        def save(key):
            sql = f"SET ROLE service_role; SELECT public.save_context_catalog_case('{owner}','{owner}','{case_id}',0,'{key}', '{json.dumps(snapshot)}'::jsonb)"
            try:
                self.sql(sql)
                return "saved"
            except AssertionError as exc:
                self.assertIn("Catalog revision conflict", str(exc))
                return "conflict"
        with ThreadPoolExecutor(max_workers=2) as executor:
            self.assertCountEqual(list(executor.map(save, ["race-a", "race-b"])), ["saved", "conflict"])
        result = self.sql(f"select count(*) from public.context_catalog_case_revisions where case_id='{case_id}'")
        self.assertEqual(result.stdout.strip(), "1")
