-- Create agent template email shares table
-- Stores raw invited email addresses for private agent template sharing

CREATE TABLE IF NOT EXISTS agent_template_email_shares (
  template_id uuid NOT NULL REFERENCES agent_templates(id) ON DELETE CASCADE,
  email text NOT NULL,
  created_at timestamp with time zone DEFAULT now(),
  PRIMARY KEY (template_id, email)
);

-- Indexes for lookups by template and email
CREATE INDEX IF NOT EXISTS idx_agent_template_email_shares_template_id
  ON agent_template_email_shares(template_id);

CREATE INDEX IF NOT EXISTS idx_agent_template_email_shares_email
  ON agent_template_email_shares(email);

-- Enable row level security
ALTER TABLE agent_template_email_shares ENABLE ROW LEVEL SECURITY;

-- Grant permissions
GRANT SELECT, INSERT, DELETE ON agent_template_email_shares TO authenticated;
GRANT SELECT, INSERT, DELETE ON agent_template_email_shares TO anon;
