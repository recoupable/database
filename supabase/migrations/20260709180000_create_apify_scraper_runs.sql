-- Create apify_scraper_runs: digest-batch bookkeeping for scrape runs
-- (recoupable/chat#1855, PR #2 of 6).
--
-- One artist-socials scrape starts one Apify run per platform; each completes
-- independently via its own webhook invocation, sharing no memory with its
-- siblings. To send ONE consolidated "new posts" digest per scrape instead of
-- one email per platform, a completing webhook must answer three questions its
-- own request can't:
--   which runs are my batch siblings?      -> batch_id (Apify can't group runs
--                                             by our scrape call, and siblings
--                                             don't exist yet when the first
--                                             run's webhook is registered)
--   am I the last one to finish?           -> completed_at on every sibling
--                                             (Apify run status is NOT a
--                                             substitute: SUCCEEDED means the
--                                             scrape finished, not that our
--                                             webhook processed it and wrote
--                                             new_post_urls)
--   what did the earlier runs find?        -> new_post_urls (the pre-upsert
--                                             diff against posts; the upsert
--                                             destroys it moments later, so it
--                                             cannot be re-derived at digest
--                                             time)
--
-- Supersedes database#41, which ALTERed this table without creating it:
-- database#39 (the chat#1840 ownership map) was closed unmerged when run
-- polling moved to the capability model, so the table never existed (42P01 on
-- prod). This table is scoped to digest bookkeeping only — it is NOT an
-- ownership/authorization map; the chat#1840 decision stands and polling auth
-- stays capability-based.
--
-- Loose ids, no FKs (like email_send_log — bookkeeping shouldn't
-- cascade-delete with accounts/socials). Written by api insertApifyScraperRuns
-- (upsert on run_id at scrape start) + completeApifyScraperRun (webhook); read
-- by selectApifyScraperRunsByBatch (recoupable/api#760).

CREATE TABLE IF NOT EXISTS public.apify_scraper_runs (
    run_id        TEXT PRIMARY KEY,  -- Apify run id (natural key; one row per started run)
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    account_id    UUID NOT NULL,     -- account whose scrape started the run (denormalized audit)
    social_id     UUID,              -- scraped social profile
    platform      TEXT,              -- 'instagram' | 'tiktok' | 'x' | ... (digest section label)
    batch_id      UUID,              -- minted per POST /api/artist/socials/scrape call; siblings share it
    completed_at  TIMESTAMP WITH TIME ZONE,  -- set when OUR webhook finished processing this run's results
    new_post_urls JSONB              -- post URLs genuinely new to the platform (diffed against posts BEFORE upsert)
);

CREATE INDEX IF NOT EXISTS apify_scraper_runs_batch_id_idx
    ON public.apify_scraper_runs (batch_id)
    WHERE batch_id IS NOT NULL;
