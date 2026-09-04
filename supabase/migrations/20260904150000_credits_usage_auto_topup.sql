-- Opt-in auto top-up settings on credits_usage (recoupable/app#2062, decision 6).
--
-- One row per account already holds the balance, so the settings that decide
-- when that balance is refilled live beside it. Everything is off by default:
-- auto_topup_enabled = false and null amount/threshold mean "never charge".
-- The api only flips enabled to true through PUT /api/accounts/{id}/auto-top-up,
-- which requires a card on file and a user-chosen amount and threshold.
--
-- Amounts are credit micro-dollars (CREDIT_DECIMALS = 6, 1 credit = $0.000001),
-- the same unit as remaining_credits, so threshold comparisons need no
-- conversion at charge time.
--
-- last_run_at feeds the one-top-up-per-10-minutes lease; last_error stores the
-- Stripe decline that turned enabled back off, so the billing page can show why.

ALTER TABLE public.credits_usage
  ADD COLUMN auto_topup_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN auto_topup_amount bigint,
  ADD COLUMN auto_topup_threshold bigint,
  ADD COLUMN auto_topup_last_run_at timestamptz,
  ADD COLUMN auto_topup_last_error text;

ALTER TABLE public.credits_usage
  ADD CONSTRAINT credits_usage_auto_topup_amount_positive
    CHECK (auto_topup_amount IS NULL OR auto_topup_amount > 0),
  ADD CONSTRAINT credits_usage_auto_topup_threshold_nonnegative
    CHECK (auto_topup_threshold IS NULL OR auto_topup_threshold >= 0),
  ADD CONSTRAINT credits_usage_auto_topup_threshold_below_amount
    CHECK (auto_topup_amount IS NULL OR auto_topup_threshold IS NULL
           OR auto_topup_threshold < auto_topup_amount),
  ADD CONSTRAINT credits_usage_auto_topup_enabled_needs_settings
    CHECK (NOT auto_topup_enabled
           OR (auto_topup_amount IS NOT NULL AND auto_topup_threshold IS NOT NULL));

COMMENT ON COLUMN public.credits_usage.auto_topup_enabled IS
  'Opt-in: charge the default card when remaining_credits drops below auto_topup_threshold. Off by default; a card decline sets it back to false.';
COMMENT ON COLUMN public.credits_usage.auto_topup_amount IS
  'Credits (micro-dollars) to buy per auto top-up. Null until the user sets it.';
COMMENT ON COLUMN public.credits_usage.auto_topup_threshold IS
  'Balance (micro-dollars) below which an auto top-up runs. Null until the user sets it.';
COMMENT ON COLUMN public.credits_usage.auto_topup_last_run_at IS
  'When the last auto top-up charge was attempted; the api refuses another within 10 minutes.';
COMMENT ON COLUMN public.credits_usage.auto_topup_last_error IS
  'Stripe decline message from the attempt that disabled auto top-up, null once re-enabled.';
