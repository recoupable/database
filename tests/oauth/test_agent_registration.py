"""Atomic encrypted claim-state transitions against disposable PostgreSQL."""
import concurrent.futures
import json
import unittest
import test_store


class AgentRegistrationTest(unittest.TestCase):
    sql = test_store.OAuthStoreTest.sql
    setUp = test_store.OAuthStoreTest.setUp

    def transition(self, expected="pending", replacement="approved", namespace="test-issuer"):
        return self.sql(
            f"SELECT public.oauth_store_compare_and_swap('{namespace}', "
            f"'RecoupAgentRegistration', '{'a' * 64}', '{expected}', '{replacement}')"
        )

    def create_registration(self, check=True):
        return self.sql(
            f"SELECT public.oauth_store_upsert('test-issuer', 'RecoupAgentRegistration', "
            f"'{ 'a' * 64 }', 'pending', 4200, '{ 'b' * 64 }', NULL, NULL)",
            check=check,
        )

    def test_only_one_concurrent_claim_can_change_the_ciphertext(self):
        self.create_registration()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.transition(), range(8)))
        self.assertEqual(results.count("t"), 1)
        self.assertEqual(results.count("f"), 7)
        self.assertEqual(self.transition("approved", "denied"), "t")

    def test_cannot_transition_expired_revoked_missing_or_cross_issuer_state(self):
        self.assertEqual(self.transition(), "f")
        self.create_registration()
        self.assertEqual(self.transition(namespace="other-issuer"), "f")
        self.sql("UPDATE public.oauth_provider_artifacts SET expires_at = now() - interval '1 second'")
        self.assertEqual(self.transition(), "f")
        self.setUp()
        self.create_registration()
        self.sql(f"SELECT public.oauth_store_revoke_grant('test-issuer', '{'b' * 64}')")
        self.assertEqual(self.transition(), "f")

    def test_transition_never_recreates_a_revoked_registration(self):
        for _ in range(5):
            self.setUp()
            self.create_registration()
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                work = [
                    pool.submit(self.transition),
                    pool.submit(self.sql, f"SELECT public.oauth_store_revoke_grant('test-issuer', '{'b' * 64}')"),
                ]
                for result in work:
                    result.result()
            self.assertEqual(self.sql("SELECT count(*) FROM public.oauth_provider_artifacts"), "0")

    def test_cas_is_server_only_and_cannot_change_provider_token_models(self):
        for role in ("anon", "authenticated"):
            self.assertNotEqual(self.sql(
                f"SET ROLE {role}; SELECT public.oauth_store_compare_and_swap("
                f"'test-issuer','RecoupAgentRegistration','{'a' * 64}','pending','approved')",
                check=False,
            ).returncode, 0)
        for model in ("Grant", "AccessToken", "RecoupGrant"):
            self.assertNotEqual(self.sql(
                f"SELECT public.oauth_store_compare_and_swap("
                f"'test-issuer','{model}','{'a' * 64}','pending','approved')",
                check=False,
            ).returncode, 0)
        self.create_registration()
        self.assertEqual(self.sql(
            f"SET ROLE service_role; SELECT public.oauth_store_compare_and_swap("
            f"'test-issuer','RecoupAgentRegistration','{'a' * 64}','pending','approved')"
        ).splitlines()[-1], "t")

    def test_stale_upserts_cannot_replace_registration_state_or_extend_its_lifetime(self):
        self.create_registration()
        original = self.sql("SELECT grant_hash, expires_at, consumed_at FROM public.oauth_provider_artifacts")
        self.assertEqual(self.transition(), "t")
        self.assertNotEqual(self.create_registration(check=False).returncode, 0)
        self.assertEqual(self.sql("SELECT payload FROM public.oauth_provider_artifacts"), "approved")
        self.assertEqual(self.sql("SELECT grant_hash, expires_at, consumed_at FROM public.oauth_provider_artifacts"), original)

    def test_upsert_racing_with_transition_cannot_restore_stale_ciphertext(self):
        self.create_registration()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            transition = pool.submit(self.transition)
            stale_save = pool.submit(self.create_registration, False)
            self.assertEqual(transition.result(), "t")
            self.assertNotEqual(stale_save.result().returncode, 0)
        self.assertEqual(self.sql("SELECT payload FROM public.oauth_provider_artifacts"), "approved")

    def test_cleanup_removes_only_expired_registration_families_in_its_issuer(self):
        # Registration identifiers and grant hashes are the same in the API profile.
        for namespace, key in [("test-issuer", "a"), ("test-issuer", "c"), ("other-issuer", "d")]:
            self.sql(f"SELECT public.oauth_store_upsert('{namespace}', 'RecoupAgentRegistration', '{key * 64}', 'ciphertext', 4200, '{key * 64}', NULL, NULL)")
            self.sql(f"SELECT public.oauth_store_upsert('{namespace}', 'AccessToken', '{key * 64}', 'ciphertext', 300, '{key * 64}', NULL, NULL)")
        self.sql(f"UPDATE public.oauth_provider_artifacts SET expires_at = now() - interval '1 second' WHERE id_hash != '{'c' * 64}'")
        self.sql(f"SELECT public.oauth_store_revoke_grant('test-issuer', '{'e' * 64}')")
        self.assertEqual(self.sql("SELECT public.oauth_store_purge_agent_registrations('test-issuer')"), "2")
        self.assertEqual(
            self.sql("SELECT namespace, model, id_hash FROM public.oauth_provider_artifacts ORDER BY namespace, model"),
            "\n".join([
                f"other-issuer|AccessToken|{'d' * 64}",
                f"other-issuer|RecoupAgentRegistration|{'d' * 64}",
                f"test-issuer|AccessToken|{'c' * 64}",
                f"test-issuer|RecoupAgentRegistration|{'c' * 64}",
            ]),
        )
        self.assertEqual(self.sql("SELECT count(*) FROM public.oauth_revoked_grants"), "1")
        for role in ("anon", "authenticated"):
            self.assertNotEqual(self.sql(f"SET ROLE {role}; SELECT public.oauth_store_purge_agent_registrations('test-issuer')", check=False).returncode, 0)

    def test_cleanup_processes_at_most_one_hundred_expired_registrations(self):
        self.sql("""
            INSERT INTO public.oauth_provider_artifacts(namespace, model, id_hash, grant_hash, payload, expires_at)
            SELECT 'test-issuer', 'RecoupAgentRegistration', lpad(to_hex(i),64,'0'), lpad(to_hex(i),64,'0'), 'ciphertext', now() - interval '1 second'
            FROM generate_series(1,105) AS i
        """)
        self.assertEqual(self.sql("SELECT public.oauth_store_purge_agent_registrations('test-issuer')"), "100")
        self.assertEqual(self.sql("SELECT public.oauth_store_purge_agent_registrations('test-issuer')"), "5")

    def test_cleanup_can_select_an_issuer_batch_without_a_global_scan_or_sort(self):
        raw = self.sql("""
            SET enable_seqscan = off;
            EXPLAIN (FORMAT JSON)
            SELECT id_hash FROM public.oauth_provider_artifacts
            WHERE namespace = 'test-issuer' AND model = 'RecoupAgentRegistration'
              AND grant_hash = id_hash AND expires_at <= statement_timestamp()
            ORDER BY expires_at, id_hash LIMIT 100 FOR UPDATE SKIP LOCKED
        """)
        plan = json.loads(raw[raw.index("["):])[0]["Plan"]
        def nodes(node):
            yield node
            for child in node.get("Plans", []):
                yield from nodes(child)
        all_nodes = list(nodes(plan))
        self.assertFalse(any(node["Node Type"] in ("Sort", "Seq Scan") for node in all_nodes))
        scan = next(node for node in all_nodes if node["Node Type"] == "Index Scan")
        self.assertEqual(scan["Index Name"], "oauth_agent_registration_expiry_idx")
        self.assertIn("namespace", scan["Index Cond"])
        self.assertIn("expires_at", scan["Index Cond"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
