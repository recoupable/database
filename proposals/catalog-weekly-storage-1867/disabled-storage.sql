-- OFFLINE PROTOTYPE ONLY. Not in supabase/migrations. No execution/enable path.
BEGIN;
CREATE ROLE catalog_report_owner NOLOGIN NOINHERIT;
GRANT USAGE ON SCHEMA public TO catalog_report_owner;
GRANT SELECT ON public.accounts, public.catalogs, public.account_organization_ids, public.account_catalogs TO catalog_report_owner;
-- PostgreSQL row-lock privilege only; owner is NOLOGIN and exposes no dependency writes.
GRANT UPDATE(id) ON public.accounts, public.catalogs TO catalog_report_owner;
GRANT UPDATE(account_id) ON public.account_organization_ids TO catalog_report_owner;
GRANT UPDATE(account) ON public.account_catalogs TO catalog_report_owner;

-- Dependency RLS access for this isolated RPC owner only; no browser/service policy.
CREATE POLICY catalog_report_owner_read ON public.accounts FOR SELECT TO catalog_report_owner USING (true);
-- Row-lock scans also consult UPDATE USING; WITH CHECK false prohibits writes.
CREATE POLICY catalog_report_owner_lock ON public.accounts FOR UPDATE TO catalog_report_owner USING (true) WITH CHECK (false);
CREATE POLICY catalog_report_owner_read ON public.catalogs FOR SELECT TO catalog_report_owner USING (true);
-- Row-lock scans also consult UPDATE USING; WITH CHECK false prohibits writes.
CREATE POLICY catalog_report_owner_lock ON public.catalogs FOR UPDATE TO catalog_report_owner USING (true) WITH CHECK (false);
CREATE POLICY catalog_report_owner_read ON public.account_organization_ids FOR SELECT TO catalog_report_owner USING (true);
-- Row-lock scans also consult UPDATE USING; WITH CHECK false prohibits writes.
CREATE POLICY catalog_report_owner_lock ON public.account_organization_ids FOR UPDATE TO catalog_report_owner USING (true) WITH CHECK (false);
CREATE POLICY catalog_report_owner_read ON public.account_catalogs FOR SELECT TO catalog_report_owner USING (true);
-- Row-lock scans also consult UPDATE USING; WITH CHECK false prohibits writes.
CREATE POLICY catalog_report_owner_lock ON public.account_catalogs FOR UPDATE TO catalog_report_owner USING (true) WITH CHECK (false);

