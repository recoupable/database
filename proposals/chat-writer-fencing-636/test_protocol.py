"""Actual draft SQL on a disposable socket-only PostgreSQL cluster. No remote DSN."""
import concurrent.futures
import json
import hashlib
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

    def snapshot_payload(self, data, chat=None, account=ACCOUNT):
        chat=chat or self.chat
        snapshot={'contractVersion':'chat-execution/v1','effectiveAccountId':account,'chatId':chat,'sessionId':chat,'id':'snapshot-'+data['request_id'],'requestId':data['request_id'],'content':{'modelId':'synthetic','credentialIdentity':{'accountId':account,'id':'reference-only'}}}
        canonical=lambda value:json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)
        digest=lambda value:hashlib.sha256(value.encode('utf8')).hexdigest()
        snapshot_bytes=canonical(snapshot)
        envelope={'contractVersion':'chat-admission/v1','effectiveAccountId':account,'chatId':chat,'sessionId':chat,'expectedEpoch':data['expected_epoch'],'messages':[{'id':'synthetic-user','role':'user','parts':[{'type':'text','text':'changed' if data.get('input_hash')=='b'*64 else 'original'}]}],'options':{'modelId':'synthetic','artistId':None,'interactive':True,'devSurface':None},'executionSnapshot':{'id':snapshot['id'],'digest':digest(snapshot_bytes)}}
        envelope_bytes=canonical(envelope)
        return {**data,'input_hash':digest(envelope_bytes),'admission_envelope':envelope,'execution_snapshot':snapshot,'admission_canonical':envelope_bytes,'execution_canonical':snapshot_bytes}

    def command_sql(self, action, data, chat=None, account=ACCOUNT):
        if action=='admit' and 'admission_envelope' not in data:
            data=self.snapshot_payload(data,chat,account)
        return f"SET ROLE service_role; SELECT public.chat_fence_command({quote(chat or self.chat)},'{account}',{quote(action)},{quote(json.dumps(data))}::jsonb);"

    def cmd(self, action, data, **kw):
        return json.loads(self.sql(self.command_sql(action, data, **kw)))

    def admit(self, expected=0, key=None):
        key = key or str(uuid.uuid4())
        result = self.cmd('admit', {'request_id': key, 'expected_epoch': expected, 'input_hash': 'a'*64})
        return {'owner': key, 'epoch': result['epoch']}

    def bind(self, token, run='run-1'):
        dispatch=self.cmd('admission_snapshot',{'request_id':token['owner']})['dispatch']
        attempt=dispatch['attempt_id'] or str(uuid.uuid4())
        if dispatch['attempt_id'] is None:
            self.cmd('claim_dispatch',{**token,'attempt_id':attempt})
        self.cmd('bind', {**token, 'run_id': run,'attempt_id':attempt})
        return {**token, 'run_id': run}

    def write(self, token, id='message', role='assistant', parts=None, mode='upsert'):
        return self.cmd('write', {**token, 'id': self.chat+id, 'role':role,'parts':{'id':self.chat+id,'role':role,'parts':parts or []},'mode':mode})

    def release(self, token):
        return self.cmd('release', {**token, 'reason':'external_terminal'})

    def delete(self, epoch, key=None):
        return self.cmd('delete', {'request_id':key or str(uuid.uuid4()),'expected_epoch':epoch,'anchor_id':self.chat+'message'})

    def test_close_unattempted_and_claim_serialize_both_orders(self):
        for first_action in ('claim_dispatch','close_unattempted'):
            token=self.admit(self.cmd('state',{})['epoch'])
            original=self.cmd('admission_snapshot',{'request_id':token['owner']})
            self.assertEqual(original['dispatch']['status'],'never_attempted')
            claim={**token,'attempt_id':str(uuid.uuid4())}
            first_payload=claim if first_action=='claim_dispatch' else token
            second_action='close_unattempted' if first_action=='claim_dispatch' else 'claim_dispatch'
            second_payload=token if second_action=='close_unattempted' else claim
            process=subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
            try:
                process.stdin.write('BEGIN; '+self.command_sql(first_action,first_payload)+" SELECT 'LOCKED';\n");process.stdin.flush()
                while process.stdout.readline().strip()!='LOCKED':
                    if process.poll() is not None:self.fail('first transaction terminated')
                with concurrent.futures.ThreadPoolExecutor(1) as ex:
                    future=ex.submit(self.cmd,second_action,second_payload)
                    deadline=time.monotonic()+4
                    while int(self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%{self.chat}%' AND pid<>pg_backend_pid()"))<1:
                        if time.monotonic()>deadline:self.fail('second caller did not reach real lock wait')
                        time.sleep(.02)
                    self.assertFalse(future.done())
                    process.stdin.write('COMMIT;\n');process.stdin.flush()
                    result=future.result(timeout=5)
                if first_action=='claim_dispatch':
                    self.assertEqual(result,{'closed':False})
                    self.assertEqual(self.cmd('state',{})['owner'],token['owner'])
                    self.assertFalse(self.cmd('admission_snapshot',{'request_id':token['owner']})['receipt']['closed'])
                    # Separate reconciliation route: synthetic authoritative proof only.
                    self.cmd('release',{**token,'reason':'confirmed_no_start'})
                else:
                    self.assertFalse(result['claimed']);self.assertIsNone(result['attempt_id'])
                    self.assertTrue(result['receipt']['closed'])
                    self.assertEqual(self.cmd('state',{})['phase'],'idle')
                after=self.cmd('admission_snapshot',{'request_id':token['owner']})
                for field in ('admission_envelope','execution_snapshot','admission_canonical','execution_canonical'):
                    self.assertEqual(after[field],original[field])
            finally:
                process.stdin.close();process.wait(timeout=5);process.stdout.close();process.stderr.close()

    def test_close_unattempted_retry_rollback_scope_and_new_owner(self):
        token=self.admit()
        with self.assertRaisesRegex(AssertionError,'release proof'):
            self.cmd('release',{**token,'reason':'confirmed_no_start'})
        with self.assertRaisesRegex(AssertionError,'ownership denied'):
            self.cmd('close_unattempted',token,account=OTHER)
        for role in ('anon','authenticated'):
            with self.assertRaisesRegex(AssertionError,'permission denied'):
                self.sql(self.command_sql('close_unattempted',token).replace('SET ROLE service_role',f'SET ROLE {role}'))
        self.assertEqual(self.cmd('close_unattempted',{**token,'epoch':0}),{'closed':False})
        self.assertEqual(self.cmd('close_unattempted',{**token,'owner':str(uuid.uuid4())}),{'closed':False})
        with self.assertRaisesRegex(AssertionError,'missing close identity'):self.cmd('close_unattempted',{})
        self.sql('BEGIN; '+self.command_sql('close_unattempted',token)+' ROLLBACK;')
        self.assertFalse(self.cmd('admission_snapshot',{'request_id':token['owner']})['receipt']['closed'])
        self.assertEqual(self.cmd('state',{})['phase'],'pending')
        self.assertEqual(self.cmd('close_unattempted',token),{'closed':True})
        self.assertEqual(self.cmd('close_unattempted',token),{'closed':False})
        new=self.bind(self.admit(1),'new-bound-run')
        self.assertEqual(self.cmd('close_unattempted',token),{'closed':False})
        self.assertEqual(self.cmd('close_unattempted',new),{'closed':False})
        self.assertEqual(self.cmd('state',{})['run_id'],'new-bound-run')
        closed=self.cmd('admission_snapshot',{'request_id':token['owner']})
        self.assertTrue(closed['receipt']['closed']);self.assertIsNone(closed['receipt']['bound_run_id'])
        self.assertEqual(closed['dispatch']['status'],'never_attempted')

    def test_dispatch_one_shot_concurrent_claim_and_response_loss(self):
        token=self.admit();attempts=[str(uuid.uuid4()),str(uuid.uuid4())]
        with self.assertRaisesRegex(AssertionError,'dispatch claim required'):
            self.cmd('bind',{**token,'run_id':'unclaimed'})
        self.assertEqual(self.cmd('admission_snapshot',{'request_id':token['owner']})['dispatch'],{'status':'never_attempted','attempt_id':None})
        with concurrent.futures.ThreadPoolExecutor(2) as ex:
            results=list(ex.map(lambda attempt:self.cmd('claim_dispatch',{**token,'attempt_id':attempt}),attempts))
        self.assertEqual(sum(r['claimed'] for r in results),1)
        winner=next(r for r in results if r['claimed'])
        self.assertTrue(all(r['attempt_id']==winner['attempt_id'] for r in results))
        # Treat a lost winning claim response as ambiguous; replay never grants start.
        retry=self.cmd('claim_dispatch',{**token,'attempt_id':winner['attempt_id']})
        self.assertFalse(retry['claimed']);self.assertEqual(retry['receipt'],winner['receipt'])
        self.assertEqual(self.cmd('admission_snapshot',{'request_id':token['owner']})['dispatch'],{'status':'claimed','attempt_id':winner['attempt_id']})
        self.assertEqual(self.cmd('state',{})['phase'],'pending')
        with self.assertRaisesRegex(AssertionError,'dispatch claim required'):
            self.cmd('bind',{**token,'run_id':'wrong-attempt','attempt_id':str(uuid.uuid4())})
        with self.assertRaisesRegex(AssertionError,'release proof'):
            self.cmd('release',{**token,'reason':'timeout'})
        # The provider can bind before its start response reaches the dispatch caller.
        self.cmd('bind',{**token,'run_id':'original-run','attempt_id':winner['attempt_id']})
        self.assertFalse(self.cmd('claim_dispatch',{**token,'attempt_id':str(uuid.uuid4())})['claimed'])
        original={**token,'run_id':'original-run'};self.write(original);self.release(original)
        new=self.bind(self.admit(1),'new-run')
        replay=self.cmd('claim_dispatch',{**token,'attempt_id':winner['attempt_id']})
        self.assertFalse(replay['claimed']);self.assertTrue(replay['receipt']['closed'])
        self.assertEqual(replay['receipt']['bound_run_id'],'original-run')
        self.assertEqual(self.cmd('state',{})['run_id'],'new-run')
        self.assertFalse(self.release(original)['released'])

    def test_dispatch_claim_rollback_scope_and_closed_never_attempted(self):
        token=self.admit();attempt=str(uuid.uuid4());payload={**token,'attempt_id':attempt}
        self.sql('BEGIN; '+self.command_sql('claim_dispatch',payload)+' ROLLBACK;')
        self.assertEqual(self.cmd('admission_snapshot',{'request_id':token['owner']})['dispatch']['status'],'never_attempted')
        with self.assertRaisesRegex(AssertionError,'ownership denied'):self.cmd('claim_dispatch',payload,account=OTHER)
        with self.assertRaisesRegex(AssertionError,'stale dispatch authority'):self.cmd('claim_dispatch',{**payload,'epoch':0})
        with self.assertRaisesRegex(AssertionError,'missing dispatch identity'):self.cmd('claim_dispatch',token)
        for role in ['anon','authenticated']:
            with self.assertRaisesRegex(AssertionError,'permission denied'):
                self.sql(self.command_sql('claim_dispatch',payload).replace('SET ROLE service_role',f'SET ROLE {role}'))
        with self.assertRaisesRegex(AssertionError,'permission denied'):
            self.sql("SET ROLE service_role; UPDATE chat_fence.turns SET dispatch_attempt_id=NULL")
        self.assertTrue(self.cmd('close_unattempted',token)['closed'])
        result=self.cmd('claim_dispatch',payload)
        self.assertFalse(result['claimed']);self.assertIsNone(result['attempt_id']);self.assertTrue(result['receipt']['closed'])
        new=self.admit(1);claim=self.cmd('claim_dispatch',{**new,'attempt_id':str(uuid.uuid4())})
        self.assertTrue(claim['claimed'])
        # Even authoritative no-start closure does not reset or reclaim that intent.
        self.cmd('release',{**new,'reason':'confirmed_no_start'})
        self.assertFalse(self.cmd('claim_dispatch',{**new,'attempt_id':claim['attempt_id']})['claimed'])

    def test_snapshot_tampering_scope_and_original_closed_retrieval(self):
        import copy
        key=str(uuid.uuid4());payload=self.snapshot_payload({'request_id':key,'expected_epoch':0})
        def rehash(value):
            value['execution_canonical']=json.dumps(value['execution_snapshot'],sort_keys=True,separators=(',',':'))
            value['admission_envelope']['executionSnapshot']['digest']=hashlib.sha256(value['execution_canonical'].encode()).hexdigest()
            value['admission_canonical']=json.dumps(value['admission_envelope'],sort_keys=True,separators=(',',':'))
            value['input_hash']=hashlib.sha256(value['admission_canonical'].encode()).hexdigest()
            return value
        for field in ['input_hash','admission_canonical','execution_canonical']:
            bad=copy.deepcopy(payload)
            bad[field]='f'*64 if field=='input_hash' else '{}'
            with self.assertRaisesRegex(AssertionError,'bytes or digest mismatch'):self.cmd('admit',bad)
        bad=copy.deepcopy(payload);bad['execution_snapshot']['content']['modelId']='tampered'
        with self.assertRaisesRegex(AssertionError,'bytes or digest mismatch'):self.cmd('admit',bad)
        for field,value in [('effectiveAccountId',OTHER),('chatId','another-chat'),('sessionId','another-session'),('requestId',str(uuid.uuid4())),('contractVersion','chat-execution/v2'),('id','rebound-id')]:
            bad=copy.deepcopy(payload);bad['execution_snapshot'][field]=value
            with self.assertRaisesRegex(AssertionError,'scope or version mismatch'):self.cmd('admit',rehash(bad))
        receipt=self.cmd('admit',payload)
        # SQL binds supplied bytes; it does not claim ECMAScript canonicalization.
        alternate=copy.deepcopy(payload)
        alternate['admission_canonical']=json.dumps(alternate['admission_envelope'],indent=2)
        alternate['input_hash']=hashlib.sha256(alternate['admission_canonical'].encode()).hexdigest()
        with self.assertRaisesRegex(AssertionError,'retry input conflict'):self.cmd('admit',alternate)
        stored=self.cmd('admission_snapshot',{'request_id':key})
        self.assertEqual(stored['receipt'],receipt)
        for field in ['admission_envelope','execution_snapshot','admission_canonical','execution_canonical']:self.assertEqual(stored[field],payload[field])
        bad=copy.deepcopy(payload);bad['execution_snapshot']['content']['modelId']='rebound-content'
        with self.assertRaisesRegex(AssertionError,'retry input conflict'):self.cmd('admit',rehash(bad))
        with self.assertRaisesRegex(AssertionError,'ownership denied'):self.cmd('admission_snapshot',{'request_id':key},account=OTHER)
        with self.assertRaisesRegex(AssertionError,'snapshot missing'):self.cmd('admission_snapshot',{'request_id':str(uuid.uuid4())})
        with self.assertRaisesRegex(AssertionError,'permission denied'):self.sql("SET ROLE service_role; UPDATE chat_fence.turns SET execution_snapshot='{}'")
        token=self.bind({'owner':key,'epoch':receipt['epoch']},'original-snapshot-run');self.release(token)
        self.bind(self.admit(1),'new-owner-run')
        closed=self.cmd('admission_snapshot',{'request_id':key})
        self.assertTrue(closed['receipt']['closed']);self.assertEqual(closed['receipt']['bound_run_id'],'original-snapshot-run')
        for field in ['admission_envelope','execution_snapshot','admission_canonical','execution_canonical']:self.assertEqual(closed[field],stored[field])
        self.assertEqual(self.cmd('state',{})['run_id'],'new-owner-run')

    def test_snapshot_concurrent_retry_atomic_rollback_and_cross_chat_lookup(self):
        key=str(uuid.uuid4());payload=self.snapshot_payload({'request_id':key,'expected_epoch':0})
        self.sql('BEGIN; '+self.command_sql('admit',payload)+' ROLLBACK;')
        with self.assertRaisesRegex(AssertionError,'snapshot missing'):self.cmd('admission_snapshot',{'request_id':key})
        self.assertEqual(self.cmd('state',{})['epoch'],0)
        with concurrent.futures.ThreadPoolExecutor(2) as ex:
            results=list(ex.map(lambda _:self.cmd('admit',payload),range(2)))
        self.assertEqual(results[0],results[1]);self.assertEqual(self.cmd('state',{})['epoch'],1)
        self.assertEqual(self.cmd('admission_snapshot',{'request_id':key})['receipt'],results[0])
        changed=self.snapshot_payload({'request_id':key,'expected_epoch':0,'input_hash':'b'*64})
        def replay(candidate):
            try:return self.cmd('admit',candidate)
            except AssertionError as error:
                self.assertIn('retry input conflict',str(error));return None
        with concurrent.futures.ThreadPoolExecutor(2) as ex:
            replayed=list(ex.map(replay,[payload,changed]))
        self.assertEqual(replayed,[results[0],None])
        self.assertEqual(self.cmd('admission_snapshot',{'request_id':key})['admission_envelope'],payload['admission_envelope'])
        other='other-snapshot-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES('{other}','{ACCOUNT}','synthetic'); INSERT INTO chats(id,session_id,title) VALUES('{other}','{other}','synthetic'); SELECT enable_chat_fence('{other}','{ACCOUNT}')")
        with self.assertRaisesRegex(AssertionError,'snapshot missing'):self.cmd('admission_snapshot',{'request_id':key},chat=other)
        for role in ['anon','authenticated']:
            with self.assertRaisesRegex(AssertionError,'permission denied'):
                self.sql(self.command_sql('admission_snapshot',{'request_id':key}).replace('SET ROLE service_role',f'SET ROLE {role}'))

    def test_original_closed_run_receipt_write_outcomes_and_self_completion(self):
        key=str(uuid.uuid4());token=self.bind(self.admit(key=key),'original-run')
        payload={'request_id':key,'expected_epoch':0,'input_hash':'a'*64}
        self.assertEqual(self.cmd('admit',payload)['bound_run_id'],'original-run')
        self.assertEqual(self.write(token)['outcome'],'inserted')
        self.assertEqual(self.write(token)['outcome'],'exactDuplicate')
        self.assertEqual(self.write(token,parts=[{'type':'text','text':'changed'}])['outcome'],'updated')
        self.assertEqual(self.write(token,'user',role='user',mode='insert')['outcome'],'inserted')
        self.assertEqual(self.write(token,'user',role='user',mode='insert')['outcome'],'exactDuplicate')
        with self.assertRaisesRegex(AssertionError,'duplicate input conflict'):
            self.write(token,'user',role='user',mode='insert',parts=[{'type':'text','text':'different'}])
        for reason in ('terminal','timeout','confirmed_no_start'):
            with self.assertRaisesRegex(AssertionError,'release proof'):
                self.cmd('release',{**token,'reason':reason})
        with self.assertRaisesRegex(AssertionError,'release proof'):
            self.cmd('release',{**token,'run_id':'loser','reason':'workflow_complete'})
        self.assertTrue(self.cmd('release',{**token,'reason':'workflow_complete'})['released'])
        with self.assertRaisesRegex(AssertionError,'stale writer'):self.write(token)
        new=self.bind(self.admit(1),'new-run')
        closed=self.cmd('admit',payload)
        self.assertTrue(closed['closed'])
        self.assertEqual(closed['bound_run_id'],'original-run')
        self.assertEqual(self.cmd('state',{})['run_id'],'new-run')
        self.assertFalse(self.cmd('release',{**token,'reason':'workflow_complete'})['released'])
        self.assertEqual(self.write(new,'user',role='user',mode='insert')['outcome'],'exactDuplicate')
        self.assertEqual(self.cmd('admit',payload),closed)

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
        self.assertFalse(self.cmd('release',{**token,'epoch':0,'reason':'external_terminal','run_id':'first-run'})['released'])
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
        self.assertTrue(self.cmd('close_unattempted',token)['closed'])
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
