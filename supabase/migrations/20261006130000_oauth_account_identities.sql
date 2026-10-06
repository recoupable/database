-- Bind verified Privy subjects to existing accounts without changing normal app onboarding.
BEGIN;
CREATE TABLE public.oauth_account_identities (
  provider_app_id text NOT NULL CHECK (length(provider_app_id) BETWEEN 1 AND 200),
  provider_subject text NOT NULL CHECK (length(provider_subject) BETWEEN 1 AND 300),
  -- Retain a tombstone after account deletion; never relink the subject through a new email.
  account_id uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (provider_app_id, provider_subject)
);
CREATE INDEX oauth_account_identities_account_idx ON public.oauth_account_identities(account_id);
ALTER TABLE public.oauth_account_identities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.oauth_account_identities FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON public.oauth_account_identities TO service_role;

-- Emails are server-verified Privy evidence, never request-body claims. Only service_role may call.
CREATE FUNCTION public.resolve_oauth_account(p_app_id text, p_subject text, p_verified_emails text[])
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE bound_account uuid; candidates uuid[];
BEGIN
  IF p_app_id IS NULL OR length(p_app_id) NOT BETWEEN 1 AND 200
     OR p_subject IS NULL OR length(p_subject) NOT BETWEEN 1 AND 300
     OR p_verified_emails IS NULL OR cardinality(p_verified_emails) > 20 THEN
    RAISE EXCEPTION 'Invalid OAuth identity evidence' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    pg_catalog.json_build_array(p_app_id, p_subject)::text, 0));
  SELECT account_id INTO bound_account FROM public.oauth_account_identities
    WHERE provider_app_id = p_app_id AND provider_subject = p_subject;
  IF FOUND THEN
    IF bound_account IS NULL THEN
      RAISE EXCEPTION 'OAuth account unavailable' USING ERRCODE = '22023';
    END IF;
    RETURN bound_account;
  END IF;
  SELECT array_agg(DISTINCT account.id) INTO candidates
    FROM public.account_emails AS email
    JOIN public.accounts AS account ON account.id = email.account_id
    WHERE lower(btrim(email.email)) IN (
      SELECT lower(btrim(value)) FROM unnest(p_verified_emails) AS value
      WHERE value IS NOT NULL AND length(value) BETWEEN 3 AND 320
    );
  IF coalesce(cardinality(candidates), 0) <> 1 THEN
    RAISE EXCEPTION 'OAuth requires one existing account' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.oauth_account_identities(provider_app_id, provider_subject, account_id)
    VALUES (p_app_id, p_subject, candidates[1]);
  RETURN candidates[1];
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_oauth_account(text,text,text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_oauth_account(text,text,text[]) TO service_role;
COMMIT;
