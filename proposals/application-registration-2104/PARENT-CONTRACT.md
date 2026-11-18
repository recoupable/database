# Inactive application parent and entitlement candidate — App2104

17 November 2026. **Proposed source for disposable qualification only. No runtime
or customer policy is adopted.** This directory is outside `supabase/migrations`,
has no workflow, public API/MCP caller, grants, production role, enrollment API,
provider call, DNS resolver, connection string or bootstrap path. Do not deploy it,
point a fixture at another database, or use `qualification-bootstrap.sql` in runtime.

The concrete contribution is an atomic parent-creation transaction and explicit
management entitlement check. The existing proof/configuration algorithms can operate
on its parent shapes in an isolated composition. Passing qualification does not make
this an application registry release, least-privilege runtime adapter or App2104 completion.
Only the initial selected environment is created; there is no add-environment operation.

## Files and source bindings

| File | Purpose |
| --- | --- |
| `parents.sql` | Proposed parents, enrolled personal principals, named creation/management entitlements and immutable registration history. No seeded permission or grants. |
| `registration.sql` | Unexposed invoker helpers, atomic create and authorized historical receipt read. |
| `qualification-bootstrap.sql` | Synthetic existing accounts and a trivial fresh-auth observation stub. Test setup only; not part of candidate runtime SQL. |
| `protocol-composition.py` | Exact-hash mechanical binding of the existing proof/configuration SQL to these parents and the new entitlement helper; disposable execution only. |
| `test_registration.py` | Owned Unix-socket PostgreSQL supervisor, new transaction/contended-lock tests and negative execution checks. |
| `sources.json` | API, Database and copied cleanup provenance; every composition substitution/count and adapter hash. |

API authentication/validation references are pinned to accepted
`1fff6b55b8c1b98826c375f99b4f4f66a5ba201c`. Database source baseline is
`7708e337feca212563bdfa48934a72227bcf1b63`. The accepted proof/configuration sources
under `../application-proof-2104/` are not edited. `sources.json` binds their complete
bytes. Composition performs exactly 7 and 14 `proof_parent_fixture.` →
`application_registration_proposal.` substitutions, respectively, then appends the
hash-checked five-argument authority adapter. It preserves function volatility,
revisions, CAS, replay order and lock algorithms. Any unexpected source hash/count
fails before SQL. No `fixture-authority.sql`, fixture parent DDL or configuration-fixture
is loaded. Generated SQL is ephemeral, not a migration or a committed copied protocol.

## Authentication is a precondition, not a SQL feature

A future trusted server must freshly call the actual existing `validateAuthContext`
with `allowAccountCreation:false` and `includeVerificationEvidence:true`, with no
account or organization override. It must require original principal actor equals
effective account and selected workspace, self access, and no organization context.
Only that original identity is passed as `p_actor`. Original actor UUIDs are internal
server arguments, never customer registration fields. A positive authentication result
does not provide an application-management entitlement.

The transaction locks/rechecks an existing `public.accounts` row and an explicitly
enrolled personal-principal row. It does **not** verify API keys/Privy tokens, observe
credential revocation after authentication, or classify personal accounts from UUID
equality alone. No credential/key hash/token ledger is added. The enrollment row is
an explicit proposed personal classification requiring separately authorized provisioning.
API-key/Privy verification and its lifetime boundary remain with the existing verifier.
There is no invented claim of atomic credential revocation with this database transaction.

The qualification stub merely distinguishes labels representing accepted/rejected
fresh authentication. Its `current-key` versus revoked/wrong/changed labels are **not
tests of real key verification or revocation**. The real verifier bytes are pinned,
not exercised against live accounts. Stale/changed **idempotency keys and input** are
separately tested against actual SQL. There is no organization membership, admin,
service-role, client boolean or fixture-authority fallback.

## Proposed authority and inputs

`register_application(actor, workspace, environment, key, entitlement_revision, registration)`
requires current enabled `create_entitlements` for the exact actor/workspace/environment.
The proposed operation name is `create_application`, not an OAuth scope. Workspace
must equal actor and billing owner is fixed to workspace. Expected entitlement revision
is a concurrency observation, not authority. A new request must match it. Creation
has an optional expiry checked after authority-lock waits, after retry-key waits and
before parent insertion using `clock_timestamp()`.

