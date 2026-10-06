-- OAuth budgets share the existing authorization database, not the song queue's Redis.
BEGIN;
CREATE TABLE public.oauth_rate_limits (
  namespace text NOT NULL CHECK (namespace ~ '^[a-f0-9]{64}$'),
  key_hash text NOT NULL CHECK (key_hash ~ '^[a-f0-9]{64}$'),
  count integer NOT NULL CHECK (count > 0),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (namespace, key_hash)
);
CREATE INDEX oauth_rate_limits_expiry_idx ON public.oauth_rate_limits (namespace, expires_at);
ALTER TABLE public.oauth_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.oauth_rate_limits FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.oauth_rate_limits TO service_role;

CREATE FUNCTION public.consume_oauth_rate_limit(p_namespace text, p_keys text[], p_limits integer[])
RETURNS integer LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_now timestamptz;
  retry_after integer;
  i integer;
BEGIN
  IF p_namespace IS NULL OR p_namespace !~ '^[a-f0-9]{64}$'
    OR p_keys IS NULL OR p_limits IS NULL OR cardinality(p_keys) NOT BETWEEN 1 AND 4
    OR cardinality(p_keys) <> cardinality(p_limits)
    OR array_ndims(p_keys) <> 1 OR array_ndims(p_limits) <> 1
    OR array_lower(p_keys, 1) <> 1 OR array_lower(p_limits, 1) <> 1
    OR (SELECT count(DISTINCT key) FROM unnest(p_keys) key) <> cardinality(p_keys) THEN
    RAISE EXCEPTION 'Invalid OAuth budgets' USING ERRCODE = '22023';
  END IF;
  FOR i IN 1..cardinality(p_keys) LOOP
    IF p_keys[i] IS NULL OR p_keys[i] !~ '^[a-f0-9]{64}$'
      OR p_limits[i] IS NULL OR p_limits[i] NOT BETWEEN 1 AND 1200 THEN
      RAISE EXCEPTION 'Invalid OAuth budgets' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  -- All budgets for an issuer are checked and incremented as one transaction.
  PERFORM pg_advisory_xact_lock(hashtextextended('oauth-rate:' || p_namespace, 0));
  v_now := clock_timestamp();
  DELETE FROM public.oauth_rate_limits WHERE namespace = p_namespace AND expires_at <= v_now;
  SELECT coalesce(ceil(max(extract(epoch FROM (r.expires_at - v_now)))), 0)::integer
    INTO retry_after
    FROM unnest(p_keys, p_limits) AS b(key_hash, budget_limit)
    JOIN public.oauth_rate_limits r ON r.namespace = p_namespace AND r.key_hash = b.key_hash
    WHERE r.count >= b.budget_limit;
  IF retry_after > 0 THEN RETURN retry_after; END IF;
  INSERT INTO public.oauth_rate_limits (namespace, key_hash, count, expires_at)
    SELECT p_namespace, key, 1, v_now + interval '60 seconds' FROM unnest(p_keys) key
    ON CONFLICT (namespace, key_hash) DO UPDATE SET count = public.oauth_rate_limits.count + 1;
  RETURN 0;
END;
$$;
REVOKE ALL ON FUNCTION public.consume_oauth_rate_limit(text, text[], integer[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_oauth_rate_limit(text, text[], integer[]) TO service_role;
COMMIT;
