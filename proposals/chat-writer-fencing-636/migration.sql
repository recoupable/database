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
 closed boolean NOT NULL DEFAULT false, PRIMARY KEY(chat_id,request_id)
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
 request uuid; expected bigint; token uuid; generation bigint; mode text;
BEGIN
 IF p_action IS NULL OR p_action NOT IN ('state','admit','bind','write','update_parts','release','delete') OR p IS NULL OR jsonb_typeof(p)<>'object' THEN
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
 IF p_action IN ('admit','delete') THEN
  request := (p->>'request_id')::uuid; expected := (p->>'expected_epoch')::bigint;
  IF request IS NULL OR expected IS NULL THEN RAISE EXCEPTION 'missing retry identity'; END IF;
 END IF;
 IF p_action='admit' THEN
  IF p->>'input_hash' IS NULL OR length(p->>'input_hash')<>64 THEN RAISE EXCEPTION 'invalid input hash'; END IF;
  SELECT * INTO t FROM chat_fence.turns WHERE chat_id=p_chat AND request_id=request;
  IF FOUND THEN
   IF t.input_hash<>p->>'input_hash' OR t.expected_epoch<>expected THEN RAISE EXCEPTION 'retry input conflict' USING ERRCODE='22023'; END IF;
   RETURN to_jsonb(t); -- Replay never allocates a new owner or authorizes redispatch.
  END IF;
  IF s.phase<>'idle' OR s.epoch<>expected THEN RAISE EXCEPTION 'admission conflict' USING ERRCODE='40001'; END IF;
  UPDATE chat_fence.state SET epoch=epoch+1,owner=request,phase='pending' WHERE chat_id=p_chat RETURNING * INTO s;
  INSERT INTO chat_fence.turns VALUES(p_chat,request,p->>'input_hash',expected,s.epoch,false) RETURNING * INTO t;
  UPDATE public.chats SET active_stream_id='pending-'||request::text WHERE id=p_chat;
  RETURN to_jsonb(t);
 END IF;
 IF p_action='delete' THEN
  SELECT * INTO d FROM chat_fence.deletions WHERE chat_id=p_chat AND request_id=request;
  IF FOUND THEN
   IF d.anchor_id IS DISTINCT FROM p->>'anchor_id' OR d.expected_epoch<>expected THEN RAISE EXCEPTION 'retry input conflict' USING ERRCODE='22023'; END IF;
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
  INSERT INTO chat_fence.deletions VALUES(p_chat,request,a.id,expected,receipt);
  RETURN receipt;
 END IF;
 token := (p->>'owner')::uuid; generation := (p->>'epoch')::bigint;
 IF token IS NULL OR generation IS NULL OR s.owner IS DISTINCT FROM token OR s.epoch<>generation OR s.phase='idle' THEN
  IF p_action='release' THEN RETURN jsonb_build_object('released',false); END IF;
  RAISE EXCEPTION 'stale writer' USING ERRCODE='40001';
 END IF;
 IF p_action='bind' THEN
  IF coalesce(p->>'run_id','')='' OR p->>'run_id' LIKE 'pending-%' THEN RAISE EXCEPTION 'invalid run'; END IF;
  IF s.run_id IS NOT NULL AND s.run_id<>p->>'run_id' THEN RAISE EXCEPTION 'run already bound' USING ERRCODE='40001'; END IF;
  UPDATE chat_fence.state SET phase='running',run_id=p->>'run_id' WHERE chat_id=p_chat;
  UPDATE public.chats SET active_stream_id=p->>'run_id' WHERE id=p_chat;
  RETURN jsonb_build_object('bound',true);
 END IF;
 IF p_action='release' THEN
  IF (s.phase='running' AND (p->>'reason' IS DISTINCT FROM 'terminal' OR p->>'run_id' IS DISTINCT FROM s.run_id)) OR
     (s.phase='pending' AND p->>'reason' IS DISTINCT FROM 'confirmed_no_start') THEN RAISE EXCEPTION 'release proof required'; END IF;
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
 ELSE
  IF m.role<>p->>'role' THEN RAISE EXCEPTION 'immutable message role'; END IF;
  IF mode='insert' THEN
   IF m.parts IS DISTINCT FROM p->'parts' THEN RAISE EXCEPTION 'duplicate input conflict' USING ERRCODE='22023'; END IF;
  ELSE
   IF NOT EXISTS(SELECT 1 FROM chat_fence.message_epochs WHERE message_id=m.id AND chat_id=p_chat AND epoch=s.epoch) THEN RAISE EXCEPTION 'prior message generation' USING ERRCODE='40001'; END IF;
   UPDATE public.chat_messages SET parts=p->'parts' WHERE id=m.id AND chat_id=p_chat;
  END IF;
 END IF;
 RETURN jsonb_build_object('written',true);
END $$;
ALTER FUNCTION public.chat_fence_command(text,uuid,text,jsonb) OWNER TO recoup_chat_fence_owner;
REVOKE ALL ON FUNCTION public.chat_fence_command(text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.chat_fence_command(text,uuid,text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.guard_chat_fence_message(), public.guard_chat_fence_parent(), public.guard_chat_fence_identity_after() FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
