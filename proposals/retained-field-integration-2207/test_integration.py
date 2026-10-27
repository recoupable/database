"""Actual retained writer -> locked reader -> pinned evaluator, disposable only."""
import contextlib
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'stream-retention-writer-2207'))
from test_writer import Writer, uid

PIN = '6ba799dbb67be284adcd6f8bcd8fcde2faa6c2b8'
FILES = {
    'scripts/proposals/catalog-stream-fields/evaluate.ts': '163563e15dd92d473aa51899c54c96300f20d27072b83e39ffb01c84f3adc64e',
    'scripts/proposals/catalog-stream-fields/recipe.json': '65a06a785aa496e1232fe3a9f1606595f19c1a152b710ca30c4c06612f01864a',
    'lib/catalog/compareSpotifyDailyStreams.ts': '91dcca66c8dec0851c1f6e110257a63b730e9b7ae33a60bceb0e9ffcf318dd81',
}


def verify_source(source):
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != PIN:
        raise AssertionError(f'API checkout must be pinned at {PIN}; got {head}')
    for name, digest in FILES.items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
            raise AssertionError(f'Pinned source drift: {name}')


class Integration(Writer):
    @classmethod
    def setUpClass(cls):
        cls.source = pathlib.Path(os.environ['CATALOG_API_SOURCE']).resolve()
        verify_source(cls.source)
        cls.output = tempfile.TemporaryDirectory(prefix='recoup-field-evaluator-')
        cls.addClassCleanup(cls.output.cleanup)
        subprocess.run(['node', str(HERE / 'build.mjs'), str(cls.source), cls.output.name], check=True)
        cls.addClassCleanup(verify_source, cls.source)
        super().setUpClass()

    def complete_bundle(self, previous=50):
        self.sql(f"""UPDATE catalog_stream_runs SET since='2026-10-23';
        INSERT INTO catalog_stream_observations
        SELECT run_id,catalog_id,isrc,'2026-10-23',{previous},provider_recording_id,source_hash,retrieved_at
        FROM catalog_stream_observations;""")
        bundle = json.loads(self.bundle)
        row = dict(bundle['observations'][0], date='2026-10-23', streams=previous)
        bundle['observations'].insert(0, row)
        bundle['absentDates'] = []
        self.bundle = json.dumps(bundle)

    @contextlib.contextmanager
    def locked_read(self, receipt, actor=1):
        # Actor is explicit synthetic fixture authority, never inferred from receipt.
        p = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55473', '-d', 'postgres',
                              '-XAtq', '-v', 'ON_ERROR_STOP=1'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        args = [uid(actor)] + [receipt[k] for k in ('ownerId', 'requestId', 'subjectId', 'catalogId', 'resultId', 'sourceVersionId')]
        values = ','.join("'" + value + "'" for value in args)
        try:
            p.stdin.write(f"BEGIN; SELECT stream_binding_proposal.read_binding({values},{receipt['revision']});\n")
            p.stdin.flush()
            line = p.stdout.readline()
            if not line:
                self.fail('Reader failed: ' + p.stderr.read())
            yield json.loads(line)
        finally:
            _, error = p.communicate('ROLLBACK;\n', timeout=10)
            self.assertEqual(p.returncode, 0, error)

    def evaluate(self, receipt, envelope, field='absolute_growth', selection_changes=None):
        selection = {k: receipt[k] for k in ('ownerId','subjectId','requestId','catalogId','resultId','revision')}
        selection.update(topic='catalog_retained_streams', sourceVersionIds=[receipt['sourceVersionId']],
                         query={'since': '2026-10-24', 'days': 1, 'timezone': 'UTC'})
        selection.update(selection_changes or {})
        boundary = {'state': 'unavailable'} if envelope is None else {'state': 'qualified', 'envelope': envelope}
        payload = {'operation': 'read_field', 'recipe': 'catalog-retained-stream-fields/1',
                   'field': field, 'selection': selection, 'boundary': boundary, 'asOf': '2026-10-27T00:00:00Z'}
        result = subprocess.run(['node', str(pathlib.Path(self.output.name) / 'driver.mjs')],
                                input=json.dumps(payload), capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def assert_refused(self, receipt, actor=1):
        with self.locked_read(receipt, actor) as envelope:
            self.assertIsNone(envelope)
            value = self.evaluate(receipt, envelope)
            self.assertEqual(value['state'], 'refused')
            self.assertEqual(set(value), {'state', 'reason'})

    def test_integration_four_fields_full_binding(self):
        self.complete_bundle()
        receipt = self.retain()
        with self.locked_read(receipt) as envelope:
            self.assertLessEqual(len(json.dumps(envelope).encode()), 786432)
            self.assertLessEqual(len(json.dumps(envelope['evidence']).encode()), 524288)
            for field, amount in [('previous_streams',50),('current_streams',100),('absolute_growth',50),('percentage_growth',100)]:
                value = self.evaluate(receipt, envelope, field)
                self.assertEqual(value['state'], 'ready', value)
                self.assertEqual(value['field']['amount'], amount)
                self.assertEqual(value['binding'], {k:v for k,v in envelope.items() if k != 'evidence'})
                self.assertEqual(value['query'], {'since':'2026-10-24','days':1,'timezone':'UTC'})
                self.assertEqual(value['periods'], envelope['evidence']['periods'])
                self.assertEqual(value['provenance']['observations'], envelope['evidence']['observations'])
                self.assertEqual(value['ref'], {'workspaceId':receipt['ownerId'],'authority':'context',
                                               'kind':'recording','id':receipt['subjectId'],
                                               'sourceVersionIds':[receipt['sourceVersionId']]})
                self.assertEqual(value['recipeHash'], FILES['scripts/proposals/catalog-stream-fields/recipe.json'])
                self.assertEqual(value['helperSha256'], FILES['lib/catalog/compareSpotifyDailyStreams.ts'])
            for changes in ({'revision':2},{'resultId':uid(99)},{'sourceVersionIds':[uid(99)]},{'query':{'since':'2026-10-23','days':1,'timezone':'UTC'}}):
                self.assertEqual(self.evaluate(receipt,envelope,selection_changes=changes)['state'],'refused')

    def test_integration_unknown_and_observed_zero(self):
        receipt = self.retain()
        with self.locked_read(receipt) as envelope:
            value = self.evaluate(receipt,envelope)
            self.assertEqual(value['field']['state'],'unknown')
            self.assertIsNone(value['field']['amount'])
        self.setUp(); self.complete_bundle(previous=0)
        receipt = self.retain()
        with self.locked_read(receipt) as envelope:
            self.assertEqual(self.evaluate(receipt,envelope,'previous_streams')['field']['amount'],0)
            self.assertIsNone(self.evaluate(receipt,envelope,'percentage_growth')['field']['amount'])

    def test_integration_retry_and_current_revision(self):
        self.complete_bundle()
        first = self.retain()
        self.assertEqual(self.retain(), first)
        self.assertEqual(self.reconcile(), first)
        second = self.retain(key='second',revision=1)
        self.assertEqual(first['sourceVersionId'],second['sourceVersionId'])
        self.assertNotEqual(first['resultId'],second['resultId'])
        self.assert_refused(first)
        self.assertIsNone(self.reconcile())
        with self.locked_read(second) as envelope:
            value = self.evaluate(second,envelope)
            self.assertEqual(value['binding']['revision'],2)
            self.assertEqual(value['field']['amount'],50)

    def test_integration_correction_withdrawal_revocation(self):
        for mutation in ("UPDATE catalog_stream_observations SET streams=200",
                         'SELECT withdraw_context_source(owner_id,id) FROM context_sources',
                         'DELETE FROM catalog_songs', 'DELETE FROM account_catalogs'):
            with self.subTest(mutation=mutation):
                self.setUp(); self.complete_bundle(); receipt=self.retain()
                with self.locked_read(receipt) as envelope:
                    self.assertEqual(self.evaluate(receipt,envelope)['state'],'ready')
                self.sql(mutation)
                self.assert_refused(receipt)
                self.assertIsNone(self.reconcile())
        self.setUp(); receipt=self.retain()
        self.assert_refused(receipt,actor=12)

    def test_integration_supported_correction_retain_and_recompute(self):
        self.complete_bundle(); original = self.retain()
        self.sql(f"""INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
        SELECT '{uid(13)}',catalog_id,revision,'2026-10-26','2026-10-24','2026-10-24' FROM catalog_stream_tracking;""")
        correction = {'state':'complete','days':[{'date':'2026-10-24','streams':200}],
                      'provider_recording_id':'provider-a','source_hash':'b'*64,'retrieved_at':'2026-10-26T00:00:00Z'}
        self.assertEqual(self.sql(f"SELECT commit_catalog_stream_track('{uid(13)}','USAAA2600001','{json.dumps(correction)}')").stdout.strip(),'t')
        self.assert_refused(original)
        bundle=json.loads(self.bundle)
        bundle['observations'][1].update(run_id=uid(13),streams=200,source_hash='b'*64,retrieved_at='2026-10-26T00:00:00+00:00')
        bundle['retrievalRange']['latest']='2026-10-26T00:00:00+00:00'
        fresh=self.retain(key='corrected',revision=1,bundle=bundle)
        self.assertNotEqual(original['sourceVersionId'],fresh['sourceVersionId'])
        with self.locked_read(fresh) as envelope:
            self.assertEqual(self.evaluate(fresh,envelope)['field']['amount'],150)
        self.assert_refused(original)

    def test_integration_utf8_budget_refuses_atomic_retention(self):
        provider='é'*140000
        self.sql("UPDATE catalog_stream_observations SET provider_recording_id=repeat('é',140000)")
        bundle=json.loads(self.bundle)
        bundle['providerRecordingId']=provider
        bundle['observations'][0]['provider_recording_id']=provider
        self.assertGreater(len(json.dumps(bundle,ensure_ascii=False).encode()),524288)
        self.assertIsNone(self.retain(bundle=bundle))
        for table in ('context_sources','context_source_versions','context_attempts','context_results','context_result_sources','context_documents'):
            self.assertEqual(self.sql(f'SELECT count(*) FROM {table}').stdout.strip(),'0')

    def test_integration_storage_budget_denies_previously_ready_result(self):
        self.complete_bundle(); receipt=self.retain()
        with self.locked_read(receipt) as envelope:
            self.assertEqual(self.evaluate(receipt,envelope)['state'],'ready')
        self.sql("""INSERT INTO context_source_versions(owner_id,source_id,fingerprint,content,retrieved_at)
        SELECT owner_id,source_id,md5(i::text)||md5(i::text),content,retrieved_at
        FROM context_source_versions CROSS JOIN generate_series(1,256) i;""")
        self.assert_refused(receipt)

    def test_integration_compute_holds_supported_mutator_locks(self):
        self.complete_bundle(); receipt=self.retain()
        with self.locked_read(receipt) as envelope:
            for mutation in ('DELETE FROM catalog_songs','DELETE FROM account_catalogs',
                             'SELECT withdraw_context_source(owner_id,id) FROM context_sources',
                             f"SELECT commit_catalog_stream_track('{uid(7)}','USAAA2600001','{{\"state\":\"unavailable\"}}')"):
                with self.assertRaisesRegex(AssertionError,'statement timeout'):
                    self.sql("SET statement_timeout='200ms'; " + mutation)
            self.assertEqual(self.evaluate(receipt,envelope)['field']['amount'],50)
        self.sql('SELECT withdraw_context_source(owner_id,id) FROM context_sources')
        self.assert_refused(receipt)


if __name__ == '__main__':
    suite = unittest.TestSuite(Integration(name) for name in unittest.defaultTestLoader.getTestCaseNames(Integration)
                               if name.startswith('test_integration_'))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
