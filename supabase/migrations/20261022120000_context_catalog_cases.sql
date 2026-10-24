-- Private portable catalog workpapers over existing Context source/access foundations.
-- These are customer assertions, never provider execution or a second rights ledger.
begin;
create table public.context_catalog_cases (
 id uuid primary key,
 owner_id uuid not null references public.accounts(id),
 created_by uuid not null references public.accounts(id),
 revision integer not null check(revision > 0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(id,owner_id)
);
create table public.context_catalog_case_revisions (
 case_id uuid not null,
 owner_id uuid not null,
 revision integer not null check(revision > 0),
 actor_id uuid not null references public.accounts(id),
 idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 input_fingerprint text not null check(input_fingerprint ~ '^[a-f0-9]{64}$'),
 snapshot jsonb not null check(jsonb_typeof(snapshot)='object' and octet_length(snapshot::text)<=1048576),
 created_at timestamptz not null default now(),
 primary key(case_id,revision),
 foreign key(case_id,owner_id) references public.context_catalog_cases(id,owner_id),
 unique(owner_id,idempotency_key)
);
create index context_catalog_cases_page on public.context_catalog_cases(owner_id,created_at desc,id desc);
alter table public.context_catalog_cases enable row level security;
alter table public.context_catalog_case_revisions enable row level security;
revoke all on public.context_catalog_cases,public.context_catalog_case_revisions from public,anon,authenticated,service_role;
grant select,insert on public.context_catalog_cases,public.context_catalog_case_revisions to service_role;
grant update(revision,updated_at) on public.context_catalog_cases to service_role;

create function public.validate_context_catalog_snapshot(p_owner uuid,p_case uuid,p_expected integer,p_snapshot jsonb)
returns void language plpgsql set search_path='' as $$
declare group_name text; item record; ref jsonb; source_row jsonb; linked uuid; actual integer; seen text[]:='{}';
begin
 if p_snapshot is null or jsonb_typeof(p_snapshot)<>'object' or octet_length(p_snapshot::text)>1048576
 or p_snapshot->>'schema_version' is distinct from '1' or p_snapshot->>'case_id' is distinct from p_case::text
 or p_snapshot->>'workspace_id' is distinct from p_owner::text or p_snapshot->>'revision' is distinct from p_expected::text
 or jsonb_typeof(p_snapshot->'scope') is distinct from 'string' or p_snapshot ? 'history'
 then raise exception 'Invalid catalog snapshot' using errcode='22023'; end if;
 if exists(select 1 from jsonb_object_keys(p_snapshot) k where k not in ('schema_version','case_id','workspace_id','revision','scope','sources','assessments','findings','actions','attempts','outcomes'))
 then raise exception 'Unsupported catalog snapshot field' using errcode='22023'; end if;
 -- Acquire every candidate and historical binding in the same global order before
 -- any per-record validation takes a source lock.
 perform 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
 where v.owner_id=p_owner and v.id in (
  select (x.value->>'context_source_version_id')::uuid from jsonb_each(coalesce(p_snapshot->'sources','{}')) x where x.value->>'context_source_version_id' is not null
  union
  select (x.value->>'context_source_version_id')::uuid from public.context_catalog_case_revisions r,
   lateral jsonb_each(r.snapshot->'sources') x where r.owner_id=p_owner and r.case_id=p_case and x.value->>'context_source_version_id' is not null
 ) order by s.id,v.id for share of s,v;
 foreach group_name in array array['sources','assessments','findings','actions','attempts','outcomes'] loop
  if jsonb_typeof(p_snapshot->group_name) is distinct from 'object' then raise exception 'Missing catalog collection' using errcode='22023'; end if;
  select count(*) into actual from jsonb_object_keys(p_snapshot->group_name);
  if actual>1000 then raise exception 'Catalog collection exceeds limit' using errcode='22023'; end if;
  for item in select * from jsonb_each(p_snapshot->group_name) loop
   if jsonb_typeof(item.value)<>'object' or item.value->>'id' is distinct from item.key or length(item.key)=0
    or item.value->>'withheld'='true' then raise exception 'Invalid catalog record' using errcode='22023'; end if;
   if item.key=any(seen) then raise exception 'Duplicate catalog record ID' using errcode='22023'; end if;
   seen:=array_append(seen,item.key);
   if item.value ? 'depends_on' and jsonb_typeof(item.value->'depends_on')<>'array' then raise exception 'Invalid record dependencies' using errcode='22023'; end if;
   if group_name='sources' then
    if coalesce(item.value->>'version','')='' or coalesce(item.value->>'sha256','') !~ '^[a-f0-9]{64}$'
     or item.value->>'status' is null or item.value->>'status' not in ('active','withdrawn') or not item.value ? 'locator'
    then raise exception 'Invalid catalog source' using errcode='22023'; end if;
    if exists(select 1 from public.context_catalog_case_revisions r where r.owner_id=p_owner and r.case_id=p_case
      and r.snapshot->'sources'->item.key->>'version'=item.value->>'version'
      and ((r.snapshot->'sources'->item.key->>'sha256' is distinct from item.value->>'sha256')
       or (r.snapshot->'sources'->item.key->>'context_source_version_id' is distinct from item.value->>'context_source_version_id')))
    then raise exception 'Source version binding is immutable' using errcode='22023'; end if;
   else
    if jsonb_typeof(item.value->'source_refs') is distinct from 'array' or coalesce(item.value->>'rule_version','')=''
    then raise exception 'Derived record requires versioned evidence' using errcode='22023'; end if;
    if jsonb_array_length(item.value->'source_refs')=0 and coalesce(item.value->>'evidence_gap','')=''
    then raise exception 'Empty evidence requires a gap' using errcode='22023'; end if;
    for ref in select * from jsonb_array_elements(item.value->'source_refs') loop
     source_row:=p_snapshot->'sources'->(ref->>'source_id');
     if source_row is null or ((source_row->>'version' is distinct from ref->>'version') and coalesce(item.value->>'stale','false')<>'true')
     then raise exception 'Unknown source reference' using errcode='22023'; end if;
     if source_row->>'version' is distinct from ref->>'version' then
      select r.snapshot->'sources'->(ref->>'source_id') into source_row
       from public.context_catalog_case_revisions r where r.owner_id=p_owner and r.case_id=p_case
       and r.snapshot->'sources'->(ref->>'source_id')->>'version'=ref->>'version' order by r.revision desc limit 1;
      if source_row is null then raise exception 'Historical source binding unavailable' using errcode='22023'; end if;
      if source_row->>'context_source_version_id' is not null then
       perform 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
        where v.id=(source_row->>'context_source_version_id')::uuid and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null for share of s,v;
       if not found then raise exception 'Catalog evidence unavailable' using errcode='42501'; end if;
      end if;
     end if;
    end loop;
   end if;
  end loop;
 end loop;
 -- Stable ordering matches existing Context source-before-derived-record locking.
 for linked in select distinct (value->>'context_source_version_id')::uuid from jsonb_each(p_snapshot->'sources')
  where value->>'context_source_version_id' is not null order by 1 loop
  perform 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
   where v.id=linked and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null for share of s,v;
  if not found then raise exception 'Catalog evidence unavailable' using errcode='42501'; end if;
 end loop;
end $$;

create function public.read_context_catalog_case(p_actor uuid,p_owner uuid,p_case uuid,p_revision integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare current_case public.context_catalog_cases; saved public.context_catalog_case_revisions;
 body jsonb; hidden text[]:='{}'; previous_count integer; group_name text; item record; linked uuid; invalid boolean; ref jsonb; binding jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into current_case from public.context_catalog_cases where id=p_case and owner_id=p_owner;
 if current_case.id is null then raise exception 'Catalog case unavailable' using errcode='42501'; end if;
 select * into saved from public.context_catalog_case_revisions where case_id=p_case and owner_id=p_owner and revision=coalesce(p_revision,current_case.revision);
 if saved.case_id is null then raise exception 'Catalog case unavailable' using errcode='42501'; end if;
 body:=saved.snapshot;
 -- Lock all retained source bindings in one order, including historical versions
 -- referenced by stale derivatives after a newer source version was imported.
 perform 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
 where v.owner_id=p_owner and v.id in (
  select (x.value->>'context_source_version_id')::uuid from public.context_catalog_case_revisions r,
   lateral jsonb_each(r.snapshot->'sources') x where r.owner_id=p_owner and r.case_id=p_case
   and x.value->>'context_source_version_id' is not null) order by s.id,v.id for share of s,v;
 for item in select * from jsonb_each(body->'sources') order by key loop
  linked:=(item.value->>'context_source_version_id')::uuid;
  if linked is not null then
   perform 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
    where v.id=linked and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null for share of s,v;
   if not found then
    hidden:=array_append(hidden,item.key);
    body:=jsonb_set(body,array['sources',item.key],jsonb_build_object('id',item.key,'version',item.value->>'version','status','withdrawn','withheld',true));
   end if;
  end if;
 end loop;
 loop
  previous_count:=cardinality(hidden);
  foreach group_name in array array['assessments','findings','actions','attempts','outcomes'] loop
   for item in select * from jsonb_each(body->group_name) loop
    if item.key=any(hidden) then continue; end if;
    invalid:=exists(select 1 from jsonb_array_elements(coalesce(item.value->'source_refs','[]')) referenced(value) where referenced.value->>'source_id'=any(hidden))
      or exists(select 1 from jsonb_array_elements_text(coalesce(item.value->'depends_on','[]')) dep where dep=any(hidden))
      or coalesce(item.value->>'action_id'=any(hidden),false);
    for ref in select * from jsonb_array_elements(coalesce(item.value->'source_refs','[]')) loop
     binding:=saved.snapshot->'sources'->(ref->>'source_id');
     if binding->>'version' is distinct from ref->>'version' then
      select r.snapshot->'sources'->(ref->>'source_id') into binding
       from public.context_catalog_case_revisions r where r.owner_id=p_owner and r.case_id=p_case
       and r.snapshot->'sources'->(ref->>'source_id')->>'version'=ref->>'version' order by r.revision desc limit 1;
     end if;
     if binding is null then invalid:=true;
     elsif binding->>'context_source_version_id' is not null then
      invalid:=invalid or not exists(select 1 from public.context_source_versions v join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id
       where v.id=(binding->>'context_source_version_id')::uuid and v.owner_id=p_owner and v.removed_at is null and s.withdrawn_at is null);
     end if;
    end loop;
    if invalid then
     hidden:=array_append(hidden,item.key);
     body:=jsonb_set(body,array[group_name,item.key],jsonb_build_object('id',item.key,'status',item.value->>'status','stale',true,'withheld',true));
    end if;
   end loop;
  end loop;
  exit when cardinality(hidden)=previous_count;
 end loop;
 return jsonb_build_object('case_id',p_case,'revision',saved.revision,'state',case when cardinality(hidden)>0 then 'partial' else 'saved' end,
  'evidence_kind','customer_assertion','snapshot',body,'withheld_record_ids',to_jsonb(hidden),
  'snapshot_usable_for_save',cardinality(hidden)=0,'external_actions','unsupported','created_at',saved.created_at);
end $$;

create function public.save_context_catalog_case(p_actor uuid,p_owner uuid,p_case uuid,p_expected_revision integer,p_key text,p_snapshot jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare current_case public.context_catalog_cases; saved public.context_catalog_case_revisions; digest text; next_revision integer;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_case is null or p_expected_revision is null or p_expected_revision<0 or p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$'
 then raise exception 'Invalid catalog case request' using errcode='22023'; end if;
 -- Fingerprint covers the exact input revision and artifact; replay does not create another revision.
 digest:=encode(sha256(convert_to(jsonb_build_object('case',p_case,'revision',p_expected_revision,'snapshot',p_snapshot)::text,'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(p_owner::text||':catalog-key:'||p_key,0));
 select * into saved from public.context_catalog_case_revisions where owner_id=p_owner and idempotency_key=p_key;
 if saved.case_id is not null then
  if saved.actor_id<>p_actor or saved.input_fingerprint<>digest then raise exception 'Catalog key reused for different input' using errcode='22023'; end if;
  return public.read_context_catalog_case(p_actor,p_owner,saved.case_id,saved.revision);
 end if;
 perform public.validate_context_catalog_snapshot(p_owner,p_case,p_expected_revision,p_snapshot);
 perform pg_advisory_xact_lock(hashtextextended(p_case::text||':catalog-case',0));
 select * into current_case from public.context_catalog_cases where id=p_case for update;
 if current_case.id is not null and current_case.owner_id<>p_owner then raise exception 'Catalog case unavailable' using errcode='42501'; end if;
 if coalesce(current_case.revision,0)<>p_expected_revision then raise exception 'Catalog revision conflict' using errcode='40001'; end if;
 next_revision:=p_expected_revision+1;
 if current_case.id is null then
  insert into public.context_catalog_cases(id,owner_id,created_by,revision) values(p_case,p_owner,p_actor,next_revision);
 else
  update public.context_catalog_cases set revision=next_revision,updated_at=clock_timestamp() where id=p_case and owner_id=p_owner;
 end if;
 insert into public.context_catalog_case_revisions(case_id,owner_id,revision,actor_id,idempotency_key,input_fingerprint,snapshot)
 values(p_case,p_owner,next_revision,p_actor,p_key,digest,jsonb_set(p_snapshot,'{revision}',to_jsonb(next_revision)));
 return public.read_context_catalog_case(p_actor,p_owner,p_case,next_revision);
end $$;

create function public.list_context_catalog_cases(p_actor uuid,p_owner uuid,p_after uuid default null,p_limit integer default 50)
returns jsonb language plpgsql set search_path='' as $$
declare cursor_row public.context_catalog_cases; items jsonb; more boolean;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 if p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid catalog page limit' using errcode='22023'; end if;
 if p_after is not null then
  select * into cursor_row from public.context_catalog_cases where id=p_after and owner_id=p_owner;
  if cursor_row.id is null then raise exception 'Catalog cursor unavailable' using errcode='42501'; end if;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('case_id',q.id,'revision',q.revision,'created_at',q.created_at,'updated_at',q.updated_at) order by q.created_at desc,q.id desc),'[]'::jsonb)
 into items from (select * from public.context_catalog_cases where owner_id=p_owner
  and (p_after is null or (created_at,id)<(cursor_row.created_at,cursor_row.id)) order by created_at desc,id desc limit p_limit+1) q;
 more:=jsonb_array_length(items)>p_limit;
 if more then items:=items-p_limit; end if;
 return jsonb_build_object('cases',items,'has_more',more,'next_id',case when more then items->(p_limit-1)->>'case_id' end);
end $$;

do $$ declare f text; begin
 foreach f in array array['validate_context_catalog_snapshot(uuid,uuid,integer,jsonb)',
 'save_context_catalog_case(uuid,uuid,uuid,integer,text,jsonb)','read_context_catalog_case(uuid,uuid,uuid,integer)',
 'list_context_catalog_cases(uuid,uuid,uuid,integer)'] loop
 execute 'revoke all on function public.'||f||' from public,anon,authenticated';
 execute 'grant execute on function public.'||f||' to service_role';
 end loop;
end $$;
commit;
