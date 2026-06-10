-- YAGNI cleanup ahead of the play-count measurement store (recoupable/chat#1791):
-- spotify_tracks, spotify_albums and their join tables social_spotify_tracks /
-- social_spotify_albums (created 20250201102146_spotify_tables.sql, funnel era)
-- have zero references in any submodule (api, chat, admin, tasks, gtm, cli,
-- open-agents, marketing) outside generated types. The only FKs into
-- spotify_tracks/spotify_albums come from the social_spotify_* pair, so the
-- four drop as a unit; CASCADE cleans up triggers, indexes, RLS policies, and
-- the FKs from:
--   20250201102146_spotify_tables.sql
--   20250201102147_typo_fix.sql

DROP TABLE IF EXISTS public.social_spotify_tracks CASCADE;
DROP TABLE IF EXISTS public.social_spotify_albums CASCADE;
DROP TABLE IF EXISTS public.spotify_tracks CASCADE;
DROP TABLE IF EXISTS public.spotify_albums CASCADE;
