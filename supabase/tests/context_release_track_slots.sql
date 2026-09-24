-- Run inside a disposable database transaction and roll back the fixture rows.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); album text:=repeat('A',22); track text:=repeat('B',22); single_album text:=repeat('C',22);
 req jsonb; other_req jsonb; subject uuid; module jsonb; claim jsonb; saved jsonb; v_result_id uuid; response jsonb; rows integer;
begin
 insert into public.accounts(id,name) values(owner,'Release slots fixture'),(outsider,'Other workspace');
 req:=public.create_context_release_request(owner,owner,album,'release-track-slots');
 subject:=(public.list_context_release_request_target(owner,(req->>'id')::uuid)->>'subjectId')::uuid;
 module:=jsonb_build_object('key','spotify-release-pages-v1','topic','spotify_release_context','subjectId',subject,
  'provider','spotify','model','none','evidenceKind','observation','fingerprint',repeat('f',64),
  'sources',jsonb_build_array(jsonb_build_object('url','https://api.spotify.com/v1/albums/'||album,'kind','provider_metadata','content',jsonb_build_object('role','lookup_request'))));
 claim:=public.claim_context_enrichment(owner,(req->>'id')::uuid,module);
 if claim->>'state'<>'claimed' then raise exception 'Provider attempt not claimed'; end if;
 response:=jsonb_build_object('releaseId',album,'album',jsonb_build_object('id',album),
  'tracks',jsonb_build_array(
   jsonb_build_object('id',track,'type','track','disc_number',1,'track_number',1),
   jsonb_build_object('id',track,'type','track','disc_number',1,'track_number',2),
   jsonb_build_object('name','Unavailable track slot')),
  'trackCoverage',jsonb_build_object('extent','partial','collectedSlots',3,'reportedTotal',4));
 saved:=public.complete_context_enrichment(owner,(req->>'id')::uuid,(claim->>'attemptId')::uuid,
  jsonb_build_object('content',response,'coverage','partial','trace',jsonb_build_object('provider','spotify'),
   'costUsd',null,'costStatus','unknown','observedSources',jsonb_build_array(
    jsonb_build_object('url','https://api.spotify.com/v1/albums/'||album,'kind','provider_metadata','content',jsonb_build_object('pages',jsonb_build_array(jsonb_build_object('payload',response)))))));
 v_result_id:=(saved->>'resultId')::uuid;
 begin
  perform public.save_context_spotify_release_track_slots(outsider,(req->>'id')::uuid,subject,v_result_id);
  raise exception 'TEST_FAILURE: wrong workspace linked tracks';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  perform public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,gen_random_uuid());
  raise exception 'TEST_FAILURE: invented source result linked tracks';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 other_req:=public.create_context_release_request(owner,owner,album,'same-album-different-request');
 begin
  perform public.save_context_spotify_release_track_slots(owner,(other_req->>'id')::uuid,subject,v_result_id);
  raise exception 'TEST_FAILURE: evidence from another request linked tracks';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 if exists(select 1 from public.context_release_track_slots where owner_id=owner) then raise exception 'Tracks linked before explicit source check'; end if;
 saved:=public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,v_result_id);
 if saved->>'observedSlots'<>'3' or saved->>'linkedSlots'<>'2' or saved->>'skippedSlots'<>'1' or saved->>'coverage'<>'partial'
 then raise exception 'Observed and unavailable slots were confused'; end if;
 select count(*) into rows from public.context_release_track_slots where owner_id=owner and release_subject_id=subject and source_result_id=v_result_id;
 if rows<>2 then raise exception 'Observed repeated track positions were not preserved'; end if;
 if exists(select 1 from public.context_subjects s join public.context_resources r on r.id=s.resource_id where r.provider='spotify' and r.resource_kind='track' and r.provider_id=track)
 then raise exception 'Spotify track slot was mistaken for a confirmed recording'; end if;
 perform public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,v_result_id);
 select count(*) into rows from public.context_release_track_slots where owner_id=owner and source_result_id=v_result_id;
 if rows<>2 then raise exception 'Idempotent replay duplicated slots'; end if;
 update public.context_results set normalized_response=jsonb_set(normalized_response,'{album,id}',to_jsonb(repeat('Z',22))) where id=v_result_id;
 begin
  perform public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,v_result_id);
  raise exception 'TEST_FAILURE: mismatched album produced memberships';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Release result does not contain verified Spotify track slots' then raise; end if;
 end;
 update public.context_results set normalized_response=response where id=v_result_id;
 update public.context_sources set withdrawn_at=now() where id in (
  select v.source_id from public.context_result_sources rs
  join public.context_source_versions v on v.id=rs.source_version_id where rs.result_id=v_result_id);
 begin
  perform public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,v_result_id);
  raise exception 'TEST_FAILURE: withdrawn provider source produced memberships';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 req:=public.create_context_release_request(owner,owner,single_album,'single-track-release');
 subject:=(public.list_context_release_request_target(owner,(req->>'id')::uuid)->>'subjectId')::uuid;
 module:=module||jsonb_build_object('subjectId',subject,'fingerprint',repeat('e',64),
  'sources',jsonb_build_array(jsonb_build_object('url','https://api.spotify.com/v1/albums/'||single_album,'kind','provider_metadata','content',jsonb_build_object('role','lookup_request'))));
 claim:=public.claim_context_enrichment(owner,(req->>'id')::uuid,module);
 response:=jsonb_build_object('releaseId',single_album,'album',jsonb_build_object('id',single_album,'album_type','single'),
  'tracks',jsonb_build_array(jsonb_build_object('id',track,'type','track','disc_number',1,'track_number',1)),
  'trackCoverage',jsonb_build_object('extent','full','collectedSlots',1,'reportedTotal',1));
 saved:=public.complete_context_enrichment(owner,(req->>'id')::uuid,(claim->>'attemptId')::uuid,
  jsonb_build_object('content',response,'coverage','partial','trace',jsonb_build_object('provider','spotify'),
   'costUsd',null,'costStatus','unknown','observedSources',jsonb_build_array(
    jsonb_build_object('url','https://api.spotify.com/v1/albums/'||single_album,'kind','provider_metadata','content',jsonb_build_object('pages',jsonb_build_array(jsonb_build_object('payload',response)))))));
 saved:=public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,(saved->>'resultId')::uuid);
 if saved->>'linkedSlots'<>'1' or saved->>'coverage'<>'full' then raise exception 'Single release was not linked to its one observed track'; end if;
 if pg_catalog.has_function_privilege('authenticated','public.save_context_spotify_release_track_slots(uuid,uuid,uuid,uuid)','EXECUTE')
 then raise exception 'Browser role may link release tracks'; end if;
end $$;
