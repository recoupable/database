"""Scoped source withdrawal through recorded input relationships; disposable PG only."""
import subprocess
import time

import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATION = ROOT / 'supabase/migrations/20261010212400_context_source_withdrawal.sql'
FUNCTION = 'public.withdraw_context_request_source(uuid,uuid,uuid,uuid,uuid)'
TRIGGER_FUNCTION = 'public.keep_context_source_withdrawn()'
PUBLIC_B = 'https://example.test/public-b'

# One workspace (owner) with a member and an outsider. Request q1 has two accepted
# documents from two sources (A private, B public) and two saved briefs that depend
# on exactly one of them each. Request q2 holds unrelated accepted evidence (source C).
DECLARE = '''
 owner uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 res1 uuid; res2 uuid; s1 uuid; s2 uuid; q1 uuid; q2 uuid;
 src_a uuid; src_b uuid; src_c uuid; foreign_src uuid; ver_a uuid; ver_b uuid; ver_c uuid;
 att_a uuid; att_b uuid; att_c uuid; att_d uuid; res_a uuid; res_b uuid; res_c uuid; res_d uuid; late uuid;
 doc_a uuid; doc_b uuid; doc_c uuid; doc_d uuid; evidence jsonb; brief_a jsonb; brief_b jsonb;
 receipt jsonb; replay jsonb; shifted timestamptz; late_b uuid; other_src uuid;
'''

SEED = '''
 insert into public.accounts(id,name) values(owner,'Withdrawal owner'),(member,'Withdrawal member'),(outsider,'Withdrawal outsider');
 insert into public.account_organization_ids(account_id,organization_id) values(member,owner);
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('spotify','release','WITHDRAWAL1AAAAAAAAAAA','https://open.spotify.com/album/WITHDRAWAL1AAAAAAAAAAA') returning id into res1;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('spotify','release','WITHDRAWAL2AAAAAAAAAAA','https://open.spotify.com/album/WITHDRAWAL2AAAAAAAAAAA') returning id into res2;
 insert into public.context_subjects(kind,resource_id) values('release',res1) returning id into s1;
 insert into public.context_subjects(kind,resource_id) values('release',res2) returning id into s2;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(owner,member,res1,'withdrawal-q1',repeat('a',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(s1))) returning id into q1;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
  values(owner,member,res2,'withdrawal-q2',repeat('b',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(s2))) returning id into q2;
 insert into public.context_sources(owner_id,source_url,kind) values(owner,'https://example.test/private-a','customer') returning id into src_a;
 insert into public.context_sources(owner_id,source_url,kind) values(owner,'https://example.test/public-b','provider_metadata') returning id into src_b;
 insert into public.context_sources(owner_id,source_url,kind) values(owner,'https://example.test/public-c','provider_metadata') returning id into src_c;
 insert into public.context_sources(owner_id,source_url,kind) values(outsider,'https://example.test/foreign','web') returning id into foreign_src;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content) values(owner,src_a,repeat('1',64),'{}') returning id into ver_a;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content) values(owner,src_b,repeat('2',64),'{}') returning id into ver_b;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content) values(owner,src_c,repeat('3',64),'{}') returning id into ver_c;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
  values(owner,q1,'song_summary',1,'succeeded','1','1') returning id into att_a;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
  values(owner,q1,'lyrics',1,'succeeded','1','1') returning id into att_b;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
  values(owner,q2,'song_summary',1,'succeeded','1','1') returning id into att_c;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_a,s1,'song_summary',repeat('4',64),'accepted','customer_assertion','{"summary":"Private note"}','{"extent":"full"}') returning id into res_a;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_b,s1,'lyrics',repeat('5',64),'accepted','observation','{"lyrics":"Public lyrics"}','{"extent":"full"}') returning id into res_b;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_c,s2,'song_summary',repeat('6',64),'accepted','observation','{"summary":"Unrelated"}','{"extent":"full"}') returning id into res_c;
 insert into public.context_result_sources values(owner,res_a,ver_a),(owner,res_b,ver_b),(owner,res_c,ver_c);
 insert into public.context_documents(owner_id,subject_id,topic,revision,current_result_id) values(owner,s1,'song_summary',1,res_a) returning id into doc_a;
 insert into public.context_documents(owner_id,subject_id,topic,revision,current_result_id) values(owner,s1,'lyrics',1,res_b) returning id into doc_b;
 insert into public.context_documents(owner_id,subject_id,topic,revision,current_result_id) values(owner,s2,'song_summary',1,res_c) returning id into doc_c;
 evidence:=public.read_context_documents(owner,q1);
 brief_a:=public.save_context_brief(owner,'withdrawal-brief-a',jsonb_build_object('request_id',q1,'request_ids',jsonb_build_array(q1),
  'purpose','creative_direction','text','Brief depending on the private source',
  'documents',(select jsonb_agg(d) from jsonb_array_elements(evidence) d where d->>'id'=doc_a::text),
  'input_manifest',jsonb_build_object('compilerVersion','context-brief-v1','method','saved_evidence_selection','requestIds',jsonb_build_array(q1),
   'documents',jsonb_build_array(jsonb_build_object('documentId',doc_a,'resultId',res_a,'subjectId',s1,'topic','song_summary','version',1,'sourceVersionIds',jsonb_build_array(ver_a))))));
 brief_b:=public.save_context_brief(owner,'withdrawal-brief-b',jsonb_build_object('request_id',q1,'request_ids',jsonb_build_array(q1),
  'purpose','playlist_pitch','text','Brief depending on the public source only',
  'documents',(select jsonb_agg(d) from jsonb_array_elements(evidence) d where d->>'id'=doc_b::text),
  'input_manifest',jsonb_build_object('compilerVersion','context-brief-v1','method','saved_evidence_selection','requestIds',jsonb_build_array(q1),
   'documents',jsonb_build_array(jsonb_build_object('documentId',doc_b,'resultId',res_b,'subjectId',s1,'topic','lyrics','version',1,'sourceVersionIds',jsonb_build_array(ver_b))))));
 if brief_a->>'state' is distinct from 'saved' or brief_b->>'state' is distinct from 'saved' then raise exception 'seed briefs were not saved'; end if;
'''


