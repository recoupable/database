-- INACTIVE PROPOSAL. Apply only to a disposable fixture, never through migration discovery.
-- No callable roles are granted here. fixture-grants.sql is synthetic test admission only.
begin;
do $$ begin
 if current_user in ('service_role','anon','authenticated') or pg_has_role('service_role',current_user,'MEMBER') then
  raise exception 'Proposal owner must be isolated from runtime roles';
 end if;
end $$;
create schema sites_evidence_proposal;
revoke all on schema sites_evidence_proposal from public, anon, authenticated, service_role;

create table sites_evidence_proposal.records (
 id uuid primary key default gen_random_uuid(),
 site_id uuid not null references public.sites(id) on delete cascade,
 owner_id uuid not null references public.accounts(id),
 revision integer not null check(revision >= 0),
 operation_key text not null check(operation_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 recorded_by_account_id uuid not null references public.accounts(id),
 recorded_at timestamptz not null default clock_timestamp(),
 candidate jsonb not null,
 candidate_canonical text not null,
 candidate_sha256 text not null check(candidate_sha256 ~ '^[a-f0-9]{64}$'),
 decision jsonb not null,
 review_canonical text,
 unique(site_id,owner_id,operation_key)
);
alter table sites_evidence_proposal.records enable row level security;
revoke all on sites_evidence_proposal.records from public,anon,authenticated,service_role;
alter table public.sites add column published_evidence_id uuid
 references sites_evidence_proposal.records(id) on delete set null;

-- Only deletion of the parent site purges retained evidence. Ordinary UPDATE/DELETE is denied.
create function sites_evidence_proposal.guard_record() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' and not exists(select 1 from public.sites where id=old.site_id) then return old; end if;
 raise exception 'Sites evidence is immutable' using errcode='42501';
end $$;
create trigger immutable_site_evidence before update or delete on sites_evidence_proposal.records
 for each row execute function sites_evidence_proposal.guard_record();

-- JSONB is not JSON.stringify. The trusted adapter supplies canonical UTF-8 text using
-- API hashSiteEvidence's sorting/serialization; SQL verifies its JSON meaning and byte digest.
-- This is a content binding, NOT independent renderer/reviewer or authentication execution.
create function sites_evidence_proposal.candidate_projection(p_candidate jsonb) returns jsonb
language sql immutable set search_path='' as $$
 select case when p_candidate ? 'production' then
  jsonb_set(p_candidate,'{production}',(p_candidate->'production')-'reviews'-'status')
 else p_candidate end
$$;

create function sites_evidence_proposal.journey_shape(p_journey jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare item jsonb; key text;
begin
 if jsonb_typeof(p_journey) is distinct from 'object' then return false; end if;
 foreach key in array array['releaseConnection','motivation','payoff'] loop
  if jsonb_typeof(p_journey->key) is distinct from 'string' or length(p_journey->>key)<20 then return false; end if;
 end loop;
 if jsonb_typeof(p_journey->'evidence') is distinct from 'array'
 or jsonb_array_length(p_journey->'evidence') not between 1 and 8 then return false; end if;
 for item in select value from jsonb_array_elements(p_journey->'evidence') loop
  if jsonb_typeof(item) is distinct from 'string' or length(item#>>'{}')<5 then return false; end if;
 end loop;
 if jsonb_typeof(p_journey->'capabilities') is distinct from 'array'
 or jsonb_array_length(p_journey->'capabilities')<1 then return false; end if;
 for item in select value from jsonb_array_elements(p_journey->'capabilities') loop
  if jsonb_typeof(item) is distinct from 'string' or item#>>'{}' not in
   ('browser-interaction','production-artwork','image-download','file-share') then return false; end if;
 end loop;
 if jsonb_typeof(p_journey->'steps') is distinct from 'array'
 or jsonb_array_length(p_journey->'steps') not between 3 and 16 then return false; end if;
 for item in select value from jsonb_array_elements(p_journey->'steps') loop
  if jsonb_typeof(item) is distinct from 'object'
   or jsonb_typeof(item->'action') is distinct from 'string' or item->>'action' not in ('click','fill','press','download','share')
   or jsonb_typeof(item->'target') is distinct from 'string' or length(item->>'target') not between 1 and 100
   or jsonb_typeof(item->'value') is distinct from 'string' or length(item->>'value')>200
   or jsonb_typeof(item->'expected') is distinct from 'string' or length(item->>'expected')>300
   or jsonb_typeof(item->'checkpoint') is distinct from 'string' or item->>'checkpoint' not in ('participate','result','delivery') then return false; end if;
  foreach key in array array['holdMs','waitMs'] loop
   if item ? key and (jsonb_typeof(item->key) is distinct from 'number'
    or (item->>key)::numeric<>trunc((item->>key)::numeric)
    or (item->>key)::numeric<0 or (item->>key)::numeric>case when key='holdMs' then 2000 else 20000 end) then return false; end if;
  end loop;
 end loop;
 return true;
exception when others then return false;
end $$;

-- Necessary persisted conditions matching API1260. Full API assessment must additionally
-- compare the actual candidate's document, executed journey and current runner digests.
create function sites_evidence_proposal.review_passes(p_review jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare v jsonb; item jsonb; key text; opening jsonb;
begin
 if jsonb_typeof(p_review) is distinct from 'object' or p_review->>'verdict' is distinct from 'pass'
 or p_review ? 'blocked' or jsonb_typeof(p_review->'summary') is distinct from 'string'
 or jsonb_typeof(p_review->'issues') is distinct from 'array' or jsonb_array_length(p_review->'issues')>12 then return false; end if;
 for item in select value from jsonb_array_elements(p_review->'issues') loop
  if jsonb_typeof(item) is distinct from 'object'
   or jsonb_typeof(item->'severity') is distinct from 'string' or item->>'severity' not in ('visual','minor')
   or jsonb_typeof(item->'module') is distinct from 'string' or item->>'module' not in ('assets','implementation')
   or jsonb_typeof(item->'detail') is distinct from 'string' or jsonb_typeof(item->'fix') is distinct from 'string' then return false; end if;
 end loop;
 v:=p_review->'verification';
 if jsonb_typeof(v) is distinct from 'object' or v->>'scope' is distinct from 'generated-experience'
 or v->>'humanApproval' is distinct from 'not-recorded' or v->>'nativeShareDelivery' is distinct from 'not-tested'
 or v->>'spotifyAuthentication' is distinct from 'not-tested'
 or jsonb_typeof(v->'evidence') is distinct from 'object' then return false; end if;
 foreach key in array array['sourceSha256','journeySha256','runnerSha256'] loop
  if jsonb_typeof(v->'evidence'->key) is distinct from 'string'
   or (v->'evidence'->>key) !~ '^[a-f0-9]{64}$' then return false; end if;
 end loop;
 if not sites_evidence_proposal.journey_shape(v->'journey') then return false; end if;
 if jsonb_typeof(v->'viewports') is distinct from 'array' or jsonb_array_length(v->'viewports')<>2 then return false; end if;
 if (select count(distinct value->>'name') from jsonb_array_elements(v->'viewports'))<>2 then return false; end if;
 for item in select value from jsonb_array_elements(v->'viewports') loop
  if jsonb_typeof(item) is distinct from 'object' or jsonb_typeof(item->'name') is distinct from 'string'
   or item->>'name' not in ('mobile','desktop') or item->'journeyPassed' is distinct from 'true'::jsonb
   or item->'errors' is distinct from '[]'::jsonb or item->'overflow' is distinct from 'false'::jsonb then return false; end if;
 end loop;
 if v ? 'opening' then
  opening:=v->'opening';
  if jsonb_typeof(opening) is distinct from 'object' or opening->>'verdict' is distinct from 'pass'
   or opening->'issues' is distinct from '[]'::jsonb or jsonb_typeof(opening->'summary') is distinct from 'string'
   or jsonb_typeof(opening->'observations') is distinct from 'array' or jsonb_array_length(opening->'observations')<>2 then return false; end if;
  for item in select value from jsonb_array_elements(opening->'observations') loop
   if jsonb_typeof(item) is distinct from 'object' or jsonb_typeof(item->'viewport') is distinct from 'string'
    or item->>'viewport' not in ('mobile','desktop') then return false; end if;
   foreach key in array array['invitation','firstAction','expectedResponse'] loop
    if jsonb_typeof(item->key) is distinct from 'string' then return false; end if;
   end loop;
  end loop;
 end if;
 return true;
exception when others then return false;
end $$;

-- Match ECMAScript trim whitespace for the API's explicit nonblank reason contract.
create function sites_evidence_proposal.explicit_override(p_decision jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
begin
 return coalesce(jsonb_typeof(p_decision)='object'
  and p_decision - array['kind','intent','reason']='{}'::jsonb
  and p_decision->>'kind'='override'
  and p_decision->>'intent'='publish-without-passed-review'
  and jsonb_typeof(p_decision->'reason')='string'
  and length(btrim(p_decision->>'reason', U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF')) between 1 and 2000,false);
exception when others then return false;
end $$;

create function sites_evidence_proposal.record_json(r sites_evidence_proposal.records) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('id',r.id,'siteId',r.site_id,'ownerId',r.owner_id,'revision',r.revision,
  'candidateSha256',r.candidate_sha256,'recordedByAccountId',r.recorded_by_account_id,
  'recordedAt',to_char(r.recorded_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) || r.decision
$$;

create function sites_evidence_proposal.record_evidence(
 p_actor uuid,p_owner uuid,p_site uuid,p_revision integer,p_key text,
 p_candidate jsonb,p_candidate_canonical text,p_candidate_sha text,p_decision jsonb,p_review_canonical text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.sites; r sites_evidence_proposal.records;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into s from public.sites where id=p_site and owner_id=p_owner for update;
 if s.id is null then raise exception 'Site unavailable' using errcode='42501'; end if;
 if p_revision is null or s.revision<>p_revision then raise exception 'Revision conflict' using errcode='40001'; end if;
 if p_key is null or p_key !~ '^[A-Za-z0-9._:-]{1,128}$' then raise exception 'Invalid operation key'; end if;
 if jsonb_typeof(p_candidate) is distinct from 'object' or octet_length(p_candidate::text)>1048576
 or jsonb_typeof(p_candidate#>'{design,experience}') is distinct from 'object'
 or jsonb_typeof(p_candidate#>'{design,experience,html}') is distinct from 'string' or length(p_candidate#>>'{design,experience,html}')=0
 or jsonb_typeof(p_candidate#>'{design,experience,css}') is distinct from 'string'
 or jsonb_typeof(p_candidate#>'{design,experience,javascript}') is distinct from 'string'
 or (p_candidate ? 'production' and jsonb_typeof(p_candidate->'production') is distinct from 'object') then raise exception 'Invalid candidate'; end if;
 if p_candidate_canonical is null or octet_length(p_candidate_canonical)>1048576
 or p_candidate_canonical::jsonb is distinct from sites_evidence_proposal.candidate_projection(p_candidate)
 or p_candidate_sha is null or p_candidate_sha !~ '^[a-f0-9]{64}$'
 or encode(sha256(convert_to(p_candidate_canonical,'UTF8')),'hex')<>p_candidate_sha then raise exception 'Candidate digest mismatch'; end if;
 if jsonb_typeof(p_decision) is distinct from 'object' or octet_length(p_decision::text)>1048576 then raise exception 'Invalid decision'; end if;
 if p_decision->>'kind'='review' then
  if p_decision - array['kind','review','reviewSha256'] <> '{}'::jsonb
   or jsonb_typeof(p_decision->'review') is distinct from 'object'
   or p_review_canonical is null or octet_length(p_review_canonical)>1048576
   or p_review_canonical::jsonb is distinct from p_decision->'review'
   or jsonb_typeof(p_decision->'reviewSha256') is distinct from 'string'
   or (p_decision->>'reviewSha256') !~ '^[a-f0-9]{64}$'
   or encode(sha256(convert_to(p_review_canonical,'UTF8')),'hex')<>p_decision->>'reviewSha256' then raise exception 'Report digest mismatch'; end if;
 elsif p_decision->>'kind'='override' then
  if p_review_canonical is not null or not sites_evidence_proposal.explicit_override(p_decision)
   then raise exception 'Explicit override required'; end if;
 else raise exception 'Invalid decision kind'; end if;
 select * into r from sites_evidence_proposal.records where site_id=p_site and owner_id=p_owner and operation_key=p_key;
 if r.id is not null then
  if r.revision<>p_revision or r.recorded_by_account_id<>p_actor or r.candidate<>p_candidate
   or r.candidate_canonical<>p_candidate_canonical or r.candidate_sha256<>p_candidate_sha
   or r.decision<>p_decision or r.review_canonical is distinct from p_review_canonical then raise exception 'Idempotency conflict' using errcode='23505'; end if;
  return sites_evidence_proposal.record_json(r);
 end if;
 insert into sites_evidence_proposal.records(site_id,owner_id,revision,operation_key,recorded_by_account_id,
  candidate,candidate_canonical,candidate_sha256,decision,review_canonical)
 values(p_site,p_owner,p_revision,p_key,p_actor,p_candidate,p_candidate_canonical,p_candidate_sha,p_decision,p_review_canonical) returning * into r;
 return sites_evidence_proposal.record_json(r);
end $$;

create function sites_evidence_proposal.read_evidence(p_actor uuid,p_owner uuid,p_site uuid,p_record uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r sites_evidence_proposal.records;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 perform 1 from public.sites where id=p_site and owner_id=p_owner for share;
 if not found then raise exception 'Site unavailable' using errcode='42501'; end if;
 select * into r from sites_evidence_proposal.records where id=p_record and site_id=p_site and owner_id=p_owner;
 if r.id is null then raise exception 'Evidence unavailable' using errcode='42501'; end if;
 return sites_evidence_proposal.record_json(r);
end $$;

-- Retained records remain bound to their original workspace, even while unpublished.
-- The trigger needs owner privilege only to inspect private record existence.
create function sites_evidence_proposal.guard_owner() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.owner_id is distinct from old.owner_id and exists(
  select 1 from sites_evidence_proposal.records where site_id=old.id
 ) then raise exception 'Evidence owner cannot change' using errcode='42501'; end if;
 return new;
end $$;
create trigger preserve_site_evidence_owner before update of owner_id on public.sites
 for each row execute function sites_evidence_proposal.guard_owner();

-- Legacy advisory writers can still publish/unpublish, but cannot claim evidence.
-- The schema owner is the trusted function owner, not the service caller or a settable GUC.
create function sites_evidence_proposal.guard_publication() returns trigger
language plpgsql set search_path='' as $$
declare trusted_owner name; r sites_evidence_proposal.records;
begin
 select pg_get_userbyid(nspowner) into trusted_owner from pg_catalog.pg_namespace where nspname='sites_evidence_proposal';
 if new.published_evidence_id is distinct from old.published_evidence_id and new.published_evidence_id is not null
  and current_user<>trusted_owner then raise exception 'Evidence pointer is server-owned' using errcode='42501'; end if;
 if new.published is null then new.published_evidence_id:=null;
 elsif current_user<>trusted_owner and
  (tg_argv[0]='publication' or new.artist_id is distinct from old.artist_id)
 then new.published_evidence_id:=null;
 end if;
 if new.published_evidence_id is not null and
  (new.published_evidence_id is distinct from old.published_evidence_id or new.published is distinct from old.published or new.published_at is distinct from old.published_at) then
  select * into r from sites_evidence_proposal.records where id=new.published_evidence_id and site_id=new.id and owner_id=new.owner_id;
  if r.id is null or r.candidate is distinct from new.published or r.revision<>new.revision then raise exception 'Evidence pointer mismatch'; end if;
 end if;
 return new;
end $$;
create trigger maintain_site_publication_evidence before insert or update of published,published_at,published_evidence_id on public.sites
 for each row execute function sites_evidence_proposal.guard_publication('publication');
create trigger maintain_site_artist_evidence before update of artist_id on public.sites
 for each row execute function sites_evidence_proposal.guard_publication('artist');

create function sites_evidence_proposal.publish_candidate(
 p_actor uuid,p_owner uuid,p_site uuid,p_revision integer,p_record uuid,p_candidate_sha text,p_expected_pointer uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.sites; r sites_evidence_proposal.records;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into s from public.sites where id=p_site and owner_id=p_owner for update;
 if s.id is null then raise exception 'Site unavailable' using errcode='42501'; end if;
 if p_revision is null or s.revision<>p_revision or s.published_evidence_id is distinct from p_expected_pointer then raise exception 'Publication conflict' using errcode='40001'; end if;
 select * into r from sites_evidence_proposal.records where id=p_record and site_id=p_site and owner_id=p_owner;
 if r.id is null or r.revision<>p_revision or p_candidate_sha is distinct from r.candidate_sha256 then raise exception 'Evidence conflict' using errcode='40001'; end if;
 if not coalesce(case r.decision->>'kind'
  when 'review' then sites_evidence_proposal.review_passes(r.decision->'review')
  when 'override' then sites_evidence_proposal.explicit_override(r.decision) and r.recorded_by_account_id=p_actor
  else false end,false) then raise exception 'Evidence not eligible' using errcode='42501'; end if;
 update public.sites set published=r.candidate,published_evidence_id=r.id,published_at=clock_timestamp(),updated_at=clock_timestamp()
 where id=p_site returning * into s;
 return jsonb_build_object('site',to_jsonb(s),'evidence',sites_evidence_proposal.record_json(r),'humanApproval','not-recorded');
end $$;

-- Functions are default-denied, including to service_role, until a separately reviewed admission.
do $$ declare f regprocedure; begin
 for f in select p.oid::regprocedure from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='sites_evidence_proposal' loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
 end loop;
end $$;
commit;
