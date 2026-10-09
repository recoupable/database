"""RPC-only source/retry concurrency scenarios on disposable PostgreSQL."""
from concurrent.futures import ThreadPoolExecutor
import time
import original_registration_fixture as fixture

class OriginalSourceRaces(fixture.OriginalFixture):
    def test_concurrent_retries_return_one_receipt(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            receipts = list(pool.map(lambda _: self.register(), range(6)))
        self.assertTrue(all(r == receipts[0] for r in receipts))
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_original_registrations WHERE owner_id='{self.owner}'").stdout.strip(), '1')

    def test_simultaneous_changed_type_neutral_retry_has_one_receipt(self):
        neutral=self.path.replace('.csv','.original')
        def call(kind):
            try:
                return self.register(path=neutral,media_type=kind,digest=('a' if kind=='text/csv' else 'b')*64)
            except AssertionError as error:
                return str(error)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(call,['text/csv','application/pdf']))
        self.assertEqual(sum(isinstance(r,dict) for r in results),1)
        self.assertTrue(any(isinstance(r,str) and 'Original retry conflict' in r for r in results))
        self.assertEqual(self.sql(f"SELECT count(*) FROM context_original_registrations WHERE owner_id='{self.owner}'").stdout.strip(),'1')

    def test_cross_owner_source_creation_race_returns_controlled_denial(self):
        self.sql("CREATE FUNCTION delay_original_source() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.2); RETURN NEW; END $$; CREATE TRIGGER delay_original_source BEFORE INSERT ON context_sources FOR EACH ROW EXECUTE FUNCTION delay_original_source();")
        try:
            def call(foreign):
                try:
                    return self.register(actor=self.other if foreign else self.actor,
                        owner=self.other if foreign else self.owner,
                        path=self.path.replace(self.owner,self.other) if foreign else self.path)
                except AssertionError as error:
                    return str(error)
            with ThreadPoolExecutor(max_workers=2) as pool:
                results=list(pool.map(call,[False,True]))
            self.assertEqual(sum(isinstance(r,dict) for r in results),1)
            errors=[r for r in results if isinstance(r,str)]
            self.assertEqual(len(errors),1)
            self.assertIn('Original unavailable',errors[0])
            self.assertNotIn('duplicate key',errors[0])
        finally:
            self.sql("DROP TRIGGER delay_original_source ON context_sources; DROP FUNCTION delay_original_source();")

    def test_contended_source_lock_returns_without_waiting(self):
        def hold():
            self.sql(f"SET application_name='original-lock-fixture'; BEGIN; SELECT pg_advisory_xact_lock(hashtextextended('context-original-source:{self.source}',0)); SELECT pg_sleep(1); ROLLBACK;")
        with ThreadPoolExecutor(max_workers=1) as pool:
            held=pool.submit(hold)
            for _ in range(50):
                if self.sql("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='original-lock-fixture' AND wait_event='PgSleep')").stdout.strip()=='t': break
                time.sleep(0.01)
            else: self.fail('Fixture did not acquire source lock')
            with self.assertRaisesRegex(AssertionError,'Original unavailable'):
                self.register()
            held.result()
