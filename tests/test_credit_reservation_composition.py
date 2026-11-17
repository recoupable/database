"""Released pack/refill/debit RPCs composed with shared reservations, on local PostgreSQL."""
import concurrent.futures
import json
import subprocess
import uuid
from credit_charge_fixture import CreditChargeFixture, ROOT


class CreditReservationComposition(CreditChargeFixture):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql('''CREATE TABLE public.accounts(id uuid PRIMARY KEY);
          CREATE TABLE public.account_organization_ids(account_id uuid, organization_id uuid);
          ALTER TABLE public.credits_usage ADD COLUMN timestamp timestamp DEFAULT now();''')
        # Replay the owning migrations in deployment order, not rewritten model functions.
        for name in ['20261010210500_credit_reservations.sql',
                     '20261020150000_release_pack_jobs.sql',
                     '20261117000000_compose_credit_reservations.sql']:
            cls.sql((ROOT / 'supabase/migrations' / name).read_text())

    def setUp(self):
        self.owner = str(uuid.uuid4())
        self.job = str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{self.owner}'); INSERT INTO credits_usage"
                 f"(account_id,remaining_credits) VALUES ('{self.owner}',1000)")

    def rpc(self, function, args, succeeds=True):
        result = self.sql(f'SET ROLE service_role; SELECT {function}({args});', succeeds=succeeds)
        return json.loads(result.stdout) if succeeds else result

    def reserve(self, amount=600, key='shared'):
        return self.rpc('reserve_credits_once', f"'{self.owner}','{key}',{amount}")

    def settle(self, amount=600, key='shared', event=None, succeeds=True):
        data = json.dumps(event or {}).replace("'", "''")
        return self.rpc('settle_credit_reservation',
                        f"'{self.owner}','{key}',{amount},'{data}'::jsonb", succeeds)

    def wallet(self):
        return int(self.sql(f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'").stdout)

    def holds(self):
        return int(self.sql(f"SELECT coalesce(sum(credits_held),0) FROM credit_reservations "
                            f"WHERE account_id='{self.owner}' AND state='held'").stdout)

    def events(self):
        return int(self.sql(f"SELECT count(*) FROM usage_events WHERE account_id='{self.owner}'").stdout)

    def command(self, action, data=None, succeeds=True):
        payload = json.dumps(data or {}).replace("'", "''")
        return self.rpc('release_pack_command',
                        f"'{self.owner}',null,'{action}','{self.job}','{payload}'::jsonb", succeeds)

    def quote_pack(self):
        assets = [{'kind': 'artwork', 'ordinal': 0, 'credits': 100, 'maximum_usd': 0.01}]
        self.command('prepare', {'idempotency_key': self.job, 'fingerprint': 'a'*64,
                                'brief': {}, 'deliverables': {}, 'status': 'ready_to_quote', 'assets': assets})
        quote = {'id': str(uuid.uuid4()), 'revision': 1, 'credits': 100,
                 'maximum_usd': 0.01, 'expires_at': '2099-01-01T00:00:00Z'}
        self.command('estimate', {'quote': quote, 'assets': assets})
        return {'quote_id': quote['id'], 'expected_revision': 1, 'approved_max_usd': 0.01}

    def debit_sql(self, amount):
        return (f"SET ROLE service_role; SELECT deduct_credits_with_audit('{self.owner}',"
                f"{amount}::bigint,'legacy-{uuid.uuid4()}','{{}}'::jsonb);")

    def test_pack_hold_and_shared_hold_protect_the_same_wallet_without_double_counting(self):
        self.command('approve', self.quote_pack())
        self.assertEqual(self.reserve()['spendableCredits'], 300)
        denied = self.sql(self.debit_sql(301), succeeds=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertEqual((self.wallet(), self.holds(), self.events()), (900, 600, 0))
        self.sql(self.debit_sql(300))
        self.command('settle', {'error': 'cancelled before provider dispatch'})
        self.assertEqual(self.wallet(), 700)
        self.settle()
        self.assertEqual((self.wallet(), self.holds(), self.events()), (100, 0, 2))

    def test_pack_approval_cannot_consume_a_preexisting_shared_reservation(self):
        approval = self.quote_pack()
        self.reserve(960)
        denied = self.command('approve', approval, succeeds=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertEqual(self.command('read')['job']['status'], 'awaiting_approval')
        self.assertEqual((self.wallet(), self.holds()), (1000, 960))

    def test_atomic_adjustment_and_stable_charge_also_cannot_consume_held_funds(self):
        self.reserve(960)
        for function, args in [
            ('adjust_credit_balance_atomic', f"'{self.owner}',-41"),
            ('record_credit_charge_once', f"'{self.owner}','other',41,'{{}}'::jsonb"),
        ]:
            self.assertNotEqual(self.rpc(function, args, False).returncode, 0)
        self.assertEqual((self.wallet(), self.holds(), self.events()), (1000, 960, 0))

    def test_settlement_excludes_its_own_hold_but_preserves_other_holds(self):
        self.reserve(200)
        self.reserve(800, 'other')
        self.assertEqual(self.settle(150)['creditsReleased'], 50)
        self.assertEqual((self.wallet(), self.holds()), (850, 800))
        self.settle(800, 'other')
        self.assertEqual((self.wallet(), self.holds(), self.events()), (50, 0, 2))

    def test_lost_settlement_acknowledgement_reuses_one_charge_and_conflict_rolls_back(self):
        self.reserve()
        first = self.settle(120)  # Committed response is deliberately not used to retry a provider.
        replay = self.settle(120)
        self.assertEqual(replay['state'], 'reused')
        self.assertEqual(replay['eventId'], first['eventId'])
        self.assertNotEqual(self.settle(121, succeeds=False).returncode, 0)
        self.assertEqual((self.wallet(), self.holds(), self.events()), (880, 0, 1))

    def test_rejected_charge_restores_open_hold_and_no_event(self):
        self.reserve()
        self.assertNotEqual(self.settle(120, event={'unexpected': True}, succeeds=False).returncode, 0)
        self.assertEqual((self.wallet(), self.holds(), self.events()), (1000, 600, 0))
        self.assertEqual(self.reserve()['status'], 'held')

    def test_actual_refill_counts_pack_hold_once_and_does_not_release_shared_hold(self):
        self.sql(f"UPDATE credits_usage SET remaining_credits=150 WHERE account_id='{self.owner}'")
        self.command('approve', self.quote_pack())
        self.reserve(40)
        stamp = self.sql(f"SELECT timestamp::text FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip()
        receipt = self.rpc('refill_credits_to_floor', f"'{self.owner}',200,'{stamp}'::timestamp")
        self.assertEqual(receipt['remainingCredits'], 100)
        self.assertEqual(self.holds(), 40)
        self.settle(30)
        stale = self.rpc('refill_credits_to_floor', f"'{self.owner}',200,'{stamp}'::timestamp")
        self.assertEqual(stale['state'], 'superseded')
        self.command('settle', {'error': 'cancelled'})
        self.assertEqual((self.wallet(), self.holds()), (170, 0))

    def test_actual_topup_and_settlement_concurrently_both_survive(self):
        self.reserve()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(self.rpc, 'increment_credits_atomic', f"'{self.owner}',500")
            b = pool.submit(self.settle, 120)
            a.result(); b.result()
        self.assertEqual((self.wallet(), self.holds(), self.events()), (1380, 0, 1))

    def test_concurrent_legacy_debit_and_reservation_cannot_both_oversubscribe(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(self.reserve, 960)
            b = pool.submit(self.sql, self.debit_sql(50), False)
            reservation, debit = a.result(), b.result()
        if reservation['state'] == 'held':
            self.assertNotEqual(debit.returncode, 0)
            self.assertEqual((self.wallet(), self.holds(), self.events()), (1000, 960, 0))
        else:
            self.assertEqual(reservation['state'], 'insufficient')
            self.assertEqual(debit.returncode, 0)
            self.assertEqual((self.wallet(), self.holds(), self.events()), (950, 0, 1))

    def test_existing_no_hold_legacy_debit_behavior_is_unchanged(self):
        self.sql(self.debit_sql(1001))
        self.assertEqual((self.wallet(), self.events()), (-1, 1))

    def test_outstanding_hold_blocks_null_balance_owner_change_and_wallet_deletion(self):
        self.reserve()
        for statement in [
            f"UPDATE credits_usage SET remaining_credits=NULL WHERE account_id='{self.owner}'",
            f"UPDATE credits_usage SET account_id='{uuid.uuid4()}' WHERE account_id='{self.owner}'",
            f"DELETE FROM credits_usage WHERE account_id='{self.owner}'",
        ]:
            self.assertNotEqual(self.sql(statement, succeeds=False).returncode, 0)
        self.assertEqual((self.wallet(), self.holds()), (1000, 600))

    def test_release_keeps_balance_and_makes_capacity_available_to_legacy_debit(self):
        self.reserve()
        self.rpc('release_credit_reservation', f"'{self.owner}','shared'")
        self.sql(self.debit_sql(1000))
        self.assertEqual((self.wallet(), self.holds(), self.events()), (0, 0, 1))

    def test_old_repeatable_read_snapshot_cannot_miss_a_new_reservation(self):
        client = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55474', '-d', 'postgres',
                                   '-XAtq', '-v', 'ON_ERROR_STOP=1'], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: client.poll() is None and client.kill())
        client.stdin.write(f"BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT remaining_credits "
                           f"FROM credits_usage WHERE account_id='{self.owner}';\n")
        client.stdin.flush()
        self.assertEqual(client.stdout.readline().strip(), '1000')
        self.reserve(960)
        _, stderr = client.communicate(self.debit_sql(50) + ' COMMIT;', timeout=10)
        self.assertNotEqual(client.returncode, 0)
        self.assertIn('could not serialize access', stderr)
        self.assertEqual((self.wallet(), self.holds(), self.events()), (1000, 960, 0))

    def test_guard_sees_holds_hidden_from_a_wallet_writer(self):
        role = 'wallet_' + uuid.uuid4().hex
        self.sql(f"CREATE ROLE {role}; GRANT USAGE ON SCHEMA public TO {role}; "
                 f"GRANT SELECT, UPDATE, DELETE ON credits_usage TO {role}; "
                 f"CREATE POLICY {role}_policy ON credits_usage TO {role} USING (true) WITH CHECK (true);")
        self.reserve(960)
        self.assertNotEqual(self.sql(f'SET ROLE {role}; SELECT * FROM credit_reservations', False).returncode, 0)
        # Unrelated metadata updates are not a financial operation.
        self.sql(f"SET ROLE {role}; UPDATE credits_usage SET timestamp=now() WHERE account_id='{self.owner}'")
        denied = self.sql(f"SET ROLE {role}; UPDATE credits_usage SET remaining_credits=950 "
                          f"WHERE account_id='{self.owner}'", False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn('Outstanding credit reservations', denied.stderr)
        self.assertNotEqual(self.sql(f'SET ROLE {role}; SELECT protect_credit_reservations()', False).returncode, 0)
        self.assertEqual((self.wallet(), self.holds()), (1000, 960))

    def test_concurrent_pack_approval_and_shared_reservation_cannot_both_oversubscribe(self):
        approval = self.quote_pack()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(self.reserve, 960)
            b = pool.submit(self.command, 'approve', approval, False)
            reservation, pack = a.result(), b.result()
        if reservation['state'] == 'held':
            self.assertNotEqual(pack.returncode, 0)
            self.assertEqual((self.wallet(), self.holds()), (1000, 960))
        else:
            self.assertEqual(pack.returncode, 0)
            self.assertEqual((self.wallet(), self.holds()), (900, 0))

    def test_failed_usage_insert_restores_hold_and_wallet(self):
        name = 'fail_usage_' + uuid.uuid4().hex
        self.sql(f"""CREATE FUNCTION {name}() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN IF NEW.provider='fixture_failure' THEN RAISE EXCEPTION 'fixture insert failure';
          END IF; RETURN NEW; END $$;
          CREATE TRIGGER {name} BEFORE INSERT ON usage_events FOR EACH ROW EXECUTE FUNCTION {name}();""")
        self.reserve()
        rejected = self.settle(120, event={'provider': 'fixture_failure'}, succeeds=False)
        self.assertIn('fixture insert failure', rejected.stderr)
        self.assertEqual((self.wallet(), self.holds(), self.events()), (1000, 600, 0))
        self.assertEqual(self.reserve()['status'], 'held')

    def test_another_owners_holds_do_not_limit_this_wallet(self):
        other = str(uuid.uuid4())
        self.sql(f"INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{other}',1000)")
        self.rpc('reserve_credits_once', f"'{other}','other',1000")
        self.sql(self.debit_sql(1000))
        self.assertEqual((self.wallet(), self.holds()), (0, 0))
