"""Disposable proof against existing Context and Catalog migrations; never a hosted DSN."""
import json
import os
import pathlib
import sys
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
import unittest

# Canonical retained timestamp serialization; proposal reader also pins UTC.
os.environ['PGTZ'] = 'UTC'

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
import test_release_cases as harness


class Binding(harness.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('''CREATE TABLE catalogs(id uuid PRIMARY KEY,name text,updated_at timestamptz);
        CREATE TABLE account_catalogs(account uuid,catalog uuid);
        CREATE TABLE catalog_songs(song text,catalog uuid);''')
        for name in ('20260922070000_context_catalog_entry.sql',
                     '20260923080000_context_execution_records.sql',
                     '20261009193000_catalog_daily_stream_tracking.sql',
                     '20261010035000_catalog_stream_membership_locks.sql',
                     '20261010040000_catalog_stream_parent_lock_order.sql'):
            cls.sql((ROOT / 'supabase/migrations' / name).read_text())
        cls.sql((pathlib.Path(__file__).parent / 'proposal.sql').read_text())

    def setUp(self):
        self.sql((pathlib.Path(__file__).parent / 'fixture.sql').read_text())

    def call(self, actor=1, owner=1, version=9, revision=1):
        return self.sql(f"SELECT stream_binding_proposal.read_binding('{uid(actor)}','{uid(owner)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(11)}','{uid(version)}',{revision})").stdout.strip()

    def test_exact_expanded_member(self):
        value = json.loads(self.call())
        self.assertEqual(value['sourceVersionIds'], [uid(9)])
        self.assertEqual(value['subjectId'], uid(5))
        self.assertEqual(self.sql(f"SELECT output->'subjectIds' ? '{uid(5)}' FROM context_requests WHERE id='{uid(4)}'").stdout.strip(), 'f')

    def test_wrong_owner_actor_version_revision(self):
        for args in ({'owner': 12}, {'actor': 12}, {'version': 12}, {'revision': 2}):
            self.assertEqual(self.call(**args), 'null')

    def test_current_membership_and_expansion_required(self):
        for table in ('account_catalogs', 'catalog_songs', 'context_request_catalog_members'):
            self.setUp()
            self.sql(f'DELETE FROM {table}')
            self.assertEqual(self.call(), 'null')

    def test_withdrawal_clears_document_and_refuses(self):
        self.sql(f"SELECT withdraw_context_source('{uid(1)}','{uid(8)}')")
        self.assertEqual(self.call(), 'null')
        self.assertEqual(self.sql('SELECT current_result_id IS NULL FROM context_documents').stdout.strip(), 't')

    def test_removed_version_and_missing_link(self):
        self.sql('UPDATE context_source_versions SET removed_at=now()')
        self.assertEqual(self.call(), 'null')
        self.setUp()
        self.sql('DELETE FROM context_result_sources')
        self.assertEqual(self.call(), 'null')

    def test_correction_and_provider_conflict_refuse_old_binding(self):
        for provider, streams in [('provider-a', 200), ('provider-b', 100), ('provider-a', 'NULL')]:
            self.setUp()
            self.sql(f"""INSERT INTO catalog_stream_runs(id,catalog_id,revision,scheduled_day,since,until)
            SELECT '{uid(13)}',catalog_id,revision,'2026-10-26','2026-10-24','2026-10-25' FROM catalog_stream_tracking;
            INSERT INTO catalog_stream_observations SELECT '{uid(13)}',catalog_id,isrc,date,{streams},'{provider}',repeat('b',64),retrieved_at+interval '1 hour' FROM catalog_stream_observations;""")
            self.assertEqual(self.call(), 'null')

    def test_tracking_disable_is_not_withdrawal(self):
        self.sql('UPDATE catalog_stream_tracking SET enabled=false')
        self.assertNotEqual(self.call(), 'null')

    def test_exact_tuple_tamper(self):
        for column, value in [('source_hash', "'changed'"), ('streams', '0'), ('provider_recording_id', "'other'"), ('retrieved_at', "retrieved_at+interval '1 second'")]:
            self.setUp()
            self.sql(f'UPDATE catalog_stream_observations SET {column}={value}')
            self.assertEqual(self.call(), 'null')

    def test_source_and_membership_locks(self):
        statements = [
            'DELETE FROM account_catalogs',
            'DELETE FROM catalog_songs',
            f"SELECT withdraw_context_source('{uid(1)}','{uid(8)}')",
            'UPDATE catalog_stream_tracking SET enabled=false',
            'UPDATE catalog_stream_observations SET streams=999',
            'DELETE FROM context_result_sources',
            'DELETE FROM catalog_stream_runs',
            f"INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(11)}','{uid(14)}')", 
        ]
        self.sql(f"INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content,retrieved_at) SELECT '{uid(14)}',owner_id,source_id,repeat('d',64),content,retrieved_at FROM context_source_versions")
        self.hold_and_refuse(statements)

    def test_organization_revocation_lock(self):
        self.sql(f"INSERT INTO account_organization_ids(account_id,organization_id) VALUES ('{uid(12)}','{uid(1)}')")
        self.assertNotEqual(self.call(actor=12), 'null')
        self.hold_and_refuse(['DELETE FROM account_organization_ids'], actor=12)
        self.sql('DELETE FROM account_organization_ids')
        self.assertEqual(self.call(actor=12), 'null')

    def hold_and_refuse(self, statements, actor=1):
        holder = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55473', '-d', 'postgres',
            '-XAt', '-v', 'ON_ERROR_STOP=1'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        try:
            holder.stdin.write(f"BEGIN; SELECT stream_binding_proposal.read_binding('{uid(actor)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(11)}','{uid(9)}',1);\n\\echo HELD\n")
            holder.stdin.flush()
            while True:
                line = holder.stdout.readline()
                if not line:
                    self.fail('Lock holder exited: ' + holder.stderr.read())
                if line.strip() == 'HELD':
                    break
            for statement in statements:
                with self.assertRaisesRegex(AssertionError, 'statement timeout'):
                    self.sql("SET statement_timeout='200ms'; " + statement)
        finally:
            holder.communicate('ROLLBACK;\n', timeout=10)
            self.assertEqual(holder.returncode, 0)

    def test_current_result_and_extra_lineage_refused(self):
        self.sql('UPDATE context_documents SET revision=revision+1')
        self.assertEqual(self.call(), 'null')
        self.setUp()
        self.sql(f"INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content,retrieved_at) SELECT '{uid(14)}',owner_id,source_id,repeat('d',64),content,retrieved_at FROM context_source_versions; INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(11)}','{uid(14)}')")
        self.assertEqual(self.call(), 'null')

    def test_corrected_version_is_explicit_and_old_selection_stays_stale(self):
        self.sql(f"""UPDATE catalog_stream_observations SET streams=200,source_hash=repeat('b',64);
        INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content,retrieved_at)
        SELECT '{uid(14)}',owner_id,source_id,repeat('e',64),jsonb_set(content,'{{observations}}',
        (SELECT jsonb_agg(to_jsonb(o) ORDER BY date) FROM catalog_stream_observations o)),retrieved_at FROM context_source_versions;
        INSERT INTO context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
        SELECT '{uid(15)}',r.owner_id,r.attempt_id,r.subject_id,r.topic,repeat('f',64),r.status,r.evidence_kind,v.content,r.coverage
        FROM context_results r CROSS JOIN context_source_versions v WHERE v.id='{uid(14)}';
        INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(15)}','{uid(14)}');
        SELECT accept_context_result('{uid(1)}',id,'{uid(15)}',1) FROM context_documents;""")
        self.assertEqual(self.call(), 'null')
        value = json.loads(self.sql(f"SELECT stream_binding_proposal.read_binding('{uid(1)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(15)}','{uid(14)}',2)").stdout)
        self.assertEqual(value['evidence']['observations'][0]['streams'], 200)

    def test_link_insert_before_reader_lock_is_rechecked(self):
        self.sql(f"INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content,retrieved_at) SELECT '{uid(14)}',owner_id,source_id,repeat('d',64),content,retrieved_at FROM context_source_versions")
        holder = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55473', '-d', 'postgres',
            '-XAt', '-v', 'ON_ERROR_STOP=1'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        try:
            holder.stdin.write(f"BEGIN; INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(11)}','{uid(14)}');\n\\echo HELD\n")
            holder.stdin.flush()
            while holder.stdout.readline().strip() != 'HELD':
                if holder.poll() is not None:
                    self.fail('Link insertion holder exited')
            with ThreadPoolExecutor(max_workers=1) as pool:
                result = pool.submit(self.call)
                deadline = time.monotonic() + 5
                saw_wait = False
                while time.monotonic() < deadline:
                    waits = self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%read_binding%'").stdout.strip()
                    if int(waits):
                        saw_wait = True
                        break
                    time.sleep(0.02)
                holder.communicate('COMMIT;\n', timeout=10)
                self.assertTrue(saw_wait, 'Reader never reached the conflicting result lock')
                self.assertEqual(result.result(timeout=10), 'null')
        finally:
            if holder.poll() is None:
                holder.communicate('ROLLBACK;\n', timeout=10)

    def test_repeatable_read_refused(self):
        value = self.sql(f"BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT stream_binding_proposal.read_binding('{uid(1)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(11)}','{uid(9)}',1); ROLLBACK").stdout
        self.assertIn('null', value.splitlines())

    def test_active_replacement_cannot_bypass_withdrawn_scope(self):
        self.sql(f"INSERT INTO context_sources(id,owner_id,source_url,kind,withdrawn_at) SELECT '{uid(14)}',owner_id,source_url,kind,now() FROM context_sources")
        self.assertEqual(self.call(), 'null')

    def refresh_fixture_bundle(self, since='2026-10-23', until='2026-10-25', version=9, result=11):
        # Synthetic persistence fixture only; no production writer is exercised.
        self.sql(f"""WITH rows AS (
          SELECT o.* FROM catalog_stream_observations o JOIN context_source_versions v
          ON o.catalog_id=(v.content->>'catalogId')::uuid AND o.isrc=v.content->>'isrc'
          WHERE v.id='{uid(version)}' AND date>='{since}' AND date<'{until}'
        ), aggregate AS (SELECT jsonb_agg(to_jsonb(rows) ORDER BY date) AS observations,
          min(retrieved_at) AS earliest,max(retrieved_at) AS latest FROM rows)
        UPDATE context_source_versions v SET content=content || jsonb_build_object(
          'since','{since}','until','{until}','observations',a.observations,
          'providerRecordingId',(SELECT provider_recording_id FROM rows ORDER BY date LIMIT 1),
          'periods',jsonb_build_object('previous',jsonb_build_object('start','{since}',
          'end_exclusive','{since}'::date+('{until}'::date-'{since}'::date)/2),
          'current',jsonb_build_object('start','{since}'::date+('{until}'::date-'{since}'::date)/2,
          'end_exclusive','{until}'),'days',('{until}'::date-'{since}'::date)/2,'timezone','UTC'),
          'absentDates',(SELECT coalesce(jsonb_agg(d::date::text ORDER BY d),'[]'::jsonb)
          FROM generate_series('{since}'::timestamp,'{until}'::timestamp-interval '1 day',interval '1 day') d
          WHERE NOT EXISTS(SELECT 1 FROM rows WHERE date=d::date)),
          'nullDates',(SELECT coalesce(jsonb_agg(date::text ORDER BY date),'[]'::jsonb) FROM rows WHERE streams IS NULL),
          'retrievalRange',jsonb_build_object('earliest',a.earliest,'latest',a.latest)), retrieved_at=a.latest
        FROM aggregate a WHERE v.id='{uid(version)}';
        UPDATE context_results r SET normalized_response=v.content FROM context_source_versions v
        WHERE r.id='{uid(result)}' AND v.id='{uid(version)}';""")

    def new_fixture_result(self):
        self.sql(f"""INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content,retrieved_at)
        SELECT '{uid(14)}',owner_id,source_id,repeat('e',64),content,retrieved_at FROM context_source_versions WHERE id='{uid(9)}';
        INSERT INTO context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
        SELECT '{uid(15)}',owner_id,attempt_id,subject_id,topic,repeat('f',64),status,evidence_kind,normalized_response,coverage
        FROM context_results WHERE id='{uid(11)}';
        INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(15)}','{uid(14)}');""")

    def read_new(self):
        return self.sql(f"SELECT stream_binding_proposal.read_binding('{uid(1)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(15)}','{uid(14)}',2)").stdout.strip()

    def test_multi_run_732_dates_and_over_limit(self):
        self.sql(f"""DELETE FROM catalog_stream_observations; DELETE FROM catalog_stream_runs;
        INSERT INTO catalog_stream_runs(catalog_id,revision,scheduled_day,since,until)
        SELECT catalog_id,revision,'2024-01-01'::date+i*62,'2024-01-01'::date+i*62,
        least('2024-01-01'::date+i*62+61,'2024-01-01'::date+731)
        FROM catalog_stream_tracking CROSS JOIN generate_series(0,11) i;
        INSERT INTO catalog_stream_observations
        SELECT r.id,r.catalog_id,'USAAA2600001',d::date,1,'provider-a',repeat('a',64),'2026-10-25T00:00:00Z'
        FROM catalog_stream_runs r CROSS JOIN LATERAL generate_series(r.since::timestamp,r.until::timestamp,interval '1 day') d;""")
        self.refresh_fixture_bundle('2024-01-01','2026-01-02')
        value = json.loads(self.call())
        self.assertEqual(len(value['evidence']['observations']), 732)
        self.assertEqual(value['evidence']['periods']['days'], 366)
        self.assertEqual(len({r['run_id'] for r in value['evidence']['observations']}), 12)
        self.assertEqual(len(value['sourceVersionIds']), 1)
        self.refresh_fixture_bundle('2024-01-01','2026-01-04')
        self.assertEqual(self.call(), 'null')

    def test_window_replacement_stales_original_selection(self):
        self.new_fixture_result()
        self.refresh_fixture_bundle('2026-10-21','2026-10-25',14,15)
        self.sql(f"SELECT accept_context_result('{uid(1)}',id,'{uid(15)}',1) FROM context_documents")
        self.assertEqual(self.call(), 'null')
        self.assertNotEqual(self.read_new(), 'null')
        self.assertEqual(self.sql('SELECT count(*) FROM context_documents').stdout.strip(), '1')

    def test_all_dates_provider_switch_requires_disposition(self):
        self.new_fixture_result()
        self.sql("UPDATE catalog_stream_observations SET provider_recording_id='provider-b'")
        self.refresh_fixture_bundle(version=14,result=15)
        self.sql(f"SELECT accept_context_result('{uid(1)}',id,'{uid(15)}',1) FROM context_documents")
        self.assertEqual(self.read_new(), 'null')

    def test_null_zero_missing_and_mixed_provider_rows(self):
        for count in ['NULL', '0']:
            self.setUp()
            self.sql(f'UPDATE catalog_stream_observations SET streams={count}')
            self.refresh_fixture_bundle()
            value = json.loads(self.call())['evidence']
            self.assertEqual(value['absentDates'], ['2026-10-23'])
            self.assertEqual(value['nullDates'], ['2026-10-24'] if count=='NULL' else [])
            self.assertEqual(value['observations'][0]['streams'], None if count=='NULL' else 0)
        self.sql("UPDATE catalog_stream_runs SET since='2026-10-23'; INSERT INTO catalog_stream_observations SELECT run_id,catalog_id,isrc,'2026-10-23',NULL,'provider-b',source_hash,retrieved_at FROM catalog_stream_observations")
        self.refresh_fixture_bundle()
        self.assertEqual(self.call(), 'null')

    def test_forged_run_range_and_malformed_retained_fields(self):
        for sql in ["UPDATE catalog_stream_runs SET since='2026-10-25'",
                    "UPDATE catalog_stream_observations SET source_hash='not-a-hash'",
                    "UPDATE catalog_stream_observations SET provider_recording_id=' '",
                    "UPDATE catalog_stream_observations SET provider_recording_id=chr(9)||chr(10)",
                    "UPDATE catalog_stream_observations SET retrieved_at='infinity'"]:
            self.setUp()
            self.sql(sql)
            self.refresh_fixture_bundle()
            self.assertEqual(self.call(), 'null')

    def test_utf8_and_jsonb_byte_bound_refuses_without_truncation(self):
        # Multi-byte provider text gives an otherwise structurally valid matching bundle.
        self.sql("UPDATE catalog_stream_observations SET provider_recording_id=repeat('é',140000)")
        self.refresh_fixture_bundle()
        size = int(self.sql("SELECT octet_length(convert_to(content::text,'UTF8')) FROM context_source_versions").stdout.strip())
        self.assertGreater(size, 524288)
        self.assertEqual(self.call(), 'null')

    def test_scope_shape_freshness_and_result_status(self):
        mutations = ["UPDATE context_source_versions SET retrieved_at=now()",
          "UPDATE context_source_versions SET content=jsonb_set(content,'{schemaVersion}',to_jsonb('1'::text))",
          "UPDATE context_source_versions SET content=content||jsonb_build_object('inventedGrowth',999)",
          "UPDATE context_results SET status='stale'",
          "UPDATE context_results SET evidence_kind='customer_assertion'",
          "UPDATE context_source_versions SET content=content||'{\"unexpected\":true}'::jsonb",
          "UPDATE context_source_versions SET content=jsonb_set(content,'{metric}','\"spotify_annual_royalties\"')"]
        for sql in mutations:
            self.setUp()
            self.sql(sql)
            self.sql('UPDATE context_results SET normalized_response=(SELECT content FROM context_source_versions)')
            self.assertEqual(self.call(), 'null')

    def test_cross_catalog_replacement_has_one_current_document(self):
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
        INSERT INTO context_sources(id,owner_id,source_url,kind)
        VALUES ('{uid(26)}','{uid(1)}','urn:recoup:retained-catalog-streams:{uid(20)}:{uid(5)}:all_dsps:worldwide','provider_metadata');
        INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content,retrieved_at)
        SELECT '{uid(25)}',owner_id,'{uid(26)}',repeat('e',64),jsonb_set(content,'{{catalogId}}','"{uid(20)}"'),retrieved_at
        FROM context_source_versions WHERE id='{uid(9)}';
        INSERT INTO context_attempts(id,owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version)
        SELECT '{uid(28)}',owner_id,'{uid(23)}',module,attempt,status,provider,recipe_version,schema_version FROM context_attempts;
        INSERT INTO context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
        SELECT '{uid(27)}',owner_id,'{uid(28)}',subject_id,topic,repeat('f',64),status,evidence_kind,normalized_response,coverage FROM context_results;
        INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(27)}','{uid(25)}');""")
        self.refresh_fixture_bundle(version=25,result=27)
        self.sql(f"SELECT accept_context_result('{uid(1)}',id,'{uid(27)}',1) FROM context_documents")
        self.assertEqual(self.call(), 'null')
        value = self.sql(f"SELECT stream_binding_proposal.read_binding('{uid(1)}','{uid(1)}','{uid(23)}','{uid(5)}','{uid(20)}','{uid(27)}','{uid(25)}',2)").stdout.strip()
        self.assertNotEqual(value, 'null')
        self.assertEqual(self.sql('SELECT count(*) FROM context_documents').stdout.strip(), '1')
        self.assertEqual(self.sql('SELECT topic FROM context_documents').stdout.strip(), 'catalog_retained_streams')

    def test_no_service_execute(self):
        self.assertEqual(self.sql("SELECT has_schema_privilege('service_role','stream_binding_proposal','USAGE')").stdout.strip(), 'f')


def uid(n):
    return f'10000000-0000-4000-8000-{n:012d}'


if __name__ == '__main__':
    unittest.main()
