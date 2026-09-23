-- Immutable server-built execution plans and per-node outcomes. This is trace
-- storage, not a spending grant, provider dispatch, or a replacement wallet.
begin;
create table public.context_executions (
 id uuid primary key,
 owner_id uuid not null,
 request_id uuid not null,
 policy_version text not null check(length(policy_version) between 1 and 100),
 plan jsonb not null check(jsonb_typeof(plan)='array' and jsonb_array_length(plan)<=100),
 created_at timestamptz not null default now(),
 unique(id,owner_id),
 foreign key(request_id,owner_id) references public.context_requests(id,owner_id)
);
create index context_executions_request on public.context_executions(owner_id,request_id,created_at);
create table public.context_execution_outcomes (
 execution_id uuid not null,
 owner_id uuid not null,
 node_key text not null,
 outcome jsonb not null,
 recorded_at timestamptz not null default now(),
 primary key(execution_id,node_key),
 foreign key(execution_id,owner_id) references public.context_executions(id,owner_id)
);
alter table public.context_executions enable row level security;
alter table public.context_execution_outcomes enable row level security;
revoke all on public.context_executions,public.context_execution_outcomes from public,anon,authenticated;
grant all on public.context_executions,public.context_execution_outcomes to service_role;

create function public.create_context_execution(p_owner uuid,p_request uuid,p_execution uuid,p_policy_version text,p_plan jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; existing public.context_executions; node jsonb; keys text[]:='{}'; dep text; inserted_id uuid;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') then raise exception 'Request is not ready for enrichment'; end if;
 if jsonb_typeof(p_plan) is distinct from 'array' then raise exception 'Invalid execution plan'; end if;
 if jsonb_array_length(p_plan)>100 or p_policy_version is null or length(p_policy_version) not between 1 and 100 then raise exception 'Invalid execution plan'; end if;
 for node in select value from jsonb_array_elements(p_plan) loop
  if jsonb_typeof(node) is distinct from 'object' or jsonb_typeof(node->'dependsOn') is distinct from 'array'
   or coalesce(node->>'state','') not in ('ready_for_dispatch','reuse_candidate','blocked','not_implemented')
   or coalesce(node->>'module','') !~ '^[a-z][a-z0-9_]{0,99}$'
   or node->>'key' is distinct from ((node->>'subjectId')||':'||(node->>'module'))
   or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
   or (req.output->'subjectIds' ? (node->>'subjectId')) is not true
   or node->>'key'=any(keys) then raise exception 'Invalid execution node'; end if;
  keys:=array_append(keys,node->>'key');
 end loop;
 -- Graph ordering/cycle validation remains the server planner's responsibility.
 for node in select value from jsonb_array_elements(p_plan) loop
  for dep in select jsonb_array_elements_text(node->'dependsOn') loop
   if dep is null or not (dep=any(keys)) or dep=node->>'key' then raise exception 'Invalid execution dependency'; end if;
  end loop;
 end loop;
 insert into public.context_executions(id,owner_id,request_id,policy_version,plan)
 values(p_execution,p_owner,p_request,p_policy_version,p_plan) on conflict(id) do nothing returning id into inserted_id;
 select * into strict existing from public.context_executions where id=p_execution;
 if existing.owner_id<>p_owner or existing.request_id<>p_request or existing.policy_version<>p_policy_version or existing.plan<>p_plan then raise exception 'Execution identity conflict'; end if;
 -- A replay may inspect the record, but must not dispatch the same provider work again.
 return to_jsonb(existing)||jsonb_build_object('created',inserted_id is not null);
end $$;

create function public.save_context_execution_outcome(p_owner uuid,p_execution uuid,p_node_key text,p_outcome jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare run public.context_executions; node jsonb; existing public.context_execution_outcomes;
begin
 select * into strict run from public.context_executions where id=p_execution and owner_id=p_owner;
 select value into node from jsonb_array_elements(run.plan) where value->>'key'=p_node_key;
 if node is null then raise exception 'Unknown execution node'; end if;
 if jsonb_typeof(p_outcome) is distinct from 'object' or coalesce(p_outcome->>'status','') not in ('saved','reused','failed','blocked') then raise exception 'Invalid execution outcome'; end if;
 -- A success trace must refer to evidence saved for this owner and subject.
 if p_outcome->>'status' in ('saved','reused') and not exists(
  select 1 from public.context_results r where r.id::text=p_outcome->'receipt'->>'resultId'
   and r.owner_id=p_owner and r.subject_id::text=node->>'subjectId'
   and node->>'state' in ('ready_for_dispatch','reuse_candidate')
   and r.topic=case node->>'module' when 'musicbrainz' then 'musicbrainz_recordings' when 'mlc_recording' then 'mlc_recordings' when 'spotify_release' then 'spotify_release_context' end
 ) then raise exception 'Execution evidence does not match node'; end if;
 insert into public.context_execution_outcomes(execution_id,owner_id,node_key,outcome)
 values(p_execution,p_owner,p_node_key,p_outcome) on conflict(execution_id,node_key) do nothing;
 select * into strict existing from public.context_execution_outcomes where execution_id=p_execution and node_key=p_node_key;
 if existing.outcome<>p_outcome then raise exception 'Execution outcome conflict'; end if;
 return to_jsonb(existing);
end $$;

create function public.read_context_execution(p_owner uuid,p_execution uuid)
returns jsonb language plpgsql set search_path='' as $$
declare run public.context_executions; outcomes jsonb; claims jsonb;
begin
 select * into strict run from public.context_executions where id=p_execution and owner_id=p_owner;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.node_key),'[]'::jsonb) into outcomes from public.context_execution_outcomes o where o.execution_id=p_execution and o.owner_id=p_owner;
 -- A claim without an outcome is uncertain. Expose that state to the authorized reader without raw provider data.
 select coalesce(jsonb_agg(jsonb_build_object('nodeKey',c.node_key,'claimedAt',c.claimed_at,
  'state',coalesce(o.outcome->>'status','unknown')) order by c.claimed_at,c.node_key),'[]'::jsonb)
 into claims from public.context_execution_node_claims c
 left join public.context_execution_outcomes o on o.execution_id=c.execution_id and o.owner_id=c.owner_id and o.node_key=c.node_key
 where c.execution_id=p_execution and c.owner_id=p_owner;
 return to_jsonb(run)||jsonb_build_object('outcomes',outcomes,'claims',claims);
