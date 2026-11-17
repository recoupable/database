# Retained evidence version manifest

Run with PostgreSQL `initdb`, `pg_ctl` and `psql` on `PATH`:

```sh
python3 -m unittest discover -s tests -p 'test_evidence_manifest*.py'
```

The fixture creates disposable clusters, applies the Context, release-entry and
manifest migrations to a minimal legacy schema, and removes the clusters afterward.
It uses synthetic inputs; it is not a full migration replay or hosted transport test.

`list_context_request_evidence_versions` returns up to 50 unique retained versions
for an authorized request. It includes source/version IDs, kind, fingerprint,
retrieval time, evidence kinds and current-versus-historical status. It does not
return source contents, storage paths or signed URLs, or confirm identity or rights.
Removed/withdrawn inputs withhold every version belonging to their dependent result.

Pass returned `next_id` as `p_after` when `has_more` is true. A cursor must still be
visible in the same owned request. Each page rechecks access and uses a coherent
query snapshot; successive pages are not a frozen export or an authorization grant.

The two manifest test classes define 12 cases. Each also runs the inherited
`test_review_lifecycle_and_access` from `ReleaseCases`, yielding 14 executions.
CI runs PostgreSQL 15 and 16. Local validation also covers PostgreSQL 17.
Forward migration `20261009200001` inlines the retained-version query in the
bounded wrapper and revokes the unbounded helper from `service_role`. Browser
roles remain denied; the original preview-applied migration is unchanged.
Forward migration `20261009200002` selects at most 51 cursor-eligible versions
before aggregating their evidence kinds and current status. This bounds the
provenance aggregation, not all eligibility scans; query cost still depends on
history size and available indexes. The 56-version paging case checks complete
coverage without overlap.
The API must supply the authenticated actor and validate returned scope/metadata.
Release requires explicit approval and production migration/permission verification.
