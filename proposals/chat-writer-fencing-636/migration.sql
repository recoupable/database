-- DRAFT PROPOSAL ONLY. Not in supabase/migrations; never automatically applied.
-- Requires a migration administrator able to create/own roles and policies.
BEGIN;
CREATE ROLE recoup_chat_fence_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
CREATE SCHEMA chat_fence AUTHORIZATION recoup_chat_fence_owner;
REVOKE ALL ON SCHEMA chat_fence FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO recoup_chat_fence_owner;
GRANT SELECT ON public.sessions, public.chats, public.chat_messages TO recoup_chat_fence_owner;
GRANT REFERENCES ON public.chats, public.chat_messages TO recoup_chat_fence_owner;
GRANT UPDATE (id) ON public.sessions TO recoup_chat_fence_owner;
GRANT UPDATE (active_stream_id) ON public.chats TO recoup_chat_fence_owner;
GRANT INSERT, UPDATE, DELETE ON public.chat_messages TO recoup_chat_fence_owner;
CREATE POLICY chat_fence_sessions ON public.sessions FOR ALL TO recoup_chat_fence_owner USING (true) WITH CHECK (true);
CREATE POLICY chat_fence_chats ON public.chats FOR ALL TO recoup_chat_fence_owner USING (true) WITH CHECK (true);
CREATE POLICY chat_fence_messages ON public.chat_messages FOR ALL TO recoup_chat_fence_owner USING (true) WITH CHECK (true);
SET LOCAL ROLE recoup_chat_fence_owner;
CREATE TABLE chat_fence.state (
 chat_id text PRIMARY KEY REFERENCES public.chats(id),
 epoch bigint NOT NULL DEFAULT 0 CHECK (epoch >= 0 AND epoch <= 9007199254740991),
 owner uuid, phase text NOT NULL DEFAULT 'idle' CHECK (phase IN ('idle','pending','running')),
 run_id text,
 CHECK ((phase='idle' AND owner IS NULL AND run_id IS NULL) OR
        (phase='pending' AND owner IS NOT NULL AND run_id IS NULL) OR
        (phase='running' AND owner IS NOT NULL AND run_id IS NOT NULL))
);
CREATE TABLE chat_fence.turns (
 chat_id text NOT NULL REFERENCES chat_fence.state(chat_id), request_id uuid NOT NULL,
 input_hash text NOT NULL, expected_epoch bigint NOT NULL, epoch bigint NOT NULL,
 admission_envelope jsonb NOT NULL, execution_snapshot jsonb NOT NULL,
 admission_canonical text NOT NULL, execution_canonical text NOT NULL,
 dispatch_attempt_id uuid, bound_run_id text, closed boolean NOT NULL DEFAULT false, PRIMARY KEY(chat_id,request_id)
);
CREATE TABLE chat_fence.message_epochs (
 message_id text PRIMARY KEY REFERENCES public.chat_messages(id) ON DELETE CASCADE,
 chat_id text NOT NULL REFERENCES chat_fence.state(chat_id), epoch bigint NOT NULL
);
CREATE TABLE chat_fence.tombstones (
 message_id text PRIMARY KEY, chat_id text NOT NULL REFERENCES chat_fence.state(chat_id), deleted_epoch bigint NOT NULL
);
CREATE TABLE chat_fence.deletions (
 chat_id text NOT NULL REFERENCES chat_fence.state(chat_id), request_id uuid NOT NULL,
 anchor_id text NOT NULL, expected_epoch bigint NOT NULL, receipt jsonb NOT NULL,
 edit_material jsonb CHECK (edit_material IS NULL OR jsonb_typeof(edit_material)='object'),
 PRIMARY KEY(chat_id,request_id)
);
RESET ROLE;

-- Trigger functions run as INVOKER: current_user must be the dedicated RPC owner,
-- not a caller-controlled GUC. The service role has no membership in this role.
-- Guards need state visibility without making state mutable by service clients.
GRANT USAGE ON SCHEMA chat_fence TO service_role;
GRANT SELECT ON chat_fence.state, chat_fence.tombstones TO service_role;
CREATE FUNCTION public.guard_chat_fence_message() RETURNS trigger LANGUAGE plpgsql
SET search_path = '' AS $$
DECLARE c text; enabled boolean;
BEGIN
 IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'chat fence requires READ COMMITTED' USING ERRCODE='0A000';
 END IF;
 IF TG_OP='TRUNCATE' THEN
  IF EXISTS(SELECT 1 FROM chat_fence.state) THEN RAISE EXCEPTION 'fenced truncate denied' USING ERRCODE='42501'; END IF;
  RETURN NULL;
 END IF;
 IF TG_OP<>'DELETE' AND EXISTS(SELECT 1 FROM chat_fence.tombstones WHERE message_id=NEW.id) THEN
  RAISE EXCEPTION 'deleted identity cannot be reused' USING ERRCODE='40001';
 END IF;
 c := CASE WHEN TG_OP='DELETE' THEN OLD.chat_id ELSE NEW.chat_id END;
 -- All legacy message writes serialize with activation too, even before enabled.
 IF TG_OP='UPDATE' THEN
  PERFORM 1 FROM public.chats WHERE id IN (OLD.chat_id,NEW.chat_id) ORDER BY id FOR UPDATE;
 ELSE
  PERFORM 1 FROM public.chats WHERE id=c FOR UPDATE;
 END IF;
 enabled := EXISTS(SELECT 1 FROM chat_fence.state WHERE chat_id=c);
 IF TG_OP='UPDATE' AND OLD.chat_id IS DISTINCT FROM NEW.chat_id THEN
  IF enabled OR EXISTS(SELECT 1 FROM chat_fence.state WHERE chat_id=OLD.chat_id) THEN
   RAISE EXCEPTION 'message identity move denied' USING ERRCODE='42501';
  END IF;
 END IF;
 IF enabled AND current_user <> 'recoup_chat_fence_owner' THEN
  RAISE EXCEPTION 'fenced message requires RPC' USING ERRCODE='42501';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
