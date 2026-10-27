"""Offline transaction proposal: synthetic authority and observations, Unix socket only."""
import json
import os
import pathlib
import select
import subprocess
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

HERE = pathlib.Path(__file__).resolve().parent


def uid(n):
    return f'00000000-0000-0000-0000-{n:012d}'


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class ProofTransactions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='recoup-proof-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.cluster = pathlib.Path(cls.tmp.name) / 'pg'
        subprocess.run(['initdb', '-D', str(cls.cluster), '-A', 'trust'], check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-l', str(pathlib.Path(cls.tmp.name) / 'pg.log'),
                        '-o', f"-k {cls.tmp.name} -p 55479 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True)
        cls.addClassCleanup(cls.stop)
        cls.sql((HERE / 'fixture.sql').read_text())
        cls.sql((HERE / 'proposal.sql').read_text())
        cls.sql('CREATE ROLE proof_browser;')

    @classmethod
    def stop(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.cluster), '-m', 'immediate', '-w', 'stop'],
                       check=True, capture_output=True)

    @classmethod
    def args(cls):
        return ['psql', '-h', cls.tmp.name, '-p', '55479', '-d', 'postgres', '-XqAt', '-v', 'ON_ERROR_STOP=1']

    @classmethod
    def sql(cls, sql):
        result = subprocess.run(cls.args(), input=sql, text=True, capture_output=True, timeout=15)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.sql('TRUNCATE proof_parent_fixture.workspaces,proof_parent_fixture.authority CASCADE;')
        self.sql((HERE / 'fixture-authority.sql').read_text())
        for workspace, application, actor in [(1, 2, 3), (11, 12, 13)]:
            self.sql(f"""INSERT INTO proof_parent_fixture.workspaces VALUES ('{uid(workspace)}');
            INSERT INTO proof_parent_fixture.applications(workspace_id,id) VALUES ('{uid(workspace)}','{uid(application)}');
            INSERT INTO proof_parent_fixture.environments(workspace_id,application_id,environment)
            VALUES ('{uid(workspace)}','{uid(application)}','production'),('{uid(workspace)}','{uid(application)}','development');
            INSERT INTO proof_parent_fixture.origins(workspace_id,application_id,environment,origin,hostname)
            SELECT workspace_id,application_id,environment,'https://music.example','music.example' FROM proof_parent_fixture.environments
            WHERE workspace_id='{uid(workspace)}';
            INSERT INTO proof_parent_fixture.authority
            SELECT '{uid(actor)}',workspace_id,application_id,environment,ARRAY['issue','verify','revoke','read'],true
            FROM proof_parent_fixture.environments WHERE workspace_id='{uid(workspace)}';""")

    def statement(self, operation, key='key', revisions=(1, 1, 1), payload=None,
                  actor=3, workspace=1, application=2, environment='production', origin='https://music.example'):
        args = [uid(actor), uid(workspace), uid(application), environment, origin, operation, key]
        return ('SELECT application_proof_proposal.transact(' + ','.join(literal(x) for x in args)
                + ',' + ','.join(str(x) for x in revisions) + ',' + literal(json.dumps(payload or {})) + '::jsonb);')

    def call(self, *args, **kwargs):
        return json.loads(self.sql(self.statement(*args, **kwargs)))

    def issue(self, **kwargs):
        return self.call('issue', payload={'digest': 'a' * 64}, **kwargs)

    def observation(self, issued, **changes):
        observed = self.sql('SELECT clock_timestamp()')
        result = {'challenge_id': issued['challenge_id'], 'digest': 'a' * 64,
                  'query_name': '_recoup-app.music.example', 'queried_at': observed,
                  'resolver_policy': 'synthetic-v1'}
        result.update(changes)
        return result

    def test_default_authority_and_browser_denial(self):
        # Restore the actual default-deny adapter without loading a real management policy.
        source = (HERE / 'proposal.sql').read_text()
        self.sql(source[source.index('-- DEFAULT AUTHORITY'):source.index('-- TRANSACTION')])
        with self.assertRaisesRegex(AssertionError, 'management authority unavailable'):
            self.issue()
        with self.assertRaisesRegex(AssertionError, 'permission denied'):
            self.sql('SET ROLE proof_browser; ' + self.statement('issue', payload={'digest': 'a' * 64}))

    def test_exact_retry_and_receipt_read_never_activate(self):
        issued = self.issue()
        self.assertEqual(issued, self.issue())
        payload = self.observation(issued)
        receipt = self.call('verify', 'verify', (1, 1, 2), payload)
        self.assertEqual(receipt, self.call('verify', 'verify', (1, 1, 2), payload))
        self.assertEqual(receipt, self.call('read', payload={'receipt_id': receipt['receipt_id']}))
        self.assertFalse(receipt['access_activated'])
        self.assertFalse(receipt['bootstrap_enabled'])
        self.assertEqual(receipt['proof_revision'], 2)
        self.assertEqual(receipt['config_revision'], 1)
        self.assertEqual(receipt['cas_revision'], 3)
        with self.assertRaisesRegex(AssertionError, 'idempotency conflict'):
            self.call('verify', 'verify', (1, 1, 2), {**payload, 'digest': 'b' * 64})
        with self.assertRaisesRegex(AssertionError, 'challenge unavailable'):
            self.call('verify', 'again', (1, 2, 3), payload)

    def test_cross_binding_and_authority_failures(self):
        issued = self.issue()
        for override in [{'workspace': 11}, {'actor': 13}, {'environment': 'invalid'}, {'application': 12}]:
            with self.assertRaisesRegex(AssertionError, 'management authority unavailable'):
                self.issue(**override)
        for override in [dict(actor=13,workspace=11,application=12), dict(environment='development')]:
            with self.assertRaisesRegex(AssertionError, 'challenge unavailable'):
                self.call('verify', 'foreign', (1, 1, 1), self.observation(issued), **override)
        with self.assertRaisesRegex(AssertionError, 'resource unavailable'):
            self.issue(origin='https://other.example')
        self.sql('UPDATE proof_parent_fixture.authority SET enabled=false')
        with self.assertRaisesRegex(AssertionError, 'management authority unavailable'):
            self.issue()

    def test_digest_uniqueness_and_rotation(self):
        first = self.issue()
        with self.assertRaisesRegex(AssertionError, 'duplicate key'):
            self.issue(actor=13,workspace=11,application=12)
        rotated = self.call('issue','rotate',(1,1,2),{'digest':'b'*64})
        self.assertNotEqual(first['challenge_id'],rotated['challenge_id'])
        with self.assertRaisesRegex(AssertionError, 'challenge unavailable'):
            self.call('verify','old',(1,1,3),self.observation(first))
        self.assertEqual(self.sql("SELECT state FROM application_proof_proposal.challenges WHERE id="+literal(first['challenge_id'])), 'superseded')

    def test_expiry_freshness_and_wrong_observations(self):
        issued = self.issue()
        for changes in [{'digest':'b'*64},{'query_name':'_recoup-app.example'},
                        {'queried_at':'infinity'},{'queried_at':'2000-01-01'},
                        {'queried_at':'2099-01-01'},{'resolver_policy':'unknown'}, {'extra':True}]:
            with self.assertRaises(AssertionError):
                self.call('verify','bad',(1,1,2),self.observation(issued,**changes))
        self.sql("UPDATE application_proof_proposal.challenges SET issued_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour'")
        with self.assertRaisesRegex(AssertionError,'challenge expired'):
            self.call('verify','expired',(1,1,2),self.observation(issued))

    def test_rollback_unknown_outcome_and_history(self):
        # An explicit rollback leaves neither challenge nor retry result.
        self.sql('BEGIN;'+self.statement('issue',payload={'digest':'a'*64})+'ROLLBACK;')
        self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.challenges'),'0')
        # Discard the committed response to model a client that cannot tell whether commit succeeded.
        self.sql('BEGIN;'+self.statement('issue',payload={'digest':'a'*64})+'COMMIT;')
        issued = self.issue()
        self.assertEqual(issued,self.issue())
        payload = self.observation(issued)
        receipt = self.call('verify','verify',(1,1,2),payload)
        revoked = self.call('revoke','revoke',(1,2,3))
        self.assertFalse(revoked['access_activated'])
        self.assertEqual(receipt,self.call('verify','verify',(1,1,2),payload))
        self.assertEqual(receipt,self.call('read',payload={'receipt_id':receipt['receipt_id']}))
        with self.assertRaisesRegex(AssertionError,'revoked'):
            self.call('issue','new',(1,3,4),{'digest':'b'*64})
        with self.assertRaisesRegex(AssertionError,'immutable'):
            self.sql('UPDATE application_proof_proposal.receipts SET result=result')

    def test_invalid_input_and_isolation(self):
        for payload in [{'digest':None},{'digest':'not-a-digest'},{'digest':'a'*64,'caller_grant':True}]:
            with self.assertRaisesRegex(AssertionError,'invalid input'):
                self.call('issue',payload=payload)
        with self.assertRaisesRegex(AssertionError,'read committed required'):
            self.sql('BEGIN ISOLATION LEVEL REPEATABLE READ;'+self.statement('issue',payload={'digest':'a'*64}))
        self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.receipts'),'0')

    def test_stale_observation_and_transaction_rollback_after_verify(self):
        issued=self.issue()
        self.sql("UPDATE application_proof_proposal.challenges SET issued_at=clock_timestamp()-interval '2 minutes'")
        stale=self.sql("SELECT clock_timestamp()-interval '61 seconds'")
        with self.assertRaisesRegex(AssertionError,'observation rejected'):
            self.call('verify','stale',(1,1,2),self.observation(issued,queried_at=stale))
        payload=self.observation(issued)
        self.sql('BEGIN;'+self.statement('verify','verify',(1,1,2),payload)+'ROLLBACK;')
        self.assertEqual(self.sql('SELECT state FROM application_proof_proposal.challenges'),'pending')
        self.assertEqual(self.sql("SELECT cas_revision FROM proof_parent_fixture.origins WHERE environment='production' AND workspace_id="+literal(uid(1))),'2')
        self.assertEqual(self.call('verify','verify',(1,1,2),payload)['proof_revision'],2)

    def test_suspension_and_read_scope(self):
        issued=self.issue()
        for table in ['applications','environments']:
            self.sql('UPDATE proof_parent_fixture.'+table+' SET suspended=true')
            with self.assertRaisesRegex(AssertionError,'resource suspended'):
                self.call('verify','blocked',(1,1,2),self.observation(issued))
            self.sql('UPDATE proof_parent_fixture.'+table+' SET suspended=false')
        with self.assertRaisesRegex(AssertionError,'resource unavailable'):
            self.call('read',payload={'receipt_id':issued['receipt_id']},actor=13,workspace=11,application=12)
        self.sql("UPDATE proof_parent_fixture.authority SET operations=ARRAY['issue']")
        with self.assertRaisesRegex(AssertionError,'management authority unavailable'):
            self.call('read',payload={'receipt_id':issued['receipt_id']})

    def holder(self, sql):
        process = subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        process.stdin.write('BEGIN;'+sql+';\n\\echo HELD\n')
        process.stdin.flush()
        deadline=time.monotonic()+5
        buffered = ''
        while time.monotonic()<deadline:
            ready,_,_=select.select([process.stdout],[],[],0.1)
            if ready:
                buffered += os.read(process.stdout.fileno(), 65536).decode()
                if 'HELD' in buffered.splitlines():
                    return process
            if process.poll() is not None:
                raise AssertionError(process.stderr.read())
        process.kill()
        raise AssertionError('holder barrier timed out')

    def race(self, winning_sql, losing_sql, error):
        holder=self.holder(winning_sql)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(self.sql,losing_sql)
                self.wait_for_lock()
                holder.communicate('COMMIT;\n',timeout=5)
                self.assertEqual(holder.returncode,0)
                with self.assertRaisesRegex(AssertionError,error):
                    future.result(timeout=5)
        finally:
            if holder.poll() is None:
                holder.communicate('ROLLBACK;\n',timeout=5)

    def test_verify_loses_to_revoke_rotation_and_config_change(self):
        for kind in ['revoke','rotate','config']:
            self.setUp()
            issued=self.issue()
            verify=self.statement('verify','verify',(1,1,2),self.observation(issued))
            if kind=='config':
                winner="UPDATE proof_parent_fixture.origins SET config_revision=config_revision+1,cas_revision=cas_revision+1 WHERE environment='production'"
            elif kind=='rotate':
                winner=self.statement('issue','rotate',(1,1,2),{'digest':'b'*64})
            else:
                winner=self.statement('revoke','revoke',(1,1,2))
            self.race(winner,verify,'revision conflict')
            self.assertEqual(self.sql("SELECT count(*) FROM application_proof_proposal.receipts WHERE operation='verify'"),'0')

    def test_verify_wins_then_revoke_retries_on_new_revision(self):
        issued=self.issue()
        self.race(self.statement('verify','verify',(1,1,2),self.observation(issued)),
                  self.statement('revoke','revoke',(1,1,2)),'revision conflict')
        revoked=self.call('revoke','revoke',(1,2,3))
        self.assertTrue(revoked['revoked'])
        self.assertEqual(self.sql("SELECT count(*) FROM application_proof_proposal.receipts WHERE operation='verify'"),'1')

    def test_two_connections_exact_retry_returns_one_result(self):
        statement=self.statement('issue',payload={'digest':'a'*64})
        holder=self.holder(statement)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(self.sql,statement)
                self.wait_for_lock()
                holder.communicate('COMMIT;\n',timeout=5)
                retried=json.loads(future.result(timeout=5))
            self.assertEqual(retried,self.issue())
            self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.challenges'),'1')
            self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.receipts'),'1')
        finally:
            if holder.poll() is None:
                holder.communicate('ROLLBACK;\n',timeout=5)

    def wait_for_lock(self):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if int(self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%application_proof_proposal.transact%'")):
                return
            time.sleep(0.02)
        self.fail('second connection did not reach a real database lock')

    def test_expiry_is_checked_after_waiting_for_parent_lock(self):
        issued=self.issue()
        holder=self.holder("UPDATE proof_parent_fixture.origins SET cas_revision=cas_revision WHERE environment='production'; UPDATE application_proof_proposal.challenges SET expires_at=clock_timestamp()+interval '0.4 seconds'")
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(self.call,'verify','verify',(1,1,2),self.observation(issued))
                self.wait_for_lock()
                time.sleep(0.45)
                holder.communicate('COMMIT;\n',timeout=5)
                with self.assertRaisesRegex(AssertionError,'challenge expired'):
                    future.result(timeout=5)
        finally:
            if holder.poll() is None:
                holder.communicate('ROLLBACK;\n',timeout=5)

    def test_verify_loses_to_authority_revocation(self):
        issued=self.issue()
        self.race('UPDATE proof_parent_fixture.authority SET enabled=false',
                  self.statement('verify','verify',(1,1,2),self.observation(issued)),
                  'management authority unavailable')


if __name__=='__main__':
    unittest.main(verbosity=2)
