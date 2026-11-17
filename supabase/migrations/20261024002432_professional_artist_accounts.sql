-- Professionals use the existing artist account identity and organization roster.
-- Keep professional IDs stable for role history and idempotency receipts.
ALTER TABLE public.organization_professionals
  ADD COLUMN artist_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE;

-- Explicitly confirmed identity repair; never infer identity from a name.
-- On environments without this professional, this block is a no-op.
DO $$
DECLARE person public.organization_professionals;
BEGIN
  SELECT * INTO person FROM public.organization_professionals
    WHERE id='c73c1ca6-971f-44e9-ad7a-b00e5e57a35f' FOR UPDATE;
  IF FOUND THEN
    IF person.organization_id <> '14524163-fd59-4d49-b58f-bd739b1bc0b5'::uuid
      OR person.confirmed_by <> '1ca89eeb-14ab-4a4a-a1c5-2dd41663c039'::uuid
      OR NOT EXISTS (SELECT 1 FROM public.account_artist_ids
        WHERE account_id=person.confirmed_by
          AND artist_id='9b16358d-6d2d-4f3c-a69f-625dbd7bf74a')
    THEN RAISE EXCEPTION 'Confirmed professional repair prerequisites changed'; END IF;
    UPDATE public.organization_professionals
      SET artist_id='9b16358d-6d2d-4f3c-a69f-625dbd7bf74a' WHERE id=person.id;
    INSERT INTO public.artist_organization_ids(artist_id,organization_id)
      VALUES ('9b16358d-6d2d-4f3c-a69f-625dbd7bf74a',person.organization_id)
      ON CONFLICT (artist_id,organization_id) DO NOTHING;
  END IF;
END $$;

-- Other legacy records get distinct accounts, never name-based merges. Use the
-- organization as owner so a former confirming member gains no renewed access.
DO $$
DECLARE person public.organization_professionals; artist jsonb;
BEGIN
  FOR person IN SELECT * FROM public.organization_professionals WHERE artist_id IS NULL FOR UPDATE LOOP
    artist := public.create_artist_with_roster(person.organization_id,person.organization_id,person.name);
    UPDATE public.organization_professionals SET artist_id=(artist->>'account_id')::uuid WHERE id=person.id;
  END LOOP;
END $$;

ALTER TABLE public.organization_professionals
  ALTER COLUMN artist_id SET NOT NULL,
  ADD CONSTRAINT organization_professionals_artist_unique UNIQUE (organization_id,artist_id);
COMMENT ON COLUMN public.organization_professionals.artist_id IS
  'Existing artist identity: accounts.id. Professional roles do not create a separate account type.';

-- Preserve each receipt's role snapshot and creation outcome, adding only the
-- account link so requests committed before rollout remain safely replayable.
UPDATE public.professional_roster_requests r
  SET result=jsonb_set(r.result,'{professional,artist_id}',to_jsonb(p.artist_id))
  FROM public.organization_professionals p
  WHERE r.organization_id=p.organization_id AND r.result->'professional'->>'id'=p.id::text;

CREATE OR REPLACE FUNCTION public.confirm_professional_roster(p_actor uuid,p_org uuid,p_key uuid,p_input jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE saved public.professional_roster_requests; person public.organization_professionals;
  role_set text[]; normalized_name text; payload jsonb; result jsonb; artist jsonb;
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
  IF p_input->>'mode'='new' AND (jsonb_typeof(p_input->'name') IS DISTINCT FROM 'string' OR normalized_name IS NULL OR length(normalized_name) NOT BETWEEN 2 AND 200 OR p_input->>'name' ~ '[[:cntrl:]]')
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
    -- Account, profile, roster links, roles and receipt commit or roll back together.
    artist := public.create_artist_with_roster(p_actor,p_org,normalized_name);
    INSERT INTO public.organization_professionals(organization_id,name,roles,confirmed_by,artist_id)
      VALUES(p_org,normalized_name,role_set,p_actor,(artist->>'account_id')::uuid) RETURNING * INTO person;
  ELSE
    SELECT * INTO person FROM public.organization_professionals WHERE id=(p_input->>'professional_id')::uuid AND organization_id=p_org FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Professional is not in this organization' USING ERRCODE='42501'; END IF;
    UPDATE public.organization_professionals SET roles=ARRAY(SELECT DISTINCT unnest(person.roles||role_set) ORDER BY 1),updated_at=now()
      WHERE id=person.id RETURNING * INTO person;
    INSERT INTO public.account_artist_ids(account_id,artist_id) VALUES (p_actor,person.artist_id)
      ON CONFLICT (account_id,artist_id) DO NOTHING;
    INSERT INTO public.artist_organization_ids(artist_id,organization_id) VALUES (person.artist_id,p_org)
      ON CONFLICT (artist_id,organization_id) DO NOTHING;
  END IF;
  result:=jsonb_build_object('professional',to_jsonb(person),'created',p_input->>'mode'='new');
  INSERT INTO public.professional_roster_requests(organization_id,request_key,actor_id,input,result) VALUES(p_org,p_key,p_actor,payload,result);
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.confirm_professional_roster(uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_professional_roster(uuid,uuid,uuid,jsonb) TO service_role;
