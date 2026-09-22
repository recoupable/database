-- Run inside a transaction against the local Context Engine fixture database.
-- The enclosing test runner must ROLLBACK. No provider calls or customer data required.
do $$
declare req public.context_requests; module jsonb; claim jsonb; saved jsonb; kind text; snapshot jsonb; topic text; evidence text;
begin
 select * into strict req from public.context_requests where status in ('partial','completed') and jsonb_array_length(output->'subjectIds')>0 limit 1;
 for topic,evidence in select * from (values ('musicbrainz_recordings','observation'),('mlc_recordings','observation'),('mlc_works','observation'),('mlc_work_candidates','observation'),('chartmetric_candidates','observation'),('social_context','observation'),('catalog_valuation','estimate'),('lyrics','interpretation')) t(topic,evidence) loop
  module:=jsonb_build_object('key','provider-test-v1','topic',topic,'subjectId',req.output->'subjectIds'->>0,'provider','fixture','model','none','evidenceKind',evidence,'fingerprint',encode(sha256(convert_to(gen_random_uuid()::text,'UTF8')),'hex'),'sources',jsonb_build_array(jsonb_build_object('url','https://example.com/fixture','kind','provider_metadata','content',jsonb_build_object('fixture',true))));
  if topic='lyrics' then module:=module-'evidenceKind'; end if;
  claim:=public.claim_context_enrichment(req.owner_id,req.id,module);
  if claim->>'state'<>'claimed' then raise exception 'Expected claim'; end if;
  saved:=public.complete_context_enrichment(req.owner_id,req.id,(claim->>'attemptId')::uuid,jsonb_build_object('content',jsonb_build_object('fixture',true),'coverage','unknown','trace',jsonb_build_object('fixture',true),'costUsd',null,'costStatus','unknown','observedSources',jsonb_build_array(jsonb_build_object('url','https://example.com/fixture','kind','provider_metadata','content',jsonb_build_object('response',topic)))));
  select evidence_kind into kind from public.context_results where id=(saved->>'resultId')::uuid;
  select v.content into strict snapshot from public.context_result_sources rs join public.context_source_versions v on v.id=rs.source_version_id where rs.result_id=(saved->>'resultId')::uuid;
  if snapshot->>'response' is distinct from topic then raise exception 'Response snapshot was not versioned'; end if;
  if kind<>evidence then raise exception 'Wrong evidence kind: % expected %',kind,evidence; end if;
  if public.claim_context_enrichment(req.owner_id,req.id,module)->>'state'<>'reused' then raise exception 'Expected reuse'; end if;
 end loop;
 module:=module||jsonb_build_object('topic','mlc_works','evidenceKind','interpretation','fingerprint',repeat('b',64));
 begin
  perform public.claim_context_enrichment(req.owner_id,req.id,module);
  raise exception 'TEST_FAILURE: mismatched kind accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
 end;
 module:=module||jsonb_build_object('topic','invented_topic','evidenceKind','observation');
 begin
  perform public.claim_context_enrichment(req.owner_id,req.id,module);
  raise exception 'TEST_FAILURE: unknown topic accepted';
 exception when others then
  if SQLERRM like 'TEST_FAILURE:%' then raise; end if;
 end;
end $$;
