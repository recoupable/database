-- Validate posts_media_is_array, added NOT VALID in 20261010213200
-- (recoupable/app#2132). Runs in its own transaction so the scan of existing
-- posts holds only a SHARE UPDATE EXCLUSIVE lock and never blocks scraper
-- reads or writes. Re-running it on a validated constraint is a no-op.

ALTER TABLE public.posts VALIDATE CONSTRAINT posts_media_is_array;
