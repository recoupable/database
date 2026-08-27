-- Add usage_events.resource_url: the app-relative path of whatever produced
-- a charge, so a line on the /usage page can open the chat turn, the song
-- generation or the scheduled task run behind it (recoupable/app#2029).
--
-- Values are written by the api at billing time:
--   * chat turn            -> /chat?roomId=<roomId>
--   * song generation      -> /music/<generationId>
--   * scheduled task run   -> /tasks/<taskId>/runs/<runId>
--   * plain API call       -> NULL
-- Rows written before this column existed stay NULL; there is no backfill.
-- The column is never filtered on, so it carries no index.
--
-- deduct_credits_with_audit keeps its signature (uuid, bigint, text, jsonb),
-- so CREATE OR REPLACE is enough and the existing GRANTs stay in place; the
-- api passes resource_url inside p_event like every other audit field.

BEGIN;

ALTER TABLE public.usage_events
    ADD COLUMN IF NOT EXISTS resource_url text NULL;

CREATE OR REPLACE FUNCTION public.deduct_credits_with_audit(
    p_account_id uuid,
    p_amount     bigint,
    p_event_id   text,
    p_event      jsonb
) RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.credits_usage
       SET remaining_credits = remaining_credits - p_amount
     WHERE account_id = p_account_id;

    INSERT INTO public.usage_events (
        id,
        account_id,
        source,
        agent_type,
        provider,
        model_id,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        tool_call_count,
        credits_deducted,
        resource_url
    ) VALUES (
        p_event_id,
        p_account_id,
        coalesce(p_event->>'source', 'api'),
        coalesce(p_event->>'agent_type', 'main'),
        p_event->>'provider',
        p_event->>'model_id',
        coalesce((p_event->>'input_tokens')::int, 0),
        coalesce((p_event->>'cached_input_tokens')::int, 0),
        coalesce((p_event->>'output_tokens')::int, 0),
        coalesce((p_event->>'tool_call_count')::int, 0),
        p_amount,
        p_event->>'resource_url'
    );
END;
$$;

COMMIT;
