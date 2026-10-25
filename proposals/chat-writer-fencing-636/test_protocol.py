"""Actual draft SQL on a disposable socket-only PostgreSQL cluster. No remote DSN."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BIN = Path(os.environ.get('PG_BIN', '/opt/homebrew/opt/postgresql@17/bin'))
ACCOUNT = '11111111-1111-4111-8111-111111111111'
OTHER = '22222222-2222-4222-8222-222222222222'


def quote(s):
    return "'" + str(s).replace("'", "''") + "'"


class Protocol(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='f636-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp')
        cls.root = Path(cls.temp.name)
        cls.data = cls.root / 'data'
        cls.sock = cls.root / 'sock'
        cls.sock.mkdir()
        cls.addClassCleanup(cls.cleanup)
        subprocess.run([str(BIN/'initdb'), '-D', str(cls.data), '-A', 'trust', '--no-locale', '-E', 'UTF8'], check=True, capture_output=True)
        subprocess.run([str(BIN/'pg_ctl'), '-D', str(cls.data), '-l', str(cls.root/'server.log'), '-o', f"-k {cls.sock} -c listen_addresses=''", '-w', 'start'], check=True, capture_output=True)
        cls.sql("""CREATE ROLE anon LOGIN; CREATE ROLE authenticated LOGIN; CREATE ROLE service_role LOGIN BYPASSRLS;
        CREATE TABLE public.accounts(id uuid primary key);
        INSERT INTO public.accounts VALUES ('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222');
        CREATE FUNCTION public.trigger_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at=now(); RETURN NEW; END $$;""")
        cls.sql((ROOT/'supabase/migrations/20260501000000_open_agents_sessions_and_chats.sql').read_text())
        cls.sql('GRANT USAGE ON SCHEMA public TO service_role,anon,authenticated; GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;')
        cls.sql((HERE/'migration.sql').read_text())
        cls.sql((HERE/'rollback.sql').read_text())
        assert cls.sql("SELECT count(*) FROM pg_roles WHERE rolname='recoup_chat_fence_owner'") == '0'
        cls.sql((HERE/'migration.sql').read_text())

    @classmethod
    def cleanup(cls):
        if (cls.data/'postmaster.pid').exists():
            subprocess.run([str(BIN/'pg_ctl'), '-D', str(cls.data), '-m', 'immediate', '-w', 'stop'], check=True, capture_output=True)
        cls.temp.cleanup()

    @classmethod
    def args(cls):
        return [str(BIN/'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', str(cls.sock), '-d', 'postgres']

    @classmethod
    def sql(cls, sql):
        args = cls.args()
        for role in ('service_role', 'anon', 'authenticated'):
            prefix = f'SET ROLE {role};'
            if sql.startswith(prefix):
                args += ['-U', role]
                sql = sql[len(prefix):]
                break
        r = subprocess.run(args, input=sql, text=True, capture_output=True, timeout=15)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def setUp(self):
        self.chat = 'legacy-text-chat-' + str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES({quote(self.chat)},'{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES({quote(self.chat)},{quote(self.chat)},'synthetic');")
        self.sql(f"SELECT public.enable_chat_fence({quote(self.chat)},'{ACCOUNT}')")

    def command_sql(self, action, data, chat=None, account=ACCOUNT):
        return f"SET ROLE service_role; SELECT public.chat_fence_command({quote(chat or self.chat)},'{account}',{quote(action)},{quote(json.dumps(data))}::jsonb);"

    def cmd(self, action, data, **kw):
        return json.loads(self.sql(self.command_sql(action, data, **kw)))

    def admit(self, expected=0, key=None):
        key = key or str(uuid.uuid4())
        result = self.cmd('admit', {'request_id': key, 'expected_epoch': expected, 'input_hash': 'a'*64})
        return {'owner': key, 'epoch': result['epoch']}

    def bind(self, token, run='run-1'):
        self.cmd('bind', {**token, 'run_id': run})
        return {**token, 'run_id': run}

    def write(self, token, id='message', role='assistant', parts=None, mode='upsert'):
        return self.cmd('write', {**token, 'id': self.chat+id, 'role':role,'parts':{'id':self.chat+id,'role':role,'parts':parts or []},'mode':mode})

    def release(self, token):
        return self.cmd('release', {**token, 'reason':'terminal'})

    def delete(self, epoch, key=None):
        return self.cmd('delete', {'request_id':key or str(uuid.uuid4()),'expected_epoch':epoch,'anchor_id':self.chat+'message'})

    def test_late_user_stale_assistant_update_parts_and_tombstone(self):
        token = self.bind(self.admit())
        self.write(token)
        self.assertTrue(self.release(token)['released'])
        receipt = self.delete(1)
        self.assertEqual(receipt['deleted'], 1)
        for action,data in [('write',{'role':'user','mode':'insert'}),('write',{'role':'assistant','mode':'upsert'}),('update_parts',{})]:
            with self.assertRaisesRegex(AssertionError,'stale writer'):
                self.cmd(action,{**token,'id':self.chat+'message','parts':[],**data})
        new = self.bind(self.admit(2),'run-new')
        with self.assertRaisesRegex(AssertionError,'deleted identity'):
            self.write(new)
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_messages WHERE chat_id={quote(self.chat)}"),'0')
        self.assertFalse(self.cmd('update_parts',{**new,'id':'missing','parts':{'id':'missing','role':'assistant','parts':[]}})['updated'])

    def test_two_admissions_and_headless_start_must_bind_once(self):
        def claim(_):
            try: return self.admit()
            except AssertionError as e: self.assertIn('admission conflict',str(e)); return None
        with concurrent.futures.ThreadPoolExecutor(2) as ex:
            results=list(ex.map(claim,range(2)))
        winners=[r for r in results if r]
        self.assertEqual(len(winners),1)
        token=winners[0]
        with self.assertRaisesRegex(AssertionError,'not bound'):
            self.write(token)
        with self.assertRaisesRegex(AssertionError,'delete conflict'):
            self.delete(1)
        first=self.bind(token,'first-run')
        with self.assertRaisesRegex(AssertionError,'already bound'):
            self.bind(token,'duplicate-run')
        self.write(first)
        self.assertFalse(self.cmd('release',{**token,'epoch':0,'reason':'terminal','run_id':'first-run'})['released'])
        self.assertEqual(self.cmd('state',{})['run_id'],'first-run')

    def test_crash_retry_receipts_and_owner_cleanup(self):
        key=str(uuid.uuid4());t=self.admit(key=key)
        self.assertEqual(self.admit(key=key),t) # committed response lost
        with self.assertRaisesRegex(AssertionError,'retry input conflict'):
            self.cmd('admit',{'request_id':key,'expected_epoch':0,'input_hash':'b'*64})
        token=self.bind(t);self.write(token);self.release(token)
        delete_key=str(uuid.uuid4());receipt=self.delete(1,delete_key)
        new=self.bind(self.admit(2),'run-2');self.write(new,'new')
        self.assertEqual(self.delete(1,delete_key),receipt) # retry does not delete newer work
        self.assertFalse(self.release(token)['released'])
        self.assertEqual(self.cmd('state',{})['run_id'],'run-2')
        closed=self.cmd('admit',{'request_id':key,'expected_epoch':0,'input_hash':'a'*64})
        self.assertTrue(closed['closed'])
        with self.assertRaisesRegex(AssertionError,'stale writer'):
            self.bind(token)

    def test_acl_legacy_bulk_cascades_and_cross_chat_identity(self):
        for sql in [
            f"INSERT INTO chat_messages(id,chat_id,role,parts) VALUES('legacy',{quote(self.chat)},'user','[]')",
            f"UPDATE chats SET active_stream_id='wrong' WHERE id={quote(self.chat)}",
            f"UPDATE sessions SET account_id='{OTHER}' WHERE id={quote(self.chat)}",
            f"DELETE FROM chats WHERE id={quote(self.chat)}",
            f"DELETE FROM sessions WHERE id={quote(self.chat)}",
            'TRUNCATE chat_messages',
            f"DELETE FROM chat_fence.state WHERE chat_id={quote(self.chat)}",
            "SET ROLE recoup_chat_fence_owner",
            f"SELECT enable_chat_fence({quote(self.chat)},'{ACCOUNT}')",
        ]:
            with self.assertRaises(AssertionError): self.sql('SET ROLE service_role; '+sql)
        for role in ['anon','authenticated']:
            with self.assertRaisesRegex(AssertionError,'permission denied'):
                self.sql(self.command_sql('state',{}).replace('SET ROLE service_role',f'SET ROLE {role}'))
        with self.assertRaisesRegex(AssertionError,'ownership denied'): self.cmd('state',{},account=OTHER)
        token=self.bind(self.admit());self.write(token)
        for mutation in [f"UPDATE chat_messages SET parts='[1]' WHERE chat_id={quote(self.chat)}",f"DELETE FROM chat_messages WHERE chat_id={quote(self.chat)}"]:
            with self.assertRaisesRegex(AssertionError,'requires RPC'): self.sql('SET ROLE service_role; '+mutation)
        foreign='foreign-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{foreign}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES('{foreign}','{foreign}','synthetic'); INSERT INTO chat_messages(id,chat_id,role,parts) VALUES('{foreign}','{foreign}','assistant','[]')")
        with self.assertRaisesRegex(AssertionError,'foreign message identity'):
            self.cmd('write',{**token,'id':foreign,'role':'assistant','parts':{'id':foreign,'role':'assistant','parts':[]},'mode':'upsert'})

    def test_abort_uncommitted_admission_and_pending_failure_recovery(self):
        key=str(uuid.uuid4())
        self.sql('BEGIN; '+self.command_sql('admit',{'request_id':key,'expected_epoch':0,'input_hash':'a'*64})+' ROLLBACK;')
        token=self.admit(key=key)
        with self.assertRaisesRegex(AssertionError,'release proof'):
            self.cmd('release',{**token,'reason':'timeout'})
        self.assertTrue(self.cmd('release',{**token,'reason':'confirmed_no_start'})['released'])
        new=self.admit(1)
        with self.assertRaisesRegex(AssertionError,'stale writer'):self.bind(token)
        self.assertEqual(self.cmd('state',{})['owner'],new['owner'])

    def test_actual_row_lock_orders_delete_and_new_admission(self):
        token=self.bind(self.admit());self.write(token);self.release(token)
        # Hold the real deletion transaction after its RPC; admission blocks on its chat row.
        process=subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
        try:
            payload={'request_id':str(uuid.uuid4()),'expected_epoch':1,'anchor_id':self.chat+'message'}
            process.stdin.write('BEGIN; '+self.command_sql('delete',payload)+" SELECT 'LOCKED';\n");process.stdin.flush()
            while process.stdout.readline().strip()!='LOCKED':
                if process.poll() is not None:self.fail('lock holder terminated')
            with concurrent.futures.ThreadPoolExecutor(2) as ex:
                future=ex.submit(self.admit,1)
                stale = ex.submit(self.write, token)
                deadline = time.monotonic() + 4
                while int(self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%{self.chat}%' AND pid<>pg_backend_pid()")) < 2:
                    if time.monotonic()>deadline: self.fail('both real SQL callers did not reach lock wait')
                    time.sleep(.02)
                self.assertFalse(future.done())
                self.assertFalse(stale.done())
                process.stdin.write('COMMIT;\n');process.stdin.flush()
                with self.assertRaisesRegex(AssertionError,'admission conflict'):future.result(timeout=5)
                with self.assertRaisesRegex(AssertionError,'stale writer'):stale.result(timeout=5)
            self.assertEqual(self.cmd('state',{})['epoch'],2)
        finally:
            process.stdin.close();process.wait(timeout=5)
            process.stdout.close();process.stderr.close()
        # Opposite serial order: admission wins, so delete cannot proceed.
        new=self.admit(2)
        with self.assertRaisesRegex(AssertionError,'delete conflict'): self.delete(2)
        self.assertEqual(self.cmd('state',{})['owner'],new['owner'])

    def test_tuple_precision_envelope_and_legacy_identity_reuse(self):
        chat='tuple-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{chat}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES('{chat}','{chat}','synthetic');")
        rows=[('a','2026-10-25T12:00:00.123456Z'),('b','2026-10-25T12:00:00.123456Z'),('c','2026-10-25T12:00:00.123456Z'),('d','2026-10-25T12:00:00.123455Z'),('e','2026-10-25T12:00:00.123457Z')]
        for suffix,ts in rows:
            id=chat+suffix;envelope={'id':id,'role':'user','parts':[{'type':'text','text':'synthetic'}]}
            self.sql(f"SET ROLE service_role; INSERT INTO chat_messages(id,chat_id,role,parts,created_at) VALUES('{id}','{chat}','user',{quote(json.dumps(envelope))},'{ts}')")
        self.sql(f"SELECT enable_chat_fence('{chat}','{ACCOUNT}')")
        receipt=self.cmd('delete',{'request_id':str(uuid.uuid4()),'expected_epoch':0,'anchor_id':chat+'b'},chat=chat)
        self.assertEqual(receipt['deleted'],3)
        self.assertEqual(self.sql(f"SELECT string_agg(right(id,1),',' ORDER BY id) FROM chat_messages WHERE chat_id='{chat}'"),'a,d')
        other='unenrolled-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{other}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES('{other}','{other}','synthetic');")
        with self.assertRaisesRegex(AssertionError,'deleted identity'):
            self.sql(f"SET ROLE service_role; INSERT INTO chat_messages(id,chat_id,role,parts) VALUES('{chat}b','{other}','user','{{}}')")
        token=self.bind(self.admit())
        self.write(token,'user',role='user',mode='insert',parts=[{'type':'text','text':'question'}])
        self.write(token,parts=[{'type':'text','text':'kept'}])
        row=json.loads(self.sql(f"SELECT parts FROM chat_messages WHERE id={quote(self.chat+'message')}"))
        self.assertEqual(row,{'id':self.chat+'message','role':'assistant','parts':[{'type':'text','text':'kept'}]})
        row['parts'].append({'type':'data-commit','id':'commit-1','data':{'sha':'synthetic'}})
        self.assertTrue(self.cmd('update_parts',{**token,'id':self.chat+'message','parts':row})['updated'])
        self.assertEqual(json.loads(self.sql(f"SELECT parts FROM chat_messages WHERE id={quote(self.chat+'message')}")),row)
        with self.assertRaisesRegex(AssertionError,'invalid stored UIMessage'):
            self.cmd('write',{**token,'id':'wrong-envelope','role':'assistant','parts':[]})
        with self.assertRaisesRegex(AssertionError,'unsupported command'):
            self.sql(self.command_sql('write',{**token,'id':'wrong-action','role':'assistant','parts':[]}).replace("'write',","NULL,"))
        with self.assertRaisesRegex(AssertionError,'Enabled chat fences exist'):
            self.sql((HERE/'rollback.sql').read_text())

    def test_old_repeatable_and_serializable_snapshot_cannot_bypass_activation(self):
        for isolation in ('REPEATABLE READ','SERIALIZABLE'):
            chat='snapshot-'+str(uuid.uuid4())
            self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{chat}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES('{chat}','{chat}','synthetic');")
            process=subprocess.Popen(self.args()+['-U','service_role'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
            process.stdin.write(f"BEGIN ISOLATION LEVEL {isolation}; SELECT count(*) FROM chat_fence.state; SELECT 'SNAPSHOT';\n");process.stdin.flush()
            while process.stdout.readline().strip()!='SNAPSHOT':
                if process.poll() is not None:self.fail('snapshot holder terminated')
            self.sql(f"SELECT enable_chat_fence('{chat}','{ACCOUNT}')")
            process.stdin.write(f"INSERT INTO chat_messages(id,chat_id,role,parts) VALUES('{chat}-late','{chat}','user','{{}}'); COMMIT;\n");process.stdin.flush();process.stdin.close()
            self.assertNotEqual(process.wait(timeout=5),0)
            self.assertIn('requires READ COMMITTED',process.stderr.read())
            process.stdout.close();process.stderr.close()
            self.assertEqual(self.sql(f"SELECT count(*) FROM chat_messages WHERE chat_id='{chat}'"),'0')
            with self.assertRaisesRegex(AssertionError,'requires READ COMMITTED'):
                self.sql(f"SET ROLE service_role; BEGIN ISOLATION LEVEL {isolation}; SELECT chat_fence_command('{chat}','{ACCOUNT}','state','{{}}')")

    def test_activation_blocks_pending_legacy_slot_and_direct_identity_moves(self):
        chat='not-enabled-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{chat}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title,active_stream_id) VALUES('{chat}','{chat}','synthetic','legacy-run');")
        with self.assertRaisesRegex(AssertionError,'occupied or changed'):
            self.sql(f"SELECT enable_chat_fence('{chat}','{ACCOUNT}')")
        self.sql(f"SET ROLE service_role; INSERT INTO chat_messages(id,chat_id,role,parts) VALUES('{chat}-msg','{chat}','user','{{}}')")
        with self.assertRaisesRegex(AssertionError,'identity move'):
            self.sql(f"SET ROLE service_role; UPDATE chat_messages SET chat_id={quote(self.chat)} WHERE id='{chat}-msg'")
        with self.assertRaises(AssertionError):
            self.sql(f"SET ROLE service_role; INSERT INTO chat_messages(id,chat_id,role,parts) VALUES('{chat}-bulk','{chat}','user','{{}}'),('fenced-bulk',{quote(self.chat)},'user','{{}}')")
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_messages WHERE id='{chat}-bulk'"),'0')


    def test_cross_chat_legacy_insert_waiting_on_delete_cannot_reuse_identity(self):
        token=self.bind(self.admit());self.write(token);self.release(token)
        other='legacy-target-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{other}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES('{other}','{other}','synthetic');")
        process=subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
        try:
            payload={'request_id':str(uuid.uuid4()),'expected_epoch':1,'anchor_id':self.chat+'message'}
            process.stdin.write('BEGIN; '+self.command_sql('delete',payload)+" SELECT 'LOCKED';\n");process.stdin.flush()
            while process.stdout.readline().strip()!='LOCKED':
                if process.poll() is not None:self.fail('delete holder terminated')
            sql=f"SET ROLE service_role; INSERT INTO chat_messages(id,chat_id,role,parts) VALUES({quote(self.chat+'message')},'{other}','user','{{}}')"
            with concurrent.futures.ThreadPoolExecutor(1) as ex:
                future=ex.submit(self.sql,sql)
                deadline=time.monotonic()+4
                while int(self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%{other}%' AND pid<>pg_backend_pid()"))<1:
                    if time.monotonic()>deadline:self.fail('legacy INSERT did not reach unique-index wait')
                    time.sleep(.02)
                process.stdin.write('COMMIT;\n');process.stdin.flush()
                with self.assertRaisesRegex(AssertionError,'deleted identity'):future.result(timeout=5)
            self.assertEqual(self.sql(f"SELECT count(*) FROM chat_messages WHERE id={quote(self.chat+'message')}"),'0')
        finally:
            process.stdin.close();process.wait(timeout=5);process.stdout.close();process.stderr.close()


if __name__=='__main__': unittest.main(verbosity=2)