CREATE TABLE public.catalog_report_schedules (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 kind text NOT NULL DEFAULT 'catalog_weekly_report' CHECK(kind='catalog_weekly_report'),
 schema_version smallint NOT NULL DEFAULT 1 CHECK(schema_version=1),
 actor_account_id uuid NOT NULL,
 effective_account_id uuid NOT NULL CHECK(effective_account_id=actor_account_id),
 organization_id uuid,
 owner_id uuid GENERATED ALWAYS AS(coalesce(organization_id,effective_account_id)) STORED,
 catalog_id uuid NOT NULL,
 recipient_account_id uuid NOT NULL CHECK(recipient_account_id=effective_account_id),
 principal_mechanism text NOT NULL CHECK(principal_mechanism IN ('recoup_api_key','privy')),
 api_key_id uuid,
 privy_app_id text CHECK(privy_app_id IS NULL OR length(privy_app_id) BETWEEN 1 AND 200),
 privy_issuer text CHECK(privy_issuer IS NULL OR length(privy_issuer) BETWEEN 1 AND 500),
 privy_subject text CHECK(privy_subject IS NULL OR length(privy_subject) BETWEEN 1 AND 300),
 revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
 schedule text NOT NULL CHECK(schedule ~ '^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) \* \* [0-6]$'),
 timezone text NOT NULL CHECK(length(timezone) BETWEEN 1 AND 100),
 enabled boolean NOT NULL DEFAULT false CHECK(NOT enabled),
 next_due_at timestamptz CHECK(next_due_at IS NULL),
 archived_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((principal_mechanism='recoup_api_key' AND api_key_id IS NOT NULL AND privy_app_id IS NULL AND privy_issuer IS NULL AND privy_subject IS NULL)
 OR (principal_mechanism='privy' AND api_key_id IS NULL AND privy_app_id IS NOT NULL AND privy_issuer IS NOT NULL AND privy_subject IS NOT NULL))
);
CREATE UNIQUE INDEX catalog_report_business_key ON public.catalog_report_schedules(kind,effective_account_id,organization_id,catalog_id) NULLS NOT DISTINCT WHERE archived_at IS NULL;
CREATE INDEX ON public.catalog_report_schedules(owner_id,created_at,id);
CREATE TABLE public.catalog_report_schedule_revisions (
 schedule_id uuid NOT NULL REFERENCES public.catalog_report_schedules(id) ON DELETE RESTRICT,
 revision integer NOT NULL CHECK(revision>0),
 changed_by_account_id uuid NOT NULL,
 operation text NOT NULL CHECK(operation IN ('create','edit_disabled','disable','archive')),
 schedule text NOT NULL CHECK(schedule ~ '^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) \* \* [0-6]$'),
 timezone text NOT NULL CHECK(length(timezone) BETWEEN 1 AND 100),
 enabled boolean NOT NULL CHECK(NOT enabled),
 archived_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(schedule_id,revision),
 CHECK((revision=1)=(operation='create')),
 CHECK((archived_at IS NOT NULL)=(operation='archive'))
);
ALTER TABLE public.catalog_report_schedules ADD CONSTRAINT catalog_report_current_revision FOREIGN KEY(id,revision) REFERENCES public.catalog_report_schedule_revisions(schedule_id,revision) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE public.catalog_report_mutation_receipts (
 actor_account_id uuid NOT NULL,
 request_id uuid NOT NULL,
 schedule_id uuid NOT NULL,
 revision integer NOT NULL,
 operation text NOT NULL CHECK(operation IN ('create','edit_disabled','disable','archive')),
 input jsonb NOT NULL CHECK(jsonb_typeof(input)='object' AND octet_length(input::text)<=16384),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(actor_account_id,request_id),
 FOREIGN KEY(schedule_id,revision) REFERENCES public.catalog_report_schedule_revisions(schedule_id,revision) ON DELETE RESTRICT
);
ALTER TABLE public.catalog_report_schedules OWNER TO catalog_report_owner;
ALTER TABLE public.catalog_report_schedule_revisions OWNER TO catalog_report_owner;
ALTER TABLE public.catalog_report_mutation_receipts OWNER TO catalog_report_owner;
ALTER TABLE public.catalog_report_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_report_schedule_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_report_mutation_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.catalog_report_schedules, public.catalog_report_schedule_revisions, public.catalog_report_mutation_receipts FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.catalog_report_immutable_guard() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF TG_OP<>'UPDATE' OR TG_TABLE_NAME<>'catalog_report_schedules' THEN
  RAISE EXCEPTION 'Immutable catalog report history' USING ERRCODE='42501';
 END IF;
 IF (to_jsonb(NEW)-ARRAY['revision','schedule','timezone','enabled','next_due_at','archived_at','updated_at','owner_id'])
 IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['revision','schedule','timezone','enabled','next_due_at','archived_at','updated_at','owner_id'])
 OR OLD.archived_at IS NOT NULL OR OLD.revision=2147483647 OR NEW.revision<>OLD.revision+1 THEN
  RAISE EXCEPTION 'Immutable catalog report identity or revision' USING ERRCODE='42501';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER catalog_report_immutable BEFORE UPDATE OR DELETE ON public.catalog_report_schedules FOR EACH ROW EXECUTE FUNCTION public.catalog_report_immutable_guard();
CREATE TRIGGER catalog_report_revision_immutable BEFORE UPDATE OR DELETE ON public.catalog_report_schedule_revisions FOR EACH ROW EXECUTE FUNCTION public.catalog_report_immutable_guard();
CREATE TRIGGER catalog_report_receipt_immutable BEFORE UPDATE OR DELETE ON public.catalog_report_mutation_receipts FOR EACH ROW EXECUTE FUNCTION public.catalog_report_immutable_guard();

