-- One private contact per workspace/provider identity; player_fans remain artist relationships.
-- Preserve all relationship IDs and historical session/event references during the backfill.
begin;
lock table public.player_fans in share row exclusive mode;

create table public.player_fan_contacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id),
  provider text not null check (provider = 'spotify'),
  provider_id text not null,
  email text,
  display_name text,
  first_connected_at timestamptz not null default now(),
  last_connected_at timestamptz not null default now(),
  unique (owner_id, provider, provider_id),
  unique (id, owner_id, provider, provider_id)
);
create index player_fan_contacts_owner_recent_idx
  on public.player_fan_contacts(owner_id, last_connected_at desc, id desc);
alter table public.player_fan_contacts enable row level security;
revoke all on public.player_fan_contacts from public, anon, authenticated;
grant all on public.player_fan_contacts to service_role;

insert into public.player_fan_contacts(owner_id,provider,provider_id,email,display_name,first_connected_at,last_connected_at)
select owner_id,provider,provider_id,
  (array_agg(email order by last_connected_at desc,id) filter (where email is not null))[1],
  (array_agg(display_name order by last_connected_at desc,id) filter (where display_name is not null))[1],
  min(first_connected_at),max(last_connected_at)
from public.player_fans group by owner_id,provider,provider_id;

alter table public.player_fans add column contact_id uuid;
update public.player_fans f set contact_id=c.id from public.player_fan_contacts c
where c.owner_id=f.owner_id and c.provider=f.provider and c.provider_id=f.provider_id;
alter table public.player_fans alter column contact_id set not null;
-- A relationship cannot attach to a contact in a different workspace or Spotify identity.
alter table public.player_fans add constraint player_fans_contact_identity_fkey
  foreign key (contact_id,owner_id,provider,provider_id)
  references public.player_fan_contacts(id,owner_id,provider,provider_id);
create index player_fans_contact_idx on public.player_fans(contact_id);

create function public.sync_player_fan_contact()
returns trigger language plpgsql security definer set search_path='' as $$
declare contact uuid;
begin
  if tg_op='UPDATE' and (
    new.owner_id is distinct from old.owner_id or new.artist_id is distinct from old.artist_id
    or new.provider is distinct from old.provider or new.provider_id is distinct from old.provider_id
    or new.contact_id is distinct from old.contact_id
  ) then raise exception 'Fan relationship identity cannot be changed'; end if;
  -- This runs for existing connect_player_fan callers, so API rollout need not be atomic.
  insert into public.player_fan_contacts(owner_id,provider,provider_id,email,display_name,first_connected_at,last_connected_at)
  values(new.owner_id,new.provider,new.provider_id,
    case when tg_op='UPDATE' and new.email is not distinct from old.email then null else new.email end,
    case when tg_op='UPDATE' and new.display_name is not distinct from old.display_name then null else new.display_name end,
    new.first_connected_at,new.last_connected_at)
  on conflict(owner_id,provider,provider_id) do update set
    email=case when excluded.last_connected_at>=player_fan_contacts.last_connected_at then coalesce(excluded.email,player_fan_contacts.email) else coalesce(player_fan_contacts.email,excluded.email) end,
    display_name=case when excluded.last_connected_at>=player_fan_contacts.last_connected_at then coalesce(excluded.display_name,player_fan_contacts.display_name) else coalesce(player_fan_contacts.display_name,excluded.display_name) end,
    first_connected_at=least(excluded.first_connected_at,player_fan_contacts.first_connected_at),
    last_connected_at=greatest(excluded.last_connected_at,player_fan_contacts.last_connected_at)
  returning id into contact;
  if new.contact_id is not null and new.contact_id<>contact then raise exception 'Invalid fan contact'; end if;
  new.contact_id=contact;
  return new;
end; $$;
create trigger player_fans_sync_contact before insert or update on public.player_fans
  for each row execute function public.sync_player_fan_contact();
revoke all on function public.sync_player_fan_contact() from public,anon,authenticated;
grant execute on function public.sync_player_fan_contact() to service_role;
-- Reports retain relationship IDs and add organization contact identity.
-- Owner-scoped summary and a bounded page of fan-linked playback history.
create or replace function public.read_player_report(p_owner uuid,p_player uuid,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not exists(select 1 from public.release_players where id=p_player and owner_id=p_owner) then raise exception 'Player not found'; end if;
  if p_offset < 0 or p_offset > 100000 then raise exception 'Invalid offset'; end if;
  with sessions as (select * from public.player_sessions where player_id=p_player and created_at>=now()-interval '30 days'),
  events as (select e.*,s.provider,s.fan_id,s.acquisition from public.player_listening_events e join public.player_sessions s on s.id=e.session_id where s.player_id=p_player and e.received_at>=now()-interval '30 days'),
  campaigns as (select provider,acquisition->>'source' as source,acquisition->>'campaign' as campaign,count(distinct session_id) as sessions,sum(listened_ms) as listened_ms from events group by provider,acquisition->>'source',acquisition->>'campaign'),
  activity as (select e.id,e.session_id,e.event,e.provider,e.track_id,e.position_ms,e.listened_ms,e.received_at,e.fan_id,f.contact_id,c.display_name from events e left join public.player_fans f on f.id=e.fan_id left join public.player_fan_contacts c on c.id=f.contact_id order by e.received_at desc,e.id limit 100 offset p_offset)
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

commit;