-- READ COMMITTED AFTER recheck closes the cross-chat unique-index wait:
-- a BEFORE check can precede an uncommitted tombstone, then wait for its DELETE.
CREATE FUNCTION public.guard_chat_fence_identity_after() RETURNS trigger LANGUAGE plpgsql
SET search_path = '' AS $$
BEGIN
 IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'chat fence requires READ COMMITTED' USING ERRCODE='0A000';
 END IF;
 IF EXISTS(SELECT 1 FROM chat_fence.tombstones WHERE message_id=NEW.id) THEN
  RAISE EXCEPTION 'deleted identity cannot be reused after write' USING ERRCODE='40001';
 END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION public.guard_chat_fence_parent() RETURNS trigger LANGUAGE plpgsql
SET search_path = '' AS $$
BEGIN
 IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'chat fence requires READ COMMITTED' USING ERRCODE='0A000';
 END IF;
 IF TG_OP='TRUNCATE' THEN
  IF EXISTS(SELECT 1 FROM chat_fence.state) THEN RAISE EXCEPTION 'fenced truncate denied' USING ERRCODE='42501'; END IF;
  RETURN NULL;
 END IF;
 IF TG_TABLE_NAME='sessions' THEN
  IF (TG_OP='DELETE' OR NEW.account_id IS DISTINCT FROM OLD.account_id OR NEW.id IS DISTINCT FROM OLD.id)
    AND EXISTS(SELECT 1 FROM public.chats c JOIN chat_fence.state s ON s.chat_id=c.id WHERE c.session_id=OLD.id) THEN
   RAISE EXCEPTION 'fenced session ownership/cascade denied' USING ERRCODE='42501';
  END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM chat_fence.state WHERE chat_id=OLD.id) THEN
   IF TG_OP='DELETE' OR NEW.id IS DISTINCT FROM OLD.id OR NEW.session_id IS DISTINCT FROM OLD.session_id THEN
    RAISE EXCEPTION 'fenced chat identity/cascade denied' USING ERRCODE='42501';
   END IF;
   IF NEW.active_stream_id IS DISTINCT FROM OLD.active_stream_id AND current_user <> 'recoup_chat_fence_owner' THEN
    RAISE EXCEPTION 'fenced slot requires RPC' USING ERRCODE='42501';
   END IF;
  END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER chat_fence_message BEFORE INSERT OR UPDATE OR DELETE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION public.guard_chat_fence_message();
CREATE TRIGGER chat_fence_identity_after AFTER INSERT OR UPDATE ON public.chat_messages FOR EACH ROW EXECUTE FUNCTION public.guard_chat_fence_identity_after();
CREATE TRIGGER chat_fence_message_truncate BEFORE TRUNCATE ON public.chat_messages FOR EACH STATEMENT EXECUTE FUNCTION public.guard_chat_fence_message();
CREATE TRIGGER chat_fence_chat BEFORE UPDATE OR DELETE ON public.chats FOR EACH ROW EXECUTE FUNCTION public.guard_chat_fence_parent();
CREATE TRIGGER chat_fence_chat_truncate BEFORE TRUNCATE ON public.chats FOR EACH STATEMENT EXECUTE FUNCTION public.guard_chat_fence_parent();
CREATE TRIGGER chat_fence_session BEFORE UPDATE OR DELETE ON public.sessions FOR EACH ROW EXECUTE FUNCTION public.guard_chat_fence_parent();
CREATE TRIGGER chat_fence_session_truncate BEFORE TRUNCATE ON public.sessions FOR EACH STATEMENT EXECUTE FUNCTION public.guard_chat_fence_parent();

