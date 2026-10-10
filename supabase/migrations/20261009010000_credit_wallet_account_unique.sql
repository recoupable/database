-- One wallet row per assigned billing account. Never merge or discard balances.
-- Existing duplicates cause the whole migration to fail for operator review.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE public.credits_usage
    ADD CONSTRAINT credits_usage_account_id_key UNIQUE (account_id);

COMMIT;
