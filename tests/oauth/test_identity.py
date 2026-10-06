"""Existing-account identity binding against disposable PostgreSQL."""
import concurrent.futures
import unittest
from test_store import OAuthStoreTest

A = '00000000-0000-4000-8000-000000000001'
B = '00000000-0000-4000-8000-000000000002'

class OAuthIdentityTest(unittest.TestCase):
    sql = OAuthStoreTest.sql
    def setUp(self):
        self.sql('TRUNCATE public.oauth_account_identities, public.account_emails, public.accounts CASCADE')
        self.sql(f"INSERT INTO public.accounts VALUES ('{A}'), ('{B}'); INSERT INTO public.account_emails VALUES ('{A}', 'alice@example.test'), ('{B}', 'bob@example.test')")

    def bind(self, subject='did:privy:alice', emails="ARRAY['alice@example.test']", app='app', check=True):
        return self.sql(f"SELECT public.resolve_oauth_account('{app}', '{subject}', {emails})", check=check)

    def test_first_verified_email_binds_existing_account(self):
        self.assertEqual(self.bind(emails="ARRAY[' Alice@Example.Test ' ]"), A)

    def test_mapping_survives_email_changes_without_switching_account(self):
        self.assertEqual(self.bind(), A)
        self.assertEqual(self.bind(emails="ARRAY['bob@example.test']"), A)
        self.assertEqual(self.bind(emails="ARRAY[]::text[]"), A)

    def test_missing_or_ambiguous_email_never_creates_an_account(self):
        for emails in ["ARRAY[]::text[]", "ARRAY['unknown@example.test']", "ARRAY['alice@example.test', 'bob@example.test']"]:
            self.assertNotEqual(self.bind(emails=emails, check=False).returncode, 0)
        self.assertEqual(self.sql('SELECT count(*) FROM public.accounts'), '2')
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_account_identities'), '0')

    def test_duplicate_email_rows_for_one_account_are_unambiguous(self):
        self.sql(f"INSERT INTO public.account_emails VALUES ('{A}', 'alice@example.test')")
        self.assertEqual(self.bind(), A)

    def test_deleted_account_is_not_silently_rebound(self):
        self.bind()
        self.sql(f"DELETE FROM public.accounts WHERE id = '{A}'")
        self.assertNotEqual(self.bind(emails="ARRAY['bob@example.test']", check=False).returncode, 0)

    def test_concurrent_first_links_are_immutable(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda email: self.bind(emails=f"ARRAY['{email}']"), ['alice@example.test', 'bob@example.test']))
        self.assertEqual(len(set(results)), 1)
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_account_identities'), '1')

    def test_apps_are_isolated(self):
        self.assertEqual(self.bind(), A)
        self.assertEqual(self.bind(app='other-app', emails="ARRAY['bob@example.test']"), B)

    def test_identity_rpc_and_table_are_server_only(self):
        for role in ['anon', 'authenticated']:
            self.assertEqual(self.sql(f"SELECT has_function_privilege('{role}', 'public.resolve_oauth_account(text,text,text[])', 'EXECUTE')"), 'f')
            self.assertNotEqual(self.sql(f'SET ROLE {role}; SELECT * FROM public.oauth_account_identities', check=False).returncode, 0)
        self.assertEqual(self.sql(f"SET ROLE service_role; SELECT public.resolve_oauth_account('app', 'did:privy:service', ARRAY['alice@example.test'])").splitlines()[-1], A)

if __name__ == '__main__':
    unittest.main(defaultTest='OAuthIdentityTest', verbosity=2)
