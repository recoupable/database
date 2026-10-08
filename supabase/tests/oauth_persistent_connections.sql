-- Isolated fixture only. Run after the OAuth migrations; all writes roll back.
BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  ns text := 'persistent-fixture-' || gen_random_uuid()::text;
  grant_id text := repeat('a',64);
  account_id text := repeat('b',64);
  item jsonb;
  rejected boolean;
  model_name text;
BEGIN
  FOREACH model_name IN ARRAY ARRAY['Grant','RefreshToken','RecoupGrant'] LOOP
    PERFORM public.oauth_store_upsert(ns,model_name,grant_id,'encrypted-fixture',NULL,grant_id,NULL,NULL,account_id);
    IF NOT EXISTS (SELECT 1 FROM public.oauth_provider_artifacts WHERE namespace=ns AND model=model_name AND expires_at IS NULL) THEN
      RAISE EXCEPTION 'Persistent record has database expiry';
    END IF;
  END LOOP;
  item := public.oauth_store_list_connections(ns,account_id);
  IF jsonb_array_length(item) <> 1 THEN RAISE EXCEPTION 'Persistent connection missing'; END IF;
  FOREACH model_name IN ARRAY ARRAY['AccessToken','AuthorizationCode','Session','RecoupInteraction'] LOOP
    rejected := false;
    BEGIN
      PERFORM public.oauth_store_upsert(ns,model_name,grant_id,'encrypted-fixture',NULL,grant_id,NULL,NULL);
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Short-lived artifact accepted without expiry'; END IF;
  END LOOP;
  PERFORM public.oauth_store_upsert(ns,'Grant',repeat('c',64),'finite-fixture',300,NULL,NULL,NULL);
  rejected := false;
  BEGIN
    PERFORM public.oauth_store_upsert(ns,'Grant',repeat('c',64),'persistent-overwrite',NULL,NULL,NULL,NULL);
  EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Finite approval silently extended'; END IF;
  PERFORM public.oauth_store_revoke_grant(ns,grant_id);
  IF jsonb_array_length(public.oauth_store_list_connections(ns,account_id)) <> 0 THEN RAISE EXCEPTION 'Revoked connection remains'; END IF;
  IF public.oauth_store_find(ns,'RefreshToken','id',grant_id) IS NOT NULL THEN RAISE EXCEPTION 'Revoked refresh remains'; END IF;
  rejected := false;
  BEGIN
    PERFORM public.oauth_store_upsert(ns,'RefreshToken',grant_id,'encrypted-fixture',NULL,grant_id,NULL,NULL);
  EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Revoked grant resurrected'; END IF;
END;
$$;
ROLLBACK;
