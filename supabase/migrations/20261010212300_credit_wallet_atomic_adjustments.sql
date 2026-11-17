-- Atomic writers for the two legacy wallet paths that still wrote a balance
-- read earlier: the monthly plan refill (absolute write) and the Stripe credit
-- top-up (read-modify-write). Each function locks the single wallet row and
-- applies its change inside the UPDATE itself, so a concurrent atomic debit,
-- top-up or grant is never overwritten. The refill also re-checks, under the lock,
-- that the refill timestamp the caller observed is still current, so two callers
-- that read the same stale row refill once and a debit in between stays spent.
-- (The API's unaudited deductCredits read-modify-write is a separate known gap.)
--
-- Not a reservation, hold, settlement, ceiling, price or spending
-- authorization. No usage event is written, no auto-top-up column is touched,
-- and no caller is enabled here; the API adopts these separately after release.
BEGIN;

CREATE OR REPLACE FUNCTION public.refill_credits_to_floor(
    p_account_id uuid, p_floor bigint, p_expected_timestamp timestamp
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE
    v_wallet public.credits_usage%ROWTYPE;
    v_before bigint;
BEGIN
    IF p_account_id IS NULL OR p_floor IS NULL OR p_floor < 0 OR p_floor > 9007199254740991
       OR p_expected_timestamp IS NULL THEN
        RAISE EXCEPTION 'Invalid credit refill' USING ERRCODE = '22023';
    END IF;
    -- The lock serializes with charge receipts, legacy debits and top-ups on this row.
    BEGIN
        SELECT * INTO STRICT v_wallet FROM public.credits_usage
          WHERE account_id = p_account_id ORDER BY id FOR UPDATE;
    EXCEPTION WHEN no_data_found OR too_many_rows THEN
        RAISE EXCEPTION 'Credit wallet is unavailable or ambiguous' USING ERRCODE = '22023';
    END;
    IF v_wallet.remaining_credits IS NULL THEN
        RAISE EXCEPTION 'Credit wallet is unavailable' USING ERRCODE = '22023';
    END IF;
    -- The caller decided a refill was due from the timestamp it read. If another
    -- refill (or a grant, which restarts the clock) has moved it since, this period
    -- is already settled: report the current balance and change nothing.
    IF v_wallet."timestamp" IS DISTINCT FROM p_expected_timestamp THEN
        RETURN jsonb_build_object(
            'state', 'superseded',
            'remainingCredits', v_wallet.remaining_credits,
            'timestamp', v_wallet."timestamp");
    END IF;
    v_before := v_wallet.remaining_credits;
    -- The floor is applied here, never from a value the caller read earlier. The
    -- timestamp advances on every due refill, including no-op ones, so the account
    -- stops evaluating as refill-due; it is stored in UTC like the API writer did.
    UPDATE public.credits_usage
       SET remaining_credits = GREATEST(remaining_credits, p_floor),
           "timestamp" = (now() AT TIME ZONE 'UTC')
     WHERE id = v_wallet.id
     RETURNING * INTO STRICT v_wallet;
    RETURN jsonb_build_object(
        'state', CASE WHEN v_wallet.remaining_credits > v_before THEN 'raised' ELSE 'unchanged' END,
        'remainingCredits', v_wallet.remaining_credits,
        'timestamp', v_wallet."timestamp");
END;
$$;

CREATE OR REPLACE FUNCTION public.increment_credits_atomic(
    p_account_id uuid, p_delta bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE
    v_wallet public.credits_usage%ROWTYPE;
BEGIN
    IF p_account_id IS NULL OR p_delta IS NULL OR p_delta <= 0 OR p_delta > 9007199254740991 THEN
        RAISE EXCEPTION 'Invalid credit increment' USING ERRCODE = '22023';
    END IF;
    BEGIN
        SELECT * INTO STRICT v_wallet FROM public.credits_usage
          WHERE account_id = p_account_id ORDER BY id FOR UPDATE;
    EXCEPTION WHEN no_data_found OR too_many_rows THEN
        RAISE EXCEPTION 'Credit wallet is unavailable or ambiguous' USING ERRCODE = '22023';
    END;
    IF v_wallet.remaining_credits IS NULL THEN
        RAISE EXCEPTION 'Credit wallet is unavailable' USING ERRCODE = '22023';
    END IF;
    -- The delta is added in place. The timestamp is left alone, as the legacy
    -- writer did, so a top-up never postpones the monthly refill.
    UPDATE public.credits_usage
       SET remaining_credits = remaining_credits + p_delta
     WHERE id = v_wallet.id
     RETURNING * INTO STRICT v_wallet;
    RETURN jsonb_build_object('remainingCredits', v_wallet.remaining_credits);
END;
$$;

REVOKE ALL ON FUNCTION public.refill_credits_to_floor(uuid,bigint,timestamp)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refill_credits_to_floor(uuid,bigint,timestamp) TO service_role;
REVOKE ALL ON FUNCTION public.increment_credits_atomic(uuid,bigint)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.increment_credits_atomic(uuid,bigint) TO service_role;
COMMIT;
