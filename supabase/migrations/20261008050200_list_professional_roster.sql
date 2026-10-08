CREATE FUNCTION public.list_professional_roster(p_actor uuid,p_org uuid,p_after uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE rows jsonb;
BEGIN
  IF p_actor IS NULL OR p_org IS NULL THEN RAISE EXCEPTION 'Organization required' USING ERRCODE='22023'; END IF;
  IF p_actor<>p_org THEN
    PERFORM 1 FROM public.account_organization_ids WHERE account_id=p_actor AND organization_id=p_org FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Organization access denied' USING ERRCODE='42501'; END IF;
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.id),'[]'::jsonb) INTO rows FROM
    (SELECT * FROM public.organization_professionals WHERE organization_id=p_org AND (p_after IS NULL OR id>p_after) ORDER BY id LIMIT 101) p;
  RETURN jsonb_build_object('professionals',CASE WHEN jsonb_array_length(rows)>100 THEN rows-100 ELSE rows END,
    'next_cursor',CASE WHEN jsonb_array_length(rows)>100 THEN rows->99->>'id' END);
END $$;
REVOKE ALL ON FUNCTION public.list_professional_roster(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.list_professional_roster(uuid,uuid,uuid) TO service_role;
