"""Document version history on disposable PostgreSQL: legacy backfill, lifecycle, rollback."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATION = ROOT / 'supabase/migrations/20261010212100_context_document_versions.sql'
FIXTURE = ROOT / 'supabase/tests/context_document_versions.sql'

# Synthetic identifiers only; the legacy rows are written before the history migration exists.
OWNER = '0d0c0b0a-0000-4000-8000-000000000001'
RESOURCE = '0d0c0b0a-0000-4000-8000-000000000002'
SUBJECT = '0d0c0b0a-0000-4000-8000-000000000003'
REQUEST = '0d0c0b0a-0000-4000-8000-000000000004'
SOURCE = '0d0c0b0a-0000-4000-8000-000000000005'
VERSION = '0d0c0b0a-0000-4000-8000-000000000006'
ATTEMPT = '0d0c0b0a-0000-4000-8000-000000000007'
RESULT = '0d0c0b0a-0000-4000-8000-000000000008'
ACCEPTED_DOC = '0d0c0b0a-0000-4000-8000-000000000009'
EMPTY_DOC = '0d0c0b0a-0000-4000-8000-00000000000a'
CLEARED_DOC = '0d0c0b0a-0000-4000-8000-00000000000b'
URL = 'https://open.spotify.com/album/' + 'L' * 22

LEGACY = f"""
insert into public.accounts(id,name) values('{OWNER}','Legacy history owner');
insert into public.context_resources(id,provider,resource_kind,provider_id,canonical_url)
 values('{RESOURCE}','spotify','release','{'L' * 22}','{URL}');
insert into public.context_subjects(id,kind,resource_id) values('{SUBJECT}','release','{RESOURCE}');
insert into public.context_requests(id,owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values('{REQUEST}','{OWNER}','{OWNER}','{RESOURCE}','legacy-history',repeat('a',64),'{{}}','completed',
  jsonb_build_object('subjectIds',jsonb_build_array('{SUBJECT}'::uuid)));
insert into public.context_sources(id,owner_id,source_url,kind) values('{SOURCE}','{OWNER}','{URL}','provider_metadata');
insert into public.context_source_versions(id,owner_id,source_id,fingerprint,content)
 values('{VERSION}','{OWNER}','{SOURCE}',repeat('b',64),'{{}}');
insert into public.context_attempts(id,owner_id,request_id,module,attempt,status,recipe_version,schema_version)
 values('{ATTEMPT}','{OWNER}','{REQUEST}','release_metadata',1,'succeeded','1','1');
insert into public.context_results(id,owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values('{RESULT}','{OWNER}','{ATTEMPT}','{SUBJECT}','release_metadata',repeat('c',64),'accepted','observation',
  '{{"title":"Legacy release"}}','{{"extent":"partial"}}');
insert into public.context_result_sources values('{OWNER}','{RESULT}','{VERSION}');
insert into public.context_documents(id,owner_id,subject_id,topic,revision,current_result_id,updated_at) values
 ('{ACCEPTED_DOC}','{OWNER}','{SUBJECT}','release_metadata',2,'{RESULT}','2026-09-21T10:00:00Z'),
 ('{EMPTY_DOC}','{OWNER}','{SUBJECT}','artist_research',0,null,'2026-09-21T10:00:00Z'),
 ('{CLEARED_DOC}','{OWNER}','{SUBJECT}','lyrics',3,null,'2026-09-22T10:00:00Z');
"""

# The documented rollback: history objects only; documents, results and sources stay.
ROLLBACK = """
drop trigger context_documents_record_version on public.context_documents;
drop trigger context_document_versions_immutable on public.context_document_versions;
drop function public.record_context_document_version();
drop function public.reject_context_document_version_change();
drop function public.read_context_document_history(uuid,uuid,bigint,integer);
drop table public.context_document_versions;
"""


class ContextDocumentVersions(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((ROOT / 'supabase/migrations/20260926170000_context_brief_snapshots.sql').read_text())
        cls.sql(LEGACY)
        if MIGRATION.exists():
            cls.sql(MIGRATION.read_text())

    def rows(self, document):
        return self.sql(
            "select revision||':'||change||':'||backfilled||':'||coalesce(result_id::text,'none')"
            f" from public.context_document_versions where document_id='{document}' order by revision"
        ).stdout.split()

    def assert_backfilled(self):
        self.assertEqual(self.rows(ACCEPTED_DOC), [f'2:accepted:true:{RESULT}'])
        self.assertEqual(self.rows(EMPTY_DOC), [])
        self.assertEqual(self.rows(CLEARED_DOC), ['3:cleared:true:none'])
        self.assertEqual(self.sql(
            "select count(*) from public.context_document_versions v join public.context_documents d on d.id=v.document_id"
            f" where d.owner_id='{OWNER}' and v.recorded_at<>d.updated_at").stdout.strip(), '0')

    def test_legacy_documents_backfill_without_rewriting_readers(self):
        self.assert_backfilled()
        current = self.sql(
            f"select jsonb_array_length(d), d->0->>'id', d->0->>'version', d->0->>'resultId'"
            f" from public.read_context_documents('{OWNER}','{REQUEST}') d").stdout.split('|')
        self.assertEqual([x.strip() for x in current], ['1', ACCEPTED_DOC, '2', RESULT])
        history = self.sql(
            f"select h->'versions'->0->>'backfilled', h->'versions'->0->>'result_status', h->'versions'->0->>'source_state',"
            f" h->'document'->>'current_revision' from public.read_context_document_history('{OWNER}','{ACCEPTED_DOC}') h"
        ).stdout.split('|')
        self.assertEqual([x.strip() for x in history], ['true', 'accepted', 'live', '2'])
        self.assertEqual(self.sql(
            f"select public.read_context_document_history('{RESULT}','{ACCEPTED_DOC}') is null").stdout.strip(), 't')

    def test_lifecycle_immutability_and_access(self):
        result = self.sql(FIXTURE.read_text())
        self.assertIn('PASS:', result.stderr)

    def test_rollback_keeps_customer_data_and_reapply_backfills(self):
        self.sql(ROLLBACK)
        self.assertEqual(self.sql("select to_regclass('public.context_document_versions') is null").stdout.strip(), 't')
        self.assertEqual(self.sql(
            f"select count(*) from public.context_documents where owner_id='{OWNER}'").stdout.strip(), '3')
        self.assertEqual(self.sql(
            f"select current_result_id::text||':'||revision from public.context_documents where id='{ACCEPTED_DOC}'"
        ).stdout.strip(), f'{RESULT}:2')
        self.assertEqual(self.sql(
            f"select count(*) from public.context_result_sources where result_id='{RESULT}'").stdout.strip(), '1')
        self.sql(MIGRATION.read_text())
        self.assert_backfilled()
