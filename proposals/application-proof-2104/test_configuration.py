"""Existing-origin writer against the existing proof fixture; no runtime adapter."""
import copy
import json
import pathlib
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
import test_transactions as proof

HERE = pathlib.Path(__file__).resolve().parent
ORIGIN = 'https://music.example'
SECOND = 'https://other.example'
OPERATION = 'replace_existing_origin_return_urls'
uid, literal = proof.uid, proof.literal


class Configuration(unittest.TestCase):
    # Reuse only the established disposable harness/helpers, not inherited test cases.
    args = classmethod(proof.ProofTransactions.args.__func__)
    sql = classmethod(proof.ProofTransactions.sql.__func__)
    stop = classmethod(proof.ProofTransactions.stop.__func__)
    statement = proof.ProofTransactions.statement
    call = proof.ProofTransactions.call
    issue = proof.ProofTransactions.issue
    observation = proof.ProofTransactions.observation
    holder = proof.ProofTransactions.holder
    race = proof.ProofTransactions.race

    @classmethod
    def setUpClass(cls):
        proof.ProofTransactions.setUpClass.__func__(cls)
        cls.sql((HERE / 'configuration-fixture.sql').read_text())
        cls.sql((HERE / 'configuration.sql').read_text())

    def setUp(self):
        self.sql('ALTER TABLE proof_parent_fixture.origins DROP CONSTRAINT IF EXISTS fixture_fail_second;')
        proof.ProofTransactions.setUp(self)
        self.sql("UPDATE proof_parent_fixture.authority SET operations=array_append(operations,"+literal(OPERATION)+")")
        self.sql("UPDATE proof_parent_fixture.origins SET return_urls=ARRAY[origin||'/done']")
        self.sql(f"""INSERT INTO proof_parent_fixture.origins(workspace_id,application_id,environment,origin,hostname,return_urls)
          VALUES('{uid(1)}','{uid(2)}','production','{SECOND}','other.example',ARRAY['{SECOND}/done']);""")

    def snapshot(self):
        return json.loads(self.sql(f"SELECT application_proof_proposal.configuration_snapshot('{uid(1)}','{uid(2)}','production')"))

    def plan(self, snapshot=None, urls=None):
        snapshot = snapshot or self.snapshot()
        urls = urls or {ORIGIN: [ORIGIN+'/new']}
        changes = []
        for row in snapshot['origins']:
            if row['origin'] not in urls:
                continue
            expected = {k: row[k] for k in ('config_revision','proof_revision','cas_revision')}
            next_values = {**expected, 'config_revision':expected['config_revision']+1,
                           'cas_revision':expected['cas_revision']+1}
            changes.append({'origin':row['origin'],'expected':expected,'next':next_values,
                            'return_urls':urls[row['origin']]})
        return snapshot,changes

    def config_statement(self, snapshot=None, changes=None, key='config', actor=3, workspace=1, application=2, environment='production'):
        if snapshot is None:
            snapshot,changes=self.plan()
        return ("SELECT application_proof_proposal.configure_return_urls("+
                ','.join(literal(x) for x in [uid(actor),uid(workspace),uid(application),environment,key])+
                ','+literal(json.dumps(snapshot))+'::jsonb,'+literal(json.dumps(changes))+'::jsonb);')

    def configure(self, *args, **kwargs):
        return json.loads(self.sql(self.config_statement(*args, **kwargs)))

    def wait_for_lock(self):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if int(self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%application_proof_proposal.%'")):
                return
            time.sleep(0.02)
        self.fail('second connection did not reach an actual database lock')

    def test_default_denial_before_writes_and_browser_access(self):
        sql=(HERE/'proposal.sql').read_text()
        self.sql(sql[sql.index('-- DEFAULT AUTHORITY'):sql.index('-- TRANSACTION')])
        with self.assertRaisesRegex(AssertionError,'management authority unavailable'):
            self.configure()
        self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.configuration_receipts'),'0')
        with self.assertRaisesRegex(AssertionError,'permission denied'):
            self.sql('SET ROLE proof_browser;'+self.config_statement())

    def test_shape_projection_empty_origin_and_proof_history(self):
        issued=self.issue()
        verified=self.call('verify','verify',(1,1,2),self.observation(issued))
        issued2=self.call('issue','renew',(1,2,3),{'digest':'b'*64})
        before,changes=self.plan(urls={ORIGIN:[],SECOND:[SECOND+'/new']})
        receipt=self.configure(before,changes)
        self.assertEqual(receipt['before'],before)
        self.assertEqual(receipt['changes'],changes)
        self.assertFalse(receipt['bootstrap_enabled'])
        self.assertFalse(receipt['access_activated'])
        self.assertEqual(receipt['after']['return_urls'],[SECOND+'/new'])
        self.assertEqual(receipt['after']['origins'][0],{'origin':ORIGIN,'config_revision':2,'proof_revision':2,'cas_revision':5,'revoked':False})
        self.assertEqual(self.sql('SELECT state FROM application_proof_proposal.challenges WHERE id='+literal(issued2['challenge_id'])),'superseded')
        self.assertEqual(verified,self.call('read',payload={'receipt_id':verified['receipt_id']}))

    def test_current_authority_scope_suspension_and_revocation(self):
        before,changes=self.plan()
        for args in [{'actor':13},{'workspace':11},{'application':12},{'environment':'development'}, {'actor':13,'workspace':11,'application':12}]:
            with self.assertRaises(AssertionError): self.configure(before,changes,**args)
        for table in ['applications','environments']:
            self.sql('UPDATE proof_parent_fixture.'+table+' SET suspended=true')
            with self.assertRaisesRegex(AssertionError,'resource suspended'): self.configure(before,changes)
            self.sql('UPDATE proof_parent_fixture.'+table+' SET suspended=false')
        self.call('revoke','revoke')
        before,changes=self.plan()
        with self.assertRaisesRegex(AssertionError,'origin revoked'): self.configure(before,changes)

    def test_complete_snapshot_conflicts_including_unchanged_origin(self):
        mutations=["UPDATE proof_parent_fixture.applications SET name='Changed'",
                   "UPDATE proof_parent_fixture.origins SET proof_revision=proof_revision+1 WHERE origin='https://other.example'",
                   "UPDATE proof_parent_fixture.origins SET return_urls=ARRAY[origin||'/changed'] WHERE origin='https://other.example'",
                   "DELETE FROM proof_parent_fixture.origins WHERE origin='https://other.example'"]
        for mutation in mutations:
            self.setUp()
            before,changes=self.plan()
            self.sql(mutation)
            with self.assertRaisesRegex(AssertionError,'snapshot conflict'): self.configure(before,changes)

    def test_rejects_injected_revisions_origins_destinations_and_noop(self):
        before,changes=self.plan()
        bad=[]
        changed=copy.deepcopy(changes);changed[0]['next']['proof_revision']+=1;bad.append(changed)
        changed=copy.deepcopy(changes);changed[0]['expected']['cas_revision']+=1;bad.append(changed)
        changed=copy.deepcopy(changes);changed[0]['origin']='https://new.example';bad.append(changed)
        changed=copy.deepcopy(changes);changed[0]['return_urls']=['https://foreign.example/done'];bad.append(changed)
        changed=copy.deepcopy(changes);changed[0]['return_urls']=[ORIGIN+'/done'];bad.append(changed)
        changed=copy.deepcopy(changes);changed[0]['return_urls']=[ORIGIN+'/new#fragment'];bad.append(changed)
        changed=copy.deepcopy(changes);changed[0]['return_urls']=[ORIGIN+'/new',ORIGIN+'/new'];bad.append(changed)
        bad.extend([[],changes+changes])
        for value in bad:
            with self.assertRaises(AssertionError): self.configure(before,value)
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.configuration_receipts'),'0')

    def test_exact_retry_unknown_outcome_and_immutable_receipt(self):
        before,changes=self.plan()
        self.sql('BEGIN;'+self.config_statement(before,changes)+'COMMIT;')  # discard committed response
        receipt=self.configure(before,changes)
        self.assertEqual(receipt,self.configure(before,changes))
        self.call('revoke','revoke',(2,1,2))
        self.assertEqual(receipt,self.configure(before,changes))  # authorized historical result only
        with self.assertRaisesRegex(AssertionError,'idempotency conflict'):
            self.configure(before,[{**changes[0],'return_urls':[ORIGIN+'/different']}])
        for table in ['configuration_receipts','configuration_requests']:
            with self.assertRaisesRegex(AssertionError,'immutable'):
                self.sql('DELETE FROM application_proof_proposal.'+table)
        self.sql('UPDATE proof_parent_fixture.authority SET enabled=false')
        with self.assertRaisesRegex(AssertionError,'management authority unavailable'):
            self.configure(before,changes)

    def test_rollback_and_second_origin_failure_restore_all_state(self):
        issued=self.issue()
        before,changes=self.plan(urls={ORIGIN:[ORIGIN+'/new'],SECOND:[SECOND+'/new']})
        self.sql('BEGIN;'+self.config_statement(before,changes)+'ROLLBACK;')
        self.assertEqual(self.snapshot(),before)
        self.sql("ALTER TABLE proof_parent_fixture.origins ADD CONSTRAINT fixture_fail_second CHECK(NOT ('https://other.example/new'=ANY(return_urls)))")
        with self.assertRaisesRegex(AssertionError,'fixture_fail_second'):
            self.configure(before,changes)
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.sql('SELECT state FROM application_proof_proposal.challenges WHERE id='+literal(issued['challenge_id'])),'pending')
        self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.configuration_receipts'),'0')
        self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.configuration_requests'),'0')

    def test_competing_configurations_compare_entire_baseline(self):
        before,first=self.plan()
        _,second=self.plan(before,{SECOND:[SECOND+'/new']})
        self.race(self.config_statement(before,first,'one'),self.config_statement(before,second,'two'),'snapshot conflict')

    def test_configuration_loses_to_proof_issue_and_revoke(self):
        for operation in ['issue','revoke']:
            self.setUp();before,changes=self.plan()
            winner=self.statement(operation,payload={'digest':'a'*64} if operation=='issue' else {})
            self.race(winner,self.config_statement(before,changes),'snapshot conflict')

    def test_issue_on_unchanged_origin_invalidates_configuration_baseline(self):
        before,changes=self.plan()
        winner=self.statement('issue',payload={'digest':'b'*64},origin=SECOND)
        self.race(winner,self.config_statement(before,changes),'snapshot conflict')

    def test_only_changed_origin_pending_challenge_is_invalidated(self):
        first=self.issue()
        second=self.call('issue','second',payload={'digest':'b'*64},origin=SECOND)
        before,changes=self.plan()
        receipt=self.configure(before,changes)
        self.assertEqual(receipt['after']['origins'][1],before['origins'][1])
        self.assertEqual(self.sql('SELECT state FROM application_proof_proposal.challenges WHERE id='+literal(first['challenge_id'])),'superseded')
        self.assertEqual(self.sql('SELECT state FROM application_proof_proposal.challenges WHERE id='+literal(second['challenge_id'])),'pending')

    def test_proof_issue_revoke_and_verify_lose_to_configuration(self):
        for operation in ['issue','revoke','verify']:
            self.setUp()
            if operation=='verify':
                issued=self.issue();revisions=(1,1,2);payload=self.observation(issued)
            else:
                revisions=(1,1,1);payload={'digest':'a'*64} if operation=='issue' else {}
            before,changes=self.plan()
            self.race(self.config_statement(before,changes),self.statement(operation,'later',revisions,payload),'revision conflict')

    def phantom_insert(self):
        return f"""INSERT INTO proof_parent_fixture.origins(workspace_id,application_id,environment,origin,hostname)
        VALUES('{uid(1)}','{uid(2)}','production','https://third.example','third.example')"""

    def test_committed_phantom_or_removal_invalidates_baseline(self):
        for mutation in [self.phantom_insert(),"DELETE FROM proof_parent_fixture.origins WHERE origin='https://other.example'"]:
            self.setUp();before,changes=self.plan()
            self.race(mutation,self.config_statement(before,changes),'snapshot conflict')

    def test_environment_lock_prevents_phantom_during_configuration(self):
        before,changes=self.plan()
        holder=self.holder(self.config_statement(before,changes))
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(self.sql,self.phantom_insert()+';')
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    if int(self.sql("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%third.example%'")): break
                    time.sleep(0.02)
                else: self.fail('origin insert did not wait on parent lock')
                holder.communicate('COMMIT;\n',timeout=5)
                future.result(timeout=5)
            self.assertEqual(len(self.snapshot()['allowed_origins']),3)
            result=json.loads(self.sql('SELECT result FROM application_proof_proposal.configuration_receipts'))
            self.assertEqual(len(result['after']['allowed_origins']),2)
        finally:
            if holder.poll() is None: holder.communicate('ROLLBACK;\n',timeout=5)

    def test_configuration_rechecks_authority_and_suspension_after_wait(self):
        for mutation,error in [('UPDATE proof_parent_fixture.authority SET enabled=false','management authority unavailable'),
                               ('UPDATE proof_parent_fixture.applications SET suspended=true','resource suspended'),
                               ('UPDATE proof_parent_fixture.environments SET suspended=true','resource suspended')]:
            self.setUp();before,changes=self.plan()
            self.race(mutation,self.config_statement(before,changes),error)

    def test_concurrent_exact_retry_produces_one_receipt(self):
        before,changes=self.plan();statement=self.config_statement(before,changes)
        holder=self.holder(statement)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(self.sql,statement)
                self.wait_for_lock();holder.communicate('COMMIT;\n',timeout=5)
                result=json.loads(future.result(timeout=5))
            self.assertEqual(result,self.configure(before,changes))
            self.assertEqual(self.sql('SELECT count(*) FROM application_proof_proposal.configuration_receipts'),'1')
        finally:
            if holder.poll() is None: holder.communicate('ROLLBACK;\n',timeout=5)


if __name__=='__main__': unittest.main(verbosity=2)
