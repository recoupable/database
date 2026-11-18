"""Action-specific CAS/replay must be checked before expiry may mutate state."""
import unittest
import uuid
from test_contract import FencedPacks


class ExpiryFence(FencedPacks):
    def expire(self):
        self.sql(f"UPDATE release_pack_jobs SET hold_expires_at=now()-interval '1 second' WHERE id='{self.job}'")

    def complete_state(self):
        history = self.sql(f"SELECT jsonb_build_object('executions',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM release_pack_executions e WHERE job_id='{self.job}'),'claims',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM release_pack_claims c WHERE owner_id='{self.owner}'))").stdout.strip()
        return self.snapshot(), history

    def test_context_cas_refuses_before_expiry_and_current_version_can_recover(self):
        fence = self.running()
        self.command('context', {**fence, 'context_version': 0, 'value': {'state': 'complete'}})
        self.expire()
        before = self.complete_state()
        for extra in [{'context_version': 0}, {'context_version': None}, {}]:
            rejected = self.command('context', {**fence, **extra, 'value': {'stale': True}}, succeeds=False)
            self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
            self.assertIn('Context version changed', rejected.stderr)
            self.assertEqual(before, self.complete_state())
        recovered = self.command('context', {**fence, 'context_version': 1, 'value': {'not_saved_after_expiry': True}})
        self.assertTrue(recovered['command_expired'])
        self.assertEqual(recovered['job']['context_version'], 1)
        self.assertEqual(recovered['job']['production_context'], {'state': 'complete'})
        self.assertEqual(recovered['job']['held_credits'], 0)
        after = self.complete_state()
        self.command('read')
        self.assertEqual(after, self.complete_state())

    def test_pending_claim_cas_and_request_identity_refuse_before_expiry(self):
        saved, _ = self.approve_v2()
        fence = self.bind(saved)
        asset_id = saved['assets'][0]['id']
        self.expire()
        before = self.complete_state()
        for extra, message in [
            ({'asset_attempt': 99, 'request_id': str(uuid.uuid4())}, 'Stale pending attempt'),
            ({'request_id': str(uuid.uuid4())}, 'Stale pending attempt'),
            ({'asset_attempt': 0}, 'Claim request identity required'),
        ]:
            rejected = self.command('claim', {**fence, 'asset_id': asset_id, **extra}, succeeds=False)
            self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
            self.assertIn(message, rejected.stderr)
            self.assertEqual(before, self.complete_state())
        expired = self.command('claim', {**fence, 'asset_id': asset_id, 'asset_attempt': 0, 'request_id': str(uuid.uuid4())})
        self.assertTrue(expired['command_expired'])
        self.assertEqual(expired['job']['held_credits'], 0)
        self.assertEqual(self.sql(f"SELECT count(*) FROM release_pack_claims WHERE owner_id='{self.owner}'").stdout.strip(), '0')
        after = self.complete_state()
        self.command('read')
        self.assertEqual(after, self.complete_state())

    def test_claim_replay_or_conflict_never_becomes_expiry_authority(self):
        saved, _ = self.approve_v2()
        fence = self.bind(saved)
        payload = {**fence, 'asset_id': saved['assets'][0]['id'], 'asset_attempt': 0, 'request_id': str(uuid.uuid4())}
        self.command('claim', payload)
        self.expire()
        before = self.complete_state()
        replay = self.command('claim', payload)
        self.assertTrue(replay.get('replayed'), replay)
        self.assertFalse(replay['claimed'])
        self.assertEqual(before, self.complete_state())
        conflict = self.command('claim', {**payload, 'asset_attempt': 1}, succeeds=False)
        self.assertNotEqual(conflict.returncode, 0, conflict.stdout)
        self.assertIn('Claim payload conflict', conflict.stderr)
        self.assertEqual(before, self.complete_state())
        loser = self.command('claim', {**payload, 'request_id': str(uuid.uuid4())})
        self.assertFalse(loser['claimed'])
        self.assertEqual(before, self.complete_state())


if __name__ == '__main__':
    suite = unittest.TestSuite(ExpiryFence(name) for name in ExpiryFence.__dict__ if name.startswith('test_'))
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
