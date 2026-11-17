-- Compose the existing shared-reservation candidate with released pack holds and
-- all wallet debit writers. Depends on 20261010210500_credit_reservations and
-- 20261020150000_release_pack_jobs. No balances, prices or callers are changed.
-- Pack holds have already been deducted from remaining_credits. Shared holds
-- have not: protect only the latter at the common wallet-write boundary.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.protect_credit_reservations()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_held numeric;
BEGIN
    -- Definer visibility is necessary: a permitted legacy writer may not be
    -- allowed to read reservation rows. This function grants no read/write API.
    SELECT coalesce(sum(credits_held),0) INTO v_held
      FROM public.credit_reservations
      WHERE account_id = OLD.account_id AND state = 'held';
    IF v_held > 0 THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'Outstanding credit reservations prevent wallet removal'
              USING ERRCODE = '22023';
        END IF;
        IF NEW.account_id IS DISTINCT FROM OLD.account_id
           OR NEW.remaining_credits IS NULL OR NEW.remaining_credits < v_held THEN
            RAISE EXCEPTION 'Outstanding credit reservations exceed available wallet funds'
              USING ERRCODE = '22023';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.protect_credit_reservations()
    FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER protect_credit_reservations
BEFORE UPDATE OF remaining_credits, account_id OR DELETE ON public.credits_usage
FOR EACH ROW EXECUTE FUNCTION public.protect_credit_reservations();

