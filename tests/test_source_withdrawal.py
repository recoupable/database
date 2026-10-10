"""Scoped source withdrawal through recorded input relationships; disposable PG only."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATION = ROOT / 'supabase/migrations/20261010212400_context_source_withdrawal.sql'
FUNCTION = 'public.withdraw_context_request_source(uuid,uuid,uuid,uuid)'

# One workspace (owner) with a member and an outsider. Request q1 has two accepted
# documents from two sources (A private, B public) and two saved briefs that depend
# on exactly one of them each. Request q2 holds unrelated accepted evidence (source C).
DECLARE = '''
 owner uuid:=gen_random_uuid(); member uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
 res1 uuid; res2 uuid; s1 uuid; s2 uuid; q1 uuid; q2 uuid;
 src_a uuid; src_b uuid; src_c uuid; foreign_src uuid; ver_a uuid; ver_b uuid; ver_c uuid;
 att_a uuid; att_b uuid; att_c uuid; att_d uuid; res_a uuid; res_b uuid; res_c uuid; res_d uuid; late uuid;
 doc_a uuid; doc_b uuid; doc_c uuid; doc_d uuid; evidence jsonb; brief_a jsonb; brief_b jsonb;
 receipt jsonb; replay jsonb; shifted timestamptz;
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
 if brief_a->>'state'<>'saved' or brief_b->>'state'<>'saved' then raise exception 'seed briefs were not saved'; end if;
'''


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
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);
 if receipt->>'contract_version'<>'context-source-withdrawal-v1' or receipt->>'request_id'<>q1::text
  or receipt->>'source_id'<>src_a::text or receipt->>'already_withdrawn'<>'false' or receipt->>'withdrawn_at' is null
 then raise exception 'receipt malformed: %',receipt; end if;
 if (receipt->'affected'->>'results')::int<>1 or (receipt->'affected'->>'documents')::int<>1
  or receipt->'affected'->'request_ids'<>jsonb_build_array(q1) then raise exception 'affected set wrong: %',receipt; end if;
 if (select withdrawn_at from public.context_sources where id=src_a) is null then raise exception 'source A not withdrawn'; end if;
 if (select status from public.context_results where id=res_a)<>'withdrawn' then raise exception 'result A not withdrawn'; end if;
 if (select current_result_id from public.context_documents where id=doc_a) is not null
  or (select revision from public.context_documents where id=doc_a)<>2 then raise exception 'document A not suppressed'; end if;
 if (select status from public.context_results where id=res_b)<>'accepted' or (select withdrawn_at from public.context_sources where id=src_b) is not null
  or (select current_result_id from public.context_documents where id=doc_b)<>res_b or (select revision from public.context_documents where id=doc_b)<>1
 then raise exception 'unrelated document B changed'; end if;
 if (select status from public.context_results where id=res_c)<>'accepted' or (select withdrawn_at from public.context_sources where id=src_c) is not null
  or (select current_result_id from public.context_documents where id=doc_c)<>res_c or (select revision from public.context_documents where id=doc_c)<>1
 then raise exception 'unrelated request changed'; end if;
 if (select status from public.context_requests where id=q1)<>'completed' then raise exception 'request status changed'; end if;
 if exists(select 1 from jsonb_array_elements(public.read_context_documents(owner,q1)) d where d->>'id'=doc_a::text)
  then raise exception 'withdrawn document still readable'; end if;
 if not exists(select 1 from jsonb_array_elements(public.read_context_documents(owner,q1)) d where d->>'id'=doc_b::text)
  then raise exception 'unrelated document lost'; end if;
 if (select count(*) from public.context_results)<>3 or (select count(*) from public.context_source_versions)<>3
  then raise exception 'history was deleted'; end if;''')

    def test_replay_returns_the_same_receipt_without_touching_timestamps(self):
        self.case('''
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);
 update public.context_sources set withdrawn_at=withdrawn_at-interval '1 hour' where id=src_a returning withdrawn_at into shifted;
 replay:=public.withdraw_context_request_source(member,owner,q1,src_a);
 if replay->>'already_withdrawn'<>'true' or (replay->>'withdrawn_at')::timestamptz<>shifted
  then raise exception 'replay reset withdrawal: %',replay; end if;
 if replay-'already_withdrawn'-'withdrawn_at'<>receipt-'already_withdrawn'-'withdrawn_at'
  then raise exception 'replay changed receipt: % vs %',receipt,replay; end if;
 if (select revision from public.context_documents where id=doc_a)<>2 then raise exception 'replay bumped revision'; end if;
 if (select withdrawn_at from public.context_sources where id=src_a)<>shifted then raise exception 'replay touched withdrawn_at'; end if;''')

    def test_old_job_cannot_republish_a_withdrawn_source(self):
        self.case('''
 perform public.withdraw_context_request_source(member,owner,q1,src_a);
 if public.accept_context_result(owner,doc_a,res_a,2) then raise exception 'withdrawn result resurrected'; end if;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_a,s1,'song_summary',repeat('7',64),'accepted','customer_assertion','{"summary":"Late job"}','{"extent":"full"}') returning id into late;
 insert into public.context_result_sources values(owner,late,ver_a);
 if public.accept_context_result(owner,doc_a,late,1) then raise exception 'stale revision accepted'; end if;
 if public.accept_context_result(owner,doc_a,late,2) then raise exception 'late job republished withdrawn source'; end if;
 if (select current_result_id from public.context_documents where id=doc_a) is not null then raise exception 'document republished'; end if;''')

    def test_saved_briefs_depending_on_the_source_become_unavailable(self):
        self.case('''
 perform public.withdraw_context_request_source(member,owner,q1,src_a);
 replay:=public.read_context_brief(owner,(brief_a->>'id')::uuid);
 if replay->>'state'<>'unavailable' or replay->'brief'<>'null'::jsonb then raise exception 'brief on withdrawn source still readable: %',replay; end if;
 replay:=public.read_context_brief(owner,(brief_b->>'id')::uuid);
 if replay->>'state'<>'saved' or replay->'brief' is null then raise exception 'unrelated brief lost: %',replay; end if;''')

    def test_withdrawal_reports_every_request_sharing_the_source(self):
        self.case('''
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,recipe_version,schema_version)
  values(owner,q2,'lyrics',1,'succeeded','1','1') returning id into att_d;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
  values(owner,att_d,s2,'lyrics',repeat('8',64),'accepted','customer_assertion','{"lyrics":"Shared private note"}','{"extent":"full"}') returning id into res_d;
 insert into public.context_result_sources values(owner,res_d,ver_a);
 insert into public.context_documents(owner_id,subject_id,topic,revision,current_result_id) values(owner,s2,'lyrics',1,res_d) returning id into doc_d;
 receipt:=public.withdraw_context_request_source(member,owner,q1,src_a);
 if (receipt->'affected'->>'results')::int<>2 or (receipt->'affected'->>'documents')::int<>2
  or jsonb_array_length(receipt->'affected'->'request_ids')<>2
  or not (receipt->'affected'->'request_ids' ? q1::text) or not (receipt->'affected'->'request_ids' ? q2::text)
 then raise exception 'shared lineage not reported: %',receipt; end if;
 if (select status from public.context_results where id=res_d)<>'withdrawn'
  or (select current_result_id from public.context_documents where id=doc_d) is not null then raise exception 'dependent read in q2 not suppressed'; end if;
 if (select current_result_id from public.context_documents where id=doc_c)<>res_c then raise exception 'unrelated q2 document changed'; end if;''')

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
  or (select status from public.context_results where id=res_a)<>'accepted'
  or (select current_result_id from public.context_documents where id=doc_a)<>res_a then raise exception 'denied actor changed data'; end if;
 receipt:=public.withdraw_context_request_source(owner,owner,q1,src_a);
 if receipt->>'already_withdrawn'<>'false' then raise exception 'workspace owner could not withdraw'; end if;''')

    def test_sources_outside_the_request_lineage_are_rejected(self):
        self.case('''
 begin
  perform public.withdraw_context_request_source(member,owner,q1,src_c);
  raise exception 'TEST_FAILURE: unlinked source withdrawn';
 exception when raise_exception then if sqlerrm<>'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q2,src_a);
  raise exception 'TEST_FAILURE: source withdrawn through an unrelated request';
 exception when raise_exception then if sqlerrm<>'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,q1,foreign_src);
  raise exception 'TEST_FAILURE: foreign workspace source withdrawn';
 exception when raise_exception then if sqlerrm<>'Source is not an input of this request' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(member,owner,gen_random_uuid(),src_a);
  raise exception 'TEST_FAILURE: unknown request accepted';
 exception when raise_exception then if sqlerrm<>'Context request not found' then raise; end if; end;
 begin
  perform public.withdraw_context_request_source(outsider,outsider,q1,src_a);
  raise exception 'TEST_FAILURE: request read across workspaces';
 exception when raise_exception then if sqlerrm<>'Context request not found' then raise; end if; end;
 if exists(select 1 from public.context_sources where withdrawn_at is not null)
  or exists(select 1 from public.context_results where status<>'accepted')
  or exists(select 1 from public.context_documents where current_result_id is null or revision<>1)
 then raise exception 'rejected withdrawal changed data'; end if;''')

    def test_browser_roles_cannot_withdraw(self):
        self.sql(f'''
do $$ begin
 if pg_catalog.has_function_privilege('anon','{FUNCTION}','EXECUTE')
  or pg_catalog.has_function_privilege('authenticated','{FUNCTION}','EXECUTE')
  or not pg_catalog.has_function_privilege('service_role','{FUNCTION}','EXECUTE')
 then raise exception 'withdrawal privileges are wrong'; end if;
end $$;''')
