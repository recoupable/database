-- SOURCE-ONLY PROPOSAL. Requires disabled 636 + durable-surfaces-2207 proposals.
-- No migrations, service grants, enrollment, activation or source-authority bypass.
BEGIN;
SET LOCAL ROLE recoup_chat_fence_owner;
CREATE TABLE chat_fence.catalog_surface_sources (
 message_id text PRIMARY KEY REFERENCES public.chat_messages(id) ON DELETE CASCADE,
 chat_id text NOT NULL REFERENCES chat_fence.state(chat_id),
 workspace_id uuid NOT NULL,
 source_revision bigint NOT NULL DEFAULT 1 CHECK (source_revision=1),
 source_canonical text NOT NULL CHECK (octet_length(source_canonical)<=262144),
 surface_canonical text NOT NULL CHECK (octet_length(surface_canonical)<=262144),
 source_sha256 text NOT NULL,
 surface_sha256 text NOT NULL
);
-- The exact original tuple list is evidence, not authority. Current owning rows
-- and actor/workspace/catalog/source policy must be checked under this transaction.
CREATE FUNCTION chat_fence.authorize_catalog_surface_source(p_account uuid,p_workspace uuid,p_source jsonb)
RETURNS void LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
 RAISE EXCEPTION 'catalog snapshot authority adapter unavailable' USING ERRCODE='0A000';
