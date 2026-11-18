-- INACTIVE PROPOSAL. Outside migrations; no live enrollment, grants or credential store.
-- Requires the existing public.accounts relation. Never load qualification-bootstrap in runtime.
CREATE SCHEMA application_registration_proposal;
REVOKE ALL ON SCHEMA application_registration_proposal FROM PUBLIC;
CREATE TABLE application_registration_proposal.personal_principals (
 account_id uuid PRIMARY KEY REFERENCES public.accounts(id),
 enabled boolean NOT NULL DEFAULT true,
 policy_version text NOT NULL DEFAULT 'proposed-personal-v1' CHECK(policy_version='proposed-personal-v1')
);
-- An enrollment row is an explicit proposed personal classification, not UUID equality/membership inference.
CREATE TABLE application_registration_proposal.create_entitlements (
 actor uuid NOT NULL REFERENCES application_registration_proposal.personal_principals(account_id),
 workspace_id uuid NOT NULL CHECK(workspace_id=actor),
 environment text NOT NULL CHECK(environment IN ('production','development')),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision BETWEEN 1 AND 9007199254740991),
 enabled boolean NOT NULL DEFAULT true, expires_at timestamptz CHECK(isfinite(expires_at)),
 policy_version text NOT NULL DEFAULT 'proposed-personal-v1' CHECK(policy_version='proposed-personal-v1'),
 PRIMARY KEY(actor,workspace_id,environment)
);
CREATE TABLE application_registration_proposal.applications (
 workspace_id uuid NOT NULL REFERENCES application_registration_proposal.personal_principals(account_id),
 id uuid NOT NULL DEFAULT gen_random_uuid(),
 billing_owner_id uuid NOT NULL CHECK(billing_owner_id=workspace_id),
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 120),
 suspended boolean NOT NULL DEFAULT false,
 PRIMARY KEY(workspace_id,id)
);
CREATE TABLE application_registration_proposal.environments (
 workspace_id uuid NOT NULL, application_id uuid NOT NULL,
 environment text NOT NULL CHECK(environment IN ('production','development')),
 suspended boolean NOT NULL DEFAULT false,
 PRIMARY KEY(workspace_id,application_id,environment),
 FOREIGN KEY(workspace_id,application_id) REFERENCES application_registration_proposal.applications
);
CREATE TABLE application_registration_proposal.origins (
 workspace_id uuid NOT NULL, application_id uuid NOT NULL, environment text NOT NULL,
 origin text NOT NULL, hostname text NOT NULL, return_urls text[] NOT NULL,
 config_revision bigint NOT NULL DEFAULT 1 CHECK(config_revision>0),
 proof_revision bigint NOT NULL DEFAULT 1 CHECK(proof_revision>0),
 cas_revision bigint NOT NULL DEFAULT 1 CHECK(cas_revision>0), revoked boolean NOT NULL DEFAULT false,
 PRIMARY KEY(workspace_id,application_id,environment,origin),
 FOREIGN KEY(workspace_id,application_id,environment) REFERENCES application_registration_proposal.environments
);
CREATE TABLE application_registration_proposal.management_entitlements (
 actor uuid NOT NULL REFERENCES application_registration_proposal.personal_principals(account_id),
 workspace_id uuid NOT NULL CHECK(workspace_id=actor), application_id uuid NOT NULL, environment text NOT NULL,
 operation text NOT NULL CHECK(operation IN ('read_registration','issue','verify','revoke','read','replace_existing_origin_return_urls')),
 enabled boolean NOT NULL DEFAULT true, revision bigint NOT NULL DEFAULT 1 CHECK(revision>0),
 policy_version text NOT NULL DEFAULT 'proposed-personal-v1' CHECK(policy_version='proposed-personal-v1'),
 PRIMARY KEY(actor,workspace_id,application_id,environment,operation),
 FOREIGN KEY(workspace_id,application_id,environment) REFERENCES application_registration_proposal.environments
);
CREATE TABLE application_registration_proposal.receipts (
 id uuid PRIMARY KEY, actor uuid NOT NULL, workspace_id uuid NOT NULL,
 application_id uuid NOT NULL, environment text NOT NULL, recorded_at timestamptz NOT NULL,
 result jsonb NOT NULL,
 FOREIGN KEY(workspace_id,application_id,environment) REFERENCES application_registration_proposal.environments,
 CHECK(result @> '{"origins_verified":false,"bootstrap_enabled":false,"access_activated":false,"runtime_enabled":false,"production_persisted":false,"policy_status":"proposed_unadopted","evidence_kind":"disposable_parent_assertion"}')
);
CREATE TABLE application_registration_proposal.requests (
 actor uuid NOT NULL, workspace_id uuid NOT NULL, key text NOT NULL,
 input jsonb NOT NULL, receipt_id uuid NOT NULL REFERENCES application_registration_proposal.receipts,
 PRIMARY KEY(actor,workspace_id,key)
);
CREATE FUNCTION application_registration_proposal.immutable_history() RETURNS trigger
 LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'immutable registration history'; END $$;
CREATE TRIGGER immutable_receipt BEFORE UPDATE OR DELETE ON application_registration_proposal.receipts
 FOR EACH ROW EXECUTE FUNCTION application_registration_proposal.immutable_history();
CREATE TRIGGER immutable_request BEFORE UPDATE OR DELETE ON application_registration_proposal.requests
 FOR EACH ROW EXECUTE FUNCTION application_registration_proposal.immutable_history();
REVOKE ALL ON ALL TABLES IN SCHEMA application_registration_proposal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA application_registration_proposal FROM PUBLIC;
