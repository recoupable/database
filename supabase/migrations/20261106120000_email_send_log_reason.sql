-- Record why a POST /api/emails attempt was rejected or failed (recoupable/app#1949 F2).
--
-- 59% of logged sends were `rejected` with nothing to say why: the rejected
-- path stored only the raw body, and the earlier `error` column was dropped in
-- 20260630211500 because nothing filled it. `reason` is written by api
-- `logEmailAttempt` on the rejected and send_failed paths as a short code
-- followed by detail, e.g. `recipient_not_allowed: a@example.com`, so the
-- rejection rate can be grouped by cause. Null for successful sends.

ALTER TABLE public.email_send_log ADD COLUMN IF NOT EXISTS reason TEXT;
