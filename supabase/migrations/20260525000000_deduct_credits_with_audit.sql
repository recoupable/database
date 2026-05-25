-- Atomic credit debit with audit trail.
--
-- Mirrors open-agents' recordUsage pattern
-- (apps/web/lib/db/usage.ts:60) which wraps wallet debit + meter
-- insert in a single transaction so the two never drift apart on
-- failure (the cubic code-review concern).
--
-- PostgREST cannot execute multi-statement transactions, so the
-- atomic guarantee has to live in a PL/pgSQL function — function
-- bodies run inside an implicit transaction. Either both writes
-- commit or both roll back together.
--
-- Args:
--   p_account_id  account whose wallet is being debited
--   p_amount      debit amount in cents (matches the unit on
--                 usage_events.credits_deducted_cents and the cents
--                 produced by open-agents' computeCreditsDeductedCents)
--   p_event_id    caller-supplied audit row id (matches the nanoid
--                 convention in lib/supabase/usage_events/insertUsageEvent.ts;
--                 explicit so callers can correlate with workflow runs)
--   p_event       JSON payload for the usage_events row:
--                   { source, agent_type, provider, model_id,
--                     input_tokens, cached_input_tokens, output_tokens,
--                     tool_call_count }
--                 All fields optional; absent fields fall back to
--                 column defaults (source='api', agent_type='main',
--                 token/tool counts=0, provider/model_id NULL).
--
-- Replaces the per-caller pattern of `deduct_credits(...)` followed
-- by a separate `INSERT INTO usage_events` — those two writes are
-- NOT atomic through PostgREST and can drift on partial failure.

CREATE OR REPLACE FUNCTION public.deduct_credits_with_audit(
    p_account_id uuid,
    p_amount     integer,
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
        credits_deducted_cents
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
        p_amount
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.deduct_credits_with_audit(uuid, integer, text, jsonb)
    TO authenticated, service_role;
