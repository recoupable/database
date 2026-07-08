-- Clean up funnel-duplicate roster leftovers: redundant rows + orphaned dupe
-- artists (recoupable/chat#1859; follow-up to 20260707190000 + 20260708170000).
--
-- 20260707190000 repointed duplicates to the canonical ONLY when the account did
-- not already hold the canonical, and — by design — never deleted anything
-- ("orphaning them is enough; deletion is a follow-up"). Two leftovers remain,
-- neither fixable by re-running the repoint
-- (https://github.com/recoupable/chat/issues/1859#issuecomment-4916313589):
--
--   A. REDUNDANT ROSTER ROWS (Category B). When the account already held the
--      canonical (via api#768 claim-attach or a prior link), the repoint SKIPPED
--      the duplicate row to avoid minting a second (account, canonical) link — so
--      the account keeps a redundant row pointing at the song-less duplicate that
--      the repoint will never touch. Measured 2026-07-08 on prod: 5 rows.
--
--   B. ORPHANED DUPLICATE ARTIST ACCOUNTS. Every repoint (the original 14 + this
--      pass) leaves the duplicate account behind: song-less, catalog-less, still
--      carrying its scraped Spotify social, polluting artist search. Measured
--      2026-07-08 on prod: 16 already orphaned, plus the 5 orphaned by step 1
--      below and the 2 orphaned by the pass-2 repoint (20260708170000).
--
-- This migration completes the deferred cleanup. It runs AFTER the pass-2 repoint
-- (20260708170000 < this file's timestamp), so Category A is already handled and
-- only Category B redundant rows remain to remove.
--
-- Safety: destructive, so tightly guarded and idempotent.
--   * Step 1 removes a roster row ONLY when the same account also holds the
--     canonical twin — so it is never an account's only link to that artist
--     (Category A rows, where the duplicate is the sole link, are untouched here;
--     the pass-2 repoint fixes those).
--   * Step 2 deletes an artist account ONLY when it is a pure funnel artifact:
--     zero song_artists (never a canonical or any real artist), zero
--     account_catalogs, not in artist_organization_ids, carries a Spotify social,
--     has exactly one song-owning same-name twin, and is fully orphaned (zero
--     account_artist_ids references). Deleting it cascades only its own scraped
--     account_socials.
--   Re-running finds nothing (rows/accounts already gone).

-- Duplicate -> canonical twin map (same 5-condition signature as 20260707190000).
CREATE TEMP TABLE cleanup_dupe_map ON COMMIT DROP AS
WITH dupes AS (
  SELECT a.id, a.name
  FROM public.accounts a
  WHERE EXISTS (SELECT 1 FROM public.account_artist_ids aai WHERE aai.artist_id = a.id)
    AND NOT EXISTS (SELECT 1 FROM public.song_artists sa WHERE sa.artist = a.id)
    AND EXISTS (
      SELECT 1
      FROM public.account_socials asoc
      JOIN public.socials s ON s.id = asoc.social_id
      WHERE asoc.account_id = a.id
        AND s.profile_url ILIKE '%open.spotify.com/artist/%')
    AND NOT EXISTS (
      SELECT 1
      FROM public.account_artist_ids aai
      WHERE aai.artist_id = a.id
        AND NOT EXISTS (
          SELECT 1 FROM public.account_catalogs ac WHERE ac.account = aai.account_id))
)
SELECT d.id AS dupe_id, d.name, (array_agg(c.id ORDER BY c.id))[1] AS canonical_id
FROM dupes d
JOIN public.accounts c
  ON c.name = d.name
 AND c.id <> d.id
 AND EXISTS (SELECT 1 FROM public.song_artists sa WHERE sa.artist = c.id)
GROUP BY d.id, d.name
HAVING count(*) = 1;

-- STEP 1: delete redundant duplicate roster rows (account already holds the
-- canonical twin). Capture first, then delete.
CREATE TEMP TABLE redundant_rows ON COMMIT DROP AS
SELECT aai.id AS row_id, aai.account_id, m.dupe_id, m.canonical_id
FROM public.account_artist_ids aai
JOIN cleanup_dupe_map m ON m.dupe_id = aai.artist_id
WHERE EXISTS (
  SELECT 1 FROM public.account_artist_ids k
  WHERE k.account_id = aai.account_id AND k.artist_id = m.canonical_id);

DELETE FROM public.account_artist_ids aai
USING redundant_rows r
WHERE aai.id = r.row_id;

-- STEP 2: delete fully-orphaned funnel-duplicate artist accounts. Independent of
-- the map above so it also sweeps the duplicates orphaned by the original repoint
-- and by the pass-2 repoint, not just the ones step 1 just orphaned.
CREATE TEMP TABLE orphan_dupe_accounts ON COMMIT DROP AS
SELECT a.id
FROM public.accounts a
WHERE NOT EXISTS (SELECT 1 FROM public.account_artist_ids aai WHERE aai.artist_id = a.id)
  AND NOT EXISTS (SELECT 1 FROM public.song_artists sa WHERE sa.artist = a.id)
  AND NOT EXISTS (SELECT 1 FROM public.account_catalogs ac WHERE ac.account = a.id)
  AND NOT EXISTS (SELECT 1 FROM public.artist_organization_ids aoi WHERE aoi.artist_id = a.id)
  AND EXISTS (
    SELECT 1 FROM public.account_socials asoc
    JOIN public.socials s ON s.id = asoc.social_id
    WHERE asoc.account_id = a.id
      AND s.profile_url ILIKE '%open.spotify.com/artist/%')
  AND (SELECT count(*) FROM public.accounts c
       WHERE c.name = a.name AND c.id <> a.id
         AND EXISTS (SELECT 1 FROM public.song_artists sa WHERE sa.artist = c.id)) = 1;

DELETE FROM public.accounts a
USING orphan_dupe_accounts o
WHERE a.id = o.id;

-- Post-condition: no account now holds BOTH a qualifying duplicate row and the
-- canonical (every redundant row was removed).
DO $$
DECLARE remaining integer;
BEGIN
  SELECT count(*) INTO remaining
  FROM public.account_artist_ids aai
  JOIN cleanup_dupe_map m ON m.dupe_id = aai.artist_id
  WHERE EXISTS (
    SELECT 1 FROM public.account_artist_ids k
    WHERE k.account_id = aai.account_id AND k.artist_id = m.canonical_id);
  IF remaining > 0 THEN
    RAISE EXCEPTION 'cleanup_funnel_duplicate_roster_leftovers: % redundant rows remain', remaining;
  END IF;
END $$;
