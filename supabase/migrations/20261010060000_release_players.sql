-- Registered release players: public configuration, private fans and reported listening.
create table public.release_players (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id),
  artist_id uuid not null references public.accounts(id),
  created_by uuid not null references public.accounts(id),
  name text not null check(length(name) between 1 and 120),
  spotify_url text, apple_url text, artwork text,
  allowed_origins text[] not null default '{}',
  enabled boolean not null default false,
  revision integer not null default 1 check(revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(spotify_url is not null or apple_url is not null)
);
create index release_players_owner_idx on public.release_players(owner_id,created_at desc);
create table public.player_fans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id),
  artist_id uuid not null references public.accounts(id),
  provider text not null check(provider='spotify'),
  provider_id text not null, email text, display_name text,
  first_connected_at timestamptz not null default now(),
  last_connected_at timestamptz not null default now(),
  unique(owner_id,artist_id,provider,provider_id)
);
create table public.player_sessions (
  id uuid primary key,
  player_id uuid not null references public.release_players(id),
  revision integer not null,
  provider text not null check(provider in ('spotify','apple_music')),
  fan_id uuid references public.player_fans(id),
  scopes text[] not null default '{}',
  acquisition jsonb not null default '{}',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_event_at timestamptz not null default now(),
  connected_at timestamptz,
  check(expires_at > created_at and expires_at <= created_at + interval '2 hours')
);
create index player_sessions_player_idx on public.player_sessions(player_id,created_at desc);
create table public.player_listening_events (
  id uuid primary key,
  session_id uuid not null references public.player_sessions(id),
  event text not null check(event in ('connected','playing','paused','stopped','track_changed','skip','heartbeat','disconnected')),
  track_id text, position_ms integer not null default 0 check(position_ms between 0 and 86400000),
  listened_ms integer not null default 0 check(listened_ms between 0 and 30000),
  received_at timestamptz not null default now()
);
create index player_listening_session_idx on public.player_listening_events(session_id,received_at);
-- Bind identity and scopes atomically. Signing in is not email marketing consent.
create function public.connect_player_fan(p_session uuid,p_revision integer,p_spotify_id text,p_email text,p_display_name text,p_scopes text[])
returns uuid language plpgsql security definer set search_path='' as $$
declare s public.player_sessions; p public.release_players; f uuid;
begin
  select * into s from public.player_sessions where id=p_session for update;
  if not found or s.provider <> 'spotify' or s.expires_at <= now() or s.revision <> p_revision or s.connected_at is not null then raise exception 'Invalid player session'; end if;
  select * into p from public.release_players where id=s.player_id for share;
  if not p.enabled or p.revision <> p_revision then raise exception 'Player changed'; end if;
  if p_scopes is null or not (array['user-read-email','user-read-private','streaming','user-modify-playback-state','user-read-playback-state'] <@ p_scopes) then raise exception 'Missing permissions'; end if;
  insert into public.player_fans(owner_id,artist_id,provider,provider_id,email,display_name)
    values(p.owner_id,p.artist_id,'spotify',p_spotify_id,p_email,p_display_name)
    on conflict(owner_id,artist_id,provider,provider_id) do update set
      email=coalesce(excluded.email,player_fans.email),display_name=coalesce(excluded.display_name,player_fans.display_name),last_connected_at=now()
    returning id into f;
  update public.player_sessions set fan_id=f,scopes=p_scopes,connected_at=now() where id=s.id;
  return f;
end; $$;
-- Dedupe retries and serialize duration reports; client timing is never a DSP stream count.
create function public.record_player_listening(p_session uuid,p_revision integer,p_provider text,p_id uuid,p_event text,p_track text,p_position integer,p_listened integer)
returns boolean language plpgsql security definer set search_path='' as $$
declare s public.player_sessions; p public.release_players;
begin
  select * into s from public.player_sessions where id=p_session for update;
  if not found or s.expires_at <= now() or s.revision <> p_revision or s.provider <> p_provider then raise exception 'Invalid player session'; end if;
  select * into p from public.release_players where id=s.player_id for share;
  if not p.enabled or p.revision <> p_revision then raise exception 'Player changed'; end if;
  if exists(select 1 from public.player_listening_events where id=p_id and session_id=s.id) then return false; end if;
  if p_listened > greatest(0,extract(epoch from(now()-s.last_event_at))*1000)+2000 then raise exception 'Invalid listening duration'; end if;
  insert into public.player_listening_events(id,session_id,event,track_id,position_ms,listened_ms)
    values(p_id,s.id,p_event,p_track,p_position,p_listened);
  update public.player_sessions set last_event_at=now() where id=s.id;
  return true;
end; $$;
do $$ declare t text; begin
  foreach t in array array['release_players','player_fans','player_sessions','player_listening_events'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
  end loop;
end $$;
revoke all on function public.connect_player_fan(uuid,integer,text,text,text,text[]) from public,anon,authenticated;
grant execute on function public.connect_player_fan(uuid,integer,text,text,text,text[]) to service_role;
revoke all on function public.record_player_listening(uuid,integer,text,uuid,text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.record_player_listening(uuid,integer,text,uuid,text,text,integer,integer) to service_role;
-- Owner-scoped summary and a bounded page of fan-linked playback history.
create function public.read_player_report(p_owner uuid,p_player uuid,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not exists(select 1 from public.release_players where id=p_player and owner_id=p_owner) then raise exception 'Player not found'; end if;
  if p_offset < 0 or p_offset > 100000 then raise exception 'Invalid offset'; end if;
  with sessions as (select * from public.player_sessions where player_id=p_player and created_at>=now()-interval '30 days'),
  events as (select e.*,s.provider,s.fan_id,s.acquisition from public.player_listening_events e join sessions s on s.id=e.session_id),
  campaigns as (select provider,acquisition->>'source' as source,acquisition->>'campaign' as campaign,count(distinct session_id) as sessions,sum(listened_ms) as listened_ms from events group by provider,acquisition->>'source',acquisition->>'campaign'),
  activity as (select e.id,e.session_id,e.event,e.provider,e.track_id,e.position_ms,e.listened_ms,e.received_at,e.fan_id,f.display_name from events e left join public.player_fans f on f.id=e.fan_id order by e.received_at desc,e.id limit 100 offset p_offset)
  select jsonb_build_object(
    'sessions',(select count(*) from sessions),
    'connectedFans',(select count(distinct fan_id) from sessions),
    'reportedListeningMs',coalesce((select sum(listened_ms) from events),0),
    'playEvents',(select count(*) from events where event='playing'),
    'campaigns',coalesce((select jsonb_agg(to_jsonb(c)) from campaigns c),'[]'::jsonb),
    'activity',coalesce((select jsonb_agg(to_jsonb(a) order by a.received_at desc,a.id) from activity a),'[]'::jsonb)
  ) into result;
  return result;
end; $$;
revoke all on function public.read_player_report(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.read_player_report(uuid,uuid,integer) to service_role;
