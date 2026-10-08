-- New approvals may persist until revoked. Existing finite approvals are not extended.
-- Keep revoked-grant tombstones indefinitely: permanent tokens must never resurrect them.
BEGIN;
CREATE OR REPLACE FUNCTION public.oauth_store_upsert(
  p_namespace text, p_model text, p_id_hash text, p_payload text,
  p_expires_in integer, p_grant_hash text, p_uid_hash text, p_user_code_hash text, p_account_hash text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  bound_grant text := CASE WHEN p_model = 'Grant' THEN p_id_hash ELSE p_grant_hash END;
BEGIN
  IF (p_expires_in IS NULL AND p_model NOT IN ('Client', 'Grant', 'RecoupGrant', 'RefreshToken'))
    OR (p_expires_in IS NOT NULL AND (p_expires_in < 1 OR p_expires_in > 2678400)) THEN
    RAISE EXCEPTION 'Invalid OAuth artifact lifetime' USING ERRCODE = '22023';
  END IF;
  IF bound_grant IS NOT NULL THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_namespace || ':' || bound_grant, 0));
    IF EXISTS (SELECT 1 FROM public.oauth_revoked_grants WHERE namespace = p_namespace AND grant_hash = bound_grant) THEN
      RAISE EXCEPTION 'OAuth grant is revoked' USING ERRCODE = '22023';
    END IF;
  END IF;
  INSERT INTO public.oauth_provider_artifacts (
    namespace, model, id_hash, payload, expires_at, grant_hash, uid_hash, user_code_hash, account_hash
  ) VALUES (
    p_namespace, p_model, p_id_hash, p_payload,
    CASE WHEN p_expires_in IS NULL THEN NULL ELSE clock_timestamp() + p_expires_in * interval '1 second' END,
    bound_grant, p_uid_hash, p_user_code_hash, p_account_hash
  ) ON CONFLICT (namespace, model, id_hash) DO UPDATE SET
    payload = EXCLUDED.payload,
    expires_at = EXCLUDED.expires_at,
    uid_hash = EXCLUDED.uid_hash,
    user_code_hash = EXCLUDED.user_code_hash
    -- Neither the grant binding nor consumed marker may be reset by saving a stale payload.
    WHERE public.oauth_provider_artifacts.grant_hash IS NOT DISTINCT FROM EXCLUDED.grant_hash
      AND public.oauth_provider_artifacts.account_hash IS NOT DISTINCT FROM EXCLUDED.account_hash
      -- A new approval gets a new ID; never extend an existing finite approval.
      AND (public.oauth_provider_artifacts.expires_at IS NULL OR EXCLUDED.expires_at IS NOT NULL);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'OAuth artifact binding or finite lifetime cannot change' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.oauth_store_upsert(text,text,text,text,integer,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.oauth_store_upsert(text,text,text,text,integer,text,text,text,text) TO service_role;
CREATE OR REPLACE FUNCTION public.oauth_store_list_connections(p_namespace text, p_account_hash text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id_hash', a.id_hash, 'payload', a.payload, 'consumed', a.consumed)), '[]'::jsonb)
  FROM (
    SELECT a.id_hash, a.payload, floor(extract(epoch FROM a.consumed_at))::bigint AS consumed
    FROM public.oauth_provider_artifacts a
    WHERE a.namespace = p_namespace AND a.model = 'RecoupGrant' AND a.account_hash = p_account_hash
      AND (a.expires_at IS NULL OR a.expires_at > statement_timestamp())
      AND NOT EXISTS (SELECT 1 FROM public.oauth_revoked_grants r WHERE r.namespace = a.namespace AND r.grant_hash = a.grant_hash)
    ORDER BY a.expires_at DESC, a.id_hash LIMIT 200
  ) a;
$$;
REVOKE ALL ON FUNCTION public.oauth_store_list_connections(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.oauth_store_list_connections(text,text) TO service_role;
COMMIT;
