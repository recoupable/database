# Recoup Supabase

Supabase migration scripts for the Recoup project.

## Scheduled posts migration

`20261015230000_create_scheduled_posts.sql` adds `scheduled_posts` for `POST /api/posts`; see [tests/SCHEDULED-POSTS.md](tests/SCHEDULED-POSTS.md).

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
the cluster. CI runs the same command with PostgreSQL 15 and 16.

`supabase/tests/context_release_cases.sql` runs with synthetic fixtures inside a
rolled-back transaction. It checks the real service role, cross-workspace denial,
missing evidence, exact retries, changed-input rejection, stale fingerprints,
historical snapshots, the 100-track review bound, source withdrawal, revoked
membership and browser-role grants. Run it against a disposable database with the
prerequisites applied, never a production database. A fixture owner needs setup
permissions and permission to `SET ROLE service_role` for that test.

The implementation was tested locally with PostgreSQL 15 and 17 and a minimal
legacy bootstrap plus the actual prerequisite Context SQL. That is not a replay
of all historical migrations.

On 2026-10-08, a read-only production audit confirmed PostgreSQL 15.6, the required
Context migrations, the request composite key, dependency tables/functions, and
service-role read and row-lock privileges. The existing Context evidence tables
have RLS enabled and no browser-role CRUD grants; dependency RPCs inspected are
security-invoker functions executable by the service role. The membership table
has browser grants but RLS enabled with no policies, so those grants alone do not
allow browser row access. A transaction using the actual `service_role` confirmed
schema access, scoped reads and the built-in SHA-256 function, then rolled back.
Neither new review migration was deployed during this audit.

This closes the narrow prerequisite schema/grant inspection gate, not deployment
or hosted workflow verification. The previously reported hosted preview project
was not accessible through this connector during the audit; do not infer current
preview health from an earlier CI result. Run normal migration checks on the final
PR commit, then verify the authorized HTTP/MCP/UI paths after approved rollout.
An empty workspace needs a separately authorized collection through the supported
workflow before saved-evidence review can be exercised; do not insert fabricated
production evidence to make a review test pass.

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

## Portable catalog cases

`20261022120000_context_catalog_cases.sql` stores versioned private catalog case
artifacts without requiring an artist, recording, catalog ID or ingestion request.
It reuses `authorize_context_case_actor`, Context source versions and the existing
workspace-membership lock. Apply the Context foundation, release-case authorization
and membership-lock prerequisites before this additive migration.

Service-only RPCs are `save_context_catalog_case`, `read_context_catalog_case` and
`list_context_catalog_cases`. Each takes the authenticated actor and resolved owner.
Save uses an expected revision, workspace-scoped idempotency key and a portable
version-1 snapshot (at most 1 MiB; 1,000 records per collection). Revision history
is immutable; pagination uses stable creation order. Source links use existing
Context version IDs and are checked within the transaction. Revoking membership
blocks future access. Withdrawing linked evidence redacts that source and its
transitive dependent records, including historical reads, while preserving unrelated
work. A redacted snapshot is visibly partial and cannot be blindly saved.

All saved content is labeled `customer_assertion`. Storage does not authenticate
contracts, grant provider authority, calculate royalties or execute actions. Local
file references remain private supplied assertions, not hosted original uploads.
The independent local calculators retain their controlled outputs as referenced
artifacts; no second financial calculation is implemented in SQL. API must enforce
the complete typed record schema in addition to these persistence checks.

Run synthetic transaction tests with a functioning PostgreSQL installation:

```sh
python3 -m unittest discover -s tests -p test_catalog_cases.py
```

The harness uses a disposable Unix-socket-only cluster, actual prerequisite SQL and
synthetic fixtures. Local tests and CI do not apply a production migration. Roll out
the contract, database migration, then dependent API operations; verify authenticated
HTTP/MCP readback separately. Roll back the API before schema changes and retain
case history; deleting persisted work requires a separate retention decision.
