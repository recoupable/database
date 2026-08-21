-- Create music_generations: songs generated with MiniMax Music 3 on fal.ai,
-- and the run record for the workflow that produces them
-- (recoupable/chat#1992, contract: recoupable/docs#308).
--
-- Nothing in the schema tracks generated media today. There is no fal, image,
-- video or audio generation table anywhere in these migrations, so every
-- column here is new rather than an extension of an existing shape.
--
-- Why the row is also the run record: a generation takes roughly one to two
-- minutes, far past a request budget, so POST /api/music inserts a pending row
-- and hands the id to a Vercel Workflow. That is the same pattern
-- playcount_snapshots uses (20260610010000) — the API reads the row, never the
-- Workflow API — and it means one resource answers status, result, and
-- timeline with no second call and no dependency on Workflow run retention.
--
-- Why real cascading foreign keys rather than the loose ids on
-- apify_scraper_runs and email_send_log: those are logs, where outliving the
-- account is the point. A generated song is user content, so it follows
-- catalog_valuations (20260729230000) and dies with its owner.
--
-- Scope is personal-or-organization only. There is deliberately no
-- artist_account_id: the artist axis was dropped from v1 on a KISS call
-- (chat#1992, 2026-08-21), and adding the column now would ship a nullable
-- field nothing writes.

CREATE TABLE IF NOT EXISTS public.music_generations (
    id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The account the generation belongs to, after the standard account_id
    -- override has been resolved — not necessarily the caller.
    account_id                 UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    -- Organization context captured at creation. NULL means a personal
    -- generation. Stored rather than derived through account_organization_ids
    -- so the gallery read stays a single indexed filter, and so moving an
    -- account between organizations cannot retroactively reassign old songs.
    organization_id            UUID REFERENCES public.accounts(id) ON DELETE CASCADE,
    -- TEXT + CHECK, not a Postgres enum: only two enum types exist across all
    -- of these migrations and both are legacy.
    status                     TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    -- The generating model. Defaulted rather than hardcoded in the API so a
    -- future model swap is a value change, not a contract change.
    model                      TEXT NOT NULL DEFAULT 'minimax/music-3',
    prompt                     TEXT NOT NULL,
    lyrics                     TEXT NOT NULL,
    -- Display title. NULL until the generation completes.
    title                      TEXT,
    -- What the caller asked for, versus what the model actually produced. The
    -- model may stop early, so these genuinely differ and both are worth
    -- keeping: the first explains the price charged, the second the audio.
    requested_duration_seconds NUMERIC,
    duration_seconds           NUMERIC,
    -- Generation parameters as resolved for the fal call, so a completed row
    -- carries everything needed to reproduce it. seed is NULL until fal
    -- reports the seed it actually used for a randomized request.
    seed                       BIGINT,
    num_inference_steps        INTEGER,
    guidance_scale             NUMERIC,
    -- fal's queue request id, for correlating with their dashboard when a
    -- generation stalls.
    fal_request_id             TEXT,
    workflow_run_id            TEXT,
    -- fal's CDN URL, kept as provenance. Third-party and may expire, so it is
    -- never the thing we serve once the mirror below succeeds.
    source_url                 TEXT,
    -- Key inside the public-uploads bucket, once the audio is mirrored. NULL
    -- until completed. UNIQUE because two rows pointing at one object would
    -- make deletion unsafe.
    storage_key                TEXT UNIQUE,
    mime_type                  TEXT,
    file_size_bytes            BIGINT,
    credits_charged            INTEGER,
    -- Workflow timeline as [{at, message}], appended a step at a time. Lives
    -- on the row rather than in the Workflow API so a stuck generation is
    -- diagnosable from the resource alone, and so the timeline outlives
    -- Workflow run retention.
    logs                       JSONB NOT NULL DEFAULT '[]'::jsonb,
    error_message              TEXT,
    created_at                 TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- The gallery read: one account's generations, newest first.
CREATE INDEX IF NOT EXISTS music_generations_account_created_idx
  ON public.music_generations (account_id, created_at DESC);

-- The organization-scoped variant of the same read.
CREATE INDEX IF NOT EXISTS music_generations_organization_created_idx
  ON public.music_generations (organization_id, created_at DESC)
  WHERE organization_id IS NOT NULL;

-- Sweeping for in-flight work: rows stuck in pending or processing.
CREATE INDEX IF NOT EXISTS music_generations_status_created_idx
  ON public.music_generations (status, created_at DESC);

-- Correlating a fal webhook or a support question back to the row.
CREATE INDEX IF NOT EXISTS music_generations_fal_request_idx
  ON public.music_generations (fal_request_id)
  WHERE fal_request_id IS NOT NULL;

CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.music_generations
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- RLS on with zero policies: denies anon and authenticated outright while
-- service_role, which is how the API writes and reads, bypasses it. These rows
-- hold user-authored prompts and lyrics plus a storage key, so leaving the
-- table reachable through PostgREST with the anon key would expose one
-- account's songs to any other. The three most recent tables here skip the
-- statement; that is the pattern this one deliberately does not copy.
ALTER TABLE public.music_generations ENABLE ROW LEVEL SECURITY;
