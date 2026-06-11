-- Atomic claim function for the Songstats backfill worker (recoupable/chat#1791).
-- FOR UPDATE SKIP LOCKED can't be expressed through supabase-js, so the worker
-- claims its batch via this RPC: pending rows in value order (rank_score DESC),
-- marked in_progress and returned in one statement. Concurrent workers skip
-- each other's locked rows instead of blocking.
--
-- SECURITY INVOKER (default): RLS on songstats_backfill_queue has no policies,
-- so only the service-role worker (which bypasses RLS) can claim rows; anon /
-- authenticated callers get zero rows even if they can execute the function.

CREATE OR REPLACE FUNCTION claim_songstats_backfill_rows(batch_size integer)
RETURNS SETOF songstats_backfill_queue
LANGUAGE sql
AS $$
  UPDATE songstats_backfill_queue q
  SET status = 'in_progress', updated_at = now()
  WHERE q.id IN (
    SELECT id FROM songstats_backfill_queue
    WHERE status = 'pending'
    ORDER BY rank_score DESC
    FOR UPDATE SKIP LOCKED
    LIMIT batch_size
  )
  RETURNING q.*;
$$;
