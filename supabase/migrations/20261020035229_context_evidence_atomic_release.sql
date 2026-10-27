-- REVIEW-ONLY MCP METHOD: five schema changes plus one tool execution record.
-- Target godremdqwajrwazhbrue. apply_migration owns the transaction and generated version.
-- Preserve this exact query as the generated-version source file after authorized execution.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SET LOCAL idle_in_transaction_session_timeout='60s';
DO $recoup_mcp_release$
DECLARE
  installed integer;
  checked record;
  fn oid;
BEGIN
  IF current_database()<>'postgres' OR current_user<>'postgres' THEN
    RAISE EXCEPTION 'Release database/role mismatch';
  END IF;
  SELECT count(*) INTO installed FROM supabase_migrations.schema_migrations WHERE version IN ('20261009180000','20261009180001','20261009180002','20261009180003','20261009180004');
  IF installed=0 THEN
    -- The approved clean installer, including its guards and five records, is unchanged.
    EXECUTE $approved_install$DO $recoup_release$
DECLARE
  originals text[] := ARRAY[
$source0$-- Relevance links for retained evidence, not identity, rights or mandate approval.
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
$source0$,
$source1$-- Forward-only correction: preserve the initial migration already applied in preview.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
grant update(updated_at) on public.artist_organization_ids to service_role;
alter table public.context_evidence_attachments add column target_count integer;
-- Seal the existing canonical receipt payload, never reinterpret or repair it.
update public.context_evidence_attachments a set target_count=(
 select count(*) from public.context_evidence_attachment_targets t where t.attachment_id=a.id and t.owner_id=a.owner_id);
do $$
begin
 if exists(select 1 from public.context_evidence_attachments a where a.target_count not between 1 and 100 or
  a.fingerprint<>encode(sha256(convert_to(jsonb_build_object('version',a.source_version_id,'targets',
   (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('artist_id',artist_id,'professional_id',professional_id,
    'request_id',request_id,'subject_id',subject_id)) order by position)
    from public.context_evidence_attachment_targets where attachment_id=a.id and owner_id=a.owner_id))::text,'UTF8')),'hex'))
 then raise exception 'Inconsistent existing evidence receipt; review required' using errcode='23514'; end if;
end $$;
alter table public.context_evidence_attachments alter column target_count set not null;
alter table public.context_evidence_attachments add constraint context_evidence_target_count check(target_count between 1 and 100);
-- Every slot must be filled in the creation transaction. A receipt cannot be
-- committed with holes, nor appended after its fixed slots have been filled.
create function public.guard_context_evidence_target_slot()
returns trigger language plpgsql set search_path='' as $$
declare slots integer;
begin
 select target_count into slots from public.context_evidence_attachments where id=new.attachment_id and owner_id=new.owner_id;
 if slots is null or new.position>=slots then raise exception 'Evidence receipt target count' using errcode='23514'; end if;
 return new;
end $$;
create trigger context_evidence_target_slot before insert on public.context_evidence_attachment_targets
 for each row execute function public.guard_context_evidence_target_slot();
create function public.check_context_evidence_receipt_complete()
returns trigger language plpgsql set search_path='' as $$
begin
 if (select count(*) from public.context_evidence_attachment_targets where attachment_id=new.id and owner_id=new.owner_id)<>new.target_count
 then raise exception 'Evidence receipt target count' using errcode='23514'; end if;
 return new;
end $$;
create constraint trigger context_evidence_receipt_complete after insert on public.context_evidence_attachments
 deferrable initially deferred for each row execute function public.check_context_evidence_receipt_complete();
revoke all on function public.guard_context_evidence_target_slot(),public.check_context_evidence_receipt_complete() from public,anon,authenticated;
grant execute on function public.guard_context_evidence_target_slot(),public.check_context_evidence_receipt_complete() to service_role;

