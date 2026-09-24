-- A submitted Spotify album URL identifies a locator, not verified release
-- metadata or ownership. Singles, EPs and albums all use this release path.
begin;
create function public.create_context_release_request(p_owner uuid,p_actor uuid,p_album text,p_key text)
returns jsonb language plpgsql set search_path='' as $$
declare resource uuid; subject uuid; r public.context_requests; request_fingerprint text; uri text;
 source uuid; source_version uuid; document public.context_documents; v_attempt uuid; result uuid; snapshot jsonb; snapshot_hash text;
begin
 if p_album is null or p_album !~ '^[A-Za-z0-9]{22}$' then raise exception 'Invalid Spotify release identifier'; end if;
 request_fingerprint:=encode(sha256(convert_to('spotify-release-locator-v1:'||p_album,'UTF8')),'hex');
 uri:='https://open.spotify.com/album/'||p_album;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('spotify','release',p_album,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,request_fingerprint,jsonb_build_object('kind','release','url',uri,'releaseId',p_album))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict r from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if r.input_fingerprint<>request_fingerprint then raise exception 'Idempotency key already used for different input'; end if;
 if r.status in ('completed','partial','cancelled') then return to_jsonb(r)-'claim_token'; end if;
 insert into public.context_subjects(kind,resource_id) values('release',resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 insert into public.context_resource_links(resource_id,subject_id,relation,status,evidence)
 values(resource,subject,'identity','accepted',jsonb_build_object('source','submitted_spotify_album_url'))
 on conflict(resource_id,subject_id,relation) do nothing;
 if not exists(select 1 from public.context_resource_links where resource_id=resource and subject_id=subject and relation='identity' and status='accepted')
 then raise exception 'Release locator identity is disputed'; end if;
 snapshot:=jsonb_build_object('url',uri,'spotifyReleaseId',p_album,'submittedBy',p_actor,'metadataVerified',false,'rightsVerified',false);
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'customer')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'release_locator') on conflict do nothing;
 select * into strict document from public.context_documents where owner_id=p_owner and subject_id=subject and topic='release_locator' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,r.id,'release_locator:'||subject,1,'succeeded','user_submission','spotify-album-url-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into v_attempt;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,v_attempt,subject,'release_locator',snapshot_hash,'accepted','customer_assertion',snapshot,snapshot,
  '{"extent":"partial","scope":"submitted_locator","metadataVerified":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision) then raise exception 'Release locator acceptance conflict'; end if;
 update public.context_requests set status='partial',output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',jsonb_build_array('Spotify release metadata not verified')),updated_at=now()
 where id=r.id returning * into r;
 return to_jsonb(r)-'claim_token';
end $$;
revoke all on function public.create_context_release_request(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.create_context_release_request(uuid,uuid,text,text) to service_role;

create function public.list_context_release_request_target(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject public.context_subjects;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') or req.input->>'kind'<>'release'
 or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
 or jsonb_array_length(req.output->'subjectIds')<>1 then raise exception 'Release request is not ready'; end if;
 select s.* into strict subject from public.context_subjects s
 join public.context_resources r on r.id=s.resource_id and r.id=req.resource_id
  and r.provider='spotify' and r.resource_kind='release' and r.provider_id=req.input->>'releaseId'
 join public.context_resource_links l on l.resource_id=r.id and l.subject_id=s.id and l.relation='identity' and l.status='accepted'
 where s.kind='release' and req.output->'subjectIds' ? s.id::text;
 return jsonb_build_object('subjectId',subject.id,'kind','release','identityConfirmed',false,
  'availableFields',jsonb_build_array('spotify_id'),'reusableModules','[]'::jsonb);
end $$;
revoke all on function public.list_context_release_request_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_release_request_target(uuid,uuid) to service_role;
commit;
