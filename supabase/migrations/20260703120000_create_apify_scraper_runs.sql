-- Ownership map for Apify scraper runs (recoupable/chat#1840).
--
-- GET /api/apify/runs/{runId} is admin-only because Apify run identifiers
-- carry no account scope — the endpoint has nothing to authorize against, so
-- account-key agents that start a scrape via POST /api/socials/{id}/scrape
-- get Forbidden polling their own run. This records who started each run at
-- start time, giving the results endpoint an ownership chain: owning account
-- OR admin may poll. Written by the api scrape-start handler; read by the
-- results validator.
--
-- Loose ids, no FKs (like email_send_log / error_logs — an ownership log
-- shouldn't cascade-delete with accounts, and a dangling row just means the
-- run degrades to admin-only). run_id is the natural key: one owner per run.
-- social_id is denormalized for audit ("which profile was scraped").
--
-- RLS: enabled with no policies, matching neighboring service-written tables.
-- The api reads/writes via the service role (bypasses RLS); anon/authenticated
-- have no access.

CREATE TABLE IF NOT EXISTS public.apify_scraper_runs (
    run_id      TEXT PRIMARY KEY,
    account_id  UUID NOT NULL,   -- account whose key started the run
    social_id   UUID,            -- social profile the run scrapes (audit)
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS apify_scraper_runs_account_id_idx ON public.apify_scraper_runs (account_id);

ALTER TABLE public.apify_scraper_runs ENABLE ROW LEVEL SECURITY;
