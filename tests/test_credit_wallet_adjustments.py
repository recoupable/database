"""Atomic refill/top-up wallet writers against real local transactions; no hosted balances."""
import concurrent.futures
import json
import subprocess
import threading
import time
import uuid
from credit_charge_fixture import CreditChargeFixture, ROOT

MIGRATION = ROOT / 'supabase/migrations/20261010212300_credit_wallet_atomic_adjustments.sql'
SEED_STAMP = '2026-01-01 00:00:00'


class CreditWalletAdjustments(CreditChargeFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # Production stores the refill timestamp without time zone (20241209025457).
        cls.sql('ALTER TABLE public.credits_usage ADD COLUMN "timestamp" timestamp DEFAULT CURRENT_TIMESTAMP')
        cls.sql(MIGRATION.read_text())

    def setUp(self):
        self.owner = str(uuid.uuid4())

    def seed(self, balance=1000):
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits,\"timestamp\") "
                 f"VALUES ('{self.owner}',{balance},'{SEED_STAMP}')")

    def refill_statement(self, floor=1000, role='service_role'):
        return f"SET ROLE {role}; SELECT public.refill_credits_to_floor('{self.owner}', {floor});"

    def increment_statement(self, delta=100, role='service_role'):
        return f"SET ROLE {role}; SELECT public.increment_credits_atomic('{self.owner}', {delta});"

    def charge_statement(self, key='work-1', amount=100):
        return (f"SET ROLE service_role; SELECT public.record_credit_charge_once("
                f"'{self.owner}', '{key}', {amount}, '{{}}'::jsonb);")

    def refill(self, **kwargs):
        return json.loads(self.sql(self.refill_statement(**kwargs)).stdout)

    def increment(self, **kwargs):
        return json.loads(self.sql(self.increment_statement(**kwargs)).stdout)

    def wallet(self):
        out = self.sql(f"SELECT remaining_credits, \"timestamp\" FROM credits_usage "
                       f"WHERE account_id='{self.owner}'").stdout.strip()
        balance, stamp = out.split('|')
        return int(balance), stamp

    def failing(self, statement):
        result = self.sql('\\set VERBOSITY verbose\n' + statement, succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        return result.stderr

    def test_concurrent_top_ups_are_all_kept(self):
        self.seed(1000)
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            receipts = list(pool.map(lambda _: self.increment(delta=100), range(12)))
        # Every increment saw a distinct serialized balance; none was lost.
        self.assertEqual(sorted(r['remainingCredits'] for r in receipts), list(range(1100, 2300, 100)))
        self.assertEqual(self.wallet(), (2200, SEED_STAMP))

    def test_refill_is_a_floor_and_always_advances_the_timestamp(self):
        self.seed(300)
        raised = self.refill(floor=1000)
        self.assertEqual((raised['state'], raised['remainingCredits']), ('raised', 1000))
        balance, stamp = self.wallet()
        self.assertEqual(balance, 1000)
        self.assertGreater(stamp, SEED_STAMP)
        self.assertEqual(raised['timestamp'].replace('T', ' '), stamp)

        self.sql(f"UPDATE credits_usage SET remaining_credits=1500, \"timestamp\"='{SEED_STAMP}' "
                 f"WHERE account_id='{self.owner}'")
        unchanged = self.refill(floor=1000)
        self.assertEqual((unchanged['state'], unchanged['remainingCredits']), ('unchanged', 1500))
        balance, stamp = self.wallet()
        self.assertEqual(balance, 1500)
        self.assertGreater(stamp, SEED_STAMP)

        self.sql(f"UPDATE credits_usage SET remaining_credits=1000 WHERE account_id='{self.owner}'")
        self.assertEqual(self.refill(floor=1000)['state'], 'unchanged')
        self.assertEqual(self.wallet()[0], 1000)

    def test_refill_blocked_by_an_open_top_up_keeps_the_top_up(self):
        # Deterministic lost-update reproduction: the top-up holds the row lock in
        # an open transaction, the refill blocks on it, and after commit the refill
        # must see 2300 (unchanged), not overwrite it with an absolute 1000.
        self.seed(300)
        holder = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55474', '-d', 'postgres',
                                   '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        holder.stdin.write('BEGIN;\n' + self.increment_statement(delta=2000) + '\n')
        holder.stdin.flush()
        self.wait_for("SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction'")

        refill = {}
        worker = threading.Thread(target=lambda: refill.update(self.refill(floor=1000)))
        worker.start()
        self.wait_for("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' "
                      "AND query ILIKE '%refill_credits_to_floor%'")
        self.assertEqual(self.wallet(), (300, SEED_STAMP))

        out, err = holder.communicate('COMMIT;\n', timeout=10)
        self.assertEqual(holder.returncode, 0, err)
        self.assertEqual(json.loads(out.strip().splitlines()[0]), {'remainingCredits': 2300})
        worker.join(timeout=10)
        self.assertEqual((refill['state'], refill['remainingCredits']), ('unchanged', 2300))
        balance, stamp = self.wallet()
        self.assertEqual(balance, 2300)
        self.assertGreater(stamp, SEED_STAMP)

    def wait_for(self, count_query, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.sql(count_query).stdout.strip() != '0':
                return
            time.sleep(0.05)
        self.fail(f'timed out waiting for: {count_query}')

    def test_refill_concurrent_with_charge_receipt_and_legacy_debit_keeps_every_debit(self):
        self.seed(1500)
        legacy = (f"SET ROLE service_role; SELECT deduct_credits_with_audit("
                  f"'{self.owner}',50::bigint,'legacy-{self.owner}','{{}}'::jsonb)")
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(self.sql, [self.charge_statement(), legacy, self.refill_statement(floor=1000)]))
        # An absolute refill write ordered last would have produced 1000 here.
        self.assertEqual(self.wallet()[0], 1350)
        self.assertEqual(json.loads(results[2].stdout)['state'], 'unchanged')
        self.assertEqual(json.loads(self.sql(self.charge_statement()).stdout)['state'], 'reused')
        self.assertEqual(self.sql(f"SELECT count(*) FROM usage_events WHERE account_id='{self.owner}'").stdout.strip(), '2')

    def test_invalid_inputs_raise_22023_and_change_nothing(self):
        self.seed(1000)
        cases = [self.refill_statement(floor=-1), self.refill_statement(floor=9007199254740992),
                 self.increment_statement(delta=0), self.increment_statement(delta=-5),
                 self.increment_statement(delta=9007199254740992),
                 "SET ROLE service_role; SELECT public.refill_credits_to_floor(NULL::uuid, 1000);",
                 "SET ROLE service_role; SELECT public.increment_credits_atomic(NULL::uuid, 100);"]
        for statement in cases:
            stderr = self.failing(statement)
            self.assertIn('22023', stderr)
            self.assertIn('Invalid credit', stderr)
        self.assertEqual(self.wallet(), (1000, SEED_STAMP))

    def test_missing_or_duplicate_wallets_are_rejected_without_change(self):
        for statement in [self.refill_statement(), self.increment_statement()]:
            self.assertIn('unavailable or ambiguous', self.failing(statement))
        self.seed(1000)
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits,\"timestamp\") "
                 f"VALUES ('{self.owner}',700,'{SEED_STAMP}')")
        for statement in [self.refill_statement(), self.increment_statement()]:
            self.assertIn('unavailable or ambiguous', self.failing(statement))
        self.assertEqual(self.sql(
            f"SELECT sum(remaining_credits), min(\"timestamp\"), max(\"timestamp\") FROM credits_usage "
            f"WHERE account_id='{self.owner}'").stdout.strip(), f'1700|{SEED_STAMP}|{SEED_STAMP}')

    def test_browser_roles_cannot_adjust(self):
        self.seed(1000)
        for role in ['anon', 'authenticated']:
            self.assertIn('permission denied', self.failing(self.refill_statement(role=role)))
            self.assertIn('permission denied', self.failing(self.increment_statement(role=role)))
        self.assertEqual(self.wallet(), (1000, SEED_STAMP))

    def test_rollback_leaves_balance_and_timestamp_unchanged(self):
        self.seed(300)
        self.sql('BEGIN;' + self.increment_statement(delta=2000) + self.refill_statement(floor=1000) + 'ROLLBACK;')
        self.assertEqual(self.wallet(), (300, SEED_STAMP))
        self.assertEqual(self.refill(floor=1000)['state'], 'raised')
