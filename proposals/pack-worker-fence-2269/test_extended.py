"""Additional actual proposal checks; no hosted state."""
import concurrent.futures
import json
import unittest
import uuid
from test_contract import FencedPacks, ReleasePackJobs

class Extended(FencedPacks):
    def register(self,f,phase='image_submission_0'):
        v={'state':'submitting','model':'fixture','input_sha256':'a'*64,'charge_credits':40}
        return self.command('phase',{**f,'phase':phase,'value':v})['operation_id'],v
    def test_actual_late_receipt_survives_stale_refusal_and_conflict_races(self):
        f=self.running();op,v=self.register(f)
        self.observe(op,f,{'kind':'accepted','request_id':'original'})
        self.command('phase',{**f,'phase':'image_submission_0','value':{**v,'state':'accepted','request_id':'original'}})
        self.command('finish_asset',{**f,'status':'uncertain'});self.command('settle',f)
        j=self.command('read')['job']
        resumed=self.command('resume',{'request_id':str(uuid.uuid4()),'quote_id':j['quote']['id'],'expected_revision':1,'approved_max_usd':.006,'asset_id':f['asset_id'],'asset_attempt':1,'source_claim_id':f['claim_id'],'source_execution_id':f['execution_id'],'source_execution_version':f['execution_version']})
        newf=self.bind(resumed,'run-resume');self.claim(newf,f['asset_id'],1)
        before=self.snapshot()
        self.observe(op,f,{'kind':'completed','request_id':'original','output_sha256':'b'*64})
        self.assertNotEqual(self.command('phase',{**f,'phase':'image_submission_0','value':{**v,'state':'complete','request_id':'original','data':{'old':'result'}}},succeeds=False).returncode,0)
        self.assertEqual(before,self.snapshot())
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            rows=list(pool.map(lambda _:self.observe(op,f,{'kind':'accepted','request_id':'conflicting'}),range(6)))
        self.assertTrue(all(x['state']=='conflict' for x in rows))
        self.assertEqual(self.sql(f"SELECT count(*) FROM release_pack_provider_observations WHERE operation_id='{op}'").stdout.strip(),'3')
        self.assertEqual(self.observe(op,f,{'kind':'accepted','request_id':'third'})['state'],'conflict_unretained_capacity')
        self.assertEqual(before,self.snapshot())
    def test_owner_pages_redaction_and_privilege_denials(self):
        self.asset_kind='carousel';f=self.running();op,_=self.register(f);self.register(f,'image_submission_1')
        self.observe(op,f,{'kind':'accepted','request_id':'original'})
        for bad in [{'kind':'accepted','request_id':'original','raw':'secret'}, {'kind':'accepted','request_id':'x'*1100}]:
            self.assertNotEqual(self.observe(op,f,bad,succeeds=False).returncode,0)
        def page(actor,after='null'):
            return self.sql(f"SET ROLE service_role; SELECT read_pack_provider_observations('{actor}',null,'{self.job}',{after},1)",succeeds=False)
        first=json.loads(page(self.owner).stdout);self.assertEqual(len(first['operations']),1)
        second=json.loads(page(self.owner,"'"+first['next_cursor']+"'").stdout);self.assertIsNone(second['next_cursor'])
        self.assertNotEqual(page(str(uuid.uuid4())).returncode,0)
        self.assertNotEqual(page(self.owner,"'"+str(uuid.uuid4())+"'").returncode,0)
        for role in ['anon','authenticated','service_role']:
            self.assertNotEqual(self.sql(f'SET ROLE {role}; DELETE FROM release_pack_provider_observations',succeeds=False).returncode,0)
        self.assertEqual(self.sql("SELECT has_table_privilege('pack_receipt_port','release_pack_jobs','UPDATE'),has_table_privilege('pack_receipt_port','credits_usage','UPDATE'),has_table_privilege('pack_receipt_port','usage_events','INSERT')").stdout.strip(),'f|f|f')
    def test_unobserved_charge_and_direct_complete_refused_atomically(self):
        f=self.running();op,v=self.register(f);before=self.snapshot()
        self.assertNotEqual(self.command('phase',{**f,'phase':'image_submission_0','value':{**v,'state':'accepted','request_id':'unretained'}},succeeds=False).returncode,0)
        self.assertEqual(before,self.snapshot())
        self.assertNotEqual(self.command('finish_asset',{**f,'status':'failed'},succeeds=False).returncode,0)
        self.observe(op,f,{'kind':'accepted','request_id':'accepted'})
        self.observe(op,f,{'kind':'completed','request_id':'accepted'})
        self.assertNotEqual(self.command('phase',{**f,'phase':'image_submission_0','value':{**v,'state':'complete','request_id':'accepted','data':{}}},succeeds=False).returncode,0)
        self.assertEqual(before,self.snapshot())
        payload={**f,'phase':'image_submission_0','value':{**v,'state':'accepted','request_id':'accepted'}}
        self.command('phase',payload);before=self.snapshot();self.command('phase',payload);self.assertEqual(before,self.snapshot())
        self.assertEqual(self.sql(f"SELECT count(*) FROM usage_events WHERE account_id='{self.owner}'").stdout.strip(),'1')
    def test_legacy_job_refuses_v2_without_adoption(self):
        self.command('prepare',{'idempotency_key':self.job,'fingerprint':'a'*64,'brief':{},'deliverables':{},'status':'ready_to_quote'},legacy=True)
        before=self.snapshot();self.assertNotEqual(self.command('read',succeeds=False).returncode,0);self.assertEqual(before,self.snapshot())

    def test_claim_replay_and_concurrent_intent_grant_only_once(self):
        saved,_=self.approve_v2();f=self.bind(saved);asset=saved['assets'][0]['id']
        payload={**f,'asset_id':asset,'asset_attempt':0,'request_id':str(uuid.uuid4())}
        claimed=self.command('claim',payload);before=self.snapshot()
        replay=self.command('claim',payload)
        self.assertFalse(replay['claimed']);self.assertTrue(replay['replayed']);self.assertEqual(before,self.snapshot())
        f={**f,'asset_id':asset,'asset_attempt':1,'claim_id':claimed['asset']['claim_id']}
        payload={**f,'phase':'image_submission_0','value':{'state':'submitting','model':'fixture','input_sha256':'a'*64,'charge_credits':40}}
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            rows=list(pool.map(lambda _:self.command('phase',payload),range(6)))
        self.assertEqual(sum(r['operation_created'] for r in rows),1)
        self.assertEqual(len({r['operation_id'] for r in rows}),1)
        before=self.snapshot()
        self.assertNotEqual(self.command('phase',{**payload,'value':{**payload['value'],'input_sha256':'b'*64}},succeeds=False).returncode,0)
        self.assertEqual(before,self.snapshot())
    def test_current_expiry_refunds_once_and_missing_fences_never_trigger_it(self):
        f=self.running()
        self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")
        before=self.snapshot()
        for missing in ['execution_id','execution_version','expected_revision','workflow_run_id','claim_id','asset_attempt']:
            payload={**f,'status':'completed'};del payload[missing]
            self.assertNotEqual(self.command('finish_asset',payload,succeeds=False).returncode,0)
            self.assertEqual(before,self.snapshot())
        expired=self.command('settle',f);self.assertTrue(expired['command_expired'])
        settled=self.snapshot();self.command('read');self.command('read');self.assertEqual(settled,self.snapshot())
    def test_receipt_foreign_identity_and_invalid_page_leave_state_unchanged(self):
        f=self.running();op,_=self.register(f);before=self.snapshot()
        for identity in [{**f,'claim_id':str(uuid.uuid4())},{**f,'execution_id':str(uuid.uuid4())}]:
            self.assertNotEqual(self.observe(op,identity,{'kind':'accepted','request_id':'original'},succeeds=False).returncode,0)
        self.assertNotEqual(self.observe(op,f,{'kind':'accepted','request_id':'original'},actor=str(uuid.uuid4()),succeeds=False).returncode,0)
        for limit in ['0','101','null']:
            self.assertNotEqual(self.sql(f"SET ROLE service_role; SELECT read_pack_provider_observations('{self.owner}',null,'{self.job}',null,{limit})",succeeds=False).returncode,0)
        self.assertEqual(self.sql(f"SELECT count(*) FROM release_pack_provider_observations WHERE operation_id='{op}'").stdout.strip(),'0')
        self.assertEqual(before,self.snapshot())

class LegacyCompatibility(ReleasePackJobs):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        for name in ['schema.sql','command.sql','receipts.sql']:
            cls.sql((__import__('pathlib').Path(__file__).parent/name).read_text())

if __name__=='__main__':
    suite=unittest.TestSuite()
    for cls in [FencedPacks,Extended]:
        suite.addTests(cls(x) for x in cls.__dict__ if x.startswith('test_'))
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(LegacyCompatibility))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
