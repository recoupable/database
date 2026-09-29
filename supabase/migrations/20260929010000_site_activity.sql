-- First-party activity has a fixed vocabulary and no arbitrary personal-data payload.
create table public.site_activity_events (
  id uuid primary key,
  site_id uuid not null references public.sites(id) on delete cascade,
  visit_id uuid not null,
  event text not null check(event in ('visit','start','complete','replay','share','signup')),
  created_at timestamptz not null default now()
);
create index site_activity_site_time_idx on public.site_activity_events(site_id,created_at);
alter table public.site_activity_events enable row level security;
revoke all on public.site_activity_events from public, anon, authenticated;
grant all on public.site_activity_events to service_role;

create table public.site_request_windows (
  key text primary key,
  window_start timestamptz not null,
  requests integer not null
);
alter table public.site_request_windows enable row level security;
revoke all on public.site_request_windows from public,anon,authenticated;
grant all on public.site_request_windows to service_role;
create function public.take_site_request(p_key text,p_limit integer) returns boolean
language plpgsql security definer set search_path='' as $$
declare used integer; bucket timestamptz := date_trunc('minute',now());
begin
  if p_limit < 1 or p_limit > 1000 or length(p_key)>200 then raise exception 'Invalid limit'; end if;
  insert into public.site_request_windows(key,window_start,requests) values(p_key,bucket,1)
  on conflict(key) do update set window_start=bucket, requests=case when site_request_windows.window_start=bucket then site_request_windows.requests+1 else 1 end
  returning requests into used;
  return used<=p_limit;
end $$;
revoke all on function public.take_site_request(text,integer) from public,anon,authenticated;
grant execute on function public.take_site_request(text,integer) to service_role;

create function public.site_activity_summary(p_site_id uuid) returns jsonb
language sql security definer set search_path='' as $$
  select jsonb_build_object('days',30,'visits',count(distinct visit_id) filter(where event='visit'),
  'starts',count(*) filter(where event='start'),'completions',count(*) filter(where event='complete'),
  'replays',count(*) filter(where event='replay'),'shares',count(*) filter(where event='share'),
  'signups',count(*) filter(where event='signup'))
  from public.site_activity_events where site_id=p_site_id and created_at>=now()-interval '30 days';
$$;
revoke all on function public.site_activity_summary(uuid) from public,anon,authenticated;
grant execute on function public.site_activity_summary(uuid) to service_role;

-- Bounded maintenance cannot turn a busy connection request into a full-table sweep.
create function public.cleanup_site_transient_data() returns void
language plpgsql security definer set search_path='' as $$
begin
 delete from public.site_fan_oauth_sessions where state_hash in
   (select state_hash from public.site_fan_oauth_sessions where expires_at<now() order by expires_at limit 100);
 delete from public.site_request_windows where key in
   (select key from public.site_request_windows where window_start<now()-interval '1 day' limit 100);
end $$;
revoke all on function public.cleanup_site_transient_data() from public,anon,authenticated;
grant execute on function public.cleanup_site_transient_data() to service_role;
