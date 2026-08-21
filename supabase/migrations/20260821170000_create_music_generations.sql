-- Create music_generations: songs generated with MiniMax Music 3 on fal.ai
-- (recoupable/chat#1992, contract: recoupable/docs#308).
--
-- Nothing in this schema tracks generated media today, so every column is new
-- rather than an extension of an existing shape.
--
-- Why the row is also the run record: a generation takes roughly one to two
-- minutes, far past a request budget, so POST /api/music inserts a pending row
-- and hands the id to a Vercel Workflow. Same pattern as playcount_snapshots
-- (20260610010000) - the API reads the row, never the Workflow API.
--
-- Deliberately narrow. Anything another system already knows is not stored
-- here: generation parameters ride along as workflow arguments, the seed and
-- the step timeline are readable from fal_request_id and workflow_run_id, and
-- credits are accounted in usage_events. What stays is what the gallery has to
-- render without making a call per row.
--
-- Scope needs no second column. Organizations are accounts in this schema, so
-- an organization's song is one whose account_id is that organization; the
-- membership join tables already say which accounts are organizations.

CREATE TABLE IF NOT EXISTS public.music_generations (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The owning account, after the standard account_id override resolves.
    -- A person or an organization; nothing here needs to know which.
    account_id       UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    -- TEXT + CHECK, not a Postgres enum: only two enum types exist across all
    -- of these migrations and both are legacy.
    status           TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    -- Provenance for immutable content. A song made by one model has to stay
    -- attributable once a second model exists, and it cannot be backfilled.
    model            TEXT NOT NULL DEFAULT 'minimax/music-3',
    prompt           TEXT NOT NULL,
    lyrics           TEXT NOT NULL,
    -- Actual length, reported by fal. Rendered on every gallery card, so it is
    -- stored rather than fetched per row.
    duration_seconds NUMERIC CHECK (duration_seconds IS NULL OR duration_seconds > 0),
    -- Key inside the public-uploads bucket, once the audio is mirrored. NULL
    -- until completed. UNIQUE because two rows pointing at one object would
    -- make deletion unsafe.
    storage_key      TEXT UNIQUE,
    -- Handles to the two external systems this generation touches: fal for the
    -- request itself, Vercel Workflow for the run that drove it. Different
    -- systems answer different questions, so both are kept.
    fal_request_id   TEXT,
    workflow_run_id  TEXT,
    -- Why a generation failed, in terms a user can act on. The one thing the
    -- workflow cannot answer cheaply: the gallery lists failures and cannot
    -- make a call per row, and a failed row with no reason is a dead end.
    error_message    TEXT,
    created_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- The gallery read: one account's generations, newest first.
CREATE INDEX IF NOT EXISTS music_generations_account_created_idx
  ON public.music_generations (account_id, created_at DESC);

-- Sweeping for work still in flight.
CREATE INDEX IF NOT EXISTS music_generations_status_created_idx
  ON public.music_generations (status, created_at DESC);

-- CREATE TRIGGER has no IF NOT EXISTS, so re-applying this file would fail
-- here even though every statement above is idempotent.
DROP TRIGGER IF EXISTS set_updated_at ON public.music_generations;
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.music_generations
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- RLS on with zero policies: denies anon and authenticated outright while
-- service_role, which is how the API reads and writes, bypasses it. These rows
-- hold user-authored prompts and lyrics plus a storage key, so leaving the
-- table reachable through PostgREST with the anon key would expose one
-- account's songs to any other.
ALTER TABLE public.music_generations ENABLE ROW LEVEL SECURITY;
