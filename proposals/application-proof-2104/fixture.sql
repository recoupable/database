-- SYNTHETIC parent schema, not an application registry or production migration.
CREATE SCHEMA proof_parent_fixture;
REVOKE ALL ON SCHEMA proof_parent_fixture FROM PUBLIC;
CREATE TABLE proof_parent_fixture.workspaces (id uuid PRIMARY KEY);
CREATE TABLE proof_parent_fixture.applications (
 workspace_id uuid REFERENCES proof_parent_fixture.workspaces,
 id uuid NOT NULL, suspended boolean NOT NULL DEFAULT false,
 PRIMARY KEY(workspace_id,id)
);
CREATE TABLE proof_parent_fixture.environments (
 workspace_id uuid NOT NULL, application_id uuid NOT NULL,
 environment text CHECK(environment IN ('production','development')),
 suspended boolean NOT NULL DEFAULT false,
 PRIMARY KEY(workspace_id,application_id,environment),
 FOREIGN KEY(workspace_id,application_id) REFERENCES proof_parent_fixture.applications
);
CREATE TABLE proof_parent_fixture.origins (
 workspace_id uuid NOT NULL, application_id uuid NOT NULL, environment text NOT NULL,
 origin text NOT NULL, hostname text NOT NULL,
 config_revision bigint NOT NULL DEFAULT 1 CHECK(config_revision>0),
 proof_revision bigint NOT NULL DEFAULT 1 CHECK(proof_revision>0),
 cas_revision bigint NOT NULL DEFAULT 1 CHECK(cas_revision>0),
 revoked boolean NOT NULL DEFAULT false,
 PRIMARY KEY(workspace_id,application_id,environment,origin),
 FOREIGN KEY(workspace_id,application_id,environment) REFERENCES proof_parent_fixture.environments
);
-- No grants or membership inference. This is replaced only in disposable tests.
CREATE TABLE proof_parent_fixture.authority (
 actor uuid, workspace_id uuid, application_id uuid, environment text,
 operations text[] NOT NULL, enabled boolean NOT NULL DEFAULT true,
 PRIMARY KEY(actor,workspace_id,application_id,environment)
);
