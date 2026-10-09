"""Private original receipts; no hosted bytes or providers."""
import uuid
from concurrent.futures import ThreadPoolExecutor
import original_registration_fixture as fixture

class OriginalRegistration(fixture.OriginalFixture):
    def test_exact_retry_and_fresh_session_reuse(self):
        saved = self.register()
        self.assertEqual(self.register(), saved)
        self.assertEqual(self.read(saved['id']), saved)
        self.assertEqual(self.read(saved['id'], actor=self.owner), saved)
        self.assertEqual(saved['status'], 'registered')
        self.assertEqual(saved['evidence_kind'], 'customer_assertion')
        self.assertNotIn('storage_path', saved)
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_results WHERE owner_id='{self.owner}'").stdout.strip(), '0')

    def test_changed_retry_conflict_and_new_version_history(self):
        old = self.register()
        new_path = self.path.replace(self.object, str(uuid.uuid4()))
        with self.assertRaisesRegex(AssertionError, 'Original retry conflict'):
            self.register(digest='b'*64, path=new_path)
        new = self.register(key='next', digest='b'*64, path=new_path)
        self.assertEqual(old['source_id'], new['source_id'])
        self.assertNotEqual(old['source_version_id'], new['source_version_id'])
        self.assertEqual(self.read(old['id']), old)

    def test_object_path_cannot_be_rebound_to_changed_bytes(self):
        self.register()
        with self.assertRaisesRegex(AssertionError, 'Original storage conflict'):
            self.register(key='next', digest='b'*64)
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_source_versions WHERE owner_id='{self.owner}'").stdout.strip(), '1')

    def test_revoked_foreign_and_withdrawn_read_or_replay_denied(self):
        saved = self.register()
        for call in [lambda: self.read(saved['id'], owner=self.other), lambda: self.register(owner=self.other)]:
            with self.assertRaises(AssertionError): call()
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
        for call in [lambda: self.read(saved['id']), lambda: self.register()]:
            with self.assertRaisesRegex(AssertionError, 'Case access denied'): call()
        self.sql(f"SELECT withdraw_context_source('{self.owner}','{self.source}')")
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'):
            self.read(saved['id'], actor=self.owner)
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'):
            self.register(actor=self.owner)

    def test_concurrent_retries_return_one_receipt(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            receipts = list(pool.map(lambda _: self.register(), range(6)))
        self.assertTrue(all(r == receipts[0] for r in receipts))
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_original_registrations WHERE owner_id='{self.owner}'").stdout.strip(), '1')

    def test_foreign_key_invalid_path_and_browser_role_denied(self):
        with self.assertRaises(AssertionError): self.register(path=self.path.replace(self.owner, self.other))
        for role in ['anon', 'authenticated']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(f"SET ROLE {role}; SELECT read_context_original_registration('{self.actor}','{self.owner}','{uuid.uuid4()}')")
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(f"SET ROLE {role}; SELECT register_context_original('{self.actor}','{self.owner}','{self.source}','browser','{self.path}','{'a'*64}',26,'text/csv')")

    def test_same_bytes_new_work_key_reuses_the_retained_version(self):
        first, second = self.register(), self.register(key='second')
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual(first['source_version_id'], second['source_version_id'])

    def test_existing_foreign_source_cannot_be_claimed(self):
        self.register()
        foreign_path = self.path.replace(self.owner, self.other)
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'):
            self.register(actor=self.other, owner=self.other, path=foreign_path)

    def test_removed_or_modified_version_denies_read_and_retry(self):
        saved = self.register()
        self.sql(f"UPDATE context_source_versions SET content='{{}}' WHERE id='{saved['source_version_id']}'")
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'): self.read(saved['id'])
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'): self.register()
        self.sql(f"UPDATE context_source_versions SET removed_at=now() WHERE id='{saved['source_version_id']}'")
        with self.assertRaisesRegex(AssertionError, 'Original unavailable'): self.read(saved['id'])

    def test_receipts_immutable_and_failed_registration_rolls_back(self):
        saved = self.register()
        with self.assertRaisesRegex(AssertionError, 'permission denied'):
            self.sql(f"SET ROLE service_role; DELETE FROM context_original_registrations WHERE id='{saved['id']}'")
        new_source = str(uuid.uuid4())
        with self.assertRaisesRegex(AssertionError, 'Original storage conflict'):
            self.register(key='other', source=new_source)
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_sources WHERE id='{new_source}'").stdout.strip(), '0')

    def test_explicit_empty_inputs_are_not_repaired_by_fixture(self):
        for field in ['actor', 'owner', 'source', 'path']:
            with self.subTest(field=field):
                with self.assertRaises(AssertionError): self.register(**{field: ''})

    def test_neutral_path_and_legacy_receipts_survive_forward_change(self):
        legacy = self.register()
        neutral = self.path.replace(self.object, str(uuid.uuid4())).replace('.csv','.original')
        saved = self.register(key='neutral',digest='b'*64,path=neutral)
        self.assertEqual(self.register(key='neutral',digest='b'*64,path=neutral),saved)
        self.assertEqual(self.read(legacy['id']),legacy)
        self.assertEqual(self.register(),legacy)
        self.assertEqual(self.read(saved['id']),saved)

    def test_simultaneous_changed_type_neutral_retry_has_one_receipt(self):
        neutral=self.path.replace('.csv','.original')
        def call(kind):
            try:
                return self.register(path=neutral,media_type=kind,digest=('a' if kind=='text/csv' else 'b')*64)
            except AssertionError as error:
                return str(error)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(call,['text/csv','application/pdf']))
        self.assertEqual(sum(isinstance(r,dict) for r in results),1)
        self.assertTrue(any(isinstance(r,str) and 'Original retry conflict' in r for r in results))
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_original_registrations WHERE owner_id='{self.owner}'").stdout.strip(),'1')
