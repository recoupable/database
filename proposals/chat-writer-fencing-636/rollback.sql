-- DRAFT, operator-only. Safe only before ANY chat has been enabled.
-- After enablement retain state/tombstones/guards; roll forward runtime or hold
-- service in maintenance. Removing the fence restores the original defect.
BEGIN;
LOCK TABLE public.sessions, public.chats, public.chat_messages IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM chat_fence.state) THEN
  RAISE EXCEPTION 'Enabled chat fences exist: destructive rollback prohibited';
 END IF;
END $$;
DROP TRIGGER chat_fence_message ON public.chat_messages;
DROP TRIGGER chat_fence_message_truncate ON public.chat_messages;
DROP TRIGGER chat_fence_chat ON public.chats;
DROP TRIGGER chat_fence_chat_truncate ON public.chats;
DROP TRIGGER chat_fence_session ON public.sessions;
DROP TRIGGER chat_fence_session_truncate ON public.sessions;
DROP FUNCTION public.chat_fence_command(text,uuid,text,jsonb);
DROP FUNCTION public.enable_chat_fence(text,uuid);
DROP FUNCTION public.guard_chat_fence_message();
DROP FUNCTION public.guard_chat_fence_parent();
DROP SCHEMA chat_fence CASCADE;
DROP POLICY chat_fence_messages ON public.chat_messages;
DROP POLICY chat_fence_chats ON public.chats;
DROP POLICY chat_fence_sessions ON public.sessions;
REVOKE UPDATE (id) ON public.sessions FROM recoup_chat_fence_owner;
REVOKE UPDATE (active_stream_id) ON public.chats FROM recoup_chat_fence_owner;
REVOKE ALL ON public.sessions, public.chats, public.chat_messages FROM recoup_chat_fence_owner;
REVOKE USAGE ON SCHEMA public FROM recoup_chat_fence_owner;
DROP ROLE recoup_chat_fence_owner;
COMMIT;
