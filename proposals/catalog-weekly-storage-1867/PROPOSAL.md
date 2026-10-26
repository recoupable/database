# Catalog weekly report storage — decision proposal, not implementation

> Historical source-only design at afeb9c2; original snapshot/reviews preserved. Current disabled-only implementation and qualification are in [PROTOTYPE.md](PROTOTYPE.md). Its narrower scope and explicit owner-only dependency grants/policies supersede historical statements below that no SQL or dependency grant changes are included. Wider execution lifecycle remains unimplemented.

2026-10-25. Existing scope: catalog weekly report setup (#1867/#1803). Root selects the final reviewed contract before implementation. This directory is outside automatic migrations and contains no executable migration, runtime code, generated production types, credentials or customer data. No schema was applied, scheduler enabled, provider called or report sent. Sources are pinned in [sources.json](sources.json): Database main `76bad6195b4bd1918284c5ebe49c91f408072ed2`, API main `fd2a46735f572af458d3617f434fcad615d8de3f` (tree `462a405ae253de3bac04b7e475dc24a8044b1334`). Source presence is not proof of deployed schema or permission.

## Recommendation and decision

Use dedicated `catalog_report_schedules`, immutable `catalog_report_schedule_revisions`, mutation receipts and occurrence records. Keep legacy artist schedules separate. Store original principal and exact effective account/workspace/catalog as typed columns; keep authority out of editable prompts. Start future implementation with disabled storage and mocked execution. Enabling remains blocked until principal reauthorization, delivery, membership consistency and side-effect admission contracts pass their own gates.

Root selected this source-proposal direction on 2026-10-25: separate typed schedule/revisions/receipts/occurrences, immutable scope/principal/recipient, actor=effective self-only v1 (no admin override), weekly-only cadence with no catch-up, and disable-before-archive with exact-scope dedupe. This is not SQL implementation or activation approval. Remaining selection: confirm creator-bound control with workspace emergency disable and explicitly accept that a lost/revoked original creator can leave the disabled dedupe slot occupied until a separately designed archive-only recovery is approved. These are concrete proposed choices, not existing policy. No UI guard may be removed based on this document.

## Existing-record reuse evaluated first

| Existing record / actual fields | Why it is not the schedule authority |
| --- | --- |
| `scheduled_actions`: id, account_id, required artist_account_id, title, prompt, schedule, nullable enabled, model, trigger_schedule_id, timestamps. Timezone resides in Trigger; last_run/next_run were removed. | No original principal, selected workspace or catalog. Generic PATCH edits prompt/artist/model. A fake artist or prompt envelope would bypass typed scope. No changes proposed to this table. |
| `catalog_stream_tracking`: catalog_id PK, owner_id, enabled, revision UUID, updated_at. `catalog_stream_runs`: unique(catalog_id,revision,scheduled_day), measurement window/status/coverage. | This is opt-in daily stream collection, one row per catalog, not a report schedule/recipient/principal. Reuse revision fencing and claim pattern, not its rows or execution authority. |
| `context_catalog_cases`: id, owner_id, created_by, revision, timestamps; immutable revisions contain customer-assertion snapshot, actor, input fingerprint, workspace idempotency key. | Private workpapers explicitly do not grant provider execution. Embedding a schedule in snapshot actions would not provide executable ownership or enable/disable semantics. Reuse immutable revision/receipt conventions only. |
| `context_briefs`: owner, request_ids (1–10), purpose, immutable snapshot, idempotency key. | Compiled output/evidence, not recurring control. Existing purpose constraints do not mean arbitrary weekly reports are supported. |
| `scheduled_posts`: account, optional creator, required video_url/platform, publish_at, status, workflow_run_id. | One social publishing operation, not recurrence or catalog authority. Reuse task-id workflow input pattern only. |
| `workflow_runs`: text run ID, required chat_id, terminal status, timings. | Observability after execution; no durable schedule or original catalog principal. Do not create a chat just to obtain a schedule record. |
| `project_tasks`: project, human milestone title/date/assignee/completion. | Human client delivery, not automation. Do not repurpose project access as catalog access. |
| `oauth_account_identities`: (provider_app_id,provider_subject) PK, account_id nullable tombstone, created_at. | Actual stable identity binding exists for the OAuth flow, but is neither a schedule nor a revocable execution grant. Ordinary Privy app authentication does not automatically use it. |

No inspected approved record represents all required fields and lifecycle. This conclusion covers the pinned Database migrations and API generated types/helpers; it is not a live database inventory.

## Exact API-owned boundary to coordinate with Catalog

The Catalog lane owns strict intent, current catalog authority and bounded membership readers in new API files. This proposal adds no competing validator or shared generic task edit. Agree on these logical types before storage implementation; camelCase below is internal, snake_case remains HTTP/SQL. UUID is a validated string, not a new branded public format.

```ts
type CatalogWeeklyReportIntentV1 = {
  kind: "catalog_weekly_report";
  catalog_id: string;
  organization_id: string | null; // required; null explicitly personal
  schedule: string;               // v1: one minute/hour/day-of-week
  timezone: string;               // required IANA zone
};
type CapturedPrincipalV1 =
  | { mechanism: "recoup_api_key"; actorAccountId: string; keyId: string }
  | { mechanism: "privy"; actorAccountId: string;
      appId: string; issuer: string; subject: string };
type CatalogReportStoredScopeV1 = {
  kind: "catalog_weekly_report"; version: 1;
  catalogId: string;
  actorAccountId: string;
  effectiveAccountId: string;
  organizationId: string | null;
  recipientAccountId: string; // equal to effectiveAccountId in v1
};
type CatalogReportExecutionReferenceV1 = {
  taskId: string;
  occurrenceId: string;
}; // internal reference only; no supplied scope or prompt
```

CapturedPrincipalV1 comes from `validateAuthContext(...,{includeVerificationEvidence:true})`, never request JSON, a prompt or cron's credential. Store actorAccountId once in schedule scope; principal subtype fields complete that identity. `version:1` maps to `schema_version=1`; schedule `revision` is a different concurrency counter. Owner is derived as organizationId ?? effectiveAccountId; no caller supplies a separate owner. recipientAccountId is not an email address or proof of verified delivery.

Create/confirm has no client actor/account/artist/prompt/title/model fields. A separate authenticated idempotency key header (UUID) is proposed, not a new authority field. Exact read response remains flat and echoes id, kind, version, catalog_id, organization_id, enabled, revision, schedule and timezone. Do not expose private principal IDs in ordinary UI responses. The public HTTP route/discriminated generic-task integration remains Root/API+Docs ownership; this proposal chooses no route and edits none.

## Principal and current-access qualification

API1159 `VerificationEvidence` explicitly marks executionResources unresolved. Its account/organization observations are historical proof of the allowing branch at authentication, not a permission revision, grant or credential recovery scheme. Schedule revision is not permission revision.

1. **API key:** source has durable `account_api_keys.id`, account, key_hash and nullable expires_at; revocation is row deletion, no explicit revoked flag/version. A future narrow metadata-only selector by stored key ID must require the row still exists, `account=actorAccountId`, a usable key hash exists, and expiry is null or strictly later than current DB time. Never select/return/log raw key or key_hash; no raw credential is persisted here. The existing selector accepts keyHash only and returns full rows, so it cannot be called unfiltered as a substitute. Reassignment/deletion/expiry/error denies. This is proposed current key-liveness verification under explicit schedule consent, not replay of original authentication. It does not authorize downstream providers/resources. Recreated same-ID row or credential rotation is not covered by a nonexistent key generation: immutable key IDs and insert-only identity must be established before enabling, or the mechanism remains blocked.
2. **Privy:** normal `getExistingAccountIdByAuthToken` verifies a fresh token, fetches the subject and maps its first linked email through account_emails. No universal persisted (app,issuer,subject)→account mapping or current subject revocation interface is established by that helper. OAuth's separate binding can prove an existing app/subject maps to the original actor (including null tombstone denial); it has no issuer/revoked/permission-version fields and does not prove current provider identity/session validity. Never invoke `resolve_oauth_account` with saved/unverified emails at scheduled execution: it can bind a missing subject. Never use current email to silently adopt a new account. **Unattended Privy execution remains unsupported** until Root accepts a concrete current-principal resolver/grant policy using actual available mapping and revocation evidence. A stored subject alone or an old JWT is insufficient. A live token must not be archived for reuse.
3. **Current account/workspace/catalog:** require actorAccountId=effectiveAccountId for every v1 schedule; reject overrides even if generic `canAccessAccount` would permit them. After principal continuity succeeds, require explicit selected-workspace access for both original actor and effective account (self-organization or current membership). This proposed extra explicit-workspace restriction deliberately does not let admin/shared-org visibility substitute for selected-workspace membership. Personal scope requires actor=effective in v1. Catalog link must be exactly `account_catalogs(account=owner,catalog=stored catalog)`, not union-visible catalogs. Missing account/catalog/link/membership, read failure, or changed principal denies; no owner replacement.
4. **Plan/delivery/resource gates:** current plan check precedes claim/provider work. Recipient is effective account only; current verified delivery destination and consent must be resolved separately before email. `account_emails` is not assumed to encode verified deliverability. No destination supplied by cron, artist metadata or model. No recipient change on retry. Unavailable delivery/credential/resource contract means explicit blocked result, not success or inferred authority.

DB state transactions must recheck catalog/workspace relations under locks and recheck API-key liveness if that mechanism is enabled. Trusted API still authenticates the current management caller; SQL does not manufacture a credential from actor UUIDs. General org/admin override is excluded from v1 rather than reproduced in ad-hoc SQL. SQL enforces actor=effective. No generic override adapter is implemented or required for this scope.

## Lifecycle and scheduling

- Create under fresh authorization, dedupe by exact scope. Same idempotency key+same strict input returns original acknowledgement after current read authorization; changed input conflicts. A distinct key colliding with an unarchived exact scope returns existing ID only to an authorized reader and a conflict for mutation; it never replaces principal/recipient or changes cadence. UI must confirm exact scope and creator continuity, not treat first enabled task as success.
- Immutable: kind/version, catalog, personal/organization choice, actor, effective account, recipient, principal mechanism/identity, created time. Scope/principal/recipient change requires disabling+archiving old identity and a separately authorized new creation. No generic PATCH, model prompt, account transfer or key substitution may rewrite them. A replacement ID never inherits old receipts or in-flight work.
- Editable only through catalog-specific compare-and-swap command: schedule/timezone and enabled. Every edit increments revision; append exact full configuration snapshot, actor and operation receipt. Disable increments revision immediately and clears next_due_at. It prevents later DB admissions/commits for old revisions; it cannot retract an already-admitted external request.
- Creator-bound management: fresh principal must match captured principal and current scope access to edit/enable/archive. Proposed emergency disable permits another currently authorized workspace member, recording that actor; it never grants enable, adoption or recipient change. Missing original creator authority cannot be repaired by generic administrator credentials. Scope deletion/revocation causes blocked execution, not an automatic schedule transfer.
- Orphaned creator policy: if the original principal is deleted, revoked or unavailable, current workspace members can emergency-disable but cannot archive/re-enable/adopt. The disabled record continues to occupy the dedupe slot, so replacement is blocked in v1. This is an explicit availability limitation for Root selection. A future archive-only recovery requires separate policy/authorization and retained history; no such recovery is implied here.
- Archive requires the record already be disabled at the supplied expected revision; an enabled→archive request fails rather than silently combining the operations. Archive is irreversible soft deletion with revision bump and enabled=false; retained history/occurrences/receipts remain. New creation may then reuse the business dedupe key with a new UUID. No hard-delete endpoint in v1.
- Proposed v1 cadence is exactly five decimal fields `minute hour * * weekday`, minute 0..59, hour 0..23, weekday 0..6; no wildcards in those three positions, aliases, lists/ranges, seconds or subweekly frequencies. Required timezone validated by existing Intl helper. This restricts the new kind only; do not change legacy parser compatibility. Use installed cron-parser for next occurrences with explicit zone, qualify DST behavior rather than assume it. Proposal policy: skipped local times skip that week's occurrence; repeated local time chooses the first instant, one report. Store/claim UTC scheduled instant and a local occurrence key to prevent duplicate repeated-hour delivery. Parser/runtime version must be pinned/tested before enabling.
- New API cron route authenticates with existing validateCronRequest and starts a Vercel Workflow, following catalog-stream-maintenance structure. No Trigger job or per-task Trigger schedule. Cron secret grants dispatch access only; all execution authority is reloaded per task ID. Pagination bounded to 100 due rows/page, maximum pages/run to be qualified; deterministic `(next_due_at,id)` cursor, continue next sweep if cap reached.
- One atomic claim for a due schedule: lock current schedule, check enabled/current revision/current authorization, insert unique occurrence, advance next_due_at to first future instant. No overdue catch-up occurrence is eligible: only a due instant in the current UTC minute may be admitted; earlier slots are skipped with a recorded reason. This deliberately sacrifices delivery on a missed sweep rather than sending a backlog. The one-minute dispatch window is a proposed runtime detail requiring qualification before scheduler implementation; the selected minimum offline prototype has no scheduler or enable operation. Revision changes choose next strictly future occurrence, not an immediate report. Candidate due values are checked against persisted next_due_at; caller cannot invent a period.
- Dispatch is a separate one-shot claim on the occurrence. Persist attempt ID before `start`; exact replay observes its recorded status and cannot start again. Ambiguous start has no automatic lease stealing/retry. Bind returned run ID to original attempt; if unavailable, record ambiguous/blocked until a separately qualified reconciliation establishes the outcome. This favors missed delivery over duplicates without claiming exactly-once external effects.
- Workflow accepts task/occurrence IDs only, rereads stored record, validates returned IDs, enabled, revision, scope and original principal, and reauthorizes before protected steps/retries. No trusting worker-supplied catalogId, broad worker credential or serialized historical auth result. A persisted receipt replay is never fresh permission to send again.
- Membership is current catalog_songs for the stored catalog, including creator-less/non-roster tracks. Catalog lane owns deterministic bounded read, completeness/change detection and observation semantics. Do not add artist enumeration or equate catalog membership with rights. Until qualified, occurrence remains blocked before provider/report work. A snapshot/fingerprint is evidence, not a global membership permission version.

SQL transactions provide serial order for control/state admission; an external request cannot be held atomically with a DB transaction. Future side-effect integration must define its own admission point, current recheck and idempotency receipt. Disable/revoke after admission cannot promise cancellation of a request already sent. Ambiguous delivery must not automatically resend; provider idempotency and reconciliation are a separate acceptance gate.

See [SCHEMA.md](SCHEMA.md) for exact proposed columns/constraints and [QUALIFICATION.md](QUALIFICATION.md) for commands, tests and rollback gates. These documents are a reviewable contract, not evidence that those gates pass.
