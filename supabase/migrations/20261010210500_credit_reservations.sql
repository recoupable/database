-- Shared credit reservations (holds) on the existing wallet for AI work
-- (recoupable/app#2105 milestone 1, reused by Context accounting app#2123).
--
-- Wallet invariant: confirmed balance = credits_usage.remaining_credits;
-- outstanding holds = sum(credits_held) of this owner's 'held' reservations;
-- spendable = confirmed balance - outstanding holds. A hold is a claim, never a
-- temporary debit, so refill, top-up and auto-top-up logic never see it as use.
-- Settlement charges through record_credit_charge_once with the same operation
-- key, so a reservation and its charge share one retry-stable identity.
--
-- Not a price, spending ceiling, top-up, expiry policy, or activation of any
-- caller. Legacy debit writers do not consult holds yet. Holds never expire on
-- their own: unknown provider exposure stays held until explicitly reconciled.
BEGIN;

CREATE TABLE public.credit_reservations (
    id text PRIMARY KEY CHECK (id ~ '^hold-v1-[a-f0-9]{64}$'),
    account_id uuid NOT NULL,
    operation_key text NOT NULL
        CHECK (btrim(operation_key) <> '' AND length(operation_key) <= 200),
    credits_held bigint NOT NULL CHECK (credits_held > 0 AND credits_held <= 9007199254740991),
    state text NOT NULL DEFAULT 'held' CHECK (state IN ('held','settled','released')),
    credits_charged bigint CHECK (credits_charged > 0 AND credits_charged <= credits_held),
    charge_event_id text CHECK (charge_event_id ~ '^charge-v1-[a-f0-9]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    closed_at timestamptz,
    UNIQUE (account_id, operation_key),
    CHECK ((state = 'held' AND credits_charged IS NULL AND charge_event_id IS NULL AND closed_at IS NULL)
        OR (state = 'settled' AND credits_charged IS NOT NULL AND charge_event_id IS NOT NULL
            AND closed_at IS NOT NULL)
        OR (state = 'released' AND credits_charged IS NULL AND charge_event_id IS NULL
            AND closed_at IS NOT NULL))
);
CREATE INDEX credit_reservations_open_idx
    ON public.credit_reservations (account_id) WHERE state = 'held';
ALTER TABLE public.credit_reservations ENABLE ROW LEVEL SECURITY;
-- Retained like charge receipts: deleting a row would let a recycled key hold again,
-- so the service role gets no DELETE/TRUNCATE even where default privileges grant it.
-- UPDATE is limited to the columns settle/release close; a hold's owner, key and
-- amount are immutable once written. The service role may read open holds
-- (state = 'held', by account and created_at) to reconcile lost operation keys.
REVOKE ALL ON public.credit_reservations FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON public.credit_reservations TO service_role;
GRANT UPDATE (state, credits_charged, charge_event_id, closed_at)
    ON public.credit_reservations TO service_role;

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
    v_charge := public.record_credit_charge_once(p_account_id,p_operation_key,p_credits,p_event);
    IF v_hold.state = 'held' THEN
        UPDATE public.credit_reservations
           SET state = 'settled', credits_charged = p_credits,
               charge_event_id = v_charge->>'eventId', closed_at = now()
         WHERE id = v_id;
    ELSIF v_hold.charge_event_id IS DISTINCT FROM v_charge->>'eventId'
       OR v_hold.credits_charged IS DISTINCT FROM p_credits THEN
        RAISE EXCEPTION 'Credit settlement identity conflict' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object(
        'state',CASE WHEN v_hold.state = 'held' THEN 'settled' ELSE 'reused' END,
        'reservationId',v_id,'eventId',v_charge->>'eventId','creditsHeld',v_hold.credits_held,
        'creditsCharged',p_credits,'creditsReleased',v_hold.credits_held - p_credits);
END;
$$;

CREATE OR REPLACE FUNCTION public.release_credit_reservation(
    p_account_id uuid, p_operation_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp AS $$
DECLARE
    v_id text;
    v_hold public.credit_reservations%ROWTYPE;
    v_wallet public.credits_usage%ROWTYPE;
BEGIN
    IF p_account_id IS NULL OR p_operation_key IS NULL OR btrim(p_operation_key) = ''
       OR length(p_operation_key) > 200 THEN
        RAISE EXCEPTION 'Invalid credit release' USING ERRCODE = '22023';
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
    IF v_hold.state = 'settled' THEN
        RAISE EXCEPTION 'Credit reservation was settled' USING ERRCODE = '22023';
    END IF;
    -- Release writes no usage event and never changes the confirmed balance.
    IF v_hold.state = 'held' THEN
        UPDATE public.credit_reservations SET state = 'released', closed_at = now() WHERE id = v_id;
    END IF;
    RETURN jsonb_build_object(
        'state',CASE WHEN v_hold.state = 'held' THEN 'released' ELSE 'reused' END,
        'reservationId',v_id,'creditsHeld',v_hold.credits_held,'creditsReleased',v_hold.credits_held);
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_credits_once(uuid,text,bigint)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_credits_once(uuid,text,bigint) TO service_role;
REVOKE ALL ON FUNCTION public.settle_credit_reservation(uuid,text,bigint,jsonb)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_credit_reservation(uuid,text,bigint,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.release_credit_reservation(uuid,text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_credit_reservation(uuid,text) TO service_role;
COMMIT;
