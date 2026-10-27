"""Disposable proof against existing Context and Catalog migrations; never a hosted DSN."""
import json
import os
import pathlib
import sys
import subprocess
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
            INSERT INTO catalog_stream_observations SELECT '{uid(13)}',catalog_id,isrc,date,{streams},'{provider}','correction',retrieved_at+interval '1 hour' FROM catalog_stream_observations;""")
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
        self.sql(f"INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content) SELECT '{uid(14)}',owner_id,source_id,repeat('d',64),content FROM context_source_versions")
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
        self.sql(f"INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content) SELECT '{uid(14)}',owner_id,source_id,repeat('d',64),content FROM context_source_versions; INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(11)}','{uid(14)}')")
        self.assertEqual(self.call(), 'null')

    def test_corrected_version_is_explicit_and_old_selection_stays_stale(self):
        self.sql(f"""UPDATE catalog_stream_observations SET streams=200,source_hash='correction';
        INSERT INTO context_source_versions(id,owner_id,source_id,fingerprint,content)
        SELECT '{uid(14)}',owner_id,source_id,repeat('e',64),jsonb_set(content,'{{observations}}',
        (SELECT jsonb_agg(to_jsonb(o) ORDER BY date) FROM catalog_stream_observations o)) FROM context_source_versions;
        INSERT INTO context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
        SELECT '{uid(15)}',r.owner_id,r.attempt_id,r.subject_id,r.topic,repeat('f',64),r.status,r.evidence_kind,v.content,r.coverage
        FROM context_results r CROSS JOIN context_source_versions v WHERE v.id='{uid(14)}';
        INSERT INTO context_result_sources VALUES ('{uid(1)}','{uid(15)}','{uid(14)}');
        SELECT accept_context_result('{uid(1)}',id,'{uid(15)}',1) FROM context_documents;""")
        self.assertEqual(self.call(), 'null')
        value = json.loads(self.sql(f"SELECT stream_binding_proposal.read_binding('{uid(1)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(15)}','{uid(14)}',2)").stdout)
        self.assertEqual(value['evidence']['observations'][0]['streams'], 200)

    def test_repeatable_read_refused(self):
        value = self.sql(f"BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT stream_binding_proposal.read_binding('{uid(1)}','{uid(1)}','{uid(4)}','{uid(5)}','{uid(2)}','{uid(11)}','{uid(9)}',1); ROLLBACK").stdout
        self.assertIn('null', value.splitlines())

    def test_no_service_execute(self):
        self.assertEqual(self.sql("SELECT has_schema_privilege('service_role','stream_binding_proposal','USAGE')").stdout.strip(), 'f')


def uid(n):
    return f'10000000-0000-4000-8000-{n:012d}'


if __name__ == '__main__':
    unittest.main()
