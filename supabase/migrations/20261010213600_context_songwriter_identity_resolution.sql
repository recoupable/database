-- An operator may link one saved songwriter-name request to one explicitly selected
-- organization professional. The link is a scoped operator assertion recorded with
-- the request. No roster enrollment, new professional, name matching, enrichment,
-- login account, catalog right or mandate follows from it.
begin;
create table public.context_songwriter_identity_resolutions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id) on delete restrict,
  request_id uuid not null,
  subject_id uuid not null references public.context_subjects(id) on delete restrict,
  professional_id uuid not null references public.organization_professionals(id) on delete restrict,
  resolved_by uuid not null references public.accounts(id) on delete restrict,
  resolution_basis text not null default 'operator_confirmed' check (resolution_basis='operator_confirmed'),
  request_key text not null check (length(request_key) between 1 and 200),
  created_at timestamptz not null default now(),
  foreign key(request_id, owner_id) references public.context_requests(id, owner_id) on delete restrict,
  unique(owner_id, request_id),
  unique(owner_id, request_key)
);
create index context_songwriter_identity_resolutions_professional_idx
  on public.context_songwriter_identity_resolutions(professional_id);
alter table public.context_songwriter_identity_resolutions enable row level security;
revoke all on public.context_songwriter_identity_resolutions from public, anon, authenticated;
grant select, insert on public.context_songwriter_identity_resolutions to service_role;

-- Same readiness checks as before; only an explicit operator resolution confirms identity.
create or replace function public.list_context_songwriter_request_target(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject public.context_subjects; professional uuid;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') or req.input->>'kind'<>'songwriter'
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
  or jsonb_array_length(req.output->'subjectIds')<>1
 then raise exception 'Songwriter request is not ready'; end if;
 select s.* into strict subject from public.context_subjects s
 join public.context_resources r on r.id=s.resource_id and r.id=req.resource_id
  and r.provider='recoup' and r.resource_kind='songwriter_input'
 join public.context_documents d on d.owner_id=p_owner and d.subject_id=s.id and d.topic='songwriter_input'
 join public.context_results result on result.id=d.current_result_id and result.owner_id=p_owner
  and result.status='accepted' and result.evidence_kind='customer_assertion'
 where s.kind='songwriter' and req.output->'subjectIds' ? s.id::text
  and result.normalized_response->>'name'=req.input->>'name'
  and exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
   join public.context_sources source on source.id=v.source_id and source.owner_id=p_owner and source.withdrawn_at is null
   where rs.result_id=result.id and rs.owner_id=p_owner and source.kind='customer');
 select r.professional_id into professional from public.context_songwriter_identity_resolutions r
  where r.owner_id=p_owner and r.request_id=p_request and r.subject_id=subject.id;
 return jsonb_build_object('subjectId',subject.id,'kind','songwriter','identityConfirmed',professional is not null,
  'availableFields',jsonb_build_array('submitted_name'),'reusableModules','[]'::jsonb)
  || case when professional is null then '{}'::jsonb else jsonb_build_object('professionalId',professional) end;
end $$;
revoke all on function public.list_context_songwriter_request_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_songwriter_request_target(uuid,uuid) to service_role;

create function public.resolve_context_songwriter_identity(
 p_actor uuid,p_owner uuid,p_request uuid,p_professional uuid,p_key text
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare target jsonb; saved public.context_songwriter_identity_resolutions; receipt public.context_songwriter_identity_resolutions;
begin
 if p_actor is null or p_owner is null or p_request is null or p_professional is null
  or p_key is null or length(p_key) not between 1 and 200
 then raise exception 'Explicit request, professional and idempotency key required' using errcode='22023'; end if;
 -- Serialize retries per key and per request so parallel identical calls yield one receipt.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('context-songwriter-identity-key:'||p_owner::text||':'||p_key,0));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('context-songwriter-identity-request:'||p_owner::text||':'||p_request::text,0));
 if p_actor<>p_owner then
  perform 1 from public.account_organization_ids where account_id=p_actor and organization_id=p_owner for share;
  if not found then raise exception 'Organization access denied' using errcode='42501'; end if;
 end if;
 begin
  target:=public.list_context_songwriter_request_target(p_owner,p_request);
 exception when no_data_found or too_many_rows or raise_exception then
  raise exception 'Songwriter request is not ready for identity resolution' using errcode='22023';
 end;
 -- A professional outside this workspace is denied, never reported as missing.
 perform 1 from public.organization_professionals where id=p_professional and organization_id=p_owner for share;
 if not found then raise exception 'Professional is not in this organization' using errcode='42501'; end if;
 select * into saved from public.context_songwriter_identity_resolutions where owner_id=p_owner and request_id=p_request;
 if found then
  if saved.professional_id=p_professional and saved.request_key=p_key and saved.resolved_by=p_actor
  then return jsonb_build_object('resolution',to_jsonb(saved)-'owner_id'-'request_key','created',false); end if;
  -- Ambiguity is resolved explicitly once; a different selection is a conflict, not an overwrite.
  raise exception 'Songwriter request is already resolved' using errcode='23505';
 end if;
 if exists(select 1 from public.context_songwriter_identity_resolutions where owner_id=p_owner and request_key=p_key)
 then raise exception 'Request key already used for different input' using errcode='23505'; end if;
 -- Record the resolution with the request; submitted-name evidence, input and sources stay unchanged.
 update public.context_requests set
  output=coalesce(output,'{}'::jsonb)||jsonb_build_object('resolvedProfessionalId',p_professional,
   'gaps',coalesce((select jsonb_agg(gap) from jsonb_array_elements(
    case when jsonb_typeof(output->'gaps')='array' then output->'gaps' else '[]'::jsonb end) gap
    where gap<>to_jsonb('Songwriter identity not confirmed'::text)),'[]'::jsonb)),
  updated_at=now()
  where id=p_request and owner_id=p_owner;
 insert into public.context_songwriter_identity_resolutions(owner_id,request_id,subject_id,professional_id,resolved_by,request_key)
 values(p_owner,p_request,(target->>'subjectId')::uuid,p_professional,p_actor,p_key) returning * into receipt;
 return jsonb_build_object('resolution',to_jsonb(receipt)-'owner_id'-'request_key','created',true);
end $$;
revoke all on function public.resolve_context_songwriter_identity(uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.resolve_context_songwriter_identity(uuid,uuid,uuid,uuid,text) to service_role;
commit;
