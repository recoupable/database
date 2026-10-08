CREATE FUNCTION public.confirm_professional_roster(p_actor uuid,p_org uuid,p_key uuid,p_input jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE saved public.professional_roster_requests; person public.organization_professionals;
  role_set text[]; normalized_name text; payload jsonb; result jsonb;
BEGIN
  IF p_actor IS NULL OR p_org IS NULL OR p_key IS NULL OR p_input IS NULL
    OR p_input->>'roster_intent' IS DISTINCT FROM 'add'
    OR p_input->'confirmed' IS DISTINCT FROM 'true'::jsonb
    OR p_input->>'mode' IS NULL OR p_input->>'mode' NOT IN ('new','existing')
    OR jsonb_typeof(p_input->'roles') IS DISTINCT FROM 'array'
  THEN RAISE EXCEPTION 'Explicit identity confirmation and roster intent required' USING ERRCODE='22023'; END IF;
  SELECT array_agg(DISTINCT value ORDER BY value) INTO role_set FROM jsonb_array_elements_text(p_input->'roles');
  IF cardinality(role_set) IS NULL OR cardinality(role_set) NOT BETWEEN 1 AND 2
    OR NOT role_set <@ ARRAY['songwriter','producer']::text[] OR array_position(role_set,NULL) IS NOT NULL
  THEN RAISE EXCEPTION 'Choose songwriter or producer roles' USING ERRCODE='22023'; END IF;
  normalized_name:=btrim(regexp_replace(p_input->>'name','[[:space:]]+',' ','g'));
  IF p_input->>'mode'='new' AND (normalized_name IS NULL OR length(normalized_name) NOT BETWEEN 2 AND 200 OR p_input->>'name' ~ '[[:cntrl:]]')
  THEN RAISE EXCEPTION 'Invalid professional name' USING ERRCODE='22023'; END IF;
  IF p_input->>'mode'='existing' AND p_input->>'professional_id' IS NULL
  THEN RAISE EXCEPTION 'Select an existing professional ID' USING ERRCODE='22023'; END IF;
  payload:=jsonb_build_object('mode',p_input->>'mode','name',CASE WHEN p_input->>'mode'='new' THEN normalized_name END,
    'professional_id',CASE WHEN p_input->>'mode'='existing' THEN (p_input->>'professional_id')::uuid END,'roles',role_set);
  PERFORM pg_advisory_xact_lock(hashtextextended('professional-roster:'||p_org::text||':'||p_key::text,0));
  IF p_actor<>p_org THEN
    PERFORM 1 FROM public.account_organization_ids WHERE account_id=p_actor AND organization_id=p_org FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Organization access denied' USING ERRCODE='42501'; END IF;
  END IF;
  SELECT * INTO saved FROM public.professional_roster_requests WHERE organization_id=p_org AND request_key=p_key;
  IF FOUND THEN
    IF saved.input<>payload OR saved.actor_id<>p_actor THEN RAISE EXCEPTION 'Request key already used for different input' USING ERRCODE='23505'; END IF;
    RETURN saved.result;
  END IF;
  IF p_input->>'mode'='new' THEN
    INSERT INTO public.organization_professionals(organization_id,name,roles,confirmed_by)
      VALUES(p_org,normalized_name,role_set,p_actor) RETURNING * INTO person;
  ELSE
    SELECT * INTO person FROM public.organization_professionals WHERE id=(p_input->>'professional_id')::uuid AND organization_id=p_org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Professional is not in this organization' USING ERRCODE='42501'; END IF;
    UPDATE public.organization_professionals SET roles=ARRAY(SELECT DISTINCT unnest(person.roles||role_set) ORDER BY 1),updated_at=now()
      WHERE id=person.id RETURNING * INTO person;
  END IF;
  result:=jsonb_build_object('professional',to_jsonb(person),'created',p_input->>'mode'='new');
  INSERT INTO public.professional_roster_requests(organization_id,request_key,actor_id,input,result) VALUES(p_org,p_key,p_actor,payload,result);
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.confirm_professional_roster(uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_professional_roster(uuid,uuid,uuid,jsonb) TO service_role;
