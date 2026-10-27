-- EXECUTABLE PROPOSAL ONLY. Depends on fixture.sql; never load as a migration.
CREATE SCHEMA application_proof_proposal;
REVOKE ALL ON SCHEMA application_proof_proposal FROM PUBLIC;
CREATE TABLE application_proof_proposal.challenges (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL, application_id uuid NOT NULL, environment text NOT NULL, origin text NOT NULL,
 config_revision bigint NOT NULL, proof_revision bigint NOT NULL,
 digest text NOT NULL UNIQUE CHECK(digest ~ '^[0-9a-f]{64}$'),
 issued_at timestamptz NOT NULL, expires_at timestamptz NOT NULL CHECK(expires_at>issued_at),
 state text NOT NULL CHECK(state IN ('pending','consumed','superseded','revoked')),
 FOREIGN KEY(workspace_id,application_id,environment,origin) REFERENCES proof_parent_fixture.origins
);
CREATE UNIQUE INDEX one_pending_challenge ON application_proof_proposal.challenges
 (workspace_id,application_id,environment,origin) WHERE state='pending';
CREATE TABLE application_proof_proposal.receipts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 workspace_id uuid NOT NULL, application_id uuid NOT NULL, environment text NOT NULL, origin text NOT NULL,
 actor uuid NOT NULL, operation text NOT NULL CHECK(operation IN ('issue','verify','revoke')),
 challenge_id uuid REFERENCES application_proof_proposal.challenges,
 recorded_at timestamptz NOT NULL, result jsonb NOT NULL,
 CHECK(result->'access_activated' = 'false'::jsonb AND result ? 'access_activated'),
 CHECK(result->'bootstrap_enabled' = 'false'::jsonb AND result ? 'bootstrap_enabled'),
 FOREIGN KEY(workspace_id,application_id,environment,origin) REFERENCES proof_parent_fixture.origins
);
CREATE TABLE application_proof_proposal.requests (
 actor uuid NOT NULL, workspace_id uuid NOT NULL, operation text NOT NULL, key text NOT NULL,
 input jsonb NOT NULL, receipt_id uuid NOT NULL REFERENCES application_proof_proposal.receipts,
 PRIMARY KEY(actor,workspace_id,operation,key)
);
CREATE FUNCTION application_proof_proposal.immutable_receipt() RETURNS trigger
 LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'immutable receipt'; END $$;
CREATE TRIGGER immutable_receipt BEFORE UPDATE OR DELETE ON application_proof_proposal.receipts
 FOR EACH ROW EXECUTE FUNCTION application_proof_proposal.immutable_receipt();
CREATE TRIGGER immutable_retry BEFORE UPDATE OR DELETE ON application_proof_proposal.requests
 FOR EACH ROW EXECUTE FUNCTION application_proof_proposal.immutable_receipt();

-- DEFAULT AUTHORITY: no membership fallback, feature flag or caller-provided boolean.
CREATE OR REPLACE FUNCTION application_proof_proposal.authorize_management(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_operation text
) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'management authority unavailable' USING ERRCODE='42501'; END $$;
REVOKE ALL ON FUNCTION application_proof_proposal.authorize_management(uuid,uuid,uuid,text,text) FROM PUBLIC;

