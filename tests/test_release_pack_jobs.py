"""Ownership, revisions, budget reservations and idempotency on disposable PostgreSQL."""
import concurrent.futures
import json
import uuid
from release_pack_fixture import ReleasePackFixture

class ReleasePackJobs(ReleasePackFixture):
    def setUp(self):
        self.owner=str(uuid.uuid4())
        self.job=str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{self.owner}'); INSERT INTO credits_usage(account_id,remaining_credits) VALUES ('{self.owner}',10000000)")
    def command(self, action, payload=None, actor=None, org=None, succeeds=True):
        data=json.dumps(payload or {}).replace("'","''")
        orgsql=f"'{org}'" if org else 'null'
        sql=f"SET ROLE service_role; SELECT release_pack_command('{actor or self.owner}',{orgsql},'{action}','{self.job}','{data}'::jsonb)"
        result=self.sql(sql,succeeds=succeeds)
        return json.loads(result.stdout) if succeeds else result
    def prepare(self):
        return self.command('prepare',{'idempotency_key':self.job,'fingerprint':'a'*64,'brief':{},'deliverables':{},'status':'ready_to_quote','assets':[{'kind':'artwork','ordinal':0,'credits':100,'maximum_usd':0.01}]})
    def quote(self):
        self.prepare()
        return self.command('estimate',{'quote':{'id':str(uuid.uuid4()),'revision':1,'credits':100,'maximum_usd':0.01,'expires_at':'2099-01-01T00:00:00Z'},'assets':[{'kind':'artwork','ordinal':0,'credits':100,'maximum_usd':0.01}]})
    def approve(self):
        q=self.quote()['job']['quote']
        return self.command('approve',{'quote_id':q['id'],'expected_revision':1,'approved_max_usd':0.01})
    def test_owner_and_revision(self):
        first=self.prepare()
        self.assertEqual(first['job']['revision'],1)
        self.assertEqual(self.prepare()['job']['id'],first['job']['id'])
        self.assertNotEqual(self.command('read',actor=str(uuid.uuid4()),succeeds=False).returncode,0)
        self.assertNotEqual(self.command('prepare',{'expected_revision':99,'idempotency_key':'next','fingerprint':'b'*64},succeeds=False).returncode,0)
    def test_concurrent_approval_holds_only_once(self):
        q=self.quote()['job']['quote']
        args={'quote_id':q['id'],'expected_revision':1,'approved_max_usd':0.01}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            rows=list(pool.map(lambda _:self.command('approve',args),range(8)))
        self.assertEqual(self.sql(f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip(),'9999900')
        self.assertEqual(sum(bool(row.get('dispatch')) for row in rows),1)
    def test_claim_replay_and_budget(self):
        approved=self.approve()
        asset=approved['assets'][0]['id']
        first=self.command('claim',{'asset_id':asset})
        second=self.command('claim',{'asset_id':asset})
        self.assertTrue(first['claimed'])
        self.assertFalse(second['claimed'])
        self.command('phase',{'asset_id':asset,'phase':'image_submission_0','value':{'state':'accepted','request_id':'fixture','charge_credits':100}})
        self.command('phase',{'asset_id':asset,'phase':'image_submission_0','value':{'state':'accepted','request_id':'fixture','charge_credits':100}})
        self.command('finish_asset',{'asset_id':asset,'status':'completed','files':[{'storage_key':'fixture'}],'caption':'ok','qa':{'passed':True}})
        settled=self.command('settle')
        self.assertEqual(settled['job']['status'],'completed')
        self.assertEqual(self.sql(f"SELECT count(*) FROM usage_events WHERE account_id='{self.owner}'").stdout.strip(),'1')
    def refill(self, floor):
        stamp=self.sql(f"SELECT timestamp::text FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip()
        return self.sql(f"SET ROLE service_role; SELECT refill_credits_to_floor('{self.owner}',{floor},'{stamp}'::timestamp)")
    def test_unspent_hold_refunds_preserved_funds_across_noop_refill(self):
        self.approve()
        self.refill(2000000)
        self.command('settle',{'error':'fixture failure'})
        self.command('settle',{'error':'replay'})
        self.assertEqual(self.sql(f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip(),'10000000')
    def test_floor_refill_counts_held_funds_without_minting_or_losing_credits(self):
        self.sql(f"UPDATE credits_usage SET remaining_credits=150 WHERE account_id='{self.owner}'")
        self.approve()
        self.refill(200)
        self.command('settle',{'error':'fixture failure'})
        self.assertEqual(self.sql(f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip(),'200')
    def test_refill_and_atomic_topups_do_not_undo_a_hold(self):
        self.approve()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _:self.sql(f"SET ROLE service_role; SELECT adjust_credit_balance_atomic('{self.owner}',100)"),range(8)))
        self.refill(200)
        self.command('settle',{'error':'fixture failure'})
        self.assertEqual(self.sql(f"SELECT remaining_credits FROM credits_usage WHERE account_id='{self.owner}'").stdout.strip(),'10000800')
    def test_org_membership_and_browser_denial(self):
        org=str(uuid.uuid4())
        self.sql(f"INSERT INTO accounts VALUES ('{org}')")
        self.assertNotEqual(self.command('read',org=org,succeeds=False).returncode,0)
        for role in ['anon','authenticated']:
            result=self.sql(f"SET ROLE {role}; SELECT release_pack_command('{self.owner}',null,'read','{self.job}','{{}}')",succeeds=False)
            self.assertIn('permission denied',result.stderr)

    def test_ambiguous_dispatch_retains_hold_until_reconciled_or_expired(self):
        self.approve()
        uncertain=self.command('dispatch_uncertain',{'error':'lost dispatch response'})
        self.assertEqual(uncertain['job']['status'],'running')
        self.assertEqual(uncertain['job']['held_credits'],100)
        self.assertEqual(uncertain['job']['dispatch_state'],'uncertain')
    def test_expiry_fences_old_work_and_preserves_targeted_recovery(self):
        approved=self.approve()
        asset=approved['assets'][0]['id']
        self.command('claim',{'asset_id':asset})
        self.command('phase',{'asset_id':asset,'phase':'image_submission_0','value':{'state':'submitting'}})
        self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")
        expired=self.command('read')
        self.assertEqual(expired['job']['held_credits'],0)
        self.assertEqual(expired['assets'][0]['status'],'uncertain')
        self.assertNotEqual(self.command('phase',{'asset_id':asset,'phase':'image_submission_0','value':{'state':'accepted','request_id':'late','charge_credits':100}},succeeds=False).returncode,0)

    def test_revision_clears_preproduction_context_after_early_failure(self):
        self.approve()
        self.command('context',{'value':{'state':'complete','summary':'old song'}})
        self.command('settle',{'error':'stopped before first visual'})
        revised=self.command('prepare',{'expected_revision':1,'idempotency_key':'revision','fingerprint':'b'*64,'brief':{'song_title':'new song'},'deliverables':{},'status':'ready_to_quote'})
        self.assertIsNone(revised['job']['production_context'])
        self.assertIsNone(revised['job']['quote'])
        self.assertEqual(revised['job']['revision'],2)
