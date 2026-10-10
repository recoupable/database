-- Forward upgrade for previews that already applied the original player tables.
alter table public.player_sessions add column reported_listening_ms bigint not null default 0 check(reported_listening_ms >= 0);
update public.player_sessions s set reported_listening_ms=coalesce((select sum(listened_ms) from public.player_listening_events e where e.session_id=s.id),0);
-- Dedupe retries and serialize duration reports; client timing is never a DSP stream count.
create or replace function public.record_player_listening(p_session uuid,p_revision integer,p_provider text,p_id uuid,p_event text,p_track text,p_position integer,p_listened integer)
returns boolean language plpgsql security definer set search_path='' as $$
declare s public.player_sessions; p public.release_players;
begin
  select * into s from public.player_sessions where id=p_session for update;
  if not found or s.expires_at <= now() or s.revision <> p_revision or s.provider <> p_provider then raise exception 'Invalid player session'; end if;
  select * into p from public.release_players where id=s.player_id for share;
  if not p.enabled or p.revision <> p_revision then raise exception 'Player changed'; end if;
  if exists(select 1 from public.player_listening_events where id=p_id) then return false; end if;
  if p_listened > greatest(0,extract(epoch from(now()-s.last_event_at))*1000)+2000 or s.reported_listening_ms+p_listened > greatest(0,extract(epoch from(now()-s.created_at))*1000)+2000 then raise exception 'Invalid listening duration'; end if;
  insert into public.player_listening_events(id,session_id,event,track_id,position_ms,listened_ms)
    values(p_id,s.id,p_event,p_track,p_position,p_listened) on conflict(id) do nothing;
  if not found then return false; end if;
  update public.player_sessions set last_event_at=now(),reported_listening_ms=reported_listening_ms+p_listened where id=s.id;
  return true;
end; $$;

revoke all on function public.record_player_listening(uuid,integer,text,uuid,text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.record_player_listening(uuid,integer,text,uuid,text,text,integer,integer) to service_role;
