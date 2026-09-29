-- The initial account migrations predate explicit service-role grants.
-- Fresh preview databases must support the same server-side provisioning path.
grant select, insert, update, delete on public.accounts to service_role;
grant select, insert, update, delete on public.credits_usage to service_role;
