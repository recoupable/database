-- Project the observed release format and disc structure from the Spotify album
-- observation that is already saved for a release case. Spotify metadata alone
-- cannot establish reissue or physical format, so those stay the literal 'unknown';
-- a UPC is passed through only when the provider reported one, never inferred.
-- Disc structure is definite only when every reported track slot was collected with a
-- disc number. A partial track list (page limit or a failed later page) proves at most
-- that a release has several discs, never how many or that it has only one.
-- Additive read-side change: no provider calls, no new tables, no identity writes.
-- The case fingerprint hashes the whole projected body, so adding release_format and
-- its gap changes every fingerprint even though no evidence changed: saved reviews read
-- stale after release and operators must re-review those cases.
begin;
create function public.project_context_release_format(p_album jsonb,p_tracks jsonb,p_coverage jsonb)
returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object(
  'source','spotify_album_observation',
  'state',case when c.collected then 'observed' else 'uncollected' end,
  'observed_type',p_album->>'album_type',
  'format_state',case when p_album->>'album_type' in ('single','album','compilation') then p_album->>'album_type' else 'unknown' end,
  'reported_total_tracks',case when p_album->>'total_tracks' ~ '^[0-9]{1,9}$' then (p_album->>'total_tracks')::integer end,
  'release_date',p_album->>'release_date',
  'release_date_precision',p_album->>'release_date_precision',
  'label',p_album->>'label',
  'upc',nullif(p_album->'external_ids'->>'upc',''),
  'upc_state',case when not c.collected then 'uncollected'
   when nullif(p_album->'external_ids'->>'upc','') is null then 'not_observed' else 'observed' end,
  'track_coverage',case when not c.collected then 'uncollected' when c.complete then 'full' else 'partial' end,
  'disc_count',case when c.complete and discs.numbered=discs.slots then discs.highest end,
  'multi_disc',case when discs.highest>1 then true
   when c.complete and discs.numbered=discs.slots and discs.highest is not null then false end,
  'reissue','unknown',
  'physical_format','unknown')
 from (select count(*) as slots,count(*) filter (where s.numbered) as numbered,
   max(case when s.numbered then (s.slot->>'disc_number')::integer end) as highest
  from (select slot,coalesce(jsonb_typeof(slot)='object' and slot->>'disc_number' ~ '^[1-9][0-9]{0,8}$',false) as numbered
   from jsonb_array_elements(case when jsonb_typeof(p_tracks)='array' then p_tracks else '[]'::jsonb end) slot) s) discs
 cross join lateral (select coalesce(jsonb_typeof(p_album)='object',false) as collected,
   -- Full only when the collector reported full extent and every reported slot is present.
   coalesce(jsonb_typeof(p_album)='object' and p_coverage->>'extent'='full'
    and case when p_coverage->>'reportedTotal' ~ '^[0-9]{1,9}$' then discs.slots=(p_coverage->>'reportedTotal')::bigint else false end,false) as complete) c;
