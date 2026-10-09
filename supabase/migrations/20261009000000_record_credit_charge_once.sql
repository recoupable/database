-- Opt-in charge receipts in the existing wallet/audit log. Not a reservation,
-- spending authorization, pricing rule, or activation of any billing caller.
BEGIN;
CREATE OR REPLACE FUNCTION public.record_credit_charge_once(
    p_account_id uuid, p_operation_key text, p_amount bigint, p_event jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE
    v_id text;
    v_event jsonb;
    v_saved jsonb;
    v_row public.usage_events%ROWTYPE;
    v_wallet public.credits_usage%ROWTYPE;
BEGIN
    IF p_account_id IS NULL OR p_operation_key IS NULL OR btrim(p_operation_key) = ''
       OR length(p_operation_key) > 200 OR p_amount IS NULL OR p_amount <= 0
       OR p_amount > 9007199254740991 OR jsonb_typeof(p_event) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Invalid credit charge' USING ERRCODE = '22023';
    END IF;
    IF p_event - ARRAY['source','agent_type','provider','model_id','input_tokens',
       'cached_input_tokens','output_tokens','tool_call_count','resource_url'] <> '{}'::jsonb
       OR EXISTS (SELECT 1 FROM jsonb_each(p_event) e WHERE
          e.key IN ('source','agent_type','provider','model_id','resource_url')
          AND jsonb_typeof(e.value) NOT IN ('string','null'))
       OR EXISTS (SELECT 1 FROM jsonb_each(p_event) e WHERE
          e.key IN ('input_tokens','cached_input_tokens','output_tokens','tool_call_count')
          AND jsonb_typeof(e.value) NOT IN ('number','null')) THEN
        RAISE EXCEPTION 'Invalid credit charge event' USING ERRCODE = '22023';
    END IF;
    v_event := jsonb_build_object(
       'source',coalesce(p_event->>'source','api'), 'agent_type',coalesce(p_event->>'agent_type','main'),
       'provider',p_event->>'provider', 'model_id',p_event->>'model_id',
       'input_tokens',coalesce((p_event->>'input_tokens')::int,0),
       'cached_input_tokens',coalesce((p_event->>'cached_input_tokens')::int,0),
       'output_tokens',coalesce((p_event->>'output_tokens')::int,0),
       'tool_call_count',coalesce((p_event->>'tool_call_count')::int,0),
       'resource_url',p_event->>'resource_url');
    IF v_event->>'source' NOT IN ('api','web') OR v_event->>'agent_type' NOT IN ('main','subagent')
       OR (v_event->>'input_tokens')::int < 0 OR (v_event->>'cached_input_tokens')::int < 0
       OR (v_event->>'output_tokens')::int < 0 OR (v_event->>'tool_call_count')::int < 0 THEN
        RAISE EXCEPTION 'Invalid credit charge event' USING ERRCODE = '22023';
    END IF;
    -- The lock covers check plus debit, and also serializes with legacy wallet updates.
    BEGIN
        SELECT * INTO STRICT v_wallet FROM public.credits_usage
          WHERE account_id = p_account_id ORDER BY id FOR UPDATE;
    EXCEPTION WHEN no_data_found OR too_many_rows THEN
        RAISE EXCEPTION 'Credit wallet is unavailable or ambiguous' USING ERRCODE = '22023';
    END;
    IF v_wallet.remaining_credits IS NULL THEN
        RAISE EXCEPTION 'Credit wallet is unavailable' USING ERRCODE = '22023';
    END IF;
    v_id := 'charge-v1-' || encode(sha256(convert_to(
        jsonb_build_array(p_account_id::text,p_operation_key)::text,'UTF8')),'hex');
    SELECT * INTO v_row FROM public.usage_events WHERE id = v_id;
    IF FOUND THEN
        v_saved := jsonb_build_object(
            'source',v_row.source, 'agent_type',v_row.agent_type,
            'provider',v_row.provider, 'model_id',v_row.model_id,
            'input_tokens',v_row.input_tokens, 'cached_input_tokens',v_row.cached_input_tokens,
            'output_tokens',v_row.output_tokens, 'tool_call_count',v_row.tool_call_count,
            'resource_url',v_row.resource_url);
        IF v_row.account_id IS DISTINCT FROM p_account_id
           OR v_row.credits_deducted IS DISTINCT FROM p_amount OR v_saved IS DISTINCT FROM v_event THEN
            RAISE EXCEPTION 'Credit charge identity conflict' USING ERRCODE = '22023';
        END IF;
        RETURN jsonb_build_object('state','reused','eventId',v_id,'creditsCharged',v_row.credits_deducted);
    END IF;
    -- Preserve the existing atomic debit/audit shape, but target the exact locked row.
    -- The legacy account-wide RPC could debit multiple rows if a legacy writer adds one.
    UPDATE public.credits_usage SET remaining_credits = remaining_credits - p_amount
      WHERE id = v_wallet.id;
    INSERT INTO public.usage_events(id,account_id,source,agent_type,provider,model_id,
      input_tokens,cached_input_tokens,output_tokens,tool_call_count,credits_deducted,resource_url)
    VALUES(v_id,p_account_id,v_event->>'source',v_event->>'agent_type',v_event->>'provider',
      v_event->>'model_id',(v_event->>'input_tokens')::int,(v_event->>'cached_input_tokens')::int,
      (v_event->>'output_tokens')::int,(v_event->>'tool_call_count')::int,p_amount,v_event->>'resource_url');
    RETURN jsonb_build_object('state','charged','eventId',v_id,'creditsCharged',p_amount);
END;
$$;
REVOKE ALL ON FUNCTION public.record_credit_charge_once(uuid,text,bigint,jsonb)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_credit_charge_once(uuid,text,bigint,jsonb) TO service_role;
COMMIT;
