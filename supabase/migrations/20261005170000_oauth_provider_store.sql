-- Server-only persistence boundary for the MCP OAuth provider.
-- Identifiers are hashed and payloads MUST be authenticated ciphertext produced by the API adapter.
-- This migration does not enable OAuth, issue credentials, or change existing account permissions.
BEGIN;

CREATE TABLE public.oauth_provider_artifacts (
  namespace text NOT NULL CHECK (length(namespace) BETWEEN 1 AND 512),
  model text NOT NULL CHECK (length(model) BETWEEN 1 AND 100),
  id_hash text NOT NULL CHECK (id_hash ~ '^[0-9a-f]{64}$'),
  payload text NOT NULL CHECK (octet_length(payload) BETWEEN 1 AND 262144),
  grant_hash text CHECK (grant_hash ~ '^[0-9a-f]{64}$'),
  uid_hash text CHECK (uid_hash ~ '^[0-9a-f]{64}$'),
  user_code_hash text CHECK (user_code_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (namespace, model, id_hash)
);
CREATE INDEX oauth_provider_artifacts_grant_idx ON public.oauth_provider_artifacts (namespace, grant_hash) WHERE grant_hash IS NOT NULL;
CREATE UNIQUE INDEX oauth_provider_artifacts_uid_idx ON public.oauth_provider_artifacts (namespace, model, uid_hash) WHERE uid_hash IS NOT NULL;
CREATE UNIQUE INDEX oauth_provider_artifacts_user_code_idx ON public.oauth_provider_artifacts (namespace, model, user_code_hash) WHERE user_code_hash IS NOT NULL;
CREATE INDEX oauth_provider_artifacts_expiry_idx ON public.oauth_provider_artifacts (expires_at) WHERE expires_at IS NOT NULL;

-- Tombstones prevent an in-flight issuance from resurrecting a disconnected grant.
-- Do not purge tombstones until the maximum lifetime of every possible associated artifact has elapsed.
CREATE TABLE public.oauth_revoked_grants (
  namespace text NOT NULL CHECK (length(namespace) BETWEEN 1 AND 512),
  grant_hash text NOT NULL CHECK (grant_hash ~ '^[0-9a-f]{64}$'),
  revoked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (namespace, grant_hash)
);

ALTER TABLE public.oauth_provider_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.oauth_revoked_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.oauth_provider_artifacts, public.oauth_revoked_grants FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.oauth_provider_artifacts, public.oauth_revoked_grants TO service_role;

CREATE FUNCTION public.oauth_store_upsert(
  p_namespace text, p_model text, p_id_hash text, p_payload text,
  p_expires_in integer, p_grant_hash text, p_uid_hash text, p_user_code_hash text
) RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  bound_grant text := CASE WHEN p_model = 'Grant' THEN p_id_hash ELSE p_grant_hash END;
BEGIN
  IF p_expires_in IS NOT NULL AND (p_expires_in < 1 OR p_expires_in > 2678400) THEN
    RAISE EXCEPTION 'Invalid OAuth artifact lifetime' USING ERRCODE = '22023';
  END IF;
  IF bound_grant IS NOT NULL THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_namespace || ':' || bound_grant, 0));
    IF EXISTS (SELECT 1 FROM public.oauth_revoked_grants WHERE namespace = p_namespace AND grant_hash = bound_grant) THEN
      RAISE EXCEPTION 'OAuth grant is revoked' USING ERRCODE = '22023';
    END IF;
  END IF;
  INSERT INTO public.oauth_provider_artifacts (
    namespace, model, id_hash, payload, expires_at, grant_hash, uid_hash, user_code_hash
  ) VALUES (
    p_namespace, p_model, p_id_hash, p_payload,
    CASE WHEN p_expires_in IS NULL THEN NULL ELSE clock_timestamp() + p_expires_in * interval '1 second' END,
    bound_grant, p_uid_hash, p_user_code_hash
  ) ON CONFLICT (namespace, model, id_hash) DO UPDATE SET
    payload = EXCLUDED.payload,
    expires_at = EXCLUDED.expires_at,
    uid_hash = EXCLUDED.uid_hash,
    user_code_hash = EXCLUDED.user_code_hash
    -- Neither the grant binding nor consumed marker may be reset by saving a stale payload.
    WHERE public.oauth_provider_artifacts.grant_hash IS NOT DISTINCT FROM EXCLUDED.grant_hash;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'OAuth artifact grant binding cannot change' USING ERRCODE = '22023';
  END IF;
END;
$$;

CREATE FUNCTION public.oauth_store_find(p_namespace text, p_model text, p_index text, p_hash text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  IF p_index NOT IN ('id', 'uid', 'user_code') THEN
    RAISE EXCEPTION 'Invalid OAuth artifact index' USING ERRCODE = '22023';
  END IF;
  SELECT jsonb_build_object('payload', artifact.payload, 'consumed', floor(extract(epoch FROM artifact.consumed_at)))
  INTO result FROM public.oauth_provider_artifacts AS artifact
  WHERE artifact.namespace = p_namespace AND artifact.model = p_model
    AND CASE p_index WHEN 'id' THEN artifact.id_hash = p_hash WHEN 'uid' THEN artifact.uid_hash = p_hash ELSE artifact.user_code_hash = p_hash END
    AND (artifact.expires_at IS NULL OR artifact.expires_at > statement_timestamp())
    AND NOT EXISTS (SELECT 1 FROM public.oauth_revoked_grants AS revoked WHERE revoked.namespace = artifact.namespace AND revoked.grant_hash = artifact.grant_hash);
  RETURN result;
END;
$$;

CREATE FUNCTION public.oauth_store_consume(p_namespace text, p_model text, p_id_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  UPDATE public.oauth_provider_artifacts AS artifact SET consumed_at = clock_timestamp()
  WHERE artifact.namespace = p_namespace AND artifact.model = p_model AND artifact.id_hash = p_id_hash
    AND artifact.consumed_at IS NULL
    AND (artifact.expires_at IS NULL OR artifact.expires_at > statement_timestamp())
    AND NOT EXISTS (SELECT 1 FROM public.oauth_revoked_grants AS revoked WHERE revoked.namespace = artifact.namespace AND revoked.grant_hash = artifact.grant_hash);
  RETURN FOUND;
END;
$$;

CREATE FUNCTION public.oauth_store_revoke_grant(p_namespace text, p_grant_hash text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_namespace || ':' || p_grant_hash, 0));
  INSERT INTO public.oauth_revoked_grants (namespace, grant_hash) VALUES (p_namespace, p_grant_hash)
  ON CONFLICT (namespace, grant_hash) DO NOTHING;
  DELETE FROM public.oauth_provider_artifacts WHERE namespace = p_namespace AND grant_hash = p_grant_hash;
END;
$$;

CREATE FUNCTION public.oauth_store_destroy(p_namespace text, p_model text, p_id_hash text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF p_model = 'Grant' THEN
    PERFORM public.oauth_store_revoke_grant(p_namespace, p_id_hash);
  ELSE
    DELETE FROM public.oauth_provider_artifacts WHERE namespace = p_namespace AND model = p_model AND id_hash = p_id_hash;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.oauth_store_upsert(text,text,text,text,integer,text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.oauth_store_find(text,text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.oauth_store_consume(text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.oauth_store_revoke_grant(text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.oauth_store_destroy(text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.oauth_store_upsert(text,text,text,text,integer,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.oauth_store_find(text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.oauth_store_consume(text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.oauth_store_revoke_grant(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.oauth_store_destroy(text,text,text) TO service_role;

COMMIT;
