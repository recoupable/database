do $$
declare req public.context_requests; subject uuid; resource uuid; legacy uuid; owner uuid:=gen_random_uuid(); track uuid; release text := '3vX9jU6Ix8t7XsAWLoZs10';
begin
 insert into public.accounts(id,name) values(owner,'Release scope fixture');
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','track','2zpWJxfuyxqCYhpsAqH7Uh','https://open.spotify.com/track/2zpWJxfuyxqCYhpsAqH7Uh')
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into track;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,output)
 values(owner,owner,track,'release-scope-fixture',repeat('a',64),jsonb_build_object('url','https://open.spotify.com/track/2zpWJxfuyxqCYhpsAqH7Uh'),'partial',jsonb_build_object('subjectIds',jsonb_build_array())) returning * into req;
 select s.id into legacy from public.context_subjects s join public.context_resources x on x.id=s.resource_id where s.kind='release' and x.resource_kind='track' and req.output->'subjectIds' ? s.id::text limit 1;
 if legacy is not null then
  begin
   perform public.resolve_context_spotify_release(req.owner_id,req.id,legacy);
   raise exception 'TEST_FAILURE: track-backed legacy release accepted as album';
  exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 end if;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url) values('spotify','release',release,'https://open.spotify.com/album/'||release) on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_subjects(kind,resource_id) values('release',resource) on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 update public.context_requests set output=jsonb_set(output,'{subjectIds}',coalesce(output->'subjectIds','[]'::jsonb)||jsonb_build_array(subject::text)) where id=req.id;
 begin
  perform public.resolve_context_spotify_release(req.owner_id,req.id,subject);
  raise exception 'TEST_FAILURE: unlinked album accepted by track request';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 insert into public.context_resource_links(resource_id,subject_id,relation,status)
 values(req.resource_id,subject,'release_member','accepted');
 if public.resolve_context_spotify_release(req.owner_id,req.id,subject)->>'releaseId' is distinct from release then raise exception 'Wrong release'; end if;
 begin
  perform public.resolve_context_spotify_release(gen_random_uuid(),req.id,subject);
  raise exception 'TEST_FAILURE: wrong owner accepted';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
 update public.context_requests set output=jsonb_set(output,'{subjectIds}','[]'::jsonb) where id=req.id;
 begin
  perform public.resolve_context_spotify_release(req.owner_id,req.id,subject);
  raise exception 'TEST_FAILURE: detached release accepted';
 exception when others then if SQLERRM like 'TEST_FAILURE:%' then raise; end if; end;
end $$;
