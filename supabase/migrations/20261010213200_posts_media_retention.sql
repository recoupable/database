-- posts: retain the captions, media references and publish dates the
-- Instagram profile scraper already reports (recoupable/app#2132, Context
-- Engine CE16 "retain artist social images").
--
-- The Apify profile actor returns caption, displayUrl, images, alt,
-- dimensions, timestamp and carousel children with every post, and the api
-- threw all of it away after the run was read. A creative task could only
-- reference one mirrored avatar plus bare engagement counts, so there was no
-- stored evidence for "what does this artist's current era look like".
--
-- Boundaries of what these columns hold:
--   * media entries are provider URLs only, never retained bytes:
--       {position, kind: image|video|unknown, provider_url, width, height,
--        alt, source: 'apify_instagram'}
--     provider_url is always a still image: for kind = video it is the cover
--     frame the scraper reports, and the video stream itself is not
--     retained. Provider CDN URLs may expire. Refreshing them or retaining asset bytes
--     is a later slice built on the private-original receipt work, not here.
--   * Everything in these columns is reference-only material. Retained
--     internet imagery is not a production asset; no approval state is
--     recorded here.
--   * NULL caption means "not captured" (row scraped before this migration,
--     or the actor did not report one), distinct from an empty-string
--     caption the platform actually returned.
--   * published_at is the platform publish timestamp when reported.
--     updated_at keeps its existing meaning for the posts contract
--     (recoupable/docs#316) and is not touched.
--   * media_observed_at is when the api last wrote media for the row, so a
--     reader can tell fresh provider URLs from stale ones.
--
-- Writers must name the same columns for every row of one bulk upsert:
-- PostgREST fills a column a row omits with NULL, which media NOT NULL
-- rejects. The api groups rows by column set before upserting.
--
-- Additive and idempotent: ADD COLUMN IF NOT EXISTS skips existing columns
-- and the CHECK is added only when missing. No backfill (there is nothing to
-- backfill from), no trigger changes (20260827120100 already dropped
-- set_updated_at), no RLS or grant changes (existing table-level grants
-- already cover the new columns).
--
-- The constant DEFAULT makes the new columns a catalog-only change. The CHECK
-- is added NOT VALID here and validated in the next migration file
-- (20261010213201), so the scan of existing posts runs under SHARE UPDATE
-- EXCLUSIVE instead of the ACCESS EXCLUSIVE lock this ALTER holds, and
-- concurrent scraper writes are not blocked. New and updated rows are
-- checked immediately; every existing row gets '[]', which satisfies it.

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS caption           text,
    ADD COLUMN IF NOT EXISTS published_at      timestamptz,
    ADD COLUMN IF NOT EXISTS media             jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS media_observed_at timestamptz;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.posts'::regclass AND conname = 'posts_media_is_array'
    ) THEN
        ALTER TABLE public.posts
            ADD CONSTRAINT posts_media_is_array CHECK (jsonb_typeof(media) = 'array') NOT VALID;
    END IF;
END $$;

COMMENT ON COLUMN public.posts.caption IS
    'Platform caption as scraped; NULL = not captured, '''' = platform returned an empty caption. Reference-only evidence.';
COMMENT ON COLUMN public.posts.published_at IS
    'Platform publish timestamp when the scraper reported one; NULL = unknown.';
COMMENT ON COLUMN public.posts.media IS
    'Array of provider media references {position, kind, provider_url, width, height, alt, source}; provider_url is a still image (the cover frame when kind = video; the video stream is not retained); provider URLs only, no retained bytes, reference-only, URLs may expire.';
COMMENT ON COLUMN public.posts.media_observed_at IS
    'When the api last wrote caption/media for this row from a scrape; NULL = never retained.';
