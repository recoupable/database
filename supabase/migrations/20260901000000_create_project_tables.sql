-- Create the client project status tables (recoupable/app#2048,
-- contract: recoupable/docs#326).
--
-- We send a paying client one link and they see what is done, what is in
-- flight, and what needs them. Nothing in this schema models that today:
-- scheduled_actions is agent automation on a Trigger.dev schedule, and these
-- are human milestones on a paid engagement. Superficially similar, unrelated
-- in purpose, so they get their own tables and share no code.
--
-- Four tables, deliberately small. The shape was reviewed twice and every
-- column that could not name a renderer was cut: projects.status (nothing
-- displays a project status), projects.client_account_id (project_collaborators
-- already answers who is on a project, and a second answer is a second thing to
-- get wrong), project_tasks.sort_order (the timeline is created in one pass, so
-- created_at orders it), and email / display_name / role from the collaborators
-- table (all recoverable from the account).

CREATE TABLE IF NOT EXISTS public.projects (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL CHECK (btrim(name) <> ''),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- No updated_at: there is no project-update endpoint, so the column would only
-- ever record a hand edit that nothing reads. project_tasks is the one table
-- here with an update path, and it is the one table that keeps the trigger.

CREATE TABLE IF NOT EXISTS public.project_tasks (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id          UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    title               TEXT NOT NULL CHECK (btrim(title) <> ''),
    description         TEXT,
    -- DATE, not TIMESTAMPTZ: "due Sep 12" has no time of day, and storing one
    -- invents a timezone question that the product never asks.
    due_date            DATE,
    -- Who the task is waiting on. This is what produces the client-facing
    -- "needs you" treatment: the page renders it when the assignee matches the
    -- viewing account. Nothing else in the schema distinguishes a task waiting
    -- on the client from one waiting on us. Not a boolean, so it does not
    -- hard-code that an engagement has exactly two sides.
    assignee_account_id UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
    -- NULL means not complete. This column is the completed state; there is no
    -- separate boolean to disagree with it.
    completed_at        TIMESTAMP WITH TIME ZONE,
    completed_by        UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- No CHECK pairing completed_at with completed_by, deliberately: ON DELETE SET
-- NULL on a removed account would violate it. A row with completed_at set and
-- completed_by NULL reads correctly as "done, by someone since removed".

-- The only read is "one project's tasks, in order".
CREATE INDEX IF NOT EXISTS project_tasks_project_created_idx
  ON public.project_tasks (project_id, created_at);

-- The access-control list, and nothing else. A row grants one account access to
-- one project; deleting it revokes.
--
-- Keyed on account_id rather than email: an email is not reliably unique in
-- this database (one address already maps to two accounts across the 1,320
-- account_emails rows), and a stored email is a copy that drifts from the
-- account it names. The cost is that access can only be granted to someone who
-- has signed in at least once, so an account exists to point at. Accepted.
--
-- No timestamps and no denormalized name: the account carries both.
CREATE TABLE IF NOT EXISTS public.project_collaborators (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE
);

-- One row per person per project. Also the index hasProjectAccess reads on
-- every single request, so the gate is one lookup.
CREATE UNIQUE INDEX IF NOT EXISTS project_collaborators_project_account_idx
  ON public.project_collaborators (project_id, account_id);

CREATE TABLE IF NOT EXISTS public.project_task_comments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id    UUID NOT NULL REFERENCES public.project_tasks(id) ON DELETE CASCADE,
    -- ON DELETE RESTRICT, deliberately, following credit_grants.granted_by
    -- (20260806230000): attribution is the point of the row and SET NULL would
    -- quietly destroy it. Deleting an account that has commented should fail
    -- loudly and be dealt with, not silently orphan what it said.
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
    body       TEXT NOT NULL CHECK (btrim(body) <> '' AND length(body) <= 4000),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- No updated_at and no deleted_at: comments are append-only in v1, so there is
-- nothing to update. Edit and delete are each a real feature with real edge
-- cases, and neither is needed to replace an email thread.

-- The feed read: one task's comments, oldest first, so it reads top to bottom.
CREATE INDEX IF NOT EXISTS project_task_comments_task_created_idx
  ON public.project_task_comments (task_id, created_at);

-- CREATE TRIGGER has no IF NOT EXISTS, so re-applying this file would fail here
-- even though every statement above is idempotent.
DROP TRIGGER IF EXISTS set_updated_at ON public.project_tasks;
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.project_tasks
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- RLS on with zero policies: denies anon and authenticated outright while
-- service_role, which is how the api reads and writes, bypasses.
--
-- This matters more here than on most tables. project_collaborators IS the
-- authorization model, so a table reachable through PostgREST with the anon key
-- would let anyone read the allowlist, or worse write themselves into it. The
-- other three carry a paying client's engagement status and their private
-- correspondence with us.
ALTER TABLE public.projects              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_tasks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_collaborators ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_task_comments ENABLE ROW LEVEL SECURITY;
