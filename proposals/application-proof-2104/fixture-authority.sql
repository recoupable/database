-- TEST-ONLY override. Never load outside this disposable fixture.
CREATE OR REPLACE FUNCTION application_proof_proposal.authorize_management(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_operation text
) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE enabled_value boolean; permitted text[];
BEGIN
 SELECT a.enabled,a.operations INTO enabled_value,permitted
 FROM proof_parent_fixture.authority a
 WHERE a.actor=p_actor AND a.workspace_id=p_workspace AND a.application_id=p_application
 AND a.environment=p_environment FOR SHARE;
 IF enabled_value IS DISTINCT FROM true OR NOT (p_operation=ANY(permitted))
 THEN RAISE EXCEPTION 'management authority unavailable' USING ERRCODE='42501'; END IF;
END $$;
REVOKE ALL ON FUNCTION application_proof_proposal.authorize_management(uuid,uuid,uuid,text,text) FROM PUBLIC;
