-- Read only currently accepted, source-backed track positions for the exact
-- release request. This never resolves a Spotify track to a recording/ISRC.
begin;
create function public.list_context_release_track_slots(p_owner uuid,p_request uuid,p_subject uuid,p_after_slot integer default -1,p_limit integer default 100)
returns jsonb language plpgsql set search_path='' as $$
declare release_id text; observed public.context_results; expected integer; materialized integer; page jsonb; last_slot integer; more boolean;
begin
 if p_after_slot is null or p_after_slot < -1 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid release track page'; end if;
 release_id:=public.resolve_context_spotify_release(p_owner,p_request,p_subject)->>'releaseId';
 select r.* into observed from public.context_results r
 join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id and a.request_id=p_request and a.provider='spotify' and a.status='succeeded'
 join public.context_documents d on d.owner_id=r.owner_id and d.subject_id=r.subject_id and d.topic=r.topic and d.current_result_id=r.id
 where r.owner_id=p_owner and r.subject_id=p_subject and r.topic='spotify_release_context'
  and r.status='accepted' and r.evidence_kind='observation'
  and r.normalized_response->>'releaseId'=release_id and r.normalized_response->'album'->>'id'=release_id
  and exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
   join public.context_sources s on s.id=v.source_id and s.owner_id=p_owner and s.withdrawn_at is null
   where rs.result_id=r.id and rs.owner_id=p_owner and s.kind='provider_metadata'
    and s.source_url='https://api.spotify.com/v1/albums/'||release_id);
 if observed.id is null then return jsonb_build_object('state','not_collected','releaseId',release_id,'slots','[]'::jsonb,'nextCursor',null,'hasMore',false); end if;
 if jsonb_typeof(observed.normalized_response->'tracks') is distinct from 'array' then raise exception 'Current release result has no track array'; end if;
 select count(*) into expected from jsonb_array_elements(observed.normalized_response->'tracks') slot
 where jsonb_typeof(slot)='object' and slot->>'type'='track' and slot->>'id' ~ '^[A-Za-z0-9]{22}$';
 select count(*) into materialized from public.context_release_track_slots s
 where s.owner_id=p_owner and s.release_subject_id=p_subject and s.source_result_id=observed.id;
 select coalesce(jsonb_agg(jsonb_build_object('slotIndex',items.slot_index,'spotifyTrackId',items.provider_id,
  'discNumber',items.disc_number,'trackNumber',items.track_number,'sourceResultId',observed.id) order by items.slot_index),'[]'::jsonb),max(items.slot_index)
 into page,last_slot from (
  select slots.slot_index,resources.provider_id,slots.disc_number,slots.track_number
  from public.context_release_track_slots slots
  join public.context_resources resources on resources.id=slots.track_resource_id and resources.provider='spotify' and resources.resource_kind='track'
  where slots.owner_id=p_owner and slots.release_subject_id=p_subject and slots.source_result_id=observed.id and slots.slot_index>p_after_slot
  order by slots.slot_index limit p_limit
 ) items;
 select last_slot is not null and exists(select 1 from public.context_release_track_slots s
  where s.owner_id=p_owner and s.release_subject_id=p_subject and s.source_result_id=observed.id and s.slot_index>last_slot) into more;
 return jsonb_build_object('state',case when materialized=expected then 'ready' else 'needs_reconciliation' end,
  'releaseId',release_id,'sourceResultId',observed.id,
  'coverage',observed.normalized_response->'trackCoverage'->>'extent',
  'collectedSlots',jsonb_array_length(observed.normalized_response->'tracks'),
  'reportedTotal',observed.normalized_response->'trackCoverage'->'reportedTotal',
  'linkedSlots',materialized,'unavailableSlots',jsonb_array_length(observed.normalized_response->'tracks')-expected,
  'slots',page,'nextCursor',case when more then last_slot else null end,'hasMore',more);
end $$;
revoke all on function public.list_context_release_track_slots(uuid,uuid,uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.list_context_release_track_slots(uuid,uuid,uuid,integer,integer) to service_role;
commit;
