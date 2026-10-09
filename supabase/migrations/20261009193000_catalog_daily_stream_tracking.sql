-- Private calendar-day series, separate from public cumulative song_measurements.
create table public.catalog_stream_tracking (
  catalog_id uuid primary key references public.catalogs(id) on delete cascade,
  owner_id uuid not null references public.accounts(id),
  enabled boolean not null default false,
  revision uuid not null default gen_random_uuid(),
  updated_at timestamptz not null default now()
);
create table public.catalog_stream_runs (
  id uuid primary key default gen_random_uuid(),
  catalog_id uuid not null references public.catalog_stream_tracking(catalog_id) on delete cascade,
  revision uuid not null,
  scheduled_day date not null,
  since date not null,
  until date not null,
  status text not null default 'queued' check (status in ('queued','running','complete','partial','failed','cancelled')),
  coverage jsonb not null default '{}'::jsonb,
  error text,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (catalog_id, revision, scheduled_day),
  check (until >= since and until - since <= 61)
);
create table public.catalog_stream_observations (
  run_id uuid not null references public.catalog_stream_runs(id) on delete cascade,
  catalog_id uuid not null references public.catalog_stream_tracking(catalog_id) on delete cascade,
  isrc text not null references public.songs(isrc),
  date date not null,
  streams bigint check (streams >= 0 and streams <= 9007199254740991),
  provider_recording_id text not null,
  source_hash text not null,
  retrieved_at timestamptz not null,
  primary key (run_id, isrc, date)
);
create index on public.catalog_stream_runs(catalog_id, created_at desc);
create index on public.catalog_stream_observations(catalog_id, isrc, date, retrieved_at desc);
alter table public.catalog_stream_tracking enable row level security;
alter table public.catalog_stream_runs enable row level security;
alter table public.catalog_stream_observations enable row level security;
revoke all on public.catalog_stream_tracking, public.catalog_stream_runs, public.catalog_stream_observations from anon, authenticated;
grant all on public.catalog_stream_tracking, public.catalog_stream_runs, public.catalog_stream_observations to service_role;

-- Lock tracking before claim/commit: disable or revision changes fence in-flight work.
create function public.claim_catalog_stream_run(p_catalog_id uuid, p_day date)
returns setof public.catalog_stream_runs language plpgsql security invoker set search_path = public as $$
declare t public.catalog_stream_tracking;
begin
  select * into t from public.catalog_stream_tracking where catalog_id=p_catalog_id for update;
  if not found or not t.enabled or not exists (select 1 from public.account_catalogs where catalog=p_catalog_id and account=t.owner_id) then return; end if;
  return query insert into public.catalog_stream_runs(catalog_id,revision,scheduled_day,since,until)
    values(p_catalog_id,t.revision,p_day,p_day-63,p_day-2)
    on conflict (catalog_id,revision,scheduled_day) do nothing returning *;
end $$;

create function public.commit_catalog_stream_track(p_run_id uuid, p_isrc text, p_result jsonb)
returns boolean language plpgsql security invoker set search_path = public as $$
declare r public.catalog_stream_runs; t public.catalog_stream_tracking;
begin
  select * into r from public.catalog_stream_runs where id=p_run_id;
  if not found then return false; end if;
  select * into t from public.catalog_stream_tracking where catalog_id=r.catalog_id for update;
  if not t.enabled or t.revision <> r.revision or r.status not in ('queued','running') or
    not exists (select 1 from public.account_catalogs where catalog=r.catalog_id and account=t.owner_id) or
    not exists (select 1 from public.catalog_songs where catalog=r.catalog_id and song=p_isrc) then return false; end if;
  if p_result->>'state' in ('complete','partial') then
    -- Memoized fetch payload reused on write retries; original receipts never overwritten.
    insert into public.catalog_stream_observations(run_id,catalog_id,isrc,date,streams,provider_recording_id,source_hash,retrieved_at)
    select r.id,r.catalog_id,p_isrc,d::date,
      (select (v->>'streams')::bigint from jsonb_array_elements(p_result->'days') v where v->>'date'=d::date::text),
      p_result->>'provider_recording_id',p_result->>'source_hash',(p_result->>'retrieved_at')::timestamptz
    from generate_series(r.since::timestamp,r.until::timestamp,interval '1 day') d
    where not exists (
      select 1 from (
        select streams,provider_recording_id from public.catalog_stream_observations
        where catalog_id=r.catalog_id and isrc=p_isrc and date=d::date
        order by retrieved_at desc,run_id desc limit 1
      ) prior where prior.provider_recording_id=p_result->>'provider_recording_id'
        and prior.streams is not distinct from
          (select (v->>'streams')::bigint from jsonb_array_elements(p_result->'days') v where v->>'date'=d::date::text)
    )
    on conflict (run_id,isrc,date) do nothing;
  end if;
  update public.catalog_stream_runs set status='running', coverage=coverage || jsonb_build_object(p_isrc,
    jsonb_build_object('state',p_result->>'state','observed_days',coalesce(jsonb_array_length(p_result->'days'),0),
      'retrieved_at',p_result->>'retrieved_at','source_hash',p_result->>'source_hash',
      'provider_recording_id',p_result->>'provider_recording_id')) where id=r.id;
  return true;
end $$;
revoke all on function public.claim_catalog_stream_run(uuid,date), public.commit_catalog_stream_track(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.claim_catalog_stream_run(uuid,date), public.commit_catalog_stream_track(uuid,text,jsonb) to service_role;

-- Latest source version wins, including missing/null dates. Reads cannot be truncated
-- by PostgREST's row limit as historical correction versions accumulate.
create function public.read_catalog_stream_days(p_catalog_id uuid, p_isrc text, p_since date, p_until date)
returns setof public.catalog_stream_observations language sql stable security invoker set search_path = public as $$
  select latest.* from (
    select distinct on (date) * from public.catalog_stream_observations
    where catalog_id=p_catalog_id and isrc=p_isrc and date >= p_since and date < p_until
      and p_until - p_since between 1 and 62
    order by date, retrieved_at desc, run_id desc
  ) latest order by retrieved_at desc, date;
$$;
revoke all on function public.read_catalog_stream_days(uuid,text,date,date) from public, anon, authenticated;
grant execute on function public.read_catalog_stream_days(uuid,text,date,date) to service_role;
