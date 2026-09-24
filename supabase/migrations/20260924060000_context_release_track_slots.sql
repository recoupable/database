-- A provider album lists track slots, not confirmed recording identities.
-- Keep the observed membership scoped to the owner and the exact source result.
-- Readers must require the current accepted result and live source lineage;
-- old rows are historical evidence, not permanent current membership.
begin;
create table public.context_release_track_slots (
 owner_id uuid not null,
 release_subject_id uuid not null references public.context_subjects(id) on delete restrict,
 source_result_id uuid not null,
 source_topic text not null default 'spotify_release_context' check(source_topic='spotify_release_context'),
 slot_index integer not null check(slot_index>=0),
 track_resource_id uuid not null references public.context_resources(id) on delete restrict,
 disc_number integer check(disc_number>0),
 track_number integer check(track_number>0),
 primary key(owner_id,release_subject_id,source_result_id,slot_index),
 foreign key(source_result_id,owner_id,release_subject_id,source_topic)
  references public.context_results(id,owner_id,subject_id,topic) on delete restrict
);
create index context_release_track_slots_resource on public.context_release_track_slots(track_resource_id,owner_id);
alter table public.context_release_track_slots enable row level security;
revoke all on public.context_release_track_slots from public,anon,authenticated;
grant all on public.context_release_track_slots to service_role;

create function public.save_context_spotify_release_track_slots(p_owner uuid,p_request uuid,p_subject uuid,p_result uuid)
returns jsonb language plpgsql set search_path='' as $$
declare release_id text; observed public.context_results; slot jsonb; position integer; track_id text; resource uuid;
 linked integer:=0; skipped integer:=0; total integer;
begin
 -- This check binds both standalone release requests and track-origin requests
 -- to the release that actually belongs to the selected request.
 release_id:=public.resolve_context_spotify_release(p_owner,p_request,p_subject)->>'releaseId';
 select r.* into strict observed from public.context_results r
 join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id and a.request_id=p_request and a.provider='spotify' and a.status='succeeded'
 join public.context_documents d on d.owner_id=r.owner_id and d.subject_id=r.subject_id and d.topic=r.topic and d.current_result_id=r.id
 where r.id=p_result and r.owner_id=p_owner and r.subject_id=p_subject
  and r.topic='spotify_release_context' and r.status='accepted' and r.evidence_kind='observation'
  and exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
   join public.context_sources s on s.id=v.source_id and s.owner_id=p_owner and s.withdrawn_at is null
   where rs.result_id=r.id and rs.owner_id=p_owner and s.kind='provider_metadata'
    and s.source_url='https://api.spotify.com/v1/albums/'||release_id);
 if observed.normalized_response->>'releaseId' is distinct from release_id
  or observed.normalized_response->'album'->>'id' is distinct from release_id
  or jsonb_typeof(observed.normalized_response->'tracks') is distinct from 'array'
 then raise exception 'Release result does not contain verified Spotify track slots'; end if;
 total:=jsonb_array_length(observed.normalized_response->'tracks');
 if total>2500 or (observed.normalized_response->'trackCoverage'->>'collectedSlots')::integer is distinct from total
 then raise exception 'Release track slot count is invalid'; end if;
 for slot,position in select value,ordinality::integer-1 from jsonb_array_elements(observed.normalized_response->'tracks') with ordinality loop
  track_id:=slot->>'id';
  if jsonb_typeof(slot) is distinct from 'object' or slot->>'type' is distinct from 'track'
   or track_id is null or track_id !~ '^[A-Za-z0-9]{22}$' then
   skipped:=skipped+1;
   continue;
  end if;
  insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
  values('spotify','track',track_id,'https://open.spotify.com/track/'||track_id)
  on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
  insert into public.context_release_track_slots(owner_id,release_subject_id,source_result_id,slot_index,track_resource_id,disc_number,track_number)
  values(p_owner,p_subject,p_result,position,resource,
   case when slot->>'disc_number' ~ '^[0-9]+$' and (slot->>'disc_number')::numeric between 1 and 2147483647 then (slot->>'disc_number')::integer end,
   case when slot->>'track_number' ~ '^[0-9]+$' and (slot->>'track_number')::numeric between 1 and 2147483647 then (slot->>'track_number')::integer end)
  on conflict(owner_id,release_subject_id,source_result_id,slot_index) do nothing;
  linked:=linked+1;
 end loop;
 return jsonb_build_object('sourceResultId',p_result,'observedSlots',total,'linkedSlots',linked,'skippedSlots',skipped,'coverage',observed.normalized_response->'trackCoverage'->>'extent');
end $$;
revoke all on function public.save_context_spotify_release_track_slots(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.save_context_spotify_release_track_slots(uuid,uuid,uuid,uuid) to service_role;
commit;
