-- Run inside a disposable database transaction and roll back the fixture rows.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); album text:=repeat('A',22); track text:=repeat('B',22); single_album text:=repeat('C',22);
 req jsonb; other_req jsonb; subject uuid; module jsonb; claim jsonb; lookup_claim jsonb; saved jsonb; v_result_id uuid; response jsonb; rows integer;
 execution_id uuid:=gen_random_uuid(); wrong_execution_id uuid:=gen_random_uuid(); node_key text; execution_plan jsonb;
begin
 insert into public.accounts(id,name) values(owner,'Release slots fixture'),(outsider,'Other workspace');
 req:=public.create_context_release_request(owner,owner,album,'release-track-slots');
 subject:=(public.list_context_release_request_target(owner,(req->>'id')::uuid)->>'subjectId')::uuid;
 if public.list_context_release_track_slots(owner,(req->>'id')::uuid,subject)->>'state'<>'not_collected'
 then raise exception 'Unverified album appeared to have collected tracks'; end if;
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
 if public.list_context_release_track_slots(owner,(req->>'id')::uuid,subject)->>'state'<>'needs_reconciliation'
 then raise exception 'Saved evidence with missing track rows was shown as an empty release'; end if;
 saved:=public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,v_result_id);
 if saved->>'observedSlots'<>'3' or saved->>'linkedSlots'<>'2' or saved->>'skippedSlots'<>'1' or saved->>'coverage'<>'partial'
 then raise exception 'Observed and unavailable slots were confused'; end if;
 select count(*) into rows from public.context_release_track_slots where owner_id=owner and release_subject_id=subject and source_result_id=v_result_id;
 if rows<>2 then raise exception 'Observed repeated track positions were not preserved'; end if;
 saved:=public.list_context_release_track_slots(owner,(req->>'id')::uuid,subject,-1,1);
 if saved->>'state'<>'ready' or saved->>'hasMore'<>'true' or saved->>'nextCursor'<>'0'
  or saved->'slots'->0->>'spotifyTrackId'<>track or saved->>'unavailableSlots'<>'1'
 then raise exception 'First release track page is incorrect'; end if;
 saved:=public.list_context_release_track_slots(owner,(req->>'id')::uuid,subject,0,1);
 if saved->>'hasMore'<>'false' or saved->'slots'->0->>'slotIndex'<>'1'
 then raise exception 'Second release track page is incorrect'; end if;
 begin
  perform public.claim_context_release_track_isrcs(outsider,(req->>'id')::uuid,subject,v_result_id,repeat('a',64));
  raise exception 'TEST_FAILURE: wrong workspace claimed track lookup';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
 end;
 begin
  perform public.claim_context_release_track_isrcs(owner,(other_req->>'id')::uuid,subject,v_result_id,repeat('a',64));
  raise exception 'TEST_FAILURE: another request claimed this release evidence';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
 end;
 begin
  perform public.claim_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,gen_random_uuid(),repeat('a',64));
  raise exception 'TEST_FAILURE: unrelated result claimed track lookup';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
 end;
 lookup_claim:=public.claim_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,repeat('a',64));
 if lookup_claim->>'state'<>'claimed' or lookup_claim->>'linkedSlots'<>'2' then raise exception 'Current release track lookup was not claimed'; end if;
 lookup_claim:=public.claim_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,repeat('a',64));
 if lookup_claim->>'state'<>'unknown' then raise exception 'Repeated provider lookup was not held for reconciliation'; end if;
 response:=jsonb_build_object('slots',jsonb_build_array(
   jsonb_build_object('slotIndex',0,'spotifyTrackId',track,'state','observed','isrc','USAAA1234567'),
   jsonb_build_object('slotIndex',1,'spotifyTrackId',track,'state','observed','isrc','USAAA1234567')),
  'observations',jsonb_build_array(jsonb_build_object('spotifyTrackId',track,'state','observed',
   'isrc','USAAA1234567','sourceUrl','https://api.spotify.com/v1/tracks/'||track,
   'retrievedAt','2026-09-24T12:00:00Z','elapsedMs',10,'httpStatus',200,'gap',null,
   'raw',jsonb_build_object('id',track,'external_ids',jsonb_build_object('isrc','USAAA1234567')))));
 begin
  perform public.complete_context_release_track_isrcs(outsider,(req->>'id')::uuid,subject,v_result_id,
   (lookup_claim->>'attemptId')::uuid,response);
  raise exception 'TEST_FAILURE: other workspace completed track lookup';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  perform public.complete_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,
   (lookup_claim->>'attemptId')::uuid,jsonb_set(response,'{observations,0,spotifyTrackId}',to_jsonb(repeat('Z',22))));
  raise exception 'TEST_FAILURE: substituted track identity completed';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 begin
  perform public.complete_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,
   (lookup_claim->>'attemptId')::uuid,jsonb_set(response,'{observations,0,isrc}','"USBBB1234567"'::jsonb));
  raise exception 'TEST_FAILURE: invented ISRC completed';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 saved:=public.complete_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,
  (lookup_claim->>'attemptId')::uuid,response);
 if saved->>'state'<>'saved' or saved->>'observedIsrcCount'<>'1' then raise exception 'Verified track evidence was not saved'; end if;
 if (select count(*) from public.context_result_sources where owner_id=owner and result_id=(saved->>'resultId')::uuid)<>2
 then raise exception 'Track and release source lineage were not both saved'; end if;
 node_key:=subject::text||':spotify_release_track_isrcs';
 execution_plan:=jsonb_build_array(jsonb_build_object('key',node_key,'subjectId',subject,
  'module','spotify_release_track_isrcs','state','ready_for_dispatch','dependsOn','[]'::jsonb,
  'sourceResultId',v_result_id));
 perform public.create_context_execution(owner,(req->>'id')::uuid,execution_id,'spotify-release-track-isrcs-v1',execution_plan);
 perform public.save_context_execution_outcome(owner,execution_id,node_key,
  jsonb_build_object('key',node_key,'status','saved','receipt',jsonb_build_object('state','saved','resultId',saved->>'resultId')));
 if (public.read_context_execution(owner,execution_id)->'outcomes'->0->'outcome'->>'status') is distinct from 'saved'
 then raise exception 'Verified track observation did not appear in recorded execution'; end if;
 perform public.create_context_execution(owner,(req->>'id')::uuid,wrong_execution_id,'spotify-release-track-isrcs-v1',execution_plan);
 begin
  perform public.save_context_execution_outcome(owner,wrong_execution_id,node_key,
   jsonb_build_object('key',node_key,'status','saved','receipt',jsonb_build_object('state','saved','resultId',v_result_id)));
  raise exception 'TEST_FAILURE: album result accepted as track lookup outcome';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 if (public.complete_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,
  (lookup_claim->>'attemptId')::uuid,response))->>'resultId' is distinct from saved->>'resultId'
 then raise exception 'Completion replay created another result'; end if;
 if exists(select 1 from public.context_subjects s join public.context_resources r on r.id=s.resource_id where r.provider='spotify' and r.resource_kind='track' and r.provider_id=track)
 then raise exception 'Observed track ISRC created a recording identity'; end if;
 begin
  perform public.list_context_release_track_slots(outsider,(req->>'id')::uuid,subject);
  raise exception 'TEST_FAILURE: wrong workspace read release tracks';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
 end;
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
 if not exists(select 1 from public.context_result_sources rs
  join public.context_source_versions v on v.id=rs.source_version_id
  join public.context_sources s on s.id=v.source_id
  where rs.result_id=(saved->>'resultId')::uuid and s.withdrawn_at is not null)
 then raise exception 'Album source withdrawal did not invalidate track evidence lineage'; end if;
 begin
  perform public.save_context_spotify_release_track_slots(owner,(req->>'id')::uuid,subject,v_result_id);
  raise exception 'TEST_FAILURE: withdrawn provider source produced memberships';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 if public.list_context_release_track_slots(owner,(req->>'id')::uuid,subject)->>'state'<>'not_collected'
 then raise exception 'Withdrawn source remained readable as current'; end if;
 begin
  perform public.claim_context_release_track_isrcs(owner,(req->>'id')::uuid,subject,v_result_id,repeat('a',64));
  raise exception 'TEST_FAILURE: withdrawn release source permitted track lookup';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
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
 or pg_catalog.has_function_privilege('authenticated','public.list_context_release_track_slots(uuid,uuid,uuid,integer,integer)','EXECUTE')
  or pg_catalog.has_function_privilege('authenticated','public.claim_context_release_track_isrcs(uuid,uuid,uuid,uuid,text)','EXECUTE')
 or pg_catalog.has_function_privilege('authenticated','public.complete_context_release_track_isrcs(uuid,uuid,uuid,uuid,uuid,jsonb)','EXECUTE')
 then raise exception 'Browser role may link release tracks'; end if;
end $$;