CREATE OR REPLACE FUNCTION public.reserve_credits_once(
    p_account_id uuid, p_operation_key text, p_credits bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE
    v_id text;
    v_held bigint;
    v_hold public.credit_reservations%ROWTYPE;
    v_wallet public.credits_usage%ROWTYPE;
BEGIN
    IF p_account_id IS NULL OR p_operation_key IS NULL OR btrim(p_operation_key) = ''
       OR length(p_operation_key) > 200 OR p_credits IS NULL OR p_credits <= 0
       OR p_credits > 9007199254740991 THEN
        RAISE EXCEPTION 'Invalid credit reservation' USING ERRCODE = '22023';
    END IF;
    -- Every reservation operation locks the owner's single wallet row first, so
    -- holds serialize with each other, charge receipts and legacy wallet writers.
    BEGIN
        SELECT * INTO STRICT v_wallet FROM public.credits_usage
          WHERE account_id = p_account_id ORDER BY id FOR UPDATE;
    EXCEPTION WHEN no_data_found OR too_many_rows THEN
        RAISE EXCEPTION 'Credit wallet is unavailable or ambiguous' USING ERRCODE = '22023';
    END;
    IF v_wallet.remaining_credits IS NULL THEN
        RAISE EXCEPTION 'Credit wallet is unavailable' USING ERRCODE = '22023';
    END IF;
    v_id := 'hold-v1-' || encode(sha256(convert_to(
        jsonb_build_array(p_account_id::text,p_operation_key)::text,'UTF8')),'hex');
    SELECT * INTO v_hold FROM public.credit_reservations WHERE id = v_id;
    IF FOUND THEN
        IF v_hold.account_id IS DISTINCT FROM p_account_id
           OR v_hold.operation_key IS DISTINCT FROM p_operation_key
           OR v_hold.credits_held IS DISTINCT FROM p_credits THEN
            RAISE EXCEPTION 'Credit reservation identity conflict' USING ERRCODE = '22023';
        END IF;
        -- A replay reports the saved status; it never re-holds released or settled work.
        RETURN jsonb_build_object('state','reused','reservationId',v_id,
            'status',v_hold.state,'creditsHeld',v_hold.credits_held);
    END IF;
    SELECT coalesce(sum(credits_held),0)::bigint INTO v_held FROM public.credit_reservations
      WHERE account_id = p_account_id AND state = 'held';
    IF v_wallet.remaining_credits - v_held < p_credits THEN
        -- A definite denial writes nothing; the same key may be retried later.
        RETURN jsonb_build_object('state','insufficient','creditsRequested',p_credits,
            'spendableCredits',v_wallet.remaining_credits - v_held);
    END IF;
    INSERT INTO public.credit_reservations(id,account_id,operation_key,credits_held)
      VALUES (v_id,p_account_id,p_operation_key,p_credits);
    -- Version the locked wallet so an older REPEATABLE READ writer cannot miss
    -- this new hold. This changes no amount, timestamp, usage event or top-up.
    UPDATE public.credits_usage SET remaining_credits = remaining_credits
      WHERE id = v_wallet.id;
    RETURN jsonb_build_object('state','held','reservationId',v_id,'creditsHeld',p_credits,
        'spendableCredits',v_wallet.remaining_credits - v_held - p_credits);
END;
$$;

CREATE OR REPLACE FUNCTION public.settle_credit_reservation(
    p_account_id uuid, p_operation_key text, p_credits bigint, p_event jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE
    v_id text;
    v_charge jsonb;
    v_hold public.credit_reservations%ROWTYPE;
    v_wallet public.credits_usage%ROWTYPE;
BEGIN
    IF p_account_id IS NULL OR p_operation_key IS NULL OR btrim(p_operation_key) = ''
       OR length(p_operation_key) > 200 OR p_credits IS NULL OR p_credits <= 0
       OR p_credits > 9007199254740991 THEN
        RAISE EXCEPTION 'Invalid credit settlement' USING ERRCODE = '22023';
    END IF;
    BEGIN
        SELECT * INTO STRICT v_wallet FROM public.credits_usage
          WHERE account_id = p_account_id ORDER BY id FOR UPDATE;
    EXCEPTION WHEN no_data_found OR too_many_rows THEN
        RAISE EXCEPTION 'Credit wallet is unavailable or ambiguous' USING ERRCODE = '22023';
    END;
    v_id := 'hold-v1-' || encode(sha256(convert_to(
        jsonb_build_array(p_account_id::text,p_operation_key)::text,'UTF8')),'hex');
    SELECT * INTO v_hold FROM public.credit_reservations WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Credit reservation not found' USING ERRCODE = '22023';
    END IF;
    IF v_hold.state = 'released' THEN
        -- Charging released work needs an explicit failure/cancellation policy.
        RAISE EXCEPTION 'Credit reservation was released' USING ERRCODE = '22023';
    END IF;
    IF p_credits > v_hold.credits_held THEN
        RAISE EXCEPTION 'Credit settlement exceeds reservation' USING ERRCODE = '22023';
    END IF;
    -- Same owner/key as the reservation: an identical retry reuses the charge
    -- receipt; a changed amount or usage payload raises its identity conflict.
    IF v_hold.state = 'held' THEN
        -- Close only this hold before debiting, so the wallet guard still protects
        -- every other reservation. Both writes are one transaction: invalid event,
        -- identity conflict or any charge failure restores the original open hold.
        -- Hold and charge IDs use the same owner/key digest, with different prefixes.
        UPDATE public.credit_reservations
           SET state = 'settled', credits_charged = p_credits,
               charge_event_id = 'charge-v1-' || substr(v_id,9), closed_at = now()
         WHERE id = v_id;
    END IF;
    v_charge := public.record_credit_charge_once(p_account_id,p_operation_key,p_credits,p_event);
    IF v_hold.state = 'settled' AND
       (v_hold.charge_event_id IS DISTINCT FROM v_charge->>'eventId'
        OR v_hold.credits_charged IS DISTINCT FROM p_credits) THEN
        RAISE EXCEPTION 'Credit settlement identity conflict' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object(
        'state',CASE WHEN v_hold.state = 'held' THEN 'settled' ELSE 'reused' END,
        'reservationId',v_id,'eventId',v_charge->>'eventId','creditsHeld',v_hold.credits_held,
        'creditsCharged',p_credits,'creditsReleased',v_hold.credits_held - p_credits);
END;
$$;

COMMIT;
