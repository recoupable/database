# Recoup Supabase

Supabase migration scripts for the Recoup project.

## Release metadata review migration

`20261008160000_context_release_cases.sql` adds an immutable metadata review
receipt and four service-only operations: list/read a saved release case, record
an exact-version review, and read a historical receipt. It uses existing Context
requests, results, documents, release positions and ISRC observations. No rights,
collection, payment or provider mutation is introduced.

The trusted API supplies the authenticated actor. Every operation checks workspace
membership inside its transaction. Current and historical evidence reads lock
source/version rows; new reviews also lock the request and current documents.
Revocation waits for an already-authorized transaction; later transactions fail.
Browser roles have no table or function access. Service-role receipts are insert
and read only, with a server-created snapshot and a workspace-scoped retry key.

Dependencies include the Context foundation/pipeline, release verification scope,
track positions/read/identity-review migrations, and existing `service_role`
SELECT plus UPDATE-column privileges on `account_organization_ids` (see
`20261008030000_onboarding_membership_lock_privilege.sql`). This is an additive
migration against that existing schema, not a replacement baseline.

### Local verification

With `initdb`, `pg_ctl` and `psql` from one PostgreSQL installation on PATH:

```sh
python3 -m unittest discover -s tests -p 'test_release_cases.py'
```

The runner starts a disposable Unix-socket-only cluster, applies the actual
migration files listed in the runner, executes the assertions and stops/removes
the cluster. CI runs the same command with PostgreSQL 16.

`supabase/tests/context_release_cases.sql` runs with synthetic fixtures inside a
rolled-back transaction. It checks the real service role, cross-workspace denial,
missing evidence, exact retries, changed-input rejection, stale fingerprints,
historical snapshots, the 100-track review bound, source withdrawal, revoked
membership and browser-role grants. Run it against a disposable database with the
prerequisites applied, never a production database. A fixture owner needs setup
permissions and permission to `SET ROLE service_role` for that test.

The implementation was tested with PostgreSQL 17 and a minimal legacy bootstrap
plus the actual prerequisite Context SQL. That is not a replay of all historical
migrations. Before deployment, inspect Recoup's live baseline and grants and run
its normal migration checks. Live Recoup schema access was unavailable through
the connector during implementation, so this deployment gate remains open.

The original migration is preserved after its hosted PR preview passed.
`20261008160100_context_release_case_cursor.sql` is a forward-only correction
that rejects missing, foreign and non-release cursors with the same controlled
permission error. Apply both migrations in order.

### Rollout and rollback

Apply this migration through the approved database release process before the
API actions and Chat `/releases` route are deployed. Then verify the original
business case through authenticated hosted API/MCP/UI paths. No provider flags
or paid jobs need activation for saved-evidence review.

If application rollout fails, revert the dependent API/UI changes first and retain
the additive table and receipts. Do not drop historical review data as a routine
rollback. Any later schema removal requires a separate reviewed retention/export
plan. Existing Context collection paths are unchanged.
