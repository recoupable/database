-- Disposable database only. The fixture rolls back; no external providers.
-- Requires the Context foundation, Spotify pipeline, brief snapshot and
-- document version migrations.
begin;
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); resource uuid; subject uuid; req uuid;
 url text:='https://open.spotify.com/album/'||repeat('D',22); doc uuid; first_result uuid; second_result uuid; src uuid;
 history jsonb; docs jsonb; manifest jsonb; brief jsonb; saved jsonb; readback jsonb; page jsonb;
begin
 insert into public.accounts(id,name) values(owner,'Document history owner'),(outsider,'Other workspace');
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release',repeat('D',22),url) returning id into resource;
 insert into public.context_subjects(kind,resource_id) values('release',resource) returning id into subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,'history-fixture',repeat('a',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject)))
 returning id into req;

 -- First accepted observation becomes revision 1 through the unchanged writer.
 doc:=public.save_context_metadata(owner,req,subject,'release_metadata',url,'{"title":"Fixture release","take":1}');
 select current_result_id into first_result from public.context_documents where id=doc;
 if first_result is null or (select revision from public.context_documents where id=doc)<>1 then raise exception 'First acceptance did not set the current pointer'; end if;
 history:=public.read_context_document_history(owner,doc);
 if jsonb_array_length(history->'versions')<>1 or history->'versions'->0->>'revision'<>'1'
  or history->'versions'->0->>'result_id'<>first_result::text or history->'versions'->0->>'change'<>'accepted'
  or history->'versions'->0->>'backfilled'<>'false' or history->'versions'->0->>'source_state'<>'live'
  or history->'versions'->0->>'result_status'<>'accepted' or jsonb_array_length(history->'versions'->0->'source_version_ids')<>1
  or history->>'has_more'<>'false' or history->'next_before'<>'null'::jsonb
 then raise exception 'First version was not recorded: %',history; end if;

 -- Freeze a brief that cites revision 1 before the document changes.
 docs:=public.read_context_documents(owner,req);
 select coalesce(jsonb_agg(jsonb_build_object('documentId',value->'id','resultId',value->'resultId','subjectId',value->'subjectId',
  'topic',value->'topic','version',value->'version','sourceVersionIds',value->'sourceVersionIds') order by ordinal),'[]'::jsonb)
 into manifest from jsonb_array_elements(docs) with ordinality d(value,ordinal);
 brief:=jsonb_build_object('request_id',req,'request_ids',jsonb_build_array(req),'purpose','playlist_pitch',
  'text','Document history fixture','documents',docs,'input_manifest',jsonb_build_object('compilerVersion','context-brief-v1',
  'method','saved_evidence_selection','requestIds',jsonb_build_array(req),'documents',manifest));
 saved:=public.save_context_brief(owner,'history-brief',brief);
 if saved->>'superseded'<>'false' or saved->>'state'<>'saved' then raise exception 'Fresh brief misreported: %',saved; end if;

 -- Identical content is reused without a new revision; changed content becomes revision 2.
 if public.save_context_metadata(owner,req,subject,'release_metadata',url,'{"title":"Fixture release","take":1}')<>doc
  or (select revision from public.context_documents where id=doc)<>1 then raise exception 'Identical content created a new revision'; end if;
 perform public.save_context_metadata(owner,req,subject,'release_metadata',url,'{"title":"Fixture release (corrected)","take":2}');
 select current_result_id into second_result from public.context_documents where id=doc;
 if second_result is null or second_result=first_result or (select revision from public.context_documents where id=doc)<>2
 then raise exception 'Second acceptance did not advance the pointer'; end if;
 history:=public.read_context_document_history(owner,doc);
 if jsonb_array_length(history->'versions')<>2
  or history->'versions'->0->>'revision'<>'2' or history->'versions'->0->>'result_id'<>second_result::text
  or history->'versions'->1->>'revision'<>'1' or history->'versions'->1->>'result_id'<>first_result::text
  or history->'document'->>'current_revision'<>'2' or history->'document'->>'current_result_id'<>second_result::text
  or history->'document'->>'subject_id'<>subject::text or history->'document'->>'topic'<>'release_metadata'
 then raise exception 'Two-version history mismatch: %',history; end if;
 if public.read_context_documents(owner,req)->0->>'resultId'<>second_result::text then raise exception 'Current read changed'; end if;

 -- The superseded brief still cites revision 1, and history resolves that citation.
 readback:=public.read_context_brief(owner,(saved->>'id')::uuid);
 if readback->>'superseded'<>'true' or readback->>'state'<>'saved' or readback->'brief'<>brief then raise exception 'Superseded brief changed: %',readback; end if;
 if (select result_id from public.context_document_versions where document_id=doc
   and revision=(readback->'brief'->'input_manifest'->'documents'->0->>'version')::bigint)
  <>(readback->'brief'->'input_manifest'->'documents'->0->>'resultId')::uuid
 then raise exception 'Cited version does not resolve to the cited result'; end if;

 -- A late acceptance with a stale revision records nothing.
 if public.accept_context_result(owner,doc,first_result,1) then raise exception 'Stale revision accepted'; end if;
 if (select count(*) from public.context_document_versions where document_id=doc)<>2 then raise exception 'Rejected acceptance wrote history'; end if;

 -- Moving the pointer without a revision is a lineage bug, not a silent overwrite.
 begin
  update public.context_documents set current_result_id=first_result where id=doc;
  raise exception 'TEST_FAILURE: pointer moved without a revision';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  update public.context_documents set revision=revision-1 where id=doc;
  raise exception 'TEST_FAILURE: revision moved backwards';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;

 -- Withdrawal clears the pointer as revision 3; earlier versions report withdrawn sources.
 select s.id into strict src from public.context_sources s where s.owner_id=owner and s.kind='provider_metadata' and s.withdrawn_at is null;
 if not public.withdraw_context_source(owner,src) then raise exception 'Withdrawal failed'; end if;
 history:=public.read_context_document_history(owner,doc);
 if (select current_result_id from public.context_documents where id=doc) is not null
  or jsonb_array_length(history->'versions')<>3
  or history->'versions'->0->>'revision'<>'3' or history->'versions'->0->>'change'<>'cleared'
  or history->'versions'->0->'result_id'<>'null'::jsonb or history->'versions'->0->'source_state'<>'null'::jsonb
  or history->'versions'->0->'source_version_ids'<>'[]'::jsonb
  or history->'versions'->1->>'source_state'<>'withdrawn' or history->'versions'->1->>'result_status'<>'withdrawn'
  or history->'versions'->2->>'source_state'<>'withdrawn'
  or history->'document'->'current_result_id'<>'null'::jsonb
 then raise exception 'Withdrawal history mismatch: %',history; end if;
 if public.read_context_documents(owner,req)<>'[]'::jsonb then raise exception 'Withdrawn document still readable as current'; end if;
 if public.read_context_brief(owner,(saved->>'id')::uuid)->>'state'<>'unavailable' then raise exception 'Withdrawn evidence leaked through the brief'; end if;

 -- Pagination walks newest first with an exclusive revision cursor; limits are clamped.
 page:=public.read_context_document_history(owner,doc,null,2);
 if jsonb_array_length(page->'versions')<>2 or page->>'has_more'<>'true' or page->>'next_before'<>'2'
  or page->'versions'->0->>'revision'<>'3' or page->'versions'->1->>'revision'<>'2'
 then raise exception 'First page mismatch: %',page; end if;
 page:=public.read_context_document_history(owner,doc,(page->>'next_before')::bigint,2);
 if jsonb_array_length(page->'versions')<>1 or page->>'has_more'<>'false' or page->'next_before'<>'null'::jsonb
  or page->'versions'->0->>'revision'<>'1'
 then raise exception 'Second page mismatch: %',page; end if;
 if jsonb_array_length(public.read_context_document_history(owner,doc,null,0)->'versions')<>1
  or jsonb_array_length(public.read_context_document_history(owner,doc,null,1000)->'versions')<>3
 then raise exception 'Limit was not clamped'; end if;

 -- History is immutable and one revision is recorded once.
 begin
  update public.context_document_versions set result_id=null,change='cleared' where document_id=doc and revision=1;
  raise exception 'TEST_FAILURE: history row updated';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  delete from public.context_document_versions where document_id=doc;
  raise exception 'TEST_FAILURE: history row deleted';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  insert into public.context_document_versions(owner_id,subject_id,topic,document_id,revision,result_id,change)
  values(owner,subject,'release_metadata',doc,2,second_result,'accepted');
  raise exception 'TEST_FAILURE: duplicate revision inserted';
 exception when unique_violation then null; end;
 begin
  insert into public.context_document_versions(owner_id,subject_id,topic,document_id,revision,result_id,change)
  values(outsider,subject,'release_metadata',doc,9,second_result,'accepted');
  raise exception 'TEST_FAILURE: history cited another workspace';
 exception when foreign_key_violation then null; end;
 if (select count(*) from public.context_document_versions where document_id=doc)<>3 then raise exception 'Rejected writes changed history'; end if;

 -- Another workspace or an unknown document reads nothing, not even existence.
 if public.read_context_document_history(outsider,doc) is not null then raise exception 'Cross-workspace history read'; end if;
 if public.read_context_document_history(owner,gen_random_uuid()) is not null then raise exception 'Unknown document returned history'; end if;

 -- The production service role records and reads history through the unchanged writers.
 set local role service_role;
 perform public.save_context_metadata(owner,req,subject,'release_metadata',url,'{"title":"Fixture release","take":3}');
 history:=public.read_context_document_history(owner,doc);
 if jsonb_array_length(history->'versions')<>4 or history->'versions'->0->>'revision'<>'4'
  or history->'versions'->0->>'change'<>'accepted' or history->'versions'->0->>'source_state'<>'live'
  or history->'document'->>'current_result_id'<>history->'versions'->0->>'result_id'
 then raise exception 'Service role lineage mismatch: %',history; end if;
 if public.read_context_document_history(outsider,doc) is not null then raise exception 'Service role leaked another workspace'; end if;
 begin
  insert into public.context_document_versions(owner_id,subject_id,topic,document_id,revision,result_id,change)
  values(owner,subject,'release_metadata',doc,5,null,'cleared');
  raise exception 'TEST_FAILURE: service role wrote history directly';
 exception when insufficient_privilege then null; end;
 reset role;

 if pg_catalog.has_function_privilege('authenticated','public.read_context_document_history(uuid,uuid,bigint,integer)','EXECUTE')
  or pg_catalog.has_function_privilege('anon','public.read_context_document_history(uuid,uuid,bigint,integer)','EXECUTE')
  or pg_catalog.has_table_privilege('service_role','public.context_document_versions','INSERT')
  or pg_catalog.has_table_privilege('service_role','public.context_document_versions','UPDATE')
  or pg_catalog.has_table_privilege('service_role','public.context_document_versions','DELETE')
  or pg_catalog.has_table_privilege('authenticated','public.context_document_versions','SELECT')
  or pg_catalog.has_table_privilege('anon','public.context_document_versions','SELECT')
 then raise exception 'Document history privileges are too broad'; end if;
 if not (select prosecdef from pg_catalog.pg_proc where oid='public.record_context_document_version()'::regprocedure)
  or (select prosecdef from pg_catalog.pg_proc where oid='public.read_context_document_history(uuid,uuid,bigint,integer)'::regprocedure)
 then raise exception 'Only the recording trigger may write history as its owner'; end if;
 raise notice 'PASS: accepted/cleared revisions recorded, current pointer kept, superseded brief resolvable, immutable history, scoped reads, service-role read-only path';
end $$;
rollback;
