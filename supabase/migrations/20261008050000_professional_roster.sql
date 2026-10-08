-- Organization-private professional records. No login identity or catalog rights.
CREATE TABLE public.organization_professionals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.accounts(id),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 200),
  roles text[] NOT NULL CHECK (cardinality(roles) BETWEEN 1 AND 2 AND roles <@ ARRAY['songwriter','producer']::text[] AND array_position(roles,NULL) IS NULL),
  confirmed_by uuid NOT NULL REFERENCES public.accounts(id),
  confirmation_basis text NOT NULL DEFAULT 'operator_confirmed' CHECK (confirmation_basis='operator_confirmed'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX organization_professionals_roster ON public.organization_professionals(organization_id,id);
CREATE TABLE public.professional_roster_requests (
  organization_id uuid NOT NULL REFERENCES public.accounts(id),
  request_key uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.accounts(id),
  input jsonb NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,request_key)
);
ALTER TABLE public.organization_professionals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.professional_roster_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.organization_professionals, public.professional_roster_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT,INSERT,UPDATE ON public.organization_professionals TO service_role;
GRANT SELECT,INSERT ON public.professional_roster_requests TO service_role;
