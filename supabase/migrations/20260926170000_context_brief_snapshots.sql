-- Immutable compiled output; source withdrawal still controls read access.
begin;
create table public.context_briefs (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.accounts(id) on delete restrict,
 idempotency_key text not null check(length(idempotency_key) between 1 and 128),
 request_ids uuid[] not null check(cardinality(request_ids) between 1 and 10),
 purpose text not null check(purpose in ('creative_direction','playlist_pitch')),
 snapshot jsonb not null check(jsonb_typeof(snapshot)='object' and octet_length(snapshot::text)<=1048576),
 created_at timestamptz not null default now(),
 unique(owner_id,idempotency_key)
);
alter table public.context_briefs enable row level security;
revoke all on public.context_briefs from public,anon,authenticated,service_role;
grant select,insert on public.context_briefs to service_role;

create function public.read_context_brief(p_owner uuid,p_brief uuid)
returns jsonb language plpgsql set search_path='' as $$
declare saved public.context_briefs; item jsonb; unavailable boolean:=false; superseded boolean:=false;
begin
 select * into strict saved from public.context_briefs where id=p_brief and owner_id=p_owner;
 perform 1 from public.context_requests where owner_id=p_owner and id=any(saved.request_ids) order by id for share;
 if (select count(*) from public.context_requests where owner_id=p_owner and id=any(saved.request_ids)
  and status in ('completed','partial'))<>cardinality(saved.request_ids) then unavailable:=true; end if;
 for item in select value from jsonb_array_elements(saved.snapshot->'documents') loop
  perform 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
   join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
   where rs.result_id=(item->>'resultId')::uuid and rs.owner_id=p_owner order by s.id for share of s,v;
  if not exists(select 1 from public.context_results r where r.id=(item->>'resultId')::uuid
    and r.owner_id=p_owner and r.subject_id=(item->>'subjectId')::uuid and r.status='accepted')
   or not exists(select 1 from public.context_requests q where q.id=any(saved.request_ids) and q.owner_id=p_owner
    and (q.output->'subjectIds' ? (item->>'subjectId')) is true)
   or exists(select 1 from jsonb_array_elements_text(item->'sourceVersionIds') x
    where not exists(select 1 from public.context_result_sources rs
     join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
     join public.context_sources s on s.id=v.source_id and s.owner_id=p_owner and s.withdrawn_at is null
     where rs.owner_id=p_owner and rs.result_id=(item->>'resultId')::uuid and v.id=x.value::uuid))
  then unavailable:=true; end if;
  if not exists(select 1 from public.context_documents d where d.id=(item->>'id')::uuid and d.owner_id=p_owner
   and d.current_result_id=(item->>'resultId')::uuid and d.revision=(item->>'version')::bigint)
  then superseded:=true; end if;
 end loop;
 return jsonb_build_object('id',saved.id,'created_at',saved.created_at,'purpose',saved.purpose,
  'state',case when unavailable then 'unavailable' else 'saved' end,
  'superseded',superseded,'brief',case when unavailable then null else saved.snapshot end);
end $$;

create function public.save_context_brief(p_owner uuid,p_key text,p_snapshot jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare ids uuid[]; req uuid; existing public.context_briefs; saved_id uuid;
 item jsonb; current_documents jsonb:='[]'::jsonb; expected_manifest jsonb;
begin
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$'
  or jsonb_typeof(p_snapshot) is distinct from 'object' or octet_length(p_snapshot::text)>1048576
  or jsonb_typeof(p_snapshot->'request_ids') is distinct from 'array'
  or jsonb_typeof(p_snapshot->'documents') is distinct from 'array'
  or jsonb_typeof(p_snapshot->'text') is distinct from 'string'
  or length(p_snapshot->>'text')>32000
  or coalesce(p_snapshot->>'purpose','') not in ('creative_direction','playlist_pitch')
  or p_snapshot->'input_manifest'->>'compilerVersion' is distinct from 'context-brief-v1'
  or p_snapshot->'input_manifest'->>'method' is distinct from 'saved_evidence_selection'
  or p_snapshot->'input_manifest'->'requestIds' is distinct from p_snapshot->'request_ids'
 then raise exception 'Invalid compiled brief'; end if;
 if jsonb_array_length(p_snapshot->'request_ids') not between 1 and 10
  or jsonb_array_length(p_snapshot->'documents')>256 then raise exception 'Invalid brief input count'; end if;
 select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_snapshot->'request_ids');
 if (select count(distinct x) from unnest(ids) x)<>cardinality(ids)
  or p_snapshot->>'request_id' is distinct from ids[1]::text then raise exception 'Invalid brief requests'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_owner::text||':brief:'||p_key,0));
 select * into existing from public.context_briefs where owner_id=p_owner and idempotency_key=p_key;
 if existing.id is not null then
  if existing.snapshot<>p_snapshot then raise exception 'Brief key already used for different output'; end if;
  return public.read_context_brief(p_owner,existing.id);
 end if;
 perform 1 from public.context_requests where owner_id=p_owner and id=any(ids) order by id for share;
 if (select count(*) from public.context_requests where owner_id=p_owner and id=any(ids)
  and status in ('completed','partial'))<>cardinality(ids) then raise exception 'Brief requests are unavailable'; end if;
 -- Use the same source-then-document lock order as evidence acceptance.
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 where v.owner_id=p_owner and v.id in (select x.value::uuid from jsonb_array_elements(p_snapshot->'documents') d,
  lateral jsonb_array_elements_text(d.value->'sourceVersionIds') x) order by s.id for share of s,v;
 perform 1 from public.context_documents where owner_id=p_owner and id in
  (select (value->>'id')::uuid from jsonb_array_elements(p_snapshot->'documents')) order by id for share;
 foreach req in array ids loop
  current_documents:=current_documents||public.read_context_documents(p_owner,req);
 end loop;
 if (select count(distinct value->>'id') from jsonb_array_elements(p_snapshot->'documents'))
  <>jsonb_array_length(p_snapshot->'documents') then raise exception 'Duplicate brief documents'; end if;
 for item in select value from jsonb_array_elements(p_snapshot->'documents') loop
  if not exists(select 1 from jsonb_array_elements(current_documents) d where d.value=item)
   or item->>'evidenceKind'='creative_proposal'
   or coalesce(item->>'coverage','') not in ('full','partial')
   or jsonb_typeof(item->'sourceVersionIds') is distinct from 'array'
  then raise exception 'Brief evidence changed or is unavailable'; end if;
  if jsonb_array_length(item->'sourceVersionIds')=0 then raise exception 'Brief evidence has no sources'; end if;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('documentId',value->'id','resultId',value->'resultId',
  'subjectId',value->'subjectId','topic',value->'topic','version',value->'version',
  'sourceVersionIds',value->'sourceVersionIds') order by ordinal),'[]'::jsonb) into expected_manifest
 from jsonb_array_elements(p_snapshot->'documents') with ordinality d(value,ordinal);
 if p_snapshot->'input_manifest'->'documents' is distinct from expected_manifest
 then raise exception 'Brief manifest does not match evidence'; end if;
 insert into public.context_briefs(owner_id,idempotency_key,request_ids,purpose,snapshot)
 values(p_owner,p_key,ids,p_snapshot->>'purpose',p_snapshot) returning id into saved_id;
 return public.read_context_brief(p_owner,saved_id);
end $$;
revoke all on function public.save_context_brief(uuid,text,jsonb),public.read_context_brief(uuid,uuid) from public,anon,authenticated;
grant execute on function public.save_context_brief(uuid,text,jsonb),public.read_context_brief(uuid,uuid) to service_role;
commit;
