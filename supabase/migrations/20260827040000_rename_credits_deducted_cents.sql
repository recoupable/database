-- Rename usage_events.credits_deducted_cents to credits_deducted.
--
-- The column has held integer micro-dollars since 20260827030000 rescaled the
-- ledger (1,000,000 = $1.00; recoupable/app#2000), so "cents" in the name is
-- wrong by a factor of 10,000. Nothing about the values changes here.
--
-- Every function that names the column is re-created below with CREATE OR
-- REPLACE at its existing signature, so the GRANTs on both functions carry
-- over untouched.
--
-- DEPLOY ORDERING
--
-- deduct_credits_with_audit writes the column through this function, so api
-- writes keep working the moment this applies. The admin credits reader
-- (GET /api/admins/credits/events and /rollup) and get_credit_spend_digest's
-- caller select the column by name in the api, so the api PR that reads
-- `credits_deducted` must deploy immediately after this migration.

BEGIN;

ALTER TABLE public.usage_events
    RENAME COLUMN credits_deducted_cents TO credits_deducted;

-- Same body as 20260827020000, with only the column name changed.
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
        credits_deducted
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

-- Same body as 20260602000000, with only the column name changed. The jsonb
-- keys it returns (total_cents, main_cents, subagent_cents, by_model values)
-- are part of the api's digest contract and are left as they are.
CREATE OR REPLACE FUNCTION public.get_credit_spend_digest(
    p_since timestamptz,
    p_limit integer DEFAULT 10
) RETURNS jsonb
    LANGUAGE sql
    STABLE
    SET search_path = public, pg_temp
AS $$
    WITH windowed AS (
        SELECT *
          FROM public.usage_events
         WHERE created_at >= p_since
    ),
    emails AS (
        SELECT DISTINCT ON (account_id) account_id, email
          FROM public.account_emails
         ORDER BY account_id, updated_at DESC
    ),
    model_breakdown AS (
        SELECT account_id,
               jsonb_object_agg(model_id, cents ORDER BY cents DESC) AS by_model
          FROM (
                SELECT account_id,
                       coalesce(model_id, 'unknown') AS model_id,
                       sum(credits_deducted)         AS cents
                  FROM windowed
                 GROUP BY account_id, coalesce(model_id, 'unknown')
               ) m
         GROUP BY account_id
    ),
    per_account AS (
        SELECT account_id,
               sum(credits_deducted)       AS total_cents,
               count(*)                    AS turn_count,
               sum(input_tokens)           AS input_tokens,
               sum(output_tokens)          AS output_tokens,
               sum(cached_input_tokens)    AS cached_input_tokens,
               sum(tool_call_count)        AS tool_calls,
               coalesce(sum(credits_deducted) FILTER (WHERE agent_type = 'main'), 0)     AS main_cents,
               coalesce(sum(credits_deducted) FILTER (WHERE agent_type = 'subagent'), 0) AS subagent_cents
          FROM windowed
         GROUP BY account_id
    )
    SELECT coalesce(jsonb_agg(obj ORDER BY total_cents DESC), '[]'::jsonb)
      FROM (
            SELECT pa.total_cents,
                   jsonb_build_object(
                       'account_id',          pa.account_id,
                       'account_name',        a.name,
                       'account_email',       e.email,
                       'total_cents',         pa.total_cents,
                       'turn_count',          pa.turn_count,
                       'input_tokens',        pa.input_tokens,
                       'output_tokens',       pa.output_tokens,
                       'cached_input_tokens', pa.cached_input_tokens,
                       'tool_calls',          pa.tool_calls,
                       'main_cents',          pa.main_cents,
                       'subagent_cents',      pa.subagent_cents,
                       'by_model',            coalesce(mb.by_model, '{}'::jsonb)
                   ) AS obj
              FROM per_account pa
              LEFT JOIN public.accounts        a  ON a.id          = pa.account_id
              LEFT JOIN emails                 e  ON e.account_id   = pa.account_id
              LEFT JOIN model_breakdown        mb ON mb.account_id  = pa.account_id
             ORDER BY pa.total_cents DESC
             LIMIT greatest(least(coalesce(p_limit, 10), 1000), 1)
           ) ranked;
$$;

COMMIT;
