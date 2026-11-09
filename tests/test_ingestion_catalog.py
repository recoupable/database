"""Shared organization ingestion on disposable PostgreSQL; no hosted credentials."""
import os
import json
import pathlib
import subprocess
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = ['20261110010000_ingestion_catalog.sql', '20261110010100_ingestion_catalog_page_budget.sql']


class IngestionCatalog(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-ingestion-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', f'{cls.tmp.name}/pg.log',
                        '-o', f"-k {cls.tmp.name} -p 55489 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql('''CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
          CREATE TABLE public.accounts(id uuid PRIMARY KEY);
          CREATE TABLE public.account_organization_ids(account_id uuid, organization_id uuid);
          GRANT USAGE ON SCHEMA public TO service_role, anon, authenticated;''')
        for migration in MIGRATIONS:
            cls.sql((ROOT / 'supabase/migrations' / migration).read_text())

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'], check=True, capture_output=True)

    @classmethod
    def sql(cls, statement, succeeds=True):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55489', '-d', 'postgres', '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                input=statement, text=True, capture_output=True)
        if succeeds and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def setUp(self):
        self.actor, self.org, self.other = [str(uuid.uuid4()) for _ in range(3)]
        self.job = 'a' * 64
        self.sql(f"INSERT INTO accounts VALUES ('{self.actor}'),('{self.org}'),('{self.other}'); INSERT INTO account_organization_ids VALUES ('{self.actor}','{self.org}')")

    def manifest(self, job=None, dataset=None, org=None):
        job, org = job or self.job, org or self.org
        value = {'job_id': job, 'input_sha256': 'b' * 64, 'engine_version': '1',
                 'scope': f'organization/{org}', 'format': 'csv', 'filename': 'synthetic.csv',
                 'bronze_key': f'organization/{org}/originals/' + 'c' * 64, 'bronze_sha256': 'c' * 64,
                 'source': {'kind': 'inline'}, 'contract': {'version': '1'}, 'created_at': '2026-11-10T00:00:00.000Z'}
        if dataset:
            value['dataset_id'] = dataset
        return value

    def statement(self, action, value, actor=None, org=None, role='service_role'):
        payload = json.dumps(value).replace("'", "''")
        return f"SET ROLE {role}; SELECT public.ingestion_catalog_command('{actor or self.actor}','{org or self.org}','{action}','{payload}'::jsonb)"

    def call(self, action, value, **kwargs):
        return json.loads(self.sql(self.statement(action, value, **kwargs)).stdout.strip())

    def register(self, **kwargs):
        return self.call('register', {'manifest': self.manifest(**kwargs)})

    def completion(self, status='ready', job=None, records=None):
        records = records or [{'id': '001', 'amount': '9007199254740993.00000001'}]
        gold = {'engine_version': '1', 'contract_version': '1', 'records': records,
                'field_types': {'id': 'string', 'amount': 'decimal'}} if status == 'ready' else None
        return {'job_id': job or self.job, 'gold': gold,
                'result': {'job_id': job or self.job, 'status': status, 'engine_version': '1',
                           'source_sha256': 'c' * 64, 'rows_read': len(records), 'rows_output': len(records) if gold else 0,
                           'issues': [], 'issue_count': 0, 'issues_truncated': 0, 'controls': [],
                           'silver_sha256': 'e' * 64, 'gold_sha256': 'f' * 64 if gold else None}}

    def denied(self, action, value, **kwargs):
        result = self.sql(self.statement(action, value, **kwargs), succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Ingestion access denied', result.stderr)

    def test_register_retry_and_list(self):
        first = self.register()
        self.assertEqual(self.register(), first)
        listed = self.call('datasets', {'limit': 25})
        self.assertEqual([x['dataset_id'] for x in listed['datasets']], [first['dataset_id']])
        imports = self.call('imports', {'dataset_id': first['dataset_id'], 'limit': 25})
        self.assertEqual(imports['imports'][0]['status'], 'queued')
        changed = self.manifest()
        changed['filename'] = 'changed.csv'
        result = self.sql(self.statement('register', {'manifest': changed}), succeeds=False)
        self.assertIn('Ingestion catalog conflict', result.stderr)

    def test_exact_gold_and_idempotent_completion(self):
        dataset = self.register()['dataset_id']
        receipt = self.call('complete', self.completion())
        self.assertEqual(self.call('complete', self.completion()), receipt)
        page = self.call('records', {'dataset_id': dataset, 'job_id': self.job, 'limit': 25, 'after_row': 0})
        self.assertEqual(page['records'], [{'row_number': 1, 'record': {'id': '001', 'amount': '9007199254740993.00000001'}}])
        changed = self.completion()
        changed['gold']['records'][0]['amount'] = '0'
        result = self.sql(self.statement('complete', changed), succeeds=False)
        self.assertIn('Ingestion catalog conflict', result.stderr)
        self.assertEqual(self.call('records', {'dataset_id': dataset, 'job_id': self.job})['records'], page['records'])

    def test_versions_share_dataset_without_overwriting(self):
        dataset = self.register()['dataset_id']
        self.call('complete', self.completion())
        self.register(job='d' * 64, dataset=dataset)
        self.call('complete', self.completion(job='d' * 64, records=[{'id': '002', 'amount': '1'}]))
        versions = self.call('imports', {'dataset_id': dataset})['imports']
        self.assertEqual(len(versions), 2)
        self.assertEqual(self.call('records', {'dataset_id': dataset, 'job_id': self.job})['records'][0]['record']['id'], '001')

    def test_cross_organization_and_revoked_membership(self):
        dataset = self.register()['dataset_id']
        self.call('complete', self.completion())
        self.denied('datasets', {}, org=self.other)
        self.denied('records', {'dataset_id': dataset, 'job_id': self.job}, org=self.other, actor=self.other)
        self.denied('register', {'manifest': self.manifest(job='d' * 64, dataset=dataset, org=self.other)}, org=self.other, actor=self.other)
        self.sql(f"DELETE FROM account_organization_ids WHERE account_id='{self.actor}'")
        self.denied('records', {'dataset_id': dataset, 'job_id': self.job})
        self.denied('complete', self.completion())

    def test_held_imports_have_no_queryable_gold(self):
        dataset = self.register()['dataset_id']
        self.call('complete', self.completion('held'))
        result = self.sql(self.statement('records', {'dataset_id': dataset, 'job_id': self.job}), succeeds=False)
        self.assertIn('Artifact not ready', result.stderr)
        self.assertEqual(self.sql(f"SELECT count(*) FROM ingestion_records WHERE organization_id='{self.org}'").stdout.strip(), '0')

    def test_bad_gold_is_atomic(self):
        self.register()
        value = self.completion()
        value['gold']['records'].append({'id': '002', 'amount': {'nested': 'invalid'}})
        value['result']['rows_output'] = 2
        result = self.sql(self.statement('complete', value), succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sql(f"SELECT status FROM ingestion_imports WHERE organization_id='{self.org}'").stdout.strip(), 'queued')
        self.assertEqual(self.sql(f"SELECT count(*) FROM ingestion_records WHERE organization_id='{self.org}'").stdout.strip(), '0')

    def test_private_original_scope_and_unknown_dataset(self):
        value = self.manifest()
        value['bronze_key'] = f'organization/{self.other}/originals/' + 'c' * 64
        self.assertNotEqual(self.sql(self.statement('register', {'manifest': value}), succeeds=False).returncode, 0)
        self.denied('register', {'manifest': self.manifest(dataset=str(uuid.uuid4()))})

    def test_records_pagination_is_bounded_and_version_specific(self):
        dataset = self.register()['dataset_id']
        self.call('complete', self.completion(records=[{'id': '001', 'amount': '1'}, {'id': '002', 'amount': '2'}]))
        first = self.call('records', {'dataset_id': dataset, 'job_id': self.job, 'limit': 1})
        second = self.call('records', {'dataset_id': dataset, 'job_id': self.job, 'limit': 1, 'after_row': first['next_after']})
        self.assertEqual(first['next_after'], 1)
        self.assertIsNone(second['next_after'])
        self.assertEqual(second['records'][0]['record']['id'], '002')
        self.assertNotEqual(self.sql(self.statement('records', {'dataset_id': dataset, 'job_id': self.job, 'limit': 101}), succeeds=False).returncode, 0)

    def test_record_pages_have_a_byte_budget(self):
        dataset = self.register()['dataset_id']
        records = [{'id': 'x' * 150000 + str(i), 'amount': '1'} for i in range(20)]
        self.call('complete', self.completion(records=records))
        first = self.call('records', {'dataset_id': dataset, 'job_id': self.job, 'limit': 25})
        self.assertLess(len(first['records']), 20)
        self.assertGreater(len(first['records']), 0)
        second = self.call('records', {'dataset_id': dataset, 'job_id': self.job, 'limit': 25, 'after_row': first['next_after']})
        self.assertEqual(len(first['records']) + len(second['records']), 20)
        self.assertIsNone(second['next_after'])

    def test_an_oversized_single_record_is_not_silently_skipped(self):
        dataset = self.register()['dataset_id']
        self.call('complete', self.completion(records=[{'id': 'x' * (3 * 1024 * 1024), 'amount': '1'}]))
        result = self.sql(self.statement('records', {'dataset_id': dataset, 'job_id': self.job}), succeeds=False)
        self.assertIn('Ingestion record size limit', result.stderr)

    def test_browser_and_service_direct_table_access_denied(self):
        for role in ['anon', 'authenticated']:
            self.assertNotEqual(self.sql(self.statement('datasets', {}, role=role), succeeds=False).returncode, 0)
        for table in ['ingestion_datasets', 'ingestion_imports', 'ingestion_records']:
            for role in ['anon', 'authenticated', 'service_role']:
                self.assertNotEqual(self.sql(f'SET ROLE {role}; SELECT * FROM public.{table}', succeeds=False).returncode, 0)
        self.assertEqual(self.sql("SELECT count(*) FROM pg_class WHERE relname IN ('ingestion_datasets','ingestion_imports','ingestion_records') AND relrowsecurity").stdout.strip(), '3')

    @unittest.skipUnless(os.environ.get('INGESTION_API_WORKTREE'), 'Optional API worktree integration')
    def test_actual_api_processing_and_recovery(self):
        result = subprocess.run(['pnpm', 'dlx', 'node@22', 'node_modules/vitest/vitest.mjs', 'run',
                                 'lib/ingestion/__tests__/catalog.integration.test.ts'],
                                cwd=os.environ['INGESTION_API_WORKTREE'],
                                env={**os.environ, 'INGESTION_CATALOG_TEST_SOCKET': self.tmp.name},
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_concurrent_registration_and_completion_converge(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            ids = list(pool.map(lambda _: self.register()['dataset_id'], range(4)))
        self.assertEqual(len(set(ids)), 1)
        with ThreadPoolExecutor(max_workers=4) as pool:
            receipts = list(pool.map(lambda _: self.call('complete', self.completion()), range(4)))
        self.assertTrue(all(x == receipts[0] for x in receipts))
        self.assertEqual(self.sql(f"SELECT count(*) FROM ingestion_records WHERE organization_id='{self.org}'").stdout.strip(), '1')


if __name__ == '__main__':
    unittest.main()
