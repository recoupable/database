-- chat#1979: workspaces removed as an account type; organizations supersede them.
--
-- Convert-to-roster (owner decision 2026-08-21): usage of the 45 prod
-- workspaces is light but real, so plain deletion would strand owner access
-- to those accounts and their chat rooms. Workspaces behave as pseudo-artists
-- (rooms hang off artist_id), so each (account_id, workspace_id) pair becomes
-- an account_artist_ids (account_id, artist_id) roster row — owners keep every
-- workspace and chat through the normal artist path — and the join table is
-- then dropped. The join rows are snapshotted on the issue:
-- https://github.com/recoupable/chat/issues/1979#issuecomment-5363749640
--
-- Dropping account_workspace_ids takes its own PK, both outbound FKs to
-- accounts, its set_updated_at trigger, its two indexes, and its RLS state
-- with it; nothing else in the schema references the table (audit 2026-08-19).
--
-- Idempotent: the INSERT is guarded by a to_regclass existence check (the
-- source table is gone after the first run) and dedupes via the
-- account_artist_ids_account_id_artist_id_key UNIQUE constraint
-- (20260708200000); the DROP is IF EXISTS.

-- 1) Roster every workspace pair as a plain artist row ------------------------

DO $$
BEGIN
    IF to_regclass('public.account_workspace_ids') IS NOT NULL THEN
        INSERT INTO public.account_artist_ids (account_id, artist_id)
        SELECT account_id, workspace_id
        FROM public.account_workspace_ids
        WHERE account_id IS NOT NULL
          AND workspace_id IS NOT NULL
        ON CONFLICT (account_id, artist_id) DO NOTHING;
    END IF;
END $$;

-- 2) Drop the join table ------------------------------------------------------

DROP TABLE IF EXISTS public.account_workspace_ids;
