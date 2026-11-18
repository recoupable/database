"""Two real connections race protocol ownership; no mocked command or seeded job."""
import concurrent.futures
import json
import select
import subprocess
import time
import unittest
import uuid
from test_contract import FencedPacks


class CreationRace(FencedPacks):
    def prepare_sql(self, protocol, job, key, fingerprint=None):
        name = 'release_pack_command_v2' if protocol == 2 else 'release_pack_command'
        payload = json.dumps({'idempotency_key': key, 'fingerprint': fingerprint or 'a' * 64,
                              'brief': {}, 'deliverables': {}, 'status': 'ready_to_quote'})
        return f"SELECT {name}('{self.owner}',null,'prepare','{job}','{payload}'::jsonb);"

    def race(self, winner_protocol, loser_protocol):
        key = str(uuid.uuid4())
        winner_job, loser_job = str(uuid.uuid4()), str(uuid.uuid4())
        winner = subprocess.Popen(['psql', '-h', self.tmp.name, '-p', '55476', '-d', 'postgres',
                                   '-XAtq', '-v', 'ON_ERROR_STOP=1'], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            winner.stdin.write("BEGIN; SET LOCAL statement_timeout='10s'; SET ROLE service_role; " + self.prepare_sql(winner_protocol, winner_job, key) + '\n')
            winner.stdin.flush()
            self.assertTrue(select.select([winner.stdout], [], [], 10)[0], 'winner did not prepare')
            first = json.loads(winner.stdout.readline())
            self.assertEqual(first['job']['protocol'], winner_protocol)
            tag = 'pack_creation_' + uuid.uuid4().hex
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(self.sql, f"SET statement_timeout='10s'; SET application_name='{tag}'; SET ROLE service_role; " + self.prepare_sql(loser_protocol, loser_job, key), False)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    waiting = self.sql(f"SELECT wait_event_type||':'||wait_event FROM pg_stat_activity WHERE application_name='{tag}' AND wait_event_type='Lock'").stdout.strip()
                    if waiting:
                        break
                    self.assertFalse(pending.done(), 'contender escaped the uncommitted winner')
                    time.sleep(.01)
                else:
                    self.fail('contender did not reach an actual PostgreSQL lock')
                winner.stdin.write('COMMIT;\n')
                winner.stdin.flush()
                result = pending.result(timeout=10)
            print(json.dumps({'winner_protocol': winner_protocol, 'contender_protocol': loser_protocol,
                              'observed_wait': waiting, 'contender_exit': result.returncode,
                              'retained_protocol': self.sql(f"SELECT protocol FROM release_pack_jobs WHERE id='{winner_job}'").stdout.strip()}), flush=True)
            return first, result, waiting, key, loser_job
        finally:
            if winner.poll() is None:
                winner.communicate('ROLLBACK;\n\\q\n', timeout=10)
            else:
                winner.communicate(timeout=10)

    def test_legacy_winner_stays_legacy_and_protocol2_loser_refuses(self):
        first, result, waiting, key, _ = self.race(1, 2)
        self.assertNotEqual(result.returncode, 0, f'protocol2 adopted legacy after {waiting}: {result.stdout}')
        self.assertIn('Legacy Pack cannot be adopted', result.stderr)
        self.job = first['job']['id']
        self.assertEqual(self.command('read', legacy=True)['job']['protocol'], 1)
        before = self.snapshot()
        replay = self.sql('SET ROLE service_role; ' + self.prepare_sql(1, str(uuid.uuid4()), key))
        self.assertEqual(json.loads(replay.stdout)['job']['id'], self.job)
        self.assertEqual(before, self.snapshot())
        self.assertNotEqual(self.command('read', succeeds=False).returncode, 0)
        quote = {'id': str(uuid.uuid4()), 'revision': 1, 'credits': 100, 'maximum_usd': .01, 'expires_at': '2099-01-01T00:00:00Z'}
        quoted = self.command('estimate', {'quote': quote, 'assets': [{'kind': 'artwork', 'ordinal': 0, 'credits': 100, 'maximum_usd': .01}]}, legacy=True)
        self.assertEqual(quoted['job']['protocol'], 1)
        self.assertEqual(quoted['job']['status'], 'awaiting_approval')

    def test_protocol2_winner_rejects_legacy_and_keeps_owner_guard_and_replay(self):
        first, result, _, key, _ = self.race(2, 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Protocol 2 requires a fenced caller', result.stderr)
        self.job = first['job']['id']
        before = self.snapshot()
        replay = self.sql('SET ROLE service_role; ' + self.prepare_sql(2, str(uuid.uuid4()), key))
        self.assertEqual(json.loads(replay.stdout)['job']['id'], self.job)
        self.assertEqual(self.command('read')['job']['protocol'], 2)
        self.assertNotEqual(self.command('read', actor=str(uuid.uuid4()), succeeds=False).returncode, 0)
        self.assertNotEqual(self.sql('SET ROLE service_role; ' + self.prepare_sql(2, str(uuid.uuid4()), key, 'b' * 64), succeeds=False).returncode, 0)
        self.assertEqual(before, self.snapshot())

    def test_two_protocol2_creators_replay_one_owned_job(self):
        first, result, _, _, _ = self.race(2, 2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['job']['id'], first['job']['id'])
        self.assertEqual(self.sql(f"SELECT count(*) FROM release_pack_jobs WHERE owner_id='{self.owner}'").stdout.strip(), '1')


if __name__ == '__main__':
    suite = unittest.TestSuite(CreationRace(name) for name in CreationRace.__dict__ if name.startswith('test_'))
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
