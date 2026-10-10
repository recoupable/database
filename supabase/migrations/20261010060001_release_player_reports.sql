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
