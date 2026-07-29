-- Collapse duplicate artist accounts onto one canonical per Spotify id
-- (recoupable/chat#1889 row 9; decision 2026-07-29: one canonical artist per
-- Spotify id, shared across accounts via account_artist_ids).
--
-- Every add path that minted its own artist row per signup (marketing funnel,
-- chat add dialog, onboarding typeahead, valuation fallback) left multiple
-- artist accounts carrying the same Spotify artist social. That makes every
-- find-by-Spotify-id lookup ambiguous, which is how rosters doubled
-- (api#791 / api#792 / api#793 history on chat#1889).
--
-- Measured 2026-07-29 on prod: 79 Spotify ids carry >1 linked artist account;
-- 204 artist rows total; 125 duplicates to orphan.
--
-- Canonical pick, per Spotify id (all links grouped on the id extracted from
-- lower(profile_url), since case variants of the same id exist):
--   1. an artist that owns song_artists links (the songs-graph owner) wins;
--   2. tie-break: earliest socials.updated_at (the oldest profile row);
--   3. if MORE THAN ONE graph owner exists for the id, the id is skipped
--      entirely (ambiguous — needs a human).
--
-- Actions (mirrors 20260707190000_repoint_funnel_duplicate_roster_artists):
--   * Repoint account_artist_ids.artist_id from each duplicate to the
--     canonical — at most one row per (account, canonical), skipped when the
--     account already rosters the canonical; leftover rows are deleted.
--   * Delete the duplicates' account_socials links so the Spotify-id -> artist
--     resolution becomes unique.
--   * Copy a duplicate's Spotify social link onto the canonical when the
--     canonical has none for that id (guarded by NOT EXISTS).
--   * Duplicate accounts are NOT deleted — orphaning is enough; deletion has
--     FK blast radius and is a separate follow-up.
--
-- Idempotent: a second run finds no id with >1 linked artist (the dupes'
-- account_socials links are gone), so every temp table is empty.

-- Spotify id -> linked artist accounts.
CREATE TEMP TABLE spotify_artist_links ON COMMIT DROP AS
SELECT substring(lower(s.profile_url) from 'open\.spotify\.com/artist/([a-z0-9]+)') AS spotify_id,
       asoc.account_id AS artist_id,
       min(s.updated_at) AS social_at,
       bool_or(EXISTS (SELECT 1 FROM public.song_artists sa WHERE sa.artist = asoc.account_id)) AS owns_songs
FROM public.socials s
JOIN public.account_socials asoc ON asoc.social_id = s.id
WHERE s.profile_url ILIKE '%open.spotify.com/artist/%'
GROUP BY 1, 2;

-- Canonical per Spotify id; ids with multiple graph owners are excluded.
CREATE TEMP TABLE spotify_canonicals ON COMMIT DROP AS
SELECT spotify_id,
       (array_agg(artist_id ORDER BY owns_songs DESC, social_at ASC, artist_id))[1] AS canonical_id
FROM spotify_artist_links
WHERE spotify_id IS NOT NULL
GROUP BY spotify_id
HAVING count(*) > 1
   AND count(*) FILTER (WHERE owns_songs) <= 1;

-- Duplicate -> canonical map.
CREATE TEMP TABLE spotify_dupe_map ON COMMIT DROP AS
SELECT l.artist_id AS dupe_id, c.canonical_id, c.spotify_id
FROM spotify_artist_links l
JOIN spotify_canonicals c ON c.spotify_id = l.spotify_id
WHERE l.artist_id <> c.canonical_id;

-- 1a. Repoint roster rows to the canonical where the account doesn't have it.
-- At most ONE row per (account, canonical) — an account can roster SEVERAL
-- duplicates of the same canonical (measured on prod: two accounts hold 3
-- each), and account_artist_ids has UNIQUE (account_id, artist_id), so a
-- per-dupe update would collide with itself mid-statement. DISTINCT ON picks
-- the survivor; 1b deletes the rest.
UPDATE public.account_artist_ids aai
SET artist_id = pick.canonical_id
FROM (
  SELECT DISTINCT ON (aai2.account_id, m.canonical_id) aai2.id, m.canonical_id
  FROM public.account_artist_ids aai2
  JOIN spotify_dupe_map m ON m.dupe_id = aai2.artist_id
  WHERE NOT EXISTS (
    SELECT 1 FROM public.account_artist_ids existing
    WHERE existing.account_id = aai2.account_id
      AND existing.artist_id = m.canonical_id)
  ORDER BY aai2.account_id, m.canonical_id, aai2.id
) pick
WHERE aai.id = pick.id;

-- 1b. Delete leftover roster rows still pointing at a duplicate
--     (the account already rosters the canonical).
DELETE FROM public.account_artist_ids aai
USING spotify_dupe_map m
WHERE aai.artist_id = m.dupe_id;

-- 2a. Give the canonical a Spotify social for the id when it has none.
INSERT INTO public.account_socials (account_id, social_id)
SELECT DISTINCT ON (m.canonical_id) m.canonical_id, asoc.social_id
FROM spotify_dupe_map m
JOIN public.account_socials asoc ON asoc.account_id = m.dupe_id
JOIN public.socials s ON s.id = asoc.social_id
WHERE s.profile_url ILIKE '%open.spotify.com/artist/%'
  AND NOT EXISTS (
    SELECT 1
    FROM public.account_socials c
    JOIN public.socials cs ON cs.id = c.social_id
    WHERE c.account_id = m.canonical_id
      AND substring(lower(cs.profile_url) from 'open\.spotify\.com/artist/([a-z0-9]+)') = m.spotify_id)
ORDER BY m.canonical_id, asoc.social_id;

-- 2b. Remove the duplicates' Spotify social links so resolution is unique.
DELETE FROM public.account_socials asoc
USING spotify_dupe_map m, public.socials s
WHERE asoc.account_id = m.dupe_id
  AND s.id = asoc.social_id
  AND s.profile_url ILIKE '%open.spotify.com/artist/%';
