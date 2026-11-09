# Organization ingestion catalog

`20261110010000_ingestion_catalog.sql` adds organization-owned datasets, immutable import versions and queryable gold rows to the existing Recoup database. No database or schema is created per client. Original files and processing artifacts stay in private Supabase Storage.

The only runtime database entry point is `ingestion_catalog_command(actor, organization, action, input)`. It is executable by the service role only. The authenticated API supplies the actor; every command checks current organization membership and holds its membership lock through commit. Tables have RLS and no direct browser or service-role privileges. The security-definer functions use an empty search path and fully qualified relations. The internal authorization helper cannot be called by browser or service roles.

`register` assigns a new dataset or attaches an import to an existing dataset in the same organization. Immutable manifests bind the scoped source object, contract and selected dataset. `complete` publishes ready gold rows and the import receipt atomically, or records held/rejected metadata without gold. Repeated completion must match the entire original completion payload. Lists and row pages are bounded and scoped; reading rows requires both dataset and import version. New imports do not replace earlier records or imply semantic deduplication across statements.

Run isolated tests with PostgreSQL binaries from one installation on PATH:

```sh
python3 -m unittest discover -s tests -p 'test_ingestion_catalog.py'
```

The harness starts and removes a disposable Unix-socket-only cluster. It bootstraps minimal account/membership dependencies, applies the actual migration and exercises the real service role, cross-org denial, revocation, concurrency, exact strings, immutable versions, failed-write rollback and pagination. This is not a full historical migration replay or a production deployment.

Optionally exercise the matching API processor against that same temporary database:

```sh
INGESTION_API_WORKTREE=/absolute/path/to/api-worktree \
  python3 -m unittest discover -s tests -p 'test_ingestion_catalog.py'
```

The API checkout needs dependencies installed and `lib/ingestion/__tests__/catalog.integration.test.ts`. The test uses synthetic CSV bytes, the real parsing pipeline, the guarded SQL gateway and private in-memory artifact storage. It verifies a committed completion losing its acknowledgement, recovery without duplicate rows, and database-enforced organization/revocation checks. It does not exercise hosted Storage, PostgREST, HTTP credentials or Workflow infrastructure.

## Rollout

Apply the additive migration to the existing Recoup project before deploying the dependent API change. Keep ingestion disabled until hosted access/storage/workflow qualification. There are no new client connection strings, external database identities, scheduled jobs or production writes in the test runner.

If rolling back, revert dependent API behavior first and retain datasets/import history. Do not drop or rewrite accepted records as routine rollback. Existing private ingestion artifacts are not deleted or automatically combined across versions.

## Status — 2026-11-09

Local PostgreSQL 17 verification passes ten database tests plus the optional joined API lifecycle test. CI covers PostgreSQL 15 and 17. Migration deployment, hosted org-scoped ingestion and production activation remain unverified and are separate rollout steps.
