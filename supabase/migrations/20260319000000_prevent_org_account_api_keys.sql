-- Migration: Prevent API keys from being created for organization accounts
-- An account is an "organization" if it exists in the organization_id column
-- of the account_organization_ids table. API keys should only be issued to
-- individual member accounts, never to the org account itself.

CREATE OR REPLACE FUNCTION public.prevent_org_account_api_keys()
RETURNS trigger AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.account_organization_ids
    WHERE organization_id = NEW.account
  ) THEN
    RAISE EXCEPTION
      'Cannot create an API key for an organization account (account_id: %)',
      NEW.account;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_org_account_api_keys_trigger
  BEFORE INSERT OR UPDATE ON public.account_api_keys
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_org_account_api_keys();
