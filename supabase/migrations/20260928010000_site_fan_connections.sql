-- Private server-owned integration records for externally hosted fan sites.
create table public.site_fan_configs (
  site_id uuid primary key references public.sites(id) on delete cascade,
  return_url text not null check (return_url ~ '^https://'),
  marketing_text text not null check (length(marketing_text) between 20 and 1000),
  enabled boolean not null default false,
  revision integer not null default 1,
  updated_at timestamptz not null default now()
);
create table public.site_fan_oauth_sessions (
  state_hash text primary key,
  site_id uuid not null references public.sites(id) on delete cascade,
  browser_hash text not null,
  verifier text not null,
  return_url text not null,
  marketing_text text not null,
  config_revision integer not null,
  scopes text[] not null,
  accepted_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz
);
create index site_fan_oauth_expiry_idx on public.site_fan_oauth_sessions(expires_at);
create table public.site_fans (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.sites(id) on delete cascade,
  spotify_id text not null,
  display_name text,
  email text,
  first_connected_at timestamptz not null default now(),
  last_connected_at timestamptz not null default now(),
  unique(site_id, spotify_id)
);
create table public.site_fan_connections (
  id uuid primary key default gen_random_uuid(),
  fan_id uuid not null references public.site_fans(id) on delete cascade,
  state_hash text not null unique,
  connected_at timestamptz not null default now()
);
create table public.site_fan_permissions (
  connection_id uuid primary key references public.site_fan_connections(id) on delete cascade,
  scopes text[] not null,
  granted_at timestamptz not null default now()
);
create table public.site_fan_marketing_consents (
  connection_id uuid primary key references public.site_fan_connections(id) on delete cascade,
  consent_text text not null,
  config_revision integer not null,
  accepted_at timestamptz not null default now()
);
-- One atomic completion: no partially saved grant or success without attribution.
create function public.complete_site_fan_connection(
  p_state_hash text, p_spotify_id text, p_display_name text, p_email text, p_scopes text[]
) returns uuid language plpgsql security definer set search_path = '' as $$
declare s public.site_fan_oauth_sessions; f uuid; c uuid;
begin
  select * into s from public.site_fan_oauth_sessions where state_hash=p_state_hash for update;
  if not found or s.consumed_at is null or s.expires_at < now() then
    raise exception 'Invalid connection session';
  end if;
  if p_scopes is null or not (s.scopes <@ p_scopes) then raise exception 'Missing permissions'; end if;
  if not exists(select 1 from public.site_fan_configs where site_id=s.site_id and enabled and revision=s.config_revision) then
    raise exception 'Site connection changed';
  end if;
  insert into public.site_fans(site_id,spotify_id,display_name,email)
    values(s.site_id,p_spotify_id,p_display_name,p_email)
    on conflict(site_id,spotify_id) do update set display_name=excluded.display_name,email=excluded.email,last_connected_at=now()
    returning id into f;
  insert into public.site_fan_connections(fan_id,state_hash) values(f,p_state_hash) returning id into c;
  insert into public.site_fan_permissions(connection_id,scopes) values(c,p_scopes);
  insert into public.site_fan_marketing_consents(connection_id,consent_text,config_revision,accepted_at)
    values(c,s.marketing_text,s.config_revision,s.accepted_at);
  delete from public.site_fan_oauth_sessions where state_hash=p_state_hash;
  return f;
end;
$$;
revoke all on function public.complete_site_fan_connection(text,text,text,text,text[]) from public,anon,authenticated;
grant execute on function public.complete_site_fan_connection(text,text,text,text,text[]) to service_role;
do $$ declare t text; begin
  foreach t in array array['site_fan_configs','site_fan_oauth_sessions','site_fans','site_fan_connections','site_fan_permissions','site_fan_marketing_consents'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from anon, authenticated',t);
    execute format('grant all on public.%I to service_role',t);
  end loop;
end $$;
