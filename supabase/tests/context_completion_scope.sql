-- Disposable local database only. No provider calls; all fixtures roll back.
begin;
do $$
declare owner uuid:=gen_random_uuid(); resource uuid; subject uuid; request uuid;
 module jsonb; claim jsonb; saved jsonb; payload jsonb; invalid_output jsonb; mode text;
begin
 insert into public.accounts(id) values(owner);
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release',gen_random_uuid()::text,'https://example.com/fixture') returning id into resource;
 insert into public.context_subjects(kind,resource_id) values('release',resource) returning id into subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,'scope-fixture',repeat('a',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into request;
 module:=jsonb_build_object('key','scope-v1','topic','spotify_release_context','subjectId',subject,'provider','fixture','model','none','evidenceKind','observation','fingerprint',repeat('b',64),'sources',jsonb_build_array(jsonb_build_object('url','https://example.com/fixture','kind','provider_metadata','content',jsonb_build_object('fixture',true))));
 payload:=jsonb_build_object('content',jsonb_build_object('fixture',true),'coverage','full','trace','{}'::jsonb,'costStatus','unknown');
 claim:=public.claim_context_enrichment(owner,request,module);
 for mode in select unnest(array['cancelled','removed','null','missing','object']) loop
  invalid_output:=case mode when 'cancelled' then jsonb_build_object('subjectIds',jsonb_build_array(subject)) when 'removed' then '{"subjectIds":[]}'::jsonb when 'null' then null when 'missing' then '{}'::jsonb else jsonb_build_object('subjectIds',jsonb_build_object(subject::text,true)) end;
  update public.context_requests set status=case when mode='cancelled' then 'cancelled' else 'completed' end,output=invalid_output where id=request;
  begin
   perform public.complete_context_enrichment(owner,request,(claim->>'attemptId')::uuid,payload);
   raise exception 'TEST_FAILURE: saved after %',mode;
  exception when others then
   if SQLERRM not like 'Subject outside completed metadata request%' then raise; end if;
  end;
  begin
   perform public.claim_context_enrichment(owner,request,module);
   raise exception 'TEST_FAILURE: claimed after %',mode;
  exception when others then
   if SQLERRM not like 'Subject outside completed metadata request%' then raise; end if;
  end;
 end loop;
 if exists(select 1 from public.context_results where owner_id=owner) or exists(select 1 from public.context_documents where owner_id=owner) or exists(select 1 from public.context_sources where owner_id=owner) then raise exception 'TEST_FAILURE: rejected save left evidence'; end if;
 update public.context_requests set status='completed',output=jsonb_build_object('subjectIds',jsonb_build_array(subject)) where id=request;
 begin
  perform public.complete_context_enrichment(gen_random_uuid(),request,(claim->>'attemptId')::uuid,payload);
  raise exception 'TEST_FAILURE: wrong owner accepted';
 exception when no_data_found then null; end;
 saved:=public.complete_context_enrichment(owner,request,(claim->>'attemptId')::uuid,payload);
 if saved->>'state' is distinct from 'saved' then raise exception 'TEST_FAILURE: valid save rejected'; end if;
 perform public.complete_context_enrichment(owner,request,(claim->>'attemptId')::uuid,payload);
 if (select count(*) from public.context_results where owner_id=owner)<>1 then raise exception 'TEST_FAILURE: duplicate completion'; end if;
 update public.context_requests set status='cancelled' where id=request;
 begin
  perform public.complete_context_enrichment(owner,request,(claim->>'attemptId')::uuid,payload);
  raise exception 'TEST_FAILURE: succeeded attempt bypassed cancellation';
 exception when others then
  if SQLERRM not like 'Subject outside completed metadata request%' then raise; end if;
 end;
end $$;
rollback;
