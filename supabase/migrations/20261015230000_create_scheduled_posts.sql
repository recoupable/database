-- Create scheduled_posts: social video posts published now or at publish_at
-- (recoupable/app#2241, contract: recoupable/marketing#154 -> docs#375).
--
-- One row per POST /api/posts call: one finished video and its copy to one
-- connected account on one platform. Platforms fail independently (quota,
-- auth, content rules), so each post carries its own status and can be retried
-- alone; a multi-platform slate is several rows.
--
-- The row is also the run record, the same pattern as music_generations
-- (20260821170000): the API inserts the row and hands its id to a Vercel
-- Workflow, which sleeps until publish_at (if set), publishes through the
-- connector layer and writes the outcome back. The API reads the row, never
-- the Workflow API.
--
-- Copy is stored as submitted because it is what the owner approved and what
-- text_verified compares the live post against. Per-platform length limits
-- (X counts weighted characters) live in the API's validation, not here; the
-- CHECKs below only hold the shape the contract promises.

CREATE TABLE IF NOT EXISTS public.scheduled_posts (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The account whose connection posts (e.g. an artist), after the standard
    -- account_id override resolves.
    account_id            UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    -- Who made the request, when it differs from account_id (an org member
    -- posting for an artist). Kept if the creator's account is deleted later.
    created_by_account_id UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
    -- TEXT + CHECK, not a Postgres enum, as in music_generations. TikTok is a
    -- follow-up (unaudited app), so it is not accepted yet.
    platform              TEXT NOT NULL
        CHECK (platform IN ('instagram', 'x', 'linkedin', 'youtube')),
    -- LinkedIn organization URN when posting as a Page, else NULL.
    sub_account_id        TEXT CHECK (sub_account_id IS NULL OR (platform = 'linkedin' AND btrim(sub_account_id) <> '')),
    -- Fetched at publish time, so a scheduled post depends on it still resolving.
    video_url             TEXT NOT NULL CHECK (btrim(video_url) <> ''),
    -- Reel cover / LinkedIn thumbnail. Never sent for YouTube (API-set Shorts
    -- thumbnails rendered blank, owner rule 2026-10-13), so it is not stored either.
    cover_url             TEXT CHECK (cover_url IS NULL OR platform <> 'youtube'),
    title                 TEXT,
    description           TEXT,
    privacy               TEXT CHECK (privacy IS NULL OR privacy IN ('public', 'unlisted', 'private')),
    tags                  TEXT[],
    -- NULL = published on creation.
    publish_at            TIMESTAMP WITH TIME ZONE,
    status                TEXT NOT NULL
        CHECK (status IN ('scheduled', 'publishing', 'posted', 'failed', 'cancelled')),
    -- Live URL on the platform, once posted.
    post_url              TEXT,
    -- Why publishing failed, as the platform reported it (e.g. YouTube's shared
    -- daily upload quota). A failed row with no reason is a dead end.
    error_message         TEXT,
    -- Whether the live text, re-read after posting, equals the submitted copy.
    -- NULL until checked.
    text_verified         BOOLEAN,
    workflow_run_id       TEXT,
    created_at            TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at            TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),

    -- Required copy per platform, matching the Create Post table.
    CONSTRAINT scheduled_posts_youtube_title
        CHECK (platform <> 'youtube' OR btrim(coalesce(title, '')) <> ''),
    CONSTRAINT scheduled_posts_description_required
        CHECK (platform = 'youtube' OR btrim(coalesce(description, '')) <> ''),
    -- privacy and tags are YouTube-only fields.
    CONSTRAINT scheduled_posts_youtube_only_fields
        CHECK (platform = 'youtube' OR (privacy IS NULL AND tags IS NULL)),
    -- A scheduled post has a time to publish at.
    CONSTRAINT scheduled_posts_scheduled_has_time
        CHECK (status <> 'scheduled' OR publish_at IS NOT NULL),
    CONSTRAINT scheduled_posts_posted_has_url
        CHECK (status <> 'posted' OR btrim(coalesce(post_url, '')) <> ''),
    CONSTRAINT scheduled_posts_failed_has_reason
        CHECK (status <> 'failed' OR btrim(coalesce(error_message, '')) <> '')
);

-- GET /api/posts: one account's posts, newest first.
CREATE INDEX IF NOT EXISTS scheduled_posts_account_created_idx
  ON public.scheduled_posts (account_id, created_at DESC);

-- Sweeping for scheduled work that should have started.
CREATE INDEX IF NOT EXISTS scheduled_posts_scheduled_publish_at_idx
  ON public.scheduled_posts (publish_at)
  WHERE status = 'scheduled';

-- CREATE TRIGGER has no IF NOT EXISTS, so re-applying this file would fail
-- here even though every statement above is idempotent.
DROP TRIGGER IF EXISTS set_updated_at ON public.scheduled_posts;
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.scheduled_posts
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Only the API, as service_role, reads and writes. RLS on with zero policies
-- denies anon and authenticated, and their grants are removed too: rows hold
-- unpublished copy and media URLs for one account.
ALTER TABLE public.scheduled_posts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.scheduled_posts FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.scheduled_posts TO service_role;
