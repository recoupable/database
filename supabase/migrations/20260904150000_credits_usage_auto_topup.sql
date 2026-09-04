-- Opt-in auto top-up settings on credits_usage (recoupable/app#2062).
--
-- One row per account already holds the balance; the settings that decide
-- when that balance is refilled live beside it. Defaults mean "never":
-- auto_topup_enabled = false and null amount/threshold.
--
-- Units: auto_topup_amount and auto_topup_threshold are credit micro-dollars
-- (1 credit = $0.000001), the same unit as remaining_credits.
--
-- Constraints are added NOT VALID here and validated in the next migration
-- file (20260904150100). Each file runs in its own transaction, so the
-- ACCESS EXCLUSIVE lock this ALTER takes is released before the validation
-- scan, which then runs under SHARE UPDATE EXCLUSIVE and does not block
-- balance reads or writes. Every existing row satisfies the constraints
-- (enabled defaults to false, the amounts default to null).

ALTER TABLE public.credits_usage
  ADD COLUMN auto_topup_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN auto_topup_amount bigint,
  ADD COLUMN auto_topup_threshold bigint,
  ADD COLUMN auto_topup_last_run_at timestamptz,
  ADD COLUMN auto_topup_last_error text;

ALTER TABLE public.credits_usage
  ADD CONSTRAINT credits_usage_auto_topup_amount_positive
    CHECK (auto_topup_amount IS NULL OR auto_topup_amount > 0) NOT VALID,
  ADD CONSTRAINT credits_usage_auto_topup_threshold_nonnegative
    CHECK (auto_topup_threshold IS NULL OR auto_topup_threshold >= 0) NOT VALID,
  ADD CONSTRAINT credits_usage_auto_topup_threshold_below_amount
    CHECK (auto_topup_amount IS NULL OR auto_topup_threshold IS NULL
           OR auto_topup_threshold < auto_topup_amount) NOT VALID,
  ADD CONSTRAINT credits_usage_auto_topup_enabled_needs_settings
    CHECK (NOT auto_topup_enabled
           OR (auto_topup_amount IS NOT NULL AND auto_topup_threshold IS NOT NULL)) NOT VALID;

COMMENT ON COLUMN public.credits_usage.auto_topup_enabled IS
  'Opt-in flag for automatic credit top-ups. Default false.';
COMMENT ON COLUMN public.credits_usage.auto_topup_amount IS
  'Credits (micro-dollars) per auto top-up. Null until set; must be > 0.';
COMMENT ON COLUMN public.credits_usage.auto_topup_threshold IS
  'Balance (micro-dollars) below which an auto top-up runs. Null until set; must be < auto_topup_amount.';
COMMENT ON COLUMN public.credits_usage.auto_topup_last_run_at IS
  'When the last auto top-up was attempted.';
COMMENT ON COLUMN public.credits_usage.auto_topup_last_error IS
  'Error message from the last failed auto top-up attempt, if any.';
