-- OFFLINE PROPOSAL ONLY. Extends the disabled 636 proposal; not a migration.
-- Source authorization intentionally fails closed until an owning adapter exists.
BEGIN;
SET LOCAL ROLE recoup_chat_fence_owner;
CREATE TABLE chat_fence.working_surfaces (
 chat_id text NOT NULL REFERENCES chat_fence.state(chat_id),
 message_id text PRIMARY KEY,
 workspace_id uuid NOT NULL,
 surface_id text NOT NULL,
 surface_revision bigint NOT NULL CHECK(surface_revision BETWEEN 1 AND 9007199254740991),
 source_digest text NOT NULL,
 authority_binding jsonb NOT NULL,
 revision bigint NOT NULL CHECK(revision BETWEEN 1 AND 9007199254740991),
 deleted boolean NOT NULL DEFAULT false,
 work jsonb,
 UNIQUE(chat_id,surface_id),
 CHECK ((deleted AND work IS NULL) OR (NOT deleted AND jsonb_typeof(work)='object'))
);
CREATE TABLE chat_fence.working_surface_commands (
 chat_id text NOT NULL REFERENCES chat_fence.state(chat_id),
 request_id uuid NOT NULL,
 message_id text NOT NULL,
 command_digest text NOT NULL,
 receipt jsonb NOT NULL,
 PRIMARY KEY(chat_id,request_id)
);
-- Current state + digest-bound mutation receipts, not revision history. Do not
-- retain old draft payloads in receipt rows after delete. Digests are DB-local.
CREATE FUNCTION chat_fence.authorize_working_surface(p_account uuid,p_workspace uuid,p_binding jsonb)
RETURNS void LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
 RAISE EXCEPTION 'working surface source authority adapter unavailable' USING ERRCODE='0A000';
END $$;

