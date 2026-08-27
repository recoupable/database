-- Create social_snapshots: one follower-count point per social per day
-- (recoupable/app#2018 keystone; contract recoupable/docs#316; originally
-- app#2026).
--
-- socials.followerCount is overwritten by every scrape (api upsertSocials on
-- profile_url), so the previous value is gone the moment a new scrape lands.
-- A weekly report that wants "followers this week vs last week" has to keep
-- its own file in a sandbox, and no other surface (artist page, chat) can
-- show a trend at all. This table keeps every value the platform paid for.
--
-- Shape: append-only, written by the api socials-upsert wrapper on every
-- scrape that reports a follower count, across all seven platform handlers.
-- captured_on is the dedupe key: one row per social per UTC day, and the
-- latest scrape that day wins (the api upserts on (social_id, captured_on)).
-- A date column with a plain unique constraint instead of an expression index
-- so the upsert's ON CONFLICT target is a column list, not an expression.
--
-- Read by GET /api/artists/{id}/socials?history=<days> as the `history` array
-- on each profile. `socials` keeps the latest value for existing readers.

CREATE TABLE IF NOT EXISTS public.social_snapshots (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    social_id       UUID NOT NULL REFERENCES public.socials(id) ON DELETE CASCADE,
    -- The scrape's completion time; the day partition is derived once here so
    -- readers never re-derive it in a different timezone.
    captured_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    captured_on     DATE NOT NULL DEFAULT (now() AT TIME ZONE 'utc')::date,
    follower_count  BIGINT NOT NULL CHECK (follower_count >= 0),
    following_count BIGINT CHECK (following_count IS NULL OR following_count >= 0),
    -- Lifetime post count where the platform reports one (Instagram
    -- postsCount, TikTok authorMeta.video, YouTube channelTotalVideos, X
    -- statusesCount); NULL on LinkedIn, Threads, Facebook.
    post_count      BIGINT CHECK (post_count IS NULL OR post_count >= 0),
    UNIQUE (social_id, captured_on)
);

-- The history read: one social's points, newest first, bounded by days.
CREATE INDEX IF NOT EXISTS social_snapshots_social_captured_idx
    ON public.social_snapshots (social_id, captured_at DESC);

-- RLS on with zero policies: the api reads and writes via the service role,
-- which bypasses it; anon/authenticated get nothing, matching socials'
-- neighbours (playcount_snapshots, music_generations).
ALTER TABLE public.social_snapshots ENABLE ROW LEVEL SECURITY;

-- Backfill: history starts today rather than at the next scrape. One row per
-- social that already has a follower count, stamped with the socials row's
-- updated_at (the last scrape that wrote it). Idempotent via the unique key.
INSERT INTO public.social_snapshots (social_id, captured_at, captured_on, follower_count, following_count)
SELECT s.id,
       s.updated_at,
       (s.updated_at AT TIME ZONE 'utc')::date,
       s."followerCount",
       CASE WHEN s."followingCount" >= 0 THEN s."followingCount" END
FROM public.socials s
WHERE s."followerCount" IS NOT NULL AND s."followerCount" >= 0
ON CONFLICT (social_id, captured_on) DO NOTHING;
