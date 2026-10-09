-- Forward-only exact receipt replay before source creation contention.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
CREATE OR REPLACE FUNCTION public.register_context_original(p_actor uuid,p_owner uuid,p_source uuid,p_key text,
 p_storage_path text,p_sha256 text,p_bytes bigint,p_media_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE payload jsonb; saved public.context_original_registrations; s public.context_sources;
 v public.context_source_versions; receipt uuid;
BEGIN
 PERFORM public.authorize_context_case_actor(p_actor,p_owner);
 IF p_source IS NULL OR p_key IS NULL OR p_key !~ '^[A-Za-z0-9._:-]{1,128}$'
  OR p_sha256 IS NULL OR p_sha256 !~ '^[a-f0-9]{64}$' OR p_bytes IS NULL OR p_bytes NOT BETWEEN 1 AND 52428800
  OR p_media_type IS NULL OR p_media_type NOT IN ('application/pdf','text/csv') OR p_storage_path IS NULL
  OR p_storage_path !~ ('^'||p_owner::text||'/context-originals/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'||
    CASE WHEN p_media_type='application/pdf' THEN '\.(pdf|original)$' ELSE '\.(csv|original)$' END)
 THEN RAISE EXCEPTION 'Invalid original metadata' USING ERRCODE='22023'; END IF;
 payload:=jsonb_build_object('source_id',p_source,'storage_path',p_storage_path,'sha256',p_sha256,'bytes',p_bytes,'media_type',p_media_type);
 -- Owner serialization preserves atomic replay; runtime waits use caller timeouts.
 PERFORM pg_advisory_xact_lock(hashtextextended('context-original:'||p_owner::text,0));
 SELECT * INTO saved FROM public.context_original_registrations WHERE owner_id=p_owner AND idempotency_key=p_key;
 IF saved.id IS NOT NULL THEN
  IF saved.payload IS DISTINCT FROM payload THEN RAISE EXCEPTION 'Original retry conflict' USING ERRCODE='22023'; END IF;
  RETURN public.read_context_original_registration(p_actor,p_owner,saved.id);
 END IF;
 -- Global source IDs can race across owners; always lock owner then source.
 IF NOT pg_try_advisory_xact_lock(hashtextextended('context-original-source:'||p_source::text,0))
 THEN RAISE EXCEPTION 'Original unavailable' USING ERRCODE='42501'; END IF;
 SELECT * INTO s FROM public.context_sources WHERE id=p_source FOR SHARE;
 IF s.id IS NOT NULL AND (s.owner_id<>p_owner OR s.kind<>'customer' OR s.source_url IS DISTINCT FROM 'urn:recoup:original:'||p_source::text OR s.withdrawn_at IS NOT NULL)
 THEN RAISE EXCEPTION 'Original unavailable' USING ERRCODE='42501'; END IF;
 IF s.id IS NULL THEN INSERT INTO public.context_sources(id,owner_id,kind,source_url)
  VALUES(p_source,p_owner,'customer','urn:recoup:original:'||p_source::text); END IF;
 IF EXISTS(SELECT 1 FROM public.context_source_versions WHERE owner_id=p_owner AND storage_path=p_storage_path
  AND (source_id<>p_source OR fingerprint<>p_sha256))
 THEN RAISE EXCEPTION 'Original storage conflict' USING ERRCODE='22023'; END IF;
 SELECT * INTO v FROM public.context_source_versions WHERE source_id=p_source AND fingerprint=p_sha256 FOR SHARE;
 IF v.id IS NOT NULL THEN
  IF v.owner_id<>p_owner OR v.removed_at IS NOT NULL OR v.content IS DISTINCT FROM payload OR v.storage_path IS DISTINCT FROM p_storage_path
  THEN RAISE EXCEPTION 'Original version conflict' USING ERRCODE='22023'; END IF;
 ELSE
  INSERT INTO public.context_source_versions(owner_id,source_id,fingerprint,content,storage_path,media_manifest)
  VALUES(p_owner,p_source,p_sha256,payload,p_storage_path,jsonb_build_object('schemaVersion',1,'bytes',p_bytes,'mediaType',p_media_type)) RETURNING * INTO v;
 END IF;
 INSERT INTO public.context_original_registrations(owner_id,actor_id,source_id,source_version_id,idempotency_key,payload)
 VALUES(p_owner,p_actor,p_source,v.id,p_key,payload) RETURNING id INTO receipt;
 RETURN public.read_context_original_registration(p_actor,p_owner,receipt);
END $$;
REVOKE ALL ON FUNCTION public.register_context_original(uuid,uuid,uuid,text,text,text,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.register_context_original(uuid,uuid,uuid,text,text,text,bigint,text) TO service_role;
COMMIT;
