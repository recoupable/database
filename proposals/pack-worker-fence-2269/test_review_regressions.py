"""Post-review boundary regressions against actual disposable SQL."""
import hashlib
import json
import unittest
from test_contract import FencedPacks

class ReviewRegressions(FencedPacks):
    def register(self, fence, **extra):
        value = {'state': 'submitting', 'model': 'fixture', 'input_sha256': 'a'*64, 'charge_credits': 40, **extra}
        return self.command('phase', {**fence, 'phase': 'image_submission_0', 'value': value}), value

    def test_completed_asset_requires_complete_provider_journal(self):
        f = self.running()
        registered, value = self.register(f)
        op = registered['operation_id']
        for state in ['submitting', 'accepted']:
            if state == 'accepted':
                self.observe(op, f, {'kind': 'accepted', 'request_id': 'original'})
                self.command('phase', {**f, 'phase': 'image_submission_0', 'value': {**value, 'state': state, 'request_id': 'original'}})
            before = self.snapshot()
            rejected = self.command('finish_asset', {**f, 'status': 'completed', 'files': [{'storage_key': 'fixture'}], 'caption': 'fixture', 'qa': {'passed': True}}, succeeds=False)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Incomplete provider attempt', rejected.stderr)
            self.assertEqual(before, self.snapshot())
        self.observe(op, f, {'kind': 'completed', 'request_id': 'original'})
        self.command('phase', {**f, 'phase': 'image_submission_0', 'value': {**value, 'state': 'complete', 'request_id': 'original'}})
        self.command('finish_asset', {**f, 'status': 'completed', 'files': [{'storage_key': 'fixture'}], 'caption': 'fixture', 'qa': {'passed': True}})

    def test_submitting_intent_cannot_preseed_request_id_or_skip_charge(self):
        f = self.running()
        before = self.snapshot()
        for request_id in ['original', None]:
            value = {'state': 'submitting', 'model': 'fixture', 'input_sha256': 'a'*64, 'charge_credits': 40, 'request_id': request_id}
            rejected = self.command('phase', {**f, 'phase': 'image_submission_0', 'value': value}, succeeds=False)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(before, self.snapshot())
        registered, value = self.register(f)
        self.observe(registered['operation_id'], f, {'kind': 'accepted', 'request_id': 'original'})
        result = self.command('phase', {**f, 'phase': 'image_submission_0', 'value': {**value, 'state': 'accepted', 'request_id': 'original'}})
        self.assertEqual(self.sql(f"SELECT billed_credits FROM release_pack_assets WHERE id='{f['asset_id']}'").stdout.strip(), '40')
        self.assertEqual(self.sql(f"SELECT count(*) FROM usage_events WHERE account_id='{self.owner}'").stdout.strip(), '1')

    def test_invalid_actions_refuse_before_expiry(self):
        f = self.running()
        self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")
        before = self.snapshot()
        for action in ["'unknown'", 'NULL']:
            payload = json.dumps(f)
            result = self.sql(f"SET ROLE service_role; SELECT release_pack_command_v2('{self.owner}',null,{action},'{self.job}','{payload}')", succeeds=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unknown protocol-2 command', result.stderr)
            self.assertEqual(before, self.snapshot())

    def test_expired_settlement_replays_identical_response(self):
        f = self.running()
        self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")
        result = self.command('settle', f)
        before = self.snapshot()
        self.assertTrue(result['command_expired'])
        self.assertEqual(self.command('settle', f), result)
        self.assertEqual(before, self.snapshot())
        self.assertNotEqual(self.command('settle', {**f, 'error': 'changed'}, succeeds=False).returncode, 0)

    def test_bound_dispatch_uncertain_requires_workflow_identity_before_expiry(self):
        f = self.running()
        self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")
        before = self.snapshot()
        for run in [None, 'wrong']:
            rejected = self.command('dispatch_uncertain', {**f, 'workflow_run_id': run}, succeeds=False)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Stale workflow', rejected.stderr)
            self.assertEqual(before, self.snapshot())

    def test_receipts_reject_unsupported_transaction_isolation(self):
        f = self.running()
        registered, _ = self.register(f)
        identity = json.dumps({'execution_id': f['execution_id'], 'claim_id': f['claim_id']})
        for isolation in ['REPEATABLE READ', 'SERIALIZABLE']:
            result = self.sql(f"BEGIN ISOLATION LEVEL {isolation}; SET ROLE service_role; SELECT append_pack_provider_observation('{self.owner}',null,'{registered['operation_id']}','{identity}','{{\"kind\":\"accepted\",\"request_id\":\"original\"}}'); COMMIT", succeeds=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires READ COMMITTED', result.stderr)
        self.assertEqual(self.observe(registered['operation_id'], f, {'kind': 'accepted', 'request_id': 'original'})['state'], 'saved')

    def test_accepted_conflict_hashes_original_accepted_slot(self):
        f = self.running()
        registered, _ = self.register(f)
        op = registered['operation_id']
        self.observe(op, f, {'kind': 'accepted', 'request_id': 'original'})
        self.observe(op, f, {'kind': 'completed', 'request_id': 'original'})
        self.observe(op, f, {'kind': 'accepted', 'request_id': 'different'})
        hashes = self.sql(f"SELECT (SELECT payload->>'existing_sha256' FROM release_pack_provider_observations WHERE operation_id='{op}' AND kind='conflict')=encode(sha256(convert_to(payload::text,'UTF8')),'hex') FROM release_pack_provider_observations WHERE operation_id='{op}' AND kind='accepted'").stdout.strip()
        self.assertEqual(hashes, 't')

if __name__ == '__main__':
    suite = unittest.TestSuite(ReviewRegressions(name) for name in ReviewRegressions.__dict__ if name.startswith('test_'))
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
