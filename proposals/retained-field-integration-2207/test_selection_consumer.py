"""Deferred actual Context receipt -> selection -> locked reader -> inner consumer.
Default skipped. No PostgreSQL qualification is authorized by adding these tests.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

from test_integration import Integration, uid, FILES

HERE = Path(__file__).resolve().parent


@unittest.skipUnless(os.environ.get('CATALOG_SELECTION_SQL_QUALIFICATION') == '1',
                     'SQL hold: genuine selection scenarios are deferred')
class SelectionConsumer(Integration):
    @classmethod
    def setUpClass(cls):
        # Original fixture still pins the original evaluator checkout at its adopted SHA.
        cls.selection_source = Path(os.environ['CATALOG_SELECTION_SOURCE']).resolve()
        cls.pins = json.loads((HERE / 'selection-source.json').read_text())
        cls.verify_selection_source()
        super().setUpClass()
        cls.addClassCleanup(cls.verify_selection_source)
        subprocess.run(['node', str(HERE / 'build-selection.mjs'),
                        str(cls.selection_source), cls.output.name], check=True)

    @classmethod
    def verify_selection_source(cls):
        head = subprocess.check_output(['git', '-C', str(cls.selection_source),
                                        'rev-parse', 'HEAD'], text=True).strip()
        if head != cls.pins['head']:
            raise AssertionError('Selection source head differs from frozen companion')
        for name, digest in {**FILES, **cls.pins['files']}.items():
            if hashlib.sha256((cls.selection_source / name).read_bytes()).hexdigest() != digest:
                raise AssertionError('Selection source drift: ' + name)

    def consume(self, receipt, envelope, actor=1, key='first'):
        payload = {
            'scope': {'actorId': uid(actor), 'workspaceId': uid(1), 'requestId': uid(4),
                      'catalogId': uid(2), 'key': key},
            'actor': {'actorId': uid(actor), 'sessionId': 'synthetic-session',
                      'chatId': 'synthetic-chat', 'messageId': 'synthetic-assistant'},
            'receipt': receipt, 'envelope': envelope,
            'query': {'since': '2026-10-24', 'days': 1, 'timezone': 'UTC'},
            'asOf': '2026-10-27T00:00:00Z',
        }
        result = subprocess.run(['node', str(Path(self.output.name) / 'selection-driver.mjs')],
                                input=json.dumps(payload), capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_selection_current_receipt_exact_consumer(self):
        self.complete_bundle(); original = self.retain()
        current = self.reconcile()
        self.assertEqual(current, original)
        with self.locked_read(current) as envelope:
            result = self.consume(current, envelope)
            self.assertEqual(result['state'], 'ready')
            item = result['items'][0]
            self.assertEqual(item['value'], {'state': 'known', 'amount': 100})
            for key in ('ownerId', 'requestId', 'subjectId', 'catalogId', 'resultId', 'revision'):
                self.assertEqual(item['binding'][key], current[key])
            self.assertEqual(item['binding']['sourceVersionIds'], [current['sourceVersionId']])
            self.assertNotIn('observations', json.dumps(result))
            self.assertNotIn('providerRecordingId', json.dumps(result))

    def test_selection_missing_key_and_wrong_actor(self):
        self.complete_bundle(); original = self.retain()
        self.assertEqual(self.consume(self.reconcile('missing'), None, key='missing'), {'state': 'unavailable'})
        self.assertEqual(self.consume(self.reconcile(actor=12), None, actor=12), {'state': 'unavailable'})
        # Even a previously genuine receipt does not restore a denied current read.
        with self.locked_read(original, actor=12) as envelope:
            self.assertEqual(self.consume(original, envelope, actor=12), {'state': 'unavailable'})

    def test_selection_withdrawal_removed_membership_and_expansion(self):
        for mutation in (
            'SELECT withdraw_context_source(owner_id,id) FROM context_sources',
            'UPDATE context_source_versions SET removed_at=now()',
            'DELETE FROM catalog_songs', 'DELETE FROM account_catalogs',
            'DELETE FROM context_request_catalog_members',
        ):
            with self.subTest(mutation=mutation):
                self.setUp(); self.complete_bundle(); original = self.retain()
                self.sql(mutation)
                self.assertIsNone(self.reconcile())
                with self.locked_read(original) as envelope:
                    self.assertEqual(self.consume(original, envelope), {'state': 'unavailable'})

    def test_selection_new_current_result_does_not_upgrade_old_key(self):
        self.complete_bundle(); original = self.retain()
        fresh = self.retain(key='second', revision=1)
        self.assertNotEqual(original['resultId'], fresh['resultId'])
        self.assertEqual(self.consume(self.reconcile(), None), {'state': 'unavailable'})
        with self.locked_read(original) as envelope:
            self.assertEqual(self.consume(original, envelope), {'state': 'unavailable'})
        current_fresh = self.reconcile('second')
        with self.locked_read(fresh) as envelope:
            result = self.consume(current_fresh, envelope, key='second')
            self.assertEqual(result['items'][0]['binding']['resultId'], fresh['resultId'])

    def test_selection_supported_correction_refuses_original(self):
        self.complete_bundle(); original = self.retain()
        self.sql(f"""INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
        SELECT '{uid(13)}',catalog_id,revision,'2026-10-26','2026-10-24','2026-10-24' FROM catalog_stream_tracking;""")
        correction = {'state': 'complete', 'days': [{'date': '2026-10-24', 'streams': 200}],
                      'provider_recording_id': 'provider-a', 'source_hash': 'b'*64,
                      'retrieved_at': '2026-10-26T00:00:00Z'}
        self.assertEqual(self.sql(f"SELECT commit_catalog_stream_track('{uid(13)}','USAAA2600001','{json.dumps(correction)}')").stdout.strip(), 't')
        self.assertIsNone(self.reconcile())
        with self.locked_read(original) as envelope:
            self.assertEqual(self.consume(original, envelope), {'state': 'unavailable'})


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(SelectionConsumer(name) for name in
                              loader.getTestCaseNames(SelectionConsumer)
                              if name.startswith('test_selection_'))


if __name__ == '__main__':
    unittest.main()
