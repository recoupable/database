-- Scoped source withdrawal reachable from the shared Context operation. Reuses the
-- existing withdrawal primitive and membership check. Rows are kept: no original
-- bytes are deleted, nothing is corrected, refreshed or recomputed, and no provider
-- or model call is made. The primitive relabels every saved result on the source
-- as withdrawn, replacing its earlier status. Withdrawn evidence disappears from
-- authorized reads, document publication and saved briefs on the next read.
begin;

-- A withdrawn source URL stays withdrawn in its workspace. Writers re-create
-- sources through the active (owner, kind, URL) index, which ignores withdrawn
-- rows, so a slower or later job would otherwise record the same URL as a new
-- active source and publish it again. Such a row is born withdrawn instead: its
-- evidence is kept as history but can never be accepted or read, and writers that
-- require acceptance fail closed. Waiting on the active row first serializes with
-- an in-flight withdrawal, which holds that row FOR UPDATE until it commits. Other
-- workspaces and other source kinds are unaffected. There is no restore operation.
create index context_withdrawn_source_url on public.context_sources(owner_id,kind,source_url)
 where withdrawn_at is not null and source_url is not null;
create function public.keep_context_source_withdrawn()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.source_url is null or new.withdrawn_at is not null then return new; end if;
 perform 1 from public.context_sources s where s.owner_id=new.owner_id and s.kind=new.kind
  and s.source_url=new.source_url and s.withdrawn_at is null for key share;
 if exists(select 1 from public.context_sources s where s.owner_id=new.owner_id and s.kind=new.kind
  and s.source_url=new.source_url and s.withdrawn_at is not null) then new.withdrawn_at:=now(); end if;
 return new;
end $$;
revoke all on function public.keep_context_source_withdrawn() from public,anon,authenticated;
create trigger context_sources_keep_withdrawn before insert on public.context_sources
 for each row execute function public.keep_context_source_withdrawn();

-- Callers name the source directly or by one of its versions (brief input manifests
-- and document reads expose version IDs). The source must be owned by the workspace
-- and recorded as an input of this request through saved result lineage; arbitrary
-- IDs are rejected. Locks: membership, request, source, then the primitive updates
-- results and documents. Writers that lock a document before reusing the active
-- source row take the opposite order, so a concurrent writer on a shared document
-- can deadlock with a withdrawal; PostgreSQL aborts one transaction and the caller
-- retries. Replay returns the same receipt without touching timestamps or revisions.
create function public.withdraw_context_request_source(p_actor uuid,p_owner uuid,p_request uuid,
 p_source uuid default null,p_source_version uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; src public.context_sources; v_source uuid; already boolean;
 results_count integer; documents_count integer; affected_requests jsonb;
begin
 if (p_source is null)=(p_source_version is null) then
  raise exception 'Provide exactly one source or source version' using errcode='22023';
 end if;
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into req from public.context_requests where id=p_request and owner_id=p_owner for update;
 if req.id is null then raise exception 'Context request not found'; end if;
 v_source:=p_source;
 if p_source_version is not null then
  select v.source_id into v_source from public.context_source_versions v where v.id=p_source_version and v.owner_id=p_owner;
 end if;
 select * into src from public.context_sources where id=v_source and owner_id=p_owner for update;
 if src.id is null or not exists(
   select 1 from public.context_attempts a
   join public.context_results r on r.attempt_id=a.id and r.owner_id=a.owner_id
   join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
   where a.request_id=p_request and a.owner_id=p_owner and v.source_id=src.id)
 then raise exception 'Source is not an input of this request'; end if;
 already:=src.withdrawn_at is not null;
 if not already then
  if not public.withdraw_context_source(p_owner,src.id) then raise exception 'Source withdrawal failed'; end if;
  select withdrawn_at into src.withdrawn_at from public.context_sources where id=src.id and owner_id=p_owner;
 end if;
 -- Recorded input relationships, stable on replay: every saved result that depends
 -- on any version of the source, every document (subject and topic) holding such a
 -- result, and every request whose attempts produced those results. A document whose
 -- current result depended on the source no longer has a current result.
 with linked as (
  select r.id as result_id,r.subject_id,r.topic,a.request_id
  from public.context_attempts a
  join public.context_results r on r.attempt_id=a.id and r.owner_id=a.owner_id
  join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
  join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
  where a.owner_id=p_owner and v.source_id=src.id)
 select count(distinct l.result_id),
  (select count(*) from public.context_documents d where d.owner_id=p_owner
    and exists(select 1 from linked x where x.subject_id=d.subject_id and x.topic=d.topic)),
  coalesce((select jsonb_agg(distinct x.request_id) from linked x),'[]'::jsonb)
 into results_count,documents_count,affected_requests from linked l;
 return jsonb_build_object('contract_version','context-source-withdrawal-v1','request_id',p_request,'source_id',src.id,
  'withdrawn_at',src.withdrawn_at,'already_withdrawn',already,
  'affected',jsonb_build_object('results',results_count,'documents',documents_count,'request_ids',affected_requests));
end $$;
revoke all on function public.withdraw_context_request_source(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.withdraw_context_request_source(uuid,uuid,uuid,uuid,uuid) to service_role;
commit;
