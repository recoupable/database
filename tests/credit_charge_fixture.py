"""Disposable PostgreSQL fixture; never reads hosted credentials."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = '20261009000000_record_credit_charge_once.sql'


class CreditChargeFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-charge-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', f'{cls.tmp.name}/pg.log',
                        '-o', f"-k {cls.tmp.name} -p 55474 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql('''CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated;
          CREATE TABLE public.credits_usage(id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,account_id uuid,remaining_credits bigint);
          CREATE TABLE public.usage_events(id text PRIMARY KEY,account_id uuid NOT NULL,
            source text CHECK(source IN ('web','api')),agent_type text CHECK(agent_type IN ('main','subagent')),
            provider text,model_id text,input_tokens int,cached_input_tokens int,output_tokens int,
            tool_call_count int,credits_deducted bigint NOT NULL,created_at timestamptz DEFAULT now());
          ALTER TABLE public.credits_usage ENABLE ROW LEVEL SECURITY;
          ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;
          GRANT USAGE ON SCHEMA public TO service_role;
          GRANT SELECT,UPDATE ON public.credits_usage TO service_role;
          GRANT SELECT,INSERT ON public.usage_events TO service_role;''')
        cls.sql((ROOT / 'supabase/migrations/20260827050000_add_usage_events_resource_url.sql').read_text())
        migration = ROOT / 'supabase/migrations' / MIGRATION
        if migration.exists():
            cls.sql(migration.read_text())

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def sql(cls, statement, succeeds=True):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55474', '-d', 'postgres',
                                 '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                input=statement, text=True, capture_output=True)
        if succeeds and result.returncode:
            raise AssertionError(result.stderr)
        return result
