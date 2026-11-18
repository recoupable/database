-- SOURCE CANDIDATE ONLY. All functions are invokers, ungranted, not public RPCs/authenticators.
-- p_actor is the original existing-account identity from trusted server verification, never body input.
CREATE FUNCTION application_registration_proposal.authorize_principal(p_actor uuid,p_workspace uuid)
 RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE active boolean;
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'read committed required'; END IF;
 IF p_actor IS NULL OR p_workspace IS DISTINCT FROM p_actor THEN
  RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.accounts WHERE id=p_actor FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
 SELECT p.enabled INTO active FROM application_registration_proposal.personal_principals p
 WHERE p.account_id=p_actor AND p.policy_version='proposed-personal-v1' FOR SHARE;
 IF active IS DISTINCT FROM true THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
END $$;
CREATE FUNCTION application_registration_proposal.authorize_create(p_actor uuid,p_workspace uuid,p_environment text)
 RETURNS application_registration_proposal.create_entitlements LANGUAGE plpgsql SET search_path='' AS $$
DECLARE authority application_registration_proposal.create_entitlements%ROWTYPE;
BEGIN
 PERFORM application_registration_proposal.authorize_principal(p_actor,p_workspace);
 SELECT e.* INTO authority FROM application_registration_proposal.create_entitlements e
 WHERE e.actor=p_actor AND e.workspace_id=p_workspace AND e.environment=p_environment FOR SHARE;
 IF authority.enabled IS DISTINCT FROM true OR authority.policy_version IS DISTINCT FROM 'proposed-personal-v1'
 OR authority.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
 RETURN authority;
END $$;
CREATE FUNCTION application_registration_proposal.authorize_management(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_operation text
) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE authority application_registration_proposal.management_entitlements%ROWTYPE;
BEGIN
 PERFORM application_registration_proposal.authorize_principal(p_actor,p_workspace);
 SELECT e.* INTO authority FROM application_registration_proposal.management_entitlements e
 WHERE e.actor=p_actor AND e.workspace_id=p_workspace AND e.application_id=p_application
 AND e.environment=p_environment AND e.operation=p_operation FOR SHARE;
 IF authority.enabled IS DISTINCT FROM true OR authority.policy_version IS DISTINCT FROM 'proposed-personal-v1' THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION application_registration_proposal.register_application(
 p_actor uuid,p_workspace uuid,p_environment text,p_key text,p_entitlement_revision bigint,p_registration jsonb
) RETURNS jsonb LANGUAGE plpgsql SET search_path='' SET timezone='UTC' AS $$
DECLARE authority application_registration_proposal.create_entitlements%ROWTYPE;
 prior application_registration_proposal.requests%ROWTYPE;
 fingerprint jsonb; result_value jsonb; application_id uuid; receipt_id uuid; at_time timestamptz;
 item jsonb; urls text[]; total_urls integer:=0; snapshot jsonb; origin_list text[]; return_list text[];
