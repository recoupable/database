-- Create agent template email shares table
-- Stores raw invited email addresses for private agent template sharing

CREATE TABLE IF NOT EXISTS public.agent_template_email_shares (
  template_id uuid NOT NULL REFERENCES public.agent_templates(id) ON DELETE CASCADE,
  email text NOT NULL,
  created_at timestamp with time zone DEFAULT now(),
  PRIMARY KEY (template_id, email)
);

-- Index for lookups by invited email
CREATE INDEX IF NOT EXISTS idx_agent_template_email_shares_email
  ON public.agent_template_email_shares(email);

-- Enable row level security
ALTER TABLE public.agent_template_email_shares ENABLE ROW LEVEL SECURITY;

-- Grant permissions
GRANT SELECT, INSERT, DELETE ON TABLE public.agent_template_email_shares TO authenticated;

COMMENT ON TABLE public.agent_template_email_shares IS 'Stores raw invited email addresses for private agent template sharing when the invitee does not yet resolve to an existing account.';