def receipt_shape(name):
    """Every documented receipt key is present with its JSON type; missing keys fail."""
    return f"""
 if (select array_agg(k order by k) from jsonb_object_keys({name}) k)
   is distinct from array['affected','already_withdrawn','contract_version','request_id','source_id','withdrawn_at']
  or (select array_agg(k order by k) from jsonb_object_keys({name}->'affected') k)
   is distinct from array['documents','request_ids','results']
  or {name}->'contract_version' is distinct from to_jsonb('context-source-withdrawal-v1'::text)
  or jsonb_typeof({name}->'request_id') is distinct from 'string' or jsonb_typeof({name}->'source_id') is distinct from 'string'
  or jsonb_typeof({name}->'withdrawn_at') is distinct from 'string' or jsonb_typeof({name}->'already_withdrawn') is distinct from 'boolean'
  or jsonb_typeof({name}->'affected'->'results') is distinct from 'number'
  or jsonb_typeof({name}->'affected'->'documents') is distinct from 'number'
  or jsonb_typeof({name}->'affected'->'request_ids') is distinct from 'array'
 then raise exception 'receipt shape wrong: %',{name}; end if;"""


class SourceWithdrawal(release_cases.ReleaseCases):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((ROOT / 'supabase/migrations/20260926170000_context_brief_snapshots.sql').read_text())
        if MIGRATION.exists():
            cls.sql(MIGRATION.read_text())

    def case(self, body):
        """Seed, assert, and always roll back; failures raise inside the block."""
        self.sql('begin;\ndo $$\ndeclare' + DECLARE + 'begin' + SEED + body + '\nend $$;\nrollback;')

    def test_member_withdrawal_suppresses_only_dependent_evidence(self):
        self.case('''
 insert into public.context_documents(owner_id,subject_id,topic) values(owner,s2,'artwork');
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);''' + receipt_shape('receipt') + '''
 if receipt->'request_id' is distinct from to_jsonb(q1) or receipt->'source_id' is distinct from to_jsonb(src_a)
  or receipt->'already_withdrawn' is distinct from 'false'::jsonb
  or (receipt->>'withdrawn_at')::timestamptz is distinct from (select withdrawn_at from public.context_sources where id=src_a)
 then raise exception 'receipt malformed: %',receipt; end if;
 if receipt->'affected' is distinct from jsonb_build_object('results',1,'documents',1,'request_ids',jsonb_build_array(q1))
 then raise exception 'affected set wrong: %',receipt; end if;
 if (select withdrawn_at from public.context_sources where id=src_a) is null then raise exception 'source A not withdrawn'; end if;
 if (select status from public.context_results where id=res_a) is distinct from 'withdrawn' then raise exception 'result A not withdrawn'; end if;
 if (select current_result_id from public.context_documents where id=doc_a) is not null
  or (select revision from public.context_documents where id=doc_a) is distinct from 2 then raise exception 'document A not suppressed'; end if;
 if (select status from public.context_results where id=res_b) is distinct from 'accepted' or (select withdrawn_at from public.context_sources where id=src_b) is not null
  or (select current_result_id from public.context_documents where id=doc_b) is distinct from res_b
  or (select revision from public.context_documents where id=doc_b) is distinct from 1
 then raise exception 'unrelated document B changed'; end if;
 if (select status from public.context_results where id=res_c) is distinct from 'accepted' or (select withdrawn_at from public.context_sources where id=src_c) is not null
  or (select current_result_id from public.context_documents where id=doc_c) is distinct from res_c
  or (select revision from public.context_documents where id=doc_c) is distinct from 1
 then raise exception 'unrelated request changed'; end if;
 if (select status from public.context_requests where id=q1) is distinct from 'completed' then raise exception 'request status changed'; end if;
 if exists(select 1 from jsonb_array_elements(public.read_context_documents(owner,q1)) d where d->>'id'=doc_a::text)
  then raise exception 'withdrawn document still readable'; end if;
 if not exists(select 1 from jsonb_array_elements(public.read_context_documents(owner,q1)) d where d->>'id'=doc_b::text)
  then raise exception 'unrelated document lost'; end if;
 if (select count(*) from public.context_results) is distinct from 3::bigint or (select count(*) from public.context_source_versions) is distinct from 3::bigint
  then raise exception 'history was deleted'; end if;''')

    def test_source_version_id_resolves_to_its_source(self):
        self.case('''
 begin
  perform public.withdraw_context_request_source(member,owner,q1,src_a,ver_a);
  raise exception 'TEST_FAILURE: both identifiers accepted';
 exception when invalid_parameter_value then null; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,null,null);
  raise exception 'TEST_FAILURE: missing identifier accepted';
 exception when invalid_parameter_value then null; end;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content) values(outsider,foreign_src,repeat('9',64),'{}') returning id into late;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,null,late);
  raise exception 'TEST_FAILURE: foreign workspace version accepted';
 exception when raise_exception then if sqlerrm is distinct from 'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,null,ver_c);
  raise exception 'TEST_FAILURE: version outside the request lineage accepted';
 exception when raise_exception then if sqlerrm is distinct from 'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,null,gen_random_uuid());
  raise exception 'TEST_FAILURE: unknown version accepted';
 exception when raise_exception then if sqlerrm is distinct from 'Source is not an input of this request' then raise; end if; end;
 if exists(select 1 from public.context_sources where withdrawn_at is not null) then raise exception 'rejected version changed data'; end if;
 receipt:=public.withdraw_context_request_source(member,owner,q1,null,ver_a);''' + receipt_shape('receipt') + '''
 if receipt->'source_id' is distinct from to_jsonb(src_a)
  or receipt->'affected' is distinct from jsonb_build_object('results',1,'documents',1,'request_ids',jsonb_build_array(q1))
 then raise exception 'version did not resolve to its source: %',receipt; end if;
 if (select withdrawn_at from public.context_sources where id=src_a) is null
  or (select current_result_id from public.context_documents where id=doc_a) is not null then raise exception 'source A not withdrawn by version'; end if;''')

    def test_replay_returns_the_same_receipt_without_touching_timestamps(self):
        self.case('''
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);
 update public.context_sources set withdrawn_at=withdrawn_at-interval '1 hour' where id=src_a returning withdrawn_at into shifted;
 replay:=public.withdraw_context_request_source(member,owner,q1,src_a);''' + receipt_shape('replay') + '''
 if replay->'already_withdrawn' is distinct from 'true'::jsonb or (replay->>'withdrawn_at')::timestamptz is distinct from shifted
  then raise exception 'replay reset withdrawal: %',replay; end if;
 if replay-'already_withdrawn'-'withdrawn_at' is distinct from receipt-'already_withdrawn'-'withdrawn_at'
  then raise exception 'replay changed receipt: % vs %',receipt,replay; end if;
 if (select revision from public.context_documents where id=doc_a) is distinct from 2 then raise exception 'replay bumped revision'; end if;
 if (select withdrawn_at from public.context_sources where id=src_a) is distinct from shifted then raise exception 'replay touched withdrawn_at'; end if;''')

    def test_affected_documents_follow_recorded_lineage_and_stay_stable(self):
        self.case('''
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_b,s1,'lyrics',repeat('9',64),'stale','observation','{"lyrics":"Older"}','{"extent":"full"}') returning id into late;
 insert into public.context_result_sources values(owner,late,ver_a);
 insert into public.context_documents(owner_id,subject_id,topic) values(owner,s2,'artwork');
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);
 if receipt->'affected' is distinct from jsonb_build_object('results',2,'documents',2,'request_ids',jsonb_build_array(q1))
  then raise exception 'lineage counts wrong: %',receipt; end if;
 if (select current_result_id from public.context_documents where id=doc_b) is distinct from res_b
  or (select revision from public.context_documents where id=doc_b) is distinct from 1 then raise exception 'live document B changed'; end if;
 if (select status from public.context_results where id=late) is distinct from 'withdrawn' then raise exception 'older result not relabelled'; end if;
 perform public.withdraw_context_request_source(member,owner,q1,src_b);
 replay:=public.withdraw_context_request_source(member,owner,q1,src_a);
 if replay->'affected' is distinct from receipt->'affected' then raise exception 'replay counts drifted: % vs %',receipt,replay; end if;''')

    def test_old_job_cannot_republish_a_withdrawn_source(self):
        self.case('''
 perform public.withdraw_context_request_source(member,owner,q1,src_a);
 if public.accept_context_result(owner,doc_a,res_a,2) then raise exception 'withdrawn result resurrected'; end if;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_a,s1,'song_summary',repeat('7',64),'accepted','customer_assertion','{"summary":"Late job"}','{"extent":"full"}') returning id into late;
 insert into public.context_result_sources values(owner,late,ver_a);
 if public.accept_context_result(owner,doc_a,late,2) then raise exception 'late job republished withdrawn source'; end if;
 if (select current_result_id from public.context_documents where id=doc_a) is not null then raise exception 'document republished'; end if;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_b,s1,'lyrics',repeat('8',64),'accepted','observation','{"lyrics":"Newer"}','{"extent":"full"}') returning id into late_b;
 insert into public.context_result_sources values(owner,late_b,ver_b);
 if public.accept_context_result(owner,doc_b,late_b,0) then raise exception 'stale revision accepted on a live source'; end if;
 if not public.accept_context_result(owner,doc_b,late_b,1) then raise exception 'current revision refused on a live source'; end if;''')

    def test_late_writer_cannot_recreate_a_withdrawn_source(self):
        self.case(f'''
 perform public.withdraw_context_request_source(member,owner,q1,src_b);
 begin
  perform public.save_context_metadata(owner,q1,s1,'lyrics','{PUBLIC_B}','{{"lyrics":"Captured before withdrawal"}}'::jsonb,now()-interval '1 hour');
  raise exception 'TEST_FAILURE: late writer committed';
 exception when raise_exception then if sqlerrm is distinct from 'Context acceptance conflict' then raise; end if; end;
 if (select current_result_id from public.context_documents where id=doc_b) is not null then raise exception 'late writer republished'; end if;
 if exists(select 1 from jsonb_array_elements(public.read_context_documents(owner,q1)) d where d->>'id'=doc_b::text)
  then raise exception 'withdrawn evidence readable again'; end if;
 insert into public.context_sources(owner_id,source_url,kind) values(owner,'{PUBLIC_B}','provider_metadata')
  on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
  do update set source_url=excluded.source_url returning id into late;
 if late=src_b or (select withdrawn_at from public.context_sources where id=late) is null then raise exception 'writer upsert re-created an active source'; end if;
 if exists(select 1 from public.context_sources where owner_id=owner and kind='provider_metadata' and source_url='{PUBLIC_B}' and withdrawn_at is null)
  then raise exception 'withdrawn URL active again'; end if;
 insert into public.context_sources(owner_id,source_url,kind) values(owner,'{PUBLIC_B}','web') returning id into other_src;
 if (select withdrawn_at from public.context_sources where id=other_src) is not null then raise exception 'another source kind was withdrawn'; end if;
 insert into public.context_sources(owner_id,source_url,kind) values(outsider,'{PUBLIC_B}','provider_metadata') returning id into other_src;
 if (select withdrawn_at from public.context_sources where id=other_src) is not null then raise exception 'another workspace was withdrawn'; end if;
 if (select current_result_id from public.context_documents where id=doc_a) is distinct from res_a
  or (select current_result_id from public.context_documents where id=doc_c) is distinct from res_c then raise exception 'unrelated evidence changed'; end if;''')

    def test_in_flight_writer_waits_for_a_concurrent_withdrawal(self):
        """A writer blocked behind an uncommitted withdrawal cannot republish once it commits."""
        db = 'withdrawal_race'
        self.sql(f'create database {db} template postgres;')
        self.addCleanup(self.sql, f'drop database if exists {db} with (force);')
        ids = ('owner', 'member', 'q1', 's1', 'src_b', 'doc_b')
        self.psql(db, 'create table public.race_ids(name text primary key,id uuid not null);\n'
                  'grant select on public.race_ids to service_role;\n'
                  'do $$\ndeclare' + DECLARE + 'begin' + SEED + '\n insert into public.race_ids values '
                  + ','.join(f"('{name}',{name})" for name in ids) + ';\nend $$;')
        ref = {name: f"(select id from public.race_ids where name='{name}')" for name in ids}
        withdrawal = self.session(db)
        withdrawal.stdin.write('begin;\nselect public.withdraw_context_request_source('
                               f"{ref['member']},{ref['owner']},{ref['q1']},{ref['src_b']});\n")
        withdrawal.stdin.flush()
        self.wait_until(db, "state='idle in transaction'")
        writer = self.session(db)
        writer.stdin.write('set role service_role;\nselect public.save_context_metadata('
                           f"{ref['owner']},{ref['q1']},{ref['s1']},'lyrics','{PUBLIC_B}',"
                           '\'{"lyrics":"In flight"}\'::jsonb,now()-interval \'1 minute\');\n')
        writer.stdin.flush()
        self.wait_until(db, "wait_event_type='Lock'")
        _, err = withdrawal.communicate('commit;\n', timeout=30)
        self.assertEqual(withdrawal.returncode, 0, err)
        _, err = writer.communicate(timeout=30)
        self.assertNotEqual(writer.returncode, 0, 'in-flight writer republished the withdrawn source')
        self.assertIn('Context acceptance conflict', err)
        self.psql(db, f"""do $$ begin
 if (select current_result_id from public.context_documents where id={ref['doc_b']}) is not null
  then raise exception 'in-flight writer republished'; end if;
 if exists(select 1 from public.context_sources where owner_id={ref['owner']} and kind='provider_metadata'
   and source_url='{PUBLIC_B}' and withdrawn_at is null) then raise exception 'withdrawn URL active again'; end if;
end $$;""")

    def session(self, db):
        process = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55473', '-d', db, '-XAt', '-v', 'ON_ERROR_STOP=1'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def psql(self, db, sql):
        result = subprocess.run(['psql', '-h', self.tmp.name, '-p', '55473', '-d', db, '-XAt', '-v', 'ON_ERROR_STOP=1'],
                                input=sql, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout

    def wait_until(self, db, condition):
        deadline = time.monotonic() + 30
        while self.psql('postgres', f"select count(*) from pg_stat_activity where datname='{db}' and {condition};").strip() == '0':
            if time.monotonic() > deadline:
                self.fail(f'timed out waiting for {condition}')
            time.sleep(0.05)

    def test_saved_briefs_depending_on_the_source_become_unavailable(self):
        self.case('''
 perform public.withdraw_context_request_source(member,owner,q1,src_a);
 replay:=public.read_context_brief(owner,(brief_a->>'id')::uuid);
 if replay->>'state' is distinct from 'unavailable' or replay->'brief' is distinct from 'null'::jsonb then raise exception 'brief on withdrawn source still readable: %',replay; end if;
 replay:=public.read_context_brief(owner,(brief_b->>'id')::uuid);
 if replay->>'state' is distinct from 'saved' or replay->'brief' is null or replay->'brief'='null'::jsonb then raise exception 'unrelated brief lost: %',replay; end if;''')

    def test_withdrawal_reports_every_request_sharing_the_source(self):
        self.case('''
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
  values(owner,q2,'lyrics',1,'succeeded','1','1') returning id into att_d;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_d,s2,'lyrics',repeat('8',64),'accepted','customer_assertion','{"lyrics":"Shared private note"}','{"extent":"full"}') returning id into res_d;
 insert into public.context_result_sources values(owner,res_d,ver_a);
 insert into public.context_documents(owner_id,subject_id,topic,revision,current_result_id) values(owner,s2,'lyrics',1,res_d) returning id into doc_d;
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);
 if receipt->'affected'->'results' is distinct from '2'::jsonb or receipt->'affected'->'documents' is distinct from '2'::jsonb
  or jsonb_typeof(receipt->'affected'->'request_ids') is distinct from 'array'
  or jsonb_array_length(receipt->'affected'->'request_ids') is distinct from 2
  or not (receipt->'affected'->'request_ids' ? q1::text) or not (receipt->'affected'->'request_ids' ? q2::text)
 then raise exception 'shared lineage not reported: %',receipt; end if;
 if (select status from public.context_results where id=res_d) is distinct from 'withdrawn'
  or (select current_result_id from public.context_documents where id=doc_d) is not null then raise exception 'dependent read in q2 not suppressed'; end if;
 if (select current_result_id from public.context_documents where id=doc_c) is distinct from res_c then raise exception 'unrelated q2 document changed'; end if;''')

    def test_foreign_and_revoked_actors_are_denied(self):
        self.case('''
 begin
  perform public.withdraw_context_request_source(outsider,owner,q1,src_a);
  raise exception 'TEST_FAILURE: outsider withdrew';
 exception when insufficient_privilege then null; end;
 delete from public.account_organization_ids where account_id=member and organization_id=owner;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,src_a);
  raise exception 'TEST_FAILURE: revoked member withdrew';
 exception when insufficient_privilege then null; end;
 if (select withdrawn_at from public.context_sources where id=src_a) is not null
  or (select status from public.context_results where id=res_a) is distinct from 'accepted'
  or (select current_result_id from public.context_documents where id=doc_a) is distinct from res_a then raise exception 'denied actor changed data'; end if;
 receipt:=public.withdraw_context_request_source(owner,owner,q1,src_a);
 if receipt->'already_withdrawn' is distinct from 'false'::jsonb then raise exception 'workspace owner could not withdraw'; end if;''')

    def test_sources_outside_the_request_lineage_are_rejected(self):
        self.case('''
 begin
  perform public.withdraw_context_request_source(member,owner,q1,src_c);
  raise exception 'TEST_FAILURE: unlinked source withdrawn';
 exception when raise_exception then if sqlerrm is distinct from 'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q2,src_a);
  raise exception 'TEST_FAILURE: source withdrawn through an unrelated request';
 exception when raise_exception then if sqlerrm is distinct from 'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,foreign_src);
  raise exception 'TEST_FAILURE: foreign workspace source withdrawn';
 exception when raise_exception then if sqlerrm is distinct from 'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,gen_random_uuid(),src_a);
  raise exception 'TEST_FAILURE: unknown request accepted';
 exception when raise_exception then if sqlerrm is distinct from 'Context request not found' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(outsider,outsider,q1,src_a);
  raise exception 'TEST_FAILURE: request read across workspaces';
 exception when raise_exception then if sqlerrm is distinct from 'Context request not found' then raise; end if; end;
 if exists(select 1 from public.context_sources where withdrawn_at is not null)
  or exists(select 1 from public.context_results where status is distinct from 'accepted')
  or exists(select 1 from public.context_documents where current_result_id is null or revision is distinct from 1)
 then raise exception 'rejected withdrawal changed data'; end if;''')

    def test_browser_roles_cannot_withdraw(self):
        self.sql(f'''
do $$ begin
 if pg_catalog.has_function_privilege('anon','{FUNCTION}','EXECUTE')
  or pg_catalog.has_function_privilege('authenticated','{FUNCTION}','EXECUTE')
  or pg_catalog.has_function_privilege('anon','{TRIGGER_FUNCTION}','EXECUTE')
  or pg_catalog.has_function_privilege('authenticated','{TRIGGER_FUNCTION}','EXECUTE')
  or not pg_catalog.has_function_privilege('service_role','{FUNCTION}','EXECUTE')
 then raise exception 'withdrawal privileges are wrong'; end if;
end $$;''')
