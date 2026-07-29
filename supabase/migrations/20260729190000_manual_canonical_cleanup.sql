-- Manual canonical-artist cleanup pass (recoupable/chat#1889, follows
-- 20260729060000_collapse_duplicate_spotify_artists; decisions Sweets
-- 2026-07-29).
--
-- Parts:
--   1. Stick Figure: move the roster onto the 195-song graph owner.
--   2. Mac Miller: strip duplicate rows' Spotify socials; delete the
--      artist-rosters-artist edge (an artist account owning a roster row).
--   3. Ed Sheeran / Disclosure split: the 0-song row named "Disclosure"
--      carried Ed Sheeran's Spotify id. Accounts that added Ed Sheeran get a
--      new true Ed Sheeran canonical; the Disclosure row keeps its name and
--      gains its REAL Spotify social.
--   4. Name-keyed collapse: fold rostered zero-song rows sharing a name onto
--      the group's canonical (graph owner first). Guard: never fold a row
--      whose Spotify id conflicts with the canonical's.
--   5. Delete fully-orphaned duplicate accounts (no songs, no roster, no
--      wallet), including their socials/org/info rows.
--
-- Everything folded/deleted is recorded in zz_cleanup_manifest_20260729b
-- BEFORE any mutation. Idempotent: re-running finds empty sets.

-- ---------- Part 0: manifest ----------
CREATE TABLE IF NOT EXISTS public.zz_cleanup_manifest_20260729b (
  captured_at timestamptz DEFAULT now(),
  action text,
  subject uuid,
  detail text
);

-- ---------- Part 1: Stick Figure ----------
INSERT INTO public.zz_cleanup_manifest_20260729b (action, subject, detail)
SELECT 'stick_figure_repoint', aai.account_id, '30d623d9 -> 224251cf'
FROM public.account_artist_ids aai
WHERE aai.artist_id = '30d623d9-00ce-4e6a-862f-7c417ee0376c';

UPDATE public.account_artist_ids aai
SET artist_id = '224251cf-71e8-4ffa-81e7-342bce4f6592'
WHERE aai.artist_id = '30d623d9-00ce-4e6a-862f-7c417ee0376c'
  AND NOT EXISTS (SELECT 1 FROM public.account_artist_ids x
                  WHERE x.account_id = aai.account_id
                    AND x.artist_id = '224251cf-71e8-4ffa-81e7-342bce4f6592');
DELETE FROM public.account_artist_ids
WHERE artist_id = '30d623d9-00ce-4e6a-862f-7c417ee0376c';
DELETE FROM public.account_socials asoc
USING public.socials s
WHERE asoc.account_id = '30d623d9-00ce-4e6a-862f-7c417ee0376c'
  AND s.id = asoc.social_id
  AND s.profile_url ILIKE '%open.spotify.com/artist/%';

-- ---------- Part 2: Mac Miller ----------
INSERT INTO public.zz_cleanup_manifest_20260729b (action, subject, detail)
VALUES ('mac_miller_edge_delete', 'f95b0f73-4ac6-4063-9633-e8b17c5c31e4', 'artist-rosters-artist link to ea6406eb');

DELETE FROM public.account_artist_ids
WHERE account_id = 'f95b0f73-4ac6-4063-9633-e8b17c5c31e4'
  AND artist_id = 'ea6406eb-fe64-43ad-9fad-1ba1961ed971';
DELETE FROM public.account_socials asoc
USING public.socials s
WHERE asoc.account_id IN ('ea6406eb-fe64-43ad-9fad-1ba1961ed971',
                          '20f4d064-7657-429a-ba2f-1062366c74f9',
                          'c0901aad-37f6-4720-a771-4e6a8376e3b0')
  AND s.id = asoc.social_id
  AND s.profile_url ILIKE '%open.spotify.com/artist/%';

-- ---------- Part 3: Ed Sheeran / Disclosure split ----------
-- New true Ed Sheeran canonical (skip if one already exists post-run).
CREATE TEMP TABLE new_ed ON COMMIT DROP AS
SELECT gen_random_uuid() AS id
WHERE NOT EXISTS (
  SELECT 1 FROM public.socials s JOIN public.account_socials a ON a.social_id = s.id
  JOIN public.accounts acc ON acc.id = a.account_id
  WHERE s.profile_url ILIKE '%6eUKZXaKkcviH0Ku9w2n3V%' AND acc.name = 'Ed Sheeran');

