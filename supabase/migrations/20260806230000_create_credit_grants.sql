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

-- Atomic balance set + grant record.
--
-- Same reasoning as deduct_credits_with_audit (20260525000000): PostgREST
-- cannot run a multi-statement transaction, so two separate calls can drift on
-- partial failure. Here the drift is worse than an accounting hiccup — a moved
-- balance with no grant row is precisely the untraceable write this whole
-- change exists to eliminate, and it would be indistinguishable from the
-- hand-written database updates we are replacing. A plpgsql body runs in an
-- implicit transaction, so either both writes commit or neither does.
--
-- previous_credits is captured inside the function rather than read first by
-- the caller, so it cannot be stale by the time the balance moves.
--
-- The caller is expected to have already confirmed the account exists (the API
-- returns a 404 for an unknown account_id); if it has not, the FK on
-- credit_grants.account_id rejects the whole call rather than half-applying it.
--
-- Args:
--   p_account_id        account whose balance is being set
--   p_granted_by        admin account making the grant, from credentials
--   p_reason            why (non-empty after trimming, per the CHECK above)
--   p_remaining_credits balance to leave the account holding — absolute, not a delta

CREATE OR REPLACE FUNCTION public.grant_credits_with_audit(
    p_account_id        uuid,
    p_granted_by        uuid,
    p_reason            text,
    p_remaining_credits integer
) RETURNS public.credit_grants
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $$
DECLARE
    v_previous integer;
    v_now      timestamptz := now();
    v_grant    public.credit_grants;
BEGIN
    SELECT remaining_credits
      INTO v_previous
      FROM public.credits_usage
     WHERE account_id = p_account_id
     LIMIT 1;

    IF FOUND THEN
        UPDATE public.credits_usage
           SET remaining_credits = p_remaining_credits,
               -- Bumping the timestamp restarts the monthly-reset clock, so a
               -- deliberate grant is not undone by a stale-row heuristic days
               -- later. The API reports the resulting expiry back to the admin.
               "timestamp"       = v_now
         WHERE account_id = p_account_id;
    ELSE
        -- v_previous stays NULL, which is exactly what the column means here:
        -- the account had no balance row before this grant created one.
        INSERT INTO public.credits_usage (account_id, remaining_credits, "timestamp")
        VALUES (p_account_id, p_remaining_credits, v_now);
    END IF;

    INSERT INTO public.credit_grants (
        account_id,
        granted_by,
        reason,
        previous_credits,
        remaining_credits,
        created_at
    ) VALUES (
        p_account_id,
        p_granted_by,
        p_reason,
        v_previous,
        p_remaining_credits,
        v_now
    ) RETURNING * INTO v_grant;

    RETURN v_grant;
END;
$$;
