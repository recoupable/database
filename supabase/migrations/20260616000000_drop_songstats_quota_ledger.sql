-- Drop the local Songstats quota ledger (recoupable/chat#1797, bullet 2).
--
-- The ledger mirrored Songstats' rate quota locally so a budget gate could halt
-- the backfill drain before spending. In practice it drifted: the prod 429 storm
-- (2026-06) filled it with phantom 429 "hits" (insert-on-every-call, success or
-- not), so the gate tripped on rate-limit noise, not real quota — a premature
-- drain halt. Songstats is the rate authority; api now relies on per-track
-- bounded exponential backoff and defers rate-limited rows to the next run
-- instead of mirroring a quota.
--
-- Code references removed in api PR #674 (getBackfillBudgetStep,
-- insertSongstatsQuotaLedger, selectSongstatsQuotaSpent and their tests).
-- Created 20260610010000_create_playcount_measurement_store.sql.
-- CASCADE cleans up the table's indexes, RLS, and FKs.

DROP TABLE IF EXISTS public.songstats_quota_ledger CASCADE;
