-- Persist only source-backed Spotify track observations for a claimed release.
-- ISRCs here are candidates, not recording identities or rights assertions.
begin;
create function public.complete_context_release_track_isrcs(
 p_owner uuid,p_request uuid,p_subject uuid,p_release_result uuid,p_attempt uuid,p_payload jsonb
) returns jsonb language plpgsql set search_path='' as $$
declare a public.context_attempts; release_doc public.context_documents; page jsonb;
 item jsonb; expected_id text; actual_id text; v_source uuid; v_version uuid;
 v_saved_result uuid; document public.context_documents; observations jsonb; normalized jsonb;
 successful integer:=0; observed integer:=0; failed integer:=0; missing integer:=0;
begin
 select * into strict a from public.context_attempts
 where id=p_attempt and owner_id=p_owner and request_id=p_request for update;
 if a.module is distinct from 'spotify_release_track_isrcs:'||p_subject||':'||p_release_result
  or a.provider is distinct from 'spotify'
  or a.input->>'subjectId' is distinct from p_subject::text
  or a.input->>'releaseResultId' is distinct from p_release_result::text
 then raise exception 'Track lookup claim does not match this release'; end if;
 if a.status='succeeded' then
  select id into v_saved_result from public.context_results where owner_id=p_owner and attempt_id=p_attempt;
  return jsonb_build_object('state','saved','attemptId',p_attempt,'resultId',v_saved_result);
 end if;
 if a.status<>'running' then raise exception 'Track lookup attempt is not running'; end if;
 select * into strict release_doc from public.context_documents
 where owner_id=p_owner and subject_id=p_subject and topic='spotify_release_context'
  and current_result_id=p_release_result for share;
 page:=public.list_context_release_track_slots(p_owner,p_request,p_subject,-1,100);
 if page->>'state'<>'ready' or page->>'sourceResultId' is distinct from p_release_result::text
  or (page->>'linkedSlots')::integer not between 1 and 100 or page->>'hasMore'<>'false'
 then raise exception 'Release evidence changed during track lookup'; end if;
 observations:=p_payload->'observations';
 if jsonb_typeof(observations) is distinct from 'array'
  or jsonb_array_length(observations) <> (select count(distinct slot->>'spotifyTrackId') from jsonb_array_elements(page->'slots') slot)
 then raise exception 'Track observations do not cover the release'; end if;
 if jsonb_typeof(p_payload->'slots') is distinct from 'array'
  or jsonb_array_length(p_payload->'slots') <> (page->>'linkedSlots')::integer
  or (select count(distinct slot->>'slotIndex') from jsonb_array_elements(p_payload->'slots') slot) <> (page->>'linkedSlots')::integer
 then raise exception 'Track position coverage is incomplete'; end if;
 for item in select value from jsonb_array_elements(p_payload->'slots') loop
  if not exists(select 1 from jsonb_array_elements(page->'slots') slot
    where slot->'slotIndex'=item->'slotIndex' and slot->'spotifyTrackId'=item->'spotifyTrackId')
   or not exists(select 1 from jsonb_array_elements(observations) lookup
    where lookup->>'spotifyTrackId'=item->>'spotifyTrackId'
     and lookup->'state'=item->'state' and lookup->'isrc'=item->'isrc')
  then raise exception 'Track position is not in this release'; end if;
 end loop;
 for item in select value from jsonb_array_elements(observations) loop
  actual_id:=item->>'spotifyTrackId';
  if actual_id is null or actual_id !~ '^[A-Za-z0-9]{22}$'
   or not exists(select 1 from jsonb_array_elements(page->'slots') slot where slot->>'spotifyTrackId'=actual_id)
   or (select count(*) from jsonb_array_elements(observations) x where x->>'spotifyTrackId'=actual_id)<>1
   or item->>'sourceUrl' is distinct from 'https://api.spotify.com/v1/tracks/'||actual_id
   or item->>'retrievedAt' is null or item->>'retrievedAt' !~ '^\d{4}-\d{2}-\d{2}T'
   or item->>'elapsedMs' is null or item->>'elapsedMs' !~ '^[0-9]+$'
  then raise exception 'Invalid or duplicate Spotify track observation'; end if;
  if item->>'state'='failed' then
   if item->'raw' is distinct from 'null'::jsonb or item->'isrc' is distinct from 'null'::jsonb
    or nullif(item->>'gap','') is null then raise exception 'Failed lookup claimed evidence'; end if;
   failed:=failed+1;
  elsif item->>'state' in ('observed','missing_isrc') then
   if item->>'httpStatus'<>'200' or jsonb_typeof(item->'raw') is distinct from 'object'
    or item->'raw'->>'id' is distinct from actual_id
    or length((item->'raw')::text)>1048576 then raise exception 'Spotify track response is not verified'; end if;
   if item->>'state'='observed' then
    if item->>'isrc' !~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'
     or upper(item->'raw'->'external_ids'->>'isrc') is distinct from item->>'isrc'
    then raise exception 'ISRC does not match provider evidence'; end if;
    observed:=observed+1;
   else
    if item->'isrc' is distinct from 'null'::jsonb
     or (item->'raw'->'external_ids'->>'isrc') ~ '^[A-Za-z]{2}[A-Za-z0-9]{3}[0-9]{7}$'
    then raise exception 'Missing ISRC conflicts with provider evidence'; end if;
    missing:=missing+1;
   end if;
   successful:=successful+1;
  else raise exception 'Unknown track observation state'; end if;
 end loop;
 if successful=0 then raise exception 'No verified Spotify track response to save'; end if;
 normalized:=jsonb_build_object('releaseSourceResultId',p_release_result,
  'slots',p_payload->'slots','observations',(
   select jsonb_agg(lookup.value-'raw' order by lookup.value->>'spotifyTrackId') from jsonb_array_elements(observations) lookup),
  'observedIsrcCount',observed,'missingIsrcCount',missing,'failedLookupCount',failed,
  'coverage',case when failed=0 then 'full' else 'partial' end);
 insert into public.context_documents(owner_id,subject_id,topic)
 values(p_owner,p_subject,'spotify_release_track_isrcs') on conflict do nothing;
 select * into strict document from public.context_documents
 where owner_id=p_owner and subject_id=p_subject and topic='spotify_release_track_isrcs' for update;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,
  raw_response,normalized_response,coverage)
 values(p_owner,p_attempt,p_subject,'spotify_release_track_isrcs',a.input->>'fingerprint',
  'accepted','observation',jsonb_build_object('releaseSourceResultId',p_release_result),normalized,
  jsonb_build_object('extent',case when failed=0 then 'full' else 'partial' end,
   'successful',successful,'failed',failed,'recipe',a.recipe_version)) returning id into v_saved_result;
 for item in select value from jsonb_array_elements(observations) loop
  if item->>'state'='failed' then continue; end if;
  expected_id:=item->>'spotifyTrackId';
  insert into public.context_sources(owner_id,source_url,kind)
  values(p_owner,'https://api.spotify.com/v1/tracks/'||expected_id,'provider_metadata')
  on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
  do update set source_url=excluded.source_url returning id into v_source;
  insert into public.context_source_versions(owner_id,source_id,fingerprint,content,retrieved_at)
  values(p_owner,v_source,encode(sha256(convert_to((item->'raw')::text,'UTF8')),'hex'),item->'raw',(item->>'retrievedAt')::timestamptz)
  on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into v_version;
  insert into public.context_result_sources(owner_id,result_id,source_version_id)
  values(p_owner,v_saved_result,v_version) on conflict do nothing;
 end loop;
 -- The album result is a dependency too. Withdrawal of its source must also
 -- invalidate the derived track lookup, even if track responses remain live.
 insert into public.context_result_sources(owner_id,result_id,source_version_id)
 select p_owner,v_saved_result,rs.source_version_id from public.context_result_sources rs
 where rs.owner_id=p_owner and rs.result_id=p_release_result on conflict do nothing;
 if not public.accept_context_result(p_owner,document.id,v_saved_result,document.revision)
 then raise exception 'Track source no longer acceptable'; end if;
 update public.context_attempts set status='succeeded',finished_at=now(),provider_cost_status='unknown'
 where id=p_attempt;
 return jsonb_build_object('state','saved','attemptId',p_attempt,'resultId',v_saved_result,
  'observedIsrcCount',observed,'missingIsrcCount',missing,'failedLookupCount',failed);
end $$;
revoke all on function public.complete_context_release_track_isrcs(uuid,uuid,uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.complete_context_release_track_isrcs(uuid,uuid,uuid,uuid,uuid,jsonb) to service_role;
commit;