commit;
$source1$,
$source2$-- Validate typed targets and independent retained evidence access.
begin;
-- Exact shapes and UUIDs only. Caller order does not change replay identity.
create or replace function public.canonical_context_evidence_targets(p_targets jsonb)
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

create or replace function public.authorize_context_evidence_source(p_owner uuid,p_version uuid)
returns void language plpgsql set search_path='' as $$
begin
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 where v.id=p_version and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null for share of s,v;
 if not found then raise exception 'Evidence source unavailable' using errcode='42501'; end if;
end $$;

-- A global subject UUID never grants access. An owned request plus retained
-- accepted lineage is an independent historical path, even after roster removal.
-- Submitted company/writer candidates retain their original uncertainty.
create or replace function public.authorize_context_evidence_targets(p_owner uuid,p_targets jsonb)
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
$source2$,
$source3$-- Save/read immutable, version-specific relevance receipts.
begin;
create or replace function public.read_context_evidence_attachment(p_actor uuid,p_owner uuid,p_attachment uuid)
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
 if targets is null or jsonb_array_length(targets)<>saved.target_count or
  encode(sha256(convert_to(jsonb_build_object('version',saved.source_version_id,'targets',targets)::text,'UTF8')),'hex')<>saved.fingerprint
 then raise exception 'Evidence attachment unavailable' using errcode='42501'; end if;
 perform public.authorize_context_evidence_targets(p_owner,targets);
 return jsonb_build_object('id',saved.id,'owner_id',saved.owner_id,'actor_id',saved.actor_id,'source_version_id',saved.source_version_id,
  'created_at',saved.created_at,'targets',targets,'assertion','relevance_only','rights_verified',false,
  'policy_version','private-evidence-association-v1');
end $$;

create or replace function public.attach_context_evidence(p_actor uuid,p_owner uuid,p_version uuid,p_key text,p_targets jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare targets jsonb; fingerprint text; saved public.context_evidence_attachments;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$' then raise exception 'Invalid attachment key' using errcode='22023'; end if;
 targets:=public.canonical_context_evidence_targets(p_targets);
 perform public.authorize_context_evidence_source(p_owner,p_version);
 perform public.authorize_context_evidence_targets(p_owner,targets);
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('version',p_version,'targets',targets)::text,'UTF8')),'hex');
 insert into public.context_evidence_attachments(owner_id,actor_id,source_version_id,idempotency_key,fingerprint,target_count)
 values(p_owner,p_actor,p_version,p_key,fingerprint,jsonb_array_length(targets)) on conflict(owner_id,idempotency_key) do nothing returning * into saved;
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

revoke all on function public.read_context_evidence_attachment(uuid,uuid,uuid),public.attach_context_evidence(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.read_context_evidence_attachment(uuid,uuid,uuid),public.attach_context_evidence(uuid,uuid,uuid,text,jsonb) to service_role;
commit;
$source3$,
$source4$-- Scope-checked bounded receipt history, withholding inaccessible targets.
begin;
-- Version-scoped paging. Inaccessible target receipts are withheld, while the
-- cursor still advances over stored history so a page cannot loop indefinitely.
create or replace function public.list_context_evidence_attachments(p_actor uuid,p_owner uuid,p_version uuid,p_after uuid default null)
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

revoke all on function public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) to service_role;
commit;
$source4$
]::text[];
  bodies text[] := ARRAY[
$body0$-- Relevance links for retained evidence, not identity, rights or mandate approval.
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
$body0$,
$body1$-- Forward-only correction: preserve the initial migration already applied in preview.
set local lock_timeout='5s';
set local statement_timeout='30s';
grant update(updated_at) on public.artist_organization_ids to service_role;
alter table public.context_evidence_attachments add column target_count integer;
-- Seal the existing canonical receipt payload, never reinterpret or repair it.
update public.context_evidence_attachments a set target_count=(
 select count(*) from public.context_evidence_attachment_targets t where t.attachment_id=a.id and t.owner_id=a.owner_id);
do $$
begin
 if exists(select 1 from public.context_evidence_attachments a where a.target_count not between 1 and 100 or
  a.fingerprint<>encode(sha256(convert_to(jsonb_build_object('version',a.source_version_id,'targets',
   (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('artist_id',artist_id,'professional_id',professional_id,
    'request_id',request_id,'subject_id',subject_id)) order by position)
    from public.context_evidence_attachment_targets where attachment_id=a.id and owner_id=a.owner_id))::text,'UTF8')),'hex'))
 then raise exception 'Inconsistent existing evidence receipt; review required' using errcode='23514'; end if;
