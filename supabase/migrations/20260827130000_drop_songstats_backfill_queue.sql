-- Drop the Songstats backfill queue. The Songstats provider and its deep
-- backfill workflow are removed from the api (recoupable/app#1987); nothing
-- reads or writes this table once that deploy is live.
drop table if exists public.songstats_backfill_queue;
