-- Disposable fixture only: list trace IDs for one request in one workspace.
begin;
do $$
declare owner uuid:=gen_random_uuid(); other_owner uuid:=gen_random_uuid(); resource uuid; subject uuid; request uuid; execution uuid:=gen_random_uuid(); plan jsonb; result jsonb;
begin
 insert into public.accounts(id) values(owner),(other_owner);
 insert into public.songs(isrc) values('USAT22103065') on conflict do nothing;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','track','2zpWJxfuyxqCYhpsAqH7Uh','https://open.spotify.com/track/2zpWJxfuyxqCYhpsAqH7Uh') returning id into resource;
 insert into public.context_subjects(kind,song_isrc) values('recording','USAT22103065') returning id into subject;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,gen_random_uuid()::text,repeat('f',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into request;
 plan:=jsonb_build_array(jsonb_build_object('key',subject::text||':mlc_recording','subjectId',subject,'module','mlc_recording','state','blocked','dependsOn',jsonb_build_array()));
 perform public.create_context_execution(owner,request,execution,'metadata-review-v1',plan);
 perform public.save_context_execution_outcome(owner,execution,subject::text||':mlc_recording',jsonb_build_object('key',subject::text||':mlc_recording','status','blocked','blockReason','plan_blocked'));
 result:=public.list_context_request_executions(owner,request);
 if jsonb_array_length(result)<>1 or result->0->>'executionId' is distinct from execution::text
  or result->0->>'policyVersion' is distinct from 'metadata-review-v1'
  or result->0->>'nodeCount' is distinct from '1' or result->0->>'outcomeCount' is distinct from '1'
 then raise exception 'Saved request trace not listed'; end if;
 begin
  perform public.list_context_request_executions(other_owner,request);
  raise exception 'TEST_FAILURE: cross-owner traces exposed';
 exception when no_data_found then null; end;
 if has_function_privilege('anon','public.list_context_request_executions(uuid,uuid)','execute') then raise exception 'Browser trace list access granted'; end if;
end $$;
rollback;
