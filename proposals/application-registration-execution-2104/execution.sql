-- INACTIVE DISPOSABLE QUALIFICATION ONLY. Not a migration or production role contract.
-- Requires exact D and qualification-roles.sql in an owned Unix-only test cluster.
BEGIN;
DO $$ BEGIN
 IF current_setting('qualification.registration_fixture',true) IS DISTINCT FROM 'owned-disposable-only'
 OR to_regrole('qualification_registration_executor') IS NULL
 OR to_regclass('application_registration_proposal.requests') IS NULL THEN
  RAISE EXCEPTION 'owned disposable registration fixture required';
 END IF;
END $$;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE qualification_registration_data_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE qualification_registration_executor REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
CREATE SCHEMA application_registration_execution_proposal AUTHORIZATION qualification_registration_data_owner;
REVOKE ALL ON SCHEMA application_registration_execution_proposal FROM PUBLIC;
GRANT USAGE,CREATE ON SCHEMA application_registration_execution_proposal TO qualification_registration_executor;
SET LOCAL ROLE qualification_registration_executor;
CREATE FUNCTION application_registration_execution_proposal.create_registration(
 p_actor uuid,p_workspace uuid,p_environment text,p_key text,p_entitlement_revision bigint,p_registration jsonb
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET row_security=on
 AS $$ SELECT application_registration_proposal.register_application($1,$2,$3,$4,$5,$6) $$;
CREATE FUNCTION application_registration_execution_proposal.read_registration(
 p_actor uuid,p_workspace uuid,p_application uuid,p_environment text,p_receipt uuid
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET row_security=on
 AS $$ SELECT application_registration_proposal.read_registration($1,$2,$3,$4,$5) $$;
RESET ROLE;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA application_registration_execution_proposal FROM PUBLIC;
REVOKE CREATE ON SCHEMA application_registration_execution_proposal FROM qualification_registration_executor;
GRANT USAGE ON SCHEMA application_registration_execution_proposal TO qualification_registration_runtime;
GRANT EXECUTE ON FUNCTION application_registration_execution_proposal.create_registration(uuid,uuid,text,text,bigint,jsonb),
 application_registration_execution_proposal.read_registration(uuid,uuid,uuid,text,uuid) TO qualification_registration_runtime;
COMMIT;
