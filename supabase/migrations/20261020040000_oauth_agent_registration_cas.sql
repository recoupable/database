-- Atomic transitions for encrypted agent registration state. No new public privileges.
-- The API owns the state machine; the database compares ciphertext, never decrypts it.
BEGIN;

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
