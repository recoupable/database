-- OFFLINE ONLY. Load after fixture.sql, proposal.sql and configuration-fixture.sql.
-- No live adapter or grants. Existing authorize_management defaults to denial.
CREATE TABLE application_proof_proposal.configuration_receipts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL, application_id uuid NOT NULL, environment text NOT NULL,
 actor uuid NOT NULL, recorded_at timestamptz NOT NULL, result jsonb NOT NULL,
 FOREIGN KEY(workspace_id,application_id,environment) REFERENCES proof_parent_fixture.environments,
 CHECK(result ? 'access_activated' AND result->'access_activated'='false'::jsonb),
 CHECK(result ? 'bootstrap_enabled' AND result->'bootstrap_enabled'='false'::jsonb)
);
CREATE TABLE application_proof_proposal.configuration_requests (
 actor uuid NOT NULL, workspace_id uuid NOT NULL, key text NOT NULL,
 input jsonb NOT NULL, receipt_id uuid NOT NULL REFERENCES application_proof_proposal.configuration_receipts,
 PRIMARY KEY(actor,workspace_id,key)
);
CREATE TRIGGER immutable_configuration_receipt BEFORE UPDATE OR DELETE ON application_proof_proposal.configuration_receipts
 FOR EACH ROW EXECUTE FUNCTION application_proof_proposal.immutable_receipt();
CREATE TRIGGER immutable_configuration_retry BEFORE UPDATE OR DELETE ON application_proof_proposal.configuration_requests
 FOR EACH ROW EXECUTE FUNCTION application_proof_proposal.immutable_receipt();

-- Internal reconstruction helper: no authority or locks of its own, no PUBLIC access.
CREATE FUNCTION application_proof_proposal.configuration_snapshot(p_workspace uuid,p_application uuid,p_environment text)
 RETURNS jsonb LANGUAGE sql VOLATILE SET search_path='' AS $$
 SELECT jsonb_build_object('workspace_id',a.workspace_id,'application_id',a.id,'name',a.name,
  'environment',e.environment,
  'allowed_origins',coalesce((SELECT jsonb_agg(o.origin ORDER BY o.origin COLLATE "C")
   FROM proof_parent_fixture.origins o WHERE o.workspace_id=a.workspace_id AND o.application_id=a.id
   AND o.environment=e.environment),'[]'::jsonb),
  'return_urls',coalesce((SELECT jsonb_agg(u.url ORDER BY u.url COLLATE "C")
   FROM proof_parent_fixture.origins o CROSS JOIN LATERAL unnest(o.return_urls) u(url)
   WHERE o.workspace_id=a.workspace_id AND o.application_id=a.id AND o.environment=e.environment),'[]'::jsonb),
  'origins',coalesce((SELECT jsonb_agg(jsonb_build_object('origin',o.origin,'config_revision',o.config_revision,
   'proof_revision',o.proof_revision,'cas_revision',o.cas_revision,'revoked',o.revoked) ORDER BY o.origin COLLATE "C")
   FROM proof_parent_fixture.origins o WHERE o.workspace_id=a.workspace_id AND o.application_id=a.id
   AND o.environment=e.environment),'[]'::jsonb))
 FROM proof_parent_fixture.applications a JOIN proof_parent_fixture.environments e
 ON e.workspace_id=a.workspace_id AND e.application_id=a.id
 WHERE a.workspace_id=p_workspace AND a.id=p_application AND e.environment=p_environment;
$$;

