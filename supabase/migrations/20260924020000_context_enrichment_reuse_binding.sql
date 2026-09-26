-- A fingerprint is a cache key, not authority to reuse another subject's evidence.
begin;
create or replace function public.claim_context_enrichment(p_owner uuid,p_request uuid,p_module jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare req public.context_requests; previous public.context_attempts; found_result public.context_results; attempt uuid;
begin
 -- Preserve the request lock from the completion-scope migration (PR76).
 select * into strict req from public.context_requests where owner_id=p_owner and id=p_request for share;
 if jsonb_typeof(req.output->'subjectIds') is distinct from 'array' or (req.output->'subjectIds' ? (p_module->>'subjectId')) is not true or req.status not in ('partial','completed') then raise exception 'Subject outside completed metadata request'; end if;
 if p_module->>'fingerprint' !~ '^[a-f0-9]{64}$' or p_module->>'topic' not in ('catalog_metadata','lyrics','song_summary','artwork_branding','artist_research','musicbrainz_recordings','mlc_recordings','mlc_works','mlc_work_candidates','chartmetric_candidates','songstats_context','spotify_release_context','social_context','catalog_valuation') then raise exception 'Invalid enrichment module'; end if;
 if coalesce(p_module->>'evidenceKind','interpretation') not in ('observation','estimate','interpretation') then raise exception 'Invalid evidence kind'; end if;
 if p_module->>'topic' in ('musicbrainz_recordings','mlc_recordings','mlc_works','mlc_work_candidates','chartmetric_candidates','songstats_context','spotify_release_context','social_context') and coalesce(p_module->>'evidenceKind','')<>'observation' then raise exception 'Provider lookup requires observation evidence'; end if;
 if p_module->>'topic'='catalog_valuation' and coalesce(p_module->>'evidenceKind','')<>'estimate' then raise exception 'Valuation requires estimate evidence'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_owner::text||(p_module->>'fingerprint'),0));
 if exists(select 1 from public.context_results r where r.owner_id=p_owner and r.reuse_key=p_module->>'fingerprint' and (r.subject_id is distinct from (p_module->>'subjectId')::uuid or r.topic is distinct from p_module->>'topic'))
 or exists(select 1 from public.context_attempts a where a.owner_id=p_owner and a.input->>'fingerprint'=p_module->>'fingerprint' and (a.input->>'subjectId' is distinct from p_module->>'subjectId' or a.input->>'topic' is distinct from p_module->>'topic'))
 then raise exception 'Enrichment fingerprint subject or topic conflict'; end if;
 select r.* into found_result from public.context_results r join public.context_documents d on d.current_result_id=r.id
 where r.owner_id=p_owner and r.reuse_key=p_module->>'fingerprint' and r.subject_id=(p_module->>'subjectId')::uuid and r.topic=p_module->>'topic' and d.owner_id=p_owner and d.subject_id=r.subject_id and d.topic=r.topic and r.status='accepted'
 and not exists(select 1 from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id join public.context_sources s on s.id=v.source_id where rs.result_id=r.id and (s.withdrawn_at is not null or v.removed_at is not null)) limit 1;
 if found_result.id is not null then return jsonb_build_object('state','reused','resultId',found_result.id,'content',found_result.normalized_response); end if;
 select * into previous from public.context_attempts where owner_id=p_owner and input->>'fingerprint'=p_module->>'fingerprint' and input->>'subjectId'=p_module->>'subjectId' and input->>'topic'=p_module->>'topic' limit 1;
 -- An interrupted provider call may already have incurred expense. Do not guess or retry it.
 if previous.id is not null then return jsonb_build_object('state','unknown','attemptId',previous.id); end if;
 insert into public.context_attempts(owner_id,request_id,module,attempt,status,provider,model,recipe_version,schema_version,input,started_at)
 values(p_owner,p_request,p_module->>'fingerprint',1,'running',p_module->>'provider',p_module->>'model',p_module->>'key','1',p_module,now()) returning id into attempt;
 return jsonb_build_object('state','claimed','attemptId',attempt);
end $$;
commit;
