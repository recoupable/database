-- posts: engagement counts per post, and updated_at becomes the publish date
-- it already was in practice (recoupable/app#2018 keystone; contract
-- recoupable/docs#316).
--
-- Every platform scraper returns engagement with each post (TikTok playCount/
-- diggCount/commentCount/shareCount, YouTube viewCount/likes/commentsCount,
-- X viewCount/likeCount/replyCount/retweetCount, Instagram likesCount/
-- commentsCount, LinkedIn likes/comments/shares) and the api threw all of it
-- away after the run was read, so "which post outperformed this week" needed
-- a fresh scrape every time. Four named columns rather than a metrics JSONB
-- so the table can be ordered and filtered on them directly.
--
-- Nullable: Threads and Facebook report nothing per post, rows written
-- before this migration have nothing to backfill from, and NULL keeps
-- "not reported" distinct from 0.

ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS views    BIGINT CHECK (views    IS NULL OR views    >= 0),
    ADD COLUMN IF NOT EXISTS likes    BIGINT CHECK (likes    IS NULL OR likes    >= 0),
    ADD COLUMN IF NOT EXISTS comments BIGINT CHECK (comments IS NULL OR comments >= 0),
    ADD COLUMN IF NOT EXISTS reposts  BIGINT CHECK (reposts  IS NULL OR reposts  >= 0);

-- updated_at on posts has always been written by the handlers as the post's
-- platform publish timestamp (it is what GET /api/artists/{id}/posts orders
-- by), never as a row-modification time. The BEFORE UPDATE trigger from the
-- create migration (20250130161836) would overwrite that value with now() on
-- the first re-scrape that refreshes engagement, turning every re-scraped
-- post into "published just now". Drop it; the api sets updated_at
-- explicitly on every upsert.
DROP TRIGGER IF EXISTS set_updated_at ON public.posts;
