"""Private original receipts; synthetic verified metadata, no hosted bytes or providers."""
import json
import uuid
import test_release_cases as fixture

class OriginalFixture(fixture.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        path = fixture.ROOT / 'supabase/migrations/20261009210000_context_original_registration.sql'
        if path.exists():
            cls.sql(path.read_text())
        forward = fixture.ROOT / 'supabase/migrations/20261009230000_context_original_neutral_path.sql'
        if forward.exists():
            cls.sql(forward.read_text())
        index = fixture.ROOT / 'supabase/migrations/20261009230100_context_original_storage_lookup_index.sql'
        if index.exists():
            cls.sql(index.read_text())

    def setUp(self):
        self.actor, self.owner, self.other, self.source, self.object = [str(uuid.uuid4()) for _ in range(5)]
        self.path = f'{self.owner}/context-originals/{self.object}.csv'
        self.sql(f"INSERT INTO accounts VALUES ('{self.actor}','Operator'),('{self.owner}','Label'),('{self.other}','Other');"
                 f"INSERT INTO account_organization_ids VALUES ('{self.actor}','{self.owner}',now());")

    def register(self, key='fixture', digest='a'*64, path=None, actor=None, owner=None, source=None, media_type='text/csv'):
        sql = f"SET ROLE service_role; SELECT register_context_original('{self.actor if actor is None else actor}','{self.owner if owner is None else owner}'," \
              f"'{self.source if source is None else source}','{key}','{self.path if path is None else path}','{digest}',26,'{media_type}');"
        return json.loads(self.sql(sql).stdout.strip().splitlines()[-1])

    def read(self, receipt, actor=None, owner=None):
        return json.loads(self.sql(f"SET ROLE service_role; SELECT read_context_original_registration("
                                  f"'{self.actor if actor is None else actor}','{self.owner if owner is None else owner}','{receipt}');").stdout.strip().splitlines()[-1])

