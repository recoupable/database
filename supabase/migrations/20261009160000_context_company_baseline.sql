-- Read registered organization roster and Context source metadata, not legal completeness.
BEGIN;
CREATE FUNCTION public.read_context_company_baseline(
 p_actor uuid, p_org uuid,
 p_after_artist uuid DEFAULT NULL,
 p_after_professional uuid DEFAULT NULL,
 p_after_source uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE artists jsonb; professionals jsonb; sources jsonb; org_name text;
BEGIN
 -- Existing owner/member policy; membership lock lasts through the read transaction.
 PERFORM public.authorize_context_case_actor(p_actor,p_org);
 SELECT name INTO org_name FROM public.accounts WHERE id=p_org;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case access denied' USING ERRCODE='42501'; END IF;

 SELECT coalesce(jsonb_agg(jsonb_build_object('relationship_id',r.id,'artist_id',r.artist_id,
   'name',a.name) ORDER BY r.id),'[]'::jsonb) INTO artists
 FROM (SELECT id,artist_id FROM public.artist_organization_ids WHERE organization_id=p_org
   AND (p_after_artist IS NULL OR id>p_after_artist) ORDER BY id LIMIT 51) r
 JOIN public.accounts a ON a.id=r.artist_id;

 SELECT coalesce(jsonb_agg(jsonb_build_object('professional_id',p.id,'name',p.name,'roles',p.roles,
   'confirmation_basis',p.confirmation_basis) ORDER BY p.id),'[]'::jsonb) INTO professionals
 FROM (SELECT id,name,roles,confirmation_basis FROM public.organization_professionals
   WHERE organization_id=p_org AND (p_after_professional IS NULL OR id>p_after_professional)
   ORDER BY id LIMIT 51) p;

 -- Only metadata: no raw documents, signed URLs or storage paths are returned.
 SELECT coalesce(jsonb_agg(jsonb_build_object('source_id',s.id,'kind',s.kind,'created_at',s.created_at,
   'retained_version_count',(SELECT count(*) FROM public.context_source_versions v
     WHERE v.owner_id=p_org AND v.source_id=s.id AND v.removed_at IS NULL)) ORDER BY s.id),'[]'::jsonb)
 INTO sources FROM (SELECT id,kind,created_at FROM public.context_sources WHERE owner_id=p_org
   AND withdrawn_at IS NULL AND (p_after_source IS NULL OR id>p_after_source) ORDER BY id LIMIT 51) s;

 RETURN jsonb_build_object(
  'contract_version','company-baseline-v1','organization_id',p_org,'organization_name',org_name,
  'read_at',statement_timestamp(),'consistency','live_read',
  'coverage','registered_roster_and_context_sources_only',
  'artists',jsonb_build_object('items',CASE WHEN jsonb_array_length(artists)>50 THEN artists-50 ELSE artists END,
    'next_id',CASE WHEN jsonb_array_length(artists)>50 THEN artists->49->>'relationship_id' END),
  'professionals',jsonb_build_object('items',CASE WHEN jsonb_array_length(professionals)>50 THEN professionals-50 ELSE professionals END,
    'next_id',CASE WHEN jsonb_array_length(professionals)>50 THEN professionals->49->>'professional_id' END),
  'sources',jsonb_build_object('items',CASE WHEN jsonb_array_length(sources)>50 THEN sources-50 ELSE sources END,
    'next_id',CASE WHEN jsonb_array_length(sources)>50 THEN sources->49->>'source_id' END),
  'gaps',jsonb_build_array('company_relationships_not_linked','catalog_coverage_not_assessed',
    'sources_not_attributed_to_roster','source_parsing_and_review_not_assessed','rights_and_mandates_not_assessed')
 );
END $$;
REVOKE ALL ON FUNCTION public.read_context_company_baseline(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_context_company_baseline(uuid,uuid,uuid,uuid,uuid) TO service_role;
COMMIT;
