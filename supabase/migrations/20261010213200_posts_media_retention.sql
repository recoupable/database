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
--     Provider CDN URLs may expire. Refreshing them or retaining asset bytes
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
-- Additive and idempotent: ADD COLUMN IF NOT EXISTS skips an existing column
-- together with its inline constraint. No backfill (there is nothing to
-- backfill from), no trigger changes (20260827120100 already dropped
-- set_updated_at), no RLS or grant changes (existing table-level grants
-- already cover the new columns).

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS caption           text,
    ADD COLUMN IF NOT EXISTS published_at      timestamptz,
    ADD COLUMN IF NOT EXISTS media             jsonb NOT NULL DEFAULT '[]'::jsonb
        CONSTRAINT posts_media_is_array CHECK (jsonb_typeof(media) = 'array'),
    ADD COLUMN IF NOT EXISTS media_observed_at timestamptz;

COMMENT ON COLUMN public.posts.caption IS
    'Platform caption as scraped; NULL = not captured, '''' = platform returned an empty caption. Reference-only evidence.';
COMMENT ON COLUMN public.posts.published_at IS
    'Platform publish timestamp when the scraper reported one; NULL = unknown.';
COMMENT ON COLUMN public.posts.media IS
    'Array of provider media references {position, kind, provider_url, width, height, alt, source}; provider URLs only, no retained bytes, reference-only, URLs may expire.';
COMMENT ON COLUMN public.posts.media_observed_at IS
    'When the api last wrote caption/media for this row from a scrape; NULL = never retained.';
