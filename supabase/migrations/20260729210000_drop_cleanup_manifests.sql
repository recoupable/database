-- Drop the canonical-cleanup manifest tables (chat#1889; decision Sweets
-- 2026-07-29: drop after the cleanup pass and orphan deletion verify).
--
-- zz_dupe_manifest_20260729   — before-manifest for 20260729060000 (#49)
-- zz_cleanup_manifest_20260729b — audit manifest written by 20260729190000 (#50)
--
-- Both passes are applied and verified on prod (all assertions green,
-- 2026-07-29): 0 Spotify ids resolve to >1 artist, 663 orphans deleted with
-- zero dangling soft references. Fresh environments only ever had the stubs.
DROP TABLE IF EXISTS public.zz_dupe_manifest_20260729;
DROP TABLE IF EXISTS public.zz_cleanup_manifest_20260729b;
