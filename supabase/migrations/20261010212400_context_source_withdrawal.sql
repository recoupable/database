-- Scoped source withdrawal reachable from the shared Context operation. Reuses the
-- existing withdrawal primitive and membership check. History is retained: no
-- original bytes are deleted, nothing is corrected, refreshed or recomputed, and
-- no provider or model call is made. Withdrawn evidence disappears from authorized
-- reads, document publication and saved briefs on the next read.
begin;

-- The source must be owned by the workspace and recorded as an input of this
-- request through saved result lineage; arbitrary source IDs are rejected.
-- Lock order follows evidence acceptance: membership, request, source, then the
-- primitive updates results and documents. Replay returns the same receipt.
create function public.withdraw_context_request_source(p_actor uuid,p_owner uuid,p_request uuid,p_source uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; src public.context_sources; already boolean;
 results_count integer; documents_count integer; affected_requests jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into req from public.context_requests where id=p_request and owner_id=p_owner for update;
 if req.id is null then raise exception 'Context request not found'; end if;
 select * into src from public.context_sources where id=p_source and owner_id=p_owner for update;
 if src.id is null or not exists(
   select 1 from public.context_attempts a
   join public.context_results r on r.attempt_id=a.id and r.owner_id=a.owner_id
   join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
   where a.request_id=p_request and a.owner_id=p_owner and v.source_id=p_source)
 then raise exception 'Source is not an input of this request'; end if;
 already:=src.withdrawn_at is not null;
 if not already then
  if not public.withdraw_context_source(p_owner,p_source) then raise exception 'Source withdrawal failed'; end if;
  select withdrawn_at into src.withdrawn_at from public.context_sources where id=p_source and owner_id=p_owner;
 end if;
 -- Recorded input relationships: every saved result that depends on any version of
 -- the source, the documents whose current result is now withheld because of it,
 -- and every request whose attempts produced those results.
 with linked as (
  select r.id as result_id,r.subject_id,r.topic,a.request_id
  from public.context_attempts a
  join public.context_results r on r.attempt_id=a.id and r.owner_id=a.owner_id
  join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
  join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
  where a.owner_id=p_owner and v.source_id=p_source)
 select count(distinct l.result_id),
  (select count(*) from public.context_documents d where d.owner_id=p_owner and d.current_result_id is null
    and exists(select 1 from linked x where x.subject_id=d.subject_id and x.topic=d.topic)),
  coalesce((select jsonb_agg(distinct x.request_id) from linked x),'[]'::jsonb)
 into results_count,documents_count,affected_requests from linked l;
 return jsonb_build_object('contract_version','context-source-withdrawal-v1','request_id',p_request,'source_id',p_source,
  'withdrawn_at',src.withdrawn_at,'already_withdrawn',already,
  'affected',jsonb_build_object('results',results_count,'documents',documents_count,'request_ids',affected_requests));
end $$;
revoke all on function public.withdraw_context_request_source(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.withdraw_context_request_source(uuid,uuid,uuid,uuid) to service_role;
commit;
