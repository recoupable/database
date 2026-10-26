# Disabled catalog schedule storage — offline prototype

2026-10-25. Root selected this minimum offline prototype after the source-only proposal at `afeb9c29f48027924efd83085076634f932368dd`. That original four-file snapshot/reviews remain sealed separately. This document describes current implemented scope; PROPOSAL.md, SCHEMA.md and QUALIFICATION.md retain the historical wider design, not authorization to implement its execution features.

## Implemented boundary

`disabled-storage.sql` is deliberately outside `supabase/migrations/`. It creates only schedule parents, immutable revisions and exact mutation receipts; **no occurrence table, enable function, claim, dispatch, scheduler, provider/email effect, public route or generated production types**. Every schedule has CHECK NOT enabled and CHECK next_due_at IS NULL. Kind/version, original principal, actor/effective/recipient and explicit workspace/catalog are immutable; actor=effective=recipient. Original creator/principal only: no emergency other-member control, takeover or orphan recovery. Disabled rows occupy the business key until original-authority archival; missing/revoked creator remains a conflict.

Management RPCs:

- `mutate_catalog_report_schedule(p_actor uuid,p_principal jsonb,p_request uuid,p_command jsonb)` supports only create, edit_disabled, disable and archive.
- `read_catalog_report_schedule(p_actor uuid,p_principal jsonb,p_id uuid)` returns a flat current state after current access checks.

`p_actor` and `p_principal` are **trusted server-verified management context**, supplied synthetically in these tests. SQL does not authenticate a credential or independently prove Privy/key liveness. No hosted API wrapper is built. A later wrapper must obtain a fresh verified credential from the existing auth flow, preserve its original actor and reject overrides. Captured JSON is never a client-selected authority or a scheduler grant. Unattended Privy, immutable key-ID continuity, resource permission, verified delivery and execution remain unsupported.

Principal is exactly `{mechanism:"recoup_api_key",key_id:<UUID>}` or `{mechanism:"privy",app_id,issuer,subject}`. Each union checks exact keys, types, required nonnull values and bounded strings; no token/email/hash storage. Immutable parent columns hold this identity. SQL checks the current caller principal matches on all reads/mutations/replays. Historical UUIDs have no external FK, preserving source deletion ability and audit; current missing accounts/catalogs deny access.

Create command is `{action:"create",payload:{catalog_id,organization_id,schedule,timezone}}`; required organization_id is null or an exact UUID. effective/recipient account is always p_actor, not payload. All UUID strings are canonical lowercase; noncanonical strings and unknown keys are rejected, not silently normalized. Weekly cron accepts canonical `minute hour * * weekday` decimal fields only; no leading zeros, seconds, lists or arbitrary cadence. Timezone is exact `UTC` or a slash-qualified name in pg_timezone_names with a restricted alphabet. No timezone alias rewrite or next-run calculation occurs; compatibility with API Intl/cron-parser and DST remains future qualification. This intentionally narrower offline grammar is not a public API acceptance promise.

edit_disabled requires id, expected_revision, schedule and timezone. disable/archive require only id and expected_revision. JSON null/missing/fractional/negative/overflow revisions fail; at INT_MAX no mutation occurs. Archive requires already-disabled current revision; no combining enable/disable/archive and no post-archive mutations. Since create is always disabled, it can be archived at revision1; a dedicated test proves create→archive with no intervening disable command. The historical qualification text about separate disable/archive revisions applies only when a disable command is actually submitted, not an action-order requirement. Successful mutations append one exact revision and receipt atomically. Strict receipt input uses JSONB semantic equality: reordered JSON keys compare equal; extra/changed inputs do not. No automatic retry on stale revisions.

Every read/mutation/replay checks the actor account, explicit owner account, catalog, current org membership (unless account is the org), and exact account_catalogs link. A personally visible catalog cannot substitute for a removed org link. Locks are account parents sorted, catalog parent, organization membership, exact owner/catalog link, schedule. Receipt advisory lock precedes business key and row locks; receipt checks compare original input under current authorization before returning the historical snapshot. Scoped create unique index treats NULL workspace as a distinct explicit scope. CAS and business uniqueness prevent concurrent overwrite. SQL is READ COMMITTED only. No external effect is made while holding locks.

## Dependency security correction found in independent review

The initial synthetic bootstrap omitted dependency RLS. Both reviewers correctly rejected that qualification: privileges alone would hide rows from the non-bypass RPC owner. The final harness loads the **actual pinned** Database `76bad6195b4bd1918284c5ebe49c91f408072ed2` migrations:

1. `20251005212508_create_catalogs_table.sql`
2. `20251005214926_create_account_catalogs_table.sql`
3. `20251204000000_create_account_organization_ids.sql`

