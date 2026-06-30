-- Durable log of every POST /api/emails attempt (recoupable/chat#1829).
--
-- When an empty/footer-only "Message from Recoup" email reached customers, we
-- could not recover what the API received: malformed bodies were swallowed, the
-- route logged nothing, and the agent sandbox that built the request is
-- ephemeral. This records every attempt — sent, send_failed, and rejected
-- (empty/malformed) — with a copy of the body,
-- so a send is debuggable several days back. Written by api `logEmailAttempt`.
--
-- Append-only; loose ids, no FKs (like error_logs — a log shouldn't
-- cascade-delete with accounts, and rejected rows have no ids). Keyed by chat_id
-- only: chats.session_id reaches the session and sessions.account_id the account,
-- so session_id would be redundant (and isn't in the /api/emails contract).
-- account_id is denormalized (free at the API, the main query dimension).
-- Single responsibility = "what the API was asked to send"; Resend delivery
-- lifecycle is a future, separate concern keyed off resend_id.

CREATE TABLE IF NOT EXISTS public.email_send_log (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    account_id  UUID,            -- sender account (denormalized)
    chat_id     TEXT,            -- chat the send belongs to (chats.id is text); join chats.session_id for the session
    status      TEXT NOT NULL,   -- 'sent' | 'send_failed' | 'rejected'
    resend_id   TEXT,            -- Resend message id (forward hook for delivery events)
    raw_body    TEXT,            -- the request body as received (full; bounded by the platform request-size limit)
    error       TEXT
);

CREATE INDEX IF NOT EXISTS email_send_log_created_at_idx ON public.email_send_log (created_at DESC);
CREATE INDEX IF NOT EXISTS email_send_log_account_id_idx ON public.email_send_log (account_id);
