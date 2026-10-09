"""Charge identity, rollback and concurrency against real local transactions."""
import concurrent.futures
import json
import uuid
from credit_charge_fixture import CreditChargeFixture


class CreditChargeReceipts(CreditChargeFixture):
    def setUp(self):
        self.owner = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',1000)")

    def statement(self, key='work-1', amount=100, event=None, owner=None):
        payload = json.dumps(event or {}).replace("'", "''")
        key = key.replace("'", "''")
        return (f"SET ROLE service_role; SELECT public.record_credit_charge_once("
                f"'{owner or self.owner}', '{key}', {amount}, '{payload}'::jsonb);")

    def charge(self, **kwargs):
        return json.loads(self.sql(self.statement(**kwargs)).stdout)

    def balance(self):
        return int(self.sql(f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'").stdout)

    def test_replay_after_lost_reply_preserves_receipt_and_balance(self):
        first = self.charge(event={'model_id': 'fixture', 'resource_url': '/fixture'})
        replay = self.charge(event={'model_id': 'fixture', 'resource_url': '/fixture'})
        self.assertEqual(first['state'], 'charged')
        self.assertEqual(replay['state'], 'reused')
        self.assertEqual(first['eventId'], replay['eventId'])
        self.assertEqual(replay['creditsCharged'], 100)
        self.assertEqual(self.balance(), 900)

    def test_concurrent_duplicate_requests_charge_once(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            receipts = list(pool.map(lambda _: self.charge(), range(12)))
        self.assertEqual(sum(r['state'] == 'charged' for r in receipts), 1)
        self.assertEqual(len({r['eventId'] for r in receipts}), 1)
        self.assertEqual(self.balance(), 900)

    def test_changed_amount_or_details_conflict(self):
        self.charge()
        for args in [{'amount': 101}, {'event': {'provider': 'different'}}]:
            result = self.sql(self.statement(**args), succeeds=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Credit charge identity conflict', result.stderr)
        self.assertEqual(self.balance(), 900)

    def test_independent_work_and_owners_do_not_share_receipts(self):
        first = self.charge()
        second = self.charge(key='work-2')
        other = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{other}',1000)")
        third = self.charge(owner=other)
        self.assertEqual(len({r['eventId'] for r in [first, second, third]}), 3)
        self.assertEqual(self.balance(), 800)

    def test_invalid_inputs_and_missing_wallet_never_debit(self):
        cases = [{'amount': 0}, {'amount': -1}, {'key': ''}, {'event': {'extra': True}},
                 {'event': {'input_tokens': -1}}, {'event': {'agent_type': 'invalid'}},
                 {'owner': str(uuid.uuid4())}]
        for args in cases:
            self.assertNotEqual(self.sql(self.statement(**args), succeeds=False).returncode, 0)
        self.assertEqual(self.balance(), 1000)

    def test_browser_roles_cannot_charge(self):
        for role in ['anon', 'authenticated']:
            result = self.sql(self.statement().replace('service_role', role), succeeds=False)
            self.assertIn('permission denied', result.stderr)
        self.assertEqual(self.balance(), 1000)

    def test_transaction_rollback_leaves_no_charge_or_receipt(self):
        self.sql('BEGIN;' + self.statement() + 'ROLLBACK;')
        self.assertEqual(self.balance(), 1000)
        self.assertEqual(self.charge()['state'], 'charged')

    def test_default_fields_match_explicit_defaults(self):
        self.charge()
        receipt = self.charge(event={'source': 'api', 'agent_type': 'main', 'input_tokens': 0})
        self.assertEqual(receipt['state'], 'reused')
        self.assertEqual(self.balance(), 900)

    def test_concurrent_conflicting_retry_never_changes_first_charge(self):
        def attempt(amount):
            return self.sql(self.statement(amount=amount), succeeds=False)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, [100, 200]))
        self.assertEqual(sum(r.returncode == 0 for r in results), 1)
        charged = next(json.loads(r.stdout)['creditsCharged'] for r in results if r.returncode == 0)
        self.assertEqual(self.balance(), 1000 - charged)

    def test_legacy_debit_and_new_charge_both_survive_concurrency(self):
        legacy = (f"SET ROLE service_role; SELECT deduct_credits_with_audit("
                  f"'{self.owner}',50::bigint,'legacy-{self.owner}','{{}}'::jsonb)")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(self.sql, [legacy, self.statement()]))
        self.assertEqual(self.balance(), 850)

    def test_duplicate_wallet_records_are_rejected_without_debit(self):
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',700)")
        result = self.sql(self.statement(), succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sql(f"SELECT sum(remaining_credits) FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip(), '1700')
