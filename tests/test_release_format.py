"""Release format observation projected from saved Spotify evidence; disposable PG only."""
import test_release_cases as release_cases

ROOT = release_cases.ROOT
MIGRATION = ROOT / 'supabase/migrations/20261010213900_context_release_format_observation.sql'


class ReleaseFormat(release_cases.ReleaseCases):
    """Re-runs the sibling review fixture against the replaced read function, then the format fixture."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.previous_read = cls.sql(
            "SELECT pg_get_functiondef('public.read_context_release_case(uuid,uuid,uuid)'::regprocedure)"
        ).stdout + ";\n"
        cls.sql(MIGRATION.read_text())

    def test_release_format_observation(self):
        result = self.sql((ROOT / 'supabase/tests/context_release_format.sql').read_text())
        self.assertIn('PASS:', result.stderr)

    def test_migration_invalidates_receipts_and_rollback_preserves_history(self):
        # Reuse the established synthetic review setup, stopping before evidence mutation.
        fixture = (ROOT / 'supabase/tests/context_release_cases.sql').read_text()
        setup = fixture.split(" replay:=public.review_context_release_case", 1)[0]
        setup += """
 reset role;
 create temporary table migration_receipt as select member as actor, owner as owner_id,
   req as request_id, saved_id as review_id, old_hash as fingerprint,
   public.read_context_release_case_review(member,owner,saved_id)->'snapshot' as snapshot;
end $$;
"""
        migration = MIGRATION.read_text()
        # Execute the same DDL inside our outer rollback-only fixture transaction.
        migration = migration.replace('begin;', '', 1).rsplit('commit;', 1)[0]
        verify_upgrade = """
do $$
declare saved record; projection jsonb; receipt jsonb;
begin
 select * into saved from migration_receipt;
 projection:=public.read_context_release_case(saved.actor,saved.owner_id,saved.request_id);
 receipt:=public.read_context_release_case_review(saved.actor,saved.owner_id,saved.review_id);
 if projection->>'fingerprint'=saved.fingerprint or not (projection ? 'release_format')
 or receipt->>'stale' is distinct from 'true'
 or receipt->'snapshot' is distinct from saved.snapshot then
  raise exception 'Migration failed fingerprint invalidation or immutable-history contract';
 end if;
 begin
  perform public.review_context_release_case(saved.actor,saved.owner_id,saved.request_id,
   saved.fingerprint,'reviewed','','pre-migration-retry');
  raise exception 'TEST_FAILURE: pre-migration fingerprint accepted';
 exception when serialization_failure then null; end;
 -- Save a second immutable receipt against the newly installed projection.
 set local role service_role;
 receipt:=public.review_context_release_case(saved.actor,saved.owner_id,saved.request_id,
  projection->>'fingerprint','reviewed','Reviewed format observation','post-migration-review');
 receipt:=public.read_context_release_case_review(saved.actor,saved.owner_id,(receipt->>'id')::uuid);
 reset role;
 if receipt->>'state' is distinct from 'saved' or receipt->>'stale' is distinct from 'false'
 or receipt->'snapshot'->'release_format' is distinct from projection->'release_format'
 or receipt->'snapshot'->>'fingerprint' is distinct from projection->>'fingerprint'
 or receipt->>'id'=saved.review_id::text then
  raise exception 'New-projection receipt was not independently saved and current';
 end if;
 create temporary table upgraded_receipt as select (receipt->>'id')::uuid as review_id,
  receipt->'snapshot' as snapshot;
end $$;
"""
        verify_rollback = """
do $$
declare saved record; projection jsonb; receipt jsonb;
begin
 select * into saved from migration_receipt;
 projection:=public.read_context_release_case(saved.actor,saved.owner_id,saved.request_id);
 receipt:=public.read_context_release_case_review(saved.actor,saved.owner_id,saved.review_id);
 if projection ? 'release_format' or projection->>'fingerprint' is distinct from saved.fingerprint
 or receipt->>'stale' is distinct from 'false'
 or receipt->'snapshot' is distinct from saved.snapshot then
  raise exception 'Rollback failed to restore projection or preserve review history';
 end if;
 -- Read both receipts after rollback; neither snapshot may be rewritten or hidden.
 if receipt->>'state' is distinct from 'saved' then
  raise exception 'Rollback hid the pre-migration receipt';
 end if;
 receipt:=public.read_context_release_case_review(saved.actor,saved.owner_id,
  (select review_id from upgraded_receipt));
 if receipt->>'state' is distinct from 'saved' or receipt->>'stale' is distinct from 'true'
 or receipt->'snapshot' is distinct from (select snapshot from upgraded_receipt)
 or not (receipt->'snapshot' ? 'release_format') then
  raise exception 'Rollback lost or rewrote the new receipt, or failed to mark it stale';
 end if;
 raise notice 'PASS: migration invalidation, stale-write rejection, both immutable snapshots retained, new receipt stale after rollback';
end $$;
rollback;
"""
        drop_helper = 'DROP FUNCTION public.project_context_release_format(jsonb,jsonb,jsonb);'
        result = self.sql('begin;\n' + self.previous_read + drop_helper
                          + setup.removeprefix('begin;') + migration + verify_upgrade
                          + self.previous_read + drop_helper + verify_rollback)
        self.assertIn('PASS:', result.stderr)
