"""Actual offline writer and adopted read regressions; no hosted credentials."""
import json
import pathlib
import sys
import subprocess
import unittest
from concurrent.futures import ThreadPoolExecutor

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'stream-evidence-binding-2207'))
from test_binding import Binding, uid


class Writer(Binding):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((HERE / 'writer.sql').read_text())

    def setUp(self):
        super().setUp()
        self.bundle = self.sql('SELECT content FROM context_source_versions').stdout.strip()
        self.sql('''DELETE FROM context_documents; DELETE FROM context_result_sources;
        DELETE FROM context_results; DELETE FROM context_attempts;
        DELETE FROM context_source_versions; DELETE FROM context_sources;''')

    # Adopted reader tests need their original saved fixture; run them separately.
    def retain(self, key='first', revision=0, bundle=None, catalog=2, request=4):
        content = (self.bundle if bundle is None else json.dumps(bundle)).replace("'", "''")
        return json.loads(self.sql(f"SELECT stream_binding_proposal.retain('{uid(1)}','{uid(1)}','{uid(request)}','{uid(5)}','{uid(catalog)}','{key}',{revision},'{content}'::jsonb)").stdout)

    def reconcile(self, key='first', actor=1):
        return json.loads(self.sql(f"SELECT stream_binding_proposal.reconcile_retention('{uid(actor)}','{uid(1)}','{uid(4)}','{key}')").stdout)

    def test_writer_first_create_retry_reconcile(self):
        receipt = self.retain()
        self.assertEqual(receipt['revision'], 1)
        self.assertEqual(self.retain(), receipt)
        self.assertEqual(self.reconcile(), receipt)
        self.assertEqual(self.sql('SELECT count(*) FROM context_attempts').stdout.strip(), '1')
        self.assertEqual(self.sql('SELECT count(*) FROM context_source_versions').stdout.strip(), '1')

    def test_writer_changed_retry_and_revision_conflict_roll_back(self):
        self.retain()
        with self.assertRaisesRegex(AssertionError, 'command conflict'):
            self.retain(revision=1)
        with self.assertRaisesRegex(AssertionError, 'revision conflict'):
            self.retain(key='other')
        self.assertEqual(self.sql('SELECT count(*) FROM context_attempts').stdout.strip(), '1')

    def test_writer_invalid_bundle_rolls_back_all_records(self):
        bad = json.loads(self.bundle); bad['inventedGrowth'] = 999
        self.assertIsNone(self.retain(bundle=bad))
        for table in ('context_sources','context_source_versions','context_attempts','context_results','context_result_sources','context_documents'):
            self.assertEqual(self.sql(f'SELECT count(*) FROM {table}').stdout.strip(), '0')

    def test_writer_concurrent_first_create_one_cas_winner(self):
        def save(key):
            try:
                return self.retain(key=key)
            except AssertionError as exc:
                self.assertIn('revision conflict', str(exc)); return 'conflict'
        with ThreadPoolExecutor(max_workers=2) as pool:
            values = list(pool.map(save, ['a','b']))
        self.assertEqual(sum(isinstance(x,dict) for x in values), 1)
        self.assertEqual(values.count('conflict'), 1)
        self.assertEqual(self.sql('SELECT count(*) FROM context_sources').stdout.strip(), '1')

    def test_writer_concurrent_same_key_replays_one_receipt(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            values = list(pool.map(lambda _: self.retain(), range(2)))
        self.assertEqual(values[0],values[1])
        self.assertEqual(self.sql('SELECT count(*) FROM context_results').stdout.strip(), '1')

    def test_writer_new_key_deduplicates_version_and_stales_old_receipt(self):
        first = self.retain()
        second = self.retain(key='second', revision=1)
        self.assertEqual(first['sourceVersionId'], second['sourceVersionId'])
        self.assertNotEqual(first['resultId'], second['resultId'])
        self.assertIsNone(self.reconcile())
        self.assertEqual(self.reconcile('second'), second)
        self.assertEqual(self.sql('SELECT count(*) FROM context_source_versions').stdout.strip(), '1')

    def test_writer_customer_correction_and_removed_version_preserved(self):
        receipt = self.retain()
        self.sql("UPDATE context_results SET evidence_kind='customer_assertion'")
        self.assertIsNone(self.retain(key='new', revision=1))
        self.assertEqual(self.sql('SELECT current_result_id FROM context_documents').stdout.strip(), receipt['resultId'])
        self.assertEqual(self.sql('SELECT revision FROM context_documents').stdout.strip(), '1')
        self.sql("UPDATE context_results SET evidence_kind='observation'; UPDATE context_source_versions SET removed_at=now()")
        self.assertIsNone(self.retain(key='new', revision=1))
        self.assertIsNone(self.reconcile())

    def test_writer_withdrawal_and_revocation_no_recreation(self):
        self.retain()
        self.sql("SELECT withdraw_context_source(owner_id,id) FROM context_sources")
        self.assertIsNone(self.retain(key='new',revision=2))
        self.assertIsNone(self.reconcile())
        self.assertEqual(self.sql('SELECT count(*) FROM context_sources').stdout.strip(), '1')
        self.setUp(); self.retain()
        self.sql('DELETE FROM catalog_songs')
        self.assertIsNone(self.reconcile())
        self.assertIsNone(self.retain(key='new',revision=1))
        self.assertEqual(self.sql('SELECT count(*) FROM context_results').stdout.strip(), '1')

    def test_writer_failed_replacement_restores_all_rows_and_document(self):
        original = self.retain()
        before = self.sql('SELECT row_to_json(d) FROM context_documents d').stdout
        bad = json.loads(self.bundle); bad['inventedGrowth'] = 999
        self.assertIsNone(self.retain(key='bad', revision=1, bundle=bad))
        self.assertEqual(self.sql('SELECT row_to_json(d) FROM context_documents d').stdout, before)
        self.assertEqual(self.reconcile(), original)
        for table in ('context_sources','context_source_versions','context_attempts','context_results','context_result_sources','context_documents'):
            self.assertEqual(self.sql(f'SELECT count(*) FROM {table}').stdout.strip(), '1')

    def test_writer_receipt_failure_rolls_back_atomic_save(self):
        self.sql("""CREATE FUNCTION stream_binding_proposal.fail_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'Injected receipt failure'; END $$;
        CREATE TRIGGER fail_receipt BEFORE UPDATE OF validation ON context_results
        FOR EACH ROW EXECUTE FUNCTION stream_binding_proposal.fail_receipt();""")
        try:
            with self.assertRaisesRegex(AssertionError, 'Injected receipt failure'):
                self.retain()
            for table in ('context_sources','context_source_versions','context_attempts','context_results','context_result_sources','context_documents'):
                self.assertEqual(self.sql(f'SELECT count(*) FROM {table}').stdout.strip(), '0')
        finally:
            self.sql('DROP TRIGGER fail_receipt ON context_results; DROP FUNCTION stream_binding_proposal.fail_receipt()')

    def test_writer_provider_history_switch_rolls_back(self):
        self.retain()
        self.sql("UPDATE catalog_stream_observations SET provider_recording_id='provider-b'")
        changed=json.loads(self.bundle); changed['providerRecordingId']='provider-b'
        changed['observations'][0]['provider_recording_id']='provider-b'
        self.assertIsNone(self.retain(key='switch',revision=1,bundle=changed))
        self.assertEqual(self.sql('SELECT count(*) FROM context_source_versions').stdout.strip(), '1')
        self.assertEqual(self.sql('SELECT revision FROM context_documents').stdout.strip(), '1')

    def test_writer_observation_work_budget_overflow(self):
        self.sql("""INSERT INTO catalog_stream_runs(catalog_id,revision,scheduled_day,since,until)
        SELECT catalog_id,revision,'1900-01-01'::date+i,'2026-10-24','2026-10-24'
        FROM catalog_stream_tracking CROSS JOIN generate_series(1,4095) i;
        INSERT INTO catalog_stream_observations
        SELECT r.id,r.catalog_id,'USAAA2600001','2026-10-24',100,'provider-a',repeat('a',64),'2026-10-24T00:00:00Z'
        FROM catalog_stream_runs r WHERE r.scheduled_day<'2020-01-01';""")
        self.assertIsInstance(self.retain(),dict)
        self.sql("""WITH added AS (INSERT INTO catalog_stream_runs(catalog_id,revision,scheduled_day,since,until)
        SELECT catalog_id,revision,'1900-01-01'::date+4096,'2026-10-24','2026-10-24' FROM catalog_stream_tracking RETURNING *)
        INSERT INTO catalog_stream_observations SELECT id,catalog_id,'USAAA2600001','2026-10-24',100,'provider-a',repeat('a',64),'2026-10-24T00:00:00Z' FROM added;""")
        self.assertIsNone(self.reconcile())
        self.assertIsNone(self.retain(key='overflow',revision=1))
        self.assertEqual(self.sql('SELECT count(*) FROM context_results').stdout.strip(), '1')

    def test_writer_source_history_budget_prevents_new_and_retry_reads(self):
        self.retain()
        self.sql("""INSERT INTO context_source_versions(owner_id,source_id,fingerprint,content,retrieved_at)
        SELECT owner_id,source_id,md5(i::text)||md5(i::text),content,retrieved_at
        FROM context_source_versions CROSS JOIN generate_series(1,256) i;""")
        self.assertIsNone(self.reconcile())
        self.assertIsNone(self.retain(key='overflow',revision=1))
        self.assertEqual(self.sql('SELECT count(*) FROM context_results').stdout.strip(), '1')

    def test_writer_read_committed_and_default_denial(self):
        value=self.sql(f"BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT stream_binding_proposal.reconcile_retention('{uid(1)}','{uid(1)}','{uid(4)}','first'); ROLLBACK").stdout
        self.assertIn('null',value.splitlines())
        self.assertEqual(self.sql("SELECT has_function_privilege('service_role','stream_binding_proposal.retain(uuid,uuid,uuid,uuid,uuid,text,bigint,jsonb)','EXECUTE')").stdout.strip(),'f')

    def test_writer_held_replacement_blocks_supported_mutators(self):
        self.retain()
        content=self.bundle.replace("'","''")
        holder=subprocess.Popen(['psql','-h',self.tmp.name,'-p','55473','-d','postgres','-XAt','-v','ON_ERROR_STOP=1'],
          stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            holder.stdin.write(f"BEGIN; SELECT stream_binding_proposal.retain('{uid(1)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','held',1,'{content}'::jsonb);\n\\echo HELD\n")
            holder.stdin.flush()
            while True:
                line=holder.stdout.readline()
                if not line: self.fail('Holder failed: '+holder.stderr.read())
                if line.strip()=='HELD': break
            for sql in ['DELETE FROM catalog_songs','DELETE FROM account_catalogs',
                        'SELECT withdraw_context_source(owner_id,id) FROM context_sources',
                        f"SELECT commit_catalog_stream_track('{uid(7)}','USAAA2600001','{{\"state\":\"unavailable\"}}')"]:
                with self.assertRaisesRegex(AssertionError,'statement timeout'):
                    self.sql("SET statement_timeout='200ms'; "+sql)
        finally:
            holder.communicate('COMMIT;\n',timeout=10)
            self.assertEqual(holder.returncode,0)
        self.assertEqual(self.reconcile('held')['revision'],2)


    def second_catalog(self):
        self.sql(f"""INSERT INTO catalogs VALUES ('{uid(20)}','Second synthetic catalog',now());
        INSERT INTO account_catalogs VALUES ('{uid(1)}','{uid(20)}');
        INSERT INTO catalog_songs VALUES ('USAAA2600001','{uid(20)}');
        INSERT INTO context_resources(id,provider,resource_kind,provider_id,canonical_url)
        VALUES ('{uid(21)}','recoup','catalog','{uid(20)}','urn:recoup:catalog:{uid(20)}');
        INSERT INTO context_subjects(id,kind,catalog_id) VALUES ('{uid(22)}','catalog','{uid(20)}');
        INSERT INTO context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
        VALUES ('{uid(23)}','{uid(1)}','{uid(1)}','{uid(21)}','second',repeat('a',64),'{{}}','partial','{{"subjectIds":["{uid(22)}"]}}');
        INSERT INTO context_request_catalog_members(request_id,owner_id,catalog_subject_id,recording_subject_id,catalog_id,song_isrc)
        VALUES ('{uid(23)}','{uid(1)}','{uid(22)}','{uid(5)}','{uid(20)}','USAAA2600001');
        INSERT INTO catalog_stream_tracking(catalog_id,owner_id) VALUES ('{uid(20)}','{uid(1)}');
        INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
        SELECT '{uid(24)}',catalog_id,revision,'2026-10-25','2026-10-24','2026-10-25' FROM catalog_stream_tracking WHERE catalog_id='{uid(20)}';
        INSERT INTO catalog_stream_observations SELECT '{uid(24)}','{uid(20)}',isrc,date,streams,provider_recording_id,source_hash,retrieved_at
        FROM catalog_stream_observations WHERE catalog_id='{uid(2)}';
        """)
        bundle=json.loads(self.bundle); bundle['catalogId']=uid(20)
        for row in bundle['observations']:
            row['catalog_id']=uid(20); row['run_id']=uid(24)
        return bundle

    def test_writer_cross_catalog_first_create_and_replace_cas(self):
        other=self.second_catalog()
        def save(args):
            try: return self.retain(**args)
            except AssertionError as exc:
                self.assertIn('revision conflict',str(exc)); return 'conflict'
        args=[{}, {'catalog':20,'request':23,'bundle':other}]
        with ThreadPoolExecutor(max_workers=2) as pool:
            values=list(pool.map(save,args))
        self.assertEqual(values.count('conflict'),1)
        winner=next(x for x in values if isinstance(x,dict))
        target=args[1] if winner['catalogId']==uid(2) else args[0]
        self.assertEqual(self.sql('SELECT count(*) FROM context_sources').stdout.strip(),'1')
        replacement=self.retain(**target,key='replace',revision=1)
        self.assertEqual(replacement['revision'],2)
        with ThreadPoolExecutor(max_workers=2) as pool:
            values=list(pool.map(save,[dict(x,key='race',revision=2) for x in args]))
        self.assertEqual(values.count('conflict'),1)
        self.assertEqual(self.sql('SELECT count(*) FROM context_documents').stdout.strip(),'1')
        self.assertEqual(self.sql('SELECT revision FROM context_documents').stdout.strip(),'3')
        self.assertEqual(self.sql('SELECT count(*) FROM context_results').stdout.strip(),'3')

    def test_writer_real_stream_correction_requires_explicit_new_bundle(self):
        first=self.retain()
        self.sql(f"""INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
        SELECT '{uid(13)}',catalog_id,revision,'2026-10-26','2026-10-24','2026-10-24' FROM catalog_stream_tracking;
        SELECT commit_catalog_stream_track('{uid(13)}','USAAA2600001',jsonb_build_object(
        'state','complete','days',jsonb_build_array(jsonb_build_object('date','2026-10-24','streams',200)),
        'provider_recording_id','provider-a','source_hash',repeat('b',64),'retrieved_at','2026-10-26T00:00:00Z'));""")
        self.assertIsNone(self.reconcile())
        self.assertIsNone(self.retain(key='old',revision=1))
        updated=json.loads(self.bundle)
        updated['observations'][0].update(run_id=uid(13),streams=200,source_hash='b'*64,retrieved_at='2026-10-26T00:00:00+00:00')
        updated['retrievalRange']={'earliest':'2026-10-26T00:00:00+00:00','latest':'2026-10-26T00:00:00+00:00'}
        receipt=self.retain(key='corrected',revision=1,bundle=updated)
        self.assertEqual(receipt['revision'],2)
        self.assertNotEqual(receipt['sourceVersionId'],first['sourceVersionId'])
        self.assertEqual(json.loads(self.sql(f"SELECT content FROM context_source_versions WHERE id='{first['sourceVersionId']}'").stdout),json.loads(self.bundle))


    def test_writer_history_byte_budget_refuses_before_any_write(self):
        self.sql(f"""INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
        SELECT '{uid(13)}',catalog_id,revision,'2026-10-26','2026-10-24','2026-10-24' FROM catalog_stream_tracking;
        INSERT INTO catalog_stream_observations SELECT '{uid(13)}',catalog_id,isrc,date,streams,provider_recording_id,repeat('a',8388609),retrieved_at-interval '1 day' FROM catalog_stream_observations;""")
        self.assertIsNone(self.retain())
        self.assertEqual(self.sql('SELECT count(*) FROM context_sources').stdout.strip(),'0')

    def test_writer_post_insert_link_budget_rolls_back_receipt(self):
        original=self.retain()
        self.sql("""WITH extra AS (INSERT INTO context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
        SELECT owner_id,attempt_id,subject_id,topic,md5(i::text)||md5(i::text),status,evidence_kind,normalized_response,coverage
        FROM context_results CROSS JOIN generate_series(1,511) i RETURNING id,owner_id)
        INSERT INTO context_result_sources SELECT extra.owner_id,extra.id,v.id FROM extra CROSS JOIN context_source_versions v;""")
        self.assertEqual(self.reconcile(),original)
        self.assertIsNone(self.retain(key='overflow',revision=1))
        self.assertEqual(self.sql('SELECT count(*) FROM context_result_sources').stdout.strip(),'512')
        self.assertEqual(self.sql('SELECT revision FROM context_documents').stdout.strip(),'1')
        self.assertEqual(self.sql('SELECT count(*) FROM context_attempts').stdout.strip(),'1')

    def test_writer_wrong_actor_reconcile_is_redacted(self):
        self.retain()
        self.assertIsNone(self.reconcile(actor=12))
        self.assertIsNone(self.reconcile(key='absent'))
        self.setUp(); self.sql("UPDATE context_requests SET status='queued'")
        self.assertIsNone(self.retain())



if __name__ == '__main__':
    # Original tests run on their original fixture; writer tests use empty evidence.
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(Binding),
        unittest.TestSuite(Writer(name) for name in dir(Writer) if name.startswith('test_writer_'))])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
