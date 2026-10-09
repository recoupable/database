-- Trusted server byte metadata only; this does not verify file contents or rights.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
CREATE TABLE public.context_original_registrations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 owner_id uuid NOT NULL REFERENCES public.accounts(id),
 actor_id uuid NOT NULL REFERENCES public.accounts(id),
 source_id uuid NOT NULL,
 source_version_id uuid NOT NULL,
 idempotency_key text NOT NULL CHECK(idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'),
 payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(source_id,owner_id) REFERENCES public.context_sources(id,owner_id),
 FOREIGN KEY(source_version_id,owner_id) REFERENCES public.context_source_versions(id,owner_id),
 UNIQUE(owner_id,idempotency_key)
);
ALTER TABLE public.context_original_registrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.context_original_registrations FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON public.context_original_registrations TO service_role;

CREATE FUNCTION public.read_context_original_registration(p_actor uuid,p_owner uuid,p_receipt uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE r public.context_original_registrations; v public.context_source_versions;
BEGIN
 PERFORM public.authorize_context_case_actor(p_actor,p_owner);
 SELECT * INTO r FROM public.context_original_registrations WHERE id=p_receipt AND owner_id=p_owner;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Original unavailable' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.context_sources s WHERE s.id=r.source_id AND s.owner_id=p_owner
  AND s.kind='customer' AND s.source_url='urn:recoup:original:'||s.id::text AND s.withdrawn_at IS NULL FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Original unavailable' USING ERRCODE='42501'; END IF;
 SELECT * INTO v FROM public.context_source_versions WHERE id=r.source_version_id AND owner_id=p_owner
  AND source_id=r.source_id AND removed_at IS NULL FOR SHARE;
 IF v.id IS NULL OR v.fingerprint IS DISTINCT FROM r.payload->>'sha256'
  OR v.storage_path IS DISTINCT FROM r.payload->>'storage_path' OR v.content IS DISTINCT FROM r.payload
 THEN RAISE EXCEPTION 'Original unavailable' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('id',r.id,'owner_id',r.owner_id,'source_id',r.source_id,'source_version_id',r.source_version_id,
  'fingerprint',v.fingerprint,'bytes',(r.payload->>'bytes')::bigint,'media_type',r.payload->>'media_type',
  'status','registered','evidence_kind','customer_assertion','created_at',r.created_at);
END $$;

CREATE FUNCTION public.register_context_original(p_actor uuid,p_owner uuid,p_source uuid,p_key text,
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
    CASE WHEN p_media_type='application/pdf' THEN '\.pdf$' ELSE '\.csv$' END)
 THEN RAISE EXCEPTION 'Invalid original metadata' USING ERRCODE='22023'; END IF;
 payload:=jsonb_build_object('source_id',p_source,'storage_path',p_storage_path,'sha256',p_sha256,'bytes',p_bytes,'media_type',p_media_type);
 -- Bounded owner serialization makes replay, source creation and object binding atomic.
 PERFORM pg_advisory_xact_lock(hashtextextended('context-original:'||p_owner::text,0));
 SELECT * INTO saved FROM public.context_original_registrations WHERE owner_id=p_owner AND idempotency_key=p_key;
 IF saved.id IS NOT NULL THEN
  IF saved.payload IS DISTINCT FROM payload THEN RAISE EXCEPTION 'Original retry conflict' USING ERRCODE='22023'; END IF;
  RETURN public.read_context_original_registration(p_actor,p_owner,saved.id);
 END IF;
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
REVOKE ALL ON FUNCTION public.read_context_original_registration(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.register_context_original(uuid,uuid,uuid,text,text,text,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_context_original_registration(uuid,uuid,uuid),public.register_context_original(uuid,uuid,uuid,text,text,text,bigint,text) TO service_role;
COMMIT;
