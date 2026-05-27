-- YouTube auth has fully migrated to Composio (token storage now lives in
-- Composio's connected-account API). The youtube_tokens table is no longer
-- read or written by api/chat. Dropping it; CASCADE cleans up the trigger,
-- indexes, RLS policy, and FK from migrations:
--   20250601000001_youtube_tokens_consolidated.sql
--   20250702204149_rename_youtube_tokens_account_id_to_artist_account_id.sql
--   20250703000000_youtube_tokens_row_level_security.sql

DROP TABLE IF EXISTS public.youtube_tokens CASCADE;