end $$;
alter table public.context_evidence_attachments alter column target_count set not null;
alter table public.context_evidence_attachments add constraint context_evidence_target_count check(target_count between 1 and 100);
-- Every slot must be filled in the creation transaction. A receipt cannot be
-- committed with holes, nor appended after its fixed slots have been filled.
create function public.guard_context_evidence_target_slot()
returns trigger language plpgsql set search_path='' as $$
declare slots integer;
begin
 select target_count into slots from public.context_evidence_attachments where id=new.attachment_id and owner_id=new.owner_id;
 if slots is null or new.position>=slots then raise exception 'Evidence receipt target count' using errcode='23514'; end if;
 return new;
end $$;
create trigger context_evidence_target_slot before insert on public.context_evidence_attachment_targets
 for each row execute function public.guard_context_evidence_target_slot();
create function public.check_context_evidence_receipt_complete()
returns trigger language plpgsql set search_path='' as $$
begin
 if (select count(*) from public.context_evidence_attachment_targets where attachment_id=new.id and owner_id=new.owner_id)<>new.target_count
 then raise exception 'Evidence receipt target count' using errcode='23514'; end if;
 return new;
end $$;
create constraint trigger context_evidence_receipt_complete after insert on public.context_evidence_attachments
 deferrable initially deferred for each row execute function public.check_context_evidence_receipt_complete();
revoke all on function public.guard_context_evidence_target_slot(),public.check_context_evidence_receipt_complete() from public,anon,authenticated;
grant execute on function public.guard_context_evidence_target_slot(),public.check_context_evidence_receipt_complete() to service_role;

$body1$,
$body2$-- Validate typed targets and independent retained evidence access.
-- Exact shapes and UUIDs only. Caller order does not change replay identity.
create or replace function public.canonical_context_evidence_targets(p_targets jsonb)
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

create or replace function public.authorize_context_evidence_source(p_owner uuid,p_version uuid)
returns void language plpgsql set search_path='' as $$
begin
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 where v.id=p_version and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null for share of s,v;
 if not found then raise exception 'Evidence source unavailable' using errcode='42501'; end if;
end $$;

-- A global subject UUID never grants access. An owned request plus retained
-- accepted lineage is an independent historical path, even after roster removal.
-- Submitted company/writer candidates retain their original uncertainty.
create or replace function public.authorize_context_evidence_targets(p_owner uuid,p_targets jsonb)
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
$body2$,
$body3$-- Save/read immutable, version-specific relevance receipts.
create or replace function public.read_context_evidence_attachment(p_actor uuid,p_owner uuid,p_attachment uuid)
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
 if targets is null or jsonb_array_length(targets)<>saved.target_count or
  encode(sha256(convert_to(jsonb_build_object('version',saved.source_version_id,'targets',targets)::text,'UTF8')),'hex')<>saved.fingerprint
 then raise exception 'Evidence attachment unavailable' using errcode='42501'; end if;
 perform public.authorize_context_evidence_targets(p_owner,targets);
 return jsonb_build_object('id',saved.id,'owner_id',saved.owner_id,'actor_id',saved.actor_id,'source_version_id',saved.source_version_id,
  'created_at',saved.created_at,'targets',targets,'assertion','relevance_only','rights_verified',false,
  'policy_version','private-evidence-association-v1');
