-- Migrate all org API keys to personal account fb678396-a68f-4294-ae50-b8cacf9ce77b
--
-- Background: Org API keys are being deprecated in favor of personal API keys.
-- Org API keys are identified by their `account` column pointing to an organization
-- account (i.e., any account that appears as `organization_id` in
-- account_organization_ids, meaning it has members).
--
-- This migration reassigns all such keys to the personal account
-- fb678396-a68f-4294-ae50-b8cacf9ce77b so they remain usable.

UPDATE public.account_api_keys
SET account = 'fb678396-a68f-4294-ae50-b8cacf9ce77b'
WHERE account IN (
  SELECT DISTINCT organization_id
  FROM public.account_organization_ids
  WHERE organization_id IS NOT NULL
)
AND account != 'fb678396-a68f-4294-ae50-b8cacf9ce77b';
