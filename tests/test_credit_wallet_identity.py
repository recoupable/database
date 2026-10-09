"""Single wallet identity against disposable PostgreSQL; no hosted balances."""
import concurrent.futures
import json
import uuid
from credit_charge_fixture import CreditChargeFixture, ROOT

MIGRATION = ROOT / 'supabase/migrations/20261009010000_credit_wallet_account_unique.sql'


class CreditWalletIdentity(CreditChargeFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if MIGRATION.exists():
            cls.sql(MIGRATION.read_text())

    def setUp(self):
        self.owner = str(uuid.uuid4())

    def seed(self, balance=1000):
        return self.sql(
            f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',{balance})",
            succeeds=False)

    def test_concurrent_first_reads_create_exactly_one_wallet(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            attempts = list(pool.map(lambda _: self.seed(), range(12)))
        self.assertEqual(sum(r.returncode == 0 for r in attempts), 1)
        for failure in (r for r in attempts if r.returncode):
            self.assertIn('credits_usage_account_id_key', failure.stderr)
        self.assertEqual(self.sql(
            f"SELECT count(*),sum(remaining_credits) FROM credits_usage WHERE account_id='{self.owner}'"
        ).stdout.strip(), '1|1000')

    def test_duplicate_seed_does_not_replace_or_add_balance(self):
        self.assertEqual(self.seed(700).returncode, 0)
        self.assertNotEqual(self.seed(2000).returncode, 0)
        self.assertEqual(self.sql(
            f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'"
        ).stdout.strip(), '700')

    def test_reassigning_another_wallet_to_existing_owner_is_rejected(self):
        self.seed()
        other = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{other}',500)")
        result = self.sql(
            f"UPDATE credits_usage SET account_id='{self.owner}' WHERE account_id='{other}'", succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sql(
            f"SELECT remaining_credits FROM credits_usage WHERE account_id='{other}'"
        ).stdout.strip(), '500')

    def test_rolled_back_creation_does_not_claim_owner(self):
        self.sql(f"BEGIN; INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',300); ROLLBACK;")
        self.assertEqual(self.seed(700).returncode, 0)

    def test_legacy_debit_and_stable_receipt_still_share_one_wallet(self):
        self.seed()
        charge = (f"SET ROLE service_role; SELECT record_credit_charge_once('{self.owner}',"
                  "'work-1',100,'{}'::jsonb)")
        legacy = (f"SET ROLE service_role; SELECT deduct_credits_with_audit('{self.owner}',"
                  f"50::bigint,'legacy-{self.owner}','{{}}'::jsonb)")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(self.sql, [charge, legacy]))
        self.assertEqual(json.loads(self.sql(charge).stdout)['state'], 'reused')
        self.assertEqual(self.sql(
            f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'"
        ).stdout.strip(), '850')


class CreditWalletMigration(CreditChargeFixture):
    def test_existing_duplicates_stop_install_without_rewriting_rows(self):
        owner = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{owner}',700),('{owner}',300)")
        before = self.sql('SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM credits_usage c').stdout
        # Until the migration exists, this represents the unchanged legacy schema.
        migration = MIGRATION.read_text() if MIGRATION.exists() else 'SELECT 1;'
        result = self.sql(migration, succeeds=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('credits_usage_account_id_key', result.stderr)
        self.assertEqual(self.sql('SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM credits_usage c').stdout, before)
        self.assertEqual(self.sql("SELECT count(*) FROM pg_constraint WHERE conname='credits_usage_account_id_key'").stdout.strip(), '0')


class CreditWalletMigrationPreservation(CreditChargeFixture):
    def test_valid_existing_rows_and_nullable_owner_contract_are_preserved(self):
        owners = [str(uuid.uuid4()) for _ in range(3)]
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{owners[0]}',700),('{owners[1]}',-20),('{owners[2]}',0),(NULL,10),(NULL,20)")
        before = self.sql('SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM credits_usage c').stdout
        migration = MIGRATION.read_text() if MIGRATION.exists() else 'SELECT 1;'
        self.sql(migration)
        self.assertEqual(self.sql('SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM credits_usage c').stdout, before)
        self.assertEqual(self.sql("SELECT count(*) FROM pg_constraint WHERE conname='credits_usage_account_id_key' AND contype='u'").stdout.strip(), '1')
