-- Forward-only: choose the bounded version page before aggregating provenance.
begin;
create or replace function public.list_context_request_evidence_versions(p_actor uuid,p_owner uuid,p_request uuid,p_after uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; items jsonb; more boolean; cursor_valid boolean;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.id is null or req.status not in ('partial','completed')
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
 then raise exception 'Evidence manifest unavailable' using errcode='42501'; end if;
 -- One statement gives a coherent source/withdrawal snapshot for this page.
 with eligible_results as not materialized (
  select r.id,r.evidence_kind,d.current_result_id
  from public.context_attempts a
  join public.context_results r on r.attempt_id=a.id and r.owner_id=a.owner_id
  left join public.context_documents d on d.current_result_id=r.id and d.owner_id=r.owner_id
  where a.owner_id=p_owner and a.request_id=p_request
   and req.output->'subjectIds' ? r.subject_id::text
   and r.status='accepted' and r.evidence_kind<>'creative_proposal'
   and not exists(select 1 from public.context_result_sources dep
    join public.context_source_versions dv on dv.id=dep.source_version_id and dv.owner_id=dep.owner_id
    join public.context_sources ds on ds.id=dv.source_id and ds.owner_id=dv.owner_id
    where dep.result_id=r.id and dep.owner_id=p_owner
     and (dv.removed_at is not null or ds.withdrawn_at is not null))
 ), eligible_versions as not materialized (
  select v.id as source_version_id,s.id as source_id,s.kind as source_kind,v.fingerprint,v.retrieved_at
  from public.context_source_versions v
  join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
  where v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null
   and exists(select 1 from public.context_result_sources rs
    join eligible_results r on r.id=rs.result_id
    where rs.source_version_id=v.id and rs.owner_id=p_owner)
 ), cursor_row as (select * from eligible_versions where source_version_id=p_after),
 selected_versions as materialized (
  select * from eligible_versions where p_after is null or
   (retrieved_at,source_version_id)<(select retrieved_at,source_version_id from cursor_row)
  order by retrieved_at desc,source_version_id desc limit 51
 ), page as (
  select v.*,jsonb_agg(distinct r.evidence_kind order by r.evidence_kind) as evidence_kinds,
   bool_or(r.current_result_id is not null) as is_current
  from selected_versions v
  join public.context_result_sources rs on rs.source_version_id=v.source_version_id and rs.owner_id=p_owner
  join eligible_results r on r.id=rs.result_id
  group by v.source_version_id,v.source_id,v.source_kind,v.fingerprint,v.retrieved_at
 )
 select coalesce(jsonb_agg(to_jsonb(page) order by retrieved_at desc,source_version_id desc),'[]'::jsonb),
  p_after is null or exists(select 1 from cursor_row)
 into items,cursor_valid from page;
 if not cursor_valid then raise exception 'Evidence manifest unavailable' using errcode='42501'; end if;
 more:=jsonb_array_length(items)>50;
 if more then items:=items-50; end if;
 return jsonb_build_object('request_id',p_request,'owner_id',p_owner,'versions',items,'has_more',more,
  'next_id',case when more then items->49->>'source_version_id' end);
end $$;
revoke all on function public.context_request_evidence_versions(uuid,uuid) from service_role;
commit;
