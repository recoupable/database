-- Disposable fixture only: request-scoped, evidence-based planner targets.
begin;
do $$
declare owner uuid:=gen_random_uuid(); request uuid; track uuid; unrelated_track uuid; album uuid; profile uuid; second_profile uuid; recording uuid; release_subject uuid; artist_subject uuid; artist uuid:=gen_random_uuid();
 target_data jsonb; first jsonb; second jsonb; third jsonb;
begin
 insert into accounts(id) values(owner),(artist);
 insert into songs(isrc) values('USAT22103065') on conflict do nothing;
 insert into context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','track','2zpWJxfuyxqCYhpsAqH7Uh','https://open.spotify.com/track/2zpWJxfuyxqCYhpsAqH7Uh') returning id into track;
 insert into context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release','3vX9jU6Ix8t7XsAWLoZs10','https://open.spotify.com/album/3vX9jU6Ix8t7XsAWLoZs10') returning id into album;
 insert into context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','artist','1QzqrU2lmiW9l1mSvliVoM','https://open.spotify.com/artist/1QzqrU2lmiW9l1mSvliVoM') returning id into profile;
 insert into context_subjects(kind,song_isrc) values('recording','USAT22103065') returning id into recording;
 insert into context_subjects(kind,resource_id) values('release',album) returning id into release_subject;
 insert into context_subjects(kind,artist_id) values('artist',artist) returning id into artist_subject;
 insert into context_resource_links(resource_id,subject_id,relation,status) values
 (track,recording,'identity','accepted'),(track,release_subject,'release_member','accepted'),(profile,artist_subject,'identity','accepted'),(track,artist_subject,'credited_artist','accepted');
 insert into context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,track,gen_random_uuid()::text,repeat('f',64),'{}','completed',
  jsonb_build_object('subjectIds',jsonb_build_array(recording,release_subject,artist_subject))) returning id into request;
 target_data:=public.list_context_request_targets(owner,request);
 if jsonb_array_length(target_data)<>3 then raise exception 'Not all linked subjects returned'; end if;
 first:=target_data->0; second:=target_data->1; third:=target_data->2;
 if first->>'subjectId'<>recording::text or first->>'kind'<>'recording' or first->>'identityConfirmed'<>'true' or first->'availableFields' ? 'isrc' is not true or first->'availableFields' ? 'spotify_id' is not true then raise exception 'Recording target not verified'; end if;
 if second->>'subjectId'<>release_subject::text or second->>'kind'<>'release' or second->>'identityConfirmed'<>'true' or second->'availableFields' ? 'spotify_id' is not true then raise exception 'Release target not verified'; end if;
 if third->>'subjectId'<>artist_subject::text or third->>'kind'<>'artist' or third->>'identityConfirmed'<>'true' or third->'availableFields' ? 'spotify_id' is not true then raise exception 'Artist target not verified'; end if;
 if public.resolve_context_songstats_lookup(owner,request,recording,'recording','isrc')->>'isrc' is distinct from 'USAT22103065'
  or public.resolve_context_songstats_lookup(owner,request,recording,'recording','spotify_id')->>'spotifyId' is distinct from '2zpWJxfuyxqCYhpsAqH7Uh'
  or public.resolve_context_songstats_lookup(owner,request,artist_subject,'artist','spotify_id')->>'spotifyId' is distinct from '1QzqrU2lmiW9l1mSvliVoM'
 then raise exception 'Songstats request identifiers were not resolved'; end if;
 begin
  perform public.resolve_context_songstats_lookup(owner,request,artist_subject,'recording','isrc');
  raise exception 'TEST_FAILURE: artist passed as recording';
 exception when others then if SQLERRM<>'Songstats identifier not confirmed for subject' then raise; end if; end;
 insert into context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','artist','6pPY9v1Bk7ppYcyDgc94Bf','https://open.spotify.com/artist/6pPY9v1Bk7ppYcyDgc94Bf') returning id into second_profile;
 insert into context_resource_links(resource_id,subject_id,relation,status)
 values(second_profile,artist_subject,'identity','accepted');
 begin
  perform public.resolve_context_songstats_lookup(owner,request,artist_subject,'artist','spotify_id');
  raise exception 'TEST_FAILURE: ambiguous artist identity resolved';
 exception when others then if SQLERRM<>'Ambiguous Songstats artist identity' then raise; end if; end;
 update context_resource_links set status='rejected' where resource_id=second_profile and subject_id=artist_subject;
 insert into context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','track','0UNRELATED00000000000000','https://open.spotify.com/track/0UNRELATED00000000000000') returning id into unrelated_track;
 update context_requests set resource_id=unrelated_track where id=request;
 target_data:=public.list_context_request_targets(owner,request);
 if target_data->0->>'identityConfirmed'<>'false' or target_data->1->>'identityConfirmed'<>'false' or target_data->2->>'identityConfirmed'<>'false' then raise exception 'Unrelated source confirmed request targets'; end if;
 begin
  perform public.resolve_context_songstats_lookup(owner,request,recording,'recording','spotify_id');
  raise exception 'TEST_FAILURE: unrelated track resolved';
 exception when others then if SQLERRM<>'Songstats identifier not confirmed for subject' then raise; end if; end;
 update context_requests set resource_id=track where id=request;
 update context_resource_links set status='rejected' where resource_id=profile and subject_id=artist_subject;
 target_data:=public.list_context_request_targets(owner,request);
 if target_data->2->>'identityConfirmed'<>'false' then raise exception 'Rejected identity still confirmed'; end if;
 begin
  perform public.resolve_context_songstats_lookup(owner,request,artist_subject,'artist','spotify_id');
  raise exception 'TEST_FAILURE: rejected artist identity resolved';
 exception when others then if SQLERRM<>'Songstats identifier not confirmed for subject' then raise; end if; end;
 begin
  perform public.list_context_request_targets(gen_random_uuid(),request);
  raise exception 'TEST_FAILURE: wrong owner read';
 exception when no_data_found then null; end;
 update context_requests set output=jsonb_build_object('subjectIds',jsonb_build_array(gen_random_uuid())) where id=request;
 begin
  perform public.list_context_request_targets(owner,request);
  raise exception 'TEST_FAILURE: missing subject hidden';
 exception when others then if SQLERRM<>'Context request has missing subjects' then raise; end if; end;
 update context_requests set status='cancelled' where id=request;
 begin
  perform public.list_context_request_targets(owner,request);
  raise exception 'TEST_FAILURE: cancelled request used';
 exception when others then if SQLERRM<>'Request is not ready for enrichment' then raise; end if; end;
 if has_function_privilege('anon','public.list_context_request_targets(uuid,uuid)','execute') then raise exception 'Browser target access granted'; end if;
 if has_function_privilege('anon','public.resolve_context_songstats_lookup(uuid,uuid,uuid,text,text)','execute')
  or has_function_privilege('authenticated','public.resolve_context_songstats_lookup(uuid,uuid,uuid,text,text)','execute')
 then raise exception 'Browser Songstats resolver access granted'; end if;
end $$;
rollback;