end $$;
revoke all on function public.create_context_execution(uuid,uuid,uuid,text,jsonb),public.save_context_execution_outcome(uuid,uuid,text,jsonb),public.read_context_execution(uuid,uuid) from public,anon,authenticated;
grant execute on function public.create_context_execution(uuid,uuid,uuid,text,jsonb),public.save_context_execution_outcome(uuid,uuid,text,jsonb),public.read_context_execution(uuid,uuid) to service_role;

-- One durable claim per runnable node. An uncertain claim never expires into an automatic retry.
create table public.context_execution_node_claims (
 id uuid primary key default gen_random_uuid(),
 execution_id uuid not null,
 owner_id uuid not null,
 node_key text not null,
 claimed_at timestamptz not null default now(),
 unique(execution_id,node_key),
 foreign key(execution_id,owner_id) references public.context_executions(id,owner_id)
);
alter table public.context_execution_node_claims enable row level security;
revoke all on public.context_execution_node_claims from public,anon,authenticated;
grant all on public.context_execution_node_claims to service_role;

create function public.claim_context_execution_node(p_owner uuid,p_execution uuid,p_node_key text)
returns jsonb language plpgsql set search_path='' as $$
declare run public.context_executions; req public.context_requests; node jsonb; dep text; inserted uuid; existing public.context_execution_node_claims;
begin
 select * into strict run from public.context_executions where id=p_execution and owner_id=p_owner;
 select * into strict req from public.context_requests where id=run.request_id and owner_id=p_owner for share;
 if req.status not in ('partial','completed') then raise exception 'Request is not ready for enrichment'; end if;
 select value into node from jsonb_array_elements(run.plan) where value->>'key'=p_node_key;
 if node is null then raise exception 'Unknown execution node'; end if;
 if jsonb_typeof(req.output->'subjectIds') is distinct from 'array' or (req.output->'subjectIds' ? (node->>'subjectId')) is not true then raise exception 'Execution subject no longer in request'; end if;
 if node->>'state' not in ('ready_for_dispatch','reuse_candidate') then raise exception 'Execution node is not runnable'; end if;
 -- An outcome from an older run format is never permission for a new provider call.
 if exists(select 1 from public.context_execution_outcomes where execution_id=p_execution and owner_id=p_owner and node_key=p_node_key)
 then return jsonb_build_object('state','unknown'); end if;
 for dep in select jsonb_array_elements_text(node->'dependsOn') loop
  if not exists(select 1 from public.context_execution_outcomes o where o.execution_id=p_execution and o.owner_id=p_owner
    and o.node_key=dep and o.outcome->>'status' in ('saved','reused'))
  then raise exception 'Execution prerequisites not complete'; end if;
 end loop;
 insert into public.context_execution_node_claims(execution_id,owner_id,node_key)
 values(p_execution,p_owner,p_node_key) on conflict(execution_id,node_key) do nothing returning id into inserted;
 select * into strict existing from public.context_execution_node_claims where execution_id=p_execution and node_key=p_node_key;
 return jsonb_build_object('state',case when inserted is not null then 'claimed' else 'unknown' end,'claimId',existing.id);
