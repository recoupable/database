-- Disposable local database only. A claim means a provider step may already have run; never auto-retry it.
begin;
do $$
declare owner uuid:=gen_random_uuid(); request uuid; resource uuid; subject uuid; execution uuid:=gen_random_uuid();
 first_key text; second_key text; plan jsonb; claim jsonb; evidence_claim jsonb; saved jsonb; blocked_execution uuid:=gen_random_uuid();
begin
 insert into accounts(id) values(owner);
 insert into context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','track',execution::text,'https://example.com/test') returning id into resource;
 insert into songs(isrc) values('USAT22103065') on conflict do nothing;
 insert into context_subjects(kind,song_isrc) values('recording','USAT22103065') returning id into subject;
 insert into context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,execution::text,repeat('d',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into request;
 first_key:=subject::text||':musicbrainz'; second_key:=subject::text||':mlc_recording';
 plan:=jsonb_build_array(
  jsonb_build_object('key',first_key,'subjectId',subject,'module','musicbrainz','state','ready_for_dispatch','dependsOn',jsonb_build_array()),
  jsonb_build_object('key',second_key,'subjectId',subject,'module','mlc_recording','state','ready_for_dispatch','dependsOn',jsonb_build_array(first_key)));
 perform public.create_context_execution(owner,request,execution,'policy-v1',plan);
 perform public.create_context_execution(owner,request,blocked_execution,'policy-v1',jsonb_set(plan,'{0,state}','"blocked"'));
 begin
  perform public.claim_context_execution_node(owner,blocked_execution,first_key);
  raise exception 'TEST_FAILURE: blocked node claimed';
 exception when others then if SQLERRM<>'Execution node is not runnable' then raise; end if; end;
 begin
  perform public.claim_context_execution_node(owner,execution,second_key);
  raise exception 'TEST_FAILURE: dependency bypassed';
 exception when others then if SQLERRM<>'Execution prerequisites not complete' then raise; end if; end;
 update context_requests set output='{"subjectIds":[]}' where id=request;
 begin
  perform public.claim_context_execution_node(owner,execution,first_key);
  raise exception 'TEST_FAILURE: removed subject claimed';
 exception when others then if SQLERRM<>'Execution subject no longer in request' then raise; end if; end;
 update context_requests set output=jsonb_build_object('subjectIds',jsonb_build_array(subject)) where id=request;
 claim:=public.claim_context_execution_node(owner,execution,first_key);
 if claim->>'state'<>'claimed' then raise exception 'First claim not granted'; end if;
 if public.read_context_execution(owner,execution)->'claims'->0->>'state' is distinct from 'unknown' then raise exception 'Unresolved claim not visible'; end if;
 if public.claim_context_execution_node(owner,execution,first_key)->>'state'<>'unknown' then raise exception 'Repeated claim could dispatch'; end if;
 begin
  perform public.claim_context_execution_node(gen_random_uuid(),execution,first_key);
  raise exception 'TEST_FAILURE: wrong owner claimed';
 exception when no_data_found then null; end;
 begin
  perform public.claim_context_execution_node(owner,execution,'not-in-plan');
  raise exception 'TEST_FAILURE: unplanned node claimed';
 exception when others then if SQLERRM<>'Unknown execution node' then raise; end if; end;
 evidence_claim:=public.claim_context_enrichment(owner,request,jsonb_build_object('key','fixture','topic','musicbrainz_recordings','subjectId',subject,'provider','fixture','model','none','evidenceKind','observation','fingerprint',encode(sha256(convert_to(execution::text,'UTF8')),'hex'),'sources',jsonb_build_array(jsonb_build_object('url','https://example.com/test','kind','provider_metadata','content',jsonb_build_object('fixture',true)))));
 saved:=public.complete_context_enrichment(owner,request,(evidence_claim->>'attemptId')::uuid,'{"content":{"fixture":true},"coverage":"full","trace":{},"costStatus":"unknown"}');
 perform public.save_context_execution_outcome(owner,execution,first_key,jsonb_build_object('status','saved','receipt',saved));
 if public.read_context_execution(owner,execution)->'claims'->0->>'state' is distinct from 'saved' then raise exception 'Claim outcome not visible'; end if;
 if public.claim_context_execution_node(owner,execution,first_key)->>'state'<>'unknown' then raise exception 'Completed node claimed again'; end if;
 claim:=public.claim_context_execution_node(owner,execution,second_key);
 if claim->>'state'<>'claimed' then raise exception 'Dependency-complete claim not granted'; end if;
 if public.claim_context_execution_node(owner,execution,second_key)->>'state'<>'unknown' then raise exception 'Second node replay could dispatch'; end if;
 update context_requests set status='cancelled' where id=request;
 begin
  perform public.claim_context_execution_node(owner,execution,second_key);
  raise exception 'TEST_FAILURE: cancelled request claimed';
 exception when others then if SQLERRM<>'Request is not ready for enrichment' then raise; end if; end;
 if has_function_privilege('anon','public.claim_context_execution_node(uuid,uuid,text)','execute') then raise exception 'Browser claim access granted'; end if;
end $$;
rollback;
