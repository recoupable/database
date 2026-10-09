-- Validate typed targets and independent retained evidence access.
begin;
-- Exact shapes and UUIDs only. Caller order does not change replay identity.
create function public.canonical_context_evidence_targets(p_targets jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare t jsonb; n integer; canonical jsonb; field text;
begin
 if jsonb_typeof(p_targets) is distinct from 'array' then raise exception 'Invalid evidence targets' using errcode='22023'; end if;
 if jsonb_array_length(p_targets) not between 1 and 100 then raise exception 'Invalid evidence targets' using errcode='22023'; end if;
 for t in select value from jsonb_array_elements(p_targets) loop
  if jsonb_typeof(t) is distinct from 'object' then raise exception 'Invalid evidence targets' using errcode='22023'; end if;
  select count(*) into n from jsonb_object_keys(t);
  if not ((n=1 and (t ? 'artist_id' or t ? 'professional_id')) or (n=2 and t ? 'request_id' and t ? 'subject_id'))
  then raise exception 'Invalid evidence targets' using errcode='22023'; end if;
  for field in select jsonb_object_keys(t) loop
   if jsonb_typeof(t->field) is distinct from 'string' or (t->>field) !~* '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
   then raise exception 'Invalid evidence targets' using errcode='22023'; end if;
   t:=jsonb_set(t,array[field],to_jsonb((t->>field)::uuid::text));
  end loop;
 end loop;
 select jsonb_agg(normalized order by normalized::text),count(distinct normalized) into canonical,n
 from (select jsonb_object_agg(key,to_jsonb(value::uuid::text)) normalized
  from jsonb_array_elements(p_targets) with ordinality a(target,ordinal)
  cross join lateral jsonb_each_text(target) e(key,value) group by ordinal) q;
 if n<>jsonb_array_length(p_targets) then raise exception 'Invalid evidence targets' using errcode='22023'; end if;
 return canonical;
end $$;

create function public.authorize_context_evidence_source(p_owner uuid,p_version uuid)
returns void language plpgsql set search_path='' as $$
begin
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 where v.id=p_version and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null for share of s,v;
 if not found then raise exception 'Evidence source unavailable' using errcode='42501'; end if;
end $$;

-- A global subject UUID never grants access. An owned request plus retained
-- accepted lineage is an independent historical path, even after roster removal.
-- Submitted company/writer candidates retain their original uncertainty.
create function public.authorize_context_evidence_targets(p_owner uuid,p_targets jsonb)
returns void language plpgsql set search_path='' as $$
declare t jsonb; accessible boolean;
begin
 for t in select value from jsonb_array_elements(p_targets) loop
  accessible:=false;
  if t ? 'artist_id' then
   perform 1 from public.account_artist_ids where account_id=p_owner and artist_id=(t->>'artist_id')::uuid for share;
   accessible:=found;
   perform 1 from public.artist_organization_ids where organization_id=p_owner and artist_id=(t->>'artist_id')::uuid for share;
   accessible:=accessible or found;
  elsif t ? 'professional_id' then
   perform 1 from public.organization_professionals where organization_id=p_owner and id=(t->>'professional_id')::uuid for share;
   accessible:=found;
  else
   -- Source locks precede request/result locks, consistent with withdrawal.
   perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
    join public.context_result_sources rs on rs.source_version_id=v.id and rs.owner_id=v.owner_id
    join public.context_results r on r.id=rs.result_id and r.owner_id=rs.owner_id
    join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id
    where a.request_id=(t->>'request_id')::uuid and r.subject_id=(t->>'subject_id')::uuid and r.owner_id=p_owner
    order by s.id,v.id for share of s,v;
   perform 1 from public.context_requests where owner_id=p_owner and id=(t->>'request_id')::uuid for share;
   perform 1 from public.context_results r join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id
    where r.owner_id=p_owner and a.request_id=(t->>'request_id')::uuid and r.subject_id=(t->>'subject_id')::uuid for share of r;
   select exists(select 1 from public.context_requests req join public.context_attempts a on a.request_id=req.id and a.owner_id=req.owner_id
    join public.context_results r on r.attempt_id=a.id and r.owner_id=a.owner_id
    where req.owner_id=p_owner and req.id=(t->>'request_id')::uuid and req.status in ('partial','completed')
     and jsonb_typeof(req.output->'subjectIds')='array' and req.output->'subjectIds' ? (t->>'subject_id')
     and r.subject_id=(t->>'subject_id')::uuid and r.status='accepted' and r.evidence_kind<>'creative_proposal'
     and exists(select 1 from public.context_result_sources rs where rs.result_id=r.id and rs.owner_id=p_owner)
     and not exists(select 1 from public.context_result_sources rs
      join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id
      join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
      where rs.result_id=r.id and rs.owner_id=p_owner and (v.removed_at is not null or s.withdrawn_at is not null))) into accessible;
  end if;
  if not accessible then raise exception 'Evidence target unavailable' using errcode='42501'; end if;
 end loop;
end $$;

revoke all on function public.canonical_context_evidence_targets(jsonb),public.authorize_context_evidence_source(uuid,uuid),public.authorize_context_evidence_targets(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.canonical_context_evidence_targets(jsonb),public.authorize_context_evidence_source(uuid,uuid),public.authorize_context_evidence_targets(uuid,jsonb) to service_role;
commit;