-- TRANSACTION: the authority adapter must lock/recheck its actual policy dependencies.
CREATE FUNCTION application_proof_proposal.transact(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_origin text,
 p_operation text,p_key text,p_config bigint,p_proof bigint,p_cas bigint,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SET search_path='' SET timezone='UTC' AS $$
DECLARE
 parent proof_parent_fixture.origins%ROWTYPE;
 challenge application_proof_proposal.challenges%ROWTYPE;
 prior application_proof_proposal.requests%ROWTYPE;
 request_input jsonb; output jsonb; receipt_id uuid; challenge_id uuid;
 app_suspended boolean; env_suspended boolean; at_time timestamptz; observed_at timestamptz;
BEGIN
 IF current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'read committed required'; END IF;
 IF p_actor IS NULL OR p_workspace IS NULL OR p_application IS NULL OR p_environment IS NULL
 OR p_origin IS NULL OR p_operation IS NULL OR p_operation NOT IN ('issue','verify','revoke','read')
 OR p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 128
 OR p_config IS NULL OR p_proof IS NULL OR p_cas IS NULL OR least(p_config,p_proof,p_cas)<1
 OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR octet_length(p_payload::text)>4096
 THEN RAISE EXCEPTION 'invalid input'; END IF;
 PERFORM application_proof_proposal.authorize_management(p_actor,p_workspace,p_application,p_environment,p_operation);
 -- Serialize idempotency keys before parent locks; hash collisions only serialize extra work.
 PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(p_actor,p_workspace,p_operation,p_key)::text,0));
 SELECT a.suspended INTO app_suspended FROM proof_parent_fixture.applications a
 WHERE a.workspace_id=p_workspace AND a.id=p_application FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'resource unavailable' USING ERRCODE='42501'; END IF;
 SELECT e.suspended INTO env_suspended FROM proof_parent_fixture.environments e
 WHERE e.workspace_id=p_workspace AND e.application_id=p_application AND e.environment=p_environment FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'resource unavailable' USING ERRCODE='42501'; END IF;
 SELECT o.* INTO parent FROM proof_parent_fixture.origins o
 WHERE o.workspace_id=p_workspace AND o.application_id=p_application AND o.environment=p_environment
 AND o.origin=p_origin FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'resource unavailable' USING ERRCODE='42501'; END IF;
 IF p_operation='read' THEN
  IF NOT (p_payload ? 'receipt_id') OR p_payload - 'receipt_id' <> '{}'::jsonb
  THEN RAISE EXCEPTION 'invalid input'; END IF;
  SELECT r.result INTO output FROM application_proof_proposal.receipts r
  WHERE r.id=(p_payload->>'receipt_id')::uuid AND r.workspace_id=p_workspace
  AND r.application_id=p_application AND r.environment=p_environment AND r.origin=p_origin;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource unavailable' USING ERRCODE='42501'; END IF;
  RETURN output; -- Historical, always access-disabled; never a current grant.
 END IF;
 request_input:=jsonb_build_object('application',p_application,'environment',p_environment,
  'origin',p_origin,'config',p_config,'proof',p_proof,'cas',p_cas,'payload',p_payload);
 SELECT q.* INTO prior FROM application_proof_proposal.requests q
 WHERE q.actor=p_actor AND q.workspace_id=p_workspace AND q.operation=p_operation AND q.key=p_key;
 IF FOUND THEN
  IF prior.input IS DISTINCT FROM request_input THEN RAISE EXCEPTION 'idempotency conflict'; END IF;
  SELECT r.result INTO output FROM application_proof_proposal.receipts r WHERE r.id=prior.receipt_id;
  RETURN output; -- No refresh of timestamps or lease; current authority already rechecked.
 END IF;
 IF parent.config_revision<>p_config OR parent.proof_revision<>p_proof OR parent.cas_revision<>p_cas
 THEN RAISE EXCEPTION 'revision conflict'; END IF;
 IF parent.revoked THEN RAISE EXCEPTION 'origin revoked'; END IF;
 IF app_suspended OR env_suspended THEN RAISE EXCEPTION 'resource suspended'; END IF;
 at_time:=clock_timestamp(); -- Sample after every contended lock, never transaction-start now().
 IF p_operation='issue' THEN
  IF NOT (p_payload ? 'digest') OR p_payload - 'digest' <> '{}'::jsonb
  OR jsonb_typeof(p_payload->'digest')<>'string' OR (p_payload->>'digest') !~ '^[0-9a-f]{64}$'
  THEN RAISE EXCEPTION 'invalid input'; END IF;
  UPDATE application_proof_proposal.challenges SET state='superseded'
  WHERE workspace_id=p_workspace AND application_id=p_application AND environment=p_environment
  AND origin=p_origin AND state='pending';
  INSERT INTO application_proof_proposal.challenges(workspace_id,application_id,environment,origin,
   config_revision,proof_revision,digest,issued_at,expires_at,state)
  VALUES(p_workspace,p_application,p_environment,p_origin,p_config,p_proof,p_payload->>'digest',
   at_time,at_time+interval '1 hour','pending') RETURNING id INTO challenge_id;
  output:=jsonb_build_object('challenge_id',challenge_id,'query_name','_recoup-app.'||parent.hostname,
   'issued_at',at_time,'expires_at',at_time+interval '1 hour');
 ELSIF p_operation='verify' THEN
  IF (p_payload - ARRAY['challenge_id','digest','query_name','queried_at','resolver_policy'])<>'{}'::jsonb
  OR NOT (p_payload ?& ARRAY['challenge_id','digest','query_name','queried_at','resolver_policy'])
  OR EXISTS(SELECT 1 FROM jsonb_each(p_payload) x WHERE jsonb_typeof(x.value)<>'string')
  THEN RAISE EXCEPTION 'invalid input'; END IF;
  SELECT c.* INTO challenge FROM application_proof_proposal.challenges c
  WHERE c.id=(p_payload->>'challenge_id')::uuid AND c.workspace_id=p_workspace
  AND c.application_id=p_application AND c.environment=p_environment AND c.origin=p_origin FOR UPDATE;
  IF NOT FOUND OR challenge.state<>'pending' THEN RAISE EXCEPTION 'challenge unavailable'; END IF;
  IF challenge.config_revision<>p_config OR challenge.proof_revision<>p_proof
  THEN RAISE EXCEPTION 'challenge revision conflict'; END IF;
  -- Challenge lock may also wait; sample again before evaluating expiry/freshness.
  at_time:=clock_timestamp();
  IF at_time>=challenge.expires_at THEN RAISE EXCEPTION 'challenge expired'; END IF;
  observed_at:=(p_payload->>'queried_at')::timestamptz;
  IF NOT isfinite(observed_at) OR observed_at<challenge.issued_at OR observed_at>at_time
  OR at_time-observed_at>interval '60 seconds'
  OR p_payload->>'query_name' IS DISTINCT FROM '_recoup-app.'||parent.hostname
  OR p_payload->>'digest' IS DISTINCT FROM challenge.digest
  OR p_payload->>'resolver_policy' IS DISTINCT FROM 'synthetic-v1'
  THEN RAISE EXCEPTION 'observation rejected'; END IF;
  challenge_id:=challenge.id;
  UPDATE application_proof_proposal.challenges SET state='consumed' WHERE id=challenge_id;
  parent.proof_revision:=parent.proof_revision+1;
  output:=jsonb_build_object('challenge_id',challenge_id,'observed_at',observed_at,
   'query_name',p_payload->>'query_name','matched_digest',challenge.digest,'resolver_policy','synthetic-v1',
   'qualification_valid_until',at_time+interval '7 days');
 ELSE
  IF p_payload<>'{}'::jsonb THEN RAISE EXCEPTION 'invalid input'; END IF;
  UPDATE application_proof_proposal.challenges SET state='revoked'
  WHERE workspace_id=p_workspace AND application_id=p_application AND environment=p_environment
  AND origin=p_origin AND state='pending';
  parent.proof_revision:=parent.proof_revision+1;
  parent.revoked:=true;
  output:=jsonb_build_object('revoked',true);
 END IF;
 parent.cas_revision:=parent.cas_revision+1;
 UPDATE proof_parent_fixture.origins SET proof_revision=parent.proof_revision,
  cas_revision=parent.cas_revision,revoked=parent.revoked
 WHERE workspace_id=p_workspace AND application_id=p_application AND environment=p_environment AND origin=p_origin;
 receipt_id:=gen_random_uuid();
 output:=output||jsonb_build_object('receipt_id',receipt_id,'operation',p_operation,'actor',p_actor,
  'workspace_id',p_workspace,'application_id',p_application,'environment',p_environment,'origin',p_origin,
  'config_revision',p_config,'proof_revision',parent.proof_revision,'cas_revision',parent.cas_revision,
  'recorded_at',at_time,'access_activated',false,'bootstrap_enabled',false,'evidence_kind','synthetic_observation');
 INSERT INTO application_proof_proposal.receipts(id,workspace_id,application_id,environment,origin,
  actor,operation,challenge_id,recorded_at,result)
 VALUES(receipt_id,p_workspace,p_application,p_environment,p_origin,p_actor,p_operation,challenge_id,at_time,output);
 INSERT INTO application_proof_proposal.requests VALUES(p_actor,p_workspace,p_operation,p_key,request_input,receipt_id);
 RETURN output;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA application_proof_proposal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA application_proof_proposal FROM PUBLIC;
