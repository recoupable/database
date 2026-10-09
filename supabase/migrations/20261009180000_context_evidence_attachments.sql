-- Relevance links for retained evidence, not identity, rights or mandate approval.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

alter table public.organization_professionals add constraint organization_professionals_id_owner unique(id,organization_id);
create table public.context_evidence_attachments (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.accounts(id),
 actor_id uuid not null references public.accounts(id),
 source_version_id uuid not null,
 idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 fingerprint text not null check(fingerprint ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default now(),
 foreign key(source_version_id,owner_id) references public.context_source_versions(id,owner_id),
 unique(owner_id,idempotency_key), unique(id,owner_id)
);
create index context_evidence_attachments_version on public.context_evidence_attachments(owner_id,source_version_id,id);
create table public.context_evidence_attachment_targets (
 attachment_id uuid not null,
 owner_id uuid not null,
 position integer not null check(position between 0 and 99),
 artist_id uuid references public.accounts(id),
 professional_id uuid,
 request_id uuid,
 subject_id uuid references public.context_subjects(id),
 primary key(attachment_id,position),
 foreign key(attachment_id,owner_id) references public.context_evidence_attachments(id,owner_id),
 foreign key(professional_id,owner_id) references public.organization_professionals(id,organization_id),
 foreign key(request_id,owner_id) references public.context_requests(id,owner_id),
 check((artist_id is not null and professional_id is null and request_id is null and subject_id is null)
  or (professional_id is not null and artist_id is null and request_id is null and subject_id is null)
  or (request_id is not null and subject_id is not null and artist_id is null and professional_id is null))
);
alter table public.context_evidence_attachments enable row level security;
alter table public.context_evidence_attachment_targets enable row level security;
revoke all on public.context_evidence_attachments,public.context_evidence_attachment_targets from public,anon,authenticated,service_role;
grant select,insert on public.context_evidence_attachments,public.context_evidence_attachment_targets to service_role;

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

create function public.read_context_evidence_attachment(p_actor uuid,p_owner uuid,p_attachment uuid)
returns jsonb language plpgsql set search_path='' as $$
declare saved public.context_evidence_attachments; targets jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into saved from public.context_evidence_attachments where id=p_attachment and owner_id=p_owner;
 if saved.id is null then raise exception 'Evidence attachment unavailable' using errcode='42501'; end if;
 perform public.authorize_context_evidence_source(p_owner,saved.source_version_id);
 select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('artist_id',artist_id,'professional_id',professional_id,
  'request_id',request_id,'subject_id',subject_id)) order by position) into targets
 from public.context_evidence_attachment_targets where attachment_id=saved.id and owner_id=p_owner;
 if targets is null then raise exception 'Evidence attachment unavailable' using errcode='42501'; end if;
 perform public.authorize_context_evidence_targets(p_owner,targets);
 return jsonb_build_object('id',saved.id,'owner_id',saved.owner_id,'actor_id',saved.actor_id,'source_version_id',saved.source_version_id,
  'created_at',saved.created_at,'targets',targets,'assertion','relevance_only','rights_verified',false,
  'policy_version','private-evidence-association-v1');
end $$;

create function public.attach_context_evidence(p_actor uuid,p_owner uuid,p_version uuid,p_key text,p_targets jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare targets jsonb; fingerprint text; saved public.context_evidence_attachments;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$' then raise exception 'Invalid attachment key' using errcode='22023'; end if;
 targets:=public.canonical_context_evidence_targets(p_targets);
 perform public.authorize_context_evidence_source(p_owner,p_version);
 perform public.authorize_context_evidence_targets(p_owner,targets);
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('version',p_version,'targets',targets)::text,'UTF8')),'hex');
 insert into public.context_evidence_attachments(owner_id,actor_id,source_version_id,idempotency_key,fingerprint)
 values(p_owner,p_actor,p_version,p_key,fingerprint) on conflict(owner_id,idempotency_key) do nothing returning * into saved;
 if saved.id is not null then
  insert into public.context_evidence_attachment_targets(attachment_id,owner_id,position,artist_id,professional_id,request_id,subject_id)
  select saved.id,p_owner,ordinal-1,(value->>'artist_id')::uuid,(value->>'professional_id')::uuid,(value->>'request_id')::uuid,(value->>'subject_id')::uuid
  from jsonb_array_elements(targets) with ordinality t(value,ordinal);
 else
  select * into strict saved from public.context_evidence_attachments where owner_id=p_owner and idempotency_key=p_key;
  if saved.fingerprint<>fingerprint then raise exception 'Attachment key already used for different input' using errcode='22023'; end if;
 end if;
 return public.read_context_evidence_attachment(p_actor,p_owner,saved.id);
end $$;

-- Version-scoped paging. Inaccessible target receipts are withheld, while the
-- cursor still advances over stored history so a page cannot loop indefinitely.
create function public.list_context_evidence_attachments(p_actor uuid,p_owner uuid,p_version uuid,p_after uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare row public.context_evidence_attachments; items jsonb:='[]'; visited integer:=0; cursor_id uuid; more boolean:=false;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 perform public.authorize_context_evidence_source(p_owner,p_version);
 if p_after is not null and not exists(select 1 from public.context_evidence_attachments where id=p_after and owner_id=p_owner and source_version_id=p_version)
 then raise exception 'Invalid evidence cursor' using errcode='42501'; end if;
 for row in select * from public.context_evidence_attachments where owner_id=p_owner and source_version_id=p_version
  and (p_after is null or id>p_after) order by id limit 51 loop
  visited:=visited+1;
  if visited>50 then more:=true; exit; end if;
  cursor_id:=row.id;
  begin
   items:=items||jsonb_build_array(public.read_context_evidence_attachment(p_actor,p_owner,row.id));
  exception when insufficient_privilege then null; end;
 end loop;
 return jsonb_build_object('items',items,'next_id',case when more then cursor_id end,'has_more',more);
end $$;

revoke all on function public.canonical_context_evidence_targets(jsonb),public.authorize_context_evidence_source(uuid,uuid),
 public.authorize_context_evidence_targets(uuid,jsonb),public.read_context_evidence_attachment(uuid,uuid,uuid),
 public.attach_context_evidence(uuid,uuid,uuid,text,jsonb),public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.canonical_context_evidence_targets(jsonb),public.authorize_context_evidence_source(uuid,uuid),
 public.authorize_context_evidence_targets(uuid,jsonb),public.read_context_evidence_attachment(uuid,uuid,uuid),
 public.attach_context_evidence(uuid,uuid,uuid,text,jsonb),public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) to service_role;
commit;
