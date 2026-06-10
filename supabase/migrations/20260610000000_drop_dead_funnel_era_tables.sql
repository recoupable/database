-- YAGNI cleanup ahead of the play-count measurement store (recoupable/chat#1791):
-- drop 14 tables with zero code references in any submodule (api, chat, admin,
-- tasks, gtm, cli, open-agents, marketing) outside generated types, verified
-- 2026-06-10 by full-table-inventory sweep (git grep -w per table) plus an RPC
-- function-body scan (no SQL function touches any of these).
-- CASCADE cleans up each table's triggers, indexes, RLS policies, and FKs.
--
-- Deliberately NOT dropped (referenced by code that is itself likely dead —
-- needs a chat dead-code PR first): funnel_analytics (+ its children
-- funnel_analytics_accounts/_segments/_comments, named in chat/types/Agent.tsx),
-- campaigns + fans (queried by get_campaign / get_fans_listening_top_songs
-- RPCs, called from unimported chat helpers), and spotify_play_button_clicked /
-- spotify_login_button_clicked / apple_play_button_clicked (named in
-- chat/lib/chat/getStreamsCount.tsx / getStartedFans.tsx).

-- 2025-02 Spotify funnel tables (20250201102146_spotify_tables.sql);
-- only FKs into spotify_tracks/spotify_albums come from the social_* pair
DROP TABLE IF EXISTS public.social_spotify_tracks CASCADE;
DROP TABLE IF EXISTS public.social_spotify_albums CASCADE;
DROP TABLE IF EXISTS public.spotify_tracks CASCADE;
DROP TABLE IF EXISTS public.spotify_albums CASCADE;

-- 2024-12 funnel analytics leaves (20241223031656_funnel_tables.sql);
-- all FK -> funnel_analytics, nothing FKs into them
DROP TABLE IF EXISTS public.spotify_analytics_tracks CASCADE;
DROP TABLE IF EXISTS public.spotify_analytics_albums CASCADE;
DROP TABLE IF EXISTS public.funnel_analytics_profile CASCADE;
DROP TABLE IF EXISTS public.funnel_reports CASCADE;

-- 2024-11 campaign click-tracking leaves (20241112063734_campaign_id_foreign_keys.sql);
-- FK -> campaigns (campaigns itself stays, see header)
DROP TABLE IF EXISTS public.apple_login_button_clicked CASCADE;
DROP TABLE IF EXISTS public.popup_open CASCADE;

-- Orphaned per-feature tables, zero references:
-- artist_social_links (20241121201709), FK target `artists` was removed 20250129000020
DROP TABLE IF EXISTS public.artist_social_links CASCADE;
-- artist_fan_segment (20250204181622), FK -> socials
DROP TABLE IF EXISTS public.artist_fan_segment CASCADE;
-- room_reports (20250206180226_eliza_migration_tables.sql), FK -> rooms
DROP TABLE IF EXISTS public.room_reports CASCADE;
-- segment_reports (20250206023350)
DROP TABLE IF EXISTS public.segment_reports CASCADE;