`registration` contains exactly `name` and sorted `origins`; every origin has exactly
`origin`, `hostname` and sorted distinct `return_urls`. A future server first uses the
existing shared registration validator, then sorts/projects its exact canonical values
and derives hostname with WHATWG URL parsing. SQL additionally rejects missing/extra
fields, duplicate/out-of-order origins, host mismatch, foreign returns, fragments,
whitespace and bounds violations. It does not implement WHATWG normalization, DNS
eligibility or ownership verification. Inputs are 1–32 exact origins, 1–32 total return
URLs, at most 2048 characters per URL, 120 per name and 256 KiB total JSON. An origin
may have no return URL if the entire registration still has one. Limits are engineering
qualification bounds, not commercial quotas. HTTP loopback is development-only.

Create generates application and receipt UUIDs; the caller cannot select application
identity or billing owner. It atomically inserts application, one environment, exact
origins/return destinations (all three revisions initially 1), immutable receipt and
retry row. It grants **no** post-creation permissions and issues no credentials.

Post-create operations require separately provisioned `management_entitlements` for
exact actor/workspace/application/environment/operation. Supported labels are
`read_registration`, `issue`, `verify`, `revoke`, `read` (proof receipt), and
`replace_existing_origin_return_urls`. These are proposed internal operation names.
They support explicit enabled/revision revocation, **not time-based leases**. An early
review removed post-create expiry because the unchanged proof/configuration algorithms
can wait after initial authorization; this candidate does not claim management expiry
fencing across those later waits. Adding that behavior requires a separately reviewed
protocol, not an inferred production policy. This limitation does not weaken creation's
explicitly tested expiry boundary.

`read_registration(actor, workspace, application, environment, receipt)` checks the
exact named read entitlement before returning immutable history. A receipt ID is not
a capability. Reads do not require the original creator if a future policy permits
other principals; this proposed personal-only schema permits actor=workspace only.
No alternate policy is implemented. Missing/foreign resources yield the same controlled
authority-unavailable error. SQL errors have no adopted public transport mapping.

## Locks, replay and participating writers

One domain operation per transaction, READ COMMITTED only:

1. Lock existing account `FOR SHARE`, then enrolled personal principal `FOR SHARE`.
2. Lock the exact named creation or management entitlement `FOR SHARE` and validate
   enabled/policy state. For create, sample expiry after this lock.
3. For create, transaction advisory lock on `(actor,workspace,create_application,key)`;
   recheck expiry after waiting, then authorized replay lookup.
4. New create checks expected entitlement revision and input, samples expiry again,
   inserts generated application → selected environment → sorted exact origins,
   then immutable receipt/retry record. No existing application is mutated.

Authorization locks are held to transaction end. A revocation committed before lock
acquisition denies. Revocation arriving after an authorized operation waits for it;
it cannot undo an operation that serialized first. Subsequent calls, including exact
retries, fail. Any participating authority writer follows account → personal principal →
exact entitlement order, and uses exclusive row locks; multiple rows must be ordered
consistently. Tests use isolated direct updates to those rows as proposed revocation
writers, not a shipped grant/revoke administration API.

The unchanged proof protocol then takes its own actor/workspace/operation/key advisory
lock, application/environment `FOR SHARE`, exact origin `FOR UPDATE`, and challenge
locks as needed. Configuration takes application `FOR SHARE`, environment `FOR UPDATE`,
then every origin in bytewise order `FOR UPDATE`. Proposed parents preserve the same
composite keys/immediate FKs, so configuration/proof parent serialization is retained.
No rename, transfer, origin-add/remove, restoration or suspension API is introduced.
Arbitrary direct DML, disabled constraints and privileged operators are not fenced.

Creation retry scope is actor/workspace/create-operation/key, across environments.
The fingerprint contains exact environment, entitlement revision and canonical input.
Authorization precedes lookup. Identical retries return original IDs/timestamp/receipt
without creating anything or extending time; changed payload, environment or expected
revision under the same key conflicts. An original exact retry can return its old
entitlement revision after a later revision change if authority remains enabled/current;
a new key must match the current revision. Unknown outcome recovery uses the original
key and payload, never an automatic new key. Rollback restores every partial insert.
Receipt/retry UPDATE and DELETE are blocked; retention, purge, export and tombstone
lifetime remain unadopted. Fixture truncation is teardown only.

## Outputs and privilege boundary

Every registration receipt includes actor, workspace, fixed billing owner, generated
application/receipt IDs, selected environment, recorded timestamp, entitlement/policy
revision and full initial snapshot. It constrains all these flags false:
`origins_verified`, `bootstrap_enabled`, `access_activated`, `runtime_enabled`,
`production_persisted`. It labels `policy_status: proposed_unadopted` and
`evidence_kind: disposable_parent_assertion`. `production_persisted:false` distinguishes
local qualification persistence from a production write, not SQL's transaction durability.

