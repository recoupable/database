CREATE TABLE public.research_cache_entries (
  cache_key text NOT NULL,
  provider text NOT NULL,
  endpoint text NOT NULL,
  entity_type text NOT NULL,
  entity_id text NOT NULL,
  source text,
  query jsonb NOT NULL DEFAULT '{}'::jsonb,
  data jsonb,
  raw_data jsonb,
  status text NOT NULL DEFAULT 'refreshing',
  status_code integer,
  error text,
  fetched_at timestamp with time zone,
  expires_at timestamp with time zone,
  refresh_started_at timestamp with time zone,
  refresh_run_id text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT research_cache_entries_pkey PRIMARY KEY (cache_key),
  CONSTRAINT research_cache_entries_status_check CHECK (
    status IN ('refreshing', 'ready', 'failed')
  )
);

ALTER TABLE public.research_cache_entries ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS research_cache_entries_lookup_idx
  ON public.research_cache_entries(provider, endpoint, entity_type, entity_id, source);

CREATE INDEX IF NOT EXISTS research_cache_entries_expires_at_idx
  ON public.research_cache_entries(expires_at);

CREATE INDEX IF NOT EXISTS research_cache_entries_refresh_idx
  ON public.research_cache_entries(status, refresh_started_at);

CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.research_cache_entries
  FOR EACH ROW
  EXECUTE FUNCTION trigger_set_updated_at();
