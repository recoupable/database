-- Run inside a disposable database transaction and roll back all rows.
do $$
declare owner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); album text:=repeat('A',22); req jsonb; target jsonb; saved public.context_results; wrong_resource uuid; wrong_subject uuid;
begin
 insert into public.accounts(id,name) values(owner,'Release fixture owner'),(outsider,'Other workspace');
 begin
  perform public.create_context_release_request(owner,owner,'not-an-album','bad');
  raise exception 'TEST_FAILURE: invalid album identifier accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Invalid Spotify release identifier' then raise; end if;
 end;
 req:=public.create_context_release_request(owner,owner,album,'release-entry');
 if req->>'status'<>'partial' or req->'input'->>'kind'<>'release' then raise exception 'Release locator was not saved'; end if;
 target:=public.list_context_release_request_target(owner,(req->>'id')::uuid);
 if target->>'kind'<>'release' or target->>'identityConfirmed'<>'false'
 or (target->'availableFields' ? 'spotify_id') is not true then raise exception 'Submitted locator was incorrectly verified'; end if;
 if public.resolve_context_spotify_release(owner,(req->>'id')::uuid,(target->>'subjectId')::uuid)->>'releaseId'<>album
 then raise exception 'Submitted locator cannot be resolved for verification'; end if;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release',repeat('B',22),'https://open.spotify.com/album/'||repeat('B',22)) returning id into wrong_resource;
 insert into public.context_subjects(kind,resource_id) values('release',wrong_resource) returning id into wrong_subject;
 update public.context_requests set output=jsonb_build_object('subjectIds',jsonb_build_array(wrong_subject)) where id=(req->>'id')::uuid;
 begin
  perform public.resolve_context_spotify_release(owner,(req->>'id')::uuid,wrong_subject);
  raise exception 'TEST_FAILURE: unrelated album resolved through release request';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Spotify release context not accessible in selected request' then raise; end if;
 end;
 update public.context_requests set output=jsonb_build_object('subjectIds',jsonb_build_array((target->>'subjectId')::uuid),'gaps',jsonb_build_array('Spotify release metadata not verified')) where id=(req->>'id')::uuid;
 select r.* into strict saved from public.context_results r
 where r.owner_id=owner and r.subject_id=(target->>'subjectId')::uuid and r.topic='release_locator';
 if saved.evidence_kind<>'customer_assertion' or saved.normalized_response->>'metadataVerified'<>'false'
 or saved.normalized_response ? 'title' then raise exception 'Release metadata was invented'; end if;
 if (public.create_context_release_request(owner,owner,album,'release-entry')->>'id')<>req->>'id'
 then raise exception 'Release locator replay created another request'; end if;
 begin
  perform public.create_context_release_request(owner,owner,repeat('B',22),'release-entry');
  raise exception 'TEST_FAILURE: conflicting idempotency key accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLERRM<>'Idempotency key already used for different input' then raise; end if;
 end;
 begin
  perform public.list_context_release_request_target(outsider,(req->>'id')::uuid);
  raise exception 'TEST_FAILURE: another workspace read release target';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' or SQLSTATE<>'P0002' then raise; end if;
 end;
 if pg_catalog.has_function_privilege('authenticated','public.create_context_release_request(uuid,uuid,text,text)','EXECUTE')
 or pg_catalog.has_function_privilege('authenticated','public.list_context_release_request_target(uuid,uuid)','EXECUTE')
 then raise exception 'Browser role can execute release context function'; end if;
end $$;
