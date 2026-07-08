-- Repoint funnel-minted duplicate roster artists to their canonical twin
-- (recoupable/chat#1850 P1).
--
-- The marketing valuation funnel's linkArtistToAccount did an unconditional
-- `POST /api/artists {name}` per signup, minting a brand-new artist account
-- that owns zero song_artists links — while the songs measured for the run are
-- already linked to the *canonical* artist account created at capture time.
-- Result: the artist-scoped homepage hero reads 0 songs / $0 for every funnel
-- account (repro: catalog 4b934253… is 67 songs / 557,513,905 streams
-- unfiltered but 0/0 filtered by the account's own duplicate artist).
--
-- Scope (conservative, measured 2026-07-08 on prod: 18 candidate roster rows):
-- a duplicate qualifies only when ALL of the following hold —
--   1. it is referenced in account_artist_ids (it sits on someone's roster);
--   2. it has zero song_artists links (it owns none of the songs graph);
--   3. it carries a Spotify artist social (the funnel's fire-and-forget PATCH —
--      the funnel-created signature);
--   4. exactly one other account shares its exact accounts.name AND has
--      song_artists links (the unambiguous canonical twin);
--   5. every account referencing it also owns a catalog (the funnel claim
--      signature — leads that ran a valuation but never claimed are excluded;
--      their duplicate lights no surface and a later claim attaches the
--      canonical server-side per recoupable/api claim-time attach).
--
-- Actions:
--   * Repoint account_artist_ids.artist_id from the duplicate to the canonical
--     — at most one row per (account, canonical) pair (account_artist_ids has
--     no unique constraint on that pair, so we must not mint duplicates), and
--     skipped entirely when the account already has the canonical linked.
--   * Copy the duplicate's Spotify social onto the canonical when the
--     canonical has none (ingest-created canonicals have zero socials today,
--     which is what breaks find-by-Spotify-id resolution).
--   * Duplicate accounts are NOT deleted — orphaning them is enough; deletion
--     is a follow-up.
--
-- Idempotent: re-running finds repointed duplicates orphaned (condition 1
-- fails) and leftover second-dupe rows skip on the already-has-canonical
-- guard; the social copy is guarded by NOT EXISTS.

-- Duplicate -> canonical twin map.
CREATE TEMP TABLE funnel_dupe_map ON COMMIT DROP AS
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
CREATE TEMP TABLE repoint_rows ON COMMIT DROP AS
SELECT DISTINCT ON (aai.account_id, m.canonical_id)
       aai.id AS row_id, aai.account_id, m.dupe_id, m.canonical_id
FROM public.account_artist_ids aai
JOIN funnel_dupe_map m ON m.dupe_id = aai.artist_id
WHERE NOT EXISTS (
  SELECT 1 FROM public.account_artist_ids k
  WHERE k.account_id = aai.account_id AND k.artist_id = m.canonical_id)
ORDER BY aai.account_id, m.canonical_id, aai.updated_at ASC, aai.id ASC;

UPDATE public.account_artist_ids aai
SET artist_id = r.canonical_id,
    updated_at = now()
FROM repoint_rows r
WHERE aai.id = r.row_id;

-- Give the canonical the duplicate's Spotify social when it lacks one
-- (one deterministic pick per canonical).
INSERT INTO public.account_socials (account_id, social_id)
SELECT DISTINCT ON (m.canonical_id) m.canonical_id, asoc.social_id
FROM funnel_dupe_map m
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
  FROM repoint_rows r
  JOIN public.account_artist_ids aai ON aai.id = r.row_id
  WHERE aai.artist_id <> r.canonical_id;
  IF remaining > 0 THEN
    RAISE EXCEPTION 'repoint_funnel_duplicate_roster_artists: % rows not repointed', remaining;
  END IF;
END $$;
