-- Disposable fixture database only; no provider calls.
begin;
do $$
declare owner uuid:=gen_random_uuid(); request uuid; resource uuid; subject uuid; run uuid:=gen_random_uuid(); plan jsonb; first jsonb; claim jsonb; saved jsonb; success_run uuid:=gen_random_uuid();
begin
 insert into accounts(id) values(owner);
 insert into context_resources(provider,resource_kind,provider_id,canonical_url) values('spotify','release',run::text,'https://example.com/test') returning id into resource;
 insert into context_subjects(kind,resource_id) values('release',resource) returning id into subject;
 insert into context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,resource,run::text,repeat('c',64),'{}','completed',jsonb_build_object('subjectIds',jsonb_build_array(subject))) returning id into request;
 plan:=jsonb_build_array(jsonb_build_object('key',subject::text||':spotify_release','subjectId',subject,'module','spotify_release','state','blocked','dependsOn',jsonb_build_array(),'reasons',jsonb_build_array('Collection not permitted')));
 first:=public.create_context_execution(owner,request,run,'policy-v1',plan);
 if first->>'created' is distinct from 'true' then raise exception 'Fresh run not marked created'; end if;
 if public.create_context_execution(owner,request,run,'policy-v1',plan)->>'created' is distinct from 'false' then raise exception 'Replay could dispatch again'; end if;
 begin
  perform public.create_context_execution(owner,request,run,'policy-v2',plan);
  raise exception 'TEST_FAILURE: plan replaced';
 exception when others then if SQLERRM<>'Execution identity conflict' then raise; end if; end;
 begin
  perform public.save_context_execution_outcome(owner,run,subject::text||':spotify_release','{"status":"saved","receipt":{"resultId":"00000000-0000-4000-8000-000000000001"}}');
  raise exception 'TEST_FAILURE: invented success';
 exception when others then if SQLERRM<>'Execution evidence does not match node' then raise; end if; end;
 perform public.save_context_execution_outcome(owner,run,subject::text||':spotify_release','{"status":"blocked","blockReason":"plan_blocked","reasons":["Collection not permitted"]}');
 perform public.save_context_execution_outcome(owner,run,subject::text||':spotify_release','{"status":"blocked","blockReason":"plan_blocked","reasons":["Collection not permitted"]}');
 begin
  perform public.save_context_execution_outcome(owner,run,subject::text||':spotify_release','{"status":"failed"}');
  raise exception 'TEST_FAILURE: outcome replaced';
 exception when others then if SQLERRM<>'Execution outcome conflict' then raise; end if; end;
 begin
  perform public.save_context_execution_outcome(owner,run,'not-in-plan','{"status":"blocked"}');
  raise exception 'TEST_FAILURE: unknown node';
 exception when others then if SQLERRM<>'Unknown execution node' then raise; end if; end;
 begin
  perform public.read_context_execution(gen_random_uuid(),run);
  raise exception 'TEST_FAILURE: wrong owner';
 exception when no_data_found then null; end;
 begin
  perform public.save_context_execution_outcome(gen_random_uuid(),run,subject::text||':spotify_release','{"status":"failed"}');
  raise exception 'TEST_FAILURE: wrong owner save';
 exception when no_data_found then null; end;
 begin
  perform public.create_context_execution(owner,request,gen_random_uuid(),'policy-v1',plan||plan);
  raise exception 'TEST_FAILURE: duplicate plan keys';
 exception when others then if SQLERRM<>'Invalid execution node' then raise; end if; end;
 begin
  perform public.create_context_execution(owner,request,gen_random_uuid(),'policy-v1',jsonb_set(plan,'{0,subjectId}',to_jsonb(gen_random_uuid())));
  raise exception 'TEST_FAILURE: unlinked subject';
 exception when others then if SQLERRM<>'Invalid execution node' then raise; end if; end;
 if jsonb_array_length(public.read_context_execution(owner,run)->'outcomes')<>1 then raise exception 'Duplicate outcome'; end if;
 -- Exercise a successful receipt using the real evidence claim/save functions.
 claim:=public.claim_context_enrichment(owner,request,jsonb_build_object('key','fixture','topic','spotify_release_context','subjectId',subject,'provider','fixture','model','none','evidenceKind','observation','fingerprint',encode(sha256(convert_to(run::text,'UTF8')),'hex'),'sources',jsonb_build_array(jsonb_build_object('url','https://example.com/test','kind','provider_metadata','content',jsonb_build_object('fixture',true)))));
 saved:=public.complete_context_enrichment(owner,request,(claim->>'attemptId')::uuid,'{"content":{"fixture":true},"coverage":"full","trace":{},"costStatus":"unknown"}');
 perform public.create_context_execution(owner,request,success_run,'policy-v1',jsonb_set(plan,'{0,state}','"ready_for_dispatch"'));
 perform public.save_context_execution_outcome(owner,success_run,subject::text||':spotify_release',jsonb_build_object('status','saved','receipt',saved));
 if public.read_context_execution(owner,success_run)->'outcomes'->0->'outcome'->>'status'<>'saved' then raise exception 'Successful evidence not traced'; end if;
 update context_requests set status='cancelled' where id=request;
 -- Cancelled runs remain inspectable, but cannot be started again.
 perform public.read_context_execution(owner,run);
 begin
  perform public.create_context_execution(owner,request,gen_random_uuid(),'policy-v1',plan);
  raise exception 'TEST_FAILURE: cancelled request';
 exception when others then if SQLERRM<>'Request is not ready for enrichment' then raise; end if; end;
 if has_table_privilege('authenticated','public.context_executions','select') or has_function_privilege('anon','public.read_context_execution(uuid,uuid)','execute') then raise exception 'Browser access granted'; end if;
end $$;
rollback;