end $$;

create or replace function public.attach_context_evidence(p_actor uuid,p_owner uuid,p_version uuid,p_key text,p_targets jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare targets jsonb; fingerprint text; saved public.context_evidence_attachments;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$' then raise exception 'Invalid attachment key' using errcode='22023'; end if;
 targets:=public.canonical_context_evidence_targets(p_targets);
 perform public.authorize_context_evidence_source(p_owner,p_version);
 perform public.authorize_context_evidence_targets(p_owner,targets);
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('version',p_version,'targets',targets)::text,'UTF8')),'hex');
 insert into public.context_evidence_attachments(owner_id,actor_id,source_version_id,idempotency_key,fingerprint,target_count)
 values(p_owner,p_actor,p_version,p_key,fingerprint,jsonb_array_length(targets)) on conflict(owner_id,idempotency_key) do nothing returning * into saved;
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

revoke all on function public.read_context_evidence_attachment(uuid,uuid,uuid),public.attach_context_evidence(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.read_context_evidence_attachment(uuid,uuid,uuid),public.attach_context_evidence(uuid,uuid,uuid,text,jsonb) to service_role;
$body3$,
$body4$-- Scope-checked bounded receipt history, withholding inaccessible targets.
-- Version-scoped paging. Inaccessible target receipts are withheld, while the
-- cursor still advances over stored history so a page cannot loop indefinitely.
create or replace function public.list_context_evidence_attachments(p_actor uuid,p_owner uuid,p_version uuid,p_after uuid default null)
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

revoke all on function public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_evidence_attachments(uuid,uuid,uuid,uuid) to service_role;
$body4$
]::text[];
  versions text[] := ARRAY[
$version0$20261009180000$version0$,
$version1$20261009180001$version1$,
$version2$20261009180002$version2$,
$version3$20261009180003$version3$,
$version4$20261009180004$version4$
]::text[];
  names text[] := ARRAY[
$name0$context_evidence_attachments$name0$,
$name1$context_evidence_receipt_seal$name1$,
$name2$context_evidence_authorization$name2$,
$name3$context_evidence_receipts$name3$,
$name4$context_evidence_list$name4$
]::text[];
  hashes text[] := ARRAY[
$hash0$e8da77af97583862fc7ae083deab57c17708c0520fe4cd781b1424a92c3db5e1$hash0$,
$hash1$6de9db119f8c3fca29376af6a52356a7c11b725114af9a34cc2294549de29662$hash1$,
$hash2$3a990094055ada83aaf62410d359d23848174df2dd396cf2c8e9c8317d763140$hash2$,
$hash3$30a25384bc726ef613ddafee16c9d76649d2b436033b5632dca42d3225ea84c4$hash3$,
$hash4$27518a7a42bd3e92d3d357dc06119e190fd2ffe14685e4dfa351b00c9eb9eef5$hash4$
]::text[];
  baseline jsonb;
  actual jsonb;
  checked record;
  fn oid;
  step integer;
