-- Enforce connection ownership/revocation even when a service caller supplies malformed data.
BEGIN;
ALTER TABLE public.oauth_provider_artifacts ADD CONSTRAINT oauth_connection_bindings
  CHECK (model <> 'RecoupGrant' OR (account_hash IS NOT NULL AND grant_hash IS NOT NULL AND grant_hash = id_hash));
CREATE OR REPLACE FUNCTION public.oauth_store_list_connections(p_namespace text, p_account_hash text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id_hash', a.id_hash, 'payload', a.payload, 'consumed', a.consumed)), '[]'::jsonb)
  FROM (
    SELECT a.id_hash, a.payload, floor(extract(epoch FROM a.consumed_at))::bigint AS consumed
    FROM public.oauth_provider_artifacts a
    WHERE a.namespace = p_namespace AND a.model = 'RecoupGrant' AND a.account_hash = p_account_hash
      AND a.expires_at > statement_timestamp()
      AND NOT EXISTS (SELECT 1 FROM public.oauth_revoked_grants r WHERE r.namespace = a.namespace AND r.grant_hash = a.grant_hash)
    ORDER BY a.expires_at DESC, a.id_hash LIMIT 200
  ) a;
$$;
COMMIT;
