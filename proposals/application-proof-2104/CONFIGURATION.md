# Existing-origin return-URL configuration writer

October 27, 2026. **Executable offline proposal, outside migrations.** This extends
[the proof receipt protocol](PROTOCOL.md) with the narrow contract adopted from
[API #1191](https://github.com/recoupable/api/pull/1191), head
`e50082e3ea9ba4fa37a75e49340d94b3b97552dc`. It persists only disposable fixture rows.
No production adapter, role policy, grant, registration route, DNS request, migration
application, provider operation or bootstrap/access activation is introduced.

## Scope and files

- `configuration-fixture.sql` adds synthetic application name and per-origin return
  URLs to the existing parent fixture. It is not a production registry schema.
- `configuration.sql` adds the default-denied invoker, immutable configuration
  receipts/retry records and an internal snapshot reconstruction helper.
- `test_configuration.py` reuses the established disposable PostgreSQL harness and
  exercises the actual SQL, including two-connection contention. CI runs it alongside
  the unchanged proof transaction suite on PostgreSQL 15 and 17.

The authority adapter remains the existing always-denying `authorize_management`.
Only the test runner adds `replace_existing_origin_return_urls` to synthetic fixture
operation lists. That label is not a production role or delegated OAuth scope.
There is no membership fallback or caller boolean. Invoker functions use the caller's
privileges; all new schema objects have PUBLIC access revoked and no replacement
grant. Tests use the disposable cluster owner plus a denied browser role; they do
not demonstrate an adopted least-privilege service role. The internal snapshot helper
has no authorization or locks of its own and must not be exposed as a read endpoint.

## Exact input, baseline and projection

`configure_return_urls(actor, workspace, application, environment, key, expected,
changes)` consumes the saved-parent baseline and sorted changes from the API
rehearsal. Authenticated actor and selected resource scope are server inputs, not
registration-body fields. The future real adapter must first use the shared
registration validator; it is absent here.

`expected` has exactly the API rehearsal shape: workspace/application/environment,
name, sorted exact allowed origins, sorted exact return URLs, and one sorted origin
row containing configuration/proof/CAS revisions plus revoked status. SQL reconstructs
that entire object from locked parents. Any difference, including extra/missing
fields, changed name, an unmodified origin's revisions or destinations, or an origin
addition/removal, rejects with `snapshot conflict`. API uses sorted sets; the SQL
expects that canonical ordering and does not silently normalize a different baseline.

Each change contains exactly `origin`, `expected`, `next` and sorted distinct
`return_urls`. SQL derives both revision triples from the locked origin:
configuration +1, CAS +1, proof unchanged. The supplied triples must match exactly;
callers cannot reset or invent revisions. Only changed, existing, non-revoked origins
are supported. No-op batches and unchanged entries are rejected; the API rehearsal
already avoids invoking an empty batch. Per-origin destinations may be empty if
the complete resulting configuration retains at least one destination.

Bounds match the existing 1–32-origin / 1–32-total-return-URL shape, 2048 characters
per URL and JavaScript-safe revision projection. The prototype additionally caps
serialized expected state at 256 KiB and changes at 128 KiB. These are conservative
qualification limits, not commercial quotas. Return URLs must have the exact origin
prefix followed by `/`, with no fragment, whitespace or control characters. This
SQL guard is **not** a WHATWG URL parser and does not replace API canonical validation.
The fixture's origins/hostnames are trusted prevalidated assertions; this writer
does not qualify DNS eligibility or domain ownership.

The transaction replaces return URLs only for affected origins, advances their
configuration/CAS revisions, and supersedes their pending challenges atomically.
Unchanged origins and their pending challenges are preserved. Prior verified proof
receipts and proof revision remain unchanged. New/removed origins, rename, transfer,
reactivation and membership changes are outside this writer; fixture topology edits
exist only to test conflicts. No synthetic parent or authority is promoted to production.

## Lock protocol and origin-set phantoms

READ COMMITTED is required. Lock order is:

1. Current management-authority dependencies through the existing adapter.
2. Scoped idempotency advisory lock `(actor, workspace, operation, key)`.
3. Application `FOR SHARE`.
4. Environment **`FOR UPDATE`**, before any origin lock.
5. Every existing origin in bytewise (`COLLATE "C"`) order, `FOR UPDATE`.
6. Reconstruct and compare full baseline; validate the entire change projection;
   update affected origins/challenges and append immutable receipt/retry result.

The existing proof transaction takes application/environment `FOR SHARE` before
its origin lock, so it serializes against the stronger environment lock without
inverting the parent-before-child order. Application/environment suspension changes
also serialize, and the returned status is checked after lock acquisition.

An inserted origin references the environment through the fixture's immediate
composite foreign key. Its FK key-share lock conflicts with the environment update
lock. Thus an insertion that commits first is visible in the reconstructed baseline;
an insertion arriving while the writer holds the parent lock waits until afterward.
The tests demonstrate both orderings with real database lock waits. Existing-origin
deletions conflict with the origin row locks; a prior committed deletion causes a
baseline mismatch. This is conditional on these immediate foreign keys and the
reviewed writer protocol. A superuser disabling constraints, arbitrary multi-step
writers using inverse lock order, or a different production schema are not covered.
Use one domain operation per transaction until larger transaction composition is reviewed.

A change to an otherwise untouched origin still conflicts with the full baseline.
Tests include a concurrent proof issuance on that origin and competing configuration
batches that target different origins but start from one full snapshot. This prevents
blindly applying an older full-set intent to newer parent state.

## Receipt, retry and failure behavior

Configuration receipts contain actor/resource scope, server timestamp, complete
before/after snapshots and derived changes. Both `bootstrap_enabled` and
`access_activated` are constrained false; `production_persisted` is false and
`evidence_kind` is `synthetic_configuration`. The receipt records local fixture
persistence, not a public grant, current authorization or customer deployment.
It is a Database receipt, not the API rehearsal's fake acknowledgment envelope;
no production adapter connects those interfaces in this change.

Retry scope is actor/workspace/this operation/key. The JSONB fingerprint includes
application, environment, exact expected baseline and exact ordered changes.
JSON object key order is immaterial; array order remains significant. After current
authorization and parent locks, an identical retry returns the original immutable
receipt before baseline/suspension/revocation checks. This is authorized history
with disabled activation, not renewed access. A changed payload on the same key
conflicts; retries never change timestamps or repeat configuration updates. Losing
a committed response is recovered with that same key and payload, not a blind new
mutation. Retention and real permission policy remain unadopted.

Fresh mutations reject current suspension or any revoked origin. Exact retries
also require current management authority: revoked authority cannot recover history
through this operation. Rollback removes origin changes, challenge invalidations,
receipt and retry rows together. A test forces an error on the second origin update
and verifies the first origin and pending challenge are restored. Update/delete
triggers prevent mutation of saved configuration receipts and retry records.
Database errors remain internal prototype exceptions, not adopted HTTP error codes.

## Qualification

Run each with PostgreSQL binaries from a single installation on PATH:

```sh
python3 proposals/application-proof-2104/test_transactions.py
python3 proposals/application-proof-2104/test_configuration.py
```

The new tests cover default authority/browser denial, exact projection including an
empty per-origin destination list, immutable proof history, complete snapshot
conflicts, unsupported/injected changes, current suspension/revocation, rollback,
lost-response recovery, exact/concurrent retry, and selective challenge invalidation.
Two connections test configuration versus configuration, proof issue/revoke/verify,
authority/suspension, untouched-origin issuance, and origin-set insertion/removal.
Barriers require PostgreSQL to report an actual lock wait before releasing the winner.
No timing-only assertion substitutes for observed contention.

Before any runtime exposure: root reviews this source-only protocol; adopt real
management/delegated authority, production parent mapping and all participating
writer lock orders, least-privilege invoker access, canonical-validation adapter,
retention and consumer revocation. Keep activation disabled. No production migration
or role grants are part of this PR. #2110 hosted/provider/mobile/shared-callback gates
and the separate #2345 browser hold remain unchanged.
