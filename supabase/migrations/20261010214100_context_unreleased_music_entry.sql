-- Unreleased recordings and planned releases receive internal workspace identities.
-- No ISRC, UPC or store ID is accepted or invented; identifiers stay explicitly unknown.
-- The ISRC-backed `recording` subject arm is unchanged, so every ISRC consumer is preserved.
begin;
alter table public.context_resources drop constraint context_resources_resource_kind_check;
alter table public.context_resources add constraint context_resources_resource_kind_check
 check(resource_kind in ('artist','track','release','video','catalog','songwriter_input','company_input','campaign_input','material_input','recording_input','planned_release_input'));
alter table public.context_subjects drop constraint context_subjects_kind_check;
alter table public.context_subjects add constraint context_subjects_kind_check
 check(kind in ('artist','recording','release','video','catalog','songwriter','company','campaign','material','unreleased_recording','planned_release'));
alter table public.context_subjects drop constraint context_subjects_check;
alter table public.context_subjects add constraint context_subjects_check check(
 (kind='artist' and artist_id is not null and song_isrc is null and resource_id is null and catalog_id is null) or
 (kind='recording' and song_isrc is not null and artist_id is null and resource_id is null and catalog_id is null) or
 (kind in ('release','video','songwriter','company','campaign','material','unreleased_recording','planned_release') and resource_id is not null and artist_id is null and song_isrc is null and catalog_id is null) or
 (kind='catalog' and catalog_id is not null and artist_id is null and song_isrc is null and resource_id is null)
);

create function public.create_context_unreleased_recording_request(
 p_owner uuid,p_actor uuid,p_recording jsonb,p_key text
) returns jsonb language plpgsql set search_path='' as $$
declare title_text text; working_text text; lifecycle text; date_text text; normalized jsonb;
 input_hash text; opaque text; uri text; resource uuid; subject uuid; req public.context_requests;
 source uuid; source_version uuid; document public.context_documents; attempt_key uuid; result uuid;
 snapshot jsonb; snapshot_hash text;
begin
 if p_key is null or jsonb_typeof(p_recording) is distinct from 'object' then raise exception 'Invalid unreleased recording'; end if;
 -- Only descriptive fields are accepted: an ISRC, UPC or store ID key is rejected, never stored.
 if exists(select 1 from jsonb_object_keys(p_recording) as field(key)
  where field.key not in ('title','working_title','lifecycle_state','planned_release_date'))
 then raise exception 'Invalid unreleased recording'; end if;
 if jsonb_typeof(p_recording->'title') is distinct from 'string'
  or (p_recording ? 'working_title' and jsonb_typeof(p_recording->'working_title')<>'string')
  or (p_recording ? 'lifecycle_state' and jsonb_typeof(p_recording->'lifecycle_state')<>'string')
  or (p_recording ? 'planned_release_date' and jsonb_typeof(p_recording->'planned_release_date')<>'string')
 then raise exception 'Invalid unreleased recording'; end if;
 title_text:=p_recording->>'title'; working_text:=p_recording->>'working_title';
 if title_text ~ '[[:cntrl:]]' or working_text ~ '[[:cntrl:]]' then raise exception 'Invalid unreleased recording'; end if;
 title_text:=pg_catalog.btrim(pg_catalog.regexp_replace(title_text,'[[:space:]]+',' ','g'));
 working_text:=pg_catalog.btrim(pg_catalog.regexp_replace(working_text,'[[:space:]]+',' ','g'));
 if length(title_text) not between 2 and 200 or length(working_text) not between 1 and 200
 then raise exception 'Invalid unreleased recording'; end if;
 lifecycle:=coalesce(p_recording->>'lifecycle_state','unknown');
 if lifecycle not in ('unknown','idea','in_production','mixed','mastered','delivered_to_distributor')
 then raise exception 'Invalid unreleased recording'; end if;
 date_text:=p_recording->>'planned_release_date';
 if date_text is not null then
  if date_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Invalid unreleased recording'; end if;
  begin
   if date_text::date::text<>date_text then raise exception 'Invalid unreleased recording'; end if;
  exception when datetime_field_overflow or invalid_datetime_format then
   raise exception 'Invalid unreleased recording';
  end;
 end if;
 normalized:=jsonb_build_object('title',title_text,'lifecycle_state',lifecycle);
 if working_text is not null then normalized:=normalized||jsonb_build_object('working_title',working_text); end if;
 if date_text is not null then normalized:=normalized||jsonb_build_object('planned_release_date',date_text); end if;
 input_hash:=encode(sha256(convert_to('unreleased-recording-v1:'||normalized::text,'UTF8')),'hex');
 opaque:=encode(sha256(convert_to('recording-input-v1:'||p_owner::text||':'||p_key,'UTF8')),'hex');
 uri:='urn:recoup:recording-input:'||opaque;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('recoup','recording_input',opaque,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,input_hash,
  jsonb_build_object('kind','unreleased_recording','title',title_text,'contentHash',input_hash,'identityConfirmed',false))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict req from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if req.input_fingerprint<>input_hash or req.resource_id<>resource
 then raise exception 'Idempotency key already used for different input'; end if;
 if req.status in ('completed','partial','cancelled') then return to_jsonb(req)-'claim_token'; end if;
 insert into public.context_subjects(kind,resource_id) values('unreleased_recording',resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 snapshot:=jsonb_build_object('recording',normalized,'identifiers',jsonb_build_object('isrc','unknown'),
  'contentHash',input_hash,'submittedBy',p_actor,'identityConfirmed',false,'compositionLinked',false,
  'rightsVerified',false,'scope','workspace_private');
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'customer')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'unreleased_recording') on conflict do nothing;
 select * into strict document from public.context_documents
 where owner_id=p_owner and subject_id=subject and topic='unreleased_recording' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,req.id,'unreleased_recording:'||subject,1,'succeeded','user_submission','unreleased-recording-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into attempt_key;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,attempt_key,subject,'unreleased_recording',snapshot_hash,'accepted','customer_assertion',snapshot,snapshot,
  '{"extent":"partial","scope":"submitted_unreleased_recording","identifiers":{"isrc":"unknown"}}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision)
 then raise exception 'Unreleased recording acceptance conflict'; end if;
 update public.context_requests set status='partial',
  output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',jsonb_build_array('ISRC not assigned','Composition link unresolved')),
  updated_at=now() where id=req.id returning * into req;
 return to_jsonb(req)-'claim_token';
