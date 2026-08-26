-- Drop the legacy next_run / last_run columns from scheduled_actions
-- (recoupable/chat#2006 item 7).
--
-- Both columns predate Trigger.dev owning task schedules. Nothing in api,
-- tasks, or chat has written them since 20251104000000 added
-- trigger_schedule_id: at the time of this migration 58 of 164 rows carry
-- values, the newest is 2025-11-01, and no row created after 2025-11-04 has
-- either. Trigger.dev is the source of truth, and GET /api/tasks already
-- returns its data as `upcoming` (next fires) and `recent_runs` (previous
-- runs, each linked to its workflow + chat). Keeping a second copy of the
-- same fact is how these went stale and leaked into the UI as a 2025 "next
-- run", so they go rather than get re-derived.
--
-- The 58 affected rows are snapshotted on recoupable/chat#2006 (item 7)
-- before this runs.
--
-- Idempotent: safe to re-apply.

drop index if exists public.idx_scheduled_actions_next_run;

alter table public.scheduled_actions
  drop column if exists next_run,
  drop column if exists last_run;
