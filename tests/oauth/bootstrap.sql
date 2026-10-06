-- Only for a fresh disposable PostgreSQL cluster; never run against Supabase.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
-- Minimal account tables for identity-mapping contract tests, not the full production schema.
CREATE TABLE public.accounts (id uuid PRIMARY KEY);
CREATE TABLE public.account_emails (account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE, email text);
GRANT SELECT ON public.accounts, public.account_emails TO service_role;
