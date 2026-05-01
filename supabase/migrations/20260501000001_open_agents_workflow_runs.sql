-- Open Agents migration: workflow_runs + workflow_run_steps
-- Records each Vercel Workflow run and its per-step timings.
-- Primary observability surface for agent runs.

CREATE TABLE IF NOT EXISTS workflow_runs (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    model_id TEXT,
    status TEXT NOT NULL
        CHECK (status IN ('completed', 'aborted', 'failed')),
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ NOT NULL,
    total_duration_ms INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS workflow_runs_chat_id_idx ON workflow_runs(chat_id);
CREATE INDEX IF NOT EXISTS workflow_runs_session_id_idx ON workflow_runs(session_id);
CREATE INDEX IF NOT EXISTS workflow_runs_account_id_idx ON workflow_runs(account_id);

ALTER TABLE public.workflow_runs ENABLE ROW LEVEL SECURITY;

-- Per-step timings inside a workflow run
CREATE TABLE IF NOT EXISTS workflow_run_steps (
    id TEXT PRIMARY KEY,
    workflow_run_id TEXT NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
    step_number INTEGER NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ NOT NULL,
    duration_ms INTEGER NOT NULL,
    finish_reason TEXT,
    raw_finish_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS workflow_run_steps_run_id_idx ON workflow_run_steps(workflow_run_id);
CREATE UNIQUE INDEX IF NOT EXISTS workflow_run_steps_run_step_idx ON workflow_run_steps(workflow_run_id, step_number);

ALTER TABLE public.workflow_run_steps ENABLE ROW LEVEL SECURITY;
