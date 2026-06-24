-- Add optional expiry to account_api_keys for short-lived, account-scoped keys
-- (recoupable/chat#1813).
--
-- The async chat-generation path (POST /api/chat/generate, scheduled reports) has
-- no client Privy session to forward into the sandbox, and must NOT put the
-- long-lived service key into model-driven bash (exfiltration boundary, see
-- api/lib/agent/tools/AgentContext.ts). Instead it mints an ephemeral,
-- account-scoped recoup_sk_ key per run, injects it as $RECOUP_API_KEY, and
-- deletes it on completion. This column lets api auth reject such a key once its
-- TTL has passed (defense-in-depth if delete-on-run-end is missed).
--
-- NULL = never expires, so all existing (long-lived) keys are unaffected.
-- Enforcement lives in api (getApiKeyAccountId); this migration only adds the column.

ALTER TABLE public.account_api_keys
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

COMMENT ON COLUMN public.account_api_keys.expires_at IS
  'Optional expiry for ephemeral, account-scoped keys; NULL = never expires. Enforced in api auth (getApiKeyAccountId). recoupable/chat#1813.';