BEGIN
  IF current_database()<>'postgres' OR current_user<>'postgres' THEN
    RAISE EXCEPTION 'Release database/role mismatch';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname IN
      ('context_evidence_attachments','context_evidence_attachment_targets'))
    OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname=ANY(ARRAY[
        'canonical_context_evidence_targets','authorize_context_evidence_source','authorize_context_evidence_targets','read_context_evidence_attachment','attach_context_evidence','list_context_evidence_attachments','guard_context_evidence_target_slot','check_context_evidence_receipt_complete'])) THEN
    RAISE EXCEPTION 'Fresh-install evidence objects required; stop and inspect';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='supabase_migrations' AND table_name='schema_migrations'
      AND ((column_name IN ('version','name') AND data_type='text')
        OR (column_name='statements' AND data_type='ARRAY' AND udt_name='_text')))<>3 THEN
    RAISE EXCEPTION 'Migration-history shape must be reviewed before release';
  END IF;
  IF EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations
      WHERE version IN ('20261009180000','20261009180001','20261009180002','20261009180003','20261009180004'))
    OR (SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version IN ('20261009190000','20261009193000','20261010010000','20261010035000','20261010040000','20261010060000','20261010060001','20261010060002','20261010060003','20261010060004','20261010100000','20261015230000','20261019200000'))<>13
    OR (SELECT max(version) FROM supabase_migrations.schema_migrations) IS DISTINCT FROM '20261019200000' THEN
    RAISE EXCEPTION 'Migration history changed; do not replay or repair automatically';
  END IF;
  IF NOT has_column_privilege('service_role','public.artist_organization_ids','updated_at','UPDATE') THEN
    RAISE EXCEPTION 'Previously verified membership-lock privilege changed';
  END IF;
  SELECT jsonb_object_agg(proname,encode(sha256(convert_to(pg_get_functiondef(oid),'UTF8')),'hex'))
    INTO baseline FROM pg_proc WHERE oid IN (
      'public.commit_spotify_context(uuid,uuid,uuid,jsonb)'::regprocedure,
      'public.save_context_brief(uuid,text,jsonb)'::regprocedure);

  FOR step IN 1..5 LOOP
    -- Reassert for every file; never rely on a preceding file's SET LOCAL.
    PERFORM set_config('lock_timeout','5s',true);
    PERFORM set_config('statement_timeout','30s',true);
    PERFORM set_config('idle_in_transaction_session_timeout','60s',true);
    IF encode(sha256(convert_to(originals[step],'UTF8')),'hex')<>hashes[step] THEN
      RAISE EXCEPTION 'Pinned source hash mismatch';
    END IF;
    EXECUTE bodies[step];
    -- Bookkeeping uses the existing Supabase ledger, after actual SQL success.
    -- It commits only with all five changes; this is not a repair/applied-state claim.
    INSERT INTO supabase_migrations.schema_migrations(version,name,statements)
      VALUES(versions[step],names[step],ARRAY[originals[step]]);
    RAISE NOTICE 'Prepared step % (%/5); not committed yet',versions[step],step;
  END LOOP;

  FOR checked IN SELECT * FROM (VALUES ('public.canonical_context_evidence_targets(jsonb)','75f3d9cbf75cc774ce164914c97e24d7334d3a6207b08ea81f02b004de57cc09'),
('public.authorize_context_evidence_source(uuid,uuid)','d1f1dd6ace296a05ad48d5b24aafdab8c886b8d07a47cff280d1d19ea6760f8b'),
('public.authorize_context_evidence_targets(uuid,jsonb)','11c326ab113f3d6fff372d3f6a678a261f1689eb31f05a319bed3ae68eaeeec2'),
('public.read_context_evidence_attachment(uuid,uuid,uuid)','7e19b905769bd1dbe4bfc1f53e2e0cf99ba5496667b79ba89f8ce9fe7286fb43'),
('public.attach_context_evidence(uuid,uuid,uuid,text,jsonb)','c8cd5faa93a62ae3e2a2d4ea5919cc9f7349935ca03bc1c9c6cbb430cb2c8589'),
('public.list_context_evidence_attachments(uuid,uuid,uuid,uuid)','3377c9b3c4d2b91b2ec401e6235ddf075eeb4906b24939acbaad2a0ac58a5c0a'),
('public.guard_context_evidence_target_slot()','d0b7abff3c29bb819cb1b5e5f6cabe2976e41e4f33055e1ebeabcdffdd49bc6a'),
('public.check_context_evidence_receipt_complete()','bc75f86456a7e6b612858f56d397ab5bafff863ccd079b66cc69e2c77c770ccf')) v(signature,body_hash) LOOP
    fn:=to_regprocedure(checked.signature);
    IF fn IS NULL OR NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid=fn AND NOT prosecdef
        AND encode(sha256(convert_to(prosrc,'UTF8')),'hex')=checked.body_hash
        AND proconfig @> ARRAY['search_path=""'])
      OR NOT has_function_privilege('service_role',fn,'EXECUTE')
      OR has_function_privilege('anon',fn,'EXECUTE')
      OR has_function_privilege('authenticated',fn,'EXECUTE') THEN
      RAISE EXCEPTION 'Evidence function/body/permission verification failed';
    END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM (VALUES('public.context_evidence_attachments'),
      ('public.context_evidence_attachment_targets')) t(name) WHERE
      NOT has_table_privilege('service_role',name,'SELECT')
      OR NOT has_table_privilege('service_role',name,'INSERT')
      OR has_table_privilege('service_role',name,'UPDATE,DELETE')
      OR has_table_privilege('anon',name,'SELECT,INSERT,UPDATE,DELETE')
      OR has_table_privilege('authenticated',name,'SELECT,INSERT,UPDATE,DELETE')) THEN
    RAISE EXCEPTION 'Evidence table permissions changed';
  END IF;
  SELECT jsonb_object_agg(proname,encode(sha256(convert_to(pg_get_functiondef(oid),'UTF8')),'hex'))
    INTO actual FROM pg_proc WHERE oid IN (
      'public.commit_spotify_context(uuid,uuid,uuid,jsonb)'::regprocedure,
      'public.save_context_brief(uuid,text,jsonb)'::regprocedure);
  IF actual IS DISTINCT FROM baseline OR (SELECT count(*) FROM jsonb_object_keys(actual))<>2
    OR NOT has_column_privilege('service_role','public.artist_organization_ids','updated_at','UPDATE') THEN
    RAISE EXCEPTION 'Existing Context definitions or lock privilege changed';
  END IF;
