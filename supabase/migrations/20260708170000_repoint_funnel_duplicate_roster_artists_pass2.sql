-- Repoint funnel-minted duplicate roster artists to their canonical twin — PASS 2
-- (recoupable/chat#1859; follow-up to 20260707190000).
--
-- The original repoint (20260707190000) ran on prod 2026-07-08. Between that run
-- and the deploy of marketing#46 (which deletes linkArtistToAccount and stops the
-- per-signup mint), the funnel kept minting duplicate roster artists — and some
-- pre-existing leads only became in-scope afterward (condition 5 flips the moment
-- their account claims a catalog). Post-merge verification of #43 found the
-- health-check detection query re-qualifying stragglers
-- (https://github.com/recoupable/chat/issues/1859#issuecomment-4916313589).
--
-- marketing#46 is now deployed, so the forward mint has stopped and this pass
-- converges. This migration re-runs the SAME idempotent repoint as
-- 20260707190000 — verbatim logic, conservative 5-condition signature — to
-- repoint the remaining Category A duplicates (an account holding the duplicate
-- but NOT yet the canonical; measured 2026-07-08 on prod: 2 rows). Accounts that
-- already hold the canonical (Category B) are skipped here by design and cleaned
-- up in the sibling cleanup-delete migration (20260708170500), which the repoint
-- cannot fix.
--
-- Scope (identical to 20260707190000): a duplicate qualifies only when ALL hold —
--   1. it is referenced in account_artist_ids (it sits on someone's roster);
--   2. it has zero song_artists links (it owns none of the songs graph);
--   3. it carries a Spotify artist social (the funnel's fire-and-forget PATCH);
--   4. exactly one other account shares its exact accounts.name AND has
--      song_artists links (the unambiguous canonical twin);
--   5. every account referencing it also owns a catalog (the funnel claim signature).
--
-- Actions: repoint account_artist_ids.artist_id duplicate -> canonical (at most
-- one row per (account, canonical) pair, skipped when the account already has the
-- canonical); copy the duplicate's Spotify social onto the canonical when it has
-- none. Duplicate accounts are NOT deleted here (see the sibling cleanup migration).
--
-- Idempotent: re-running finds repointed duplicates orphaned (condition 1 fails)
-- and leftover second-dupe rows skip on the already-has-canonical guard; the
-- social copy is guarded by NOT EXISTS.

-- Duplicate -> canonical twin map.
CREATE TEMP TABLE funnel_dupe_map_pass2 ON COMMIT DROP AS
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
HAVING count(*) = 1; -- unambiguous twin only (the aggregate is then the single match)

-- One repointable roster row per (account, canonical): deterministic pick
-- (oldest first), skipping accounts that already have the canonical.
CREATE TEMP TABLE repoint_rows_pass2 ON COMMIT DROP AS
SELECT DISTINCT ON (aai.account_id, m.canonical_id)
       aai.id AS row_id, aai.account_id, m.dupe_id, m.canonical_id
FROM public.account_artist_ids aai
JOIN funnel_dupe_map_pass2 m ON m.dupe_id = aai.artist_id
WHERE NOT EXISTS (
  SELECT 1 FROM public.account_artist_ids k
  WHERE k.account_id = aai.account_id AND k.artist_id = m.canonical_id)
ORDER BY aai.account_id, m.canonical_id, aai.updated_at ASC, aai.id ASC;

UPDATE public.account_artist_ids aai
SET artist_id = r.canonical_id,
    updated_at = now()
FROM repoint_rows_pass2 r
WHERE aai.id = r.row_id;

-- Give the canonical the duplicate's Spotify social when it lacks one
-- (one deterministic pick per canonical).
INSERT INTO public.account_socials (account_id, social_id)
SELECT DISTINCT ON (m.canonical_id) m.canonical_id, asoc.social_id
FROM funnel_dupe_map_pass2 m
JOIN public.account_socials asoc ON asoc.account_id = m.dupe_id
JOIN public.socials s
  ON s.id = asoc.social_id
 AND s.profile_url ILIKE '%open.spotify.com/artist/%'
WHERE NOT EXISTS (
  SELECT 1
  FROM public.account_socials k
  JOIN public.socials ks ON ks.id = k.social_id
  WHERE k.account_id = m.canonical_id
    AND ks.profile_url ILIKE '%open.spotify.com/artist/%')
ORDER BY m.canonical_id, asoc.id;

-- Post-condition: every selected roster row now points at its canonical.
DO $$
DECLARE remaining integer;
BEGIN
  SELECT count(*) INTO remaining
  FROM repoint_rows_pass2 r
  JOIN public.account_artist_ids aai ON aai.id = r.row_id
  WHERE aai.artist_id <> r.canonical_id;
  IF remaining > 0 THEN
    RAISE EXCEPTION 'repoint_funnel_duplicate_roster_artists_pass2: % rows not repointed', remaining;
  END IF;
END $$;