Only accounts(id) and the timestamp helper are minimal legacy bootstrap. Accounts RLS is additionally enabled in the fixture; this does not assert a full historical accounts schema replay. The actual dependencies retain their own RLS, grants, IDs, nullable membership fields, FKs and triggers. No invented composite membership PK remains.

The prototype introduces a dedicated `catalog_report_owner` NOLOGIN NOINHERIT without BYPASSRLS, owning only new tables/functions. **Unlike the historical design's initial no-dependency-grant assumption, this prototype adds owner-only SELECT and row-lock UPDATE-column privileges plus policies on accounts, catalogs, account_organization_ids and account_catalogs.** `FOR SELECT USING(true)` and `FOR UPDATE USING(true) WITH CHECK(false)` allow lock scans. An additional owner-only AS RESTRICTIVE UPDATE policy with USING(true), WITH CHECK(false) keeps writes denied even when an additional permissive policy allows them. A failing regression demonstrated the permissive-OR problem before that restrictive policy was added. PostgreSQL consults UPDATE visibility for lock scans; SELECT alone was tested and failed closed. Existing service/browser grants and policies are not broadened; service_role has no membership in this owner and receives only the two new RPC execute grants. All helpers are revoked from PUBLIC/browser/service roles. Functions fix empty search_path and qualify table names.

This is **not approval to apply these policies to production**. Existing hosted policy/grant composition must be separately inspected before any deployment; the test inventory includes all applicable policies from the pinned dependency migrations (none preexisting for these dependencies), plus the prototype policies and an adversarial PUBLIC permissive UPDATE policy. The restrictive policy proves write denial for that composition while RLS is enabled. Hosted RLS enablement, force/owner semantics, role membership, policy/grant drift and trigger dependencies remain unverified; no blanket deployment claim follows. No hosted database was inspected or changed. Future owner capability expansion requires review of the dependency privileges. The offline regression asserts non-login/non-bypass identity, no service role assumption, no direct service table mutation, no browser RPC/helper access and denied dependency writes by the owner.

## Qualification performed

`test_disabled_storage.py` starts a fresh Unix-socket-only cluster, loads pinned dependencies and actual proposed SQL, uses synthetic identities with real PostgreSQL roles, then stops/removes the cluster. No credentials, network provider calls or unchanged Database122 suite. Fifteen tests pass on PostgreSQL15 and17:

- lifecycle/readback, immutable revisions, archived history and replacement identity;
- original receipt after newer revision, changed input, stale revision and overflow;
- exact org scope, principal mismatch, removed membership/link and current-access replay;
- account/catalog deletion preserving audit without blocking source deletion;
- strict keys/nulls/union/UUID/cadence/timezone validation;
- exact duplicate receipt race, changed-key-input race, independent CAS race and business-key race;
- transaction rollback, actual service/browser/helper/owner permissions and dependency RLS;
- admitted membership lock proven via pg_stat_activity wait barrier, followed by revocation and denied later read;
- explicit absence of execution objects and synthetic Privy provenance still disabled;
- direct create→archive proves disabled-state precondition without inventing a required prior disable action;
- additive permissive-policy attack still denies dependency writes after restrictive guard;
- scoped teardown and empty reinstallation preserving legacy accounts.

Commands (installed binaries, no download):

```sh
PG_BINDIR=/opt/homebrew/opt/postgresql@15/bin python3 proposals/catalog-weekly-storage-1867/test_disabled_storage.py
PG_BINDIR=/opt/homebrew/opt/postgresql@17/bin python3 proposals/catalog-weekly-storage-1867/test_disabled_storage.py
```

The harness bootstraps actual relevant migrations, not all historical production migrations. No real auth provider, HTTP/PostgREST, UI or scheduler is qualified. Initial tests were written before SQL; first execution hit a local initdb restriction rather than a behavioral red. Later SQL syntax, catalog-variable binding and dependency-RLS failures were observed and corrected; logs distinguish them. Quiet psql output fixed command-tag parsing. Overflow fixture setup explicitly disables the parent guard as a fixture owner and validates deferred constraints before restoring it; the normal service role cannot do this.

`disabled-rollback.sql` is disposable teardown only: removes these new RPCs/tables/policies/grants/role by explicit names, with no CASCADE. It does delete prototype history in the throwaway test cluster; it is not a production rollback recommendation. Production rollback remains disable/revert runtime while retaining history, followed only later by separately approved retention/export/removal. No runtime exists in this slice.

## Remaining decision

Root reviews exact commit/test/review packet and decides any subsequent work. Database123 remains draft/unmerged; no automatic migration, generated type refresh, enabling, scheduler/provider wiring, paid operation or hosted apply is authorized by passing these tests. Catalog's current-request authority observation stays separate from any future stored execution grant.
