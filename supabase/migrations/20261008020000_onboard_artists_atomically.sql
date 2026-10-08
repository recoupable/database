-- Atomic Spotify onboarding for POST /artists. No cleanup or identity reassignment.
-- Deploy before the API consumer. Only the trusted API may supply p_account_id.
CREATE OR REPLACE FUNCTION public.onboard_spotify_artist(
  p_account_id uuid,
  p_organization_id uuid,
  p_name text,
  p_spotify_artist_id text
) RETURNS TABLE (artist_id uuid, created boolean)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  v_artist_id uuid;
  v_candidates uuid[];
  v_social_id uuid;
  v_created boolean := false;
BEGIN
  IF p_account_id IS NULL OR p_name IS NULL OR btrim(p_name) = ''
     OR p_spotify_artist_id IS NULL OR p_spotify_artist_id !~ '^[A-Za-z0-9]{22}$' THEN
    RAISE EXCEPTION 'Invalid artist onboarding input' USING ERRCODE = '22023';
  END IF;

  -- Cross-process serialization, preserving case. A hash collision only causes
  -- extra waiting; identity matching below always uses the complete provider ID.
  PERFORM pg_advisory_xact_lock(hashtextextended('spotify-artist:' || p_spotify_artist_id, 0));

  -- Recheck after waiting. Lock membership until commit so revocation cannot
  -- pass between the permission check and the organization relationship write.
  IF p_organization_id IS NOT NULL AND p_account_id <> p_organization_id THEN
    PERFORM 1 FROM public.account_organization_ids aoi
      WHERE aoi.account_id = p_account_id AND aoi.organization_id = p_organization_id
      FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Access denied to specified organization_id' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Match complete Spotify artist resources only. Never lower-case provider IDs,
  -- match name/substring, or silently pick an account when existing links conflict.
  SELECT array_agg(DISTINCT a.account_id) INTO v_candidates
    FROM public.socials s
    JOIN public.account_socials a ON a.social_id = s.id
    WHERE substring(s.profile_url FROM '^(?:(?:https?://)?open[.]spotify[.]com/(?:intl-[a-z]{2}/)?artist/|spotify:artist:)([A-Za-z0-9]{22})(?:[/?#].*)?$') = p_spotify_artist_id;
  IF cardinality(v_candidates) > 1 THEN
    RAISE EXCEPTION 'Spotify artist identity is ambiguous; resolve the conflicting links before retrying'
      USING ERRCODE = '21000';
  END IF;
  v_artist_id := v_candidates[1];

  IF v_artist_id IS NULL THEN
    INSERT INTO public.accounts(name) VALUES (p_name) RETURNING id INTO v_artist_id;
    INSERT INTO public.account_info(account_id) VALUES (v_artist_id);
    INSERT INTO public.socials(username, profile_url)
      VALUES (p_spotify_artist_id, 'https://open.spotify.com/artist/' || p_spotify_artist_id)
      ON CONFLICT (profile_url) DO UPDATE SET profile_url = EXCLUDED.profile_url
      RETURNING id INTO v_social_id;
    INSERT INTO public.account_socials(account_id, social_id) VALUES (v_artist_id, v_social_id);
    v_created := true;
  END IF;

  INSERT INTO public.account_artist_ids(account_id, artist_id) VALUES (p_account_id, v_artist_id)
    ON CONFLICT (account_id, artist_id) DO NOTHING;
  IF p_organization_id IS NOT NULL THEN
    INSERT INTO public.artist_organization_ids(artist_id, organization_id) VALUES (v_artist_id, p_organization_id)
      ON CONFLICT (artist_id, organization_id) DO NOTHING;
  END IF;
  RETURN QUERY SELECT v_artist_id, v_created;
END;
$$;

REVOKE ALL ON FUNCTION public.onboard_spotify_artist(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.onboard_spotify_artist(uuid, uuid, text, text) TO service_role;
COMMENT ON FUNCTION public.onboard_spotify_artist(uuid, uuid, text, text) IS
  'API-only atomic resolve/create and roster attachment by exact Spotify artist ID. Rejects ambiguity; grants no catalog rights.';

-- Legacy name-only artist creation must not leave partial records on failure.
-- This does not infer person identity, professional roles, or deduplicate by name.
CREATE OR REPLACE FUNCTION public.create_artist_with_roster(
  p_account_id uuid, p_organization_id uuid, p_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts;
  v_info public.account_info;
BEGIN
  IF p_account_id IS NULL OR p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Invalid artist onboarding input' USING ERRCODE = '22023';
  END IF;
  IF p_organization_id IS NOT NULL AND p_account_id <> p_organization_id THEN
    PERFORM 1 FROM public.account_organization_ids aoi
      WHERE aoi.account_id = p_account_id AND aoi.organization_id = p_organization_id
      FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Access denied to specified organization_id' USING ERRCODE = '42501';
    END IF;
  END IF;
  INSERT INTO public.accounts(name) VALUES (p_name) RETURNING * INTO v_account;
  INSERT INTO public.account_info(account_id) VALUES (v_account.id) RETURNING * INTO v_info;
  INSERT INTO public.account_artist_ids(account_id,artist_id) VALUES (p_account_id,v_account.id);
  IF p_organization_id IS NOT NULL THEN
    INSERT INTO public.artist_organization_ids(artist_id,organization_id) VALUES (v_account.id,p_organization_id);
  END IF;
  RETURN to_jsonb(v_account) || jsonb_build_object(
    'account_id', v_account.id, 'account_info', jsonb_build_array(to_jsonb(v_info)),
    'account_socials', '[]'::jsonb, 'created_at', to_jsonb(v_account)->'timestamp',
    'updated_at', to_jsonb(v_info)->'updated_at'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.create_artist_with_roster(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_artist_with_roster(uuid, uuid, text) TO service_role;
