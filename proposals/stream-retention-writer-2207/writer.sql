-- Offline proposal only. Existing private schema remains denied to all application roles.
-- Receipt lives in the existing result.validation JSON, keyed through attempt.module.
create function stream_binding_proposal.reconcile_retention(p_actor uuid,p_owner uuid,p_request uuid,p_key text)
returns jsonb language plpgsql set search_path='' set timezone='UTC' as $$
declare r public.context_results; receipt jsonb; checked jsonb;
begin
 if p_key is null or p_key !~ '^[A-Za-z0-9_-]{1,100}$' then return 'null'::jsonb; end if;
 select x.* into r from public.context_results x join public.context_attempts a
 on a.id=x.attempt_id and a.owner_id=x.owner_id
 where a.owner_id=p_owner and a.request_id=p_request and a.module='retained-binding:'||p_key
 and a.attempt=1 and a.recipe_version='retained-luminate-daily-v1';
 if not found then return 'null'::jsonb; end if;
 receipt:=r.validation->'retentionReceipt';
 checked:=stream_binding_proposal.read_binding(p_actor,p_owner,p_request,r.subject_id,
 (receipt->>'catalogId')::uuid,r.id,(receipt->>'sourceVersionId')::uuid,(receipt->>'revision')::bigint);
 if checked is null or checked='null'::jsonb then return 'null'::jsonb; end if;
 return receipt;
exception when no_data_found or too_many_rows or insufficient_privilege or data_exception then
 return 'null'::jsonb;
end $$;

create function stream_binding_proposal.retain(p_actor uuid,p_owner uuid,p_request uuid,p_subject uuid,p_catalog uuid,
 p_key text,p_revision bigint,p_evidence jsonb)
returns jsonb language plpgsql set search_path='' set timezone='UTC' as $$
declare
 isrc_value text; uri text; command_digest text; content_fingerprint text;
 source_key uuid; version_key uuid; attempt_key uuid; result_key uuid;
 doc public.context_documents; existing public.context_results; v public.context_source_versions;
 receipt jsonb; checked jsonb; result_count integer;
begin
 if p_key is null or p_key !~ '^[A-Za-z0-9_-]{1,100}$' or p_revision is null or p_revision<0
 or p_evidence is null or jsonb_typeof(p_evidence)<>'object'
 or octet_length(convert_to(p_evidence::text,'UTF8'))>524288 or pg_column_size(p_evidence)>524288
 then raise insufficient_privilege; end if;
 isrc_value:=stream_binding_proposal.lock_scope(p_actor,p_owner,p_request,p_subject,p_catalog);
 if isrc_value is null then raise insufficient_privilege; end if;
 if not stream_binding_proposal.within_budget(p_owner,p_catalog,p_subject,isrc_value,(p_evidence->>'since')::date,(p_evidence->>'until')::date) then raise insufficient_privilege; end if;
 command_digest:=encode(sha256(convert_to(jsonb_build_array(p_owner,p_request,p_subject,p_catalog,p_key,p_revision,p_evidence)::text,'UTF8')),'hex');
 -- Tracking serialization also fences same-request/key retries for this catalog.
 select r.* into existing from public.context_results r join public.context_attempts a
 on a.id=r.attempt_id and a.owner_id=r.owner_id
 where a.owner_id=p_owner and a.request_id=p_request and a.module='retained-binding:'||p_key and a.attempt=1;
 if found then
  if existing.reuse_key<>command_digest then raise exception 'Retention command conflict'; end if;
  return stream_binding_proposal.reconcile_retention(p_actor,p_owner,p_request,p_key);
 end if;
 uri:='urn:recoup:retained-catalog-streams:'||p_catalog::text||':'||p_subject::text||':all_dsps:worldwide';
 select count(*) into result_count from public.context_sources where owner_id=p_owner and kind='provider_metadata' and source_url=uri;
 if result_count>1 then raise insufficient_privilege; end if;
 if result_count=1 then
  select id into source_key from public.context_sources where owner_id=p_owner and kind='provider_metadata'
  and source_url=uri and withdrawn_at is null for update;
  if source_key is null then raise insufficient_privilege; end if;
 else
  insert into public.context_sources(owner_id,kind,source_url) values(p_owner,'provider_metadata',uri) returning id into source_key;
 end if;
 content_fingerprint:=encode(sha256(convert_to(p_evidence::text,'UTF8')),'hex');
 select * into v from public.context_source_versions where source_id=source_key and fingerprint=content_fingerprint for share;
 if found then
  if v.removed_at is not null or v.content is distinct from p_evidence then raise insufficient_privilege; end if;
  version_key:=v.id;
 else
  insert into public.context_source_versions(owner_id,source_id,fingerprint,content,retrieved_at)
  values(p_owner,source_key,content_fingerprint,p_evidence,(p_evidence->'retrievalRange'->>'latest')::timestamptz) returning id into version_key;
 end if;
 -- Source lock precedes document. The document uniqueness fences cross-catalog first creation.
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,p_subject,'catalog_retained_streams')
 on conflict(owner_id,subject_id,topic) do nothing;
 select * into strict doc from public.context_documents where owner_id=p_owner and subject_id=p_subject
 and topic='catalog_retained_streams' for update;
 if doc.revision<>p_revision then raise exception 'Retention revision conflict'; end if;
 if exists(select 1 from public.context_results where id=doc.current_result_id and evidence_kind='customer_assertion')
 then raise insufficient_privilege; end if;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,recipe_version,schema_version,started_at,finished_at)
 values(p_owner,p_request,'retained-binding:'||p_key,1,'succeeded','luminate','retained-luminate-daily-v1','1',now(),now()) returning id into attempt_key;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,coverage)
 values(p_owner,attempt_key,p_subject,'catalog_retained_streams',command_digest,'accepted','observation',p_evidence,
 jsonb_build_object('extent',case when p_evidence->'absentDates'='[]'::jsonb and p_evidence->'nullDates'='[]'::jsonb then 'full' else 'partial' end,
 'scope','requested_recording_dates','derivedFieldsAuthorized',false)) returning id into result_key;
 insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result_key,version_key);
 if not public.accept_context_result(p_owner,doc.id,result_key,p_revision) then raise insufficient_privilege; end if;
 checked:=stream_binding_proposal.read_binding(p_actor,p_owner,p_request,p_subject,p_catalog,result_key,version_key,p_revision+1);
 if checked is null or checked='null'::jsonb then raise insufficient_privilege; end if;
 receipt:=jsonb_build_object('ownerId',p_owner,'requestId',p_request,'subjectId',p_subject,'catalogId',p_catalog,
 'key',p_key,'commandDigest',command_digest,'resultId',result_key,'sourceVersionId',version_key,'revision',p_revision+1);
 update public.context_results set validation=jsonb_build_object('retentionReceipt',receipt) where id=result_key;
 return receipt;
exception when no_data_found or too_many_rows or insufficient_privilege or data_exception or not_null_violation then
 -- The function subtransaction rolls every tentative write back on refusal.
 return 'null'::jsonb;
end $$;
revoke all on function stream_binding_proposal.retain(uuid,uuid,uuid,uuid,uuid,text,bigint,jsonb),
 stream_binding_proposal.reconcile_retention(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
