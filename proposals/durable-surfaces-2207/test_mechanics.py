"""Offline mechanics proof on actual 636 SQL; source authority is a named fixture.
No production DSN, migrations, provider, credentials, or runtime enrollment.
"""
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import unittest
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fence_fixture', HERE.parent/'chat-writer-fencing-636/test_protocol.py')
fence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fence)
quote, ACCOUNT, OTHER = fence.quote, fence.ACCOUNT, fence.OTHER

class Mechanics(fence.Protocol):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((HERE/'proposal.sql').read_text())
        # Demonstrate default deny before replacing the adapter in this fixture.
        try:
            cls.sql(f"SET ROLE recoup_chat_fence_owner; SELECT chat_fence.authorize_working_surface('{ACCOUNT}','{ACCOUNT}','{{}}')")
            raise RuntimeError('default authority gate unexpectedly permitted')
        except AssertionError as error:
            assert 'adapter unavailable' in str(error)
        cls.sql("""SET ROLE recoup_chat_fence_owner;
        CREATE TABLE chat_fence.fixture_authority(account_id uuid,workspace_id uuid,allowed boolean,source_allowed boolean,PRIMARY KEY(account_id,workspace_id));
        CREATE OR REPLACE FUNCTION chat_fence.authorize_working_surface(p_account uuid,p_workspace uuid,p_binding jsonb) RETURNS void
        LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
          PERFORM 1 FROM chat_fence.fixture_authority WHERE account_id=p_account AND workspace_id=p_workspace AND allowed AND (source_allowed OR p_binding->>'purpose'='delete') FOR SHARE;
          IF NOT FOUND OR p_binding->'binding' IS DISTINCT FROM '{"fixture":"source"}'::jsonb THEN
            RAISE EXCEPTION 'fixture authority denied' USING ERRCODE='42501'; END IF;
        END $$;
        GRANT EXECUTE ON FUNCTION chat_fence.working_surface_command(text,uuid,text,jsonb) TO service_role;
        """)

    def setUp(self):
        super().setUp()
        self.sql(f"INSERT INTO chat_fence.fixture_authority VALUES('{ACCOUNT}','{ACCOUNT}',true,true) ON CONFLICT(account_id,workspace_id) DO UPDATE SET allowed=true,source_allowed=true")
        self.message_id=self.chat+'message'
        self.surface={'schemaVersion':1,'id':'surface-'+str(uuid.uuid4()),'revision':1,'context':{'workspaceId':ACCOUNT,'subject':{'kind':'recording','id':OTHER,'label':'fixture'}},'components':[],'evidence':[],'fallbackText':'Fixture'}
        self.part={'type':'data-intelligent-ui-snapshot','id':self.surface['id'],'data':self.surface}
        token=self.bind(self.admit());self.write(token,parts=[self.part]);self.release(token)
        self.work={'recipe':{'id':'fixture','version':1},'displayName':'Working view','filters':{'search':''},'selection':[]}
        self.create={'message_id':self.message_id,'request_id':str(uuid.uuid4()),'expected_revision':0,'workspace_id':ACCOUNT,'surface_id':self.surface['id'],'surface_revision':1,'authority_binding':{'fixture':'source'},'work':self.work}

    def surface_sql(self, action, data, account=ACCOUNT, role='service_role'):
        return f"SET ROLE {role}; SELECT chat_fence.working_surface_command({quote(self.chat)},'{account}',{quote(action)},{quote(json.dumps(data))}::jsonb);"

    def surface_cmd(self, action, data, **kw):
        return json.loads(self.sql(self.surface_sql(action,data,**kw)))

    def save_data(self, revision=1):
        return {'message_id':self.message_id,'request_id':str(uuid.uuid4()),'expected_revision':revision,'work':{**self.work,'displayName':'Changed'}}

    def test_work_create_retry_conflict_and_exact_read(self):
        a=self.surface_cmd('create',self.create)
        self.assertEqual(a['revision'],1)
        self.assertEqual(self.surface_cmd('head',{'message_id':self.message_id})['revision'],1)
        self.assertEqual(self.surface_cmd('create',self.create),a)
        changed={**self.create,'work':{**self.work,'displayName':'Different'}}
        with self.assertRaisesRegex(AssertionError,'different command'):self.surface_cmd('create',changed)
        b=self.surface_cmd('save',self.save_data())
        self.assertEqual(b['revision'],2)
        with self.assertRaisesRegex(AssertionError,'stale working'):self.surface_cmd('read',{'message_id':self.message_id,'revision':1})
        self.assertEqual(self.surface_cmd('read',{'message_id':self.message_id,'revision':2})['work']['displayName'],'Changed')
        self.assertEqual(self.surface_cmd('reconcile',{'request_id':self.create['request_id']}),a)
        with self.assertRaisesRegex(AssertionError,'stale'):self.surface_cmd('save',self.save_data())

    def test_work_rollback_and_lost_ack(self):
        self.sql('BEGIN; '+self.surface_sql('create',self.create)+' ROLLBACK;')
        with self.assertRaisesRegex(AssertionError,'receipt not found'):self.surface_cmd('reconcile',{'request_id':self.create['request_id']})
        self.surface_cmd('create',self.create)  # deliberately discard committed receipt
        self.assertEqual(self.surface_cmd('reconcile',{'request_id':self.create['request_id']})['revision'],1)
        self.assertEqual(self.surface_cmd('create',self.create)['revision'],1)
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_fence.working_surface_commands WHERE chat_id={quote(self.chat)}"),'1')

    def test_work_scope_acl_and_revocation_on_retry(self):
        for role in ('anon','authenticated'):
            with self.assertRaisesRegex(AssertionError,'permission denied'):self.surface_cmd('create',self.create,role=role)
        with self.assertRaisesRegex(AssertionError,'ownership denied'):self.surface_cmd('create',self.create,account=OTHER)
        with self.assertRaisesRegex(AssertionError,'scope mismatch'):self.surface_cmd('create',{**self.create,'workspace_id':OTHER})
        self.surface_cmd('create',self.create)
        self.sql(f"UPDATE chat_fence.fixture_authority SET source_allowed=false WHERE account_id='{ACCOUNT}'")
        for action,payload in [('create',self.create),('read',{'message_id':self.message_id,'revision':1}),('reconcile',{'request_id':self.create['request_id']})]:
            with self.assertRaisesRegex(AssertionError,'authority denied'):self.surface_cmd(action,payload)

    def test_work_receipt_failure_rolls_back_changed_controls(self):
        self.surface_cmd('create',self.create)
        self.sql("""CREATE FUNCTION chat_fence.fixture_fail_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture receipt failure'; END $$;
        CREATE TRIGGER fixture_fail_receipt BEFORE INSERT ON chat_fence.working_surface_commands FOR EACH ROW EXECUTE FUNCTION chat_fence.fixture_fail_receipt();""")
        candidate=self.save_data()
        try:
            with self.assertRaisesRegex(AssertionError,'fixture receipt failure'):self.surface_cmd('save',candidate)
        finally:
            self.sql('DROP TRIGGER fixture_fail_receipt ON chat_fence.working_surface_commands; DROP FUNCTION chat_fence.fixture_fail_receipt()')
        self.assertEqual(self.surface_cmd('read',{'message_id':self.message_id,'revision':1})['work'],self.work)
        with self.assertRaisesRegex(AssertionError,'receipt not found'):self.surface_cmd('reconcile',{'request_id':candidate['request_id']})

    def test_work_delete_after_source_withdrawal_still_requires_workspace(self):
        self.surface_cmd('create',self.create)
        self.sql(f"UPDATE chat_fence.fixture_authority SET source_allowed=false WHERE account_id='{ACCOUNT}'")
        delete={'message_id':self.message_id,'request_id':str(uuid.uuid4()),'expected_revision':1}
        receipt=self.surface_cmd('delete',delete)
        self.assertTrue(receipt['deleted'])
        self.assertEqual(self.surface_cmd('reconcile',{'request_id':delete['request_id']}),receipt)
        self.assertEqual(self.surface_cmd('delete',delete),receipt)
        self.sql(f"UPDATE chat_fence.fixture_authority SET allowed=false WHERE account_id='{ACCOUNT}'")
        with self.assertRaisesRegex(AssertionError,'authority denied'):self.surface_cmd('delete',delete)
        with self.assertRaisesRegex(AssertionError,'authority denied'):self.surface_cmd('reconcile',{'request_id':delete['request_id']})

    def test_work_full_message_writers_cannot_clobber_companion_or_source(self):
        self.surface_cmd('create',self.create)
        full={'id':self.message_id,'role':'assistant','parts':[self.part,{'type':'text','text':'new unrelated output'}]}
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE public.chat_messages SET parts={quote(json.dumps(full))}::jsonb WHERE id={quote(self.message_id)}")
        self.assertEqual(self.surface_cmd('read',{'message_id':self.message_id,'revision':1})['work'],self.work)
        full['parts'][0]['data']['fallbackText']='clobbered'
        with self.assertRaisesRegex(AssertionError,'immutable'):
            self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE public.chat_messages SET parts={quote(json.dumps(full))}::jsonb WHERE id={quote(self.message_id)}")
        with self.assertRaisesRegex(AssertionError,'requires RPC'):
            self.sql(f"SET ROLE service_role; UPDATE public.chat_messages SET parts='{{}}' WHERE id={quote(self.message_id)}")

    def test_work_logical_delete_and_anchor_delete_do_not_resurrect(self):
        self.surface_cmd('create',self.create)
        delete={'message_id':self.message_id,'request_id':str(uuid.uuid4()),'expected_revision':1}
        receipt=self.surface_cmd('delete',delete)
        self.assertTrue(receipt['deleted'])
        self.assertEqual(self.surface_cmd('delete',delete),receipt)
        with self.assertRaisesRegex(AssertionError,'deleted'):self.surface_cmd('save',self.save_data(2))
        self.assertIsNone(json.loads(self.sql(f"SELECT to_jsonb(work) FROM chat_fence.working_surfaces WHERE message_id={quote(self.message_id)}") or 'null'))
        self.assertEqual(self.surface_cmd('reconcile',{'request_id':self.create['request_id']})['revision'],1)
        epoch=self.cmd('state',{})['epoch']
        self.delete(epoch)
        token=self.bind(self.admit(epoch+1))
        with self.assertRaisesRegex(AssertionError,'tombstone|deleted'):self.write(token)
        with self.assertRaisesRegex(AssertionError,'surface deleted'):self.surface_cmd('read',{'message_id':self.message_id,'revision':2})

    def test_work_actual_anchor_delete_marks_companion(self):
        self.surface_cmd('create',self.create)
        self.delete(self.cmd('state',{})['epoch'])
        row=json.loads(self.sql(f"SELECT jsonb_build_object('deleted',deleted,'revision',revision,'work',work) FROM chat_fence.working_surfaces WHERE message_id={quote(self.message_id)}"))
        self.assertEqual(row,{'deleted':True,'revision':2,'work':None})
        with self.assertRaisesRegex(AssertionError,'deleted'):self.surface_cmd('create',{**self.create,'request_id':str(uuid.uuid4())})

    def race(self, first, second):
        process=subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
        try:
            process.stdin.write('BEGIN; '+first+" SELECT 'LOCKED';\n");process.stdin.flush()
            while process.stdout.readline().strip()!='LOCKED':
                if process.poll() is not None:self.fail('first transaction failed')
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                future=pool.submit(self.sql,second)
                deadline=time.monotonic()+4
                while int(self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%{self.chat}%' AND pid<>pg_backend_pid()"))<1:
                    if time.monotonic()>deadline:self.fail('no actual lock wait')
                    time.sleep(.02)
                self.assertFalse(future.done())
                process.stdin.write('COMMIT;\n');process.stdin.flush()
                try:return future.result(timeout=5)
                except AssertionError as error:return str(error)
        finally:
            process.stdin.close();process.wait(timeout=5);process.stdout.close();process.stderr.close()

    def test_work_two_tab_cas_real_lock_wait(self):
        self.surface_cmd('create',self.create)
        result=self.race(self.surface_sql('save',self.save_data()),self.surface_sql('save',self.save_data()))
        self.assertIn('stale',result)
        self.assertEqual(self.surface_cmd('read',{'message_id':self.message_id,'revision':2})['revision'],2)

    def test_work_two_create_keys_real_lock_wait(self):
        result=self.race(self.surface_sql('create',self.create),self.surface_sql('create',{**self.create,'request_id':str(uuid.uuid4())}))
        self.assertIn('already exists',result)
        self.assertEqual(self.surface_cmd('head',{'message_id':self.message_id})['revision'],1)

    def test_work_save_then_delete_real_lock_wait(self):
        self.surface_cmd('create',self.create)
        delete=self.command_sql('delete',{'request_id':str(uuid.uuid4()),'expected_epoch':self.cmd('state',{})['epoch'],'anchor_id':self.message_id})
        result=self.race(self.surface_sql('save',self.save_data()),delete)
        self.assertIn('deleted',result)
        self.assertEqual(self.sql(f"SELECT revision FROM chat_fence.working_surfaces WHERE message_id={quote(self.message_id)}"),'3')
        with self.assertRaisesRegex(AssertionError,'deleted'):self.surface_cmd('head',{'message_id':self.message_id})

    def test_work_source_revocation_waits_then_blocks_future_read(self):
        self.surface_cmd('create',self.create)
        revoke=f"UPDATE chat_fence.fixture_authority SET source_allowed=false WHERE account_id='{ACCOUNT}' AND {quote(self.chat)}={quote(self.chat)}"
        self.race(self.surface_sql('save',self.save_data()),revoke)
        with self.assertRaisesRegex(AssertionError,'authority denied'):self.surface_cmd('head',{'message_id':self.message_id})

    def test_work_save_vs_anchor_delete_real_lock_wait(self):
        self.surface_cmd('create',self.create)
        delete=self.command_sql('delete',{'request_id':str(uuid.uuid4()),'expected_epoch':self.cmd('state',{})['epoch'],'anchor_id':self.message_id})
        result=self.race(delete,self.surface_sql('save',self.save_data()))
        self.assertIn('deleted',result)
        self.assertEqual(self.sql(f"SELECT count(*) FROM public.chat_messages WHERE id={quote(self.message_id)}"),'0')

    def test_work_source_size_bound(self):
        self.part['data']['fallbackText']='x'*270000
        full={'id':self.message_id,'role':'assistant','parts':[self.part]}
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE public.chat_messages SET parts={quote(json.dumps(full))}::jsonb WHERE id={quote(self.message_id)}")
        with self.assertRaisesRegex(AssertionError,'source snapshot envelope'):self.surface_cmd('create',self.create)

    def test_work_invalid_bounds_busy_and_absence(self):
        with self.assertRaisesRegex(AssertionError,'unknown|invalid'):self.surface_cmd('create',{**self.create,'execute':'payment'})
        with self.assertRaisesRegex(AssertionError,'invalid working command'):self.surface_cmd('create',{**self.create,'work':{**self.work,'filters':{'search':'x'*140000}}})
        with self.assertRaisesRegex(AssertionError,'bounded working state'):self.surface_cmd('create',{**self.create,'work':{**self.work,'filters':{'search':'x'*70000}}})
        with self.assertRaisesRegex(AssertionError,'working state'):self.surface_cmd('create',{**self.create,'work':{**self.work,'secret':'no'}})
        with self.assertRaisesRegex(AssertionError,'selection bound'):self.surface_cmd('create',{**self.create,'work':{**self.work,'selection':[{}]*9}})
        with self.assertRaisesRegex(AssertionError,'already exists'):self.surface_cmd('create',{**self.create,'expected_revision':1})
        self.admit(self.cmd('state',{})['epoch'])
        with self.assertRaisesRegex(AssertionError,'busy'):self.surface_cmd('create',self.create)

class FenceRegression(fence.Protocol):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sql((HERE/'proposal.sql').read_text())

if __name__=='__main__':
    suite=unittest.TestSuite(Mechanics(name) for name in unittest.defaultTestLoader.getTestCaseNames(Mechanics) if name.startswith('test_work_'))
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(FenceRegression))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
