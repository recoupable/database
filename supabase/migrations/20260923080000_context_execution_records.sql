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
declare req public.context_requests; existing public.context_executions; node jsonb; keys text[]:='{}'; dep text;
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
 values(p_execution,p_owner,p_request,p_policy_version,p_plan) on conflict(id) do nothing;
 select * into strict existing from public.context_executions where id=p_execution;
 if existing.owner_id<>p_owner or existing.request_id<>p_request or existing.policy_version<>p_policy_version or existing.plan<>p_plan then raise exception 'Execution identity conflict'; end if;
 return to_jsonb(existing);
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
declare run public.context_executions; outcomes jsonb;
begin
 select * into strict run from public.context_executions where id=p_execution and owner_id=p_owner;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.node_key),'[]'::jsonb) into outcomes from public.context_execution_outcomes o where o.execution_id=p_execution and o.owner_id=p_owner;
 return to_jsonb(run)||jsonb_build_object('outcomes',outcomes);
end $$;
revoke all on function public.create_context_execution(uuid,uuid,uuid,text,jsonb),public.save_context_execution_outcome(uuid,uuid,text,jsonb),public.read_context_execution(uuid,uuid) from public,anon,authenticated;
grant execute on function public.create_context_execution(uuid,uuid,uuid,text,jsonb),public.save_context_execution_outcome(uuid,uuid,text,jsonb),public.read_context_execution(uuid,uuid) to service_role;
commit;
