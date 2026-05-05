-- Open Agents migration: usage_events
-- Ports the per-LLM-turn token-usage event log from open-agents
-- (apps/web/lib/db/schema.ts) to recoupable Supabase as part of
-- the database-unification work.
--
-- This is the only open-agents-only feature being ported beyond
-- the core agent-state tables (sessions/chats/chat_messages/etc.):
-- it powers both the contribution heatmap on /settings and the
-- per-model leaderboard, neither of which can be reconstructed
-- from the existing credits_usage table (which models account
-- balance, not per-event consumption).
--
-- Drizzle-side `user_id` (text/nanoid → users.id) is replaced with
-- `account_id` (uuid → recoupable accounts.id) per the unification
-- decision to drop open-agents' independent users table.

CREATE TABLE IF NOT EXISTS usage_events (
    id TEXT PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    source TEXT NOT NULL DEFAULT 'web'
        CHECK (source IN ('web')),
    agent_type TEXT NOT NULL DEFAULT 'main'
        CHECK (agent_type IN ('main', 'subagent')),
    provider TEXT,
    model_id TEXT,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    cached_input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    tool_call_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Heatmap + leaderboard queries filter by (account_id, date(created_at))
-- and aggregate over modelId. The composite index covers both axes.
CREATE INDEX IF NOT EXISTS usage_events_account_id_created_at_idx
    ON usage_events (account_id, created_at);

-- Per-model leaderboard groups by model_id; partial index keeps it
-- compact since some events have no model_id (subagent steps, etc.).
CREATE INDEX IF NOT EXISTS usage_events_model_id_idx
    ON usage_events (model_id)
    WHERE model_id IS NOT NULL;

ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;
