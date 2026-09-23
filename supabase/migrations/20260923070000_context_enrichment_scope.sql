-- Revalidate and lock request scope for both reuse/claim and final evidence save.
-- Shared row locks allow parallel collectors but serialize cancellation or subject removal.
-- No provider calls, automatic retries, or API dispatch are enabled.
begin;
create or replace function public.claim_context_enrichment(p_owner uuid,p_request uuid,p_module jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; previous public.context_attempts; found_result public.context_results; attempt uuid;
begin
 select * into strict req from public.context_requests where owner_id=p_owner and id=p_request for share;
 if jsonb_typeof(req.output->'subjectIds') is distinct from 'array' or (req.output->'subjectIds' ? (p_module->>'subjectId')) is not true or req.status not in ('partial','completed') then raise exception 'Subject outside completed metadata request'; end if;
 if p_module->>'fingerprint' !~ '^[a-f0-9]{64}$' or p_module->>'topic' not in ('catalog_metadata','lyrics','song_summary','artwork_branding','artist_research','musicbrainz_recordings','mlc_recordings','mlc_works','mlc_work_candidates','chartmetric_candidates','songstats_context','spotify_release_context','social_context','catalog_valuation') then raise exception 'Invalid enrichment module'; end if;
 if coalesce(p_module->>'evidenceKind','interpretation') not in ('observation','estimate','interpretation') then raise exception 'Invalid evidence kind'; end if;
 if p_module->>'topic' in ('musicbrainz_recordings','mlc_recordings','mlc_works','mlc_work_candidates','chartmetric_candidates','songstats_context','spotify_release_context','social_context') and coalesce(p_module->>'evidenceKind','')<>'observation' then raise exception 'Provider lookup requires observation evidence'; end if;
 if p_module->>'topic'='catalog_valuation' and coalesce(p_module->>'evidenceKind','')<>'estimate' then raise exception 'Valuation requires estimate evidence'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_owner::text||(p_module->>'fingerprint'),0));
 select r.* into found_result from public.context_results r join public.context_documents d on d.current_result_id=r.id
 where r.owner_id=p_owner and r.reuse_key=p_module->>'fingerprint' and r.status='accepted'
 and not exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id join public.context_sources s on s.id=v.source_id where rs.result_id=r.id and (s.withdrawn_at is not null or v.removed_at is not null)) limit 1;
 if found_result.id is not null then return jsonb_build_object('state','reused','resultId',found_result.id,'content',found_result.normalized_response); end if;
 select * into previous from public.context_attempts where owner_id=p_owner and input->>'fingerprint'=p_module->>'fingerprint' limit 1;
 -- An interrupted provider call may already have incurred expense. Do not guess or retry it.
 if previous.id is not null then return jsonb_build_object('state','unknown','attemptId',previous.id); end if;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,model,recipe_version,schema_version,input,started_at)
 values(p_owner,p_request,p_module->>'fingerprint',1,'running',p_module->>'provider',p_module->>'model',p_module->>'key','1',p_module,now()) returning id into attempt;
 return jsonb_build_object('state','claimed','attemptId',attempt);
end $$;

create or replace function public.complete_context_enrichment(p_owner uuid,p_request uuid,p_attempt uuid,p_result jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; a public.context_attempts; d public.context_documents; result uuid; source uuid; version uuid; item jsonb; hash text; evidence_sources jsonb;
begin
 -- Lock request before attempt; keep status and membership stable through commit.
 select * into strict req from public.context_requests where owner_id=p_owner and id=p_request for share;
 select * into strict a from public.context_attempts where owner_id=p_owner and request_id=p_request and id=p_attempt for update;
 if jsonb_typeof(req.output->'subjectIds') is distinct from 'array' or (req.output->'subjectIds' ? (a.input->>'subjectId')) is not true or req.status not in ('partial','completed') then raise exception 'Subject outside completed metadata request'; end if;
 if a.status='succeeded' then return jsonb_build_object('state','saved','attemptId',a.id); end if;
 if a.status<>'running' then raise exception 'Attempt not running'; end if;
 evidence_sources:=coalesce(p_result->'observedSources',a.input->'sources');
 if jsonb_typeof(evidence_sources) is distinct from 'array' then raise exception 'Invalid evidence sources'; end if;
 if p_result->>'coverage' not in ('full','partial','unknown') or p_result->'content' is null or jsonb_array_length(evidence_sources)=0 then raise exception 'Missing evidence'; end if;
 insert into public.context_documents(owner_id,subject_id,topic) values(p_owner,(a.input->>'subjectId')::uuid,a.input->>'topic') on conflict do nothing;
 select * into strict d from public.context_documents where owner_id=p_owner and subject_id=(a.input->>'subjectId')::uuid and topic=a.input->>'topic' for update;
 insert into public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,raw_response,normalized_response,coverage)
 values(p_owner,p_attempt,d.subject_id,d.topic,a.input->>'fingerprint','accepted',coalesce(a.input->>'evidenceKind','interpretation'),p_result->'trace',p_result->'content',jsonb_build_object('extent',p_result->>'coverage','recipe',a.recipe_version)) returning id into result;
 for item in select value from jsonb_array_elements(evidence_sources) loop
  if item->'content' is null or item->'content'='null'::jsonb or not exists(select 1 from jsonb_array_elements(a.input->'sources') declared where declared->>'url'=item->>'url' and declared->>'kind'=item->>'kind') then raise exception 'Undeclared or empty source evidence'; end if;
  insert into public.context_sources(owner_id,source_url,kind) values(p_owner,item->>'url',item->>'kind')
  on conflict(owner_id,kind,source_url) where withdrawn_at is null and source_url is not null do update set source_url=excluded.source_url returning id into source;
  hash:=encode(sha256(convert_to((item->'content')::text,'UTF8')),'hex');
  insert into public.context_source_versions(owner_id,source_id,fingerprint,content) values(p_owner,source,hash,item->'content')
  on conflict(source_id,fingerprint) do update set fingerprint=excluded.fingerprint returning id into version;
  insert into public.context_result_sources(owner_id,result_id,source_version_id) values(p_owner,result,version) on conflict do nothing;
 end loop;
 -- A slower analysis cannot replace an attempt started after it.
 if exists(select 1 from public.context_results r join public.context_attempts newer on newer.id=r.attempt_id where r.id=d.current_result_id and newer.started_at>a.started_at)
 then update public.context_results set status='stale' where id=result;
 else if not public.accept_context_result(p_owner,d.id,result,d.revision) then raise exception 'Source no longer acceptable'; end if; end if;
 update public.context_attempts set status='succeeded',finished_at=now(),provider_cost_micros=case when jsonb_typeof(p_result->'costUsd')='number' then round((p_result->>'costUsd')::numeric*1000000)::bigint else null end,provider_cost_status=p_result->>'costStatus' where id=p_attempt;
 return jsonb_build_object('state','saved','resultId',result,'content',p_result->'content');
end $$;

commit;
