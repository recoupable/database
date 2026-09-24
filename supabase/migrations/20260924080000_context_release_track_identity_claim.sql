-- A track-level lookup is a separate operation from reading an album page.
-- Claim it only for the current, fully materialized release result. A prior
-- claim is never retried automatically because the provider call may have run.
begin;
create or replace function public.claim_context_release_track_isrcs(
 p_owner uuid,p_request uuid,p_subject uuid,p_release_result uuid,p_fingerprint text
) returns jsonb language plpgsql set search_path='' as $$
declare page jsonb; previous public.context_attempts; v_attempt uuid; claim_key text;
begin
 if p_fingerprint !~ '^[a-f0-9]{64}$' then raise exception 'Invalid track lookup fingerprint'; end if;
 page:=public.list_context_release_track_slots(p_owner,p_request,p_subject,-1,100);
 if page->>'state'<>'ready' or (page->>'sourceResultId')::uuid is distinct from p_release_result
  or (page->>'linkedSlots')::integer not between 1 and 100 or page->>'hasMore'<>'false'
 then raise exception 'Current release tracks are not ready for lookup'; end if;
 claim_key:='spotify_release_track_isrcs:'||p_subject||':'||p_release_result;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_owner::text||':'||claim_key,0));
 select a.* into previous from public.context_attempts a
 where a.owner_id=p_owner and a.request_id=p_request and a.module=claim_key and a.attempt=1;
 if previous.id is not null then
  return jsonb_build_object('state','unknown','attemptId',previous.id,
   'reason','Prior track lookup requires evidence reconciliation before another provider call');
 end if;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,model,
  recipe_version,schema_version,input,started_at)
 values(p_owner,p_request,claim_key,1,'running','spotify','none',
  'spotify-release-track-isrcs-v1','1',
  jsonb_build_object('subjectId',p_subject,'releaseResultId',p_release_result,
   'fingerprint',p_fingerprint,'linkedSlots',(page->>'linkedSlots')::integer),now())
 returning id into v_attempt;
 return jsonb_build_object('state','claimed','attemptId',v_attempt,
  'sourceResultId',p_release_result,'linkedSlots',(page->>'linkedSlots')::integer);
end $$;
revoke all on function public.claim_context_release_track_isrcs(uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.claim_context_release_track_isrcs(uuid,uuid,uuid,uuid,text) to service_role;
commit;
