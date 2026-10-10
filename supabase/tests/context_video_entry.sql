-- Run inside a disposable database transaction and roll back all rows.
-- Covers the single-video YouTube locator entry: saved as an unresolved video subject,
-- scoped to one workspace, replayable by key, with no artist/recording/lyrics side effects.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); video text:='AbCdEfGhI_1'; other text:='OtherIdAB_2'; video_input text;
 req jsonb; again jsonb; resubmit jsonb; second jsonb; foreign_req jsonb; docs jsonb; saved public.context_results; subject uuid; link public.context_resource_links;
 accounts_before bigint; requests_before bigint; results_before bigint; attempts_before bigint; revision_before bigint; source uuid;
begin
 insert into public.accounts(id,name) values(owner,'Video fixture owner'),(outsider,'Other workspace');
 select count(*) into accounts_before from public.accounts;
 -- Eleven URL-safe characters are a valid shape; shorter, longer, spaced, empty and null are not.
 foreach video_input in array array['short','AbCdEfGhI_12','not a video','',null] loop
  begin
   perform public.create_context_video_request(owner,owner,video_input,'bad');
   raise exception 'TEST_FAILURE: invalid video identifier accepted: %',coalesce(video_input,'<null>');
  exception when others then
   if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid YouTube video identifier' then raise; end if;
  end;
 end loop;
 begin
  perform public.create_context_video_request(owner,owner,'https://www.youtube.com/watch?v='||video,'bad-url');
  raise exception 'TEST_FAILURE: full URL accepted as identifier';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid YouTube video identifier' then raise; end if;
 end;

 req:=public.create_context_video_request(owner,owner,video,'video-entry');
 if req->>'status'<>'partial' or req->'input'->>'kind'<>'video' or req->'input'->>'videoId'<>video
 or req->'input'->>'identityConfirmed'<>'false' or req->'input'->>'url'<>'https://www.youtube.com/watch?v='||video
 then raise exception 'Video locator was not saved as an unresolved partial request'; end if;
 if req ? 'claim_token' then raise exception 'Claim token leaked'; end if;
 if jsonb_array_length(req->'output'->'subjectIds')<>1 then raise exception 'Expected exactly one video subject'; end if;
 subject:=(req->'output'->'subjectIds'->>0)::uuid;
 if jsonb_array_length(req->'output'->'gaps')<>6 then raise exception 'Expected six explicit gaps'; end if;
 if not exists(select 1 from jsonb_array_elements(req->'output'->'gaps') g where g->>'topic'='uploader_attribution' and g->>'status'='unresolved')
 or not exists(select 1 from jsonb_array_elements(req->'output'->'gaps') g where g->>'topic'='recording_match' and g->>'status'='unresolved')
 or not exists(select 1 from jsonb_array_elements(req->'output'->'gaps') g where g->>'topic'='captions' and g->>'status'='uncollected')
 or not exists(select 1 from jsonb_array_elements(req->'output'->'gaps') g where g->>'topic'='video_metadata' and g->>'status'='uncollected')
 or not exists(select 1 from jsonb_array_elements(req->'output'->'gaps') g where g->>'topic'='media_version' and g->>'status'='unknown')
 or not exists(select 1 from jsonb_array_elements(req->'output'->'gaps') g where g->>'topic'='video_narrative' and g->>'status'='unavailable')
 then raise exception 'Gap states are not the expected distinct unresolved/uncollected/unknown/unavailable set'; end if;

 if not exists(select 1 from public.context_subjects s join public.context_resources r on r.id=s.resource_id
  where s.id=subject and s.kind='video' and s.artist_id is null and s.song_isrc is null
  and r.provider='youtube' and r.resource_kind='video' and r.provider_id=video)
 then raise exception 'Video subject is not backed by the YouTube video resource'; end if;
 select l.* into strict link from public.context_resource_links l join public.context_subjects s on s.id=l.subject_id
  where l.subject_id=subject and l.relation='identity';
 if link.status<>'accepted' or link.evidence->>'source'<>'submitted_youtube_video_url' then raise exception 'Locator identity evidence missing'; end if;
 if exists(select 1 from public.context_resource_links where subject_id=subject and relation in ('credited_artist','release_member'))
 then raise exception 'Video was linked to an artist or release without evidence'; end if;

 select r.* into strict saved from public.context_results r where r.owner_id=owner and r.subject_id=subject and r.topic='video_locator';
 if saved.evidence_kind<>'customer_assertion' or saved.status<>'accepted'
 or saved.normalized_response->>'metadataVerified'<>'false' or saved.normalized_response->>'uploaderIsArtist'<>'unknown'
 or saved.normalized_response->>'recordingMatch'<>'unresolved' or saved.normalized_response->>'captions'<>'uncollected'
 or saved.normalized_response->>'language'<>'unknown' or saved.normalized_response->>'mediaVersion'<>'unknown'
 or saved.normalized_response ? 'title' or saved.normalized_response ? 'channel' or saved.normalized_response ? 'lyrics'
 or saved.coverage->>'extent'<>'partial' or saved.coverage->>'scope'<>'submitted_locator'
 then raise exception 'Video metadata, attribution or lyrics were invented'; end if;
 if not exists(select 1 from public.context_attempts a where a.id=saved.attempt_id and a.provider='user_submission'
  and a.provider_cost_micros=0 and a.provider_cost_status='confirmed' and a.recipe_version='youtube-video-url-v1')
 then raise exception 'Locator attempt is not a zero-cost confirmed user submission'; end if;

 if (select count(*) from public.context_documents where owner_id=owner)<>1
 or not exists(select 1 from public.context_documents where owner_id=owner and subject_id=subject and topic='video_locator' and current_result_id=saved.id)
 then raise exception 'Expected exactly one accepted video_locator document'; end if;
 if exists(select 1 from public.context_documents where topic in ('lyrics','song_summary','artist_metadata','artist_brand','release_metadata','video_narrative','era','artwork_branding'))
 then raise exception 'Song or artist documents were written from a video locator'; end if;
 docs:=public.read_context_documents(owner,(req->>'id')::uuid);
 if jsonb_array_length(docs)<>1 or docs->0->>'topic'<>'video_locator' or docs->0->>'evidenceKind'<>'customer_assertion'
 or docs->0->>'coverage'<>'partial' or docs->0->>'subjectId'<>subject::text
 then raise exception 'read_context_documents does not expose the single locator document'; end if;

 -- No artist, roster, recording or identifier rows were created by saving a video URL.
 if (select count(*) from public.accounts)<>accounts_before then raise exception 'Accounts were created'; end if;
 if (select count(*) from public.account_artist_ids)<>0 then raise exception 'Roster rows were created'; end if;
 if (select count(*) from public.songs)<>0 or (select count(*) from public.song_identifiers)<>0 then raise exception 'Recording rows were created'; end if;
 if exists(select 1 from public.context_subjects where kind in ('artist','recording','release')) then raise exception 'Artist, recording or release subjects were created'; end if;

 -- Replay with the same key and video returns the same request without new rows.
 select count(*),(select count(*) from public.context_results),(select count(*) from public.context_attempts)
  into requests_before,results_before,attempts_before from public.context_requests;
 again:=public.create_context_video_request(owner,owner,video,'video-entry');
 if again->>'id'<>req->>'id' or again->>'status'<>'partial' then raise exception 'Replay created another request'; end if;
 if (select count(*) from public.context_requests)<>requests_before or (select count(*) from public.context_results)<>results_before
 or (select count(*) from public.context_attempts)<>attempts_before then raise exception 'Replay wrote new rows'; end if;
 begin
  perform public.create_context_video_request(owner,owner,other,'video-entry');
  raise exception 'TEST_FAILURE: conflicting idempotency key accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;

 -- Re-submitting the same video with a new key reuses the subject, source and document:
 -- it appends one request, attempt and accepted result and advances the single locator document.
 select revision into strict revision_before from public.context_documents where owner_id=owner and subject_id=subject and topic='video_locator';
 resubmit:=public.create_context_video_request(owner,owner,video,'video-entry-resubmit');
 if resubmit->>'id'=req->>'id' or resubmit->>'status'<>'partial' or (resubmit->'output'->'subjectIds'->>0)::uuid<>subject
 then raise exception 'Resubmission did not reuse the video subject in a new partial request'; end if;
 if (select count(*) from public.context_requests)<>requests_before+1 or (select count(*) from public.context_attempts)<>attempts_before+1
 or (select count(*) from public.context_results)<>results_before+1
 then raise exception 'Resubmission did not append exactly one request, attempt and result'; end if;
 if (select count(*) from public.context_subjects)<>1 or (select count(*) from public.context_resources)<>1
 or (select count(*) from public.context_sources where owner_id=owner)<>1 or (select count(*) from public.context_documents where owner_id=owner)<>1
 then raise exception 'Resubmission duplicated the subject, resource, source or document'; end if;
 if not exists(select 1 from public.context_documents where owner_id=owner and subject_id=subject and topic='video_locator'
  and revision=revision_before+1 and current_result_id<>saved.id)
 then raise exception 'Resubmission did not advance the single locator document'; end if;
 if (select count(*) from public.account_artist_ids)<>0 or (select count(*) from public.songs)<>0
 or exists(select 1 from public.context_documents where topic<>'video_locator')
 then raise exception 'Resubmission created artist, recording or non-locator rows'; end if;

 -- A second video for the same workspace is a distinct subject; the first document is untouched.
 select revision into strict revision_before from public.context_documents where owner_id=owner and subject_id=subject and topic='video_locator';
 second:=public.create_context_video_request(owner,owner,other,'video-entry-2');
 if second->>'id'=req->>'id' or (second->'output'->'subjectIds'->>0)::uuid=subject then raise exception 'Second video reused the first subject'; end if;
 if (select revision from public.context_documents where owner_id=owner and subject_id=subject and topic='video_locator')<>revision_before
 then raise exception 'Second video rewrote the first locator document'; end if;

 -- Another workspace cannot read the request; its own save of the same video is scoped separately.
 if public.read_context_request(outsider,(req->>'id')::uuid) is not null then raise exception 'Another workspace read the video request'; end if;
 if jsonb_array_length(public.read_context_documents(outsider,(req->>'id')::uuid))<>0 then raise exception 'Another workspace read locator documents'; end if;
 foreign_req:=public.create_context_video_request(outsider,outsider,video,'video-entry');
 if foreign_req->>'id'=req->>'id' or foreign_req->>'owner_id'<>outsider::text then raise exception 'Workspaces shared a request'; end if;
 if (select count(*) from public.context_documents where subject_id=subject and topic='video_locator')<>2
 or (select count(*) from public.context_documents where owner_id=owner and subject_id=subject)<>1
 then raise exception 'Locator documents are not owner scoped'; end if;
 if jsonb_array_length(public.read_context_documents(owner,(req->>'id')::uuid))<>1 then raise exception 'Owner read leaked across workspaces'; end if;

 -- Withdrawing the submitted source removes the locator from reads without deleting history.
 select s.id into strict source from public.context_sources s where s.owner_id=owner and s.kind='customer' and s.source_url='https://www.youtube.com/watch?v='||video;
 if not public.withdraw_context_source(owner,source) then raise exception 'Source withdrawal failed'; end if;
 if jsonb_array_length(public.read_context_documents(owner,(req->>'id')::uuid))<>0 then raise exception 'Withdrawn locator still readable'; end if;
 if jsonb_array_length(public.read_context_documents(outsider,(foreign_req->>'id')::uuid))<>1 then raise exception 'Withdrawal crossed workspaces'; end if;

 if pg_catalog.has_function_privilege('authenticated','public.create_context_video_request(uuid,uuid,text,text)','EXECUTE')
 or pg_catalog.has_function_privilege('anon','public.create_context_video_request(uuid,uuid,text,text)','EXECUTE')
 then raise exception 'Browser role can execute video context function'; end if;
 if not pg_catalog.has_function_privilege('service_role','public.create_context_video_request(uuid,uuid,text,text)','EXECUTE')
 then raise exception 'Service role cannot execute video context function'; end if;
 raise notice 'PASS: context_video_entry';
end $$;