CREATE FUNCTION chat_fence.surface_part(p_message jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE result jsonb; n integer;
BEGIN
 IF jsonb_typeof(p_message->'parts') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION 'full assistant message required' USING ERRCODE='22023'; END IF;
 SELECT count(*), jsonb_agg(x) INTO n,result FROM jsonb_array_elements(p_message->'parts') x
 WHERE x->>'type'='data-intelligent-ui-snapshot';
 IF n<>1 THEN RAISE EXCEPTION 'one full source snapshot required' USING ERRCODE='22023'; END IF;
 result:=result->0;
 IF result->'data'->>'schemaVersion' IS DISTINCT FROM '1'
 OR result->>'id' IS DISTINCT FROM result->'data'->>'id'
 OR jsonb_typeof(result->'data'->'revision') IS DISTINCT FROM 'number'
 OR (result->'data'->>'revision') !~ '^[1-9][0-9]*$'
 OR (result->'data'->>'revision')::numeric>9007199254740991
 OR octet_length(result::text)>262144 THEN
  RAISE EXCEPTION 'invalid source snapshot envelope' USING ERRCODE='22023'; END IF;
 RETURN result;
END $$;

CREATE FUNCTION chat_fence.working_surface_command(p_chat text,p_account uuid,p_action text,p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sid text; s chat_fence.state; w chat_fence.working_surfaces; prior chat_fence.working_surface_commands;
 msg public.chat_messages; source jsonb; command jsonb; result jsonb; request uuid; expected bigint; workspace uuid;
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN
  RAISE EXCEPTION 'READ COMMITTED required' USING ERRCODE='0A000'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('create','save','delete','read','head','reconcile')
 OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR octet_length(p::text)>131072 THEN
  RAISE EXCEPTION 'invalid working command' USING ERRCODE='22023'; END IF;
 -- Matching 636 order. Source authority locks are acquired only after chat/state;
 -- its adapter must not acquire these locks again in the reverse order.
 SELECT session_id INTO sid FROM public.chats WHERE id=p_chat;
 PERFORM 1 FROM public.sessions WHERE id=sid AND account_id=p_account FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat ownership denied' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.chats WHERE id=p_chat AND session_id=sid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat changed' USING ERRCODE='40001'; END IF;
 SELECT * INTO s FROM chat_fence.state WHERE chat_id=p_chat FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'fence prerequisite unavailable' USING ERRCODE='55000'; END IF;
 IF p_action='reconcile' THEN
  IF p - 'request_id'<>'{}'::jsonb THEN RAISE EXCEPTION 'unknown fields' USING ERRCODE='22023'; END IF;
  SELECT * INTO prior FROM chat_fence.working_surface_commands WHERE chat_id=p_chat AND request_id=(p->>'request_id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'receipt not found; not dispatch permission' USING ERRCODE='P0002'; END IF;
  SELECT * INTO w FROM chat_fence.working_surfaces WHERE message_id=prior.message_id AND chat_id=p_chat;
  PERFORM chat_fence.authorize_working_surface(p_account,w.workspace_id,jsonb_build_object('binding',w.authority_binding,'work',w.work,'purpose',CASE WHEN prior.receipt->>'deleted'='true' THEN 'delete' ELSE 'read' END));
  RETURN prior.receipt;
 END IF;
 IF jsonb_typeof(p->'message_id') IS DISTINCT FROM 'string' OR octet_length(p->>'message_id') NOT BETWEEN 1 AND 128 THEN
  RAISE EXCEPTION 'message identity required' USING ERRCODE='22023'; END IF;
 SELECT * INTO w FROM chat_fence.working_surfaces WHERE message_id=p->>'message_id' AND chat_id=p_chat FOR UPDATE;
 IF p_action IN ('read','head') THEN
  IF p-ARRAY['message_id','revision']<>'{}'::jsonb OR (p_action='head' AND p ? 'revision') THEN RAISE EXCEPTION 'unknown fields' USING ERRCODE='22023'; END IF;
  IF w.message_id IS NULL THEN RAISE EXCEPTION 'surface unavailable' USING ERRCODE='P0002'; END IF;
  PERFORM chat_fence.authorize_working_surface(p_account,w.workspace_id,jsonb_build_object('binding',w.authority_binding,'work',w.work,'purpose',CASE WHEN p_action='delete' THEN 'delete' ELSE 'read' END));
  IF w.deleted THEN RAISE EXCEPTION 'surface deleted' USING ERRCODE='P0002'; END IF;
  IF p_action='read' AND p->'revision' IS DISTINCT FROM to_jsonb(w.revision) THEN RAISE EXCEPTION 'stale working revision' USING ERRCODE='40001'; END IF;
  RETURN jsonb_build_object('message_id',w.message_id,'surface_id',w.surface_id,'surface_revision',w.surface_revision,'revision',w.revision,'work',w.work);
 END IF;
 IF p-ARRAY['message_id','request_id','expected_revision','workspace_id','surface_id','surface_revision','authority_binding','work']<>'{}'::jsonb
 OR (p_action<>'create' AND p ?| ARRAY['workspace_id','surface_id','surface_revision','authority_binding'])
 OR (p_action='delete' AND p ? 'work')
 OR jsonb_typeof(p->'expected_revision') IS DISTINCT FROM 'number'
 OR (p->>'expected_revision') !~ '^(0|[1-9][0-9]*)$'
 OR (p->>'expected_revision')::numeric>9007199254740990 THEN
  RAISE EXCEPTION 'invalid command fields or revision' USING ERRCODE='22023'; END IF;
 request:=(p->>'request_id')::uuid; expected:=(p->>'expected_revision')::bigint;
 IF request IS NULL THEN RAISE EXCEPTION 'request identity required' USING ERRCODE='22023'; END IF;
 command:=jsonb_build_object('action',p_action,'payload',p);
 IF w.message_id IS NOT NULL THEN
  PERFORM chat_fence.authorize_working_surface(p_account,w.workspace_id,jsonb_build_object('binding',w.authority_binding,'work',w.work,'purpose',CASE WHEN p_action='delete' THEN 'delete' ELSE 'read' END));
 END IF;
 SELECT * INTO prior FROM chat_fence.working_surface_commands WHERE chat_id=p_chat AND request_id=request;
 IF prior.request_id IS NOT NULL THEN
  IF prior.command_digest<>encode(sha256(convert_to(command::text,'UTF8')),'hex') THEN RAISE EXCEPTION 'request reused with different command' USING ERRCODE='22023'; END IF;
  IF w.message_id IS NULL THEN RAISE EXCEPTION 'receipt binding missing' USING ERRCODE='55000'; END IF;
  RETURN prior.receipt;
 END IF;
 -- First scope is quiescent-only. This is not a claim that null legacy slot is a
 -- drain barrier: enabled fence + idle state prevents all old bound writes.
 IF s.phase<>'idle' THEN RAISE EXCEPTION 'chat busy' USING ERRCODE='40001'; END IF;
 IF p_action<>'delete' THEN
  IF jsonb_typeof(p->'work') IS DISTINCT FROM 'object' OR octet_length((p->'work')::text)>65536
   OR (p->'work')-ARRAY['recipe','displayName','filters','selection']<>'{}'::jsonb
   OR jsonb_typeof(p->'work'->'displayName') IS DISTINCT FROM 'string'
   OR length(p->'work'->>'displayName') NOT BETWEEN 1 AND 160
   OR jsonb_typeof(p->'work'->'recipe') IS DISTINCT FROM 'object'
   OR jsonb_typeof(p->'work'->'filters') IS DISTINCT FROM 'object'
   OR jsonb_typeof(p->'work'->'selection') IS DISTINCT FROM 'array'
   THEN RAISE EXCEPTION 'invalid bounded working state' USING ERRCODE='22023'; END IF;
  IF jsonb_array_length(p->'work'->'selection')>8 THEN RAISE EXCEPTION 'selection bound' USING ERRCODE='22023'; END IF;
  -- API must strictly validate the declared recipe and ObjectRefs; source adapter
  -- must independently bind their authorized identities before accepting a write.
 END IF;
 IF p_action='create' THEN
  IF expected<>0 OR w.message_id IS NOT NULL OR EXISTS(SELECT 1 FROM chat_fence.tombstones WHERE message_id=p->>'message_id') THEN
   RAISE EXCEPTION 'surface already exists or deleted' USING ERRCODE='40001'; END IF;
  SELECT * INTO msg FROM public.chat_messages WHERE id=p->>'message_id' AND chat_id=p_chat FOR UPDATE;
  IF NOT FOUND OR msg.role<>'assistant' THEN RAISE EXCEPTION 'assistant anchor missing' USING ERRCODE='P0002'; END IF;
  source:=chat_fence.surface_part(msg.parts); workspace:=(p->>'workspace_id')::uuid;
  IF workspace IS NULL OR source->'data'->'context'->>'workspaceId' IS DISTINCT FROM workspace::text
   OR source->'data'->>'id' IS DISTINCT FROM p->>'surface_id'
   OR source->'data'->'revision' IS DISTINCT FROM p->'surface_revision'
   OR jsonb_typeof(p->'authority_binding') IS DISTINCT FROM 'object' THEN
   RAISE EXCEPTION 'source scope mismatch' USING ERRCODE='22023'; END IF;
  -- Adapter must validate binding against the actual source + proposed selection.
  PERFORM chat_fence.authorize_working_surface(p_account,workspace,jsonb_build_object('binding',p->'authority_binding','source',source,'work',p->'work','purpose','create'));
  INSERT INTO chat_fence.working_surfaces VALUES(p_chat,msg.id,workspace,p->>'surface_id',(p->>'surface_revision')::bigint,
   encode(sha256(convert_to(source::text,'UTF8')),'hex'),p->'authority_binding',1,false,p->'work') RETURNING * INTO w;
 ELSE
  IF w.message_id IS NULL OR w.deleted OR w.revision<>expected THEN RAISE EXCEPTION 'stale or deleted surface' USING ERRCODE='40001'; END IF;
  IF p_action='save' THEN
   PERFORM chat_fence.authorize_working_surface(p_account,w.workspace_id,jsonb_build_object('binding',w.authority_binding,'work',p->'work','purpose','save'));
  END IF;
  UPDATE chat_fence.working_surfaces SET revision=revision+1,deleted=p_action='delete',work=CASE WHEN p_action='delete' THEN NULL ELSE p->'work' END
   WHERE message_id=w.message_id RETURNING * INTO w;
 END IF;
 result:=jsonb_build_object('request_id',request,'message_id',w.message_id,'surface_id',w.surface_id,'surface_revision',w.surface_revision,'revision',w.revision,'deleted',w.deleted);
 INSERT INTO chat_fence.working_surface_commands VALUES(p_chat,request,w.message_id,encode(sha256(convert_to(command::text,'UTF8')),'hex'),result);
 RETURN result;
END $$;

-- Internal 636 writes are trusted to mutate messages, not saved source snapshots.
-- Direct service writes are already rejected by its existing invoker guard.
CREATE FUNCTION chat_fence.guard_working_surface_source() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE w chat_fence.working_surfaces; source jsonb;
BEGIN
 IF current_user<>'recoup_chat_fence_owner' THEN
  -- Existing 636 BEFORE guard handles legacy writers. Do not expose private state.
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
 END IF;
 SELECT * INTO w FROM chat_fence.working_surfaces WHERE message_id=OLD.id;
 IF w.message_id IS NULL THEN IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF; END IF;
 IF TG_OP='DELETE' THEN
  IF NOT w.deleted THEN
   IF w.revision=9007199254740991 THEN RAISE EXCEPTION 'revision exhausted' USING ERRCODE='22023'; END IF;
   UPDATE chat_fence.working_surfaces SET deleted=true,work=NULL,revision=revision+1 WHERE message_id=OLD.id;
  END IF;
  RETURN OLD;
 END IF;
 source:=chat_fence.surface_part(NEW.parts);
 IF encode(sha256(convert_to(source::text,'UTF8')),'hex')<>w.source_digest THEN
  RAISE EXCEPTION 'saved source snapshot is immutable' USING ERRCODE='40001'; END IF;
 RETURN NEW;
END $$;
RESET ROLE;
CREATE TRIGGER working_surface_source BEFORE UPDATE OR DELETE ON public.chat_messages
 FOR EACH ROW EXECUTE FUNCTION chat_fence.guard_working_surface_source();
REVOKE ALL ON ALL TABLES IN SCHEMA chat_fence FROM anon,authenticated;
REVOKE ALL ON FUNCTION chat_fence.working_surface_command(text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION chat_fence.authorize_working_surface(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION chat_fence.surface_part(jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION chat_fence.guard_working_surface_source() FROM PUBLIC,anon,authenticated,service_role;
-- No EXECUTE grant, no enrollment. Harness explicitly grants on disposable data.
COMMIT;
