-- SYNTHETIC OWNED-CLUSTER SETUP ONLY. Never run on a hosted/live database.
DO $$ BEGIN
 IF current_setting('qualification.registration_fixture',true) IS DISTINCT FROM 'owned-disposable-only' THEN
  RAISE EXCEPTION 'owned disposable registration fixture required';
 END IF;
END $$;
CREATE ROLE qualification_registration_data_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE qualification_registration_executor NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE qualification_registration_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE qualification_registration_client LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE qualification_registration_browser LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
GRANT qualification_registration_runtime TO qualification_registration_client;
-- Ordinary PostgreSQL defaults include database TEMP and public schema USAGE.
-- This stricter synthetic profile denies TEMP; one reversible shadow-test grant is separate.
REVOKE CREATE,TEMPORARY ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON SCHEMA public,qualification_auth,application_registration_proposal FROM PUBLIC;
ALTER SCHEMA public OWNER TO qualification_registration_data_owner;
ALTER SCHEMA qualification_auth OWNER TO qualification_registration_data_owner;
ALTER SCHEMA application_registration_proposal OWNER TO qualification_registration_data_owner;
ALTER TABLE public.accounts OWNER TO qualification_registration_data_owner;
DO $$ DECLARE r record;
BEGIN
 FOR r IN SELECT c.oid::regclass AS relation FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='application_registration_proposal' AND c.relkind='r' LOOP
  EXECUTE format('ALTER TABLE %s OWNER TO qualification_registration_data_owner',r.relation);
 END LOOP;
 FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('application_registration_proposal','qualification_auth') LOOP
  EXECUTE format('ALTER FUNCTION %s OWNER TO qualification_registration_data_owner',r.signature);
 END LOOP;
END $$;
GRANT USAGE ON SCHEMA public,application_registration_proposal TO qualification_registration_executor;
GRANT EXECUTE ON FUNCTION application_registration_proposal.register_application(uuid,uuid,text,text,bigint,jsonb),
 application_registration_proposal.read_registration(uuid,uuid,uuid,text,uuid),
 application_registration_proposal.authorize_principal(uuid,uuid),
 application_registration_proposal.authorize_create(uuid,uuid,text),
 application_registration_proposal.authorize_management(uuid,uuid,uuid,text,text) TO qualification_registration_executor;
GRANT SELECT(id),UPDATE(id) ON public.accounts TO qualification_registration_executor;
GRANT SELECT(account_id,enabled,policy_version),UPDATE(account_id) ON application_registration_proposal.personal_principals TO qualification_registration_executor;
GRANT SELECT(actor,workspace_id,environment,revision,enabled,expires_at,policy_version),UPDATE(actor) ON application_registration_proposal.create_entitlements TO qualification_registration_executor;
GRANT SELECT(actor,workspace_id,application_id,environment,operation,enabled,revision,policy_version),UPDATE(actor) ON application_registration_proposal.management_entitlements TO qualification_registration_executor;
GRANT SELECT(actor,workspace_id,key,input,receipt_id),INSERT(actor,workspace_id,key,input,receipt_id) ON application_registration_proposal.requests TO qualification_registration_executor;
GRANT SELECT(id,result,workspace_id,application_id,environment),INSERT(id,actor,workspace_id,application_id,environment,recorded_at,result) ON application_registration_proposal.receipts TO qualification_registration_executor;
GRANT INSERT(workspace_id,id,billing_owner_id,name) ON application_registration_proposal.applications TO qualification_registration_executor;
GRANT INSERT(workspace_id,application_id,environment) ON application_registration_proposal.environments TO qualification_registration_executor;
GRANT INSERT(workspace_id,application_id,environment,origin,hostname,return_urls) ON application_registration_proposal.origins TO qualification_registration_executor;
DO $$ DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['public.accounts','application_registration_proposal.personal_principals',
 'application_registration_proposal.create_entitlements','application_registration_proposal.management_entitlements',
 'application_registration_proposal.requests','application_registration_proposal.receipts',
 'application_registration_proposal.applications','application_registration_proposal.environments','application_registration_proposal.origins'] LOOP
  EXECUTE 'ALTER TABLE '||t||' ENABLE ROW LEVEL SECURITY';
  EXECUTE 'ALTER TABLE '||t||' FORCE ROW LEVEL SECURITY';
 END LOOP;
 FOREACH t IN ARRAY ARRAY['public.accounts','application_registration_proposal.personal_principals',
 'application_registration_proposal.create_entitlements','application_registration_proposal.management_entitlements',
 'application_registration_proposal.requests','application_registration_proposal.receipts'] LOOP
  EXECUTE 'CREATE POLICY executor_select ON '||t||' FOR SELECT TO qualification_registration_executor USING (true)';
 END LOOP;
 FOREACH t IN ARRAY ARRAY['public.accounts','application_registration_proposal.personal_principals',
 'application_registration_proposal.create_entitlements','application_registration_proposal.management_entitlements'] LOOP
  EXECUTE 'CREATE POLICY executor_lock ON '||t||' FOR UPDATE TO qualification_registration_executor USING (true) WITH CHECK (false)';
 END LOOP;
 FOREACH t IN ARRAY ARRAY['application_registration_proposal.applications','application_registration_proposal.environments',
 'application_registration_proposal.origins','application_registration_proposal.receipts','application_registration_proposal.requests'] LOOP
  EXECUTE 'CREATE POLICY executor_insert ON '||t||' FOR INSERT TO qualification_registration_executor WITH CHECK (true)';
 END LOOP;
END $$;
