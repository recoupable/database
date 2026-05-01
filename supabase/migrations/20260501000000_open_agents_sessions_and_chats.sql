-- Open Agents migration: sessions + chat tables
-- Ports the core agent-session schema from open-agents (apps/web/lib/db/schema.ts)
-- to recoupable production. user_id maps to existing accounts.id (uuid).
-- Per-user preference columns are dropped; user_preferences will not be ported.
-- PR-related columns are dropped per auto-commit/push design.

-- Sessions: agent runs bound to a sandbox + repo state
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running', 'completed', 'failed', 'archived')),
    -- Repository info
    repo_owner TEXT,
    repo_name TEXT,
    branch TEXT,
    clone_url TEXT,
    is_new_branch BOOLEAN NOT NULL DEFAULT FALSE,
    -- Skills installed into the sandbox at provision time
    global_skill_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
    -- Sandbox runtime state (Vercel Sandbox)
    sandbox_state JSONB,
    -- Lifecycle orchestration state for sandbox management
    lifecycle_state TEXT
        CHECK (lifecycle_state IN ('provisioning', 'active', 'hibernating', 'hibernated', 'restoring', 'archived', 'failed')),
    lifecycle_version INTEGER NOT NULL DEFAULT 0,
    last_activity_at TIMESTAMPTZ,
    sandbox_expires_at TIMESTAMPTZ,
    hibernate_after TIMESTAMPTZ,
    lifecycle_run_id TEXT,
    lifecycle_error TEXT,
    -- Git stats for session list display
    lines_added INTEGER DEFAULT 0,
    lines_removed INTEGER DEFAULT 0,
    -- Snapshot info (cached snapshots feature)
    snapshot_url TEXT,
    snapshot_created_at TIMESTAMPTZ,
    snapshot_size_bytes INTEGER,
    -- Cached diff for offline viewing
    cached_diff JSONB,
    cached_diff_updated_at TIMESTAMPTZ,
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sessions_account_id_idx ON sessions(account_id);

ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;

-- Chats: per-session chat threads
CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    model_id TEXT DEFAULT 'anthropic/claude-haiku-4.5',
    active_stream_id TEXT,
    last_assistant_message_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chats_session_id_idx ON chats(session_id);

ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;

-- Chat messages: full message parts as JSON
CREATE TABLE IF NOT EXISTS chat_messages (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    role TEXT NOT NULL
        CHECK (role IN ('user', 'assistant')),
    parts JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_messages_chat_id_idx ON chat_messages(chat_id);

ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- Chat reads: per-(account, chat) last-read marker
CREATE TABLE IF NOT EXISTS chat_reads (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, chat_id)
);

CREATE INDEX IF NOT EXISTS chat_reads_chat_id_idx ON chat_reads(chat_id);

ALTER TABLE public.chat_reads ENABLE ROW LEVEL SECURITY;

-- Shares: public share-link records for chat threads
CREATE TABLE IF NOT EXISTS shares (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS shares_chat_id_idx ON shares(chat_id);

ALTER TABLE public.shares ENABLE ROW LEVEL SECURITY;
