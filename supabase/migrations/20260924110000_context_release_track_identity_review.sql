-- Read-only review of observed release-track ISRCs against existing mappings.
-- An observation is a candidate, never an automatic recording or rights claim.
begin;
create function public.review_context_release_track_identities(
 p_owner uuid,p_request uuid,p_subject uuid
) returns jsonb language plpgsql set search_path='' as $$
declare page jsonb; observed public.context_results; slot jsonb; item jsonb;
 track_id text; isrc_value text; mapping_state text; candidates jsonb:='[]'::jsonb;
begin
 page:=public.list_context_release_track_slots(p_owner,p_request,p_subject,-1,100);
 if page->>'state'<>'ready' then
  return jsonb_build_object('state',page->>'state','candidates',candidates);
 end if;
 if (page->>'linkedSlots')::integer not between 1 and 100 or page->>'hasMore'<>'false' then
  return jsonb_build_object('state','unsupported','candidates',candidates);
 end if;
 select r.* into observed from public.context_documents d
 join public.context_results r on r.id=d.current_result_id and r.owner_id=d.owner_id
 join public.context_attempts a on a.id=r.attempt_id and a.owner_id=p_owner
  and a.request_id=p_request and a.provider='spotify' and a.status='succeeded'
 where d.owner_id=p_owner and d.subject_id=p_subject and d.topic='spotify_release_track_isrcs'
  and r.status='accepted' and r.evidence_kind='observation'
  and r.normalized_response->>'releaseSourceResultId'=page->>'sourceResultId'
  and not exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id
   join public.context_sources s on s.id=v.source_id
   where rs.result_id=r.id and (v.owner_id<>p_owner or s.owner_id<>p_owner
    or v.removed_at is not null or s.withdrawn_at is not null));
 if observed.id is null then
  return jsonb_build_object('state','not_collected','releaseSourceResultId',page->>'sourceResultId','candidates',candidates);
 end if;
 if jsonb_typeof(observed.normalized_response->'observations') is distinct from 'array'
  or jsonb_typeof(observed.normalized_response->'slots') is distinct from 'array'
  or jsonb_array_length(observed.normalized_response->'slots')<>(page->>'linkedSlots')::integer
 then return jsonb_build_object('state','needs_reconciliation','candidates',candidates); end if;
 for slot in select value from jsonb_array_elements(page->'slots') loop
  track_id:=slot->>'spotifyTrackId';
  select x.value into item from jsonb_array_elements(observed.normalized_response->'slots') x
   where x.value->'slotIndex'=slot->'slotIndex' and x.value->>'spotifyTrackId'=track_id;
  if item is null or (select count(*) from jsonb_array_elements(observed.normalized_response->'slots') x
    where x.value->'slotIndex'=slot->'slotIndex' and x.value->>'spotifyTrackId'=track_id)<>1
  then return jsonb_build_object('state','needs_reconciliation','candidates','[]'::jsonb); end if;
  isrc_value:=item->>'isrc';
  if item->>'state'='observed' then
   if isrc_value is null or isrc_value !~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$' or not exists(
    select 1 from public.context_result_sources rs
    join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
    join public.context_sources s on s.id=v.source_id and s.owner_id=p_owner and s.withdrawn_at is null
    where rs.result_id=observed.id and rs.owner_id=p_owner
     and s.kind='provider_metadata' and s.source_url='https://api.spotify.com/v1/tracks/'||track_id
   ) then return jsonb_build_object('state','needs_reconciliation','candidates','[]'::jsonb); end if;
   if exists(select 1 from public.song_identifiers si where si.platform='spotify'
     and si.identifier_type='track_id' and si.value=track_id and si.song<>isrc_value)
    or exists(select 1 from public.context_resources cr
     join public.context_resource_links l on l.resource_id=cr.id and l.relation='identity' and l.status='accepted'
     join public.context_subjects s on s.id=l.subject_id
     where cr.provider='spotify' and cr.resource_kind='track' and cr.provider_id=track_id
      and (s.kind<>'recording' or s.song_isrc is distinct from isrc_value))
   then mapping_state:='conflict';
   elsif exists(select 1 from public.song_identifiers si where si.platform='spotify'
     and si.identifier_type='track_id' and si.value=track_id and si.song=isrc_value)
   then mapping_state:='existing_identifier_match';
   else mapping_state:='unmapped'; end if;
  elsif item->>'state' in ('missing_isrc','failed') and isrc_value is null then
   mapping_state:='unresolved';
  else return jsonb_build_object('state','needs_reconciliation','candidates','[]'::jsonb); end if;
  candidates:=candidates||jsonb_build_array(jsonb_build_object(
   'slotIndex',slot->'slotIndex','spotifyTrackId',track_id,'observationState',item->>'state',
   'isrc',isrc_value,'mappingState',mapping_state));
 end loop;
 return jsonb_build_object('state','ready','releaseSourceResultId',page->>'sourceResultId',
  'resultId',observed.id,'coverage',observed.normalized_response->>'coverage','candidates',candidates);
end $$;
revoke all on function public.review_context_release_track_identities(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.review_context_release_track_identities(uuid,uuid,uuid) to service_role;
commit;
