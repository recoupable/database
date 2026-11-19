"""Source guardrails only; does not execute SQL or qualify database behavior."""
import pathlib
import re
import unittest
SQL = pathlib.Path(__file__).with_name('proposal.sql').read_text()
class Boundary(unittest.TestCase):
    def test_authorizer_denies_and_no_grants(self):
        self.assertIn("adapter unavailable' USING ERRCODE='0A000'", SQL)
        self.assertNotIn('GRANT EXECUTE', SQL)
        self.assertIn('FROM PUBLIC,anon,authenticated,service_role', SQL)
    def test_exact_fence_and_original_bytes(self):
        for term in ['s.epoch IS DISTINCT FROM p_epoch', 's.owner IS DISTINCT FROM p_owner', 's.run_id IS DISTINCT FROM p_run', "s.phase<>'running'", 'prior.source_canonical<>p_source', 'prior.surface_canonical<>p_surface', "USING ERRCODE='40001'", 'part->\'data\' IS DISTINCT FROM surface']:
            self.assertIn(term, SQL)
    def test_lock_order(self):
        terms=['FROM public.sessions WHERE', 'FROM public.chats WHERE', 'FROM chat_fence.state WHERE', 'FROM public.chat_messages WHERE', 'PERFORM chat_fence.authorize_catalog_surface_source']
        self.assertEqual(sorted(SQL.index(t) for t in terms), [SQL.index(t) for t in terms])
    def test_anchor_generation_before_authorization_and_replay(self):
        guard = re.search(r"IF NOT EXISTS\(SELECT 1 FROM chat_fence\.message_epochs WHERE (.*?)\) THEN RAISE EXCEPTION 'prior message generation' USING ERRCODE='40001'; END IF;", SQL, re.S)
        self.assertIsNotNone(guard, 'retention must reject an absent or foreign-generation anchor')
        self.assertEqual(guard.group(1).split(), 'message_id=msg.id AND chat_id=p_chat AND epoch=s.epoch'.split())
        self.assertLess(SQL.index('SELECT * INTO msg'), guard.start())
        self.assertLess(guard.end(), SQL.index('PERFORM chat_fence.authorize_catalog_surface_source'))
        self.assertLess(guard.end(), SQL.index('SELECT * INTO prior'))

    def test_anchor_lifecycle(self):
        self.assertIn('REFERENCES public.chat_messages(id) ON DELETE CASCADE', SQL)
        self.assertIn('catalog_surface_source BEFORE UPDATE ON public.chat_messages', SQL)
        self.assertIn("IF current_user<>'recoup_chat_fence_owner' THEN RETURN NEW", SQL)
if __name__ == '__main__': unittest.main()
