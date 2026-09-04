-- Validate the auto top-up CHECK constraints added NOT VALID in
-- 20260904150000. Runs in its own transaction so the scan holds only a
-- SHARE UPDATE EXCLUSIVE lock and never blocks credits_usage reads or writes.

ALTER TABLE public.credits_usage VALIDATE CONSTRAINT credits_usage_auto_topup_amount_positive;
ALTER TABLE public.credits_usage VALIDATE CONSTRAINT credits_usage_auto_topup_threshold_nonnegative;
ALTER TABLE public.credits_usage VALIDATE CONSTRAINT credits_usage_auto_topup_threshold_below_amount;
ALTER TABLE public.credits_usage VALIDATE CONSTRAINT credits_usage_auto_topup_enabled_needs_settings;