BEGIN
 IF p_environment IS NULL OR p_environment NOT IN ('production','development')
 OR p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128
 OR p_entitlement_revision IS NULL OR p_entitlement_revision NOT BETWEEN 1 AND 9007199254740991
 OR p_registration IS NULL OR jsonb_typeof(p_registration)<>'object' OR octet_length(p_registration::text)>262144
 THEN RAISE EXCEPTION 'invalid input'; END IF;
 authority:=application_registration_proposal.authorize_create(p_actor,p_workspace,p_environment);
 PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(p_actor,p_workspace,'create_application'::text,p_key)::text,0));
 -- Authorization rows remain locked; time can still change while waiting for a retry-key lock.
 IF authority.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
 fingerprint:=jsonb_build_object('environment',p_environment,'entitlement_revision',p_entitlement_revision,'registration',p_registration);
 SELECT q.* INTO prior FROM application_registration_proposal.requests q
 WHERE q.actor=p_actor AND q.workspace_id=p_workspace AND q.key=p_key;
 IF FOUND THEN
  IF prior.input IS DISTINCT FROM fingerprint THEN RAISE EXCEPTION 'idempotency conflict'; END IF;
  SELECT r.result INTO result_value FROM application_registration_proposal.receipts r WHERE r.id=prior.receipt_id;
  RETURN result_value;
 END IF;
 IF authority.revision<>p_entitlement_revision THEN RAISE EXCEPTION 'entitlement revision conflict'; END IF;
 IF NOT(p_registration ?& ARRAY['name','origins']) OR p_registration-ARRAY['name','origins']<>'{}'::jsonb
 OR jsonb_typeof(p_registration->'name')<>'string' OR length(p_registration->>'name') NOT BETWEEN 1 AND 120
 OR btrim(p_registration->>'name')<>p_registration->>'name'
 OR jsonb_typeof(p_registration->'origins')<>'array' THEN RAISE EXCEPTION 'invalid registration'; END IF;
 IF jsonb_array_length(p_registration->'origins') NOT BETWEEN 1 AND 32 THEN RAISE EXCEPTION 'invalid origins'; END IF;
 -- Trusted adapter uses WHATWG canonical validation first. These are additional structural checks, not DNS proof.
 FOR item IN SELECT value FROM jsonb_array_elements(p_registration->'origins') LOOP
  IF jsonb_typeof(item)<>'object' OR NOT(item ?& ARRAY['origin','hostname','return_urls'])
  OR item-ARRAY['origin','hostname','return_urls']<>'{}'::jsonb
  OR jsonb_typeof(item->'origin')<>'string' OR jsonb_typeof(item->'hostname')<>'string'
  OR jsonb_typeof(item->'return_urls')<>'array' THEN RAISE EXCEPTION 'invalid origin'; END IF;
  IF length(item->>'origin')>2048 OR length(item->>'hostname') NOT BETWEEN 1 AND 253
  OR (item->>'hostname') !~ '^([a-z0-9.-]+|\[[0-9a-f:]+\])$'
  OR (item->>'origin') !~ '^(https|http)://[^/?#@[:space:]]+$'
  OR regexp_replace(item->>'origin','^https?://','') !~ ('^'||replace(replace(replace(item->>'hostname','.','\.'),'[','\['),']','\]')||'(:[0-9]+)?$')
  OR (left(item->>'origin',7)='http://' AND NOT(p_environment='development' AND item->>'hostname' IN ('localhost','127.0.0.1','[::1]')))
  OR (p_environment='production' AND item->>'hostname' IN ('localhost','127.0.0.1','[::1]'))
  THEN RAISE EXCEPTION 'invalid canonical origin'; END IF;
  IF jsonb_array_length(item->'return_urls')>32 OR EXISTS(SELECT 1 FROM jsonb_array_elements(item->'return_urls') u WHERE jsonb_typeof(u)<>'string')
  THEN RAISE EXCEPTION 'invalid return URLs'; END IF;
  SELECT coalesce(array_agg(DISTINCT u COLLATE "C" ORDER BY u COLLATE "C"),'{}') INTO urls
  FROM jsonb_array_elements_text(item->'return_urls') t(u);
  IF to_jsonb(urls) IS DISTINCT FROM item->'return_urls'
  OR EXISTS(SELECT 1 FROM unnest(urls) u WHERE length(u)>2048 OR left(u,length(item->>'origin')+1)<>(item->>'origin')||'/'
   OR position('#' IN u)>0 OR u ~ '[[:space:][:cntrl:]]') THEN RAISE EXCEPTION 'invalid return URLs'; END IF;
  total_urls:=total_urls+cardinality(urls);
 END LOOP;
 SELECT array_agg(DISTINCT o->>'origin' COLLATE "C" ORDER BY o->>'origin' COLLATE "C") INTO origin_list
 FROM jsonb_array_elements(p_registration->'origins') o;
 IF cardinality(origin_list)<>jsonb_array_length(p_registration->'origins')
 OR to_jsonb(origin_list) IS DISTINCT FROM (SELECT jsonb_agg(o->'origin') FROM jsonb_array_elements(p_registration->'origins') o)
 OR total_urls NOT BETWEEN 1 AND 32 THEN RAISE EXCEPTION 'invalid origins or total return URLs'; END IF;
 SELECT array_agg(u ORDER BY u COLLATE "C") INTO return_list FROM jsonb_array_elements(p_registration->'origins') o,
 LATERAL jsonb_array_elements_text(o->'return_urls') t(u);
 application_id:=gen_random_uuid(); receipt_id:=gen_random_uuid(); at_time:=clock_timestamp();
 IF authority.expires_at<=at_time THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
 INSERT INTO application_registration_proposal.applications(workspace_id,id,billing_owner_id,name)
 VALUES(p_workspace,application_id,p_workspace,p_registration->>'name');
 INSERT INTO application_registration_proposal.environments(workspace_id,application_id,environment)
 VALUES(p_workspace,application_id,p_environment);
 FOR item IN SELECT value FROM jsonb_array_elements(p_registration->'origins') LOOP
  INSERT INTO application_registration_proposal.origins(workspace_id,application_id,environment,origin,hostname,return_urls)
  VALUES(p_workspace,application_id,p_environment,item->>'origin',item->>'hostname',ARRAY(SELECT jsonb_array_elements_text(item->'return_urls')));
 END LOOP;
 snapshot:=jsonb_build_object('workspace_id',p_workspace,'application_id',application_id,'name',p_registration->>'name',
  'environment',p_environment,'allowed_origins',origin_list,'return_urls',return_list,'origins',
  (SELECT jsonb_agg(jsonb_build_object('origin',o,'config_revision',1,'proof_revision',1,'cas_revision',1,'revoked',false) ORDER BY o COLLATE "C") FROM unnest(origin_list) o));
 result_value:=jsonb_build_object('receipt_id',receipt_id,'application_id',application_id,'actor',p_actor,
  'workspace_id',p_workspace,'billing_owner_id',p_workspace,'environment',p_environment,'recorded_at',at_time,
  'entitlement_revision',authority.revision,'policy_version',authority.policy_version,'snapshot',snapshot,
  'origins_verified',false,'bootstrap_enabled',false,'access_activated',false,'runtime_enabled',false,
  'production_persisted',false,'policy_status','proposed_unadopted','evidence_kind','disposable_parent_assertion');
 INSERT INTO application_registration_proposal.receipts VALUES(receipt_id,p_actor,p_workspace,application_id,p_environment,at_time,result_value);
 INSERT INTO application_registration_proposal.requests VALUES(p_actor,p_workspace,p_key,fingerprint,receipt_id);
 RETURN result_value;
END $$;
CREATE FUNCTION application_registration_proposal.read_registration(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_receipt uuid
) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE result_value jsonb;
BEGIN
 PERFORM application_registration_proposal.authorize_management(p_actor,p_workspace,p_application,p_environment,'read_registration');
 SELECT r.result INTO result_value FROM application_registration_proposal.receipts r
 WHERE r.id=p_receipt AND r.workspace_id=p_workspace AND r.application_id=p_application AND r.environment=p_environment;
 IF NOT FOUND THEN RAISE EXCEPTION 'authority unavailable' USING ERRCODE='42501'; END IF;
 RETURN result_value;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA application_registration_proposal FROM PUBLIC;
