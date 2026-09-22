do $$
declare owner uuid; actor uuid; resource uuid; request uuid; token uuid; payload jsonb; result jsonb; n integer; release_ids uuid[]:='{}'; recording_ids uuid[]:='{}'; release_subject uuid; recording_subject uuid; legacy_count bigint;
begin
 select owner_id,created_by into strict owner,actor from public.context_requests limit 1;
 select count(*) into legacy_count from public.context_subjects s join public.context_resources r on r.id=s.resource_id where s.kind='release' and r.resource_kind='track';
 for n in 1..3 loop
  insert into public.context_resources(provider,resource_kind,provider_id,canonical_url) values('spotify','track',lpad(n::text,22,'7'),'https://open.spotify.com/track/'||lpad(n::text,22,'7')) returning id into resource;
  token:=gen_random_uuid();
  insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input,status,claim_token) values(owner,actor,resource,gen_random_uuid()::text,repeat('f',64),'{"topics":["release_metadata"]}','running',token) returning id into request;
  payload:=jsonb_build_object('trackId',lpad(n::text,22,'7'),'title','Fixture track '||n,'isrc',case when n<3 then 'USZZZ2600001' else 'USZZZ2600002' end,'artists','[]'::jsonb,'release',jsonb_build_object('id',case when n=1 then repeat('8',22) else repeat('9',22) end,'title',case when n=1 then 'Fixture single' else 'Fixture album' end,'providerType',case when n=1 then 'single' else 'album' end));
  result:=public.commit_spotify_context(owner,request,token,payload);
  select s.id into strict release_subject from public.context_subjects s join public.context_requests q on q.id=request and q.output->'subjectIds' ? s.id::text where s.kind='release';
  select s.id into strict recording_subject from public.context_subjects s join public.context_requests q on q.id=request and q.output->'subjectIds' ? s.id::text where s.kind='recording';
  release_ids:=array_append(release_ids,release_subject); recording_ids:=array_append(recording_ids,recording_subject);
  if public.resolve_context_spotify_release(owner,request,release_subject)->>'releaseId' is distinct from payload->'release'->>'id' then raise exception 'Wrong album mapping'; end if;
  if not exists(select 1 from public.context_resource_links where resource_id=resource and subject_id=release_subject and relation='release_member') then raise exception 'Missing release membership'; end if;
  if exists(select 1 from public.context_documents d join public.context_results r on r.id=d.current_result_id where d.owner_id=owner and d.subject_id=release_subject and d.topic='release_metadata' and r.normalized_response ? 'trackId') then raise exception 'Track payload polluted album metadata'; end if;
 end loop;
 if release_ids[1]=release_ids[2] or release_ids[2]<>release_ids[3] then raise exception 'Wrong release grouping'; end if;
 if recording_ids[1]<>recording_ids[2] or recording_ids[2]=recording_ids[3] then raise exception 'Wrong recording reuse'; end if;
 if legacy_count<>(select count(*) from public.context_subjects s join public.context_resources r on r.id=s.resource_id where s.kind='release' and r.resource_kind='track') then raise exception 'Legacy evidence subjects rewritten'; end if;
end $$;
