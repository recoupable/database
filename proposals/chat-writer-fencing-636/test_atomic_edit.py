"""Atomic edit proposal only; real socket PostgreSQL, synthetic authority, no providers."""
import copy
import concurrent.futures
import hashlib
import json
import subprocess
import time
import unittest
import uuid
from pathlib import Path
from test_protocol import Protocol, ACCOUNT, OTHER, quote


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(value.encode('utf8')).hexdigest()


class AtomicEdit(Protocol):
    def setUp(self):
        super().setUp()
        self.history = [
            {'id':self.chat+'-a','role':'user','parts':[{'type':'text','text':'prefix'}]},
            {'id':self.chat+'-b','role':'user','parts':[{'type':'text','text':'original'}]},
            {'id':self.chat+'-c','role':'assistant','parts':[{'type':'text','text':'suffix'}]},
        ]
        # Trusted fixture owner only; normal legacy writers are fenced.
        for m in self.history:
            self.sql(f"SET ROLE recoup_chat_fence_owner; INSERT INTO chat_messages(id,chat_id,role,parts,created_at) VALUES({quote(m['id'])},{quote(self.chat)},{quote(m['role'])},{quote(canonical(m))},'2026-01-01T00:00:00Z')")
        self.payload = self.capture()

    def capture(self, expected=0):
        key, admission_id = str(uuid.uuid4()), str(uuid.uuid4())
        edited = {**self.history[1], 'parts':[{'type':'text','text':'edited 🎵'}]}
        options = {'modelId':'synthetic','artistId':None,'interactive':True,'devSurface':None}
        snapshot = {'contractVersion':'chat-execution/v1','id':'snapshot-'+admission_id,
                    'requestId':admission_id,'effectiveAccountId':ACCOUNT,'chatId':self.chat,
                    'sessionId':self.chat,'content':{'options':options,'credentialPolicy':{'kind':'synthetic'}}}
        envelope = {'contractVersion':'chat-admission/v1','effectiveAccountId':ACCOUNT,
                    'chatId':self.chat,'sessionId':self.chat,'expectedEpoch':expected+1,
                    'messages':[self.history[0],{**edited,'id':'replacement-'+admission_id}],
                    'options':options,'executionSnapshot':{'id':snapshot['id'],'digest':digest(canonical(snapshot))}}
        admission = {'request_id':admission_id,'expected_epoch':expected+1,'input_hash':digest(canonical(envelope)),
                     'admission_envelope':envelope,'execution_snapshot':snapshot,
                     'admission_canonical':canonical(envelope),'execution_canonical':canonical(snapshot)}
        material = {'capture':{'deletion':{'chatId':self.chat,'effectiveAccount':ACCOUNT,
                    'requestId':key,'expectedEpoch':expected,'anchorId':self.history[1]['id']},
                    'turn':{'kind':'new'},'admission':{'action':'admit','payload':admission}},
                    'user_intent_canonical':canonical({'anchor_id':self.history[1]['id'],
                    'edited_user_message':edited,'requested_options':{}}),
                    'history_witness':[{'id':m['id'],'role':m['role'],'message':m} for m in self.history]}
        return {'request_id':key,'expected_epoch':expected,'anchor_id':self.history[1]['id'],'edit_material':material}

    def admission(self, p=None):
        return (p or self.payload)['edit_material']['capture']['admission']['payload']

    def recanonicalize(self,p):
        a=self.admission(p)
        a['execution_canonical']=canonical(a['execution_snapshot'])
        a['admission_envelope']['executionSnapshot']['digest']=digest(a['execution_canonical'])
        a['admission_canonical']=canonical(a['admission_envelope'])
        a['input_hash']=digest(a['admission_canonical'])

    def inventory(self):
        return self.sql(f"SELECT jsonb_build_object('messages',(SELECT jsonb_agg(to_jsonb(m) ORDER BY created_at,id) FROM chat_messages m WHERE chat_id={quote(self.chat)}),'state',(SELECT to_jsonb(s) FROM chat_fence.state s WHERE chat_id={quote(self.chat)}),'tombstones',(SELECT jsonb_agg(to_jsonb(t)) FROM chat_fence.tombstones t WHERE chat_id={quote(self.chat)}),'deletions',(SELECT jsonb_agg(to_jsonb(d)) FROM chat_fence.deletions d WHERE chat_id={quote(self.chat)}),'turns',(SELECT jsonb_agg(to_jsonb(t)) FROM chat_fence.turns t WHERE chat_id={quote(self.chat)}))")

    def rejected(self,p,action='delete_edit',error=None,**kw):
        before=self.inventory()
        with self.assertRaises(AssertionError) as failure:self.cmd(action,p,**kw)
        if error:self.assertIn(error,str(failure.exception))
        self.assertEqual(self.inventory(),before)

    def test_atomic_save_recovery_and_explicit_admission(self):
        before=self.inventory()
        self.sql('BEGIN; '+self.command_sql('delete_edit',self.payload)+' ROLLBACK;')
        self.assertEqual(before,self.inventory())
        receipt=self.cmd('delete_edit',self.payload)
        self.assertEqual(receipt,{'request_id':self.payload['request_id'],'epoch':1,'deleted':2})
        saved=self.cmd('deletion_snapshot',{'request_id':self.payload['request_id']})
        self.assertEqual(saved,{'receipt':receipt,'edit_material':self.payload['edit_material']})
        state=self.cmd('state',{});self.assertEqual(state['phase'],'idle');self.assertEqual(state['epoch'],1)
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_fence.turns WHERE chat_id={quote(self.chat)}"),'0')
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_messages WHERE chat_id={quote(self.chat)}"),'1')
        self.assertEqual(self.cmd('delete_edit',self.payload),receipt)
        turn=self.cmd('admit',self.admission());self.assertEqual(turn['epoch'],2)
        self.assertEqual(self.cmd('admit',self.admission()),turn)
        self.cmd('close_unattempted',{'owner':turn['request_id'],'epoch':2})
        newer=self.admit(2)
        closed=self.cmd('admit',self.admission());self.assertTrue(closed['closed']);self.assertEqual(closed['epoch'],turn['epoch'])
        self.assertEqual(self.cmd('delete_edit',self.payload),receipt)
        self.assertEqual(self.cmd('state',{})['owner'],newer['owner'])

    def test_failure_after_delete_rolls_back_everything(self):
        self.sql("CREATE FUNCTION public.atomic_edit_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic after-delete fault'; END $$; CREATE TRIGGER atomic_edit_fault BEFORE INSERT ON chat_fence.deletions FOR EACH ROW EXECUTE FUNCTION public.atomic_edit_fault()")
        try:self.rejected(self.payload)
        finally:self.sql('DROP TRIGGER atomic_edit_fault ON chat_fence.deletions; DROP FUNCTION public.atomic_edit_fault()')

    def test_mode_compatibility_and_newer_owner(self):
        old={k:v for k,v in self.payload.items() if k!='edit_material'}
        old['previously_tolerated']=True
        receipt=self.cmd('delete',old)
        self.assertEqual(self.cmd('deletion_snapshot',{'request_id':old['request_id']})['edit_material'],None)
        self.rejected(self.payload)
        self.admit(1)
        self.assertEqual(self.cmd('delete',old),receipt)

    def test_edit_mode_cannot_downgrade_and_new_owner_blocks_continuation(self):
        self.cmd('delete_edit',self.payload)
        self.rejected({k:v for k,v in self.payload.items() if k!='edit_material'},action='delete')
        newer=self.admit(1)
        self.rejected(self.admission(),action='admit')
        self.assertEqual(self.cmd('state',{})['owner'],newer['owner'])

    def test_scope_snapshot_and_permissions(self):
        self.cmd('delete_edit',self.payload)
        for action,p in [('deletion_snapshot',{'request_id':self.payload['request_id']}),('delete_edit',self.payload)]:
            self.rejected(p,action=action,account=OTHER)
            for role in ('anon','authenticated'):
                with self.assertRaises(AssertionError):self.sql(self.command_sql(action,p).replace('SET ROLE service_role',f'SET ROLE {role}'))
        self.rejected({'request_id':str(uuid.uuid4())},action='deletion_snapshot')
        self.rejected({'request_id':self.payload['request_id'],'extra':True},action='deletion_snapshot')
        with self.assertRaises(AssertionError):self.sql('SET ROLE service_role; SELECT edit_material FROM chat_fence.deletions')
        self.sql(f"ALTER TABLE sessions DISABLE TRIGGER chat_fence_session; UPDATE sessions SET account_id='{OTHER}' WHERE id={quote(self.chat)}; ALTER TABLE sessions ENABLE TRIGGER chat_fence_session")
        self.rejected({'request_id':self.payload['request_id']},action='deletion_snapshot')

    def test_changed_material_replay_conflicts(self):
        self.cmd('delete_edit',self.payload)
        candidates=[]
        for field,value in [('anchor_id','changed'),('expected_epoch',1)]:
            p=copy.deepcopy(self.payload);p[field]=value;candidates.append(p)
        p=copy.deepcopy(self.payload);p['edit_material']['history_witness'][0]['message']['parts']=[];candidates.append(p)
        p=self.capture();p['request_id']=self.payload['request_id'];p['edit_material']['capture']['deletion']['requestId']=p['request_id'];candidates.append(p)
        p=copy.deepcopy(self.payload);self.admission(p)['admission_canonical']+=' ';self.admission(p)['input_hash']=digest(self.admission(p)['admission_canonical']);candidates.append(p)
        for p in candidates:
            with self.subTest(p=p['anchor_id']):self.rejected(p)

    def test_validation_and_canonical_binding_fail_before_delete(self):
        candidates=[]
        for field,value in [('expected_epoch','0'),('edit_material',None),('extra',1)]:
            p=copy.deepcopy(self.payload);p[field]=value;candidates.append(p)
        for field,value in [('input_hash','0'*64),('admission_canonical','{}'),('execution_canonical','{}')]:
            p=copy.deepcopy(self.payload);self.admission(p)[field]=value;candidates.append(p)
        for field,value in [('chatId','foreign'),('sessionId','foreign'),('effectiveAccountId',OTHER),('contractVersion','v2'),('expectedEpoch',9)]:
            p=copy.deepcopy(self.payload);self.admission(p)['admission_envelope'][field]=value;self.recanonicalize(p);candidates.append(p)
        p=copy.deepcopy(self.payload);self.admission(p)['execution_snapshot']['requestId']=str(uuid.uuid4());self.recanonicalize(p);candidates.append(p)
        p=copy.deepcopy(self.payload);self.admission(p)['admission_envelope']['options']=dict(self.admission(p)['admission_envelope']['options'],interactive=False);self.recanonicalize(p);candidates.append(p)
        for p in candidates:self.rejected(p)

    def test_history_changes_and_replacement_collisions(self):
        for index in range(3):
            m=self.history[index]
            self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET parts=jsonb_set(parts,'{{parts}}','[]') WHERE id={quote(m['id'])}")
            self.rejected(self.payload)
            self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET parts={quote(canonical(m))} WHERE id={quote(m['id'])}")
        for m in self.history:
            p=copy.deepcopy(self.payload);self.admission(p)['admission_envelope']['messages'][-1]['id']=m['id'];self.recanonicalize(p);self.rejected(p)
        replacement=self.admission()['admission_envelope']['messages'][-1]['id']
        self.sql(f"INSERT INTO chat_fence.tombstones(message_id,chat_id,deleted_epoch) VALUES({quote(replacement)},{quote(self.chat)},1)")
        self.rejected(self.payload)

    def test_caps_depth_counts_and_epoch_capacity(self):
        for field in ('user_intent_canonical','history_witness'):
            p=copy.deepcopy(self.payload)
            p['edit_material'][field]='x'*(1024*1024+1) if field=='user_intent_canonical' else [p['edit_material']['history_witness'][0]]*1001
            self.rejected(p)
        for field in ('admission_canonical','execution_canonical'):
            p=copy.deepcopy(self.payload);self.admission(p)[field]=' '*(1024*1024+1);self.rejected(p)
        p=copy.deepcopy(self.payload);nested={}
        for _ in range(102):nested={'nested':nested}
        p['edit_material']['capture']['extra']=nested;self.rejected(p)
        p=self.capture(9007199254740990)
        self.sql(f"UPDATE chat_fence.state SET epoch=9007199254740990 WHERE chat_id={quote(self.chat)}")
        self.rejected(p)
        self.sql(f"UPDATE chat_fence.state SET epoch=9007199254740989 WHERE chat_id={quote(self.chat)}")
        p=self.capture(9007199254740989)
        self.assertEqual(self.cmd('delete_edit',p)['epoch'],9007199254740990)
        self.assertEqual(self.cmd('admit',self.admission(p))['epoch'],9007199254740991)

    def held_race(self,first_sql,second):
        process=subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
        try:
            process.stdin.write('BEGIN; '+first_sql+" SELECT 'LOCKED';\n");process.stdin.flush()
            while process.stdout.readline().strip()!='LOCKED':
                if process.poll() is not None:self.fail('held transaction failed: '+process.stderr.read())
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                future=pool.submit(second);deadline=time.monotonic()+5
                while int(self.sql(f"SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%{self.chat}%' AND pid<>pg_backend_pid()"))<1:
                    if time.monotonic()>deadline:self.fail('second connection never reached lock barrier')
                    time.sleep(.02)
                self.assertFalse(future.done());process.stdin.write('COMMIT;\n');process.stdin.flush()
                return future.result(timeout=5)
        finally:
            if process.poll() is None:
                process.stdin.close();process.wait(timeout=5)
            process.stdout.close();process.stderr.close()

    def test_two_connection_exact_duplicate_and_changed_candidate(self):
        receipt=self.held_race(self.command_sql('delete_edit',self.payload),lambda:self.cmd('delete_edit',self.payload))
        self.assertEqual(receipt['deleted'],2)
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_fence.deletions WHERE chat_id={quote(self.chat)}"),'1')
        loser=self.capture();loser['request_id']=self.payload['request_id'];loser['edit_material']['capture']['deletion']['requestId']=loser['request_id']
        self.rejected(loser)
        self.assertEqual(self.cmd('deletion_snapshot',{'request_id':self.payload['request_id']})['edit_material'],self.payload['edit_material'])

    def test_two_connection_history_changed_before_delete(self):
        sql=f"SET ROLE recoup_chat_fence_owner; SELECT 1 FROM chats WHERE id={quote(self.chat)} FOR UPDATE; UPDATE chat_messages SET parts=jsonb_set(parts,'{{parts}}','[]') WHERE id={quote(self.history[2]['id'])};"
        with self.assertRaises(AssertionError):self.held_race(sql,lambda:self.cmd('delete_edit',self.payload))
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_messages WHERE chat_id={quote(self.chat)}"),'3')
        self.assertEqual(self.cmd('state',{})['epoch'],0)

    def test_actual_api1169_vector_roundtrip(self):
        material=json.loads((Path(__file__).parent/'atomic-edit-vector.json').read_text())
        capture=material['capture'];chat=capture['deletion']['chatId']
        session=capture['admission']['payload']['execution_snapshot']['sessionId']
        self.sql(f"INSERT INTO sessions(id,account_id,title) VALUES({quote(session)},'{ACCOUNT}','API vector'); INSERT INTO chats(id,session_id,title) VALUES({quote(chat)},{quote(session)},'API vector')")
        for i,item in enumerate(material['history_witness']):
            self.sql(f"INSERT INTO chat_messages(id,chat_id,role,parts,created_at) VALUES({quote(item['id'])},{quote(chat)},{quote(item['role'])},{quote(canonical(item['message']))},'2026-01-01'::timestamptz+{i}*interval '1 second')")
        self.sql(f"SELECT enable_chat_fence({quote(chat)},'{ACCOUNT}')")
        p={'request_id':capture['deletion']['requestId'],'expected_epoch':0,'anchor_id':capture['deletion']['anchorId'],'edit_material':material}
        receipt=self.cmd('delete_edit',p,chat=chat)
        self.assertEqual(receipt['deleted'],2)
        saved=self.cmd('deletion_snapshot',{'request_id':p['request_id']},chat=chat)
        self.assertEqual(saved['edit_material'],material)
        self.assertEqual(saved['receipt'],receipt)
        self.assertEqual(self.cmd('state',{},chat=chat)['phase'],'idle')
        admitted=self.cmd('admit',capture['admission']['payload'],chat=chat)
        self.assertEqual(admitted['epoch'],2)

    def test_disconnect_before_commit_and_lost_response_after_commit(self):
        before=self.inventory()
        process=subprocess.Popen(self.args(),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        process.stdin.write('BEGIN; '+self.command_sql('delete_edit',self.payload)+" SELECT 'READY';\n");process.stdin.flush()
        while process.stdout.readline().strip()!='READY':
            if process.poll() is not None:self.fail(process.stderr.read())
        # Killing the client closes its database session with the transaction uncommitted.
        process.kill();process.wait();process.stdin.close();process.stdout.close();process.stderr.close()
        deadline=time.monotonic()+5
        while self.inventory()!=before:
            if time.monotonic()>deadline:self.fail('disconnected transaction did not roll back')
        result=subprocess.run(self.args(),input=self.command_sql('delete_edit',self.payload),text=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        self.assertEqual(result.returncode,0,result.stderr)
        recovered=self.cmd('deletion_snapshot',{'request_id':self.payload['request_id']})
        self.assertEqual(recovered['edit_material'],self.payload['edit_material'])
        self.assertEqual(recovered['receipt']['deleted'],2)
        self.assertEqual(self.cmd('state',{})['phase'],'idle')

    def test_two_connection_different_candidates_preserve_winner(self):
        loser=self.capture();loser['request_id']=self.payload['request_id'];loser['edit_material']['capture']['deletion']['requestId']=loser['request_id']
        with self.assertRaises(AssertionError):
            self.held_race(self.command_sql('delete_edit',self.payload),lambda:self.cmd('delete_edit',loser))
        saved=self.cmd('deletion_snapshot',{'request_id':self.payload['request_id']})
        self.assertEqual(saved['edit_material'],self.payload['edit_material'])
        self.assertEqual(loser['edit_material']['user_intent_canonical'],saved['edit_material']['user_intent_canonical'])
        self.assertEqual(self.sql(f"SELECT count(*) FROM chat_fence.deletions WHERE chat_id={quote(self.chat)}"),'1')

    def test_pending_running_and_slot_fail_without_mutation(self):
        token=self.admit(0)
        self.rejected(self.payload)
        running=self.bind(token)
        self.rejected(self.payload)
        self.release(running)
        p=self.capture(1)
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chats SET active_stream_id='legacy' WHERE id={quote(self.chat)}")
        self.rejected(p)

    def test_missing_added_reordered_history_and_foreign_snapshot(self):
        # Fixture-only edits through the owner imitate a capture made before changes.
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET created_at='2025-01-01' WHERE id={quote(self.history[2]['id'])}")
        self.rejected(self.payload)
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET created_at='2026-01-01' WHERE id={quote(self.history[2]['id'])}")
        self.sql(f"SET ROLE recoup_chat_fence_owner; DELETE FROM chat_messages WHERE id={quote(self.history[2]['id'])}")
        self.rejected(self.payload)
        foreign='other-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO chats(id,session_id,title) VALUES({quote(foreign)},{quote(self.chat)},'foreign'); SELECT enable_chat_fence({quote(foreign)},'{ACCOUNT}')")
        self.rejected({'request_id':self.payload['request_id']},action='deletion_snapshot',chat=foreign)

    def test_native_types_nulls_unknown_keys_and_jsonb_transport(self):
        candidates=[]
        paths=[('capture','deletion','chatId'),('capture','deletion','expectedEpoch'),('capture','turn','kind')]
        for path in paths:
            p=copy.deepcopy(self.payload);node=p['edit_material']
            for key in path[:-1]:node=node[key]
            node[path[-1]]=None;candidates.append(p)
        for target in ('capture','history_witness'):
            p=copy.deepcopy(self.payload);p['edit_material'][target]={};candidates.append(p)
        p=copy.deepcopy(self.payload);p['request_id']=p['request_id'].upper();candidates.append(p)
        p=copy.deepcopy(self.payload);self.admission(p)['execution_snapshot']['content']['x']=9007199254740992;self.recanonicalize(p);candidates.append(p)
        p=copy.deepcopy(self.payload);self.admission(p)['execution_snapshot']['content']['__proto__']={};self.recanonicalize(p);candidates.append(p)
        for p in candidates:self.rejected(p)
        for invalid in ('\\u0000','\\ud800'):
            with self.assertRaises(AssertionError):self.sql("SELECT '{\"bad\":\""+invalid+"\"}'::jsonb")

    def test_exact_execution_canonical_byte_cap(self):
        p=copy.deepcopy(self.payload);a=self.admission(p)
        a['execution_snapshot']['content']['sessionTitle']=''
        self.recanonicalize(p)
        a['execution_snapshot']['content']['sessionTitle']='x'*(1048576-len(a['execution_canonical'].encode()))
        self.recanonicalize(p);self.assertEqual(len(a['execution_canonical'].encode()),1048576)
        too=copy.deepcopy(p);self.admission(too)['execution_snapshot']['content']['sessionTitle']+='x';self.recanonicalize(too)
        self.rejected(too)
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_exact_id_byte_cap(self):
        p=copy.deepcopy(self.payload);self.admission(p)['admission_envelope']['messages'][-1]['id']='é'*256;self.recanonicalize(p)
        too=copy.deepcopy(p);self.admission(too)['admission_envelope']['messages'][-1]['id']+='x';self.recanonicalize(too)
        self.rejected(too)
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_stored_history_limit_without_unbounded_witness(self):
        self.sql(f"SET ROLE recoup_chat_fence_owner; INSERT INTO chat_messages(id,chat_id,role,parts) SELECT {quote(self.chat)}||'-extra-'||n,{quote(self.chat)},'user',jsonb_build_object('id',{quote(self.chat)}||'-extra-'||n,'role','user','parts','[]'::jsonb) FROM generate_series(1,998) n")
        self.rejected(self.payload)

    def test_exact_parts_count_cap(self):
        self.history[-1]['parts']=[{'type':'text'}]*9997
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET parts={quote(canonical(self.history[-1]))} WHERE id={quote(self.history[-1]['id'])}")
        p=self.capture()
        too=copy.deepcopy(p);too['edit_material']['history_witness'][-1]['message']['parts'].append({'type':'text'})
        self.rejected(too)
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_exact_depth_boundary_with_valid_shape(self):
        def depth(v):
            if isinstance(v,dict):return 1+max((depth(x) for x in v.values()),default=-1)
            if isinstance(v,list):return 1+max((depth(x) for x in v),default=-1)
            return 0
        p=copy.deepcopy(self.payload);a=self.admission(p)
        a['execution_snapshot']['content']['nesting']='leaf'
        while depth(p['edit_material'])<100:
            a['execution_snapshot']['content']['nesting']={'x':a['execution_snapshot']['content']['nesting']}
        self.recanonicalize(p);self.assertEqual(depth(p['edit_material']),100)
        too=copy.deepcopy(p);b=self.admission(too);b['execution_snapshot']['content']['nesting']={'x':b['execution_snapshot']['content']['nesting']};self.recanonicalize(too)
        self.rejected(too,error='unsupported edit JSON')
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_exact_admission_canonical_byte_boundary(self):
        p=copy.deepcopy(self.payload);a=self.admission(p)
        intent=json.loads(p['edit_material']['user_intent_canonical'])
        a['admission_envelope']['messages'][-1]['parts'][0]['text']=''
        self.recanonicalize(p)
        text='x'*(1048576-len(a['admission_canonical'].encode()))
        a['admission_envelope']['messages'][-1]['parts'][0]['text']=text
        intent['edited_user_message']['parts'][0]['text']=text
        p['edit_material']['user_intent_canonical']=canonical(intent);self.recanonicalize(p)
        self.assertEqual(len(a['admission_canonical'].encode()),1048576)
        too=copy.deepcopy(p);self.admission(too)['admission_canonical']+=' '
        self.rejected(too,error='invalid or oversized edit material')
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_intent_byte_boundary_precedes_parse(self):
        p=copy.deepcopy(self.payload)
        # Whitespace is valid JSON but deliberately not API canonical. SQL only bounds
        # and parses it; canonicality remains the trusted API's documented obligation.
        text=p['edit_material']['user_intent_canonical']
        p['edit_material']['user_intent_canonical']=text+' '*(1048576-len(text.encode()))
        self.assertEqual(len(p['edit_material']['user_intent_canonical'].encode()),1048576)
        too=copy.deepcopy(p);too['edit_material']['user_intent_canonical']+=' '
        self.rejected(too,error='invalid or oversized edit material')
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_exact_history_witness_byte_boundary(self):
        p=copy.deepcopy(self.payload);w=p['edit_material']['history_witness']
        w[-1]['message']['parts'][0]['text']=''
        size=int(self.sql(f"SELECT octet_length({quote(canonical(w))}::jsonb::text)"))
        w[-1]['message']['parts'][0]['text']='x'*(4194304-size)
        self.assertEqual(int(self.sql(f"SELECT octet_length({quote(canonical(w))}::jsonb::text)")),4194304)
        too=copy.deepcopy(p);too['edit_material']['history_witness'][-1]['message']['parts'][0]['text']+='x'
        self.rejected(too,error='invalid or oversized edit material')
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET parts={quote(canonical(w[-1]['message']))} WHERE id={quote(w[-1]['id'])}")
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_whole_material_exact_byte_boundary(self):
        p=copy.deepcopy(self.payload);a=self.admission(p)
        # Large suffix is absent from the admission, so the independent whole-record
        # cap can be tested while all individual canonical/witness caps remain valid.
        w=p['edit_material']['history_witness'];w[-1]['message']['parts'][0]['text']='x'*3000000
        a['execution_snapshot']['content']['sessionTitle']='x'*900000
        intent=json.loads(p['edit_material']['user_intent_canonical'])
        a['admission_envelope']['messages'][-1]['parts'][0]['text']='x'*900000
        intent['edited_user_message']['parts'][0]['text']='x'*900000
        p['edit_material']['user_intent_canonical']=canonical(intent);self.recanonicalize(p)
        size=int(self.sql(f"SELECT octet_length({quote(canonical(p['edit_material']))}::jsonb::text)"))
        w[-1]['message']['parts'][0]['text']+='x'*(8388608-size)
        self.assertEqual(int(self.sql(f"SELECT octet_length({quote(canonical(p['edit_material']))}::jsonb::text)")),8388608)
        too=copy.deepcopy(p);too['edit_material']['history_witness'][-1]['message']['parts'][0]['text']+='x'
        self.rejected(too,error='invalid or oversized edit material')
        self.sql(f"SET ROLE recoup_chat_fence_owner; UPDATE chat_messages SET parts={quote(canonical(w[-1]['message']))} WHERE id={quote(w[-1]['id'])}")
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],2)

    def test_exact_history_count_boundary(self):
        self.sql(f"SET ROLE recoup_chat_fence_owner; DELETE FROM chat_messages WHERE chat_id={quote(self.chat)}")
        self.history=[{'id':self.chat+'-'+str(i).zfill(4),'role':'user','parts':[]} for i in range(1000)]
        rows=','.join('('+quote(m['id'])+','+quote(self.chat)+",'user',"+quote(canonical(m))+",'2026-01-01')" for m in self.history)
        self.sql('SET ROLE recoup_chat_fence_owner; INSERT INTO chat_messages(id,chat_id,role,parts,created_at) VALUES '+rows)
        p=self.capture();too=copy.deepcopy(p);too['edit_material']['history_witness'].append(too['edit_material']['history_witness'][-1])
        self.rejected(too,error='edit message limit')
        # Last anchor produces the maximum 1,000-message admission too.
        p['anchor_id']=self.history[-1]['id'];p['edit_material']['capture']['deletion']['anchorId']=p['anchor_id']
        intent=json.loads(p['edit_material']['user_intent_canonical']);intent['anchor_id']=p['anchor_id'];intent['edited_user_message']['id']=p['anchor_id']
        p['edit_material']['user_intent_canonical']=canonical(intent)
        a=self.admission(p);a['admission_envelope']['messages']=self.history[:-1]+[a['admission_envelope']['messages'][-1]];self.recanonicalize(p)
        self.assertEqual(len(a['admission_envelope']['messages']),1000)
        self.assertEqual(self.cmd('delete_edit',p)['deleted'],1)

    def test_admission_message_count_cap(self):
        p=copy.deepcopy(self.payload);a=self.admission(p)
        a['admission_envelope']['messages']=[a['admission_envelope']['messages'][0]]*1001
        self.recanonicalize(p)
        self.rejected(p,error='edit message limit')

    def test_added_history_below_cap_is_not_silently_dropped(self):
        extra={'id':self.chat+'-d','role':'user','parts':[]}
        self.sql(f"SET ROLE recoup_chat_fence_owner; INSERT INTO chat_messages(id,chat_id,role,parts) VALUES({quote(extra['id'])},{quote(self.chat)},'user',{quote(canonical(extra))})")
        self.rejected(self.payload,error='edit history changed')

    def test_foreign_identity_and_previous_admission_collisions(self):
        foreign='foreign-'+str(uuid.uuid4())
        self.sql(f"INSERT INTO chats(id,session_id,title) VALUES({quote(foreign)},{quote(self.chat)},'foreign'); SELECT enable_chat_fence({quote(foreign)},'{ACCOUNT}')")
        replacement=self.admission()['admission_envelope']['messages'][-1]
        self.sql(f"SET ROLE recoup_chat_fence_owner; INSERT INTO chat_messages(id,chat_id,role,parts) VALUES({quote(replacement['id'])},{quote(foreign)},'user',{quote(canonical(replacement))})")
        self.rejected(self.payload,error='edited identity unavailable')
        self.sql(f"SET ROLE recoup_chat_fence_owner; DELETE FROM chat_messages WHERE id={quote(replacement['id'])}")
        self.sql(f"INSERT INTO chat_fence.tombstones(message_id,chat_id,deleted_epoch) VALUES({quote(replacement['id'])},{quote(foreign)},1)")
        self.rejected(self.payload,error='edited identity unavailable')
        # Fixture owner removes only this synthetic tombstone to isolate key reuse.
        self.sql(f"DELETE FROM chat_fence.tombstones WHERE message_id={quote(replacement['id'])}")
        key=self.admission()['request_id'];turn=self.admit(0,key)
        self.cmd('close_unattempted',turn)
        p=self.capture(1);a=self.admission(p);a['request_id']=key;a['execution_snapshot']['requestId']=key;self.recanonicalize(p)
        self.rejected(p,error='edited identity unavailable')


def load_tests(loader, tests, pattern):
    # Reuse fixture helpers only; never rerun the inherited unchanged protocol suite.
    return unittest.TestSuite(AtomicEdit(name) for name in sorted(AtomicEdit.__dict__) if name.startswith('test_'))


if __name__=='__main__':unittest.main(verbosity=2)
