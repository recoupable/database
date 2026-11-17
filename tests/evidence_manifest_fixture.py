"""Synthetic retained evidence built by real intake operations."""
import json
import uuid
import test_release_cases as fixture

ROOT = fixture.ROOT


class ManifestFixture(fixture.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((ROOT / 'supabase/migrations/20260924040000_context_release_entry.sql').read_text())
        for migration in sorted((ROOT / 'supabase/migrations').glob('2026100920000*_context_evidence_manifest.sql')):
            cls.sql(migration.read_text())

    def setUp(self):
        self.actor, self.owner, self.other = [str(uuid.uuid4()) for _ in range(3)]
        self.sql(f"INSERT INTO accounts VALUES ('{self.actor}','Operator'),('{self.owner}','Label'),('{self.other}','Other');"
                 f"INSERT INTO account_organization_ids VALUES ('{self.actor}','{self.owner}',now());")
        saved = self.run_json_query(f"SET ROLE service_role; SELECT create_context_release_request('{self.owner}',"
                          f"'{self.actor}','1234567890123456789012','fixture');")
        self.request = saved['id']
        self.subject = saved['output']['subjectIds'][0]

    def run_json_query(self, sql):
        return json.loads(self.sql(sql).stdout.strip().splitlines()[-1])

    def list_manifest(self, actor=None, owner=None, request=None, after=None):
        cursor = f"'{after}'" if after else 'null'
        return self.run_json_query(f"SET ROLE service_role; SELECT list_context_request_evidence_versions("
                         f"'{actor or self.actor}','{owner or self.owner}','{request or self.request}',{cursor});")

    def save_metadata(self, value, topic='fixture', url=None):
        url = url or f'urn:fixture:{self.request}'
        self.sql(f"SET ROLE service_role; SELECT save_context_metadata('{self.owner}','{self.request}',"
                 f"'{self.subject}','{topic}','{url}','{{\"value\":{value}}}',now());")