-- No service/browser EXECUTE grant: operator-only activation after the external
-- deployment/drain barrier. Null slot is necessary, NOT proof of that barrier.
CREATE FUNCTION public.enable_chat_fence(p_chat text, p_account uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sid text;
BEGIN
 IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'chat fence requires READ COMMITTED' USING ERRCODE='0A000';
 END IF;
 SELECT session_id INTO sid FROM public.chats WHERE id=p_chat;
 PERFORM 1 FROM public.sessions WHERE id=sid AND account_id=p_account FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat ownership denied' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.chats WHERE id=p_chat AND session_id=sid AND active_stream_id IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat occupied or changed' USING ERRCODE='40001'; END IF;
 INSERT INTO chat_fence.state(chat_id) VALUES(p_chat) ON CONFLICT DO NOTHING;
END $$;
ALTER FUNCTION public.enable_chat_fence(text,uuid) OWNER TO recoup_chat_fence_owner;
REVOKE ALL ON FUNCTION public.enable_chat_fence(text,uuid) FROM PUBLIC,anon,authenticated,service_role;

-- Trusted service API supplies the already-authorized effective account. This
-- rechecks session ownership; it does not recreate org/admin authorization in SQL.
CREATE FUNCTION public.chat_fence_command(p_chat text, p_account uuid, p_action text, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sid text; s chat_fence.state; t chat_fence.turns; d chat_fence.deletions;
 m public.chat_messages; a public.chat_messages; receipt jsonb; n bigint;
 request uuid; expected bigint; token uuid; generation bigint; mode text; outcome text; attempt uuid;
 material jsonb; capture jsonb; admission jsonb; envelope jsonb; execution jsonb; intent jsonb;
 witness jsonb; messages jsonb; replacement jsonb; actual_history jsonb; prefix_messages jsonb;
 item jsonb; part jsonb; shape record; node record; replacement_id text; admission_request uuid;
 anchor_count integer; parts_count bigint; history_bytes bigint;
BEGIN
 IF p_action IS NULL OR p_action NOT IN ('state','admission_snapshot','admit','claim_dispatch','close_unattempted','bind','write','update_parts','release','delete','delete_edit','deletion_snapshot') OR p IS NULL OR jsonb_typeof(p)<>'object' THEN
  RAISE EXCEPTION 'unsupported command or payload' USING ERRCODE='22023';
 END IF;
 IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'chat fence requires READ COMMITTED' USING ERRCODE='0A000';
 END IF;
 SELECT session_id INTO sid FROM public.chats WHERE id=p_chat;
 PERFORM 1 FROM public.sessions WHERE id=sid AND account_id=p_account FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat ownership denied' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.chats WHERE id=p_chat AND session_id=sid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat changed' USING ERRCODE='40001'; END IF;
 SELECT * INTO s FROM chat_fence.state WHERE chat_id=p_chat FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'chat fence not enabled' USING ERRCODE='55000'; END IF;
 IF p_action='state' THEN RETURN to_jsonb(s); END IF;
 IF p_action='admission_snapshot' THEN
  request := (p->>'request_id')::uuid;
  IF request IS NULL THEN RAISE EXCEPTION 'missing retry identity' USING ERRCODE='22023'; END IF;
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=request;
  IF NOT FOUND THEN RAISE EXCEPTION 'admission snapshot missing' USING ERRCODE='P0002'; END IF;
  RETURN jsonb_build_object('receipt',to_jsonb(t)-ARRAY['admission_envelope','execution_snapshot','admission_canonical','execution_canonical','dispatch_attempt_id'],
   'admission_envelope',t.admission_envelope,'execution_snapshot',t.execution_snapshot,
   'admission_canonical',t.admission_canonical,'execution_canonical',t.execution_canonical,
   'dispatch',jsonb_build_object('status',CASE WHEN t.dispatch_attempt_id IS NULL THEN 'never_attempted' ELSE 'claimed' END,'attempt_id',t.dispatch_attempt_id));
 END IF;
 -- New edit commands are strict; legacy parsing/limits remain unchanged.
 IF p_action IN ('delete_edit','deletion_snapshot') THEN
  IF (p_action='delete_edit' AND (NOT (p ?& ARRAY['request_id','expected_epoch','anchor_id','edit_material']) OR p-ARRAY['request_id','expected_epoch','anchor_id','edit_material']<>'{}'::jsonb))
    OR (p_action='deletion_snapshot' AND (NOT (p ? 'request_id') OR p- 'request_id'<>'{}'::jsonb))
    OR jsonb_typeof(p->'request_id') IS DISTINCT FROM 'string'
    OR (p->>'request_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
   RAISE EXCEPTION 'invalid deletion command' USING ERRCODE='22023';
  END IF;
  request := (p->>'request_id')::uuid;
  IF p_action='deletion_snapshot' THEN
   SELECT * INTO d FROM chat_fence.deletions WHERE chat_id=p_chat AND request_id=request;
   IF NOT FOUND THEN RAISE EXCEPTION 'deletion snapshot missing' USING ERRCODE='P0002'; END IF;
   RETURN jsonb_build_object('receipt',d.receipt,'edit_material',d.edit_material);
  END IF;
  IF jsonb_typeof(p->'expected_epoch') IS DISTINCT FROM 'number' OR (p->>'expected_epoch') !~ '^(0|[1-9][0-9]*)$'
    OR (p->>'expected_epoch')::numeric>9007199254740989
    OR jsonb_typeof(p->'anchor_id') IS DISTINCT FROM 'string' OR octet_length(p->>'anchor_id') NOT BETWEEN 1 AND 512 THEN
   RAISE EXCEPTION 'invalid edit identity or capacity' USING ERRCODE='22023';
  END IF;
  IF octet_length(p_chat) NOT BETWEEN 1 AND 512 OR octet_length(sid) NOT BETWEEN 1 AND 512 THEN RAISE EXCEPTION 'edit scope identifier limit' USING ERRCODE='22023'; END IF;
  expected := (p->>'expected_epoch')::bigint;
  material:=p->'edit_material'; capture:=material->'capture'; admission:=capture->'admission'->'payload';
  envelope:=admission->'admission_envelope'; execution:=admission->'execution_snapshot'; witness:=material->'history_witness';
  -- Caps precede traversal, hash work, history reads and all destructive work.
  IF jsonb_typeof(material) IS DISTINCT FROM 'object' OR octet_length(material::text)>8388608
    OR jsonb_typeof(witness) IS DISTINCT FROM 'array' OR octet_length(witness::text)>4194304
    OR jsonb_typeof(envelope->'messages') IS DISTINCT FROM 'array'
    OR jsonb_typeof(material->'user_intent_canonical') IS DISTINCT FROM 'string'
    OR octet_length(material->>'user_intent_canonical')>1048576
    OR jsonb_typeof(admission->'admission_canonical') IS DISTINCT FROM 'string' OR octet_length(admission->>'admission_canonical')>1048576
    OR jsonb_typeof(admission->'execution_canonical') IS DISTINCT FROM 'string' OR octet_length(admission->>'execution_canonical')>1048576 THEN
   RAISE EXCEPTION 'invalid or oversized edit material' USING ERRCODE='22023';
  END IF;
  messages:=envelope->'messages';
  IF jsonb_array_length(witness)>1000 OR jsonb_array_length(messages) NOT BETWEEN 1 AND 1000 THEN
   RAISE EXCEPTION 'edit message limit' USING ERRCODE='22023'; END IF;
  intent:=(material->>'user_intent_canonical')::jsonb;
  FOR shape IN SELECT * FROM (VALUES
   (material,ARRAY['capture','user_intent_canonical','history_witness']),
   (capture,ARRAY['deletion','turn','admission']),
   (capture->'deletion',ARRAY['chatId','effectiveAccount','requestId','expectedEpoch','anchorId']),
   (capture->'turn',ARRAY['kind']), (capture->'admission',ARRAY['action','payload']),
   (admission,ARRAY['request_id','expected_epoch','input_hash','admission_envelope','execution_snapshot','admission_canonical','execution_canonical']),
   (envelope,ARRAY['contractVersion','effectiveAccountId','sessionId','chatId','expectedEpoch','messages','options','executionSnapshot']),
   (envelope->'executionSnapshot',ARRAY['id','digest']),
   (execution,ARRAY['contractVersion','id','requestId','effectiveAccountId','chatId','sessionId','content']),
   (intent,ARRAY['anchor_id','edited_user_message','requested_options'])
  ) AS shapes(value,keys) LOOP
   IF jsonb_typeof(shape.value) IS DISTINCT FROM 'object' OR NOT (shape.value ?& shape.keys) OR shape.value-shape.keys<>'{}'::jsonb THEN
    RAISE EXCEPTION 'invalid edit object shape' USING ERRCODE='22023'; END IF;
  END LOOP;
  -- Depth includes the complete stored material; parse intent separately because it is text.
  FOR node IN WITH RECURSIVE walk(value,depth) AS (
   SELECT value,0 FROM (VALUES (material),(intent)) roots(value) UNION ALL
   SELECT child.value,w.depth+1 FROM walk w CROSS JOIN LATERAL (
    SELECT value FROM jsonb_each(CASE WHEN jsonb_typeof(w.value)='object' THEN w.value ELSE '{}'::jsonb END)
    UNION ALL SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w.value)='array' THEN w.value ELSE '[]'::jsonb END)
   ) child WHERE w.depth<=100
  ) SELECT * FROM walk LOOP
   IF node.depth>100 OR (jsonb_typeof(node.value)='object' AND node.value ? '__proto__') THEN
    RAISE EXCEPTION 'unsupported edit JSON' USING ERRCODE='22023'; END IF;
   IF jsonb_typeof(node.value)='number' AND (node.value::text)::numeric=trunc((node.value::text)::numeric)
     AND abs((node.value::text)::numeric)>9007199254740991 THEN
    RAISE EXCEPTION 'unsafe edit integer' USING ERRCODE='22023'; END IF;
  END LOOP;
  IF capture->'turn'->>'kind' IS DISTINCT FROM 'new' OR capture->'admission'->>'action' IS DISTINCT FROM 'admit'
    OR capture->'deletion'->'chatId' IS DISTINCT FROM to_jsonb(p_chat)
    OR capture->'deletion'->'effectiveAccount' IS DISTINCT FROM to_jsonb(p_account::text)
    OR capture->'deletion'->'requestId' IS DISTINCT FROM to_jsonb(request::text)
    OR capture->'deletion'->'expectedEpoch' IS DISTINCT FROM to_jsonb(expected)
    OR capture->'deletion'->'anchorId' IS DISTINCT FROM p->'anchor_id'
    OR admission->'expected_epoch' IS DISTINCT FROM to_jsonb(expected+1)
    OR jsonb_typeof(admission->'request_id') IS DISTINCT FROM 'string'
    OR (admission->>'request_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
   RAISE EXCEPTION 'edit capture binding mismatch' USING ERRCODE='22023'; END IF;
  admission_request:=(admission->>'request_id')::uuid;
  IF admission_request=request OR jsonb_typeof(admission->'input_hash') IS DISTINCT FROM 'string'
    OR jsonb_typeof(envelope->'executionSnapshot'->'digest') IS DISTINCT FROM 'string'
    OR (admission->>'admission_canonical')::jsonb IS DISTINCT FROM envelope
    OR (admission->>'execution_canonical')::jsonb IS DISTINCT FROM execution
    OR encode(sha256(convert_to(admission->>'admission_canonical','UTF8')),'hex') IS DISTINCT FROM admission->>'input_hash'
    OR encode(sha256(convert_to(admission->>'execution_canonical','UTF8')),'hex') IS DISTINCT FROM envelope->'executionSnapshot'->>'digest'
    OR envelope->>'contractVersion' IS DISTINCT FROM 'chat-admission/v1'
    OR envelope->'effectiveAccountId' IS DISTINCT FROM to_jsonb(p_account::text) OR envelope->'chatId' IS DISTINCT FROM to_jsonb(p_chat)
    OR envelope->'sessionId' IS DISTINCT FROM to_jsonb(sid) OR envelope->'expectedEpoch' IS DISTINCT FROM to_jsonb(expected+1)
    OR execution->>'contractVersion' IS DISTINCT FROM 'chat-execution/v1'
    OR execution->'effectiveAccountId' IS DISTINCT FROM to_jsonb(p_account::text) OR execution->'chatId' IS DISTINCT FROM to_jsonb(p_chat)
    OR execution->'sessionId' IS DISTINCT FROM to_jsonb(sid) OR execution->'requestId' IS DISTINCT FROM to_jsonb(admission_request::text)
    OR jsonb_typeof(execution->'id') IS DISTINCT FROM 'string' OR octet_length(execution->>'id') NOT BETWEEN 1 AND 512
    OR execution->'id' IS DISTINCT FROM envelope->'executionSnapshot'->'id'
    OR jsonb_typeof(execution->'content') IS DISTINCT FROM 'object'
    OR jsonb_typeof(envelope->'options') IS DISTINCT FROM 'object'
    OR envelope->'options' IS DISTINCT FROM execution->'content'->'options' THEN
   RAISE EXCEPTION 'edit snapshot binding mismatch' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(intent->'requested_options') IS DISTINCT FROM 'object'
    OR (intent->'requested_options')-ARRAY['modelId','artistId','interactive','devSurface']<>'{}'::jsonb
    OR intent->'anchor_id' IS DISTINCT FROM p->'anchor_id'
    OR intent->'edited_user_message'->'id' IS DISTINCT FROM p->'anchor_id'
    OR intent->'edited_user_message'->>'role' IS DISTINCT FROM 'user' THEN
   RAISE EXCEPTION 'invalid normalized edit intent' USING ERRCODE='22023'; END IF;
  FOR shape IN SELECT * FROM jsonb_each(intent->'requested_options') LOOP
   IF shape.value IS DISTINCT FROM envelope->'options'->shape.key THEN
    RAISE EXCEPTION 'requested option mismatch' USING ERRCODE='22023'; END IF;
  END LOOP;
  replacement:=messages->(jsonb_array_length(messages)-1); replacement_id:=replacement->>'id';
  IF replacement->>'role' IS DISTINCT FROM 'user' OR (replacement-'id') IS DISTINCT FROM ((intent->'edited_user_message')-'id') THEN
   RAISE EXCEPTION 'edited replacement mismatch' USING ERRCODE='22023'; END IF;
  parts_count:=0; anchor_count:=0; prefix_messages:='[]'::jsonb;
  FOR item IN SELECT value FROM jsonb_array_elements(witness) LOOP
   IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR NOT (item ?& ARRAY['id','role','message']) OR item-ARRAY['id','role','message']<>'{}'::jsonb
     OR item->'id' IS DISTINCT FROM item->'message'->'id' OR item->'role' IS DISTINCT FROM item->'message'->'role' THEN
    RAISE EXCEPTION 'invalid history witness' USING ERRCODE='22023'; END IF;
   IF item->>'id'=p->>'anchor_id' THEN
    anchor_count:=anchor_count+1;
    IF item->>'role'<>'user' THEN RAISE EXCEPTION 'edit anchor must be user' USING ERRCODE='22023'; END IF;
   END IF;
   IF anchor_count=0 THEN prefix_messages:=prefix_messages||jsonb_build_array(item->'message'); END IF;
  END LOOP;
  -- Validate full envelopes and parts before summing them. Prefix is counted only once.
  FOR item IN SELECT value->'message' FROM jsonb_array_elements(witness) UNION ALL SELECT replacement LOOP
   IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR NOT (item ?& ARRAY['id','role','parts']) OR item-ARRAY['id','role','parts','metadata']<>'{}'::jsonb
     OR jsonb_typeof(item->'id') IS DISTINCT FROM 'string' OR octet_length(item->>'id') NOT BETWEEN 1 AND 512
     OR coalesce(item->>'role','') NOT IN ('user','assistant') OR jsonb_typeof(item->'parts') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'invalid full UIMessage' USING ERRCODE='22023'; END IF;
   parts_count:=parts_count+jsonb_array_length(item->'parts');
   IF parts_count>10000 THEN RAISE EXCEPTION 'edit parts limit' USING ERRCODE='22023'; END IF;
   FOR part IN SELECT value FROM jsonb_array_elements(item->'parts') LOOP
    IF jsonb_typeof(part) IS DISTINCT FROM 'object' OR jsonb_typeof(part->'type') IS DISTINCT FROM 'string' OR coalesce(part->>'type','')='' THEN
     RAISE EXCEPTION 'invalid UIMessage part' USING ERRCODE='22023'; END IF;
   END LOOP;
  END LOOP;
  IF anchor_count<>1 OR (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(witness))<>jsonb_array_length(witness) THEN
   RAISE EXCEPTION 'witness needs one unique user anchor' USING ERRCODE='22023'; END IF;
  IF messages IS DISTINCT FROM prefix_messages||jsonb_build_array(replacement) THEN
   RAISE EXCEPTION 'edited history prefix mismatch' USING ERRCODE='22023'; END IF;
  SELECT * INTO d FROM chat_fence.deletions WHERE chat_id=p_chat AND request_id=request;
  IF FOUND THEN
   IF d.edit_material IS NULL OR d.anchor_id IS DISTINCT FROM p->>'anchor_id' OR d.expected_epoch<>expected OR d.edit_material IS DISTINCT FROM material THEN
    RAISE EXCEPTION 'edit retry input conflict' USING ERRCODE='22023'; END IF;
   RETURN d.receipt;
  END IF;
  IF s.phase<>'idle' OR s.epoch<>expected OR EXISTS(SELECT 1 FROM public.chats WHERE id=p_chat AND active_stream_id IS NOT NULL) THEN
   RAISE EXCEPTION 'edit delete conflict' USING ERRCODE='40001'; END IF;
  -- Bound row count AND projected bytes before allocating a history JSON array.
  SELECT count(*),coalesce(sum(octet_length(jsonb_build_object('id',h.id,'role',h.role,'message',h.parts)::text)+2),0)
   INTO n,history_bytes FROM (SELECT id,role,parts FROM public.chat_messages WHERE chat_id=p_chat ORDER BY created_at,id LIMIT 1001) h;
  IF n>1000 OR history_bytes>4194304 THEN RAISE EXCEPTION 'stored history exceeds edit limit' USING ERRCODE='22023'; END IF;
  SELECT count(*),coalesce(jsonb_agg(jsonb_build_object('id',h.id,'role',h.role,'message',h.parts) ORDER BY h.created_at,h.id),'[]'::jsonb)
   INTO n,actual_history FROM (SELECT id,role,parts,created_at FROM public.chat_messages WHERE chat_id=p_chat ORDER BY created_at,id LIMIT 1001) h;
  SELECT * INTO a FROM public.chat_messages WHERE chat_id=p_chat AND id=p->>'anchor_id';
  IF NOT FOUND THEN RAISE EXCEPTION 'anchor missing' USING ERRCODE='P0002'; END IF;
  IF actual_history IS DISTINCT FROM witness THEN RAISE EXCEPTION 'edit history changed' USING ERRCODE='40001'; END IF;
  IF EXISTS(SELECT 1 FROM public.chat_messages WHERE id=replacement_id)
    OR EXISTS(SELECT 1 FROM chat_fence.tombstones WHERE message_id=replacement_id)
    OR EXISTS(SELECT 1 FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=admission_request) THEN
   RAISE EXCEPTION 'edited identity unavailable' USING ERRCODE='40001'; END IF;
  UPDATE chat_fence.state SET epoch=epoch+1 WHERE chat_id=p_chat RETURNING * INTO s;
  INSERT INTO chat_fence.tombstones(message_id,chat_id,deleted_epoch)
   SELECT id,chat_id,s.epoch FROM public.chat_messages WHERE chat_id=p_chat AND (created_at,id)>=(a.created_at,a.id);
  DELETE FROM public.chat_messages WHERE chat_id=p_chat AND (created_at,id)>=(a.created_at,a.id);
  GET DIAGNOSTICS n=ROW_COUNT;
  receipt:=jsonb_build_object('epoch',s.epoch,'deleted',n,'request_id',request);
  INSERT INTO chat_fence.deletions(chat_id,request_id,anchor_id,expected_epoch,receipt,edit_material) VALUES(p_chat,request,a.id,expected,receipt,material);
  RETURN receipt;
 END IF;
 IF p_action IN ('admit','delete') THEN
  request := (p->>'request_id')::uuid; expected := (p->>'expected_epoch')::bigint;
  IF request IS NULL OR expected IS NULL THEN RAISE EXCEPTION 'missing retry identity'; END IF;
 END IF;
 IF p_action='admit' THEN
  IF p->>'input_hash' IS NULL OR (p->>'input_hash') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid input hash'; END IF;
  -- Verify supplied UTF-8 bytes, never PostgreSQL JSONB serialization as canonical.
  IF jsonb_typeof(p->'admission_envelope') IS DISTINCT FROM 'object'
    OR jsonb_typeof(p->'execution_snapshot') IS DISTINCT FROM 'object'
    OR jsonb_typeof(p->'admission_canonical') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p->'execution_canonical') IS DISTINCT FROM 'string' THEN
   RAISE EXCEPTION 'missing admission snapshot material' USING ERRCODE='22023';
  END IF;
  IF (p->>'admission_canonical')::jsonb IS DISTINCT FROM p->'admission_envelope'
    OR (p->>'execution_canonical')::jsonb IS DISTINCT FROM p->'execution_snapshot'
    OR encode(sha256(convert_to(p->>'admission_canonical','UTF8')),'hex') IS DISTINCT FROM p->>'input_hash'
    OR encode(sha256(convert_to(p->>'execution_canonical','UTF8')),'hex') IS DISTINCT FROM p->'admission_envelope'->'executionSnapshot'->>'digest' THEN
   RAISE EXCEPTION 'snapshot bytes or digest mismatch' USING ERRCODE='22023';
  END IF;
  IF p->'admission_envelope'->>'contractVersion' IS DISTINCT FROM 'chat-admission/v1'
    OR p->'admission_envelope'->>'effectiveAccountId' IS DISTINCT FROM p_account::text
    OR p->'admission_envelope'->>'chatId' IS DISTINCT FROM p_chat
    OR p->'admission_envelope'->>'sessionId' IS DISTINCT FROM sid
    OR p->'admission_envelope'->'expectedEpoch' IS DISTINCT FROM to_jsonb(expected)
    OR p->'execution_snapshot'->>'contractVersion' IS DISTINCT FROM 'chat-execution/v1'
    OR p->'execution_snapshot'->>'effectiveAccountId' IS DISTINCT FROM p_account::text
    OR p->'execution_snapshot'->>'chatId' IS DISTINCT FROM p_chat
    OR p->'execution_snapshot'->>'sessionId' IS DISTINCT FROM sid
    OR p->'execution_snapshot'->>'requestId' IS DISTINCT FROM request::text
    OR jsonb_typeof(p->'execution_snapshot'->'id') IS DISTINCT FROM 'string'
    OR coalesce(p->'execution_snapshot'->>'id','')=''
    OR p->'execution_snapshot'->>'id' IS DISTINCT FROM p->'admission_envelope'->'executionSnapshot'->>'id'
    OR jsonb_typeof(p->'execution_snapshot'->'content') IS DISTINCT FROM 'object' THEN
   RAISE EXCEPTION 'snapshot scope or version mismatch' USING ERRCODE='22023';
  END IF;
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=request;
  IF FOUND THEN
   IF t.input_hash<>p->>'input_hash' OR t.expected_epoch<>expected OR t.admission_canonical IS DISTINCT FROM p->>'admission_canonical' OR t.execution_canonical IS DISTINCT FROM p->>'execution_canonical' OR t.admission_envelope IS DISTINCT FROM p->'admission_envelope' OR t.execution_snapshot IS DISTINCT FROM p->'execution_snapshot' THEN RAISE EXCEPTION 'retry input conflict' USING ERRCODE='22023'; END IF;
   RETURN to_jsonb(t)-ARRAY['admission_envelope','execution_snapshot','admission_canonical','execution_canonical','dispatch_attempt_id']; -- Replay never allocates a new owner or authorizes redispatch.
  END IF;
  IF s.phase<>'idle' OR s.epoch<>expected THEN RAISE EXCEPTION 'admission conflict' USING ERRCODE='40001'; END IF;
  UPDATE chat_fence.state SET epoch=epoch+1,owner=request,phase='pending' WHERE chat_id=p_chat RETURNING * INTO s;
  INSERT INTO chat_fence.turns VALUES(p_chat,request,p->>'input_hash',expected,s.epoch,p->'admission_envelope',p->'execution_snapshot',p->>'admission_canonical',p->>'execution_canonical',NULL,NULL,false) RETURNING * INTO t;
  UPDATE public.chats SET active_stream_id='pending-'||request::text WHERE id=p_chat;
  RETURN to_jsonb(t)-ARRAY['admission_envelope','execution_snapshot','admission_canonical','execution_canonical','dispatch_attempt_id'];
 END IF;
 IF p_action='delete' THEN
  SELECT * INTO d FROM chat_fence.deletions WHERE chat_id=p_chat AND request_id=request;
  IF FOUND THEN
   IF d.edit_material IS NOT NULL OR d.anchor_id IS DISTINCT FROM p->>'anchor_id' OR d.expected_epoch<>expected THEN RAISE EXCEPTION 'retry input conflict' USING ERRCODE='22023'; END IF;
   RETURN d.receipt;
  END IF;
  IF s.phase<>'idle' OR s.epoch<>expected OR EXISTS(SELECT 1 FROM public.chats WHERE id=p_chat AND active_stream_id IS NOT NULL) THEN
   RAISE EXCEPTION 'delete conflict' USING ERRCODE='40001';
  END IF;
  SELECT * INTO a FROM public.chat_messages WHERE chat_id=p_chat AND id=p->>'anchor_id';
  IF NOT FOUND THEN RAISE EXCEPTION 'anchor missing' USING ERRCODE='P0002'; END IF;
  UPDATE chat_fence.state SET epoch=epoch+1 WHERE chat_id=p_chat RETURNING * INTO s;
  INSERT INTO chat_fence.tombstones(message_id,chat_id,deleted_epoch)
   SELECT id,chat_id,s.epoch FROM public.chat_messages WHERE chat_id=p_chat AND (created_at,id)>=(a.created_at,a.id);
  DELETE FROM public.chat_messages WHERE chat_id=p_chat AND (created_at,id)>=(a.created_at,a.id);
  GET DIAGNOSTICS n=ROW_COUNT;
  receipt := jsonb_build_object('epoch',s.epoch,'deleted',n,'request_id',request);
  INSERT INTO chat_fence.deletions(chat_id,request_id,anchor_id,expected_epoch,receipt) VALUES(p_chat,request,a.id,expected,receipt);
  RETURN receipt;
 END IF;
 token := (p->>'owner')::uuid; generation := (p->>'epoch')::bigint;
 IF p_action='close_unattempted' THEN
  IF token IS NULL OR generation IS NULL THEN RAISE EXCEPTION 'missing close identity' USING ERRCODE='22023'; END IF;
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=token;
  IF NOT FOUND OR t.epoch<>generation OR t.closed OR t.dispatch_attempt_id IS NOT NULL
    OR s.owner IS DISTINCT FROM token OR s.epoch<>generation OR s.phase<>'pending' THEN
   RETURN jsonb_build_object('closed',false);
  END IF;
  UPDATE chat_fence.turns SET closed=true WHERE chat_id=p_chat AND request_id=token;
  UPDATE chat_fence.state SET owner=NULL,phase='idle',run_id=NULL WHERE chat_id=p_chat;
  UPDATE public.chats SET active_stream_id=NULL WHERE id=p_chat;
  RETURN jsonb_build_object('closed',true);
 END IF;
 IF p_action='claim_dispatch' THEN
  attempt := (p->>'attempt_id')::uuid;
  IF token IS NULL OR generation IS NULL OR attempt IS NULL THEN RAISE EXCEPTION 'missing dispatch identity' USING ERRCODE='22023'; END IF;
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=token;
  IF NOT FOUND OR t.epoch<>generation THEN RAISE EXCEPTION 'stale dispatch authority' USING ERRCODE='40001'; END IF;
  -- A replay NEVER reauthorizes start, even for the exact same attempt UUID.
  IF t.dispatch_attempt_id IS NOT NULL OR t.closed OR s.owner IS DISTINCT FROM token OR s.epoch<>generation OR s.phase<>'pending' THEN
   RETURN jsonb_build_object('claimed',false,'attempt_id',t.dispatch_attempt_id,
    'receipt',to_jsonb(t)-ARRAY['admission_envelope','execution_snapshot','admission_canonical','execution_canonical','dispatch_attempt_id']);
  END IF;
  UPDATE chat_fence.turns SET dispatch_attempt_id=attempt WHERE chat_id=p_chat AND request_id=token RETURNING * INTO t;
  RETURN jsonb_build_object('claimed',true,'attempt_id',attempt,
   'receipt',to_jsonb(t)-ARRAY['admission_envelope','execution_snapshot','admission_canonical','execution_canonical','dispatch_attempt_id']);
 END IF;
 IF token IS NULL OR generation IS NULL OR s.owner IS DISTINCT FROM token OR s.epoch<>generation OR s.phase='idle' THEN
  IF p_action='release' THEN RETURN jsonb_build_object('released',false); END IF;
  RAISE EXCEPTION 'stale writer' USING ERRCODE='40001';
 END IF;
 IF p_action='bind' THEN
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=token;
  IF t.dispatch_attempt_id IS NULL OR t.dispatch_attempt_id IS DISTINCT FROM (p->>'attempt_id')::uuid THEN
   RAISE EXCEPTION 'dispatch claim required' USING ERRCODE='40001';
  END IF;
  IF coalesce(p->>'run_id','')='' OR p->>'run_id' LIKE 'pending-%' THEN RAISE EXCEPTION 'invalid run'; END IF;
  IF s.run_id IS NOT NULL AND s.run_id<>p->>'run_id' THEN RAISE EXCEPTION 'run already bound' USING ERRCODE='40001'; END IF;
  UPDATE chat_fence.turns SET bound_run_id=p->>'run_id' WHERE chat_id=p_chat AND request_id=token AND bound_run_id IS NULL;
  UPDATE chat_fence.state SET phase='running',run_id=p->>'run_id' WHERE chat_id=p_chat;
  UPDATE public.chats SET active_stream_id=p->>'run_id' WHERE id=p_chat;
  RETURN jsonb_build_object('bound',true);
 END IF;
 IF p_action='release' THEN
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=token;
  IF (s.phase='running' AND (coalesce(p->>'reason','') NOT IN ('workflow_complete','external_terminal') OR p->>'run_id' IS DISTINCT FROM s.run_id)) OR
     (s.phase='pending' AND (p->>'reason' IS DISTINCT FROM 'confirmed_no_start' OR t.dispatch_attempt_id IS NULL)) THEN RAISE EXCEPTION 'release proof required'; END IF;
  UPDATE chat_fence.turns SET closed=true WHERE chat_id=p_chat AND request_id=token;
  UPDATE chat_fence.state SET owner=NULL,phase='idle',run_id=NULL WHERE chat_id=p_chat;
  UPDATE public.chats SET active_stream_id=NULL WHERE id=p_chat;
  RETURN jsonb_build_object('released',true);
 END IF;
 IF p_action NOT IN ('write','update_parts') THEN RAISE EXCEPTION 'unsupported command'; END IF;
 IF s.phase<>'running' THEN RAISE EXCEPTION 'writer run not bound' USING ERRCODE='40001'; END IF;
 IF p->>'run_id' IS DISTINCT FROM s.run_id THEN RAISE EXCEPTION 'wrong writer run' USING ERRCODE='40001'; END IF;
 IF coalesce(p->>'id','')='' OR jsonb_typeof(p->'parts') IS DISTINCT FROM 'object'
    OR p->'parts'->>'id' IS DISTINCT FROM p->>'id'
    OR coalesce(p->'parts'->>'role','') NOT IN ('user','assistant')
    OR jsonb_typeof(p->'parts'->'parts') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION 'invalid stored UIMessage';
 END IF;
 IF EXISTS(SELECT 1 FROM chat_fence.tombstones WHERE message_id=p->>'id') THEN RAISE EXCEPTION 'deleted identity cannot be reused' USING ERRCODE='40001'; END IF;
 SELECT * INTO m FROM public.chat_messages WHERE id=p->>'id';
 IF FOUND AND m.chat_id<>p_chat THEN RAISE EXCEPTION 'foreign message identity' USING ERRCODE='42501'; END IF;
 IF p_action='update_parts' THEN
  IF m.id IS NULL THEN RETURN jsonb_build_object('updated',false); END IF;
  IF m.role IS DISTINCT FROM p->'parts'->>'role' THEN RAISE EXCEPTION 'immutable message role'; END IF;
  IF NOT EXISTS(SELECT 1 FROM chat_fence.message_epochs WHERE message_id=m.id AND chat_id=p_chat AND epoch=s.epoch) THEN RAISE EXCEPTION 'prior message generation' USING ERRCODE='40001'; END IF;
  UPDATE public.chat_messages SET parts=p->'parts' WHERE id=m.id AND chat_id=p_chat;
  RETURN jsonb_build_object('updated',true);
 END IF;
 IF p->>'role' IS DISTINCT FROM p->'parts'->>'role' THEN RAISE EXCEPTION 'invalid role'; END IF;
 mode:=coalesce(p->>'mode','insert');
 IF mode NOT IN ('insert','upsert') OR (mode='upsert' AND p->>'role'<>'assistant') THEN RAISE EXCEPTION 'invalid write mode'; END IF;
 IF m.id IS NULL THEN
  INSERT INTO public.chat_messages(id,chat_id,role,parts) VALUES(p->>'id',p_chat,p->>'role',p->'parts');
  INSERT INTO chat_fence.message_epochs VALUES(p->>'id',p_chat,s.epoch);
  outcome := 'inserted';
 ELSE
  IF m.role<>p->>'role' THEN RAISE EXCEPTION 'immutable message role'; END IF;
  IF mode='insert' THEN
   outcome := 'exactDuplicate';
   IF m.parts IS DISTINCT FROM p->'parts' THEN RAISE EXCEPTION 'duplicate input conflict' USING ERRCODE='22023'; END IF;
  ELSE
   IF NOT EXISTS(SELECT 1 FROM chat_fence.message_epochs WHERE message_id=m.id AND chat_id=p_chat AND epoch=s.epoch) THEN RAISE EXCEPTION 'prior message generation' USING ERRCODE='40001'; END IF;
   IF m.parts IS NOT DISTINCT FROM p->'parts' THEN
    outcome := 'exactDuplicate';
   ELSE
    UPDATE public.chat_messages SET parts=p->'parts' WHERE id=m.id AND chat_id=p_chat;
    outcome := 'updated';
   END IF;
  END IF;
 END IF;
 RETURN jsonb_build_object('written',true,'outcome',outcome);
END $$;
ALTER FUNCTION public.chat_fence_command(text,uuid,text,jsonb) OWNER TO recoup_chat_fence_owner;
REVOKE ALL ON FUNCTION public.chat_fence_command(text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.chat_fence_command(text,uuid,text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.guard_chat_fence_message(), public.guard_chat_fence_parent(), public.guard_chat_fence_identity_after() FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
