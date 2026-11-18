-- INACTIVE proposal. Apply only to disposable fixtures; never a migration runner.
BEGIN;
ALTER TABLE public.release_pack_jobs ADD COLUMN protocol integer NOT NULL DEFAULT 1 CHECK(protocol IN(1,2)),
 ADD COLUMN execution_id uuid, ADD COLUMN execution_version integer NOT NULL DEFAULT 0,
 ADD COLUMN context_version integer NOT NULL DEFAULT 0;
ALTER TABLE public.release_pack_assets ADD COLUMN claim_id uuid;
CREATE TABLE public.release_pack_executions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), job_id uuid NOT NULL REFERENCES public.release_pack_jobs(id) ON DELETE RESTRICT,
 owner_id uuid NOT NULL, revision integer NOT NULL, version integer NOT NULL,
 quote_id uuid NOT NULL, transition_id uuid NOT NULL, transition_action text NOT NULL,
 transition_payload jsonb NOT NULL, transition_result jsonb, workflow_run_id text UNIQUE,
 resume_asset_id uuid, settlement_payload jsonb, settlement_result jsonb,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(job_id,version), UNIQUE(job_id,transition_id)
);
CREATE TABLE public.release_pack_claims (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), execution_id uuid NOT NULL REFERENCES public.release_pack_executions(id) ON DELETE RESTRICT,
 owner_id uuid NOT NULL, asset_id uuid NOT NULL REFERENCES public.release_pack_assets(id) ON DELETE RESTRICT,
 attempt integer NOT NULL, request_id uuid NOT NULL, request_payload jsonb NOT NULL,
 claim_result jsonb, completion_payload jsonb, completion_result jsonb,
 operation_ids uuid[] NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(execution_id,asset_id), CHECK(cardinality(operation_ids)<=5)
);
CREATE TABLE public.release_pack_provider_operations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id uuid NOT NULL,
 job_id uuid NOT NULL REFERENCES public.release_pack_jobs(id) ON DELETE RESTRICT,
 asset_id uuid NOT NULL REFERENCES public.release_pack_assets(id) ON DELETE RESTRICT,
 revision integer NOT NULL, execution_id uuid NOT NULL REFERENCES public.release_pack_executions(id) ON DELETE RESTRICT,
 execution_version integer NOT NULL, workflow_run_id text NOT NULL,
 claim_id uuid NOT NULL REFERENCES public.release_pack_claims(id) ON DELETE RESTRICT,
 attempt integer NOT NULL, phase text NOT NULL, provider text NOT NULL CHECK(provider='fal'),
 model text NOT NULL CHECK(length(model) BETWEEN 1 AND 200),
 input_sha256 text NOT NULL CHECK(input_sha256 ~ '^[a-f0-9]{64}$'),
 charge_credits bigint NOT NULL CHECK(charge_credits>0), created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(owner_id,asset_id,attempt,phase)
);
CREATE INDEX release_pack_provider_operations_page ON public.release_pack_provider_operations(owner_id,job_id,id);
CREATE TABLE public.release_pack_provider_observations (
 operation_id uuid NOT NULL REFERENCES public.release_pack_provider_operations(id) ON DELETE RESTRICT,
 kind text NOT NULL CHECK(kind IN('accepted','completed','failed','conflict')),
 payload jsonb NOT NULL CHECK(octet_length(payload::text)<=1024),
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(operation_id,kind)
);
ALTER TABLE public.release_pack_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.release_pack_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.release_pack_provider_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.release_pack_provider_observations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.release_pack_executions,public.release_pack_claims,public.release_pack_provider_operations,public.release_pack_provider_observations FROM PUBLIC,anon,authenticated,service_role;
-- Existing callers use the RPC. No raw worker DML may bypass protocol ownership.
REVOKE INSERT,UPDATE,DELETE ON public.release_pack_jobs,public.release_pack_assets FROM service_role;
ALTER FUNCTION public.release_pack_command(uuid,uuid,text,uuid,jsonb) RENAME TO release_pack_command_legacy_internal;
REVOKE ALL ON FUNCTION public.release_pack_command_legacy_internal(uuid,uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.authorize_pack_actor(p_actor uuid,p_org uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF p_actor IS NULL THEN RAISE EXCEPTION 'Pack access denied' USING ERRCODE='42501'; END IF;
 IF p_org IS NOT NULL AND p_org<>p_actor THEN
   PERFORM 1 FROM public.account_organization_ids WHERE account_id=p_actor AND organization_id=p_org FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Pack access denied' USING ERRCODE='42501'; END IF;
 END IF;
 RETURN coalesce(p_org,p_actor);
END $$;
REVOKE ALL ON FUNCTION public.authorize_pack_actor(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.release_pack_command(p_actor uuid,p_org uuid,p_action text,p_job uuid,p_input jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result jsonb; owner uuid;
BEGIN
 owner:=public.authorize_pack_actor(p_actor,p_org);
 -- Both protocols serialize the same creation identity before looking up or inserting.
 IF p_action='prepare' AND NOT(p_input ? 'expected_revision') THEN
   PERFORM pg_advisory_xact_lock(hashtextextended(owner::text||':'||(p_input->>'idempotency_key'),0));
 END IF;
 IF EXISTS(SELECT 1 FROM public.release_pack_jobs WHERE id=p_job AND protocol=2) THEN
   RAISE EXCEPTION 'Protocol 2 requires a fenced caller'; END IF;
 result:=public.release_pack_command_legacy_internal(p_actor,p_org,p_action,p_job,p_input);
 -- Also protects idempotency-key resolution and a concurrent prepare at another ID.
 IF (result->'job'->>'protocol')::integer=2 THEN RAISE EXCEPTION 'Protocol 2 requires a fenced caller'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.release_pack_command(uuid,uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.release_pack_command(uuid,uuid,text,uuid,jsonb) TO service_role;
COMMIT;
