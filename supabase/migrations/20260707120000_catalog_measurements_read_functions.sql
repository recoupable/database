-- Read functions for GET /api/catalogs/measurements v2 (recoupable/chat#1850).
-- The endpoint's aggregates must cover the ENTIRE scope in one SQL aggregate
-- (the app-code loop-to-exhaustion approach was rejected 2026-07-07), and the
-- latest-per-ISRC dedupe (DISTINCT ON) is not expressible through supabase-js,
-- so both the aggregate and the paginated rows read live here as RPCs.
--
-- Scope = the catalog's songs, optionally restricted to those linked to one
-- artist account via song_artists (catalog_songs ∩ song_artists). "Latest"
-- = the newest spotify platform_displayed_play_count capture per ISRC.
--
-- SECURITY INVOKER (default): the api calls these with the service role
-- (bypasses RLS); other callers are subject to the underlying tables' RLS,
-- same as the claim_songstats_backfill_rows precedent.

CREATE OR REPLACE FUNCTION get_catalog_measurements_aggregate(
  p_catalog uuid,
  p_artist uuid DEFAULT NULL
)
RETURNS TABLE (measured_song_count bigint, total_streams numeric)
LANGUAGE sql
STABLE
AS $$
  WITH latest AS (
    SELECT DISTINCT ON (sm.song) sm.value
    FROM song_measurements sm
    JOIN catalog_songs cs ON cs.song = sm.song AND cs.catalog = p_catalog
    WHERE sm.platform = 'spotify'
      AND sm.metric = 'platform_displayed_play_count'
      AND (
        p_artist IS NULL
        OR EXISTS (
          SELECT 1 FROM song_artists sa
          WHERE sa.song = sm.song AND sa.artist = p_artist
        )
      )
    ORDER BY sm.song, sm.captured_at DESC
  )
  SELECT count(*)::bigint, COALESCE(sum(value), 0)::numeric FROM latest;
$$;

CREATE OR REPLACE FUNCTION get_catalog_measurements_page(
  p_catalog uuid,
  p_artist uuid DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (isrc text, title text, playcount bigint, measured_at timestamptz)
LANGUAGE sql
STABLE
AS $$
  SELECT l.isrc, l.title, l.playcount, l.measured_at
  FROM (
    SELECT DISTINCT ON (sm.song)
      sm.song AS isrc,
      s.name AS title,
      sm.value AS playcount,
      sm.captured_at AS measured_at
    FROM song_measurements sm
    JOIN catalog_songs cs ON cs.song = sm.song AND cs.catalog = p_catalog
    JOIN songs s ON s.isrc = sm.song
    WHERE sm.platform = 'spotify'
      AND sm.metric = 'platform_displayed_play_count'
      AND (
        p_artist IS NULL
        OR EXISTS (
          SELECT 1 FROM song_artists sa
          WHERE sa.song = sm.song AND sa.artist = p_artist
        )
      )
    ORDER BY sm.song, sm.captured_at DESC
  ) l
  ORDER BY l.playcount DESC, l.isrc ASC
  LIMIT p_limit OFFSET p_offset;
$$;
