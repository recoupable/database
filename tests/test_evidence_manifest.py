"""Request-scoped discovery without providers, original files or inferred rights."""
import uuid
import evidence_manifest_fixture as fixture


class EvidenceManifest(fixture.ManifestFixture):
    def test_saved_locator_is_discoverable_without_collection_or_raw_content(self):
        page = self.list_manifest()
        self.assertEqual(len(page['versions']), 1)
        item = page['versions'][0]
        self.assertEqual(item['source_kind'], 'customer')
        self.assertEqual(item['evidence_kinds'], ['customer_assertion'])
        self.assertTrue(item['is_current'])
        self.assertEqual(set(item), {'source_version_id', 'source_id', 'source_kind', 'fingerprint',
                                    'retrieved_at', 'evidence_kinds', 'is_current'})
        self.assertEqual(self.list_manifest(), page)

    def test_retained_history_and_exact_version_reuse(self):
        self.save_metadata(1)
        self.save_metadata(2)
        page = self.list_manifest()
        self.assertEqual(len(page['versions']), 3)
        observations = [v for v in page['versions'] if v['source_kind'] == 'provider_metadata']
        self.assertEqual(sum(v['is_current'] for v in observations), 1)
        self.save_metadata(2)
        self.assertEqual({v['source_version_id'] for v in self.list_manifest()['versions']},
                         {v['source_version_id'] for v in page['versions']})

    def test_shared_version_deduplication_preserves_distinct_kinds(self):
        self.save_metadata(1)
        self.save_metadata(1, topic='second')
        self.sql(f"UPDATE context_results SET evidence_kind='customer_assertion' WHERE owner_id='{self.owner}' AND topic='second'")
        page = self.list_manifest()
        observations = [v for v in page['versions'] if v['source_kind'] == 'provider_metadata']
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]['evidence_kinds'], ['customer_assertion', 'observation'])

    def test_nonaccepted_and_creative_results_are_not_fact_evidence(self):
        self.save_metadata(1)
        self.sql(f"UPDATE context_results SET status='failed' WHERE owner_id='{self.owner}' AND topic='fixture'")
        self.assertEqual(len(self.list_manifest()['versions']), 1)
        self.sql(f"UPDATE context_results SET status='accepted',evidence_kind='creative_proposal' WHERE owner_id='{self.owner}' AND topic='fixture'")
        self.assertEqual(len(self.list_manifest()['versions']), 1)

    def test_foreign_missing_request_cursor_and_revocation_denied(self):
        for kwargs in [{'owner': self.other}, {'request': str(uuid.uuid4())}, {'after': str(uuid.uuid4())}]:
            with self.assertRaisesRegex(AssertionError, 'Evidence manifest unavailable|Case access denied'):
                self.list_manifest(**kwargs)
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
        with self.assertRaisesRegex(AssertionError, 'Case access denied'):
            self.list_manifest()
        self.assertEqual(len(self.list_manifest(actor=self.owner)['versions']), 1)

    def test_removed_and_withdrawn_versions_withheld(self):
        item = self.list_manifest()['versions'][0]
        self.sql(f"UPDATE context_source_versions SET removed_at=now() WHERE id='{item['source_version_id']}'")
        self.assertEqual(self.list_manifest()['versions'], [])
        with self.assertRaisesRegex(AssertionError, 'Evidence manifest unavailable'):
            self.list_manifest(after=item['source_version_id'])
        self.sql(f"UPDATE context_source_versions SET removed_at=null WHERE id='{item['source_version_id']}';"
                 f"SELECT withdraw_context_source('{self.owner}','{item['source_id']}');")
        self.assertEqual(self.list_manifest()['versions'], [])

    def test_bounded_paging_and_foreign_cursor(self):
        self.sql(f"DO $$ BEGIN FOR i IN 1..55 LOOP PERFORM save_context_metadata('{self.owner}',"
                 f"'{self.request}','{self.subject}','page','urn:page:{self.request}:'||i,"
                 "jsonb_build_object('i',i),now()); END LOOP; END $$;")
        first = self.list_manifest()
        self.assertEqual(len(first['versions']), 50)
        self.assertTrue(first['has_more'])
        second = self.list_manifest(after=first['next_id'])
        self.assertEqual(len(second['versions']), 6)
        self.assertFalse(second['has_more'])
        self.assertIsNone(second['next_id'])
        self.assertFalse({v['source_version_id'] for v in first['versions']} &
                         {v['source_version_id'] for v in second['versions']})

    def test_browser_roles_cannot_execute(self):
        for role in ['anon', 'authenticated']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(f"SET ROLE {role}; SELECT list_context_request_evidence_versions("
                         f"'{self.actor}','{self.owner}','{self.request}');")
