-- INACTIVE PROPOSAL. Not a migration; no public RPC or runtime grant.
BEGIN;
CREATE SCHEMA context_retained_video_2131;
REVOKE ALL ON SCHEMA context_retained_video_2131 FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION context_retained_video_2131.load_retained_evidence(
 p_actor uuid,p_owner uuid,p_request uuid,p_snapshot_version uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE
 req public.context_requests; resource public.context_resources; subject public.context_subjects;
 link public.context_resource_links; snapshot public.context_source_versions;
 evidence jsonb; item jsonb; part jsonb; fragment jsonb; ref jsonb;
 ids uuid[]; locked_ids uuid[]:='{}'; locked_row record; seen uuid[]; bound jsonb; field text;
 texts jsonb:='[]'; txt jsonb; text_value text; units bigint; duration numeric; start_at numeric; end_at numeric;
BEGIN
 PERFORM public.authorize_context_case_actor(p_actor,p_owner);
 SELECT * INTO req FROM public.context_requests WHERE id=p_request AND owner_id=p_owner FOR SHARE;
 IF req.id IS NULL OR req.status NOT IN ('partial','completed') OR req.input->>'kind' IS DISTINCT FROM 'video'
  OR jsonb_typeof(req.output->'subjectIds') IS DISTINCT FROM 'array' OR jsonb_array_length(req.output->'subjectIds')<>1
 THEN RAISE EXCEPTION 'Video evidence unavailable' USING ERRCODE='42501'; END IF;
 SELECT * INTO resource FROM public.context_resources WHERE id=req.resource_id FOR SHARE;
 SELECT * INTO subject FROM public.context_subjects WHERE id=(req.output->'subjectIds'->>0)::uuid FOR SHARE;
 SELECT * INTO link FROM public.context_resource_links
 WHERE resource_id=req.resource_id AND subject_id=subject.id AND relation='identity' FOR SHARE;
 IF resource.id IS NULL OR resource.provider<>'youtube' OR resource.resource_kind<>'video'
  OR resource.provider_id !~ '^[A-Za-z0-9_-]{11}$' OR subject.id IS NULL OR subject.kind<>'video'
  OR subject.resource_id IS DISTINCT FROM resource.id OR link.id IS NULL OR link.status<>'accepted'
  OR link.resource_id IS DISTINCT FROM resource.id OR link.subject_id IS DISTINCT FROM subject.id OR link.relation<>'identity'
  OR req.input->>'videoId' IS DISTINCT FROM resource.provider_id
 THEN RAISE EXCEPTION 'Video binding unavailable' USING ERRCODE='42501'; END IF;
 -- Optimistic enumeration only: do not lock snapshot ahead of the sorted set.
 SELECT * INTO snapshot FROM public.context_source_versions WHERE id=p_snapshot_version AND owner_id=p_owner;
 evidence:=snapshot.content;
 IF evidence IS NULL OR jsonb_typeof(evidence)<>'object' OR octet_length(evidence::text)>4194304
  OR evidence-ARRAY['requestId','ownerId','videoSubjectId','videoId','mediaVersion','durationSeconds','variant','title','description','channel','performers','identity','sources','captions','analysis']<>'{}'::jsonb
  OR (SELECT count(*) FROM jsonb_object_keys(evidence))<>15
 THEN RAISE EXCEPTION 'Invalid retained envelope' USING ERRCODE='22023'; END IF;
 FOREACH field IN ARRAY ARRAY['requestId','ownerId','videoSubjectId'] LOOP
  IF jsonb_typeof(evidence->field) IS DISTINCT FROM 'string' OR evidence->>field !~* '^([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$' THEN RAISE EXCEPTION 'Invalid UUID spelling' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF (evidence->>'requestId')::uuid IS DISTINCT FROM p_request OR (evidence->>'ownerId')::uuid IS DISTINCT FROM p_owner
  OR (evidence->>'videoSubjectId')::uuid IS DISTINCT FROM subject.id OR evidence->>'videoId' IS DISTINCT FROM resource.provider_id
  OR jsonb_typeof(evidence->'videoId') IS DISTINCT FROM 'string'
  OR evidence->>'variant' NOT IN ('original','live','remix','dubbed','unknown') OR jsonb_typeof(evidence->'variant')<>'string'
  OR jsonb_typeof(evidence->'sources') IS DISTINCT FROM 'array' OR jsonb_array_length(evidence->'sources') NOT BETWEEN 1 AND 32
 THEN RAISE EXCEPTION 'Invalid retained binding' USING ERRCODE='22023'; END IF;
 IF evidence->'durationSeconds'<>'null'::jsonb THEN
  IF jsonb_typeof(evidence->'durationSeconds')<>'number' THEN RAISE EXCEPTION 'Invalid duration' USING ERRCODE='22023'; END IF;
  duration:=(evidence->>'durationSeconds')::numeric;
  IF duration<=0 OR duration::double precision='Infinity'::double precision THEN RAISE EXCEPTION 'Invalid duration' USING ERRCODE='22023'; END IF;
 END IF;
 IF jsonb_typeof(evidence->'channel') IS DISTINCT FROM 'object' OR (evidence->'channel')-ARRAY['id','name']<>'{}'::jsonb
  OR NOT (evidence->'channel' ?& ARRAY['id','name'])
  OR jsonb_typeof(evidence->'identity') IS DISTINCT FROM 'object' OR (evidence->'identity')-ARRAY['state','reason']<>'{}'::jsonb
  OR evidence->'identity'->>'state' IS DISTINCT FROM 'unresolved' OR NOT(evidence->'identity' ? 'reason')
 THEN RAISE EXCEPTION 'Unsupported identity or channel' USING ERRCODE='22023'; END IF;
 texts:=jsonb_build_array(jsonb_build_array(evidence->'mediaVersion',4000,true),jsonb_build_array(evidence->'title',4000,true),
  jsonb_build_array(evidence->'description',20000,false),jsonb_build_array(evidence->'channel'->'id',4000,true),
  jsonb_build_array(evidence->'channel'->'name',4000,true),jsonb_build_array(evidence->'identity'->'reason',4000,true));
 ids:='{}';
 FOR item IN SELECT value FROM jsonb_array_elements(evidence->'sources') LOOP
  IF jsonb_typeof(item)<>'object' OR item-ARRAY['versionId','videoId','mediaVersion','retrievedAt']<>'{}'::jsonb
   OR NOT(item ?& ARRAY['versionId','videoId','mediaVersion','retrievedAt'])
   OR jsonb_typeof(item->'versionId')<>'string' OR item->>'versionId' !~* '^([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$' OR jsonb_typeof(item->'retrievedAt')<>'string'
   OR item->>'retrievedAt' !~ '^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d+)?)?Z$'
   OR item->>'retrievedAt' ~ '\.[0-9]{6}[0-9]*[1-9][0-9]*Z$'
   OR item->'videoId' IS DISTINCT FROM evidence->'videoId' OR item->'mediaVersion' IS DISTINCT FROM evidence->'mediaVersion'
   OR (item->>'versionId')::uuid=ANY(ids)
  THEN RAISE EXCEPTION 'Invalid retained source list' USING ERRCODE='22023'; END IF;
  ids:=array_append(ids,(item->>'versionId')::uuid);
 END LOOP;
 IF NOT(p_snapshot_version=ANY(ids)) THEN RAISE EXCEPTION 'Snapshot not in lineage' USING ERRCODE='22023'; END IF;
 IF jsonb_typeof(evidence->'performers') IS DISTINCT FROM 'array' OR jsonb_array_length(evidence->'performers')>50
 THEN RAISE EXCEPTION 'Invalid performers' USING ERRCODE='22023'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(evidence->'performers') LOOP
  IF jsonb_typeof(item)<>'object' OR item-ARRAY['name','sourceVersionIds']<>'{}'::jsonb OR NOT(item ?& ARRAY['name','sourceVersionIds'])
  THEN RAISE EXCEPTION 'Invalid performer' USING ERRCODE='22023'; END IF;
  texts:=texts||jsonb_build_array(jsonb_build_array(item->'name',4000,true));
 END LOOP;
 FOREACH field IN ARRAY ARRAY['captions','analysis'] LOOP
  part:=evidence->field;
  IF jsonb_typeof(part) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid evidence section' USING ERRCODE='22023'; END IF;
  IF part->>'state' IN ('missing','unavailable') THEN
   IF part-ARRAY['state','reason']<>'{}'::jsonb OR NOT(part ? 'reason') THEN RAISE EXCEPTION 'Invalid unavailable evidence' USING ERRCODE='22023'; END IF;
   texts:=texts||jsonb_build_array(jsonb_build_array(part->'reason',4000,true));
  ELSIF part->>'state'='available' THEN
   IF part-ARRAY['state','sourceVersionIds',CASE field WHEN 'captions' THEN 'segments' ELSE 'ranges' END]<>'{}'::jsonb
    OR NOT(part ? 'sourceVersionIds') THEN RAISE EXCEPTION 'Invalid available evidence' USING ERRCODE='22023'; END IF;
   fragment:=part->(CASE field WHEN 'captions' THEN 'segments' ELSE 'ranges' END);
   IF jsonb_typeof(fragment) IS DISTINCT FROM 'array' OR jsonb_array_length(fragment) NOT BETWEEN 1 AND (CASE field WHEN 'captions' THEN 500 ELSE 100 END)
   THEN RAISE EXCEPTION 'Invalid evidence ranges' USING ERRCODE='22023'; END IF;
   FOR item IN SELECT value FROM jsonb_array_elements(fragment) LOOP
    IF jsonb_typeof(item)<>'object' OR NOT(item ?& ARRAY['startSeconds','endSeconds'])
     OR jsonb_typeof(item->'startSeconds') IS DISTINCT FROM 'number' OR jsonb_typeof(item->'endSeconds') IS DISTINCT FROM 'number'
    THEN RAISE EXCEPTION 'Invalid evidence range' USING ERRCODE='22023'; END IF;
    start_at:=(item->>'startSeconds')::numeric;end_at:=(item->>'endSeconds')::numeric;
    IF start_at<0 OR end_at<=start_at OR (duration IS NOT NULL AND end_at>duration)
     OR start_at::double precision='Infinity'::double precision OR end_at::double precision='Infinity'::double precision
    THEN RAISE EXCEPTION 'Invalid evidence range' USING ERRCODE='22023'; END IF;
    IF field='captions' THEN
     IF item-ARRAY['startSeconds','endSeconds','language','text']<>'{}'::jsonb OR NOT(item ?& ARRAY['language','text'])
     THEN RAISE EXCEPTION 'Invalid caption' USING ERRCODE='22023'; END IF;
     IF jsonb_typeof(item->'language') IS DISTINCT FROM 'string' OR length(item->>'language')=0 THEN RAISE EXCEPTION 'Invalid language' USING ERRCODE='22023'; END IF;
     texts:=texts||jsonb_build_array(jsonb_build_array(item->'language',100,false),jsonb_build_array(item->'text',4000,true));
    ELSE
     IF item-ARRAY['startSeconds','endSeconds','observations','interpretation']<>'{}'::jsonb OR NOT(item ? 'interpretation')
      OR jsonb_typeof(item->'observations') IS DISTINCT FROM 'array' OR jsonb_array_length(item->'observations') NOT BETWEEN 1 AND 50
     THEN RAISE EXCEPTION 'Invalid analysis' USING ERRCODE='22023'; END IF;
     texts:=texts||jsonb_build_array(jsonb_build_array(item->'interpretation',4000,true));
     FOR ref IN SELECT value FROM jsonb_array_elements(item->'observations') LOOP texts:=texts||jsonb_build_array(jsonb_build_array(ref,4000,true)); END LOOP;
    END IF;
   END LOOP;
  ELSE RAISE EXCEPTION 'Invalid evidence state' USING ERRCODE='22023'; END IF;
 END LOOP;
 -- Every reference set is nonempty, unique under UUID comparison and closed over sources.
 FOR item IN SELECT value FROM jsonb_array_elements(evidence->'performers')
  UNION ALL SELECT evidence->'captions' WHERE evidence->'captions'->>'state'='available'
  UNION ALL SELECT evidence->'analysis' WHERE evidence->'analysis'->>'state'='available'
 LOOP
  IF jsonb_typeof(item->'sourceVersionIds') IS DISTINCT FROM 'array' OR jsonb_array_length(item->'sourceVersionIds') NOT BETWEEN 1 AND 32
  THEN RAISE EXCEPTION 'Invalid evidence references' USING ERRCODE='22023'; END IF;
  seen:='{}';
  FOR ref IN SELECT value FROM jsonb_array_elements(item->'sourceVersionIds') LOOP
   IF jsonb_typeof(ref)<>'string' OR (ref#>>'{}') !~* '^([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$' OR (ref#>>'{}')::uuid=ANY(seen) OR NOT((ref#>>'{}')::uuid=ANY(ids))
   THEN RAISE EXCEPTION 'Unbound evidence reference' USING ERRCODE='22023'; END IF;
   seen:=array_append(seen,(ref#>>'{}')::uuid);
  END LOOP;
 END LOOP;
-- Blankness uses Node Unicode 17.0 \s/Cf/Default_Ignorable_Code_Point union, matching API predicates.
 FOR txt IN SELECT value FROM jsonb_array_elements(texts) LOOP
  IF jsonb_typeof(txt->0) IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'Invalid retained text' USING ERRCODE='22023'; END IF;
  text_value:=txt->>0;
  SELECT length(text_value)+count(*) INTO units FROM regexp_matches(text_value,U&'[\+010000-\+10FFFF]','g');
  IF units>(txt->>1)::integer OR text_value ~ ('['||chr(1)||'-'||chr(8)||chr(11)||chr(12)||chr(14)||'-'||chr(31)||chr(127)||']')
   OR ((txt->>2)::boolean AND regexp_replace(text_value,U&'[\0009-\000D\0020\00A0\00AD\034F\0600-\0605\061C\06DD\070F\0890-\0891\08E2\115F-\1160\1680\17B4-\17B5\180B-\180F\2000-\200F\2028-\202F\205F-\206F\3000\3164\FE00-\FE0F\FEFF\FFA0\FFF0-\FFFB\+0110BD\+0110CD\+013430-\+01343F\+01BCA0-\+01BCA3\+01D173-\+01D17A\+0E0000-\+0E0FFF]','','g')='')
  THEN RAISE EXCEPTION 'Invalid retained text' USING ERRCODE='22023'; END IF;
 END LOOP;
 -- Locks remain held through caller completion. Recheck after any wait.
 FOR locked_row IN SELECT v.id,v.source_id FROM public.context_sources s JOIN public.context_source_versions v ON v.source_id=s.id AND v.owner_id=s.owner_id
 WHERE v.owner_id=p_owner AND v.id=ANY(ids) ORDER BY s.id,v.id FOR SHARE OF s,v LOOP
  locked_ids:=array_append(locked_ids,locked_row.id);
 END LOOP;
 IF cardinality(locked_ids)<>cardinality(ids) OR NOT(locked_ids @> ids) THEN
  RAISE EXCEPTION 'Incomplete retained lock set' USING ERRCODE='42501';
 END IF;
 SELECT * INTO snapshot FROM public.context_source_versions WHERE id=p_snapshot_version AND owner_id=p_owner;
 IF snapshot.content IS DISTINCT FROM evidence OR snapshot.fingerprint IS DISTINCT FROM encode(sha256(convert_to(evidence::text,'UTF8')),'hex')
 THEN RAISE EXCEPTION 'Retained snapshot changed' USING ERRCODE='40001'; END IF;
 bound:=jsonb_build_object('contractVersion','retained-video-evidence-v1','requestId',p_request,'videoSubjectId',subject.id,'videoId',resource.provider_id,'mediaVersion',evidence->>'mediaVersion');
 FOR item IN SELECT value FROM jsonb_array_elements(evidence->'sources') LOOP
  IF NOT EXISTS(SELECT 1 FROM public.context_source_versions v JOIN public.context_sources s ON s.id=v.source_id AND s.owner_id=v.owner_id
    WHERE v.id=(item->>'versionId')::uuid AND v.owner_id=p_owner AND v.removed_at IS NULL AND s.withdrawn_at IS NULL
    AND v.content IS NOT NULL AND v.content<>'null'::jsonb AND v.media_manifest->'contextVideo'=bound
    AND v.retrieved_at=(item->>'retrievedAt')::timestamptz)
  THEN RAISE EXCEPTION 'Retained source unavailable' USING ERRCODE='42501'; END IF;
 END LOOP;
 RETURN evidence;
END $$;

CREATE FUNCTION context_retained_video_2131.save_projection(
 p_actor uuid,p_owner uuid,p_request uuid,p_snapshot_version uuid,p_key text,p_expected_revision bigint
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE e jsonb; identity_key jsonb; operation text; fingerprint text; binding jsonb; a public.context_attempts;
 d public.context_documents; result_id uuid; attempt_id uuid; receipt jsonb; item jsonb; content jsonb;
BEGIN
 e:=context_retained_video_2131.load_retained_evidence(p_actor,p_owner,p_request,p_snapshot_version);
 IF p_key IS NULL OR p_key !~ '^[A-Za-z0-9._:-]{1,128}$' OR p_expected_revision IS NULL OR p_expected_revision<0
 THEN RAISE EXCEPTION 'Invalid projection key/revision' USING ERRCODE='22023'; END IF;
 SELECT jsonb_build_object('linkId',l.id,'resourceId',l.resource_id,'subjectId',l.subject_id,'relation',l.relation) INTO STRICT binding
 FROM public.context_resource_links l JOIN public.context_requests q ON q.resource_id=l.resource_id
 WHERE q.id=p_request AND q.owner_id=p_owner AND l.subject_id=(e->>'videoSubjectId')::uuid AND l.relation='identity' AND l.status='accepted';
 identity_key:=jsonb_build_array('retained-video-projection-v1',p_actor,p_owner,p_request,p_key);
 operation:=encode(sha256(convert_to(identity_key::text,'UTF8')),'hex');
 fingerprint:=encode(sha256(convert_to(jsonb_build_array(p_snapshot_version,e,p_expected_revision)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(operation,0));
 SELECT * INTO a FROM public.context_attempts WHERE owner_id=p_owner AND request_id=p_request AND module=operation AND attempt=1;
 IF a.id IS NOT NULL THEN
  IF a.input->'identity' IS DISTINCT FROM identity_key OR a.input->>'fingerprint' IS DISTINCT FROM fingerprint
   OR a.input->'locatorBinding' IS DISTINCT FROM binding THEN RAISE EXCEPTION 'Projection replay conflict' USING ERRCODE='22023'; END IF;
  IF a.status<>'succeeded' THEN RAISE EXCEPTION 'Projection requires reconciliation' USING ERRCODE='40001'; END IF;
  SELECT * INTO d FROM public.context_documents WHERE owner_id=p_owner AND subject_id=(e->>'videoSubjectId')::uuid AND topic='video_narrative' FOR SHARE;
  IF d.current_result_id IS DISTINCT FROM (a.input->'receipt'->>'resultId')::uuid OR NOT EXISTS(
   SELECT 1 FROM public.context_results r WHERE r.id=d.current_result_id AND r.owner_id=p_owner AND r.attempt_id=a.id AND r.status='accepted')
  THEN RAISE EXCEPTION 'Projection unavailable' USING ERRCODE='42501'; END IF;
  RETURN context_retained_video_2131.read_projection(p_actor,p_owner,p_request);
 END IF;
 INSERT INTO public.context_documents(owner_id,subject_id,topic) VALUES(p_owner,(e->>'videoSubjectId')::uuid,'video_narrative') ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT d FROM public.context_documents WHERE owner_id=p_owner AND subject_id=(e->>'videoSubjectId')::uuid AND topic='video_narrative' FOR UPDATE;
 IF d.revision<>p_expected_revision THEN RAISE EXCEPTION 'Projection revision conflict' USING ERRCODE='40001'; END IF;
 INSERT INTO public.context_attempts(owner_id,request_id,module,attempt,status,provider,model,recipe_version,schema_version,input,started_at,finished_at)
 VALUES(p_owner,p_request,operation,1,'succeeded','retained-evidence','none','video-narrative-fixture-v1','1',jsonb_build_object('identity',identity_key,'fingerprint',fingerprint,'evidence',e,'snapshotVersionId',p_snapshot_version,'locatorBinding',binding),now(),now()) RETURNING id INTO attempt_id;
 content:=e||jsonb_build_object('originalSongLyrics','not_established','scope','video_only','artistBrand','not_established');
 INSERT INTO public.context_results(owner_id,attempt_id,subject_id,topic,reuse_key,status,evidence_kind,normalized_response,raw_response,coverage)
 VALUES(p_owner,attempt_id,d.subject_id,'video_narrative',fingerprint,'accepted','interpretation',content,
  jsonb_build_object('method','retained_video_projection','sourceVersionIds',(SELECT jsonb_agg(value->'versionId') FROM jsonb_array_elements(e->'sources'))),jsonb_build_object('extent','partial','recipe','video-narrative-fixture-v1')) RETURNING id INTO result_id;
 FOR item IN SELECT value FROM jsonb_array_elements(e->'sources') LOOP
  INSERT INTO public.context_result_sources(owner_id,result_id,source_version_id) VALUES(p_owner,result_id,(item->>'versionId')::uuid);
 END LOOP;
 IF NOT public.accept_context_result(p_owner,d.id,result_id,d.revision) THEN RAISE EXCEPTION 'Projection acceptance failed' USING ERRCODE='40001'; END IF;
 receipt:=jsonb_build_object('state','saved','attemptId',attempt_id,'resultId',result_id,'documentId',d.id,'revision',d.revision+1,'evidence',e);
 UPDATE public.context_attempts SET input=input||jsonb_build_object('receipt',receipt) WHERE id=attempt_id AND owner_id=p_owner;
 RETURN receipt;
END $$;

CREATE FUNCTION context_retained_video_2131.read_projection(p_actor uuid,p_owner uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE a public.context_attempts; d public.context_documents; r public.context_results; e jsonb; binding jsonb; actual uuid[]; expected uuid[];
BEGIN
 -- Optimistic lookup selects no payload for return; helper performs authority and sorted locks.
 PERFORM public.authorize_context_case_actor(p_actor,p_owner);
 SELECT a0.* INTO a FROM public.context_requests q JOIN public.context_documents d0 ON d0.owner_id=q.owner_id
  AND d0.subject_id::text=q.output->'subjectIds'->>0 AND d0.topic='video_narrative'
  JOIN public.context_results r0 ON r0.id=d0.current_result_id AND r0.owner_id=d0.owner_id
  JOIN public.context_attempts a0 ON a0.id=r0.attempt_id AND a0.owner_id=r0.owner_id AND a0.request_id=q.id
 WHERE q.id=p_request AND q.owner_id=p_owner;
 IF a.id IS NULL THEN RAISE EXCEPTION 'Projection unavailable' USING ERRCODE='42501'; END IF;
 e:=context_retained_video_2131.load_retained_evidence(p_actor,p_owner,p_request,(a.input->>'snapshotVersionId')::uuid);
 SELECT jsonb_build_object('linkId',l.id,'resourceId',l.resource_id,'subjectId',l.subject_id,'relation',l.relation) INTO STRICT binding
 FROM public.context_resource_links l JOIN public.context_requests q ON q.resource_id=l.resource_id
 WHERE q.id=p_request AND q.owner_id=p_owner AND l.subject_id=(e->>'videoSubjectId')::uuid AND l.relation='identity' AND l.status='accepted';
 SELECT * INTO d FROM public.context_documents WHERE owner_id=p_owner AND subject_id=(e->>'videoSubjectId')::uuid AND topic='video_narrative' FOR SHARE;
 SELECT * INTO r FROM public.context_results WHERE id=d.current_result_id AND owner_id=p_owner;
 SELECT array_agg(source_version_id ORDER BY source_version_id) INTO actual FROM public.context_result_sources WHERE result_id=r.id AND owner_id=p_owner;
 SELECT array_agg((value->>'versionId')::uuid ORDER BY (value->>'versionId')::uuid) INTO expected FROM jsonb_array_elements(e->'sources');
 IF a.status<>'succeeded' OR a.recipe_version<>'video-narrative-fixture-v1' OR a.provider<>'retained-evidence' OR a.model<>'none'
  OR a.input->'evidence' IS DISTINCT FROM e OR a.input->'locatorBinding' IS DISTINCT FROM binding
  OR r.id IS DISTINCT FROM (a.input->'receipt'->>'resultId')::uuid OR r.attempt_id IS DISTINCT FROM a.id OR r.status IS DISTINCT FROM 'accepted'
  OR r.topic IS DISTINCT FROM 'video_narrative' OR r.subject_id IS DISTINCT FROM (e->>'videoSubjectId')::uuid OR actual IS DISTINCT FROM expected
  OR a.input->'receipt'->'evidence' IS DISTINCT FROM e OR d.revision IS DISTINCT FROM (a.input->'receipt'->>'revision')::bigint
  OR r.normalized_response IS DISTINCT FROM e||jsonb_build_object('originalSongLyrics','not_established','scope','video_only','artistBrand','not_established')
 THEN RAISE EXCEPTION 'Projection unavailable' USING ERRCODE='42501'; END IF;
 RETURN a.input->'receipt';
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA context_retained_video_2131 FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
