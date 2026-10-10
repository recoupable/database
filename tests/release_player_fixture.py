"""Disposable PostgreSQL fixture; never reads hosted credentials."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATION = '20261010060000_release_players.sql'


class ReleasePlayerFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-player-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', f'{cls.tmp.name}/pg.log',
                        '-o', f"-k {cls.tmp.name} -p 55479 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql("CREATE ROLE service_role BYPASSRLS; CREATE ROLE anon; CREATE ROLE authenticated; CREATE TABLE public.accounts(id uuid PRIMARY KEY);")
        for name in [MIGRATION, '20261010060001_release_player_reports.sql', '20261010060002_player_duration_budget.sql']:
            migration = ROOT / 'supabase/migrations' / name
            cls.sql(migration.read_text())

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def sql(cls, statement, succeeds=True):
        result = subprocess.run(['psql', '-h', cls.tmp.name, '-p', '55479', '-d', 'postgres',
                                 '-XAtq', '-v', 'ON_ERROR_STOP=1'],
                                input=statement, text=True, capture_output=True)
        if succeeds and result.returncode:
            raise AssertionError(result.stderr)
        return result
