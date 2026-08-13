-- chat#1958 row 2: name task runs by the subject of the email they sent.
--
-- email_send_log gains the two fields the run-to-email link needs:
--   subject         — denormalized from the send request so the runs list can
--                     read it without parsing raw_body HTML/JSON per row
--   trigger_run_id  — the Trigger.dev run id (run_…) of the scheduled task
--                     that produced the send; NULL for interactive sends
--
-- The partial index serves GET /api/tasks/runs list-mode annotation
-- (WHERE trigger_run_id IN (…)); most rows are interactive sends with NULL
-- run ids, so the partial form keeps it small.

ALTER TABLE public.email_send_log
  ADD COLUMN IF NOT EXISTS subject text NULL,
  ADD COLUMN IF NOT EXISTS trigger_run_id text NULL;

CREATE INDEX IF NOT EXISTS email_send_log_trigger_run_id_idx
  ON public.email_send_log (trigger_run_id)
  WHERE trigger_run_id IS NOT NULL;

-- Backfill: raw_body stores the POST /api/emails request JSON verbatim, so
-- historical subjects are recoverable. Run linkage is NOT backfillable (old
-- sends carried no run id) — those runs fall back to their schedule's title.
-- Guarded so malformed / non-JSON raw_body rows are skipped, not fatal.
DO $$
DECLARE
  r record;
  parsed jsonb;
BEGIN
  FOR r IN
    SELECT id, raw_body FROM public.email_send_log
    WHERE subject IS NULL AND raw_body IS NOT NULL AND raw_body ~ '^\s*\{'
  LOOP
    BEGIN
      parsed := r.raw_body::jsonb;
      IF parsed ? 'subject' AND jsonb_typeof(parsed -> 'subject') = 'string' THEN
        UPDATE public.email_send_log
        SET subject = parsed ->> 'subject'
        WHERE id = r.id;
      END IF;
    EXCEPTION WHEN others THEN
      -- rejected attempts can store invalid JSON; skip, never abort
      NULL;
    END;
  END LOOP;
END $$;
