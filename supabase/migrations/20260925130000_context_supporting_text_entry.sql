-- Store supplied text privately as evidence; it is not an instruction or an attached music claim.
begin;
alter table public.context_resources drop constraint context_resources_resource_kind_check;
alter table public.context_resources add constraint context_resources_resource_kind_check
 check(resource_kind in ('artist','track','release','video','catalog','songwriter_input','company_input','campaign_input','material_input'));
alter table public.context_subjects drop constraint context_subjects_kind_check;
alter table public.context_subjects add constraint context_subjects_kind_check
 check(kind in ('artist','recording','release','video','catalog','songwriter','company','campaign','material'));
alter table public.context_subjects drop constraint context_subjects_check;
alter table public.context_subjects add constraint context_subjects_check check(
 (kind='artist' and artist_id is not null and song_isrc is null and resource_id is null and catalog_id is null) or
 (kind='recording' and song_isrc is not null and artist_id is null and resource_id is null and catalog_id is null) or
 (kind in ('release','video','songwriter','company','campaign','material') and resource_id is not null and artist_id is null and song_isrc is null and catalog_id is null) or
 (kind='catalog' and catalog_id is not null and artist_id is null and song_isrc is null and resource_id is null)
);

create function public.create_context_supporting_text_request(
 p_owner uuid,p_actor uuid,p_title text,p_text text,p_key text
) returns jsonb language plpgsql set search_path='' as $$
declare normalized_title text; input_hash text; opaque text; uri text; resource uuid; subject uuid;
 req public.context_requests; source uuid; source_version uuid; document public.context_documents;
 attempt_key uuid; result uuid; snapshot jsonb; snapshot_hash text;
begin
 if p_title is null or p_title ~ '[[:cntrl:]]' or p_text is null
 then raise exception 'Invalid supporting text'; end if;
 normalized_title:=pg_catalog.btrim(pg_catalog.regexp_replace(p_title,'[[:space:]]+',' ','g'));
 if length(normalized_title) not between 2 and 200 or length(p_text) not between 1 and 20000
 then raise exception 'Invalid supporting text'; end if;
 input_hash:=encode(sha256(convert_to(jsonb_build_object('title',normalized_title,'text',p_text)::text,'UTF8')),'hex');
 opaque:=encode(sha256(convert_to('material-input-v1:'||p_owner::text||':'||p_key,'UTF8')),'hex');
 uri:='urn:recoup:material-input:'||opaque;
 insert into public.context_resources(provider,resource_kind,provider_id,canonical_url)
 values('recoup','material_input',opaque,uri)
 on conflict(provider,resource_kind,provider_id) do update set provider_id=excluded.provider_id returning id into resource;
 insert into public.context_requests(owner_id,created_by,resource_id,idempotency_key,input_fingerprint,input)
 values(p_owner,p_actor,resource,p_key,input_hash,
  jsonb_build_object('kind','material','materialType','text','title',normalized_title,'contentHash',input_hash,'identityConfirmed',false))
 on conflict(owner_id,idempotency_key) do nothing;
 select * into strict req from public.context_requests where owner_id=p_owner and idempotency_key=p_key for update;
 if req.input_fingerprint<>input_hash or req.resource_id<>resource
 then raise exception 'Idempotency key already used for different input'; end if;
 if req.status in ('completed','partial','cancelled') then return to_jsonb(req)-'claim_token'; end if;
 insert into public.context_subjects(kind,resource_id) values('material',resource)
 on conflict(resource_id) do update set resource_id=excluded.resource_id returning id into subject;
 snapshot:=jsonb_build_object('title',normalized_title,'text',p_text,'contentHash',input_hash,
  'submittedBy',p_actor,'scope','workspace_private','instructionsAreData',true,'subjectLinked',false);
 snapshot_hash:=encode(sha256(convert_to(snapshot::text,'UTF8')),'hex');
 insert into public.context_sources(owner_id,source_url,kind) values(p_owner,uri,'customer')
 on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null
 do update set source_url=excluded.source_url returning id into source;
 insert into public.context_source_versions(owner_id,source_id,fingerprint,content)
 values(p_owner,source,snapshot_hash,snapshot)
 on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into source_version;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,subject,'material_input') on conflict do nothing;
 select * into strict document from public.context_documents
 where owner_id=p_owner and subject_id=subject and topic='material_input' for update;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at,provider_cost_micros,provider_cost_status)
 values(p_owner,req.id,'material_input:'||subject,1,'succeeded','user_submission','supporting-text-v1','1',now(),now(),0,'confirmed')
 on conflict(request_id,module,attempt) do update set finished_at=now() returning id into attempt_key;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,attempt_key,subject,'material_input',snapshot_hash,'accepted','customer_assertion',snapshot,snapshot,
  '{"extent":"partial","scope":"submitted_text","subjectLinked":false}') returning id into result;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,source_version);
 if not public.accept_context_result(p_owner,document.id,result,document.revision)
 then raise exception 'Supporting text acceptance conflict'; end if;
 update public.context_requests set status='partial',
  output=jsonb_build_object('subjectIds',jsonb_build_array(subject),'gaps',jsonb_build_array('Text not inspected or linked to a subject')),
  updated_at=now() where id=req.id returning * into req;
 return to_jsonb(req)-'claim_token';
end $$;
revoke all on function public.create_context_supporting_text_request(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.create_context_supporting_text_request(uuid,uuid,text,text,text) to service_role;

create function public.list_context_material_request_target(p_owner uuid,p_request uuid)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; subject public.context_subjects;
begin
 select * into strict req from public.context_requests where id=p_request and owner_id=p_owner for share;
 if req.status not in ('partial','completed') or req.input->>'kind'<>'material'
  or req.input->>'materialType'<>'text'
  or jsonb_typeof(req.output->'subjectIds') is distinct from 'array'
  or jsonb_array_length(req.output->'subjectIds')<>1
 then raise exception 'Material request is not ready'; end if;
 select s.* into strict subject from public.context_subjects s
 join public.context_resources r on r.id=s.resource_id and r.id=req.resource_id
  and r.provider='recoup' and r.resource_kind='material_input'
 join public.context_documents d on d.owner_id=p_owner and d.subject_id=s.id and d.topic='material_input'
 join public.context_results result on result.id=d.current_result_id and result.owner_id=p_owner
  and result.status='accepted' and result.evidence_kind='customer_assertion'
 where s.kind='material' and req.output->'subjectIds' ? s.id::text
  and result.normalized_response->>'contentHash'=req.input->>'contentHash'
  and exists(select 1 from public.context_result_sources rs
   join public.context_source_versions v on v.id=rs.source_version_id and v.owner_id=p_owner and v.removed_at is null
   join public.context_sources source on source.id=v.source_id and source.owner_id=p_owner and source.withdrawn_at is null
   where rs.result_id=result.id and rs.owner_id=p_owner and source.kind='customer');
 return jsonb_build_object('subjectId',subject.id,'kind','material','identityConfirmed',false,
  'availableFields',jsonb_build_array('submitted_text'),'reusableModules','[]'::jsonb);
end $$;
revoke all on function public.list_context_material_request_target(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_context_material_request_target(uuid,uuid) to service_role;
commit;
