"""Real PostgreSQL acceptance tests. Run only via the disposable run.sh cluster."""
import concurrent.futures
import json
import os
import subprocess
import unittest


class OAuthStoreTest(unittest.TestCase):
    def sql(self, query, check=True):
        result = subprocess.run(
            [os.environ['OAUTH_TEST_PSQL'], '-X', '-w', '-h', os.environ['OAUTH_TEST_SOCKET'],
             '-p', '5432', '-U', 'oauth_test_admin', '-d', 'postgres', '-At', '-v', 'ON_ERROR_STOP=1', '-c', query],
            capture_output=True, text=True,
        )
        if check and result.returncode:
            self.fail(result.stderr)
        return result.stdout.strip() if check else result

    def setUp(self):
        self.sql('TRUNCATE public.oauth_provider_artifacts, public.oauth_revoked_grants')

    def put(self, model='AuthorizationCode', key='a', grant='b', ttl=300, namespace='test-issuer'):
        self.sql(f"SELECT public.oauth_store_upsert('{namespace}', '{model}', '{key * 64}', 'v1:encrypted-fixture', {ttl}, '{grant * 64}', NULL, NULL)")

    def find(self, key='a', namespace='test-issuer'):
        raw = self.sql(f"SELECT public.oauth_store_find('{namespace}', 'AuthorizationCode', 'id', '{key * 64}')")
        return json.loads(raw) if raw else None

    def test_round_trip_returns_ciphertext_and_no_plaintext_payload(self):
        self.put()
        self.assertEqual(self.find()['payload'], 'v1:encrypted-fixture')
        self.assertIsNone(self.find()['consumed'])
        self.assertEqual(self.find()['id_hash'], 'a' * 64)

    def test_simultaneous_consumption_has_exactly_one_winner(self):
        self.put()
        query = f"SELECT public.oauth_store_consume('test-issuer', 'AuthorizationCode', '{'a' * 64}')"
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.sql(query), range(8)))
        self.assertEqual(results.count('t'), 1)
        self.assertEqual(results.count('f'), 7)
        self.assertIsInstance(self.find()['consumed'], int)

    def test_upsert_cannot_reset_consumption(self):
        self.put()
        self.sql(f"SELECT public.oauth_store_consume('test-issuer', 'AuthorizationCode', '{'a' * 64}')")
        consumed = self.find()['consumed']
        self.put()
        self.assertEqual(self.find()['consumed'], consumed)
        self.assertEqual(self.sql(f"SELECT public.oauth_store_consume('test-issuer', 'AuthorizationCode', '{'a' * 64}')"), 'f')

    def test_namespace_isolation(self):
        self.put()
        self.assertIsNone(self.find(namespace='another-issuer'))
        self.assertEqual(self.sql(f"SELECT public.oauth_store_consume('another-issuer', 'AuthorizationCode', '{'a' * 64}')"), 'f')

    def test_expired_codes_are_invisible_and_cannot_be_consumed(self):
        self.put()
        self.sql("UPDATE public.oauth_provider_artifacts SET expires_at = now() - interval '1 second'")
        self.assertIsNone(self.find())
        self.assertEqual(self.sql(f"SELECT public.oauth_store_consume('test-issuer', 'AuthorizationCode', '{'a' * 64}')"), 'f')

    def test_revoke_grant_blocks_reads_and_late_writes(self):
        self.put()
        self.sql(f"SELECT public.oauth_store_revoke_grant('test-issuer', '{'b' * 64}')")
        self.assertIsNone(self.find())
        late = self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'AccessToken', '{'c' * 64}', 'encrypted', 300, '{'b' * 64}', NULL, NULL)", check=False)
        self.assertNotEqual(late.returncode, 0)
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_provider_artifacts'), '0')

    def test_revocation_racing_with_issuance_never_leaves_readable_token(self):
        self.put()
        issue = f"SELECT public.oauth_store_upsert('test-issuer', 'AuthorizationCode', '{'c' * 64}', 'encrypted', 300, '{'b' * 64}', NULL, NULL)"
        revoke = f"SELECT public.oauth_store_revoke_grant('test-issuer', '{'b' * 64}')"
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            writes = [pool.submit(self.sql, issue, False), pool.submit(self.sql, revoke)]
            for result in writes: result.result()
        self.assertIsNone(self.find(key='c'))
        self.assertIsNone(self.find())

    def test_revoking_one_grant_preserves_another(self):
        self.put()
        self.put(key='c', grant='d')
        self.sql(f"SELECT public.oauth_store_revoke_grant('test-issuer', '{'b' * 64}')")
        self.assertIsNone(self.find())
        self.assertIsNotNone(self.find(key='c'))

    def test_destroying_grant_creates_revocation_marker(self):
        self.put(model='Grant', key='b', grant='b')
        self.put()
        self.sql(f"SELECT public.oauth_store_destroy('test-issuer', 'Grant', '{'b' * 64}')")
        self.assertIsNone(self.find())
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_revoked_grants'), '1')

    def test_secondary_indexes_are_scoped_to_model_and_issuer(self):
        self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'Session', '{'a' * 64}', 'encrypted', 300, NULL, '{'e' * 64}', NULL)")
        self.assertTrue(self.sql(f"SELECT public.oauth_store_find('test-issuer', 'Session', 'uid', '{'e' * 64}')"))
        self.assertFalse(self.sql(f"SELECT public.oauth_store_find('other', 'Session', 'uid', '{'e' * 64}')"))
        self.assertFalse(self.sql(f"SELECT public.oauth_store_find('test-issuer', 'AuthorizationCode', 'uid', '{'e' * 64}')"))

    def test_anonymous_and_authenticated_roles_have_no_access(self):
        for role in ['anon', 'authenticated']:
            for query in ['SELECT * FROM public.oauth_provider_artifacts', f"SELECT public.oauth_store_find('test-issuer','AuthorizationCode','id','{'a' * 64}')"]:
                self.assertNotEqual(self.sql(f'SET ROLE {role}; {query}', check=False).returncode, 0)

    def test_stale_upsert_cannot_move_an_artifact_to_another_grant(self):
        self.put()
        changed = self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'AuthorizationCode', '{'a' * 64}', 'changed', 300, '{'c' * 64}', NULL, NULL)", check=False)
        self.assertNotEqual(changed.returncode, 0)
        self.assertEqual(self.find()['payload'], 'v1:encrypted-fixture')

    def test_bad_lifetimes_and_unhashed_identifiers_are_rejected(self):
        for ttl in [0, -1, 2678401]:
            result = self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'AuthorizationCode', '{'a' * 64}', 'encrypted', {ttl}, NULL, NULL, NULL)", check=False)
            self.assertNotEqual(result.returncode, 0)
        result = self.sql("SELECT public.oauth_store_upsert('test-issuer', 'Client', 'raw-secret', 'encrypted', NULL, NULL, NULL, NULL)", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_short_lived_artifacts_cannot_omit_expiry(self):
        for model in ['AuthorizationCode', 'AccessToken', 'Session', 'RecoupInteraction']:
            result = self.sql(f"SELECT public.oauth_store_upsert('test-issuer', '{model}', '{'a' * 64}', 'encrypted', NULL, NULL, NULL, NULL)", check=False)
            self.assertNotEqual(result.returncode, 0)
        self.put(model='Client', ttl='NULL')

    def test_null_lookup_index_is_rejected(self):
        result = self.sql(f"SELECT public.oauth_store_find('test-issuer', 'Session', NULL, '{'a' * 64}')", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_all_rpc_execute_privileges_are_server_only(self):
        for role in ['anon', 'authenticated', 'service_role']:
            result = self.sql(f"SELECT bool_and(has_function_privilege('{role}', oid, 'EXECUTE')) FROM pg_proc WHERE proname LIKE 'oauth_store_%'")
            if role == 'service_role':
                self.assertEqual(result, 't')
            else:
                self.assertEqual(self.sql(f"SELECT bool_or(has_function_privilege('{role}', oid, 'EXECUTE')) FROM pg_proc WHERE proname LIKE 'oauth_store_%'"), 'f')

    def test_delete_is_scoped_to_namespace_and_model(self):
        self.put()
        self.sql(f"SELECT public.oauth_store_destroy('another-issuer', 'AuthorizationCode', '{'a' * 64}')")
        self.assertIsNotNone(self.find())
        self.sql(f"SELECT public.oauth_store_destroy('test-issuer', 'Session', '{'a' * 64}')")
        self.assertIsNotNone(self.find())
        self.sql(f"SELECT public.oauth_store_destroy('test-issuer', 'AuthorizationCode', '{'a' * 64}')")
        self.assertIsNone(self.find())

    def test_connection_index_is_owner_scoped_immutable_and_revocation_aware(self):
        owner = 'e' * 64
        other = 'f' * 64
        grant = 'b' * 64
        self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'RecoupGrant', '{grant}', 'encrypted', 300, '{grant}', NULL, NULL, '{owner}')")
        def listing(account=owner, issuer='test-issuer'):
            return json.loads(self.sql(f"SELECT public.oauth_store_list_connections('{issuer}', '{account}')"))
        self.assertEqual(len(listing()), 1)
        self.assertEqual(listing(other), [])
        self.assertEqual(listing(issuer='other-issuer'), [])
        changed = self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'RecoupGrant', '{grant}', 'changed', 300, '{grant}', NULL, NULL, '{other}')", check=False)
        self.assertNotEqual(changed.returncode, 0)
        self.assertEqual(listing()[0]['payload'], 'encrypted')
        self.sql(f"SELECT public.oauth_store_revoke_grant('test-issuer', '{grant}')")
        self.assertEqual(listing(), [])

    def test_connection_index_omits_expired_grants(self):
        self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'RecoupGrant', '{'b' * 64}', 'encrypted', 300, '{'b' * 64}', NULL, NULL, '{'e' * 64}')")
        self.sql("UPDATE public.oauth_provider_artifacts SET expires_at = now() - interval '1 second'")
        self.assertEqual(json.loads(self.sql(f"SELECT public.oauth_store_list_connections('test-issuer', '{'e' * 64}')")), [])

    def test_connection_grants_require_both_immutable_bindings(self):
        for grant, owner in [("NULL", "NULL"), ("NULL", "'" + 'e' * 64 + "'"), ("'" + 'b' * 64 + "'", "NULL"), ("'" + 'c' * 64 + "'", "'" + 'e' * 64 + "'")]:
            result = self.sql(f"SELECT public.oauth_store_upsert('test-issuer', 'RecoupGrant', '{'b' * 64}', 'encrypted', 300, {grant}, NULL, NULL, {owner})", check=False)
            self.assertNotEqual(result.returncode, 0)

    def test_service_role_can_use_functions(self):
        self.assertEqual(self.sql(f"SET ROLE service_role; SELECT public.oauth_store_consume('test-issuer','AuthorizationCode','{'a' * 64}')").splitlines()[-1], 'f')


if __name__ == '__main__':
    unittest.main(verbosity=2)
