-- Additive Context Engine foundation. Access is through authenticated API domain
-- operations, not browser Supabase clients. No existing identities are rewritten.
begin;

create table public.context_resources (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('spotify', 'youtube')),
  resource_kind text not null check (resource_kind in ('artist', 'track', 'release', 'video')),
  provider_id text collate "C" not null check (length(provider_id) between 1 and 256),
  canonical_url text not null,
  created_at timestamptz not null default now(),
  unique(provider, resource_kind, provider_id)
);

create table public.context_subjects (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('artist', 'recording', 'release', 'video')),
  artist_id uuid references public.accounts(id) on delete restrict,
  song_isrc text references public.songs(isrc) on delete restrict,
  resource_id uuid references public.context_resources(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (
    (kind = 'artist' and artist_id is not null and song_isrc is null and resource_id is null) or
    (kind = 'recording' and song_isrc is not null and artist_id is null and resource_id is null) or
    (kind in ('release','video') and resource_id is not null and artist_id is null and song_isrc is null)
  ),
  unique(artist_id), unique(song_isrc), unique(resource_id)
);

-- Candidate/conflicting evidence does not become an accepted identity implicitly.
create table public.context_resource_links (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.context_resources(id) on delete restrict,
  subject_id uuid not null references public.context_subjects(id) on delete restrict,
  relation text not null check (relation in ('identity','release_member','credited_artist')),
  status text not null check (status in ('candidate','accepted','conflict','rejected')),
  evidence jsonb not null default '{}',
  credit_role text,
  credit_order integer check (credit_order >= 0),
  created_at timestamptz not null default now(),
  unique(resource_id, subject_id, relation)
);
create unique index context_one_accepted_identity on public.context_resource_links(resource_id)
  where relation = 'identity' and status = 'accepted';
create index context_resource_links_subject_idx on public.context_resource_links(subject_id);

create table public.context_requests (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id) on delete restrict,
  created_by uuid not null references public.accounts(id) on delete restrict,
  resource_id uuid not null references public.context_resources(id) on delete restrict,
  idempotency_key text not null check (length(idempotency_key) between 1 and 128),
  input_fingerprint text not null check (length(input_fingerprint) = 64),
  input jsonb not null,
  status text not null default 'queued' check (status in ('queued','running','partial','completed','failed','cancelled')),
  workflow_id text,
  revision bigint not null default 0 check (revision >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, idempotency_key), unique(id, owner_id)
);
create index context_requests_owner_idx on public.context_requests(owner_id, created_at desc);

create table public.context_sources (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id) on delete restrict,
  source_url text,
  kind text not null check (kind in ('provider_metadata','audio','lyrics','artwork','web','social','customer')),
  withdrawn_at timestamptz,
  created_at timestamptz not null default now(),
  unique(id, owner_id)
);
create index context_sources_owner_idx on public.context_sources(owner_id);

create table public.context_source_versions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  source_id uuid not null,
  fingerprint text not null check (length(fingerprint) = 64),
  content jsonb,
  storage_path text,
  media_manifest jsonb not null default '{}',
  published_at timestamptz,
  event_at timestamptz,
  date_precision text not null default 'unknown' check (date_precision in ('unknown','year','month','day','instant')),
  retrieved_at timestamptz not null default now(),
  removed_at timestamptz,
  foreign key(source_id, owner_id) references public.context_sources(id, owner_id) on delete restrict,
  unique(source_id, fingerprint), unique(id, owner_id)
);
create index context_source_versions_owner_idx on public.context_source_versions(owner_id);

create table public.context_attempts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  request_id uuid not null,
  module text not null,
  attempt integer not null check (attempt > 0),
  status text not null check (status in ('queued','running','succeeded','failed','cancelled','unknown')),
  provider text,
  model text,
  recipe_version text not null,
  schema_version text not null,
  provider_request_id text,
  trace_storage_path text,
  provider_cost_micros bigint check (provider_cost_micros >= 0),
  provider_cost_status text not null default 'unknown' check (provider_cost_status in ('unknown','estimated','confirmed')),
  settlement_reference text,
  started_at timestamptz,
  finished_at timestamptz,
  foreign key(request_id, owner_id) references public.context_requests(id, owner_id) on delete restrict,
  unique(request_id, module, attempt), unique(id, owner_id),
  check (provider_cost_status = 'unknown' or provider_cost_micros is not null)
);
create index context_attempts_owner_idx on public.context_attempts(owner_id);

create table public.context_results (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  attempt_id uuid not null,
  subject_id uuid not null references public.context_subjects(id) on delete restrict,
  topic text not null,
  reuse_key text not null check (length(reuse_key) = 64),
  status text not null check (status in ('fetched','invalid','partial','accepted','unavailable','failed','stale','withdrawn')),
  evidence_kind text not null check (evidence_kind in ('observation','estimate','interpretation','customer_assertion','creative_proposal')),
  raw_response jsonb,
  normalized_response jsonb,
  coverage jsonb not null,
  validation jsonb not null default '{}',
  created_at timestamptz not null default now(),
  foreign key(attempt_id, owner_id) references public.context_attempts(id, owner_id) on delete restrict,
  unique(id, owner_id),
  unique(id, owner_id, subject_id, topic),
  check (status <> 'accepted' or normalized_response is not null)
);
create index context_results_reuse_idx on public.context_results(owner_id, reuse_key) where status = 'accepted';
create index context_results_subject_idx on public.context_results(subject_id);
create index context_results_attempt_idx on public.context_results(attempt_id, owner_id);

