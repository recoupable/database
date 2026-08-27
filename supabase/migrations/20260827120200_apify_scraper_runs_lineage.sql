-- apify_scraper_runs: run lineage for webhook-spawned runs (recoupable/app#2018
-- keystone, budget PR follows).
--
-- An artist profile scrape spawns a comments run, which spawns one commenter
-- profile run. Until now only the artist-batch route registered its runs
-- here; spawned runs were invisible, which is how an unbounded fan-of-fan
-- crawl ran at ~300 runs/hour for a day (app#2018 evidence) with nothing in
-- our own data to count or trace it. Every run the api starts now registers
-- with where it came from:
--   origin        'artist' — the profile belongs to a roster artist; the
--                 handler may schedule follow-ups.
--                 'fan'    — a commenter profile batch; terminal by
--                 construction, never followed up.
--   parent_run_id the run whose webhook started this one (NULL for the run a
--                 scrape endpoint started). Walk it to the root for the
--                 account and the originating scrape.
--
-- account_id becomes nullable: a spawned run inherits its parent's account
-- when the parent is registered, but a chain whose root predates this
-- migration has no account to inherit, and refusing to register it would
-- hide exactly the runs the budget PR needs to count.

ALTER TABLE public.apify_scraper_runs
    ALTER COLUMN account_id DROP NOT NULL,
    ADD COLUMN IF NOT EXISTS origin TEXT
        CHECK (origin IS NULL OR origin IN ('artist', 'fan')),
    ADD COLUMN IF NOT EXISTS parent_run_id TEXT;

-- Lineage walk (child -> parent) and "how many runs did this scrape spawn".
CREATE INDEX IF NOT EXISTS apify_scraper_runs_parent_run_id_idx
    ON public.apify_scraper_runs (parent_run_id)
    WHERE parent_run_id IS NOT NULL;

-- Per-account hourly budget count (budget PR).
CREATE INDEX IF NOT EXISTS apify_scraper_runs_account_created_idx
    ON public.apify_scraper_runs (account_id, created_at DESC)
    WHERE account_id IS NOT NULL;
