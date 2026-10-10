-- Fence concurrent owner and recording removal during stream commits.
create or replace function public.commit_catalog_stream_track(p_run_id uuid, p_isrc text, p_result jsonb)
returns boolean language plpgsql security invoker set search_path = public as $$
declare r public.catalog_stream_runs; t public.catalog_stream_tracking;
begin
  select * into r from public.catalog_stream_runs where id=p_run_id;
  if not found then return false; end if;
  select * into t from public.catalog_stream_tracking where catalog_id=r.catalog_id for update;
  -- Keep membership removals outside the successful commit's transaction boundary.
  perform 1 from public.account_catalogs where catalog=r.catalog_id and account=t.owner_id for share;
  if not found then return false; end if;
  perform 1 from public.catalog_songs where catalog=r.catalog_id and song=p_isrc for share;
  if not found then return false; end if;
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
