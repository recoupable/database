BEGIN;

-- Internal server location lookup only. Public receipt reads remain metadata-only.
-- Reuse the locked receipt authority; no new source/version or accepted analysis.
CREATE FUNCTION public.get_context_original_retrieval(p_actor uuid,p_owner uuid,p_receipt uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE receipt jsonb; path text;
BEGIN
 receipt := public.read_context_original_registration(p_actor,p_owner,p_receipt);
 SELECT v.storage_path INTO path FROM public.context_source_versions v
 WHERE v.id=(receipt->>'source_version_id')::uuid AND v.owner_id=p_owner
  AND v.source_id=(receipt->>'source_id')::uuid;
 IF path IS NULL THEN RAISE EXCEPTION 'Original unavailable' USING ERRCODE='42501'; END IF;
 RETURN receipt || jsonb_build_object('bucket','context-private','storage_path',path);
END $$;

REVOKE ALL ON FUNCTION public.get_context_original_retrieval(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_context_original_retrieval(uuid,uuid,uuid) TO service_role;
COMMIT;
