-- Converge the migration history with production for credits_usage.
--
-- Production has had `credits_usage.remaining_credits integer NOT NULL DEFAULT 0`
-- since before this repo's history begins, but no migration here creates it:
-- 20241209025457 only declares (id, account_id, timestamp). Every schema-only
-- database built from these migrations (Supabase preview branches, local
-- stacks) therefore lacks the column, and the widening that follows
-- (20260827020000) fails on it with 42703 while succeeding on production.
--
-- No-op on production (the column exists); creates it everywhere else so the
-- same migrations apply the same way on every database. The production table
-- also has a serial `id` where the migration says uuid; that mismatch is
-- documented on recoupable/app#2000 and left alone here, since nothing in the
-- credit work reads it.
ALTER TABLE public.credits_usage
    ADD COLUMN IF NOT EXISTS remaining_credits integer NOT NULL DEFAULT 0;
