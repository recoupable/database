-- INACTIVE journal ports. Dedicated owner cannot mutate Pack/accounting rows.
BEGIN;
CREATE ROLE pack_receipt_port NOLOGIN;
GRANT USAGE ON SCHEMA public TO pack_receipt_port;
GRANT EXECUTE ON FUNCTION public.authorize_pack_actor(uuid,uuid) TO pack_receipt_port;
GRANT SELECT ON public.release_pack_provider_operations,public.release_pack_claims,public.release_pack_jobs TO pack_receipt_port;
GRANT SELECT,INSERT ON public.release_pack_provider_observations TO pack_receipt_port;
CREATE POLICY receipt_operation_read ON public.release_pack_provider_operations FOR SELECT TO pack_receipt_port USING(true);
CREATE POLICY receipt_claim_read ON public.release_pack_claims FOR SELECT TO pack_receipt_port USING(true);
CREATE POLICY receipt_job_read ON public.release_pack_jobs FOR SELECT TO pack_receipt_port USING(true);
CREATE POLICY receipt_observation_read ON public.release_pack_provider_observations FOR SELECT TO pack_receipt_port USING(true);
CREATE POLICY receipt_observation_insert ON public.release_pack_provider_observations FOR INSERT TO pack_receipt_port WITH CHECK(true);
CREATE FUNCTION public.append_pack_provider_observation(p_actor uuid,p_org uuid,p_operation uuid,
 p_identity jsonb,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE op public.release_pack_provider_operations; effective_owner uuid; k text;
 existing jsonb; accepted jsonb; terminal jsonb; conflict jsonb; previous_conflict jsonb;
BEGIN
 effective_owner:=public.authorize_pack_actor(p_actor,p_org);
 SELECT * INTO STRICT op FROM public.release_pack_provider_operations WHERE id=p_operation AND owner_id=effective_owner;
 IF NOT (((p_identity->>'execution_id')::uuid=op.execution_id AND (p_identity->>'claim_id')::uuid=op.claim_id) OR EXISTS(
   SELECT 1 FROM public.release_pack_claims WHERE owner_id=effective_owner AND op.id=ANY(operation_ids)
   AND execution_id=(p_identity->>'execution_id')::uuid AND id=(p_identity->>'claim_id')::uuid
 )) OR (p_identity->>'execution_id')::uuid IS NULL OR (p_identity->>'claim_id')::uuid IS NULL THEN RAISE EXCEPTION 'Receipt identity denied'; END IF;
 IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>1024
 OR p_payload-ARRAY['kind','request_id','output_sha256','reason_code']<>'{}'::jsonb
 OR jsonb_typeof(p_payload->'kind') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p_payload->'request_id') IS DISTINCT FROM 'string'
 OR coalesce(p_payload->>'request_id','') !~ '^[A-Za-z0-9_-]{1,200}$'
 THEN RAISE EXCEPTION 'Invalid redacted observation'; END IF;
 k:=p_payload->>'kind';
 IF k NOT IN ('accepted','completed','failed')
 OR (p_payload ? 'output_sha256' AND (k<>'completed' OR jsonb_typeof(p_payload->'output_sha256') IS DISTINCT FROM 'string' OR p_payload->>'output_sha256' !~ '^[a-f0-9]{64}$'))
 OR (k='failed' AND coalesce(p_payload->>'reason_code','') NOT IN ('provider_failed','response_invalid','result_unavailable'))
 OR (k<>'failed' AND p_payload ? 'reason_code') THEN RAISE EXCEPTION 'Invalid observation state'; END IF;
 -- Advisory lock avoids granting UPDATE on immutable operation rows.
 PERFORM pg_advisory_xact_lock(hashtextextended(op.id::text,0));
 SELECT payload INTO existing FROM public.release_pack_provider_observations WHERE operation_id=op.id AND kind=k;
 IF existing=p_payload THEN RETURN jsonb_build_object('state','reused','kind',k); END IF;
 SELECT payload INTO accepted FROM public.release_pack_provider_observations WHERE operation_id=op.id AND kind='accepted';
 IF k<>'accepted' AND accepted IS NULL THEN RAISE EXCEPTION 'Acceptance must be durable first'; END IF;
 SELECT payload INTO terminal FROM public.release_pack_provider_observations WHERE operation_id=op.id
 AND kind IN ('completed','failed') AND kind<>k LIMIT 1;
 IF existing IS NOT NULL OR (accepted IS NOT NULL AND accepted->>'request_id'<>p_payload->>'request_id') OR (k<>'accepted' AND terminal IS NOT NULL) THEN
   conflict:=jsonb_build_object('kind',k,'existing_sha256',encode(sha256(convert_to(coalesce(existing,terminal,accepted)::text,'UTF8')),'hex'),
     'incoming_sha256',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
   SELECT payload INTO previous_conflict FROM public.release_pack_provider_observations WHERE operation_id=op.id AND kind='conflict';
   IF previous_conflict IS NULL THEN
     INSERT INTO public.release_pack_provider_observations VALUES(op.id,'conflict',conflict,clock_timestamp());
     RETURN jsonb_build_object('state','conflict','retained',true);
   END IF;
   RETURN jsonb_build_object('state',CASE WHEN previous_conflict=conflict THEN 'conflict' ELSE 'conflict_unretained_capacity' END,'retained',previous_conflict=conflict);
 END IF;
 INSERT INTO public.release_pack_provider_observations VALUES(op.id,k,p_payload,clock_timestamp());
 RETURN jsonb_build_object('state','saved','kind',k);
END $$;

CREATE FUNCTION public.read_pack_provider_observations(p_actor uuid,p_org uuid,p_job uuid,p_after uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE effective_owner uuid; rows jsonb;
BEGIN
 effective_owner:=public.authorize_pack_actor(p_actor,p_org);
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid receipt page'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.release_pack_jobs WHERE id=p_job AND owner_id=effective_owner) THEN RAISE EXCEPTION 'Pack access denied'; END IF;
 IF p_after IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.release_pack_provider_operations WHERE id=p_after AND job_id=p_job AND owner_id=effective_owner) THEN RAISE EXCEPTION 'Receipt cursor denied'; END IF;
 SELECT coalesce(jsonb_agg(value ORDER BY id),'[]') INTO rows FROM (
   SELECT op.id,to_jsonb(op)||jsonb_build_object('observations',(SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY kind),'[]') FROM public.release_pack_provider_observations o WHERE o.operation_id=op.id)) AS value
   FROM public.release_pack_provider_operations op WHERE op.owner_id=effective_owner AND op.job_id=p_job AND (p_after IS NULL OR op.id>p_after) ORDER BY op.id LIMIT p_limit
 ) page;
 RETURN jsonb_build_object('operations',rows,'next_cursor',CASE WHEN jsonb_array_length(rows)=p_limit AND EXISTS(SELECT 1 FROM public.release_pack_provider_operations WHERE job_id=p_job AND owner_id=effective_owner AND id>(rows->-1->>'id')::uuid) THEN rows->-1->>'id' END);
END $$;
GRANT CREATE ON SCHEMA public TO pack_receipt_port;
ALTER FUNCTION public.append_pack_provider_observation(uuid,uuid,uuid,jsonb,jsonb) OWNER TO pack_receipt_port;
ALTER FUNCTION public.read_pack_provider_observations(uuid,uuid,uuid,uuid,integer) OWNER TO pack_receipt_port;
REVOKE CREATE ON SCHEMA public FROM pack_receipt_port;
REVOKE ALL ON FUNCTION public.append_pack_provider_observation(uuid,uuid,uuid,jsonb,jsonb),public.read_pack_provider_observations(uuid,uuid,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.append_pack_provider_observation(uuid,uuid,uuid,jsonb,jsonb),public.read_pack_provider_observations(uuid,uuid,uuid,uuid,integer) TO service_role;
COMMIT;
