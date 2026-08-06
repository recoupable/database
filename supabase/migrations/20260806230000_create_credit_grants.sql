-- Create credit_grants: who set an account's credit balance by hand, and why
-- (recoupable/chat#1948).
--
-- Today there is no staff-facing way to grant an account credits. Every route
-- under /api/admins/credits is a GET, so a top-up means a direct database
-- write against credits_usage — which records nothing about who made it or
-- what for. A grant is currently indistinguishable from a Stripe top-up or a
-- monthly reset, minutes after the fact.
--
-- Why a new table rather than columns on credits_usage: credits_usage is
-- current state (one row per account, id/account_id/remaining_credits/
-- timestamp), and a grant is an event. Columns there would only ever hold the
-- most recent grant, and the second grant would erase the first — the same
-- state-vs-event split argued in recoupable/chat#1947.
--
-- Why not usage_events: that table is deduction-shaped (input/output tokens,
-- provider, model_id, credits_deducted_cents) and has no actor or reason
-- column. A grant has no tokens and no model; a debit has no human behind it.
--
-- Written by api: POST /api/admins/credits (contract: recoupable/docs#295).
-- Read by GET /api/admins/credits/events, which returns these rows alongside
-- the usage_events debits for the same account and period.

CREATE TABLE IF NOT EXISTS public.credit_grants (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id        UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    -- ON DELETE RESTRICT, deliberately: attribution is the entire point of the
    -- table, and SET NULL would quietly destroy it. Deleting a Recoup staff
    -- account that has granted credits should fail loudly and be dealt with,
    -- not silently orphan the grants they made.
    granted_by        UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
    -- Non-empty after trimming: a blank reason is the failure mode this table
    -- exists to prevent, so it is rejected in the schema and not only in Zod.
    reason            TEXT NOT NULL CHECK (btrim(reason) <> ''),
    -- Balance immediately before the grant. NULL when the account had no
    -- credits_usage row at all and the grant created one.
    previous_credits  INTEGER,
    -- Balance the account was left holding. Absolute, not a delta.
    remaining_credits INTEGER NOT NULL CHECK (remaining_credits >= 0),
    created_at        TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- The read is always "recent grants for one account", to sit beside that
-- account's usage_events in the admin drilldown.
CREATE INDEX IF NOT EXISTS credit_grants_account_created_idx
  ON public.credit_grants (account_id, created_at DESC);