Proof/configuration receipts keep their original synthetic evidence and disabled-access
contracts; no synthetic resolver observation becomes live DNS proof. No Site resource,
provider configuration, billing operation, quotas, fan session or public bootstrap is
introduced. Creating applications cannot authorize spending or reset any allowance.

All schemas/tables/functions explicitly revoke PUBLIC access, including internal
helpers. There are **no replacement grants, security-definer functions or production
roles**. The local cluster owner executes qualification; a synthetic non-login browser
role proves denial. This is not a least-privilege deployment proof. D3 remains open.

## Qualification and runner safety

```sh
PG_BIN=/path/to/postgresql15/bin python3 proposals/application-registration-2104/test_registration.py
PG_BIN=/path/to/postgresql17/bin python3 proposals/application-registration-2104/test_registration.py
```

The supervisor accepts a local binary directory, creates an owned random directory,
starts Unix-socket-only PostgreSQL, launches a dedicated worker process group, and
stops/removes only that verified lease. No hosted connection string is accepted.
The internal worker verifies absolute local socket path, UID/device/inode, parent PID,
registered binary directory and postmaster identity **before SQL**; connection-related
variables are constructed from an allowlist, not copied from the ambient environment.
HOME/TMPDIR point to owned fixture directories; PATH contains only resolved PostgreSQL/
Python directories and system binaries; LANG/LC_ALL/TZ are fixed. `initdb -E UTF8`
preserves Unicode/JSON semantics despite the C locale; qualification asserts server
encoding and a Unicode registration round trip. Only the explicit
socket/binary/validated fault controls accompany them. Worker SQL receives fixed
PGHOST/PORT/DATABASE/OPTIONS and an explicit application name. The supervisor clears
its inherited environment before launching any fixture or cleanup subprocess; workers
launch with isolated Python (-I) and scrub again before lease-check subprocesses.
Synthetic poison tests verify unrelated service, libpq service/password and loader/
Python variables are absent from actual child environments. No real credential values
or home credential files are inspected. The marker/lease is an accidental-target guard, not an OS
security boundary against a malicious local owner who can edit the runner itself.

SQL, process startup, worker duration and cleanup have bounded waits. Scoped SIGTERM/
SIGINT unwind cleanup; the worker group is quiesced even if its leader exited. The
exact reviewed worker-group and directory/PID cleanup functions are embedded with source
hashes in `sources.json`. That reuse alone does not inherit all prior supervisor tests.
This candidate separately exercises signal, worker timeout and exited-worker-with-child
faults via `REGISTRATION_QUALIFICATION_FAULT=signal|timeout|worker-exit`, using only its
own disposable cluster. Ambiguous ownership leaves files intact with a reported path.
Uncatchable supervisor SIGKILL/host loss is not claimed recoverable automatically.

New tests cover missing/foreign/disabled entitlement and principal, exact binding,
revision conflict, changed-key input, exact/lost-response replay, revoked replay,
explicit and mid-parent rollback, read isolation, immutable history, disabled outputs,
PUBLIC/helper denial, input bounds, original protocol composition and stale CAS.
Two-connection cases require observed PostgreSQL lock waits before releasing the winner:
concurrent same-key create, revocation-first, create-first, expiry after authority wait,
and expiry after advisory wait. No unchanged full protocol suite is repeated.

## Remaining adoption and publication boundaries

D1–D4 remain unadopted: personal enrollment authority, organization/delegated policy,
execution identity/function-owner permissions, retention owner/period/deletion contract,
and pilot identities/timing. No value is inferred from this qualification. Actual
HTTP/MCP adapters, credential handling, production mapping, policy, grants and deployment
need their own review. App2345 native acceptance and the completed2094 bridge remain
separate; no hosted/provider/customer outcome is claimed here.

Root reviews the exact diff and no-deploy path boundary before push. Any PR remains
DRAFT, unmerged and unapplied. Draft status alone does not disable external integrations.
The candidate changes only this proposal directory: no automatic migration files,
workflow triggers or runtime configs. Existing unconditional local-test workflows can
still run on a PR. A repository-integrated Supabase preview service may be configured
outside this checkout; its behavior is not proven by reading `.github/workflows`.
Do not publish until root dispositions that external-trigger boundary.
