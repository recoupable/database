-- Existing workspace-linked artists are a standalone entry. This does not create
-- an artist, assert roster/rights, or confirm an artist from a name alone.
begin;
create function public.create_context_artist_request(p_owner uuid,p_actor uuid,p_artist uuid,p_key text)
returns jsonb language plpgsql set search_path='' as $$
declare artist_name text; resource uuid; subject uuid; r public.context_requests; request_fingerprint text; uri text;
 source uuid; source_version uuid; document public.context_documents; v_attempt uuid; result uuid; snapshot jsonb; snapshot_hash text;
begin
 if not exists(select 1 from public.account_artist_ids a where a.account_id=p_owner and a.artist_id=p_artist)
 and not exists(select 1 from public.artist_organization_ids a where a.organization_id=p_owner and a.artist_id=p_artist)
 then raise exception 'Artist not linked to selected workspace'; end if;
 select name into strict artist_name from public.accounts where id=p_artist;
 request_fingerprint:=encode(sha256(convert_to('artist-v1:'||p_artist::text,'UTF8')),'hex');
 uri:='urn:recoup:artist:'||p_artist::text;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('recoup','artist',p_artist::text,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,request_fingerprint,jsonb_build_object('kind','artist','artistId',p_artist))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict r from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if r.input_fingerprint<>request_fingerprint then raise exception 'Idempotency key already used for different input'; end if;
 if r.status in ('completed','partial','cancelled') then return to_jsonb(r)-'claim_token'; end if;
 insert into public.context_subjects(kind,artist_id) values('artist',p_artist)
 on conflict(artist_id) do update set artist_id=excluded.artist_id returning id into subject;
 insert into public.context_resource_links(resource_id,subject_id,relation,status,evidence)
 values(resource,subject,'identity','accepted',jsonb_build_object('source','recoup_artist_account'))
 on conflict(resource_id,subject_id,relation) do nothing;
 snapshot:=jsonb_build_object('artistId',p_artist,'name',artist_name,'scope','workspace_private','rightsVerified',false);
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'provider_metadata')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'artist_identity') on conflict do nothing;
 select * into strict document from public.context_documents where owner_id=p_owner and subject_id=subject and topic='artist_identity' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,r.id,'artist_identity:'||subject,1,'succeeded','recoup','recoup-artist-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into v_attempt;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,v_attempt,subject,'artist_identity',snapshot_hash,'accepted','observation',snapshot,snapshot,
  '{"extent":"partial","scope":"workspace_private","audioAnalyzed":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision) then raise exception 'Artist context acceptance conflict'; end if;
 update public.context_requests set status='partial',output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',jsonb_build_array('Artist enrichment not run')),updated_at=now()
 where id=r.id returning * into r;
 return to_jsonb(r)-'claim_token';
end $$;
revoke all on function public.create_context_artist_request(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.create_context_artist_request(uuid,uuid,uuid,text) to service_role;

-- Current workspace membership and exact request/resource identity are checked
-- every time the planner reads an artist target.
create function public.list_context_artist_request_target(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject public.context_subjects; spotify_id boolean;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') or req.input->>'kind'<>'artist'
 or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
 or jsonb_array_length(req.output->'subjectIds')<>1 then raise exception 'Artist request is not ready'; end if;
 select s.* into strict subject from public.context_subjects s
 join public.context_resources r on r.id=req.resource_id and r.provider='recoup' and r.resource_kind='artist' and r.provider_id=s.artist_id::text
 join public.context_resource_links l on l.resource_id=r.id and l.subject_id=s.id and l.relation='identity' and l.status='accepted'
 where s.kind='artist' and s.artist_id::text=req.input->>'artistId' and req.output->'subjectIds' ? s.id::text
 and (exists(select 1 from public.account_artist_ids a where a.account_id=p_owner and a.artist_id=s.artist_id)
  or exists(select 1 from public.artist_organization_ids a where a.organization_id=p_owner and a.artist_id=s.artist_id));
 select exists(select 1 from public.context_resource_links l join public.context_resources r on r.id=l.resource_id
  where l.subject_id=subject.id and l.relation='identity' and l.status='accepted'
   and r.provider='spotify' and r.resource_kind='artist') into spotify_id;
 return jsonb_build_object('subjectId',subject.id,'kind','artist','identityConfirmed',true,
  'availableFields',case when spotify_id then jsonb_build_array('artist_account_link','spotify_id') else jsonb_build_array('artist_account_link') end,
  'reusableModules','[]'::jsonb);
end $$;
revoke all on function public.list_context_artist_request_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_artist_request_target(uuid,uuid) to service_role;
commit;
