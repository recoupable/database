-- Atomic transitions for encrypted agent registration state. No new public privileges.
-- The API owns the state machine; the database compares ciphertext, never decrypts it.
BEGIN;

-- Registrations are inserted once; all later writes must compare the ciphertext.
-- Preserve the existing upsert contract for every other provider model.
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
    WHERE p_model <> 'RecoupAgentRegistration'
      AND public.oauth_provider_artifacts.grant_hash IS NOT DISTINCT FROM EXCLUDED.grant_hash
      AND public.oauth_provider_artifacts.account_hash IS NOT DISTINCT FROM EXCLUDED.account_hash
      AND (public.oauth_provider_artifacts.expires_at IS NULL OR EXCLUDED.expires_at IS NOT NULL);
  IF NOT FOUND THEN
    IF p_model = 'RecoupAgentRegistration' THEN
      RAISE EXCEPTION 'Agent registration updates require compare-and-swap' USING ERRCODE = '22023';
    END IF;
    RAISE EXCEPTION 'OAuth artifact binding or finite lifetime cannot change' USING ERRCODE = '22023';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.oauth_store_upsert(text,text,text,text,integer,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.oauth_store_upsert(text,text,text,text,integer,text,text,text,text) TO service_role;

CREATE FUNCTION public.oauth_store_compare_and_swap(
  p_namespace text, p_model text, p_id_hash text,
  p_expected_payload text, p_payload text
) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE bound_grant text;
BEGIN
  IF p_model IS DISTINCT FROM 'RecoupAgentRegistration'
    OR p_namespace IS NULL OR length(p_namespace) NOT BETWEEN 1 AND 512
    OR p_id_hash IS NULL OR p_id_hash !~ '^[0-9a-f]{64}$'
    OR p_expected_payload IS NULL OR octet_length(p_expected_payload) NOT BETWEEN 1 AND 262144
    OR p_payload IS NULL OR octet_length(p_payload) NOT BETWEEN 1 AND 262144 THEN
    RAISE EXCEPTION 'Invalid agent registration transition' USING ERRCODE = '22023';
  END IF;

  SELECT grant_hash INTO bound_grant FROM public.oauth_provider_artifacts
    WHERE namespace = p_namespace AND model = p_model AND id_hash = p_id_hash;
  IF bound_grant IS NULL THEN RETURN false; END IF;
  -- Use the same lock as issuance/revocation. A late approval cannot resurrect a grant.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_namespace || ':' || bound_grant, 0));
  UPDATE public.oauth_provider_artifacts AS artifact SET payload = p_payload
    WHERE artifact.namespace = p_namespace AND artifact.model = p_model
      AND artifact.id_hash = p_id_hash AND artifact.payload = p_expected_payload
      AND artifact.grant_hash = bound_grant
      AND artifact.consumed_at IS NULL
      AND artifact.expires_at > statement_timestamp()
      AND NOT EXISTS (
        SELECT 1 FROM public.oauth_revoked_grants AS revoked
          WHERE revoked.namespace = p_namespace AND revoked.grant_hash = bound_grant
      );
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.oauth_store_compare_and_swap(text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.oauth_store_compare_and_swap(text,text,text,text,text) TO service_role;

-- Bound cleanup to 100 expired ceremonies per new registration. Keep revocation
-- tombstones: a delayed credential save must never restore a disconnected grant.
CREATE INDEX oauth_agent_registration_expiry_idx
  ON public.oauth_provider_artifacts(namespace, expires_at, id_hash)
  WHERE model = 'RecoupAgentRegistration' AND grant_hash = id_hash;

CREATE FUNCTION public.oauth_store_purge_agent_registrations(p_namespace text)
RETURNS integer LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE deleted_count integer;
BEGIN
  IF p_namespace IS NULL OR length(p_namespace) NOT BETWEEN 1 AND 512 THEN
    RAISE EXCEPTION 'Invalid agent registration namespace' USING ERRCODE = '22023';
  END IF;
  WITH expired AS MATERIALIZED (
    SELECT id_hash FROM public.oauth_provider_artifacts
    WHERE namespace = p_namespace AND model = 'RecoupAgentRegistration'
      AND grant_hash = id_hash AND expires_at <= statement_timestamp()
    ORDER BY expires_at, id_hash LIMIT 100 FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.oauth_provider_artifacts AS artifact USING expired
    WHERE artifact.namespace = p_namespace AND artifact.grant_hash = expired.id_hash
      AND artifact.expires_at <= statement_timestamp();
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.oauth_store_purge_agent_registrations(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.oauth_store_purge_agent_registrations(text) TO service_role;
COMMIT;