end $$;
revoke all on function public.claim_context_execution_node(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.claim_context_execution_node(uuid,uuid,text) to service_role;

-- Only the service can turn a saved request into planner targets. The request's
-- subject order is preserved, but identity is independently checked per subject.
create function public.list_context_request_targets(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; targets jsonb; expected_count integer;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') then raise exception 'Request is not ready for enrichment'; end if;
 if jsonb_typeof(req.output->'subjectIds') is distinct from 'array' then raise exception 'Request has no subject list'; end if;
 expected_count:=jsonb_array_length(req.output->'subjectIds');
 if expected_count>100 then raise exception 'Request has too many subjects'; end if;
 if exists(select 1 from jsonb_array_elements_text(req.output->'subjectIds') id where id.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
 then raise exception 'Context request has missing subjects'; end if;
 with ordered as (
  select id.value::uuid as subject_id,id.ordinality as position
  from jsonb_array_elements_text(req.output->'subjectIds') with ordinality as id(value,ordinality)
 ), verified as (
  select ordered.position,s.id,s.kind,s.song_isrc,s.artist_id,s.resource_id,
   exists(select 1 from public.context_resource_links l
    join public.context_resources r on r.id=l.resource_id
    where l.subject_id=s.id and l.resource_id=req.resource_id
      and l.relation='identity' and l.status='accepted'
      and r.provider='spotify' and r.resource_kind='track') as track_identity,
   exists(select 1 from public.context_resource_links l
    join public.context_resources r on r.id=l.resource_id
    where l.subject_id=s.id and l.resource_id=req.resource_id
      and l.relation='release_member' and l.status='accepted'
      and r.provider='spotify' and r.resource_kind='track') as release_member,
   exists(select 1 from public.context_resource_links l
    join public.context_resources r on r.id=l.resource_id
    where l.subject_id=s.id and l.relation='identity' and l.status='accepted'
      and r.provider='spotify' and r.resource_kind='artist'
      and exists(select 1 from public.context_resource_links credit
       where credit.resource_id=req.resource_id and credit.subject_id=s.id
        and credit.relation='credited_artist' and credit.status='accepted')) as artist_identity,
   exists(select 1 from public.context_resources r where r.id=s.resource_id
      and r.provider='spotify' and r.resource_kind='release') as canonical_release,
   exists(select 1 from public.account_catalogs ac
    join public.context_resources r on r.id=req.resource_id
    where ac.account=p_owner and ac.catalog=s.catalog_id and r.provider='recoup'
     and r.resource_kind='catalog' and r.provider_id=s.catalog_id::text) as catalog_access
  from ordered left join public.context_subjects s on s.id=ordered.subject_id
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'subjectId',id,'kind',kind,
  'identityConfirmed',case kind
   when 'recording' then song_isrc is not null and track_identity
   when 'release' then canonical_release and release_member
   when 'artist' then artist_id is not null and artist_identity
   when 'catalog' then catalog_access
   else false end,
  'availableFields',case
   when kind='recording' and song_isrc is not null and track_identity then jsonb_build_array('isrc','spotify_id')
   when kind='recording' and song_isrc is not null then jsonb_build_array('isrc')
   when kind='release' and canonical_release and release_member then jsonb_build_array('spotify_id')
   when kind='artist' and artist_identity then jsonb_build_array('spotify_id')
   when kind='catalog' and catalog_access then jsonb_build_array('catalog_account_link')
   else '[]'::jsonb end,
  'reusableModules','[]'::jsonb
 ) order by position),'[]'::jsonb) into targets from verified;
 if jsonb_array_length(targets)<>expected_count or exists(select 1 from jsonb_array_elements(targets) t where t->'subjectId'='null'::jsonb)
 then raise exception 'Context request has missing subjects'; end if;
 return targets;
end $$;
revoke all on function public.list_context_request_targets(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_request_targets(uuid,uuid) to service_role;
commit;
