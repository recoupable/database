-- Phase 2 of the credits / usage unification.
--
-- Widens usage_events so it can serve as the single per-event consumption
-- log across both open-agents (source='web') and the recoupable api
-- (source='api', covering chat and research callers). Adds
-- credits_deducted_cents so every event also records the wallet impact —
-- making credits_usage.remaining_credits derivable from
-- (top-ups + monthly_refills + signup_grants) − SUM(credits_deducted_cents)
-- and enabling per-customer credit-usage rollups on the admin dashboard.
--
-- Out of scope intentionally:
--   * agent_type CHECK stays ('main','subagent'). Non-agent callers in api
--     (chat, research) will write the existing 'main' default — no schema
--     change needed.
--   * x402 (lib/x402/fetchWithPayment.ts) is not being unified in this
--     phase and continues to update credits_usage only.

ALTER TABLE public.usage_events
    DROP CONSTRAINT IF EXISTS usage_events_source_check;

ALTER TABLE public.usage_events
    ADD CONSTRAINT usage_events_source_check
        CHECK (source IN ('web', 'api'));

ALTER TABLE public.usage_events
    ADD COLUMN IF NOT EXISTS credits_deducted_cents INTEGER NOT NULL DEFAULT 0;
