-- SYNTHETIC TEST SETUP ONLY. Never import in a production migration/runtime.
-- Minimal existing-account stand-in, not an account creation path in the candidate.
CREATE TABLE public.accounts(id uuid PRIMARY KEY);
INSERT INTO public.accounts VALUES ('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002');
CREATE SCHEMA qualification_auth;
REVOKE ALL ON SCHEMA qualification_auth FROM PUBLIC;
-- No tokens, keys or verifier algorithm: a small test double for fresh trusted verification.
CREATE FUNCTION qualification_auth.original_actor(observation text) RETURNS uuid
 LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF observation IS DISTINCT FROM 'current-key' THEN RAISE EXCEPTION 'verification unavailable'; END IF;
 RETURN '00000000-0000-0000-0000-000000000001'::uuid;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA qualification_auth FROM PUBLIC;