INSERT INTO public.accounts (id, name)
SELECT id, 'Ed Sheeran' FROM new_ed;
INSERT INTO public.account_info (account_id)
SELECT id FROM new_ed;

-- Attach the existing Ed Sheeran socials row (newest) to the new canonical.
INSERT INTO public.account_socials (account_id, social_id)
SELECT ne.id, s.id
FROM new_ed ne
JOIN LATERAL (
  SELECT s.id FROM public.socials s
  WHERE s.profile_url ILIKE '%6eUKZXaKkcviH0Ku9w2n3V%'
  ORDER BY s.updated_at DESC LIMIT 1
) s ON true;

INSERT INTO public.zz_cleanup_manifest_20260729b (action, subject, detail)
SELECT 'ed_sheeran_relink', aai.account_id, 'disclosure-row 95bfbf52 -> new Ed Sheeran'
FROM public.account_artist_ids aai
WHERE aai.artist_id = '95bfbf52-a8b9-472b-a61c-2c067f650ffe'
  AND aai.account_id IN ('1ca89eeb-14ab-4a4a-a1c5-2dd41663c039',
                         '848cd58d-700f-4b38-ab4c-d9f526402e3c');

UPDATE public.account_artist_ids aai
SET artist_id = ne.id
FROM new_ed ne
WHERE aai.artist_id = '95bfbf52-a8b9-472b-a61c-2c067f650ffe'
  AND aai.account_id IN ('1ca89eeb-14ab-4a4a-a1c5-2dd41663c039',
                         '848cd58d-700f-4b38-ab4c-d9f526402e3c');

-- Strip the mislinked Ed Sheeran social from the Disclosure row.
DELETE FROM public.account_socials asoc
USING public.socials s
WHERE asoc.account_id = '95bfbf52-a8b9-472b-a61c-2c067f650ffe'
  AND s.id = asoc.social_id
  AND s.profile_url ILIKE '%6eUKZXaKkcviH0Ku9w2n3V%';

