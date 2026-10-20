"""Existing foreign records and multi-input withdrawal cannot leak through discovery."""
import uuid
import evidence_manifest_fixture as fixture


class ManifestAccess(fixture.ManifestFixture):
    def test_existing_foreign_request_and_cursor_are_denied(self):
        foreign = self.run_json_query(f"SET ROLE service_role; SELECT create_context_release_request('{self.other}',"
                            f"'{self.other}','3333333333333333333333','foreign');")
        version = self.sql(f"SELECT rs.source_version_id FROM context_result_sources rs "
                           f"JOIN context_results r ON r.id=rs.result_id JOIN context_attempts a ON a.id=r.attempt_id "
                           f"WHERE a.request_id='{foreign['id']}'").stdout.strip()
        for kwargs in [{'request': foreign['id']}, {'after': version}]:
            with self.assertRaisesRegex(AssertionError, 'Evidence manifest unavailable'):
                self.list_manifest(**kwargs)

    def test_fresh_authorized_actor_can_continue_without_creator_privilege(self):
        actor = str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{actor}','New teammate');"
                 f"INSERT INTO account_organization_ids VALUES ('{actor}','{self.owner}',now());")
        self.assertEqual(self.list_manifest(actor=actor), self.list_manifest())
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{actor}'")
        with self.assertRaisesRegex(AssertionError, 'Case access denied'):
            self.list_manifest(actor=actor)

    def test_withdrawn_dependency_withholds_the_whole_result(self):
        self.save_metadata(1)
        source, version = [str(uuid.uuid4()) for _ in range(2)]
        self.sql(f"INSERT INTO context_sources(id,owner_id,kind) VALUES ('{source}','{self.owner}','customer');"
                 f"INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint) "
                 f"VALUES ('{version}','{self.owner}','{source}',repeat('f',64));"
                 f"INSERT INTO context_result_sources SELECT '{self.owner}',id,'{version}' FROM context_results "
                 f"WHERE owner_id='{self.owner}' AND topic='fixture';")
        self.assertEqual(len(self.list_manifest()['versions']), 3)
        self.sql(f"UPDATE context_source_versions SET removed_at=now() WHERE id='{version}'")
        self.assertEqual(len(self.list_manifest()['versions']), 1)

    def test_reads_do_not_change_evidence_and_unbounded_helper_is_denied(self):
        count = self.sql(f"SELECT count(*) FROM context_results WHERE owner_id='{self.owner}'").stdout.strip()
        self.list_manifest()
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_results WHERE owner_id='{self.owner}'").stdout.strip(), count)
        for role in ['anon', 'authenticated', 'service_role']:
            with self.assertRaisesRegex(AssertionError, 'permission denied'):
                self.sql(f"SET ROLE {role}; SELECT * FROM context_request_evidence_versions('{self.owner}','{self.request}');")
