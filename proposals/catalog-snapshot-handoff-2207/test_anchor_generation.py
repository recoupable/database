"""Deferred PostgreSQL regression: opt-in disposable fixture, never a remote DSN.

Not run as part of the source-only repair. Requires separate SQL qualification
approval and CATALOG_RETENTION_SQL_QUALIFICATION=1. The proposal stays unchanged;
a synthetic authorizer exists only inside the disposable fixture.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    'catalog_fence_fixture', HERE.parent / 'chat-writer-fencing-636/test_protocol.py')
fence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fence)


@unittest.skipUnless(os.environ.get('CATALOG_RETENTION_SQL_QUALIFICATION') == '1',
                     'SQL qualification not enabled; source-only repair')
class AnchorGeneration(fence.Protocol):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((HERE.parent / 'durable-surfaces-2207/proposal.sql').read_text())
        cls.sql((HERE / 'proposal.sql').read_text())
        # Verify the actual default-deny adapter before installing a synthetic seam.
        try:
            cls.sql(f"SET ROLE recoup_chat_fence_owner; SELECT chat_fence.authorize_catalog_surface_source('{fence.ACCOUNT}','{fence.ACCOUNT}','{{}}')")
        except AssertionError as error:
            if 'adapter unavailable' not in str(error):
                raise
        else:
            raise AssertionError('default authorizer unexpectedly permitted')
        cls.sql("""SET ROLE recoup_chat_fence_owner;
        CREATE OR REPLACE FUNCTION chat_fence.authorize_catalog_surface_source(
          p_account uuid,p_workspace uuid,p_source jsonb) RETURNS void
        LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
          IF p_source->>'fixtureAuthorization' IS DISTINCT FROM 'allow' THEN
            RAISE EXCEPTION 'fixture authority denied' USING ERRCODE='42501';
          END IF;
        END $$;
        GRANT EXECUTE ON FUNCTION public.retain_catalog_surface_source(text,uuid,text,bigint,uuid,text,text,bigint,text,text,text,text) TO service_role;
        """)

    def setUp(self):
        super().setUp()
        self.token = self.bind(self.admit())
        self.message_id = self.chat + 'message'
        self.surface = {'schemaVersion': 1, 'id': 'synthetic-surface', 'revision': 1,
                        'context': {'workspaceId': fence.ACCOUNT,
                                    'subject': {'kind': 'catalog', 'id': fence.OTHER}}}
        self.part = {'type': 'data-intelligent-ui-snapshot',
                     'id': self.surface['id'], 'data': self.surface}
        self.write(self.token, parts=[self.part])
        self.source = {'mappingVersion': 'catalog-streams-v1',
                       'workspaceId': fence.ACCOUNT,
                       'query': {'catalog_id': fence.OTHER},
                       'lineage': [{'fixture': 'original-observation'}],
                       'fixtureAuthorization': 'allow'}

    def retain(self, source=None):
        source_bytes = json.dumps(self.source if source is None else source)
        surface_bytes = json.dumps(self.surface)
        digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
        args = [self.chat, fence.ACCOUNT, self.chat, self.token['epoch'],
                self.token['owner'], self.token['run_id'], self.message_id, 0,
                source_bytes, surface_bytes, digest(source_bytes), digest(surface_bytes)]
        sql = 'SET ROLE service_role; SELECT public.retain_catalog_surface_source(' + ','.join(fence.quote(x) for x in args) + ')'
        return json.loads(self.sql(sql))

    def count_sources(self):
        return self.sql('SELECT count(*) FROM chat_fence.catalog_surface_sources WHERE message_id=' + fence.quote(self.message_id))

    def next_writer(self):
        self.release(self.token)
        self.token = self.bind(self.admit(self.token['epoch']), run='next-run')

    def test_catalog_current_epoch_exact_replay(self):
        receipt = self.retain()
        self.assertEqual(receipt['message_id'], self.message_id)
        self.assertEqual(receipt['source_revision'], 1)
        self.assertTrue(receipt['retained'])
        self.assertEqual(self.retain(), receipt)
        self.assertEqual(self.count_sources(), '1')

    def test_catalog_prior_epoch_reused_message_refused_before_authorizer(self):
        self.next_writer()
        # 636 insert mode can acknowledge identical bytes without adopting epoch.
        self.write(self.token, parts=[self.part], mode='insert')
        with self.assertRaisesRegex(AssertionError, 'prior message generation'):
            self.retain({**self.source, 'fixtureAuthorization': 'deny'})
        self.assertEqual(self.count_sources(), '0')

    def test_catalog_prior_epoch_refused_before_identical_receipt_replay(self):
        self.retain()
        self.next_writer()
        with self.assertRaisesRegex(AssertionError, 'prior message generation'):
            self.retain()
        self.assertEqual(self.count_sources(), '1')

    def test_catalog_missing_generation_refused(self):
        self.sql('DELETE FROM chat_fence.message_epochs WHERE message_id=' + fence.quote(self.message_id))
        with self.assertRaisesRegex(AssertionError, 'prior message generation'):
            self.retain()
        self.assertEqual(self.count_sources(), '0')

    def test_catalog_foreign_chat_generation_refused(self):
        original_chat = self.chat
        # Create another real fence row; corrupt only the fixture's anchor binding.
        super().setUp()
        self.sql('UPDATE chat_fence.message_epochs SET chat_id=' + fence.quote(self.chat) + ' WHERE message_id=' + fence.quote(self.message_id))
        self.chat = original_chat
        with self.assertRaisesRegex(AssertionError, 'prior message generation'):
            self.retain()
        self.assertEqual(self.count_sources(), '0')


def load_tests(loader, tests, pattern):
    # Reuse fixture helpers without rerunning its unrelated inherited test suite.
    return unittest.TestSuite(AnchorGeneration(name) for name in
                              loader.getTestCaseNames(AnchorGeneration)
                              if name.startswith('test_catalog_'))


if __name__ == '__main__':
    unittest.main()
