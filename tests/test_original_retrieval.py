"""Internal original lookup on disposable PostgreSQL; no storage or hosted operation."""
import json
import uuid
import original_registration_fixture as fixture

class OriginalRetrieval(fixture.OriginalFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        migration = fixture.fixture.ROOT / 'supabase/migrations/20261009220000_context_original_retrieval.sql'
        if migration.exists(): cls.sql(migration.read_text())

    def lookup(self, receipt, actor=None, owner=None):
        return json.loads(self.sql(f"SET ROLE service_role; SELECT get_context_original_retrieval("
            f"'{self.actor if actor is None else actor}','{self.owner if owner is None else owner}','{receipt}');").stdout.strip().splitlines()[-1])

    def test_scoped_lookup_retains_receipt_identity_and_private_location(self):
        saved = self.register()
        internal = self.lookup(saved['id'])
        self.assertEqual(internal, dict(saved, bucket='context-private', storage_path=self.path))
        self.assertEqual(self.lookup(saved['id'], actor=self.owner), internal)
        self.assertNotIn('storage_path', self.read(saved['id']))
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_results WHERE owner_id='{self.owner}'").stdout.strip(), '0')

    def test_foreign_actor_owner_and_missing_receipt_denied(self):
        saved = self.register()
        for call in [lambda: self.lookup(saved['id'], actor=self.other),
                     lambda: self.lookup(saved['id'], owner=self.other)]:
            with self.assertRaisesRegex(AssertionError, 'Case access denied'): call()
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'):
            self.lookup(str(uuid.uuid4()))
        foreign = self.register(actor=self.other, owner=self.other, source=str(uuid.uuid4()),
                                path=self.path.replace(self.owner, self.other))
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'):
            self.lookup(foreign['id'])

    def test_revocation_denies_new_session(self):
        saved = self.register()
        self.lookup(saved['id'])
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
        with self.assertRaisesRegex(AssertionError, 'Case access denied'): self.lookup(saved['id'])
        self.assertEqual(self.lookup(saved['id'], actor=self.owner)['id'], saved['id'])

    def test_withdrawn_source_and_removed_version_denied(self):
        saved = self.register()
        self.sql(f"UPDATE context_source_versions SET removed_at=now() WHERE id='{saved['source_version_id']}'")
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'): self.lookup(saved['id'])
        self.sql(f"UPDATE context_source_versions SET removed_at=NULL WHERE id='{saved['source_version_id']}';"
                 f"SELECT withdraw_context_source('{self.owner}','{self.source}')")
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'): self.lookup(saved['id'])

    def test_mutated_retained_version_is_never_a_retrieval_authority(self):
        saved = self.register()
        for change in ["fingerprint='" + 'b'*64 + "'", "storage_path='wrong'", "content='{}'::jsonb"]:
            with self.assertRaisesRegex(AssertionError, 'Original unavailable'):
                self.sql(f"BEGIN; UPDATE context_source_versions SET {change} WHERE id='{saved['source_version_id']}';"
                         f"SET ROLE service_role; SELECT get_context_original_retrieval('{self.actor}','{self.owner}','{saved['id']}'); ROLLBACK;")
        self.assertEqual(self.lookup(saved['id'])['fingerprint'], 'a'*64)

    def test_history_resolves_each_exact_object_and_version(self):
        old = self.register()
        new_path = self.path.replace(self.object, str(uuid.uuid4()))
        new = self.register(key='next', digest='b'*64, path=new_path)
        self.assertNotEqual(old['source_version_id'], new['source_version_id'])
        self.assertEqual(self.lookup(old['id'])['storage_path'], self.path)
        self.assertEqual(self.lookup(new['id'])['storage_path'], new_path)

    def test_browser_roles_cannot_get_internal_location(self):
        saved = self.register()
        for role in ['anon', 'authenticated']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(f"SET ROLE {role}; SELECT get_context_original_retrieval('{self.actor}','{self.owner}','{saved['id']}')")
