-- Canonicalize socials.profile_url twitter.com/* -> x.com/* (recoupable/chat#1851).
--
-- The Apify X scraper echoes profiles on the x.com domain while ~24k stored
-- rows use twitter.com keys; upsertSocials conflicts on profile_url, so scrape
-- results landed on x.com twin rows that the artists' account_socials never
-- pointed at (e.g. x.com/disclosure carried 483,103 followers while the
-- connected twitter.com/disclosure row showed 0). api PR recoupable/api#755
-- canonicalizes new writes to x.com inside normalizeProfileUrl; this migration
-- brings the existing rows onto the same key. Decision 2026-07-06: canonical
-- domain is x.com (official brand + what the actor emits).
--
-- Two cases, measured 2026-07-06 on prod:
--   1. twitter row WITH an x.com twin (403 rows): the twin is the keeper —
--      repoint FKs (guarding unique constraints), backfill any fresher scrape
--      fields from the loser, delete the loser.
--   2. twitter row WITHOUT a twin (23,622 rows): rename the key in place.
--
-- FK columns referencing socials.id: account_socials.social_id,
-- agent_status.social_id, fan_segments.fan_social_id, post_comments.social_id,
-- social_fans.artist_social_id, social_fans.fan_social_id,
-- social_posts.social_id. Unique guards required for
-- fan_segments(segment_id, fan_social_id), social_fans(artist_social_id,
-- fan_social_id), post_comments(post_id, social_id, comment, commented_at);
-- account_socials and social_posts have no composite unique constraint but we
-- guard on their logical keys anyway so the merge doesn't mint duplicates.

-- Map: loser (twitter.com row) -> keeper (x.com twin).
CREATE TEMP TABLE twitter_x_twins ON COMMIT DROP AS
SELECT t.id AS loser_id, x.id AS keeper_id,
       t.updated_at AS loser_updated_at, x.updated_at AS keeper_updated_at
FROM public.socials t
JOIN public.socials x
  ON x.profile_url = 'x.com/' || substring(t.profile_url FROM 13)
WHERE t.profile_url LIKE 'twitter.com/%';

-- 1a. Backfill scrape fields onto the keeper when the loser is fresher
--     (rare: the twin normally holds the fresh scrape and the loser is stale).
UPDATE public.socials x
SET username         = COALESCE(NULLIF(t.username, ''), x.username),
    avatar           = COALESCE(t.avatar, x.avatar),
    bio              = COALESCE(t.bio, x.bio),
    "followerCount"  = GREATEST(COALESCE(t."followerCount", 0), COALESCE(x."followerCount", 0)),
    "followingCount" = GREATEST(COALESCE(t."followingCount", 0), COALESCE(x."followingCount", 0)),
    region           = COALESCE(t.region, x.region),
    updated_at       = GREATEST(t.updated_at, x.updated_at)
FROM twitter_x_twins m
JOIN public.socials t ON t.id = m.loser_id
WHERE x.id = m.keeper_id
  AND m.loser_updated_at > m.keeper_updated_at;

-- 1b. Repoint FKs from loser to keeper, deleting rows that would duplicate an
--     existing keeper-side row on the table's logical key.

-- account_socials (logical key: account_id + social_id)
DELETE FROM public.account_socials a
USING twitter_x_twins m
WHERE a.social_id = m.loser_id
  AND EXISTS (SELECT 1 FROM public.account_socials k
              WHERE k.account_id = a.account_id AND k.social_id = m.keeper_id);
UPDATE public.account_socials a
SET social_id = m.keeper_id
FROM twitter_x_twins m
WHERE a.social_id = m.loser_id;

-- social_posts (logical key: post_id + social_id)
DELETE FROM public.social_posts sp
USING twitter_x_twins m
WHERE sp.social_id = m.loser_id
  AND EXISTS (SELECT 1 FROM public.social_posts k
              WHERE k.post_id = sp.post_id AND k.social_id = m.keeper_id);
UPDATE public.social_posts sp
SET social_id = m.keeper_id
FROM twitter_x_twins m
WHERE sp.social_id = m.loser_id;

-- post_comments (unique: post_id, social_id, comment, commented_at)
DELETE FROM public.post_comments pc
USING twitter_x_twins m
WHERE pc.social_id = m.loser_id
  AND EXISTS (SELECT 1 FROM public.post_comments k
              WHERE k.post_id = pc.post_id AND k.social_id = m.keeper_id
                AND k.comment = pc.comment AND k.commented_at = pc.commented_at);
UPDATE public.post_comments pc
SET social_id = m.keeper_id
FROM twitter_x_twins m
WHERE pc.social_id = m.loser_id;

-- social_fans.artist_social_id (unique: artist_social_id + fan_social_id)
DELETE FROM public.social_fans sf
USING twitter_x_twins m
WHERE sf.artist_social_id = m.loser_id
  AND EXISTS (SELECT 1 FROM public.social_fans k
              WHERE k.artist_social_id = m.keeper_id AND k.fan_social_id = sf.fan_social_id);
UPDATE public.social_fans sf
SET artist_social_id = m.keeper_id
FROM twitter_x_twins m
WHERE sf.artist_social_id = m.loser_id;

-- social_fans.fan_social_id (same unique, other side)
DELETE FROM public.social_fans sf
USING twitter_x_twins m
WHERE sf.fan_social_id = m.loser_id
  AND EXISTS (SELECT 1 FROM public.social_fans k
              WHERE k.artist_social_id = sf.artist_social_id AND k.fan_social_id = m.keeper_id);
UPDATE public.social_fans sf
SET fan_social_id = m.keeper_id
FROM twitter_x_twins m
WHERE sf.fan_social_id = m.loser_id;

-- fan_segments.fan_social_id (unique: segment_id + fan_social_id)
DELETE FROM public.fan_segments fs
USING twitter_x_twins m
WHERE fs.fan_social_id = m.loser_id
  AND EXISTS (SELECT 1 FROM public.fan_segments k
              WHERE k.segment_id = fs.segment_id AND k.fan_social_id = m.keeper_id);
UPDATE public.fan_segments fs
SET fan_social_id = m.keeper_id
FROM twitter_x_twins m
WHERE fs.fan_social_id = m.loser_id;

-- agent_status (no composite unique)
UPDATE public.agent_status ag
SET social_id = m.keeper_id
FROM twitter_x_twins m
WHERE ag.social_id = m.loser_id;

-- 1c. Delete the merged losers.
DELETE FROM public.socials s
USING twitter_x_twins m
WHERE s.id = m.loser_id;

-- 2. Twinless twitter rows: rename the key in place.
UPDATE public.socials
SET profile_url = 'x.com/' || substring(profile_url FROM 13),
    updated_at  = updated_at  -- key rename only; not a data refresh
WHERE profile_url LIKE 'twitter.com/%';

-- Post-condition (also the issue's Done-when): no handle exists on both
-- domains, and no twitter.com keys remain.
DO $$
DECLARE remaining integer;
BEGIN
  SELECT count(*) INTO remaining FROM public.socials WHERE profile_url LIKE 'twitter.com/%';
  IF remaining > 0 THEN
    RAISE EXCEPTION 'canonicalize_twitter_to_x: % twitter.com rows remain', remaining;
  END IF;
END $$;
