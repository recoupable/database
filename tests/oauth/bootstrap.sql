-- Only for a fresh disposable PostgreSQL cluster; never run against Supabase.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
