-- Widen every credit column from INTEGER to BIGINT.
--
-- Preparation for the micro-dollar ledger (recoupable/chat#2000). Nothing
-- about the unit changes here: values, semantics and behaviour are identical
-- after this migration. It exists so the rescale that follows has somewhere to
-- land.
--
-- Why it cannot be part of the rescale: INTEGER is int4, max 2,147,483,647. At
-- 1 credit = $0.000001 that caps a balance at $2,147.48, and live balances are
-- already far past it — the largest rescales to roughly 1.0e13, about 4,657x
-- over the ceiling. Running the UPDATE against int4 columns would overflow
-- mid-migration on the largest rows and abort, leaving the rescale half
-- applied across tables.
--
-- BIGINT is int8, max ~9.22e18, which holds the largest projected balance with
-- about six orders of magnitude to spare.
--
-- ALTER TYPE INTEGER -> BIGINT is a widening conversion: Postgres rewrites the
-- table but cannot lose or round a value, so this is safe to run against live
-- data and needs no backfill.

ALTER TABLE public.credits_usage
    ALTER COLUMN remaining_credits TYPE BIGINT;

ALTER TABLE public.credit_grants
    ALTER COLUMN remaining_credits TYPE BIGINT,
    ALTER COLUMN previous_credits  TYPE BIGINT;

ALTER TABLE public.usage_events
    ALTER COLUMN credits_deducted_cents TYPE BIGINT;

-- The atomic debit function takes the amount as `integer`. Postgres cannot
-- alter a parameter type in place, so this is a DROP and CREATE. The parameter
-- *names* are unchanged, and PostgREST resolves `rpc()` calls by name, so the
-- application keeps working across this migration without a deploy.
--
-- Dropping the old signature rather than leaving both: two overloads differing
-- only in a numeric parameter type make PostgREST's choice ambiguous, and an
-- ambiguous overload on the debit path is not worth the convenience.
DROP FUNCTION IF EXISTS public.deduct_credits_with_audit(uuid, integer, text, jsonb);

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

-- Re-granted because the DROP took the old grant with it.
GRANT EXECUTE ON FUNCTION public.deduct_credits_with_audit(uuid, bigint, text, jsonb)
    TO authenticated, service_role;

-- Same treatment for the grant function: it takes an absolute balance, so it
-- has to be able to express one that no longer fits in int4. `v_previous` is
-- widened with it, since it holds a value read straight out of the column.
DROP FUNCTION IF EXISTS public.grant_credits_with_audit(uuid, uuid, text, integer);

CREATE OR REPLACE FUNCTION public.grant_credits_with_audit(
    p_account_id        uuid,
    p_granted_by        uuid,
    p_reason            text,
    p_remaining_credits bigint
) RETURNS public.credit_grants
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $$
DECLARE
    v_previous bigint;
    v_now      timestamptz := now();
    v_grant    public.credit_grants;
BEGIN
    SELECT remaining_credits
      INTO v_previous
      FROM public.credits_usage
     WHERE account_id = p_account_id
     LIMIT 1;

    IF FOUND THEN
        UPDATE public.credits_usage
           SET remaining_credits = p_remaining_credits,
               "timestamp"       = v_now
         WHERE account_id = p_account_id;
    ELSE
        INSERT INTO public.credits_usage (account_id, remaining_credits, "timestamp")
        VALUES (p_account_id, p_remaining_credits, v_now);
    END IF;

    INSERT INTO public.credit_grants (
        account_id,
        granted_by,
        reason,
        previous_credits,
        remaining_credits,
        created_at
    ) VALUES (
        p_account_id,
        p_granted_by,
        p_reason,
        v_previous,
        p_remaining_credits,
        v_now
    ) RETURNING * INTO v_grant;

    RETURN v_grant;
END;
$$;

-- No explicit GRANT here: the original never had one and relies on Postgres's
-- default EXECUTE-to-PUBLIC. Adding privileges inside a widening migration
-- would be a permissions change wearing a type change's clothes.