END $$;
RESET ROLE;
CREATE FUNCTION public.retain_catalog_surface_source(
 p_chat text,p_account uuid,p_session text,p_epoch bigint,p_owner uuid,p_run text,
 p_message text,p_expected_revision bigint,p_source text,p_surface text,
 p_source_sha256 text,p_surface_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s chat_fence.state; msg public.chat_messages;
 prior chat_fence.catalog_surface_sources; source jsonb; surface jsonb; workspace uuid; part jsonb;
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN
  RAISE EXCEPTION 'READ COMMITTED required' USING ERRCODE='0A000'; END IF;
 IF p_expected_revision IS DISTINCT FROM 0 OR p_source IS NULL OR p_surface IS NULL
 OR octet_length(p_source)>262144 OR octet_length(p_surface)>262144
 OR p_source_sha256 IS DISTINCT FROM encode(sha256(convert_to(p_source,'UTF8')),'hex')
 OR p_surface_sha256 IS DISTINCT FROM encode(sha256(convert_to(p_surface,'UTF8')),'hex') THEN
  RAISE EXCEPTION 'invalid snapshot binding' USING ERRCODE='22023'; END IF;
 source:=p_source::jsonb; surface:=p_surface::jsonb;
 IF source->>'mappingVersion' IS DISTINCT FROM 'catalog-streams-v1'
 OR surface->>'schemaVersion' IS DISTINCT FROM '1' OR surface->'revision' IS DISTINCT FROM '1'::jsonb
 OR jsonb_typeof(source->'lineage') IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION 'invalid snapshot shape' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(source->'lineage')=0 THEN
  RAISE EXCEPTION 'lineage missing' USING ERRCODE='22023'; END IF;
 workspace:=(source->>'workspaceId')::uuid;
 IF workspace IS NULL OR surface->'context'->>'workspaceId' IS DISTINCT FROM workspace::text
 OR surface->'context'->'subject'->>'kind' IS DISTINCT FROM 'catalog'
 OR surface->'context'->'subject'->>'id' IS DISTINCT FROM source->'query'->>'catalog_id' THEN
  RAISE EXCEPTION 'scope mismatch' USING ERRCODE='22023'; END IF;
 -- Same session -> chat -> fence -> message -> source order as owning boundary.
 PERFORM 1 FROM public.sessions WHERE id=p_session AND account_id=p_account FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.chats WHERE id=p_chat AND session_id=p_session FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='42501'; END IF;
 SELECT * INTO s FROM chat_fence.state WHERE chat_id=p_chat FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'fence unavailable' USING ERRCODE='55000'; END IF;
 IF s.phase<>'running' OR s.epoch IS DISTINCT FROM p_epoch OR s.owner IS DISTINCT FROM p_owner
 OR s.run_id IS DISTINCT FROM p_run THEN
  RAISE EXCEPTION 'stale writer' USING ERRCODE='40001'; END IF;
 SELECT * INTO msg FROM public.chat_messages WHERE id=p_message AND chat_id=p_chat FOR UPDATE;
 IF NOT FOUND OR msg.role<>'assistant' THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='P0002'; END IF;
 -- A live writer cannot adopt an assistant persisted by an earlier generation.
 IF NOT EXISTS(SELECT 1 FROM chat_fence.message_epochs WHERE message_id=msg.id AND chat_id=p_chat AND epoch=s.epoch) THEN RAISE EXCEPTION 'prior message generation' USING ERRCODE='40001'; END IF;
 part:=chat_fence.surface_part(msg.parts);
 IF part->'data' IS DISTINCT FROM surface THEN
  RAISE EXCEPTION 'persisted snapshot differs' USING ERRCODE='40001'; END IF;
 PERFORM chat_fence.authorize_catalog_surface_source(p_account,workspace,source);
 SELECT * INTO prior FROM chat_fence.catalog_surface_sources WHERE message_id=p_message;
 IF FOUND THEN
  IF prior.chat_id<>p_chat OR prior.workspace_id<>workspace OR prior.source_canonical<>p_source
  OR prior.surface_canonical<>p_surface THEN
   RAISE EXCEPTION 'immutable source conflict' USING ERRCODE='40001'; END IF;
 ELSE
  INSERT INTO chat_fence.catalog_surface_sources(message_id,chat_id,workspace_id,source_canonical,surface_canonical,source_sha256,surface_sha256)
  VALUES(p_message,p_chat,workspace,p_source,p_surface,p_source_sha256,p_surface_sha256);
 END IF;
 RETURN jsonb_build_object('message_id',p_message,'source_revision',1,'source_sha256',p_source_sha256,
  'surface_sha256',p_surface_sha256,'retained',true);
END $$;
ALTER FUNCTION public.retain_catalog_surface_source(text,uuid,text,bigint,uuid,text,text,bigint,text,text,text,text) OWNER TO recoup_chat_fence_owner;
SET LOCAL ROLE recoup_chat_fence_owner;
CREATE FUNCTION chat_fence.guard_catalog_surface_source() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE saved chat_fence.catalog_surface_sources; part jsonb;
BEGIN
 -- Existing 636 invoker guard owns refusal of direct legacy/service writers on
 -- enrolled chats. Do not force unrelated unenrolled writes to read private state.
 IF current_user<>'recoup_chat_fence_owner' THEN RETURN NEW; END IF;
 SELECT * INTO saved FROM chat_fence.catalog_surface_sources WHERE message_id=OLD.id;
 IF FOUND THEN
  part:=chat_fence.surface_part(NEW.parts);
  IF NEW.chat_id IS DISTINCT FROM saved.chat_id OR NEW.role IS DISTINCT FROM 'assistant'
  OR part->'data' IS DISTINCT FROM saved.surface_canonical::jsonb THEN
   RAISE EXCEPTION 'retained source is immutable' USING ERRCODE='40001'; END IF;
 END IF;
 RETURN NEW;
END $$;
RESET ROLE;
CREATE TRIGGER catalog_surface_source BEFORE UPDATE ON public.chat_messages
 FOR EACH ROW EXECUTE FUNCTION chat_fence.guard_catalog_surface_source();
REVOKE ALL ON chat_fence.catalog_surface_sources FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION chat_fence.authorize_catalog_surface_source(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION chat_fence.guard_catalog_surface_source() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.retain_catalog_surface_source(text,uuid,text,bigint,uuid,text,text,bigint,text,text,text,text) FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
