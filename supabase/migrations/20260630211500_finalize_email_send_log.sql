-- Finalize email_send_log (recoupable/chat#1829): drop the unused `error`
-- column and enable RLS.
--
-- `error` (the Resend send-failure reason) shipped in the create migration but
-- isn't needed for the core observability goal — the empty-email failures
-- succeed (`success:true`), so it's always null for them, and real send
-- failures are rare/unobserved. The api writer never populates it.
--
-- RLS: enabled with no policies, matching neighboring internal/service-written
-- tables (error_logs, the playcount store). The api writes via the service role
-- (which bypasses RLS); anon/authenticated have no access to this internal log.

ALTER TABLE public.email_send_log DROP COLUMN IF EXISTS error;
ALTER TABLE public.email_send_log ENABLE ROW LEVEL SECURITY;
