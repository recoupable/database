"""Credit reservations (holds) on the existing wallet, against real local transactions."""
import concurrent.futures
import json
import uuid
from credit_charge_fixture import CreditChargeFixture, ROOT

MIGRATION = ROOT / 'supabase/migrations/20261010210500_credit_reservations.sql'


class CreditReservations(CreditChargeFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # Required, never skipped: without the migration the suite must fail.
        cls.sql(MIGRATION.read_text())

    def setUp(self):
        self.owner = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',1000)")

    @staticmethod
    def quote(value):
        return value.replace("'", "''")

    def reserve_statement(self, key='work-1', credits=300, owner=None, role='service_role'):
        return (f"SET ROLE {role}; SELECT public.reserve_credits_once("
                f"'{owner or self.owner}', '{self.quote(key)}', {credits});")

    def settle_statement(self, key='work-1', credits=120, event=None, owner=None):
        payload = self.quote(json.dumps(event or {}))
        return (f"SET ROLE service_role; SELECT public.settle_credit_reservation("
                f"'{owner or self.owner}', '{self.quote(key)}', {credits}, '{payload}'::jsonb);")

    def release_statement(self, key='work-1', owner=None):
        return (f"SET ROLE service_role; SELECT public.release_credit_reservation("
                f"'{owner or self.owner}', '{self.quote(key)}');")

    def run_json(self, statement):
        return json.loads(self.sql(statement).stdout)

    def reserve(self, **kwargs):
        return self.run_json(self.reserve_statement(**kwargs))

    def settle(self, **kwargs):
        return self.run_json(self.settle_statement(**kwargs))

    def release(self, **kwargs):
        return self.run_json(self.release_statement(**kwargs))

    def failing(self, statement):
        result = self.sql(statement, succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        return result.stderr

    def balance(self, owner=None):
        return int(self.sql(f"SELECT remaining_credits FROM credits_usage "
                            f"WHERE account_id='{owner or self.owner}'").stdout)

    def holds(self, state='held'):
        return int(self.sql(f"SELECT coalesce(sum(credits_held),0) FROM credit_reservations "
                            f"WHERE account_id='{self.owner}' AND state='{state}'").stdout)

    def usage_events(self):
        return int(self.sql(f"SELECT count(*) FROM usage_events WHERE account_id='{self.owner}'").stdout)

    def test_hold_reduces_spendable_without_debit_or_usage_event(self):
        receipt = self.reserve()
        self.assertEqual(receipt['state'], 'held')
        self.assertRegex(receipt['reservationId'], r'^hold-v1-[a-f0-9]{64}$')
        self.assertEqual(receipt['creditsHeld'], 300)
        self.assertEqual(receipt['spendableCredits'], 700)
        # A hold is not a temporary debit: refill/auto-top-up never see it as consumption.
        self.assertEqual(self.balance(), 1000)
        self.assertEqual(self.usage_events(), 0)
        denied = self.reserve(key='work-2', credits=701)
        self.assertEqual(denied, {'state': 'insufficient', 'creditsRequested': 701, 'spendableCredits': 700})
        self.assertEqual(self.holds(), 300)

    def test_concurrent_reservations_never_exceed_the_balance(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            receipts = list(pool.map(lambda i: self.reserve(key=f'work-{i}', credits=100), range(12)))
        self.assertEqual(sum(r['state'] == 'held' for r in receipts), 10)
        self.assertEqual(sum(r['state'] == 'insufficient' for r in receipts), 2)
        self.assertEqual(self.holds(), 1000)
        self.assertEqual(self.balance(), 1000)

    def test_concurrent_duplicate_reservation_holds_once(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            receipts = list(pool.map(lambda _: self.reserve(), range(12)))
        self.assertEqual(sum(r['state'] == 'held' for r in receipts), 1)
        self.assertEqual(sum(r['state'] == 'reused' for r in receipts), 11)
        self.assertEqual(len({r['reservationId'] for r in receipts}), 1)
        self.assertEqual(self.holds(), 300)

    def test_replayed_reservation_reports_current_status_and_changed_amount_conflicts(self):
        first = self.reserve()
        self.assertEqual(self.reserve(), {'state': 'reused', 'reservationId': first['reservationId'],
                                          'status': 'held', 'creditsHeld': 300})
        self.assertIn('Credit reservation identity conflict', self.failing(self.reserve_statement(credits=301)))
        self.release()
        # A replay after release never re-holds capacity for the same work.
        self.assertEqual(self.reserve()['status'], 'released')
        self.assertEqual(self.holds(), 0)

    def test_settlement_charges_actual_credits_and_releases_the_remainder(self):
        held = self.reserve()
        receipt = self.settle(event={'model_id': 'fixture', 'output_tokens': 12})
        self.assertEqual(receipt['state'], 'settled')
        self.assertEqual(receipt['reservationId'], held['reservationId'])
        self.assertRegex(receipt['eventId'], r'^charge-v1-[a-f0-9]{64}$')
        self.assertEqual((receipt['creditsHeld'], receipt['creditsCharged'], receipt['creditsReleased']),
                         (300, 120, 180))
        self.assertEqual(self.balance(), 880)
        self.assertEqual(self.holds(), 0)
        self.assertEqual(self.holds('settled'), 300)
        row = self.sql(f"SELECT credits_deducted, model_id, output_tokens FROM usage_events "
                       f"WHERE id='{receipt['eventId']}'").stdout.strip()
        self.assertEqual(row, '120|fixture|12')
        self.assertEqual(self.reserve(key='work-2', credits=880)['state'], 'held')

    def test_settlement_shares_the_charge_receipt_identity(self):
        self.reserve()
        settled = self.settle()
        direct = self.run_json(f"SET ROLE service_role; SELECT public.record_credit_charge_once("
                               f"'{self.owner}', 'work-1', 120, '{{}}'::jsonb);")
        self.assertEqual(direct['state'], 'reused')
        self.assertEqual(direct['eventId'], settled['eventId'])
        self.assertEqual(self.balance(), 880)

    def test_lost_and_concurrent_settlement_acknowledgements_charge_once(self):
        self.reserve()
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            receipts = list(pool.map(lambda _: self.settle(), range(12)))
        self.assertEqual(sum(r['state'] == 'settled' for r in receipts), 1)
        self.assertEqual(sum(r['state'] == 'reused' for r in receipts), 11)
        self.assertEqual(len({r['eventId'] for r in receipts}), 1)
        self.assertEqual(self.settle()['state'], 'reused')
        self.assertEqual(self.balance(), 880)
        self.assertEqual(self.usage_events(), 1)

    def test_changed_settlement_conflicts_and_keeps_the_first_charge(self):
        self.reserve()
        self.settle()
        for args in [{'credits': 121}, {'event': {'provider': 'different'}}]:
            self.assertIn('Credit charge identity conflict', self.failing(self.settle_statement(**args)))
        self.assertEqual(self.balance(), 880)

    def test_settlement_above_the_reservation_is_rejected_and_the_hold_remains(self):
        self.reserve()
        self.assertIn('Credit settlement exceeds reservation', self.failing(self.settle_statement(credits=301)))
        self.assertEqual(self.balance(), 1000)
        self.assertEqual(self.holds(), 300)
        self.assertEqual(self.usage_events(), 0)

    def test_release_returns_capacity_without_charge_and_closes_the_reservation(self):
        self.reserve()
        receipt = self.release()
        self.assertEqual((receipt['state'], receipt['creditsHeld'], receipt['creditsReleased']),
                         ('released', 300, 300))
        self.assertEqual(self.release()['state'], 'reused')
        self.assertEqual((self.balance(), self.holds(), self.usage_events()), (1000, 0, 0))
        self.assertIn('Credit reservation was released', self.failing(self.settle_statement()))
        self.reserve(key='work-2')
        self.settle(key='work-2')
        self.assertIn('Credit reservation was settled', self.failing(self.release_statement(key='work-2')))
        self.assertEqual(self.balance(), 880)

    def test_settle_or_release_without_a_reservation_never_charges(self):
        self.assertIn('Credit reservation not found', self.failing(self.settle_statement()))
        self.assertIn('Credit reservation not found', self.failing(self.release_statement()))
        self.assertEqual((self.balance(), self.usage_events()), (1000, 0))

    def test_holds_are_isolated_per_billing_owner(self):
        other = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{other}',100)")
        mine = self.reserve(credits=1000)
        # Same operation key, different billing owner: a separate hold and identity.
        foreign = self.reserve(owner=other, credits=100)
        self.assertEqual((mine['state'], foreign['state']), ('held', 'held'))
        self.assertNotEqual(foreign['reservationId'], mine['reservationId'])
        self.assertEqual(self.reserve(owner=other, key='work-2', credits=1)['state'], 'insufficient')
        self.assertIn('Credit reservation not found', self.failing(self.release_statement(owner=other, key='absent')))

    def test_top_up_and_settlement_concurrently_both_survive(self):
        self.reserve()
        top_up = (f"SET ROLE service_role; UPDATE credits_usage SET remaining_credits = remaining_credits + 500 "
                  f"WHERE account_id='{self.owner}'")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(self.sql, [top_up, self.settle_statement()]))
        self.assertEqual(self.balance(), 1380)

    def test_refill_with_an_outstanding_hold_keeps_the_hold(self):
        self.sql(f"UPDATE credits_usage SET remaining_credits = 200 WHERE account_id='{self.owner}'")
        self.reserve(credits=150)
        self.sql(f"UPDATE credits_usage SET remaining_credits = GREATEST(remaining_credits, 1000) "
                 f"WHERE account_id='{self.owner}'")
        self.assertEqual(self.holds(), 150)
        self.assertEqual(self.reserve(key='work-2', credits=851)['spendableCredits'], 850)

    def test_legacy_debit_concurrent_with_reservation_is_kept_but_ignores_holds(self):
        legacy = (f"SET ROLE service_role; SELECT deduct_credits_with_audit("
                  f"'{self.owner}',50::bigint,'legacy-{self.owner}','{{}}'::jsonb)")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.sql, [legacy, self.reserve_statement(credits=960)]))
        self.assertEqual(self.balance(), 950)
        state = json.loads(results[1].stdout)['state']
        self.assertIn(state, {'held', 'insufficient'})
        # Known limitation: legacy debit callers do not consult holds, so a debit that
        # commits after the hold can leave spendable credit below zero until settlement.
        self.assertEqual(self.holds(), 960 if state == 'held' else 0)

    def test_invalid_inputs_and_missing_or_duplicate_wallets_never_write(self):
        statements = [self.reserve_statement(credits=0), self.reserve_statement(credits=-1),
                      self.reserve_statement(key=' '), self.reserve_statement(key='k' * 201),
                      self.reserve_statement(credits=9007199254740992),
                      self.reserve_statement(owner=str(uuid.uuid4()))]
        for statement in statements:
            self.failing(statement)
        self.reserve()
        for statement in [self.settle_statement(credits=0), self.settle_statement(event={'extra': True}),
                          self.settle_statement(event={'input_tokens': -1}), self.release_statement(key='')]:
            self.failing(statement)
        self.assertEqual((self.balance(), self.holds(), self.usage_events()), (1000, 300, 0))
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',700)")
        for statement in [self.reserve_statement(key='work-2'), self.settle_statement(), self.release_statement()]:
            self.assertIn('Credit wallet is unavailable or ambiguous', self.failing(statement))
        self.assertEqual(self.holds(), 300)

    def test_browser_roles_are_denied_and_holds_cannot_be_deleted(self):
        self.reserve()
        for role in ['anon', 'authenticated']:
            for statement in [self.reserve_statement(key='browser'), self.settle_statement(),
                              self.release_statement(), 'SELECT * FROM credit_reservations;']:
                result = self.sql(statement.replace('service_role', role) if 'SET ROLE' in statement
                                  else f'SET ROLE {role}; {statement}', succeeds=False)
                self.assertIn('permission denied', result.stderr)
        self.assertEqual((self.balance(), self.holds()), (1000, 300))
        for statement in ['DELETE FROM credit_reservations;', 'TRUNCATE credit_reservations;']:
            self.assertIn('permission denied', self.failing(f'SET ROLE service_role; {statement}'))
        self.assertEqual(self.holds(), 300)

    def test_transaction_rollback_leaves_no_hold_or_charge(self):
        self.sql('BEGIN;' + self.reserve_statement() + 'ROLLBACK;')
        self.assertEqual(self.holds(), 0)
        self.reserve()
        self.sql('BEGIN;' + self.settle_statement() + 'ROLLBACK;')
        self.assertEqual((self.balance(), self.holds(), self.usage_events()), (1000, 300, 0))
