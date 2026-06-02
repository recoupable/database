-- Top-spenders aggregation for the credit-spend digest cron.
-- Returns a ranked jsonb array (highest spend first) of the top p_limit
-- accounts by total credits over [p_since, now]; '[]' when empty. Each element:
-- { account_id, account_name, account_email, total_cents, turn_count,
--   input_tokens, output_tokens, cached_input_tokens, tool_calls,
--   main_cents, subagent_cents, by_model: {"<model_id>": <cents>} }.
-- account_email = most-recent per account; NULL model_id bucketed as 'unknown'.

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
             LIMIT greatest(least(coalesce(p_limit, 10), 1000), 1)
           ) ranked;
$$;

-- Trusted backend only: the api cron calls this with the service_role key.
-- Cross-account spend + email data must never be reachable by end users, so
-- revoke the implicit PUBLIC grant and do not grant to `authenticated`.
REVOKE EXECUTE ON FUNCTION public.get_credit_spend_digest(timestamptz, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_credit_spend_digest(timestamptz, integer)
    TO service_role;
