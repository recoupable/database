do $$
declare owner uuid; actor uuid; resource uuid; legacy uuid; req uuid; first_result jsonb; second_result jsonb; before_count bigint; payload jsonb;
begin
 select owner_id,created_by into strict owner,actor from public.context_requests limit 1;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url) values('spotify','track',repeat('4',22),'https://open.spotify.com/track/'||repeat('4',22)) returning id into resource;
 insert into public.context_subjects(kind,resource_id) values('release',resource) returning id into legacy;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output) values(owner,actor,resource,gen_random_uuid()::text,repeat('b',64),'{}','partial',jsonb_build_object('subjectIds',jsonb_build_array(legacy::text))) returning id into req;
 begin perform public.correct_context_spotify_release(owner,req,legacy); raise exception 'TEST_FAILURE: guessed missing source'; exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 payload:=jsonb_build_object('trackId',repeat('4',22),'release',jsonb_build_object('id',repeat('5',22),'title','Fixture single'),'raw',jsonb_build_object('id',repeat('4',22),'album',jsonb_build_object('id',repeat('5',22))));
 perform public.save_context_metadata(owner,req,legacy,'release_metadata','https://open.spotify.com/track/'||repeat('4',22),payload);
 select count(*) into before_count from public.context_results where subject_id=legacy;
 first_result:=public.correct_context_spotify_release(owner,req,legacy);
 second_result:=public.correct_context_spotify_release(owner,req,legacy);
 if first_result->>'subjectId' is distinct from second_result->>'subjectId' or second_result->>'reused'<>'true' then raise exception 'Repair not idempotent'; end if;
 if before_count<>(select count(*) from public.context_results where subject_id=legacy) then raise exception 'Historical evidence removed'; end if;
 if public.resolve_context_spotify_release(owner,req,(first_result->>'subjectId')::uuid)->>'releaseId'<>repeat('5',22) then raise exception 'Wrong repaired identity'; end if;
 begin perform public.correct_context_spotify_release(gen_random_uuid(),req,legacy); raise exception 'TEST_FAILURE: wrong owner'; exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
end $$;
