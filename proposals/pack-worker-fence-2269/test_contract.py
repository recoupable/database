"""Actual inactive proposal on disposable PostgreSQL. No hosted credentials."""
import json
import pathlib
import sys
import unittest
import uuid
import concurrent.futures
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
from test_release_pack_jobs import ReleasePackJobs

class FencedPacks(ReleasePackJobs):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        for name in ['schema.sql','command.sql','receipts.sql']:
            path=pathlib.Path(__file__).parent/name
            if path.exists(): cls.sql(path.read_text())
    def command(self, action, payload=None, actor=None, org=None, succeeds=True, legacy=False):
        data=json.dumps(payload or {}).replace("'","''")
        orgsql="'"+org+"'" if org else 'null'
        name='release_pack_command' if legacy else 'release_pack_command_v2'
        result=self.sql(f"SET ROLE service_role; SELECT {name}('{actor or self.owner}',{orgsql},'{action}','{self.job}','{data}'::jsonb)",succeeds=succeeds)
        return json.loads(result.stdout) if succeeds else result
    def setup_quote(self):
        self.prepare()
        q={'id':str(uuid.uuid4()),'revision':1,'credits':100,'maximum_usd':.01,'expires_at':'2099-01-01T00:00:00Z',
           'execution_config':{'models':{'image':'fixture','image_edit':'fixture-edit','motion':'fixture-motion'},'rates':{'image_usd_per_unit':.004,'credits_per_usd':10000}}}
        return self.command('estimate',{'expected_revision':1,'quote':q,'assets':[{'kind':getattr(self,'asset_kind','artwork'),'ordinal':0,'credits':100,'maximum_usd':.01}]})
    def approve_v2(self):
        saved=self.setup_quote();q=saved['job']['quote']
        payload={'request_id':str(uuid.uuid4()),'quote_id':q['id'],'expected_revision':1,'approved_max_usd':.01,'source_execution_id':None,'source_execution_version':0}
        funded=self.command('approve',payload)
        return funded,payload
    def bind(self,saved,run='run-1'):
        j=saved['job']; run=self.job+'-'+run; f={'expected_revision':j['revision'],'execution_id':j['execution_id'],'execution_version':j['execution_version'],'workflow_run_id':run}
        self.command('run',f)
        return f
    def claim(self,f,asset,attempt):
        return self.command('claim',{**f,'asset_id':asset,'asset_attempt':attempt,'request_id':str(uuid.uuid4())})
    def running(self):
        s,_=self.approve_v2();f=self.bind(s);asset=s['assets'][0]['id'];c=self.claim(f,asset,0)
        return {**f,'asset_id':asset,'asset_attempt':c['asset']['attempt'],'claim_id':c['asset']['claim_id']}
    def snapshot(self):
        return self.sql(f"SELECT jsonb_build_object('job',(SELECT to_jsonb(j) FROM release_pack_jobs j WHERE id='{self.job}'),'assets',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM release_pack_assets a WHERE job_id='{self.job}'),'wallet',(SELECT jsonb_agg(to_jsonb(w) ORDER BY id) FROM credits_usage w WHERE account_id='{self.owner}'),'usage',(SELECT coalesce(jsonb_agg(to_jsonb(u) ORDER BY id),'[]') FROM usage_events u WHERE account_id='{self.owner}'))").stdout.strip()
    def retry(self,old):
        self.command('finish_asset',{**old,'status':'failed','error':'confirmed failure'})
        self.command('settle',old)
        q={'id':str(uuid.uuid4()),'revision':1,'credits':100,'maximum_usd':.01,'expires_at':'2099-01-01T00:00:00Z','retry_asset_id':old['asset_id'],'execution_config':{'models':{'image':'fixture','image_edit':'fixture-edit','motion':'fixture-motion'},'rates':{'image_usd_per_unit':.004,'credits_per_usd':10000}}}
        self.command('estimate',{'expected_revision':1,'asset_attempt':1,'retry_asset_id':old['asset_id'],'quote':q})
        s=self.command('approve',{'request_id':str(uuid.uuid4()),'quote_id':q['id'],'expected_revision':1,'approved_max_usd':.01,'source_execution_id':old['execution_id'],'source_execution_version':old['execution_version']})
        f=self.bind(s,'run-2'); c=self.claim(f,old['asset_id'],1)
        return {**f,'asset_id':old['asset_id'],'asset_attempt':2,'claim_id':c['asset']['claim_id']}
    def test_stale_all_writers_and_before_expiry(self):
        old=self.running();fresh=self.retry(old)
        for expired in [False, True]:
            if expired:
                self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")
            for action,payload in [('phase',{'phase':'image_submission_0','value':{'state':'accepted','request_id':'old','charge_credits':40}}),('finish_asset',{'status':'completed','files':[{'storage_key':'old'}],'caption':'old','qa':{'passed':True}}),('context',{'context_version':0,'value':{'old':True}}),('run',{}),('settle',{}),('claim',{'request_id':str(uuid.uuid4())}),('dispatch_uncertain',{'error':'old'})]:
                before=self.snapshot();r=self.command(action,{**old,**payload},succeeds=False)
                self.assertNotEqual(r.returncode,0,action);self.assertEqual(before,self.snapshot(),action)
    def test_transition_replay_payload_conflict_and_legacy_isolation(self):
        s,p=self.approve_v2();before=self.snapshot();replayed=self.command('approve',p)
        self.assertFalse(replayed['dispatch']);self.assertEqual(before,self.snapshot())
        self.assertNotEqual(self.command('approve',{**p,'approved_max_usd':1},succeeds=False).returncode,0)
        self.assertNotEqual(self.command('read',legacy=True,succeeds=False).returncode,0)
        self.assertEqual(s['job']['protocol'],2)
    def test_claim_run_context_finish_settle_replay(self):
        s,_=self.approve_v2();f=self.bind(s);asset=s['assets'][0]['id']
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            rows=list(pool.map(lambda _:self.claim(f,asset,0),range(4)))
        self.assertEqual(sum(r['claimed'] for r in rows),1)
        c=next(r for r in rows if r['claimed']);af={**f,'asset_id':asset,'asset_attempt':1,'claim_id':c['asset']['claim_id']}
        self.assertNotEqual(self.command('run',{**f,'workflow_run_id':'other'},succeeds=False).returncode,0)
        self.command('context',{**f,'context_version':0,'value':{'state':'complete'}})
        self.assertNotEqual(self.command('context',{**f,'context_version':0,'value':{'stale':True}},succeeds=False).returncode,0)
        done={**af,'status':'completed','files':[{'storage_key':'fixture'}],'caption':'fixture','qa':{'passed':True}}
        self.command('finish_asset',done);before=self.snapshot();self.command('finish_asset',done);self.assertEqual(before,self.snapshot())
        self.assertNotEqual(self.command('finish_asset',{**done,'caption':'changed'},succeeds=False).returncode,0)
        self.command('settle',f);before=self.snapshot();self.command('settle',f);self.assertEqual(before,self.snapshot())
    def test_real_registration_receipt_and_resume_fence(self):
        f=self.running();v={'state':'submitting','model':'fixture','input_sha256':'a'*64,'charge_credits':40}
        s=self.command('phase',{**f,'phase':'image_submission_0','value':v});op=s['operation_id']
        self.observe(op,f,{'kind':'accepted','request_id':'original'})
        self.command('phase',{**f,'phase':'image_submission_0','value':{**v,'state':'accepted','request_id':'original'}})
        self.command('finish_asset',{**f,'status':'uncertain','error':'lost result'});self.command('settle',f)
        j=self.command('read')['job'];p={'request_id':str(uuid.uuid4()),'quote_id':j['quote']['id'],'expected_revision':1,'approved_max_usd':.006,'asset_id':f['asset_id'],'asset_attempt':1,'source_claim_id':f['claim_id'],'source_execution_id':f['execution_id'],'source_execution_version':f['execution_version']}
        s=self.command('resume',p);newf=self.bind(s,'resumed');c=self.claim(newf,f['asset_id'],1);newf={**newf,'asset_id':f['asset_id'],'asset_attempt':1,'claim_id':c['asset']['claim_id']}
        self.assertEqual(c['asset']['attempt'],1)
        before=self.snapshot();self.assertNotEqual(self.command('finish_asset',{**f,'status':'failed'},succeeds=False).returncode,0);self.assertEqual(before,self.snapshot())
        self.observe(op,newf,{'kind':'completed','request_id':'original','output_sha256':'b'*64})
        self.assertEqual(before,self.snapshot())
        self.command('finish_asset',{**newf,'status':'uncertain','error':'again'});self.command('settle',newf)
        before=self.snapshot();self.assertNotEqual(self.command('resume',{**p,'request_id':str(uuid.uuid4())},succeeds=False).returncode,0);self.assertEqual(before,self.snapshot())
        self.assertFalse(self.command('resume',p)['dispatch'])
    def observe(self,op,f,payload,succeeds=True,actor=None):
        data=json.dumps(payload).replace("'","''");identity=json.dumps({'execution_id':f['execution_id'],'claim_id':f['claim_id']})
        r=self.sql(f"SET ROLE service_role; SELECT append_pack_provider_observation('{actor or self.owner}',null,'{op}','{identity}'::jsonb,'{data}'::jsonb)",succeeds=succeeds)
        return json.loads(r.stdout) if succeeds else r

if __name__=='__main__':
    names=[x for x in FencedPacks.__dict__ if x.startswith('test_')]
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(FencedPacks(x) for x in names))
    raise SystemExit(not result.wasSuccessful())
