-- OAuth 2.1 with Dynamic Client Registration (DCR) for Recoup MCP.
--
-- Adds the minimum schema needed for Claude Cowork (and other MCP clients
-- that follow the 2025-06-18 MCP auth spec) to add api.recoupable.com/mcp
-- as a Custom Connector via the standard OAuth authorization-code flow.
--
-- Design summary:
--   * DCR is supported: oauth_clients rows are inserted by the /register
--     endpoint when Cowork (or any conforming client) registers itself.
--     Admin-issued Client ID/Secret pairs are NOT in scope — the connector
--     UI's "Advanced settings" path is deliberately unused.
--   * Authorization codes are PKCE-protected (S256 only) and short-lived.
--   * Access tokens reuse the existing account_api_keys table with three
--     new columns. This keeps the existing verifyBearerToken middleware
--     working for OAuth-issued tokens without a second lookup path.
--   * Refresh tokens are co-located on the same account_api_keys row
--     (refresh_token_hash). On refresh, the row is rotated in place.
--
-- Out of scope intentionally:
--   * Per-grant consent audit log. Consent is implicit on Privy sign-in
--     for the v0 rollout; add when compliance asks for it.
--   * Refresh-token chain history for replay-attack detection. We
--     just invalidate-on-rotate (clear refresh_token_hash + issue new pair).
--   * CIMD or Anthropic-held credentials. DCR covers Rostrum's scale;
--     revisit for public marketplace listing.

-- ---------------------------------------------------------------
-- oauth_clients: one row per DCR-registered MCP client.
-- ---------------------------------------------------------------
CREATE TABLE public.oauth_clients (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  client_id text NOT NULL,
  client_secret_hash text NOT NULL,
  name text NOT NULL,
  redirect_uris text[] NOT NULL,
  client_metadata jsonb NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT oauth_clients_pkey PRIMARY KEY (id),
  CONSTRAINT oauth_clients_client_id_key UNIQUE (client_id)
) TABLESPACE pg_default;

ALTER TABLE public.oauth_clients ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.oauth_clients TO service_role;

-- ---------------------------------------------------------------
-- oauth_authorization_codes: short-lived PKCE-protected codes
-- issued at /authorize and exchanged at /token.
-- ---------------------------------------------------------------
CREATE TABLE public.oauth_authorization_codes (
  code_hash text NOT NULL,
  client_id text NOT NULL,
  account uuid NOT NULL,
  redirect_uri text NOT NULL,
  scopes text[] NULL,
  code_challenge text NOT NULL,
  code_challenge_method text NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT oauth_authorization_codes_pkey PRIMARY KEY (code_hash),
  CONSTRAINT oauth_authorization_codes_client_id_fkey FOREIGN KEY (client_id)
    REFERENCES public.oauth_clients(client_id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT oauth_authorization_codes_account_fkey FOREIGN KEY (account)
    REFERENCES public.accounts(id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT oauth_authorization_codes_method_check CHECK (code_challenge_method = 'S256')
) TABLESPACE pg_default;

ALTER TABLE public.oauth_authorization_codes ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS oauth_authorization_codes_expires_at_idx
  ON public.oauth_authorization_codes(expires_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.oauth_authorization_codes TO service_role;

-- ---------------------------------------------------------------
-- account_api_keys: extend with OAuth metadata so the same table
-- holds both long-lived API keys and OAuth-issued access tokens.
--
-- Semantics for OAuth-issued rows:
--   * key_hash               — hash of current access token
--   * refresh_token_hash     — hash of paired refresh token
--   * expires_at             — access token expiry (NULL = never)
--   * issued_via_oauth_client_id — which oauth_clients row issued the pair
-- Rotation: update key_hash, refresh_token_hash, expires_at in place on
-- /token grant_type=refresh_token. The pre-rotation refresh token becomes
-- unusable as a side effect.
-- ---------------------------------------------------------------
ALTER TABLE public.account_api_keys
  ADD COLUMN IF NOT EXISTS issued_via_oauth_client_id text NULL
    REFERENCES public.oauth_clients(client_id) ON UPDATE CASCADE ON DELETE SET NULL;

ALTER TABLE public.account_api_keys
  ADD COLUMN IF NOT EXISTS refresh_token_hash text NULL;

ALTER TABLE public.account_api_keys
  ADD COLUMN IF NOT EXISTS expires_at timestamptz NULL;

-- Refresh lookups hit this column on every OAuth refresh; index it.
CREATE INDEX IF NOT EXISTS account_api_keys_refresh_token_hash_idx
  ON public.account_api_keys(refresh_token_hash)
  WHERE refresh_token_hash IS NOT NULL;

-- Expiry sweeps and validation checks also benefit from an index.
CREATE INDEX IF NOT EXISTS account_api_keys_expires_at_idx
  ON public.account_api_keys(expires_at)
  WHERE expires_at IS NOT NULL;