CREATE FUNCTION public.catalog_report_keys(p jsonb, keys text[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT coalesce(jsonb_typeof(p)='object' AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p) k)=(SELECT array_agg(k ORDER BY k) FROM unnest(keys) k),false)
$$;
CREATE FUNCTION public.catalog_report_uuid(p jsonb) RETURNS uuid LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'string' OR (p#>>'{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
  RAISE EXCEPTION 'Invalid catalog report UUID' USING ERRCODE='22023';
 END IF;
 RETURN (p#>>'{}')::uuid;
END $$;
CREATE FUNCTION public.catalog_report_validate_principal(p jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid principal' USING ERRCODE='22023'; END IF;
 IF p->>'mechanism'='recoup_api_key' THEN
  IF NOT public.catalog_report_keys(p,ARRAY['mechanism','key_id']) THEN RAISE EXCEPTION 'Invalid principal keys' USING ERRCODE='22023'; END IF;
  PERFORM public.catalog_report_uuid(p->'key_id');
 ELSIF p->>'mechanism'='privy' THEN
  IF NOT public.catalog_report_keys(p,ARRAY['mechanism','app_id','issuer','subject'])
   OR jsonb_typeof(p->'app_id') IS DISTINCT FROM 'string' OR length(p->>'app_id') NOT BETWEEN 1 AND 200
   OR jsonb_typeof(p->'issuer') IS DISTINCT FROM 'string' OR length(p->>'issuer') NOT BETWEEN 1 AND 500
   OR jsonb_typeof(p->'subject') IS DISTINCT FROM 'string' OR length(p->>'subject') NOT BETWEEN 1 AND 300 THEN
   RAISE EXCEPTION 'Invalid principal' USING ERRCODE='22023'; END IF;
 ELSE RAISE EXCEPTION 'Unsupported principal' USING ERRCODE='22023'; END IF;
END $$;
CREATE FUNCTION public.catalog_report_validate_schedule(s jsonb,z jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF jsonb_typeof(s) IS DISTINCT FROM 'string' OR (s#>>'{}') !~ '^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) \* \* [0-6]$'
 OR jsonb_typeof(z) IS DISTINCT FROM 'string' OR length(z#>>'{}') NOT BETWEEN 1 AND 100
 OR ((z#>>'{}')<>'UTC' AND (z#>>'{}') !~ '^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$')
 OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name=z#>>'{}') THEN
  RAISE EXCEPTION 'Invalid weekly schedule or timezone' USING ERRCODE='22023'; END IF;
END $$;
CREATE FUNCTION public.catalog_report_authorize(p_actor uuid,p_org uuid,p_catalog uuid) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE owner_id uuid:=coalesce(p_org,p_actor); found_count integer;
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Read committed required' USING ERRCODE='25001'; END IF;
 PERFORM 1 FROM public.accounts WHERE id IN (p_actor,owner_id) ORDER BY id FOR KEY SHARE;
 GET DIAGNOSTICS found_count=ROW_COUNT;
 IF p_actor IS NULL OR found_count<>(CASE WHEN p_actor=owner_id THEN 1 ELSE 2 END) THEN RAISE EXCEPTION 'Catalog access denied' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.catalogs WHERE id=p_catalog FOR KEY SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Catalog access denied' USING ERRCODE='42501'; END IF;
 IF p_org IS NOT NULL AND p_actor<>p_org THEN
  PERFORM 1 FROM public.account_organization_ids WHERE account_id=p_actor AND organization_id=p_org FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Catalog access denied' USING ERRCODE='42501'; END IF;
 END IF;
 PERFORM 1 FROM public.account_catalogs WHERE account=owner_id AND catalog=p_catalog FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Catalog access denied' USING ERRCODE='42501'; END IF;
END $$;
CREATE FUNCTION public.catalog_report_match_principal(s public.catalog_report_schedules,p_actor uuid,p jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF s.actor_account_id IS DISTINCT FROM p_actor OR s.effective_account_id IS DISTINCT FROM p_actor
 OR s.principal_mechanism IS DISTINCT FROM p->>'mechanism'
 OR s.api_key_id IS DISTINCT FROM (CASE WHEN p->>'mechanism'='recoup_api_key' THEN (p->>'key_id')::uuid ELSE NULL END)
 OR s.privy_app_id IS DISTINCT FROM p->>'app_id' OR s.privy_issuer IS DISTINCT FROM p->>'issuer' OR s.privy_subject IS DISTINCT FROM p->>'subject' THEN
  RAISE EXCEPTION 'Original management principal required' USING ERRCODE='42501'; END IF;
END $$;
CREATE FUNCTION public.catalog_report_response(p_id uuid,p_revision integer,p_replayed boolean) RETURNS jsonb LANGUAGE sql SET search_path='' AS $$
 SELECT jsonb_build_object('id',s.id,'kind',s.kind,'version',s.schema_version,'catalog_id',s.catalog_id,'organization_id',s.organization_id,
 'revision',r.revision,'enabled',r.enabled,'schedule',r.schedule,'timezone',r.timezone,'archived_at',r.archived_at,'replayed',p_replayed)
 FROM public.catalog_report_schedules s JOIN public.catalog_report_schedule_revisions r ON r.schedule_id=s.id AND r.revision=p_revision WHERE s.id=p_id
$$;
CREATE FUNCTION public.read_catalog_report_schedule(p_actor uuid,p_principal jsonb,p_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.catalog_report_schedules;
BEGIN
 IF p_actor IS NULL OR p_id IS NULL THEN RAISE EXCEPTION 'Missing management identity' USING ERRCODE='22023'; END IF;
 PERFORM public.catalog_report_validate_principal(p_principal);
 SELECT * INTO s FROM public.catalog_report_schedules WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Catalog schedule unavailable' USING ERRCODE='42501'; END IF;
 PERFORM public.catalog_report_match_principal(s,p_actor,p_principal);
 PERFORM public.catalog_report_authorize(p_actor,s.organization_id,s.catalog_id);
 SELECT * INTO s FROM public.catalog_report_schedules WHERE id=p_id FOR SHARE;
 RETURN public.catalog_report_response(s.id,s.revision,false);
END $$;
CREATE FUNCTION public.mutate_catalog_report_schedule(p_actor uuid,p_principal jsonb,p_request uuid,p_command jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE action text; payload jsonb; org_id uuid; selected_catalog uuid; task_id uuid; expected integer;
 s public.catalog_report_schedules; receipt public.catalog_report_mutation_receipts; is_replay boolean;
BEGIN
 IF p_actor IS NULL OR p_request IS NULL OR jsonb_typeof(p_command) IS DISTINCT FROM 'object' OR octet_length(p_command::text)>16384 THEN RAISE EXCEPTION 'Invalid command' USING ERRCODE='22023'; END IF;
 PERFORM public.catalog_report_validate_principal(p_principal);
 IF NOT public.catalog_report_keys(p_command,ARRAY['action','payload']) OR jsonb_typeof(p_command->'action') IS DISTINCT FROM 'string' OR jsonb_typeof(p_command->'payload') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid command keys' USING ERRCODE='22023'; END IF;
 action:=p_command->>'action';payload:=p_command->'payload';
 IF action='create' THEN
  IF NOT public.catalog_report_keys(payload,ARRAY['catalog_id','organization_id','schedule','timezone']) THEN RAISE EXCEPTION 'Invalid create keys' USING ERRCODE='22023'; END IF;
  selected_catalog:=public.catalog_report_uuid(payload->'catalog_id');
  IF payload->'organization_id'<>'null'::jsonb THEN org_id:=public.catalog_report_uuid(payload->'organization_id'); END IF;
  PERFORM public.catalog_report_validate_schedule(payload->'schedule',payload->'timezone');
 ELSIF action IN ('edit_disabled','disable','archive') THEN
  IF (action='edit_disabled' AND NOT public.catalog_report_keys(payload,ARRAY['id','expected_revision','schedule','timezone'])) OR
   (action<>'edit_disabled' AND NOT public.catalog_report_keys(payload,ARRAY['id','expected_revision'])) THEN RAISE EXCEPTION 'Invalid mutation keys' USING ERRCODE='22023'; END IF;
  task_id:=public.catalog_report_uuid(payload->'id');
  IF jsonb_typeof(payload->'expected_revision') IS DISTINCT FROM 'number' OR payload->>'expected_revision' !~ '^[1-9][0-9]{0,9}$' OR (payload->>'expected_revision')::numeric>2147483647 THEN RAISE EXCEPTION 'Invalid revision' USING ERRCODE='22023'; END IF;
  expected:=(payload->>'expected_revision')::integer;
  IF action='edit_disabled' THEN PERFORM public.catalog_report_validate_schedule(payload->'schedule',payload->'timezone'); END IF;
 ELSE RAISE EXCEPTION 'Unsupported disabled-only action' USING ERRCODE='22023'; END IF;
 -- Receipt lock first, then create business-key lock, then parents/relations, then schedule.
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('catalog-report-request:'||p_actor::text||':'||p_request::text,0));
 SELECT * INTO receipt FROM public.catalog_report_mutation_receipts WHERE actor_account_id=p_actor AND request_id=p_request;
 is_replay:=FOUND;
 IF is_replay THEN
  SELECT * INTO s FROM public.catalog_report_schedules WHERE id=receipt.schedule_id;
  PERFORM public.catalog_report_match_principal(s,p_actor,p_principal);
  PERFORM public.catalog_report_authorize(p_actor,s.organization_id,s.catalog_id);
  IF receipt.input IS DISTINCT FROM p_command THEN RAISE EXCEPTION 'Changed request input' USING ERRCODE='22023'; END IF;
  RETURN public.catalog_report_response(receipt.schedule_id,receipt.revision,true);
 END IF;
 IF action='create' THEN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('catalog-report-scope:'||jsonb_build_array(p_actor,org_id,selected_catalog)::text,0));
  PERFORM public.catalog_report_authorize(p_actor,org_id,selected_catalog);
  IF EXISTS(SELECT 1 FROM public.catalog_report_schedules existing WHERE existing.effective_account_id=p_actor AND existing.organization_id IS NOT DISTINCT FROM org_id AND existing.catalog_id=selected_catalog AND existing.archived_at IS NULL) THEN
   RAISE EXCEPTION 'Catalog schedule already exists' USING ERRCODE='40001'; END IF;
  INSERT INTO public.catalog_report_schedules(actor_account_id,effective_account_id,organization_id,catalog_id,recipient_account_id,principal_mechanism,api_key_id,privy_app_id,privy_issuer,privy_subject,schedule,timezone)
  VALUES(p_actor,p_actor,org_id,selected_catalog,p_actor,p_principal->>'mechanism',(p_principal->>'key_id')::uuid,p_principal->>'app_id',p_principal->>'issuer',p_principal->>'subject',payload->>'schedule',payload->>'timezone') RETURNING * INTO s;
 ELSE
  SELECT * INTO s FROM public.catalog_report_schedules WHERE id=task_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Catalog schedule unavailable' USING ERRCODE='42501'; END IF;
  PERFORM public.catalog_report_match_principal(s,p_actor,p_principal);
  PERFORM public.catalog_report_authorize(p_actor,s.organization_id,s.catalog_id);
  SELECT * INTO s FROM public.catalog_report_schedules WHERE id=task_id FOR UPDATE;
  IF s.revision<>expected OR s.archived_at IS NOT NULL OR s.enabled THEN RAISE EXCEPTION 'Disabled schedule revision conflict' USING ERRCODE='40001'; END IF;
  IF s.revision=2147483647 THEN RAISE EXCEPTION 'Revision exhausted' USING ERRCODE='22003'; END IF;
  UPDATE public.catalog_report_schedules SET revision=revision+1,
   schedule=CASE WHEN action='edit_disabled' THEN payload->>'schedule' ELSE schedule END,
   timezone=CASE WHEN action='edit_disabled' THEN payload->>'timezone' ELSE timezone END,
   archived_at=CASE WHEN action='archive' THEN clock_timestamp() ELSE NULL END,updated_at=clock_timestamp() WHERE id=task_id RETURNING * INTO s;
 END IF;
 INSERT INTO public.catalog_report_schedule_revisions(schedule_id,revision,changed_by_account_id,operation,schedule,timezone,enabled,archived_at)
 VALUES(s.id,s.revision,p_actor,action,s.schedule,s.timezone,false,s.archived_at);
 INSERT INTO public.catalog_report_mutation_receipts(actor_account_id,request_id,schedule_id,revision,operation,input) VALUES(p_actor,p_request,s.id,s.revision,action,p_command);
 RETURN public.catalog_report_response(s.id,s.revision,false);
END $$;
-- All functions, including helpers, are non-public. Only two management entry points.
ALTER FUNCTION public.catalog_report_immutable_guard() OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_keys(jsonb,text[]) OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_uuid(jsonb) OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_validate_principal(jsonb) OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_validate_schedule(jsonb,jsonb) OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_authorize(uuid,uuid,uuid) OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_match_principal(public.catalog_report_schedules,uuid,jsonb) OWNER TO catalog_report_owner;
ALTER FUNCTION public.catalog_report_response(uuid,integer,boolean) OWNER TO catalog_report_owner;
ALTER FUNCTION public.read_catalog_report_schedule(uuid,jsonb,uuid) OWNER TO catalog_report_owner;
ALTER FUNCTION public.mutate_catalog_report_schedule(uuid,jsonb,uuid,jsonb) OWNER TO catalog_report_owner;
REVOKE ALL ON FUNCTION public.catalog_report_immutable_guard(), public.catalog_report_keys(jsonb,text[]),public.catalog_report_uuid(jsonb),public.catalog_report_validate_principal(jsonb),public.catalog_report_validate_schedule(jsonb,jsonb),public.catalog_report_authorize(uuid,uuid,uuid),public.catalog_report_match_principal(public.catalog_report_schedules,uuid,jsonb),public.catalog_report_response(uuid,integer,boolean),public.read_catalog_report_schedule(uuid,jsonb,uuid),public.mutate_catalog_report_schedule(uuid,jsonb,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.read_catalog_report_schedule(uuid,jsonb,uuid),public.mutate_catalog_report_schedule(uuid,jsonb,uuid,jsonb) TO service_role;
COMMIT;
