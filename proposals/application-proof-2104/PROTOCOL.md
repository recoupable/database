# Application proof transactions — offline proposal

October 27, 2026. Related: [application registration #2104](https://github.com/recoupable/app/issues/2104).
The adopted source-only starting contract is [API #1189](https://github.com/recoupable/api/pull/1189),
head `fd515f9981265fec04d48f2a449c4180ad360842`, merged as
`31d28cd7ac88ebc62d567a11c8ff452acb1369ea` (coordinator merge report).
This proposal implements transactions **only inside a disposable fixture**. It is
outside `supabase/migrations`, has no API/MCP caller, and adds no deployed registry,
role grants, DNS lookup, credential issuance, provider flow, or access activation.

## First scope and adoption boundaries

Authorized issuance, verification receipts, revocation and receipt read are the
first scope. Every returned receipt has `bootstrap_enabled: false`,
`access_activated: false`, and `evidence_kind: synthetic_observation`. Database
constraints also require both disabled fields. A successful TXT observation is
not a permission grant. No authentication, billing, quota, fan identity, points,
Context or customer-data store is introduced or duplicated.

The one-hour challenge expiry, 60-second observation freshness and seven-day
`qualification_valid_until` are explicit qualification parameters. They are not
production lease/access policy, provider promises or approved customer renewal
burdens. Early renewal is permitted; a fresh issue/verification records a new
historical receipt. Existing receipts and retry outputs never get new timestamps.
No active domain lease is stored or consumed by another system here.

## Files and authority

- `fixture.sql`: minimal synthetic workspace → application → environment → exact
  origin parents. Origins contain a prevalidated hostname. This is not a proposed
  full registry schema or an ownership/canonicalization implementation.
- `proposal.sql`: challenges, immutable receipts/retry records and an invoker
  transaction boundary in `application_proof_proposal`. The management-authority
  adapter **always denies**, including for workspace members or owners. PUBLIC
  schema/table/function access is revoked; no replacement grant is supplied.
- `fixture-authority.sql`: explicitly test-only replacement adapter. It locks a
  synthetic actor/workspace/application/environment record with an operation list.
  This models current authority and revocation races; it is not an adopted role
  policy, real account authentication, or evidence of production permission.
- `test_transactions.py`: creates a disposable PostgreSQL cluster with only a Unix
  socket and no TCP listener; loads these three files and synthetic data, runs
  assertions and stops/removes the cluster. No hosted connection string is accepted.

The runner uses the local cluster owner to prepare and execute the fixture. A
browser-role denial test proves absent PUBLIC access, not least-privilege runtime
service grants. Those grants, real role/delegated-scope mapping, resolver policy,
hostname eligibility and consumer enforcement require separate adoption and tests.
Do not load the fixture-authority override as an activation shortcut.

## Exact binding and revisions

Each origin's identity is the exact composite `(workspace, application,
environment, origin)`. Parent composite foreign keys prevent attaching a child to
a different workspace/application/environment. DNS query hostname is derived from
the trusted parent fixture, not a caller-supplied URL. The future admission adapter
must validate canonical origin/hostname consistency and DNS eligibility; these
fixture rows are not domain-ownership evidence. Production/development and
unrelated applications never share a challenge even if they name the same host.
Global challenge-digest uniqueness prevents nonce reuse across all bindings.
No wildcard, parent-domain inheritance, origin normalization, or shared-host grant.

Three revisions are deliberately separate:

| Revision | Owner and change rule |
| --- | --- |
| Configuration | Parent registry; changes to configured origin/return destinations or applicable security configuration advance it and CAS. This fixture's config-change test mutates the origin row directly under its row lock. |
| Origin proof | Verification/revocation protocol; advances on a new verified receipt or security revocation, not challenge issuance/rotation. |
| CAS | Per-origin serialization version; advances on every issue/rotate/verify/revoke and modeled configuration change. |

Issue snapshots configuration and proof revisions into a pending challenge.
Rotation supersedes the old pending challenge and advances CAS only. Verify must
match the exact challenge ID, binding, snapshot revisions and caller's current
three revisions; consumes once, advances proof/CAS, and appends a receipt. Revoke
marks the origin terminally revoked, invalidates pending challenges and advances
proof/CAS. Reactivation is not implemented; no old challenge can restore it.
Changing parent configuration invalidates an outstanding observation even if the
hostname still matches. It cannot rewrite historical proof receipts. A future
parent adapter must advance revisions atomically; unrelated writers bypassing that
contract are not covered by this prototype.

## Transaction order and concurrency

Only READ COMMITTED is accepted. All participating writers follow this order:

1. Management-authority adapter locks and validates its policy dependencies.
2. Transaction advisory lock on `(actor, workspace, operation, idempotency key)`.
   A hash collision serializes extra requests without granting access.
3. Application then environment `FOR SHARE`, followed by exact origin `FOR UPDATE`.
4. Current idempotency lookup or challenge `FOR UPDATE`; then atomic state change,
   immutable receipt and retry result insertion.

Fresh statements after locks recheck current state. The server samples
`clock_timestamp()` after locks, including the challenge lock, rather than using
transaction-start `now()`. A request that waited past expiry/freshness cannot pass
using an earlier clock. Suspension blocks fresh mutations. Historical reads and
exact retries remain available to currently authorized management actors even
when revoked/suspended, because all outputs are access-disabled history.

Real two-connection tests hold transactions open, observe PostgreSQL lock waits,
commit the winner and inspect the loser's result. Verify loses to an already
committed revoke, challenge rotation or configuration change through revision
conflict, and to authority revocation through denial. If verification commits
first, stale revoke conflicts; retry against current revisions revokes while
preserving the prior receipt. Revocation waits for an already-authorized transaction;
it does not retrospectively undo a receipt that serialized first.

The prototype serializes all operations for one origin. The parent adapter must
also serialize its mutations against these locks. It does not claim multi-operation
arbitrary transaction lock ordering or immunity to superuser/direct-table writes.
Use one domain operation per transaction; future broader transactions need review.

## Retry, rollback and observation contract

Idempotency is scoped to authenticated actor, workspace and operation. The stored
JSONB fingerprint contains exact application/environment/origin, expected revisions
and payload. An authorized exact retry returns its original receipt **before**
stale-revision checks, without another receipt or time extension. Changed payload
or revision on the same key conflicts. A different key cannot reconsume a challenge.
Read requires current `read` management authority and exact receipt binding; a
receipt ID alone is insufficient. Authorization is checked before retry lookup.

A committed result whose response was lost is recovered with the same key and
payload; never rotate or submit a fresh verification just because the result is
unknown. The test discards a committed response and recovers it. Explicit rollback
after issue or verify leaves no receipt/retry side effect and restores challenge
state. Errors, including a globally duplicate digest, roll back superseding the
old challenge in the same transaction. Immutable triggers reject receipt and retry
updates/deletes; deleting/truncating a fixture is test teardown, not retention policy.
Retention/tombstones and real audit requirements remain an adoption gate.

The issuer supplies a synthetic SHA-256 digest; this database prototype does not
generate or publish a nonce. Verify accepts a trusted fixture observation containing
challenge ID, matched digest, exact query name, observation timestamp and the only
supported policy marker `synthetic-v1`. It verifies exact equality and time bounds.
There are no DNS responses, credentials, HTTP URLs to fetch, or caller-controlled
resolver destinations. The API proposal's separate offline model covers TXT string
assembly; this layer does not parse raw TXT or validate resolver authenticity.
A live adapter must supply an authenticated, bounded observation and adopted policy;
a client claiming `synthetic-v1` is never acceptable evidence in production.

Errors are controlled messages for invalid input, missing management authority or
resource, suspension, revision/idempotency conflict, expired/unavailable challenge,
and rejected observation. They are prototype SQL exceptions, not an adopted HTTP
status mapping. Future public transports must sanitize database constraint errors
(e.g. duplicate digests) to avoid exposing other bindings. No transport exists here.

## Run and remaining qualification

With `initdb`, `pg_ctl` and `psql` from one PostgreSQL installation on PATH:

```sh
python3 proposals/application-proof-2104/test_transactions.py
```

The CI workflow runs PostgreSQL 15 and 17. Qualification covers exact binding,
default denial, cross-workspace/environment rejection, browser denial, digest
uniqueness, rotation, replay/idempotency, immutable historical read, disabled
activation, expiry/freshness, rollback/unknown outcome and competing transactions.
This is neither a full migration replay nor evidence of deployed registration.

Before API exposure: coordinator reviews this protocol; adopt real management
roles/delegation, parent registry mapping/revision writers and server privilege
model; qualify resolver/eligibility and observation provenance; decide lifecycle
metadata/retention. Any subsequent persistence migration belongs in a separate
Database PR. Keep bootstrap/access activation disabled until its own authority and
revocation contract is approved. #2110's provider, independent-host, mobile and
shared-callback gates and the separate #2345 browser hold remain unchanged.
