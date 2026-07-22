-- Add timezone column to scheduled_actions
-- Purpose: schedule weekly-report sends at 9am LOCAL time instead of 9am UTC
-- (currently the middle of the night in the US). See chat#1881 item 3c.

-- Change: add optional IANA timezone column with default NULL (NULL = UTC).
ALTER TABLE public.scheduled_actions
ADD COLUMN IF NOT EXISTS timezone text DEFAULT NULL;

COMMENT ON COLUMN public.scheduled_actions.timezone IS
'IANA timezone id (e.g. America/New_York) the schedule is interpreted in. NULL = UTC.';
