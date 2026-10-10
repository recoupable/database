-- A submitted YouTube video URL identifies a locator, not verified video metadata,
-- a recording match, an uploader-as-artist link, captions or lyrics. The uploading
-- channel, performers, credited artists and the recording stay explicitly unresolved
-- until separate evidence links them. No artist, recording, roster or lyrics rows
-- are created, and no song or artist brand document is touched.
begin;
create function public.create_context_video_request(p_owner uuid,p_actor uuid,p_video text,p_key text)
returns jsonb language plpgsql set search_path='' as $$
declare resource uuid; subject uuid; r public.context_requests; request_fingerprint text; uri text;
 source uuid; source_version uuid; document public.context_documents; v_attempt uuid; result uuid;
 snapshot jsonb; snapshot_hash text; gaps jsonb;
begin
 if p_video is null or p_video !~ '^[A-Za-z0-9_-]{11}$' then raise exception 'Invalid YouTube video identifier'; end if;
 request_fingerprint:=encode(sha256(convert_to('youtube-video-locator-v1:'||p_video,'UTF8')),'hex');
 uri:='https://www.youtube.com/watch?v='||p_video;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('youtube','video',p_video,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,request_fingerprint,
  jsonb_build_object('kind','video','url',uri,'videoId',p_video,'identityConfirmed',false))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict r from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if r.input_fingerprint<>request_fingerprint then raise exception 'Idempotency key already used for different input'; end if;
 if r.status in ('completed','partial','cancelled') then return to_jsonb(r)-'claim_token'; end if;
 -- The video is its own subject. It is never attached to an artist, recording or release here.
 insert into public.context_subjects(kind,resource_id) values('video',resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 insert into public.context_resource_links(resource_id,subject_id,relation,status,evidence)
 values(resource,subject,'identity','accepted',jsonb_build_object('source','submitted_youtube_video_url'))
 on conflict(resource_id,subject_id,relation) do nothing;
 if not exists(select 1 from public.context_resource_links where resource_id=resource and subject_id=subject and relation='identity' and status='accepted')
 then raise exception 'Video locator identity is disputed'; end if;
 -- Every unknown stays an explicit unknown. Nothing below is fetched or inferred.
 snapshot:=jsonb_build_object('url',uri,'youtubeVideoId',p_video,'submittedBy',p_actor,
  'metadataVerified',false,'uploaderIsArtist','unknown','recordingMatch','unresolved',
  'captions','uncollected','language','unknown','mediaVersion','unknown');
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'customer')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'video_locator') on conflict do nothing;
 select * into strict document from public.context_documents where owner_id=p_owner and subject_id=subject and topic='video_locator' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,r.id,'video_locator:'||subject,1,'succeeded','user_submission','youtube-video-url-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into v_attempt;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,v_attempt,subject,'video_locator',snapshot_hash,'accepted','customer_assertion',snapshot,snapshot,
  '{"extent":"partial","scope":"submitted_locator","metadataVerified":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision) then raise exception 'Video locator acceptance conflict'; end if;
 gaps:=jsonb_build_array(
  jsonb_build_object('topic','video_metadata','status','uncollected','reason','Title, description and channel were not fetched.'),
  jsonb_build_object('topic','uploader_attribution','status','unresolved','reason','The uploading channel is not assumed to be the artist, a performer or a credited artist.'),
  jsonb_build_object('topic','recording_match','status','unresolved','reason','No recording, release or artist was matched or created for this video.'),
  jsonb_build_object('topic','captions','status','uncollected','reason','Captions and transcripts were not collected; no lyrics were inferred.'),
  jsonb_build_object('topic','media_version','status','unknown','reason','Original, live, remix or dubbed version is unknown.'),
  jsonb_build_object('topic','video_narrative','status','unavailable','reason','Video analysis is not enabled; no narrative or visual interpretation was inferred.'));
 update public.context_requests set status='partial',output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',gaps),updated_at=now()
 where id=r.id returning * into r;
 return to_jsonb(r)-'claim_token';
end $$;
revoke all on function public.create_context_video_request(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.create_context_video_request(uuid,uuid,text,text) to service_role;
commit;
