-- Rescale the credit ledger from cents to micro-dollars.
--
-- 1 credit was $0.01. It becomes $0.000001, so every stored value is
-- multiplied by 10,000 and nothing about what an account is *worth* changes
-- (recoupable/chat#2000).
--
-- The point is granularity, not revaluation. At a cent per credit, fal's
-- $0.002 per second means one credit buys five seconds of audio and anything
-- cheaper cannot be charged without rounding to zero or up past cost. Six
-- decimals let per-call pricing mirror provider pricing exactly.
--
-- DEPLOY ORDERING — READ BEFORE RUNNING
--
-- This migration is NOT safe on its own. Between it and the application deploy
-- that flips CREDITS_PER_USD to 1_000_000, the two sides disagree by a factor
-- of 10,000 in both directions:
--   * balances render 10,000x too large;
--   * every charge is 10,000x too small, i.e. effectively free.
-- Run it in a window where writes are quiet, with the api and chat deploys
-- going out immediately after. Widening (20260824090000) must already be on
-- main, or the largest rows overflow int4 partway through this UPDATE.
--
-- Reversible by dividing by the same factor: 10,000 is exact in integer
-- arithmetic and every current value is a whole number of cents, so no
-- rounding is introduced in either direction.

BEGIN;

-- Guard: refuse to run against columns that have not been widened. Without
-- this the UPDATE below would abort partway through on the largest balances,
-- leaving some tables rescaled and others not.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND ((table_name = 'credits_usage'  AND column_name = 'remaining_credits')
             OR (table_name = 'credit_grants'  AND column_name IN ('remaining_credits', 'previous_credits'))
             OR (table_name = 'usage_events'   AND column_name = 'credits_deducted_cents'))
           AND data_type <> 'bigint'
    ) THEN
        RAISE EXCEPTION
            'Credit columns are not BIGINT yet. Apply 20260824090000_widen_credit_columns_to_bigint.sql first.';
    END IF;
END $$;

UPDATE public.credits_usage
   SET remaining_credits = remaining_credits * 10000;

UPDATE public.credit_grants
   SET remaining_credits = remaining_credits * 10000,
       previous_credits  = previous_credits * 10000
 WHERE remaining_credits IS NOT NULL
    OR previous_credits IS NOT NULL;

UPDATE public.usage_events
   SET credits_deducted_cents = credits_deducted_cents * 10000;

-- The column keeps the name `credits_deducted_cents` for now, misleading as
-- that is. It appears in the admin API's response shape
-- (`total_credits_deducted_cents`, and `credits_deducted_cents` on each event),
-- so renaming it is a breaking change for API consumers rather than an
-- internal tidy. Bundling that into a migration that also moves every balance
-- would widen the blast radius of the riskiest change here for a cosmetic
-- gain. It gets its own PR, with the api and docs changes alongside.

COMMIT;