create table public.context_result_sources (
  owner_id uuid not null,
  result_id uuid not null,
  source_version_id uuid not null,
  primary key(result_id, source_version_id),
  foreign key(result_id, owner_id) references public.context_results(id, owner_id) on delete restrict,
  foreign key(source_version_id, owner_id) references public.context_source_versions(id, owner_id) on delete restrict
);
create index context_result_sources_source_idx on public.context_result_sources(source_version_id, owner_id);

create table public.context_documents (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id) on delete restrict,
  subject_id uuid not null references public.context_subjects(id) on delete restrict,
  topic text not null,
  revision bigint not null default 0 check (revision >= 0),
  current_result_id uuid,
  updated_at timestamptz not null default now(),
  unique(owner_id, subject_id, topic),
  foreign key(current_result_id, owner_id, subject_id, topic)
    references public.context_results(id, owner_id, subject_id, topic) on delete restrict
);
create index context_documents_subject_idx on public.context_documents(subject_id);
create index context_documents_result_idx on public.context_documents(current_result_id, owner_id);

-- The caller supplies the revision it read before doing paid work. A late result
-- cannot replace a correction or a newer result. Only accepted factual context
-- with live source lineage may become current.
create function public.accept_context_result(p_owner uuid, p_document uuid, p_result uuid, p_revision bigint)
returns boolean language plpgsql set search_path = '' as $$
declare changed integer;
begin
  perform 1 from public.context_sources s
    join public.context_source_versions v on v.source_id = s.id and v.owner_id = s.owner_id
    join public.context_result_sources rs on rs.source_version_id = v.id and rs.owner_id = v.owner_id
    where rs.result_id = p_result and rs.owner_id = p_owner
    order by s.id for share of s, v;
  update public.context_documents d
  set current_result_id = r.id, revision = d.revision + 1, updated_at = now()
  from public.context_results r
  where d.id = p_document and d.owner_id = p_owner and d.revision = p_revision
    and r.id = p_result and r.owner_id = d.owner_id and r.subject_id = d.subject_id and r.topic = d.topic
    and r.status = 'accepted' and r.evidence_kind <> 'creative_proposal'
    and exists(select 1 from public.context_result_sources rs where rs.result_id = r.id and rs.owner_id = p_owner)
    and not exists(
      select 1 from public.context_result_sources rs
      join public.context_source_versions v on v.id = rs.source_version_id and v.owner_id = rs.owner_id
      join public.context_sources s on s.id = v.source_id and s.owner_id = v.owner_id
      where rs.result_id = r.id and (v.removed_at is not null or s.withdrawn_at is not null)
    );
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;
revoke all on function public.accept_context_result(uuid,uuid,uuid,bigint) from public, anon, authenticated;
grant execute on function public.accept_context_result(uuid,uuid,uuid,bigint) to service_role;

create function public.withdraw_context_source(p_owner uuid, p_source uuid)
returns boolean language plpgsql set search_path = '' as $$
declare changed integer;
begin
  update public.context_sources set withdrawn_at = coalesce(withdrawn_at, now())
    where id = p_source and owner_id = p_owner;
  get diagnostics changed = row_count;
  if changed = 0 then return false; end if;
  update public.context_results r set status = 'withdrawn'
    where r.owner_id = p_owner and exists(
      select 1 from public.context_result_sources rs
      join public.context_source_versions v on v.id = rs.source_version_id and v.owner_id = rs.owner_id
      where rs.result_id = r.id and rs.owner_id = p_owner and v.source_id = p_source
    );
  update public.context_documents d set current_result_id = null, revision = d.revision + 1, updated_at = now()
    from public.context_results r
    where d.current_result_id = r.id and d.owner_id = p_owner and r.owner_id = p_owner and r.status = 'withdrawn';
  return true;
end;
$$;
revoke all on function public.withdraw_context_source(uuid,uuid) from public, anon, authenticated;
grant execute on function public.withdraw_context_source(uuid,uuid) to service_role;

do $$
declare t text;
begin
  foreach t in array array['context_resources','context_subjects','context_resource_links','context_requests','context_sources','context_source_versions','context_attempts','context_results','context_result_sources','context_documents'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end;
$$;

insert into storage.buckets(id,name,public,file_size_limit)
values ('context-private','context-private',false,52428800);
-- A restrictive policy also protects against unrelated permissive policies
-- whose predicates are broader than their original bucket. service_role bypasses RLS.
create policy context_private_server_only on storage.objects as restrictive
  for all to public using (bucket_id <> 'context-private')
  with check (bucket_id <> 'context-private');
-- No anonymous or authenticated storage-object policy is created. The API must
-- authorize every signed read and upload. Retention/withdrawal workers follow in
-- the lifecycle ticket; this migration alone does not enable customer ingestion.
commit;