end $$;
revoke all on function public.create_context_unreleased_recording_request(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_context_unreleased_recording_request(uuid,uuid,jsonb,text) to service_role;

create function public.create_context_planned_release_request(
 p_owner uuid,p_actor uuid,p_release jsonb,p_key text
) returns jsonb language plpgsql set search_path='' as $$
declare title_text text; lifecycle text; date_text text; item jsonb; label_text text; url_text text;
 recording_id uuid; slot integer:=0; products jsonb:='[]'; links jsonb:='[]'; recordings jsonb:='[]'; tracklist jsonb:='[]';
 normalized jsonb; input_hash text; opaque text; uri text; resource uuid; subject uuid; req public.context_requests;
 source uuid; source_version uuid; document public.context_documents; attempt_key uuid; result uuid;
 snapshot jsonb; snapshot_hash text;
begin
 if p_key is null or jsonb_typeof(p_release) is distinct from 'object' then raise exception 'Invalid planned release'; end if;
 -- Lifecycle, products and promotional links are accepted; store IDs, UPC and ISRC keys are rejected.
 if exists(select 1 from jsonb_object_keys(p_release) as field(key)
  where field.key not in ('title','lifecycle_state','planned_release_date','products','promotional_links','recording_subject_ids'))
 then raise exception 'Invalid planned release'; end if;
 if jsonb_typeof(p_release->'title') is distinct from 'string' or jsonb_typeof(p_release->'lifecycle_state') is distinct from 'string'
  or (p_release ? 'planned_release_date' and jsonb_typeof(p_release->'planned_release_date')<>'string')
  or (p_release ? 'products' and jsonb_typeof(p_release->'products')<>'array')
  or (p_release ? 'promotional_links' and jsonb_typeof(p_release->'promotional_links')<>'array')
  or (p_release ? 'recording_subject_ids' and jsonb_typeof(p_release->'recording_subject_ids')<>'array')
 then raise exception 'Invalid planned release'; end if;
 title_text:=p_release->>'title';
 if title_text ~ '[[:cntrl:]]' then raise exception 'Invalid planned release'; end if;
 title_text:=pg_catalog.btrim(pg_catalog.regexp_replace(title_text,'[[:space:]]+',' ','g'));
 if length(title_text) not between 2 and 200 then raise exception 'Invalid planned release'; end if;
 lifecycle:=p_release->>'lifecycle_state';
 if lifecycle not in ('planned','scheduled','announced','delivered','released_unverified')
 then raise exception 'Invalid planned release'; end if;
 date_text:=p_release->>'planned_release_date';
 if date_text is not null then
  if date_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Invalid planned release'; end if;
  begin
   if date_text::date::text<>date_text then raise exception 'Invalid planned release'; end if;
  exception when datetime_field_overflow or invalid_datetime_format then
   raise exception 'Invalid planned release';
  end;
 end if;
 if p_release ? 'products' then
  if jsonb_array_length(p_release->'products')>20 then raise exception 'Invalid planned release'; end if;
  for item in select value from jsonb_array_elements(p_release->'products') loop
   if jsonb_typeof(item)<>'object' then raise exception 'Invalid planned release'; end if;
   if exists(select 1 from jsonb_object_keys(item) as field(key) where field.key not in ('format','label'))
    or jsonb_typeof(item->'format') is distinct from 'string' or (item ? 'label' and jsonb_typeof(item->'label')<>'string')
    or item->>'format' not in ('digital_single','digital_ep','digital_album','vinyl','cd','cassette')
   then raise exception 'Invalid planned release'; end if;
   label_text:=item->>'label';
   if label_text ~ '[[:cntrl:]]' then raise exception 'Invalid planned release'; end if;
   label_text:=pg_catalog.btrim(pg_catalog.regexp_replace(label_text,'[[:space:]]+',' ','g'));
   if length(label_text) not between 1 and 200 then raise exception 'Invalid planned release'; end if;
   products:=products||(jsonb_build_object('format',item->>'format')
    ||case when label_text is null then '{}'::jsonb else jsonb_build_object('label',label_text) end);
  end loop;
 end if;
 if p_release ? 'promotional_links' then
  if jsonb_array_length(p_release->'promotional_links')>20 then raise exception 'Invalid planned release'; end if;
  for item in select value from jsonb_array_elements(p_release->'promotional_links') loop
   if jsonb_typeof(item)<>'object' then raise exception 'Invalid planned release'; end if;
   if exists(select 1 from jsonb_object_keys(item) as field(key) where field.key not in ('kind','url'))
    or jsonb_typeof(item->'kind') is distinct from 'string' or jsonb_typeof(item->'url') is distinct from 'string'
    or item->>'kind' not in ('pre_save','smart_link','landing_page','teaser')
   then raise exception 'Invalid planned release'; end if;
   url_text:=item->>'url';
   -- A pre-save or smart link is a promotional locator, never a store identifier.
   if length(url_text)>2048 or url_text !~ '^https?://[^[:space:][:cntrl:]]+$' then raise exception 'Invalid planned release'; end if;
   links:=links||jsonb_build_object('kind',item->>'kind','url',url_text);
  end loop;
 end if;
 if p_release ? 'recording_subject_ids' then
  if jsonb_array_length(p_release->'recording_subject_ids')>100 then raise exception 'Invalid planned release'; end if;
  for item in select value from jsonb_array_elements(p_release->'recording_subject_ids') loop
   if jsonb_typeof(item)<>'string'
    or (item#>>'{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   then raise exception 'Invalid planned release'; end if;
   recording_id:=(item#>>'{}')::uuid;
   if recordings ? recording_id::text then raise exception 'Invalid planned release'; end if;
   -- The recording must already be saved evidence in this workspace: an internal unreleased
   -- recording or an ISRC-backed recording with a current, non-withdrawn accepted document.
   if not exists(
    select 1 from public.context_subjects s
    join public.context_documents d on d.subject_id=s.id and d.owner_id=p_owner
    join public.context_results r on r.id=d.current_result_id and r.owner_id=p_owner and r.status='accepted'
    where s.id=recording_id and s.kind in ('unreleased_recording','recording')
     and not exists(select 1 from public.context_result_sources rs
      join public.context_source_versions v on v.id=rs.source_version_id
      join public.context_sources src on src.id=v.source_id
      where rs.result_id=r.id and (src.withdrawn_at is not null or v.removed_at is not null)))
   then raise exception 'Planned release references an unknown recording'; end if;
   slot:=slot+1;
   recordings:=recordings||to_jsonb(recording_id::text);
   tracklist:=tracklist||jsonb_build_object('position',slot,'recordingSubjectId',recording_id);
  end loop;
 end if;
 normalized:=jsonb_build_object('title',title_text,'lifecycle_state',lifecycle,'products',products,
  'promotional_links',links,'recording_subject_ids',recordings);
 if date_text is not null then normalized:=normalized||jsonb_build_object('planned_release_date',date_text); end if;
 input_hash:=encode(sha256(convert_to('planned-release-v1:'||normalized::text,'UTF8')),'hex');
 opaque:=encode(sha256(convert_to('planned-release-input-v1:'||p_owner::text||':'||p_key,'UTF8')),'hex');
 uri:='urn:recoup:planned-release-input:'||opaque;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('recoup','planned_release_input',opaque,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,input_hash,
  jsonb_build_object('kind','planned_release','title',title_text,'contentHash',input_hash,'identityConfirmed',false))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict req from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if req.input_fingerprint<>input_hash or req.resource_id<>resource
 then raise exception 'Idempotency key already used for different input'; end if;
 if req.status in ('completed','partial','cancelled') then return to_jsonb(req)-'claim_token'; end if;
 insert into public.context_subjects(kind,resource_id) values('planned_release',resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 -- Store identifiers are a fixed unknown set; callers can never assign them through this path.
 snapshot:=jsonb_build_object('release',normalized-'recording_subject_ids','tracklist',tracklist,
  'storeIds',jsonb_build_object('spotify','unknown','apple_music','unknown','upc','unknown'),
  'contentHash',input_hash,'submittedBy',p_actor,'identityConfirmed',false,'metadataVerified',false,
  'rightsVerified',false,'scope','workspace_private');
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'customer')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'planned_release') on conflict do nothing;
 select * into strict document from public.context_documents
 where owner_id=p_owner and subject_id=subject and topic='planned_release' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,req.id,'planned_release:'||subject,1,'succeeded','user_submission','planned-release-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into attempt_key;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,attempt_key,subject,'planned_release',snapshot_hash,'accepted','customer_assertion',snapshot,snapshot,
  '{"extent":"partial","scope":"submitted_planned_release","storeIds":{"spotify":"unknown","apple_music":"unknown","upc":"unknown"}}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision)
 then raise exception 'Planned release acceptance conflict'; end if;
 update public.context_requests set status='partial',
  output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',jsonb_build_array('UPC and store identifiers not assigned','Release metadata not verified')),
  updated_at=now() where id=req.id returning * into req;
 return to_jsonb(req)-'claim_token';
end $$;
revoke all on function public.create_context_planned_release_request(uuid,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_context_planned_release_request(uuid,uuid,jsonb,text) to service_role;

create function public.list_context_unreleased_recording_request_target(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject public.context_subjects;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') or req.input->>'kind'<>'unreleased_recording'
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
  or jsonb_array_length(req.output->'subjectIds')<>1
 then raise exception 'Unreleased recording request is not ready'; end if;
 select s.* into strict subject from public.context_subjects s
 join public.context_resources r on r.id=s.resource_id and r.id=req.resource_id
  and r.provider='recoup' and r.resource_kind='recording_input'
 join public.context_documents d on d.owner_id=p_owner and d.subject_id=s.id and d.topic='unreleased_recording'
 join public.context_results result on result.id=d.current_result_id and result.owner_id=p_owner
  and result.status='accepted' and result.evidence_kind='customer_assertion'
 where s.kind='unreleased_recording' and req.output->'subjectIds' ? s.id::text
  and result.normalized_response->>'contentHash'=req.input->>'contentHash'
  and exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
   join public.context_sources source on source.id=v.source_id and source.owner_id=p_owner and source.withdrawn_at is null
   where rs.result_id=result.id and rs.owner_id=p_owner and source.kind='customer');
 return jsonb_build_object('subjectId',subject.id,'kind','unreleased_recording','identityConfirmed',false,
  'availableFields',jsonb_build_array('submitted_title'),'reusableModules','[]'::jsonb);
end $$;
revoke all on function public.list_context_unreleased_recording_request_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_unreleased_recording_request_target(uuid,uuid) to service_role;

create function public.list_context_planned_release_request_target(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject public.context_subjects;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') or req.input->>'kind'<>'planned_release'
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
  or jsonb_array_length(req.output->'subjectIds')<>1
 then raise exception 'Planned release request is not ready'; end if;
 select s.* into strict subject from public.context_subjects s
 join public.context_resources r on r.id=s.resource_id and r.id=req.resource_id
  and r.provider='recoup' and r.resource_kind='planned_release_input'
 join public.context_documents d on d.owner_id=p_owner and d.subject_id=s.id and d.topic='planned_release'
 join public.context_results result on result.id=d.current_result_id and result.owner_id=p_owner
  and result.status='accepted' and result.evidence_kind='customer_assertion'
 where s.kind='planned_release' and req.output->'subjectIds' ? s.id::text
  and result.normalized_response->>'contentHash'=req.input->>'contentHash'
  and exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
   join public.context_sources source on source.id=v.source_id and source.owner_id=p_owner and source.withdrawn_at is null
   where rs.result_id=result.id and rs.owner_id=p_owner and source.kind='customer');
 return jsonb_build_object('subjectId',subject.id,'kind','planned_release','identityConfirmed',false,
  'availableFields',jsonb_build_array('submitted_title','tracklist'),'reusableModules','[]'::jsonb);
end $$;
revoke all on function public.list_context_planned_release_request_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_planned_release_request_target(uuid,uuid) to service_role;
commit;
