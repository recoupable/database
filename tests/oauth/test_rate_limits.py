"""Rate-limit acceptance tests against the disposable PostgreSQL cluster only."""
import concurrent.futures
import unittest
import test_store


class OAuthRateLimitTest(unittest.TestCase):
    sql = test_store.OAuthStoreTest.sql

    def setUp(self):
        self.sql('TRUNCATE public.oauth_rate_limits')

    def consume(self, limits=(3, 2), namespace='a', keys=('b', 'c')):
        hashes = ','.join("'" + key * 64 + "'" for key in keys)
        values = ','.join(str(limit) for limit in limits)
        return int(self.sql(f"SELECT public.consume_oauth_rate_limit('{namespace * 64}', ARRAY[{hashes}], ARRAY[{values}])"))

    def test_rejected_peer_does_not_consume_shared_budget(self):
        self.assertEqual(self.consume(), 0)
        self.assertEqual(self.consume(), 0)
        self.assertGreater(self.consume(), 0)
        self.assertEqual(self.sql(f"SELECT count FROM public.oauth_rate_limits WHERE key_hash = '{'b' * 64}'"), '2')
        self.assertEqual(self.consume(keys=('b', 'd')), 0)
        self.assertGreater(self.consume(keys=('b', 'e')), 0)
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_rate_limits'), '3')

    def test_concurrent_requests_cannot_exceed_budget(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(lambda _: self.consume((5, 5)), range(12)))
        self.assertEqual(results.count(0), 5)
        self.assertTrue(all(0 <= value <= 60 for value in results))

    def test_expiry_restarts_budget_and_removes_old_peer_rows(self):
        self.consume()
        self.sql("UPDATE public.oauth_rate_limits SET expires_at = clock_timestamp() - interval '1 second'")
        self.assertEqual(self.consume(keys=('b', 'd')), 0)
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_rate_limits'), '2')
        self.assertEqual(self.sql('SELECT max(count) FROM public.oauth_rate_limits'), '1')

    def test_namespace_isolation(self):
        self.consume((1, 1))
        self.assertGreater(self.consume((1, 1)), 0)
        self.assertEqual(self.consume((1, 1), namespace='f'), 0)

    def test_invalid_inputs_fail_without_writing(self):
        for keys, limits in [("NULL", 'ARRAY[1]'), ("ARRAY[]::text[]", 'ARRAY[]::int[]'),
                             ("ARRAY['bad']", 'ARRAY[1]'), (f"ARRAY['{'b' * 64}']", 'ARRAY[0]'),
                             (f"ARRAY['{'b' * 64}']", 'ARRAY[NULL]::int[]'),
                             (f"ARRAY['{'b' * 64}','{'b' * 64}']", 'ARRAY[1,1]')]:
            result = self.sql(f"SELECT public.consume_oauth_rate_limit('{'a' * 64}', {keys}, {limits})", check=False)
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sql('SELECT count(*) FROM public.oauth_rate_limits'), '0')

    def test_only_service_role_can_access_counters(self):
        for role in ['anon', 'authenticated']:
            self.assertEqual(self.sql(f"SELECT has_function_privilege('{role}', 'public.consume_oauth_rate_limit(text,text[],integer[])', 'EXECUTE')"), 'f')
            self.assertNotEqual(self.sql(f'SET ROLE {role}; SELECT * FROM public.oauth_rate_limits', check=False).returncode, 0)
        self.assertEqual(self.sql(f"SET ROLE service_role; SELECT public.consume_oauth_rate_limit('{'a' * 64}', ARRAY['{'b' * 64}'], ARRAY[1])").splitlines()[-1], '0')


if __name__ == '__main__':
    unittest.main()