$$;
revoke all on function public.project_context_release_format(jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.project_context_release_format(jsonb,jsonb,jsonb) to service_role;

-- Identical to 20261008160000 except the added release_format key and the third gap.
create or replace function public.read_context_release_case(p_actor uuid,p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject uuid; page jsonb; identities jsonb; observed public.context_results;
 tracks jsonb:='[]'; manifest jsonb:='[]'; body jsonb; v_fingerprint text; latest jsonb;
begin
 perform public.authorize_context_case_actor(p_actor,p_owner);
 select * into req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.id is null or req.input->>'kind' is distinct from 'release' or req.status not in ('partial','completed')
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array' or jsonb_array_length(req.output->'subjectIds')<>1
 then raise exception 'Case is unavailable' using errcode='42501'; end if;
 subject:=(req.output->'subjectIds'->>0)::uuid;
 -- Follow the existing source-before-document lock order for review consistency.
 perform 1 from public.context_sources s join public.context_source_versions v on v.source_id=s.id and v.owner_id=s.owner_id
 join public.context_result_sources rs on rs.source_version_id=v.id and rs.owner_id=v.owner_id
 join public.context_results r on r.id=rs.result_id and r.owner_id=rs.owner_id
 join public.context_attempts a on a.id=r.attempt_id and a.owner_id=r.owner_id
 where r.owner_id=p_owner and r.subject_id=subject and a.request_id=p_request
  and r.topic in ('spotify_release_context','spotify_release_track_isrcs') order by s.id,v.id for share of s,v;
 perform 1 from public.context_documents where owner_id=p_owner and subject_id=subject
  and topic in ('spotify_release_context','spotify_release_track_isrcs') order by id for share;
 page:=public.list_context_release_track_slots(p_owner,p_request,subject,-1,100);
 identities:=public.review_context_release_track_identities(p_owner,p_request,subject);
 if page->>'sourceResultId' is not null then
  select * into strict observed from public.context_results where id=(page->>'sourceResultId')::uuid and owner_id=p_owner;
  -- Project only reviewed metadata fields. Do not expose raw provider payloads.
  select coalesce(jsonb_agg(jsonb_build_object('slot_index',x.value->'slotIndex','spotify_track_id',x.value->>'spotifyTrackId',
   'title',observed.normalized_response->'tracks'->((x.value->>'slotIndex')::integer)->>'name',
   'disc_number',x.value->'discNumber','track_number',x.value->'trackNumber',
   'credited_artists',coalesce((select jsonb_agg(jsonb_build_object('name',artist->>'name','spotify_artist_id',artist->>'id'))
     from jsonb_array_elements(observed.normalized_response->'tracks'->((x.value->>'slotIndex')::integer)->'artists') artist),'[]'::jsonb)) order by (x.value->>'slotIndex')::integer),'[]'::jsonb)
  into tracks from jsonb_array_elements(page->'slots') x;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('document_id',d.id,'document_revision',d.revision,'result_id',r.id,'source_version_id',v.id,
  'source_url',s.source_url,'retrieved_at',v.retrieved_at) order by d.id,v.id),'[]'::jsonb) into manifest
 from public.context_documents d join public.context_results r on r.id=d.current_result_id and r.owner_id=d.owner_id
 join public.context_result_sources rs on rs.result_id=r.id and rs.owner_id=r.owner_id
 join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=rs.owner_id and v.removed_at is null
 join public.context_sources s on s.id=v.source_id and s.owner_id=v.owner_id and s.withdrawn_at is null
 where d.owner_id=p_owner and d.subject_id=subject and r.status='accepted'
  and r.id::text in (page->>'sourceResultId',identities->>'resultId');
 body:=jsonb_build_object('contract_version','release-case-v1','operation','release_metadata_reconciliation',
  'request_id',p_request,'subject_id',subject,'title',observed.normalized_response->'album'->>'name',
  'release_url','https://open.spotify.com/album/'||(page->>'releaseId'),'readiness',case when page->>'state'='ready' then 'partial' else 'blocked' end,
  -- Disc structure comes from the whole observed track array and its collection coverage,
  -- not the 100-slot display page.
  'release_format',public.project_context_release_format(observed.normalized_response->'album',
    observed.normalized_response->'tracks',observed.normalized_response->'trackCoverage'),
  'tracks',tracks,'track_page',page,'identity_observations',identities,'evidence_manifest',manifest,
  'gaps',jsonb_build_array('Only saved Spotify observations are supported; cross-source comparison is unavailable.',
    'Composition, songwriter, publisher, contracts and approved-master evidence are not yet linked.',
    'Reissue and physical-format status are not observable from Spotify metadata.'),
  'reviewable',page->>'state'='ready' and page->>'hasMore'='false' and jsonb_array_length(manifest)>0,
  'capabilities',jsonb_build_object('distribute','unsupported','register_rights','unsupported','collect_royalties','unsupported'),
  'cost',jsonb_build_object('provider_calls',0,'model_calls',0,'infrastructure_cost','unmeasured'));
 v_fingerprint:=encode(sha256(convert_to(body::text,'UTF8')),'hex');
 select jsonb_build_object('id',v.id,'decision',v.decision,'created_at',v.created_at,'stale',v.fingerprint<>v_fingerprint)
 into latest from public.context_release_case_reviews v where v.owner_id=p_owner and v.request_id=p_request order by v.created_at desc,v.id desc limit 1;
 return body||jsonb_build_object('fingerprint',v_fingerprint,'latest_review',latest);
end $$;
revoke all on function public.read_context_release_case(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.read_context_release_case(uuid,uuid,uuid) to service_role;
commit;
