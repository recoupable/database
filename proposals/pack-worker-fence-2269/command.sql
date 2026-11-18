-- INACTIVE protocol-2 command; composes the unchanged pinned legacy accounting.
BEGIN;
CREATE FUNCTION public.release_pack_command_v2(p_actor uuid,p_org uuid,p_action text,p_job uuid,p_input jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
<<cmd>>
DECLARE owner uuid; j public.release_pack_jobs; a public.release_pack_assets;
 e public.release_pack_executions; c public.release_pack_claims; op public.release_pack_provider_operations;
 result jsonb; value jsonb; previous jsonb; foundation jsonb; has_foundation boolean:=false; request uuid; fresh boolean:=false;
 phase text; wanted_model text; wanted_credits bigint; continuation uuid[]; supplied jsonb:=p_input;
BEGIN
 owner:=public.authorize_pack_actor(p_actor,p_org);
 IF p_action IS NULL OR p_action NOT IN('prepare','estimate','export','read','approve','resume','run','dispatch_uncertain','claim','context','phase','finish_asset','settle') THEN RAISE EXCEPTION 'Unknown protocol-2 command'; END IF;
 IF jsonb_typeof(p_input) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid Pack input'; END IF;
 IF p_action='prepare' AND NOT(p_input ? 'expected_revision') THEN
   -- Shared with legacy prepare. Protocol ownership is set on INSERT, never promoted.
   PERFORM pg_advisory_xact_lock(hashtextextended(owner::text||':'||(p_input->>'idempotency_key'),0));
   INSERT INTO public.release_pack_jobs(id,owner_id,created_by,idempotency_key,fingerprint,brief,deliverables,status,sufficient_brief_at,protocol)
   VALUES(p_job,owner,p_actor,p_input->>'idempotency_key',p_input->>'fingerprint',p_input->'brief',p_input->'deliverables',p_input->>'status',CASE WHEN p_input->>'status'='ready_to_quote' THEN now() END,2)
   ON CONFLICT(owner_id,idempotency_key) DO NOTHING;
   -- Resolve and lock the actual winner, including after a unique-index wait.
   SELECT * INTO STRICT j FROM public.release_pack_jobs
   WHERE owner_id=owner AND idempotency_key=p_input->>'idempotency_key' FOR UPDATE;
   IF j.protocol<>2 THEN RAISE EXCEPTION 'Legacy Pack cannot be adopted'; END IF;
   IF j.fingerprint IS DISTINCT FROM p_input->>'fingerprint' THEN RAISE EXCEPTION 'Idempotency key conflicts with different inputs'; END IF;
   RETURN public.release_pack_command_legacy_internal(p_actor,p_org,'read',j.id,'{}');
 END IF;
 SELECT * INTO STRICT j FROM public.release_pack_jobs WHERE id=p_job AND owner_id=owner FOR UPDATE;
 IF j.protocol<>2 THEN RAISE EXCEPTION 'Legacy Pack cannot be adopted'; END IF;
 IF p_action IN('approve','resume') THEN
   request:=(p_input->>'request_id')::uuid;
   IF request IS NULL THEN RAISE EXCEPTION 'Transition request identity required'; END IF;
   SELECT * INTO e FROM public.release_pack_executions WHERE job_id=j.id AND transition_id=request;
   IF FOUND THEN
     IF e.transition_action<>p_action OR e.transition_payload<>p_input THEN RAISE EXCEPTION 'Transition payload conflict'; END IF;
     RETURN e.transition_result||jsonb_build_object('dispatch',false);
   END IF;
   IF NOT(p_input ? 'source_execution_id') OR (p_input->>'source_execution_id')::uuid IS DISTINCT FROM j.execution_id
     OR (p_input->>'source_execution_version')::integer IS DISTINCT FROM j.execution_version
     OR (p_input->>'expected_revision')::integer IS DISTINCT FROM j.revision THEN RAISE EXCEPTION 'Stale transition'; END IF;
   IF p_action='resume' THEN
     SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id FOR UPDATE;
     IF (p_input->>'asset_attempt')::integer IS DISTINCT FROM a.attempt OR (p_input->>'source_claim_id')::uuid IS DISTINCT FROM a.claim_id OR a.claim_id IS NULL THEN RAISE EXCEPTION 'Stale resume claim'; END IF;
   END IF;
   result:=public.release_pack_command_legacy_internal(p_actor,p_org,p_action,j.id,p_input);
   IF coalesce((result->>'command_expired')::boolean,false) OR NOT coalesce((result->>'dispatch')::boolean,false) THEN RETURN result; END IF;
   INSERT INTO public.release_pack_executions(job_id,owner_id,revision,version,quote_id,transition_id,transition_action,transition_payload,resume_asset_id)
   VALUES(j.id,owner,j.revision,j.execution_version+1,(j.quote->>'id')::uuid,request,p_action,p_input,CASE WHEN p_action='resume' THEN a.id END) RETURNING * INTO e;
   UPDATE public.release_pack_jobs SET execution_id=e.id,execution_version=e.version WHERE id=j.id;
   result:=public.release_pack_command_legacy_internal(p_actor,p_org,'read',j.id,'{}')||jsonb_build_object('dispatch',true);
   UPDATE public.release_pack_executions SET transition_result=result WHERE id=e.id;
   RETURN result;
 ELSIF p_action IN('prepare','estimate','export') THEN
   IF (p_input->>'expected_revision')::integer IS DISTINCT FROM j.revision THEN RAISE EXCEPTION 'Pack revision changed'; END IF;
   IF p_action='estimate' AND p_input ? 'retry_asset_id' THEN
     SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'retry_asset_id')::uuid AND job_id=j.id FOR UPDATE;
     IF (p_input->>'asset_attempt')::integer IS DISTINCT FROM a.attempt THEN RAISE EXCEPTION 'Retry attempt changed'; END IF;
   END IF;
   RETURN public.release_pack_command_legacy_internal(p_actor,p_org,p_action,j.id,p_input);
 ELSIF p_action='read' THEN
   result:=public.release_pack_command_legacy_internal(p_actor,p_org,'read',j.id,p_input);
   IF j.status='running' AND result->'job'->>'status'<>'running' THEN
     UPDATE public.release_pack_executions SET settlement_payload=jsonb_build_object('expiry',true),settlement_result=result WHERE id=j.execution_id AND settlement_result IS NULL;
   END IF;
   RETURN result;
 END IF;
 -- Every worker fence is checked BEFORE the legacy expiry/recovery branch can mutate.
 IF (p_input->>'expected_revision')::integer IS DISTINCT FROM j.revision
 OR (p_input->>'execution_id')::uuid IS DISTINCT FROM j.execution_id OR j.execution_id IS NULL
 OR (p_input->>'execution_version')::integer IS DISTINCT FROM j.execution_version THEN RAISE EXCEPTION 'Stale Pack execution' USING ERRCODE='P0003'; END IF;
 SELECT * INTO STRICT e FROM public.release_pack_executions WHERE id=j.execution_id AND owner_id=owner;
 IF p_action='run' THEN
   IF nullif(p_input->>'workflow_run_id','') IS NULL OR length(p_input->>'workflow_run_id')>200 THEN RAISE EXCEPTION 'Invalid workflow identity'; END IF;
   IF e.workflow_run_id IS NOT NULL AND e.workflow_run_id<>p_input->>'workflow_run_id' THEN RAISE EXCEPTION 'Workflow identity conflict' USING ERRCODE='P0003'; END IF;
 ELSIF p_action<>'dispatch_uncertain' OR e.workflow_run_id IS NOT NULL THEN
   IF e.workflow_run_id IS NULL OR p_input->>'workflow_run_id' IS DISTINCT FROM e.workflow_run_id THEN RAISE EXCEPTION 'Stale workflow' USING ERRCODE='P0003'; END IF;
 END IF;
 IF p_action IN('phase','finish_asset') THEN
   SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id FOR UPDATE;
   IF (p_input->>'asset_attempt')::integer IS DISTINCT FROM a.attempt OR (p_input->>'claim_id')::uuid IS DISTINCT FROM a.claim_id OR a.claim_id IS NULL THEN RAISE EXCEPTION 'Stale asset claim' USING ERRCODE='P0003'; END IF;
   SELECT * INTO STRICT c FROM public.release_pack_claims WHERE id=a.claim_id AND execution_id=e.id AND owner_id=owner;
   IF p_action='finish_asset' AND c.completion_result IS NOT NULL THEN
     IF c.completion_payload<>p_input THEN RAISE EXCEPTION 'Completion payload conflict'; END IF;
     RETURN c.completion_result;
   END IF;
   IF a.status<>'running' THEN RAISE EXCEPTION 'Asset not running'; END IF;
 END IF;
 IF p_action='settle' AND e.settlement_result IS NOT NULL THEN
   IF e.settlement_payload<>p_input THEN RAISE EXCEPTION 'Settlement payload conflict'; END IF;
   RETURN e.settlement_result;
 END IF;
 -- Action-specific CAS and read-only replay decisions are part of the fence too.
 -- Do not let an expired hold turn stale input or an old claim replay into settlement.
 IF p_action='context' THEN
   IF (p_input->>'context_version')::integer IS DISTINCT FROM j.context_version THEN RAISE EXCEPTION 'Context version changed'; END IF;
 ELSIF p_action='claim' THEN
   request:=(p_input->>'request_id')::uuid;
   IF request IS NULL THEN RAISE EXCEPTION 'Claim request identity required'; END IF;
   SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=(p_input->>'asset_id')::uuid AND job_id=j.id FOR UPDATE;
   SELECT * INTO c FROM public.release_pack_claims WHERE execution_id=e.id AND asset_id=a.id;
   IF FOUND THEN
     IF c.request_id=request THEN
       IF c.request_payload<>p_input THEN RAISE EXCEPTION 'Claim payload conflict'; END IF;
       RETURN jsonb_build_object('job',to_jsonb(j),'asset',to_jsonb(a),'claimed',false,'replayed',true);
     END IF;
     RETURN jsonb_build_object('job',to_jsonb(j),'asset',to_jsonb(a),'claimed',false);
   END IF;
   IF (p_input->>'asset_attempt')::integer IS DISTINCT FROM a.attempt THEN RAISE EXCEPTION 'Stale pending attempt' USING ERRCODE='P0003'; END IF;
   IF e.resume_asset_id=a.id THEN
     IF a.status<>'running' THEN RAISE EXCEPTION 'Resume asset not running'; END IF;
   ELSIF a.status<>'pending' THEN
     RETURN jsonb_build_object('job',to_jsonb(j),'asset',to_jsonb(a),'claimed',false);
   END IF;
 END IF;
 IF j.status<>'running' THEN RAISE EXCEPTION 'Pack not running'; END IF;
 IF j.hold_expires_at<now() THEN
   result:=public.release_pack_command_legacy_internal(p_actor,p_org,'settle',j.id,jsonb_build_object('error','Production window expired; reconcile accepted work'));
   result:=result||jsonb_build_object('command_expired',true);
   UPDATE public.release_pack_executions SET settlement_payload=CASE WHEN p_action='settle' THEN supplied ELSE jsonb_build_object('expiry',true) END,settlement_result=result WHERE id=e.id;
   RETURN result;
 END IF;
 IF p_action='run' THEN
   UPDATE public.release_pack_executions SET workflow_run_id=p_input->>'workflow_run_id' WHERE id=e.id AND workflow_run_id IS NULL;
 ELSIF p_action='dispatch_uncertain' THEN
   IF e.workflow_run_id IS NOT NULL THEN RETURN public.release_pack_command_legacy_internal(p_actor,p_org,'read',j.id,'{}'); END IF;
 ELSIF p_action='claim' THEN
   IF e.resume_asset_id=a.id THEN
     SELECT coalesce(array_agg(id),'{}') INTO continuation FROM public.release_pack_provider_operations WHERE owner_id=owner AND asset_id=a.id AND attempt=a.attempt;
   ELSE
     result:=public.release_pack_command_legacy_internal(p_actor,p_org,'claim',j.id,p_input);
     IF NOT coalesce((result->>'claimed')::boolean,false) THEN RETURN result; END IF;
     SELECT * INTO STRICT a FROM public.release_pack_assets WHERE id=a.id;
     continuation:='{}';
   END IF;
   INSERT INTO public.release_pack_claims(execution_id,owner_id,asset_id,attempt,request_id,request_payload,operation_ids)
   VALUES(e.id,owner,a.id,a.attempt,request,p_input,continuation) RETURNING * INTO c;
   UPDATE public.release_pack_assets SET claim_id=c.id WHERE id=a.id RETURNING * INTO a;
   result:=jsonb_build_object('job',to_jsonb(j),'asset',to_jsonb(a),'claimed',true);
   UPDATE public.release_pack_claims SET claim_result=result WHERE id=c.id;
   RETURN result;
 ELSIF p_action='context' THEN
   UPDATE public.release_pack_jobs SET context_version=context_version+1 WHERE id=j.id;
 ELSIF p_action='phase' THEN
   phase:=p_input->>'phase'; value:=p_input->'value'; previous:=a.provider_state->phase;
   IF phase IS NULL OR length(phase)>100 OR value IS NULL THEN RAISE EXCEPTION 'Invalid phase'; END IF;
   IF phase LIKE '%submission%' THEN
     IF p_input ? 'shared_foundation_binding' THEN
       foundation:=j.production_context->'shared_foundation';
       IF foundation->>'state' IS DISTINCT FROM 'ready'
       OR p_input->'shared_foundation_binding' IS DISTINCT FROM jsonb_build_object('plan_sha256',foundation->'plan'->>'digest','asset_sha256',foundation->>'asset_sha256')
       OR foundation->'plan'->>'job_id' IS DISTINCT FROM j.id::text
       OR foundation->'plan'->>'owner_id' IS DISTINCT FROM owner::text
       OR (foundation->'plan'->>'revision')::integer IS DISTINCT FROM j.revision
       OR foundation->'plan'->>'quote_id' IS DISTINCT FROM j.quote->>'id'
       OR NOT coalesce(foundation->'plan'->'dependent_asset_ids' ? a.id::text,false)
       OR NOT coalesce(foundation->'dependency_bindings' @> jsonb_build_array(jsonb_build_object('asset_id',a.id,'attempt',a.attempt)),false)
       OR NOT EXISTS(SELECT 1 FROM public.release_pack_assets source WHERE source.id=(foundation->'plan'->>'asset_id')::uuid AND source.job_id=j.id AND source.kind='artwork' AND source.status='completed')
       THEN RAISE EXCEPTION 'Retained foundation binding changed'; END IF;
       has_foundation:=true;
     END IF;
     IF phase='motion_submission' AND a.kind='video' THEN
       wanted_model:=j.quote->'execution_config'->'models'->>'motion';
       wanted_credits:=greatest(1,round((j.deliverables->>'video_seconds')::numeric*(j.quote->'execution_config'->'rates'->>'video_units_per_second')::numeric*(j.quote->'execution_config'->'rates'->>'video_usd_per_unit')::numeric*(j.quote->'execution_config'->'rates'->>'credits_per_usd')::numeric));
     ELSIF phase ~ '^image_submission_[0-3]$' AND (a.kind='carousel' OR phase='image_submission_0') THEN
       wanted_model:=CASE WHEN has_foundation OR coalesce(jsonb_array_length(j.quote->'sources'->'references'),jsonb_array_length(j.brief->'reference_image_urls'),0)>0 THEN j.quote->'execution_config'->'models'->>'image_edit' ELSE j.quote->'execution_config'->'models'->>'image' END;
       wanted_credits:=greatest(1,round((j.quote->'execution_config'->'rates'->>'image_usd_per_unit')::numeric*(j.quote->'execution_config'->'rates'->>'credits_per_usd')::numeric));
     ELSE RAISE EXCEPTION 'Provider phase outside quoted plan'; END IF;
     IF value->>'state'='submitting' AND value ? 'request_id' THEN RAISE EXCEPTION 'Submitting intent cannot contain provider receipt'; END IF;
     SELECT o.* INTO op FROM public.release_pack_provider_operations o WHERE o.owner_id=owner AND o.asset_id=a.id AND o.attempt=a.attempt AND o.phase=cmd.phase;
     IF NOT FOUND THEN
       IF value->>'state' IS DISTINCT FROM 'submitting' OR wanted_model IS NULL OR value->>'model' IS DISTINCT FROM wanted_model
       OR coalesce(value->>'input_sha256','') !~ '^[a-f0-9]{64}$' OR (value->>'charge_credits')::bigint IS NULL
       OR wanted_credits IS NULL OR (value->>'charge_credits')::bigint IS DISTINCT FROM wanted_credits
       OR (value->>'charge_credits')::bigint<=0 OR (value->>'charge_credits')::bigint>a.credits-a.billed_credits THEN RAISE EXCEPTION 'Invalid quoted provider intent'; END IF;
       fresh:=true;
       INSERT INTO public.release_pack_provider_operations(owner_id,job_id,asset_id,revision,execution_id,execution_version,workflow_run_id,claim_id,attempt,phase,provider,model,input_sha256,charge_credits)
       VALUES(owner,j.id,a.id,j.revision,e.id,e.version,e.workflow_run_id,c.id,a.attempt,phase,'fal',wanted_model,value->>'input_sha256',(value->>'charge_credits')::bigint) RETURNING * INTO op;
     END IF;
     IF value->>'model' IS DISTINCT FROM op.model OR value->>'input_sha256' IS DISTINCT FROM op.input_sha256 OR (value->>'charge_credits')::bigint IS DISTINCT FROM op.charge_credits THEN RAISE EXCEPTION 'Provider intent identity changed'; END IF;
     IF coalesce(value->>'state','') NOT IN('submitting','accepted','complete') THEN RAISE EXCEPTION 'Invalid provider state'; END IF;
     IF value->>'state' IN('accepted','complete') AND NOT EXISTS(SELECT 1 FROM public.release_pack_provider_observations o WHERE operation_id=op.id AND kind=CASE WHEN value->>'state'='accepted' THEN 'accepted' ELSE 'completed' END AND payload->>'request_id'=value->>'request_id') THEN RAISE EXCEPTION 'Durable observation required before phase'; END IF;
     IF previous->>'request_id' IS NOT NULL AND (value->>'request_id' IS DISTINCT FROM previous->>'request_id' OR value->>'state'='submitting') THEN RAISE EXCEPTION 'Provider receipt conflict'; END IF;
     IF value->>'state'='complete' AND coalesce(previous->>'state','') NOT IN('accepted','complete') THEN RAISE EXCEPTION 'Accepted charge must precede completion'; END IF;
     value:=value||jsonb_build_object('operation_id',op.id);
     IF previous->>'state'='complete' AND previous<>value THEN RAISE EXCEPTION 'Completed receipt is immutable'; END IF;
     p_input:=p_input||jsonb_build_object('value',value);
   ELSIF previous IS NOT NULL AND previous<>value THEN RAISE EXCEPTION 'Saved phase conflict'; END IF;
 ELSIF p_action='finish_asset' THEN
   IF p_input->>'status' IN('failed','completed') AND EXISTS(SELECT 1 FROM jsonb_each(a.provider_state) entry WHERE entry.key LIKE '%submission%' AND entry.value->>'state' IS DISTINCT FROM 'complete') THEN
     RAISE EXCEPTION 'Incomplete provider attempt requires uncertainty';
   END IF;
 ELSIF p_action<>'settle' THEN RAISE EXCEPTION 'Unknown protocol-2 command';
 END IF;
 result:=public.release_pack_command_legacy_internal(p_actor,p_org,p_action,j.id,p_input);
 IF p_action='finish_asset' THEN UPDATE public.release_pack_claims SET completion_payload=supplied,completion_result=result WHERE id=c.id; END IF;
 IF p_action='settle' THEN UPDATE public.release_pack_executions SET settlement_payload=supplied,settlement_result=result WHERE id=e.id; END IF;
 IF op.id IS NOT NULL THEN result:=result||jsonb_build_object('operation_id',op.id,'operation_created',fresh); END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.release_pack_command_v2(uuid,uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.release_pack_command_v2(uuid,uuid,text,uuid,jsonb) TO service_role;
COMMIT;
