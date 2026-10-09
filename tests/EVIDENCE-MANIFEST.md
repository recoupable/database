# Retained evidence version manifest

Run `python3 -m unittest discover -s tests -p 'test_evidence_manifest*.py'`
with PostgreSQL initdb/pg_ctl/psql on PATH. The suite creates disposable local
clusters, applies actual Context, release-entry and manifest migrations over a
minimal legacy fixture, then removes them. It uses synthetic locators/evidence
and no hosted credentials or provider calls; this is not full migration replay.

`20261009200000` adds service-only security-invoker functions. The public domain
adapter must supply an authenticated actor and selected owner; the list operation
rechecks/locks workspace membership and the owned request inside its transaction.
Its source query follows retained request/attempt/accepted-result/source lineage,
not roster membership or an attachment. Only request output subjects qualify.

A page returns at most50 unique versions: exact version/source IDs, source kind,
fingerprint, retrieval time, distinct evidence kinds and whether a linked result
is in the current document projection. Old accepted versions remain discoverable;
accepted customer assertions remain assertions. Failed/candidate/creative-only
results, removed versions and withdrawn sources are withheld. If a result depends
on any withdrawn input, none of that result's versions are projected.

The read exposes no raw content, storage paths, signed URLs or rights decisions.
It adds no tables, collection, registration, parsing, wallet or financial writes.
The cursor must refer to visible retained lineage in the same request; foreign,
missing or newly inaccessible cursors are denied. Pass returned next_id as p_after
while has_more is true. Each page has a coherent query snapshot; this does not
freeze the entire history across subsequent pages. A later action must recheck
source and target access rather than use this metadata as an access grant.

Validation covers a saved locator without collection, history/exact reuse,
multi-result/mixed-kind deduplication, current versus historical pointers,
foreign existing records/cursors, removal/withdrawal/multi-input dependency,
revoked/fresh actors, paging, read-only behavior and browser-role denial.
Eight initial regressions failed before implementation;14 tests pass on local
PostgreSQL15/17 including two inherited release-review lifecycle tests. CI runs15/16.

Release requires explicit approval, production prerequisite/migration/permission
verification and shared authenticated HTTP/standard MCP adapters with typed input
and response validation. No production release or business intake occurred during
implementation. Delegated OAuth requires its separate organization-grant audit.
