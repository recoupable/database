-- SECURITY INVOKER onboarding checks lock membership with SELECT ... FOR SHARE.
-- PostgreSQL requires UPDATE on at least one column for that lock. The preview
-- role has SELECT but no UPDATE; grant only the metadata column, not either
-- membership identity column. This adds no client-role, INSERT, DELETE, or identity-column grant.
GRANT UPDATE (updated_at) ON public.account_organization_ids TO service_role;
