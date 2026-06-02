-- Credit-spend visibility digest aggregation.
--
-- Powers a 10-minute Vercel Cron in the api (`/api/internal/credit-spend-digest`)
-- that posts a top-spenders summary to Telegram. Aggregation lives in the
-- database (one round trip) rather than pulling rows into JS: the function
-- buckets `usage_events` over a time window and returns the top N accounts by
-- total credits spent, each enriched with how that spend breaks down.
--
-- Args:
--   p_since   lower bound on usage_events.created_at (inclusive). The caller
--             passes `now() - interval '10 minutes'`; the window is stateless
--             (minor boundary drift is accepted).
--   p_limit   max number of accounts to return, ranked by total spend desc.
--
-- Returns a jsonb array (ranked, highest spend first). Each element:
--   {
--     account_id, account_name, account_email,
--     total_cents,                         -- total credits spent in window
--     turn_count,                          -- number of usage_events rows
--     input_tokens, output_tokens, cached_input_tokens,
--     tool_calls,
--     main_cents, subagent_cents,          -- main vs subagent split (agent_type)
--     by_model                             -- { "<model_id>": <cents>, ... }
--   }
-- Empty window -> '[]'. The caller treats that as a no-op (no Telegram ping).
--
-- account_email is the most-recent email per account (account_emails ordered
-- by updated_at desc). model_id NULL is bucketed under 'unknown' in by_model.

CREATE OR REPLACE FUNCTION public.get_credit_spend_digest(
    p_since timestamptz,
    p_limit integer DEFAULT 10
) RETURNS jsonb
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
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
                       sum(credits_deducted_cents)   AS cents
                  FROM windowed
                 GROUP BY account_id, coalesce(model_id, 'unknown')
               ) m
         GROUP BY account_id
    ),
    per_account AS (
        SELECT account_id,
               sum(credits_deducted_cents) AS total_cents,
               count(*)                    AS turn_count,
               sum(input_tokens)           AS input_tokens,
               sum(output_tokens)          AS output_tokens,
               sum(cached_input_tokens)    AS cached_input_tokens,
               sum(tool_call_count)        AS tool_calls,
               coalesce(sum(credits_deducted_cents) FILTER (WHERE agent_type = 'main'), 0)     AS main_cents,
               coalesce(sum(credits_deducted_cents) FILTER (WHERE agent_type = 'subagent'), 0) AS subagent_cents
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
             LIMIT p_limit
           ) ranked;
$$;

GRANT EXECUTE ON FUNCTION public.get_credit_spend_digest(timestamptz, integer)
    TO authenticated, service_role;