CREATE FUNCTION application_proof_proposal.configure_return_urls(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_key text,
 p_expected jsonb,p_changes jsonb
) RETURNS jsonb LANGUAGE plpgsql SET search_path='' SET timezone='UTC' AS $$
DECLARE
 operation_name constant text := 'replace_existing_origin_return_urls';
 app_suspended boolean; env_suspended boolean; current_snapshot jsonb; request_input jsonb;
 prior application_proof_proposal.configuration_requests%ROWTYPE;
 parent proof_parent_fixture.origins%ROWTYPE;
 change jsonb; derived_changes jsonb := '[]'::jsonb; expected_revision jsonb; next_revision jsonb;
 new_urls text[]; old_urls text[]; total_urls integer; receipt_id uuid; result_value jsonb;
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'read committed required'; END IF;
 IF p_actor IS NULL OR p_workspace IS NULL OR p_application IS NULL OR p_environment IS NULL
 OR p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128
 OR p_expected IS NULL OR jsonb_typeof(p_expected)<>'object' OR octet_length(p_expected::text)>262144
 OR p_changes IS NULL OR jsonb_typeof(p_changes)<>'array' OR octet_length(p_changes::text)>131072
 THEN RAISE EXCEPTION 'invalid input'; END IF;
 IF jsonb_array_length(p_changes) NOT BETWEEN 1 AND 32 THEN RAISE EXCEPTION 'invalid changes'; END IF;
 PERFORM application_proof_proposal.authorize_management(p_actor,p_workspace,p_application,p_environment,operation_name);
 PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(p_actor,p_workspace,operation_name,p_key)::text,0));
 SELECT a.suspended INTO app_suspended FROM proof_parent_fixture.applications a
 WHERE a.workspace_id=p_workspace AND a.id=p_application FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'resource unavailable' USING ERRCODE='42501'; END IF;
 -- Stronger than proof transact's FOR SHARE; also conflicts with insertion's FK KEY SHARE.
 SELECT e.suspended INTO env_suspended FROM proof_parent_fixture.environments e
 WHERE e.workspace_id=p_workspace AND e.application_id=p_application AND e.environment=p_environment FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'resource unavailable' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM proof_parent_fixture.origins o WHERE o.workspace_id=p_workspace
 AND o.application_id=p_application AND o.environment=p_environment ORDER BY o.origin COLLATE "C" FOR UPDATE;
 request_input:=jsonb_build_object('application_id',p_application,'environment',p_environment,
  'expected',p_expected,'changes',p_changes);
 SELECT q.* INTO prior FROM application_proof_proposal.configuration_requests q
 WHERE q.actor=p_actor AND q.workspace_id=p_workspace AND q.key=p_key;
 IF FOUND THEN
  IF prior.input IS DISTINCT FROM request_input THEN RAISE EXCEPTION 'idempotency conflict'; END IF;
  SELECT r.result INTO result_value FROM application_proof_proposal.configuration_receipts r WHERE r.id=prior.receipt_id;
  RETURN result_value; -- Authorized history, not a current configuration or access grant.
 END IF;
 current_snapshot:=application_proof_proposal.configuration_snapshot(p_workspace,p_application,p_environment);
 IF current_snapshot IS DISTINCT FROM p_expected THEN RAISE EXCEPTION 'snapshot conflict'; END IF;
 IF app_suspended OR env_suspended THEN RAISE EXCEPTION 'resource suspended'; END IF;
 IF EXISTS(SELECT 1 FROM proof_parent_fixture.origins o WHERE o.workspace_id=p_workspace
  AND o.application_id=p_application AND o.environment=p_environment AND o.revoked)
 THEN RAISE EXCEPTION 'origin revoked'; END IF;
 IF jsonb_array_length(current_snapshot->'origins') NOT BETWEEN 1 AND 32
 OR EXISTS(SELECT 1 FROM proof_parent_fixture.origins o WHERE o.workspace_id=p_workspace
  AND o.application_id=p_application AND o.environment=p_environment
  AND greatest(o.config_revision,o.proof_revision,o.cas_revision)>9007199254740990)
 THEN RAISE EXCEPTION 'unsupported parent state'; END IF;
 total_urls:=jsonb_array_length(current_snapshot->'return_urls');
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_changes) c
  WHERE jsonb_typeof(c)<>'object' OR NOT(c ?& ARRAY['origin','expected','next','return_urls'])
   OR c-ARRAY['origin','expected','next','return_urls']<>'{}'::jsonb)
 THEN RAISE EXCEPTION 'invalid changes'; END IF;
 IF (SELECT count(DISTINCT c->>'origin') FROM jsonb_array_elements(p_changes) c)<>jsonb_array_length(p_changes)
 THEN RAISE EXCEPTION 'invalid changes'; END IF;
 FOR change IN SELECT value FROM jsonb_array_elements(p_changes) ORDER BY value->>'origin' COLLATE "C" LOOP
  IF jsonb_typeof(change->'origin')<>'string' OR jsonb_typeof(change->'return_urls')<>'array'
  THEN RAISE EXCEPTION 'invalid changes'; END IF;
  SELECT o.* INTO parent FROM proof_parent_fixture.origins o WHERE o.workspace_id=p_workspace
  AND o.application_id=p_application AND o.environment=p_environment AND o.origin=change->>'origin';
  IF NOT FOUND THEN RAISE EXCEPTION 'origin unavailable'; END IF;
  IF jsonb_array_length(change->'return_urls')>32
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(change->'return_urls') u WHERE jsonb_typeof(u)<>'string')
  THEN RAISE EXCEPTION 'invalid return URLs'; END IF;
  SELECT coalesce(array_agg(DISTINCT url COLLATE "C" ORDER BY url COLLATE "C"),'{}') INTO new_urls
  FROM jsonb_array_elements_text(change->'return_urls') u(url);
  IF to_jsonb(new_urls) IS DISTINCT FROM change->'return_urls'
   OR EXISTS(SELECT 1 FROM unnest(new_urls) u(url) WHERE length(url)>2048
    OR left(url,length(parent.origin)+1)<>parent.origin||'/' OR position('#' IN url)>0 OR url ~ '[[:space:][:cntrl:]]')
  THEN RAISE EXCEPTION 'invalid return URLs'; END IF;
  SELECT coalesce(array_agg(url ORDER BY url COLLATE "C"),'{}') INTO old_urls FROM unnest(parent.return_urls) u(url);
  IF new_urls=old_urls THEN RAISE EXCEPTION 'unchanged origin in changes'; END IF;
  expected_revision:=jsonb_build_object('config_revision',parent.config_revision,'proof_revision',parent.proof_revision,'cas_revision',parent.cas_revision);
  next_revision:=jsonb_build_object('config_revision',parent.config_revision+1,'proof_revision',parent.proof_revision,'cas_revision',parent.cas_revision+1);
  derived_changes:=derived_changes||jsonb_build_array(jsonb_build_object('origin',parent.origin,'expected',expected_revision,
   'next',next_revision,'return_urls',new_urls));
  total_urls:=total_urls-cardinality(old_urls)+cardinality(new_urls);
 END LOOP;
 IF derived_changes IS DISTINCT FROM p_changes THEN RAISE EXCEPTION 'revision projection conflict'; END IF;
 IF total_urls NOT BETWEEN 1 AND 32 THEN RAISE EXCEPTION 'invalid total return URLs'; END IF;
 FOR change IN SELECT value FROM jsonb_array_elements(derived_changes) LOOP
  UPDATE proof_parent_fixture.origins SET return_urls=ARRAY(SELECT jsonb_array_elements_text(change->'return_urls')),
   config_revision=config_revision+1,cas_revision=cas_revision+1
  WHERE workspace_id=p_workspace AND application_id=p_application AND environment=p_environment AND origin=change->>'origin';
  UPDATE application_proof_proposal.challenges SET state='superseded'
  WHERE workspace_id=p_workspace AND application_id=p_application AND environment=p_environment
   AND origin=change->>'origin' AND state='pending';
 END LOOP;
 receipt_id:=gen_random_uuid();
 result_value:=jsonb_build_object('receipt_id',receipt_id,'actor',p_actor,'workspace_id',p_workspace,
  'application_id',p_application,'environment',p_environment,'operation',operation_name,'recorded_at',clock_timestamp(),
  'before',current_snapshot,'changes',derived_changes,
  'after',application_proof_proposal.configuration_snapshot(p_workspace,p_application,p_environment),
  'access_activated',false,'bootstrap_enabled',false,'production_persisted',false,'evidence_kind','synthetic_configuration');
 INSERT INTO application_proof_proposal.configuration_receipts(id,workspace_id,application_id,environment,actor,recorded_at,result)
 VALUES(receipt_id,p_workspace,p_application,p_environment,p_actor,(result_value->>'recorded_at')::timestamptz,result_value);
 INSERT INTO application_proof_proposal.configuration_requests VALUES(p_actor,p_workspace,p_key,request_input,receipt_id);
 RETURN result_value;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA application_proof_proposal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA application_proof_proposal FROM PUBLIC;
