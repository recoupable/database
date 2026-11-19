"""Pure compiled transport tests. Synthetic receipt/evidence; no SQL or network."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_selection_consumer import SelectionConsumer, HERE


class SelectionTransport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['CATALOG_SELECTION_SOURCE']).resolve()
        SelectionConsumer.selection_source = cls.source
        SelectionConsumer.pins = json.loads((HERE/'selection-source.json').read_text())
        SelectionConsumer.verify_selection_source()
        cls.addClassCleanup(SelectionConsumer.verify_selection_source)
        cls.output = tempfile.TemporaryDirectory(prefix='retained-selection-transport-')
        cls.addClassCleanup(cls.output.cleanup)
        subprocess.run(['node',str(HERE/'build-selection.mjs'),str(cls.source),cls.output.name],check=True,capture_output=True)
        cls.fixture_dir = cls.source/'scripts/proposals/catalog-retained-selection/fixtures'
        cls.input = json.loads((cls.fixture_dir/'synthetic-authority-input.json').read_text())

    def consume(self, payload):
        run = subprocess.run(['node', str(Path(self.output.name)/'selection-driver.mjs')],
                             input=json.dumps(payload),text=True,capture_output=True,check=True)
        return json.loads(run.stdout)

    def test_current_selection_matches_actual_inner_fixture(self):
        result=self.consume(self.input)
        self.assertEqual(result.pop('state'),'ready')
        self.assertEqual(result,json.loads((self.fixture_dir/'fieldContext.json').read_text()))

    def test_missing_pending_and_wrong_scope_receipts_withhold(self):
        for receipt in [None, {}, {'state':'pending'}, {**self.input['receipt'],'ownerId':self.input['scope']['actorId']}, {**self.input['receipt'],'key':'new-key'}]:
            with self.subTest(receipt=receipt):
                self.assertEqual(self.consume({**self.input,'receipt':receipt}),{'state':'unavailable'})

    def test_stale_binding_does_not_upgrade(self):
        for key,value in [('revision',99),('resultId',self.input['scope']['actorId']),('sourceVersionIds',[self.input['scope']['actorId']])]:
            payload=copy.deepcopy(self.input);payload['envelope'][key]=value
            self.assertEqual(self.consume(payload),{'state':'unavailable'})

    def test_current_source_refusal_redacts_entire_result(self):
        self.assertEqual(self.consume({**self.input,'envelope':None}),{'state':'unavailable'})

    def test_oversized_utf8_authority_evidence_returns_invalid_without_leak(self):
        for characters in (270000, 400000):
            with self.subTest(characters=characters):
                payload=copy.deepcopy(self.input)
                payload['envelope']['evidence']['providerRecordingId']='é'*characters
                size=len(json.dumps(payload['envelope'],ensure_ascii=False).encode('utf8'))
                self.assertGreater(size,512*1024)
                if characters==270000:self.assertLess(size,768*1024)
                else:self.assertGreater(size,768*1024)
                self.assertEqual(self.consume(payload),{'state':'invalid'})

    def test_actual_helper_integrity_failure_is_error(self):
        helper=Path(self.output.name)/'lib/catalog/compareSpotifyDailyStreams.ts'
        original=helper.read_bytes()
        try:
            helper.write_bytes(original+b'\n// synthetic integrity mismatch\n')
            self.assertEqual(self.consume(self.input),{'state':'error'})
        finally:
            helper.write_bytes(original)

    def test_invalid_query_never_uses_cached_amount(self):
        self.assertEqual(self.consume({**self.input,'query':{**self.input['query'],'days':0}}),{'state':'invalid'})


def load_tests(loader, tests, pattern):
    return loader.loadTestsFromTestCase(SelectionTransport)


if __name__=='__main__': unittest.main()
