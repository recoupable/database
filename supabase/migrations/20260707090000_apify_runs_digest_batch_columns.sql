-- Digest-batch columns for apify_scraper_runs (recoupable/chat#1855, PR #2 of 6).
--
-- One artist-socials scrape (POST /api/artist/socials/scrape) starts one Apify
-- run per platform; each completes independently via webhook. To send ONE
-- consolidated "new posts" digest per scrape instead of one email per platform,
-- completions must find their sibling runs and know what each found:
--   batch_id       — shared id minted per scrape call; siblings share it.
--   completed_at   — set by the webhook when the run's results are processed;
--                    the batch's last writer assembles and sends the digest.
--   new_post_urls  — post URLs genuinely new to the platform found by this run
--                    (diffed against posts before insert); the digest's content.
--
-- Nullable, no FKs, no backfill: rows predating this migration simply never
-- digest (same loose-ids stance as the table's creation in chat#1840).

ALTER TABLE public.apify_scraper_runs
    ADD COLUMN IF NOT EXISTS batch_id      UUID,
    ADD COLUMN IF NOT EXISTS completed_at  TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS new_post_urls JSONB;

CREATE INDEX IF NOT EXISTS apify_scraper_runs_batch_id_idx
    ON public.apify_scraper_runs (batch_id)
    WHERE batch_id IS NOT NULL;