END
$recoup_release$;
$approved_install$;
    RETURN;
  END IF;
  IF installed<>5 THEN
    RAISE EXCEPTION 'Partial evidence history; stop without repair';
  END IF;
  -- Canonical replay may contain either the approved complete-file representation
  -- or the pinned CLI 2.22.6 parsed array. Neither representation is rewritten.
  IF EXISTS(SELECT 1 FROM (VALUES ('20261009180000','context_evidence_attachments','e8da77af97583862fc7ae083deab57c17708c0520fe4cd781b1424a92c3db5e1','70988a8e8502be15ee7468a459aceea9ec5633a87a702abf1c5cd9c1e6c521ff'),
('20261009180001','context_evidence_receipt_seal','6de9db119f8c3fca29376af6a52356a7c11b725114af9a34cc2294549de29662','48cecb816bee52fb38ac78cd3574dc60df5a5f7f3a1498c1d89b5852d3faa286'),
('20261009180002','context_evidence_authorization','3a990094055ada83aaf62410d359d23848174df2dd396cf2c8e9c8317d763140','4c947fe84e01c8935b38c9b464c1748680330d0332f6ea84e992be4985641f97'),
('20261009180003','context_evidence_receipts','30a25384bc726ef613ddafee16c9d76649d2b436033b5632dca42d3225ea84c4','18a668845ee3947c7323a991820a728f1cefff0f2fc36c8399f2733a996eb6b6'),
('20261009180004','context_evidence_list','27518a7a42bd3e92d3d357dc06119e190fd2ffe14685e4dfa351b00c9eb9eef5','59c4892fa4e028d7eefa2a9b1e47bca4d83a53dfc3d91b59c1e2502ebe862e12')) e(version,name,file_hash,array_hash)
    LEFT JOIN supabase_migrations.schema_migrations m ON m.version=e.version
    WHERE m.name IS DISTINCT FROM e.name OR NOT COALESCE(
      (cardinality(m.statements)=1 AND encode(sha256(convert_to(m.statements[1],'UTF8')),'hex')=e.file_hash)
      OR encode(sha256(convert_to(to_jsonb(m.statements)::text,'UTF8')),'hex')=e.array_hash,false))
    OR (SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version IN ('20261009190000','20261009193000','20261010010000','20261010035000','20261010040000','20261010060000','20261010060001','20261010060002','20261010060003','20261010060004','20261010100000','20261015230000','20261019200000'))<>13 THEN
    RAISE EXCEPTION 'Canonical evidence source history mismatch';
  END IF;
  FOR checked IN SELECT * FROM (VALUES ('public.canonical_context_evidence_targets(jsonb)','75f3d9cbf75cc774ce164914c97e24d7334d3a6207b08ea81f02b004de57cc09'),
('public.authorize_context_evidence_source(uuid,uuid)','d1f1dd6ace296a05ad48d5b24aafdab8c886b8d07a47cff280d1d19ea6760f8b'),
('public.authorize_context_evidence_targets(uuid,jsonb)','11c326ab113f3d6fff372d3f6a678a261f1689eb31f05a319bed3ae68eaeeec2'),
('public.read_context_evidence_attachment(uuid,uuid,uuid)','7e19b905769bd1dbe4bfc1f53e2e0cf99ba5496667b79ba89f8ce9fe7286fb43'),
('public.attach_context_evidence(uuid,uuid,uuid,text,jsonb)','c8cd5faa93a62ae3e2a2d4ea5919cc9f7349935ca03bc1c9c6cbb430cb2c8589'),
('public.list_context_evidence_attachments(uuid,uuid,uuid,uuid)','3377c9b3c4d2b91b2ec401e6235ddf075eeb4906b24939acbaad2a0ac58a5c0a'),
('public.guard_context_evidence_target_slot()','d0b7abff3c29bb819cb1b5e5f6cabe2976e41e4f33055e1ebeabcdffdd49bc6a'),
('public.check_context_evidence_receipt_complete()','bc75f86456a7e6b612858f56d397ab5bafff863ccd079b66cc69e2c77c770ccf')) v(signature,body_hash) LOOP
    fn:=to_regprocedure(checked.signature);
    IF fn IS NULL OR NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid=fn AND NOT prosecdef
        AND encode(sha256(convert_to(prosrc,'UTF8')),'hex')=checked.body_hash
        AND proconfig @> ARRAY['search_path=""'])
      OR NOT has_function_privilege('service_role',fn,'EXECUTE')
      OR has_function_privilege('anon',fn,'EXECUTE')
      OR has_function_privilege('authenticated',fn,'EXECUTE') THEN
      RAISE EXCEPTION 'Evidence function/body/permission verification failed';
    END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM (VALUES('public.context_evidence_attachments'),
      ('public.context_evidence_attachment_targets')) t(name) WHERE
      NOT has_table_privilege('service_role',name,'SELECT')
      OR NOT has_table_privilege('service_role',name,'INSERT')
      OR has_table_privilege('service_role',name,'UPDATE,DELETE')
      OR has_table_privilege('anon',name,'SELECT,INSERT,UPDATE,DELETE')
      OR has_table_privilege('authenticated',name,'SELECT,INSERT,UPDATE,DELETE')) THEN
    RAISE EXCEPTION 'Evidence table permissions changed';
  END IF;
  IF EXISTS(SELECT 1 FROM (VALUES('public.context_evidence_attachments'),
      ('public.context_evidence_attachment_targets')) t(name) LEFT JOIN pg_class c ON c.oid=to_regclass(t.name)
      WHERE c.oid IS NULL OR NOT c.relrowsecurity)
    OR NOT has_column_privilege('service_role','public.artist_organization_ids','updated_at','UPDATE') THEN
    RAISE EXCEPTION 'Canonical evidence table/lock state mismatch';
  END IF;
  RAISE NOTICE 'Canonical evidence replay verified; original history and schema unchanged';
END
$recoup_mcp_release$;