-- Give the Disclosure row its real Spotify social (patrick@'s artist).
INSERT INTO public.socials (username, profile_url)
SELECT 'disclosure', 'open.spotify.com/artist/6nS5roXSAGhTGr34W6n7Et'
WHERE NOT EXISTS (SELECT 1 FROM public.socials WHERE profile_url ILIKE '%6nS5roXSAGhTGr34W6n7Et%');
INSERT INTO public.account_socials (account_id, social_id)
SELECT '95bfbf52-a8b9-472b-a61c-2c067f650ffe', s.id
FROM public.socials s
WHERE s.profile_url ILIKE '%6nS5roXSAGhTGr34W6n7Et%'
  AND NOT EXISTS (SELECT 1 FROM public.account_socials x
                  WHERE x.account_id = '95bfbf52-a8b9-472b-a61c-2c067f650ffe' AND x.social_id = s.id)
ORDER BY s.updated_at DESC LIMIT 1;

-- ---------- Part 4: name-keyed collapse of zero-song rows ----------
CREATE TEMP TABLE name_rows ON COMMIT DROP AS
SELECT a.id AS artist_id, lower(trim(a.name)) AS lname,
       (SELECT count(*) FROM public.song_artists sa WHERE sa.artist = a.id) AS songs
FROM public.accounts a
WHERE a.name IS NOT NULL AND trim(a.name) <> ''
  AND EXISTS (SELECT 1 FROM public.account_artist_ids aai WHERE aai.artist_id = a.id);

CREATE TEMP TABLE name_canonicals ON COMMIT DROP AS
SELECT lname, (array_agg(artist_id ORDER BY songs DESC, artist_id))[1] AS canonical_id
FROM name_rows
GROUP BY lname
HAVING count(*) > 1 AND count(*) FILTER (WHERE songs > 0) <= 1;

CREATE TEMP TABLE name_folds ON COMMIT DROP AS
SELECT r.artist_id AS fold_id, c.canonical_id
FROM name_rows r
JOIN name_canonicals c ON c.lname = r.lname
WHERE r.artist_id <> c.canonical_id
  AND r.songs = 0
  -- identity guard: never fold a row whose Spotify id conflicts with the canonical's
  AND NOT EXISTS (
    SELECT 1
    FROM public.account_socials fs JOIN public.socials s ON s.id = fs.social_id
    WHERE fs.account_id = r.artist_id
      AND s.profile_url ILIKE '%open.spotify.com/artist/%'
      AND EXISTS (
        SELECT 1 FROM public.account_socials cs JOIN public.socials s2 ON s2.id = cs.social_id
        WHERE cs.account_id = c.canonical_id
          AND s2.profile_url ILIKE '%open.spotify.com/artist/%'
          AND substring(lower(s2.profile_url) from 'open\.spotify\.com/artist/([a-z0-9]+)')
              <> substring(lower(s.profile_url) from 'open\.spotify\.com/artist/([a-z0-9]+)')));

INSERT INTO public.zz_cleanup_manifest_20260729b (action, subject, detail)
SELECT 'name_fold', fold_id, 'into ' || canonical_id FROM name_folds;

-- Canonical adopts a fold's Spotify social when it has none (Chillpill case).
INSERT INTO public.account_socials (account_id, social_id)
SELECT DISTINCT ON (f.canonical_id) f.canonical_id, fs.social_id
FROM name_folds f
JOIN public.account_socials fs ON fs.account_id = f.fold_id
JOIN public.socials s ON s.id = fs.social_id
WHERE s.profile_url ILIKE '%open.spotify.com/artist/%'
  AND NOT EXISTS (
    SELECT 1 FROM public.account_socials cs JOIN public.socials s2 ON s2.id = cs.social_id
    WHERE cs.account_id = f.canonical_id AND s2.profile_url ILIKE '%open.spotify.com/artist/%')
ORDER BY f.canonical_id, fs.social_id;

UPDATE public.account_artist_ids aai
SET artist_id = pick.canonical_id
FROM (
  SELECT DISTINCT ON (aai2.account_id, f.canonical_id) aai2.id, f.canonical_id
  FROM public.account_artist_ids aai2
  JOIN name_folds f ON f.fold_id = aai2.artist_id
  WHERE NOT EXISTS (SELECT 1 FROM public.account_artist_ids x
                    WHERE x.account_id = aai2.account_id AND x.artist_id = f.canonical_id)
  ORDER BY aai2.account_id, f.canonical_id, aai2.id
) pick
WHERE aai.id = pick.id;
DELETE FROM public.account_artist_ids aai USING name_folds f WHERE aai.artist_id = f.fold_id;
DELETE FROM public.account_socials asoc USING name_folds f, public.socials s
WHERE asoc.account_id = f.fold_id AND s.id = asoc.social_id
  AND s.profile_url ILIKE '%open.spotify.com/artist/%';

-- ---------- Part 4.7: repoint soft references before deleting ----------
-- rooms/memories, scheduled tasks, files, sessions, campaigns, segments and
-- funnel analytics reference artist accounts WITHOUT foreign keys (measured:
-- 3,038 rooms + 30 scheduled_actions on the spotify-orphans alone). Deleting
-- without repointing would dangle chat history and break weekly reports.
CREATE TEMP TABLE canonical_map_raw ON COMMIT DROP AS
SELECT dupe_id AS old_id, canonical_id FROM public.zz_dupe_manifest_20260729
UNION SELECT fold_id, canonical_id FROM name_folds
UNION ALL SELECT '30d623d9-00ce-4e6a-862f-7c417ee0376c'::uuid, '224251cf-71e8-4ffa-81e7-342bce4f6592'::uuid
UNION ALL SELECT 'ea6406eb-fe64-43ad-9fad-1ba1961ed971'::uuid, 'f95b0f73-4ac6-4063-9633-e8b17c5c31e4'::uuid
UNION ALL SELECT '20f4d064-7657-429a-ba2f-1062366c74f9'::uuid, 'f95b0f73-4ac6-4063-9633-e8b17c5c31e4'::uuid
UNION ALL SELECT 'c0901aad-37f6-4720-a771-4e6a8376e3b0'::uuid, 'f95b0f73-4ac6-4063-9633-e8b17c5c31e4'::uuid;

-- Resolve chains: yesterday's spotify collapse can target a canonical that
-- TODAY's name-fold folds further (Chillpill: X -> 9e936829 -> 44451c2e).
-- Follow each mapping to its terminal canonical (bounded depth).
CREATE TEMP TABLE canonical_map ON COMMIT DROP AS
WITH RECURSIVE resolve AS (
  SELECT old_id, canonical_id, 1 AS depth FROM canonical_map_raw
  UNION ALL
  SELECT r.old_id, m.canonical_id, r.depth + 1
  FROM resolve r JOIN canonical_map_raw m ON m.old_id = r.canonical_id
  WHERE r.depth < 5
)
SELECT DISTINCT ON (old_id) old_id, canonical_id
FROM resolve ORDER BY old_id, depth DESC;

UPDATE public.rooms r SET artist_id = m.canonical_id FROM canonical_map m WHERE r.artist_id = m.old_id;
UPDATE public.scheduled_actions t SET artist_account_id = m.canonical_id FROM canonical_map m WHERE t.artist_account_id = m.old_id;
UPDATE public.files f SET artist_account_id = m.canonical_id FROM canonical_map m WHERE f.artist_account_id = m.old_id;
UPDATE public.sessions se SET artist_id = m.canonical_id FROM canonical_map m WHERE se.artist_id = m.old_id;
UPDATE public.campaigns c SET artist_id = m.canonical_id FROM canonical_map m WHERE c.artist_id = m.old_id;
-- artist_segments' timestamps trigger references a created_at column the
-- table doesn't have, so ANY update on it errors (live prod bug, tracked on
-- chat#1889). Disable its user triggers for this one statement.
ALTER TABLE public.artist_segments DISABLE TRIGGER USER;
UPDATE public.artist_segments a SET artist_account_id = m.canonical_id FROM canonical_map m WHERE a.artist_account_id = m.old_id;
ALTER TABLE public.artist_segments ENABLE TRIGGER USER;
UPDATE public.funnel_analytics fa SET artist_id = m.canonical_id FROM canonical_map m WHERE fa.artist_id = m.old_id;

-- ---------- Part 5: delete fully-orphaned duplicate accounts ----------
CREATE TEMP TABLE delete_set ON COMMIT DROP AS
SELECT DISTINCT d.id
FROM (
  SELECT dupe_id AS id FROM public.zz_dupe_manifest_20260729
  UNION SELECT fold_id FROM name_folds
  UNION SELECT unnest(ARRAY['30d623d9-00ce-4e6a-862f-7c417ee0376c'::uuid,
                            'ea6406eb-fe64-43ad-9fad-1ba1961ed971'::uuid,
                            '20f4d064-7657-429a-ba2f-1062366c74f9'::uuid,
                            'c0901aad-37f6-4720-a771-4e6a8376e3b0'::uuid])
) d
WHERE NOT EXISTS (SELECT 1 FROM public.account_artist_ids x WHERE x.artist_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.song_artists sa WHERE sa.artist = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.account_wallets w WHERE w.account_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.rooms r WHERE r.artist_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.scheduled_actions t WHERE t.artist_account_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.files f WHERE f.artist_account_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.sessions se WHERE se.artist_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.campaigns c WHERE c.artist_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.artist_segments ag WHERE ag.artist_account_id = d.id)
  AND NOT EXISTS (SELECT 1 FROM public.funnel_analytics fa WHERE fa.artist_id = d.id);

INSERT INTO public.zz_cleanup_manifest_20260729b (action, subject, detail)
SELECT 'account_delete', id, NULL FROM delete_set;

DELETE FROM public.account_socials a USING delete_set d WHERE a.account_id = d.id;
DELETE FROM public.artist_organization_ids a USING delete_set d WHERE a.artist_id = d.id;
DELETE FROM public.account_info a USING delete_set d WHERE a.account_id = d.id;
DELETE FROM public.account_emails a USING delete_set d WHERE a.account_id = d.id;
DELETE FROM public.accounts a USING delete_set d WHERE a.id = d.id;
