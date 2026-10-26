# Proposed v1 typed storage and transaction contract

> Historical source-only design at afeb9c2; original snapshot/reviews preserved. Current disabled-only implementation and qualification are in [PROTOTYPE.md](PROTOTYPE.md). Its narrower scope and explicit owner-only dependency grants/policies supersede historical statements below that no SQL or dependency grant changes are included. Wider execution lifecycle remains unimplemented.

Design only. No executable SQL or generated API type change is included. Names below are proposed API/DB contracts, not existing RPCs. SQL implementation must remain outside automatic migrations until separately selected and approved.

## `catalog_report_schedules`

All columns NOT NULL unless marked nullable. IDs are UUIDs. Timestamps are timestamptz. UUIDs identifying accounts/catalog/principals are immutable historical identity values, deliberately **not cascading foreign keys**: revocation or deletion must remain possible while retaining audit. Each operation checks existence/current relation; retained UUID is never access proof. This design chooses no FK to mutable external identity tables rather than RESTRICT blocking account/catalog deletion or SET NULL erasing original identity. The internal schedule/revision/occurrence FKs below are enforced.

| Column | Type/default and constraint | Mutability |
| --- | --- | --- |
| id | uuid PK, server gen_random_uuid() | immutable |
| kind | text, CHECK = 'catalog_weekly_report' | immutable |
| schema_version | smallint, CHECK = 1 | immutable |
| actor_account_id | uuid | immutable original actor |
| effective_account_id | uuid, CHECK = actor_account_id in v1 | immutable |
| organization_id | uuid nullable; explicit null = personal | immutable |
| owner_id | uuid GENERATED ALWAYS AS (coalesce(organization_id,effective_account_id)) STORED | derived immutable |
| catalog_id | uuid | immutable |
| recipient_account_id | uuid, CHECK = effective_account_id | immutable |
| principal_mechanism | text CHECK IN ('recoup_api_key','privy') | immutable |
| api_key_id | uuid nullable | immutable |
| privy_app_id | text nullable, 1..200 chars when present | immutable |
| privy_issuer | text nullable, 1..500 chars when present | immutable |
| privy_subject | text nullable, 1..300 chars when present | immutable |
| revision | integer default 1, CHECK BETWEEN 1 AND 2147483647; reject edit at max | controlled increment |
| schedule | text 1..64 chars; anchored v1 weekly grammar below | controlled edit |
| timezone | text 1..100 chars; nonblank; API validates IANA and RPC validates allowed zone | controlled edit |
| enabled | boolean default false | controlled edit |
| next_due_at | timestamptz nullable | scheduler-owned cursor |
| archived_at | timestamptz nullable | null→server timestamp once |
| created_at | timestamptz server clock_timestamp() | immutable |
| updated_at | timestamptz server clock_timestamp() | controlled |

Principal CHECK is an exact exclusive union: API-key mechanism requires api_key_id nonnull and all privy fields null; Privy requires all three privy fields nonnull and api_key_id null. No auth token, raw key, secret reference, emails or arbitrary principal JSON. Schema stores Privy provenance without claiming unattended support.

Schedule CHECK: `^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) \* \* [0-6]$`; normalize decimal representation at strict input validation before idempotency comparison. Timezone is not checked by an immutable CHECK querying a system catalog. Proposed mutation RPC checks pg_timezone_names plus API Intl/parser agreement; ambiguous aliases/DST outcomes fail closed until the common policy is tested. No arbitrary cron accepted for this kind.

State CHECKs: archived_at nonnull implies enabled=false and next_due_at null; enabled=false implies next_due_at null; enabled=true implies archived_at null and next_due_at nonnull. No CHECK against now() on persisted rows. Revision/cursor changes use expected values in RPC, not caller-provided updated_at. current revision must have its immutable revision row before commit (deferred composite FK described below).

Business dedupe: partial UNIQUE INDEX with NULLS NOT DISTINCT on `(kind,effective_account_id,organization_id,catalog_id)` WHERE archived_at IS NULL (PostgreSQL15+ qualification required). Null workspace must not collapse into organization_id=effective_account_id; explicit contexts remain distinct. Disabled schedules occupy the slot. Principal/actor are not omitted accidentally: this policy intentionally prevents a second creator from silently installing a competing report for the same recipient/scope. Collision means conflict, not principal replacement. UUID PK is the task ID; title/catalog name never identity.

Due index: `(next_due_at,id)` WHERE enabled AND archived_at IS NULL. Read pagination index: `(owner_id,created_at,id)`; API access remains checked independently.

## `catalog_report_schedule_revisions`

Append-only configuration history. PK `(schedule_id,revision)`; FK schedule_id→schedules.id ON DELETE RESTRICT. Schedule row has deferred FK `(id,revision)`→revision PK so the current snapshot exists atomically.

Columns: schedule_id uuid, revision integer positive; changed_by_account_id uuid (historical, no external FK); operation text CHECK IN ('create','edit','enable','disable','archive'); schedule text and timezone text with same shape checks; enabled boolean; archived_at nullable timestamptz; created_at server timestamptz. No next_due_at here: cursor advancement is not a user configuration revision. Full immutable scope/principal remains on the parent, so history cannot swap it. Snapshot state checks mirror enabled/archive checks excluding cursor. RPC checks operation transition, expected revision and current caller; insertion privilege alone is not authorization.

## `catalog_report_mutation_receipts`

Append-only exact mutation retry receipts, not generic execution permissions.

Columns: `actor_account_id uuid`, `request_id uuid`, `schedule_id uuid` FK→schedules.id RESTRICT, `revision integer` with composite FK(schedule_id,revision)→revisions, `operation text` same five values, `input jsonb` CHECK object and octet_length(input::text)<=16384, `created_at timestamptz`. PK `(actor_account_id,request_id)`.

`input` is the strict normalized command (scope, captured non-secret principal for create; target ID, expected revision and exact edited fields otherwise). It excludes tokens/keys/hashes/prompt/content. It is bounded typed command evidence; never parsed as authority. SQL compares exact JSONB values (including required null workspace) on retry; no hash-only equivalence. API strict validation rejects extra fields/NUL/lone surrogate values before persistence. SQL independently validates keys/types/required fields and compares captured principal to the authenticated management context supplied by trusted API.

SQL-generated receipt is reconstructed from immutable revision plus parent identity: `{id,kind,version,catalog_id,organization_id,revision,enabled,schedule,timezone}`. Repeat after later revisions returns the historical result with an explicit `replayed:true`; UI separately refetches current state before showing enabled status. Current read authorization is required before revealing history. Changed input under same key → 22023; stale expected revision → 40001; never reinterpret as a new request or auto-adopt current revision. Another actor using same UUID cannot retrieve this actor's receipt.

## `catalog_report_occurrences`

Durable unique execution identity and bounded outcome, separate from schedule control.

| Column | Type/default/constraint |
| --- | --- |
| id | uuid PK, server generated |
| schedule_id | uuid FK→schedule RESTRICT |
| schedule_revision | integer, composite FK(schedule_id,schedule_revision)→revisions |
| due_at | timestamptz; original persisted scheduled UTC instant |
| local_occurrence | text 16 chars, `YYYY-MM-DDTHH:MM` shape; computed by trusted schedule calculator and RPC checked against timezone/due_at |
| status | text CHECK IN ('pending','dispatching','running','complete','blocked','failed','skipped','ambiguous') |
| dispatch_attempt_id | uuid nullable, UNIQUE when nonnull; generated server-side before dispatch |
| workflow_run_id | text nullable 1..500 chars, UNIQUE when nonnull |
| reason | text nullable CHECK IN ('authorization_unavailable','authorization_denied','disabled_or_revised','schedule_archived','membership_unqualified','delivery_unqualified','missed_window','dispatch_unknown','execution_failed') |
| created_at | timestamptz server clock_timestamp() |
| finished_at | timestamptz nullable |

UNIQUE(schedule_id,due_at) AND UNIQUE(schedule_id,local_occurrence). Do not include revision in these uniqueness keys: editing around the same occurrence must not create another delivery. The local key prevents fallback-hour double dispatch. It is an occurrence identity, not the report's measurement window; Catalog defines period semantics separately. Different schedule IDs after explicit archive/recreate are different user intents; v1 never backfills, reducing accidental same-window repeats without claiming global email dedupe.

State shape: pending has null attempt/run/finished/reason; dispatching has attempt, null run/finished/reason; running has attempt+run and null finished/reason; complete has attempt+run+finished and null reason. skipped has finished and reason=missed_window, no attempt/run. blocked/failed/ambiguous require finished+reason; ambiguous requires attempt and reason=dispatch_unknown. run implies attempt. Failure/block may retain original attempt/run for audit. RPCs enforce legal transitions and keep attempt/run immutable once set. Ambiguous→running is allowed only by separately qualified original-attempt reconciliation; no timeout-steal operation is proposed. Terminal occurrence is not restarted as a new occurrence under same key. A future report artifact/delivery receipt schema is out of this storage selection and remains an execution gate, not an arbitrary JSON slot here.

## Proposed commands, authorization and locks

No RPC is implemented. Suggested typed wrappers belong under lib/supabase/catalog_report_schedules or catalog_report_occurrences; domain code must not import serverClient directly.

| Operation | Exact essential input | Transaction result / rule |
| --- | --- | --- |
| create | server verified management context, request UUID, strict intent+captured principal, enabled=false | current scope check, business-key lock, immutable parent+revision1+receipt in one commit; zero downstream calls |
| read/list | authenticated actor, exact task ID or owner/cursor | current scope and reader checks, no union visibility fallback; scoped cursor required |
| edit/enable/disable/archive | current management context, task ID, request UUID, expected revision, allowlisted change | authority then receipt replay or CAS, revision row+receipt atomically; enabling requires all capability gates |
| claim_due | trusted dispatcher, task ID, expected revision+expected next_due_at | reread scoped row and principal; insert one pending or skipped occurrence, advance cursor; duplicates return existing occurrence with dispatchAllowed=false |
| claim_dispatch | task+occurrence IDs, server attempt UUID | reauthorize/current enabled+revision, pending→dispatching once; duplicates cannot authorize start |
| bind_run | original task+occurrence+attempt+returned run ID | bind exact original attempt once; mismatch conflicts; no adopting a newer attempt |
| read_execution | task+occurrence IDs only | verify identity relation/revision/status, reauthorize original principal/scope/plan; return trusted typed scope or explicit blocked result |
| finish/block | task+occurrence+attempt/run as applicable, controlled result | current original identity; no caller-supplied scope; preserve historical outcome; complete needs future required report/delivery acknowledgements |

Read-committed isolation required for these control transactions. Lock existing account parent rows sorted by UUID, catalog parent, API-key metadata row if supported, current membership rows sorted, exact account_catalogs row, then schedule, then occurrence. Parent rows FOR KEY SHARE, relation/key authorization rows FOR SHARE, schedule/occurrence FOR UPDATE. Do not hold DB locks across external calls. All mutation paths must use the same order. Acquire business-key advisory transaction lock for create collisions, with full tuple equality still enforced by unique index. Recheck state after locks. Account/catalog deletion or membership/key removal waits for already-admitted DB transaction, then subsequent admissions deny. This is a DB transaction boundary only; current external effect authorization needs its own gate.

Avoid deadlocks by acquiring receipt-key advisory lock in a single documented order before business-key/row locks; implementation tests must cover repeated keys targeting different schedules. Replays check current access, then exact immutable original input, never implicitly allow a new effect. Archive rejects enabled rows; caller must first disable with its own CAS/receipt, then archive the disabled revision. SQL validates not-null actor/IDs and arrays rather than relying on SQL three-valued comparisons. Counter overflow fails closed.

Access proposal: RLS enabled on all four tables; revoke all table/function access from PUBLIC, anon and authenticated. Use a narrowly scoped NOLOGIN owner for new SECURITY DEFINER RPCs, fixed empty search_path, schema-qualified objects and no dynamic SQL; service_role receives EXECUTE only on the explicit RPC allowlist, not direct mutation/TRUNCATE. The owner gets only required row-lock/read privileges on dependency columns, explicitly audited for side effects. Definer permissions do not replace current caller or original principal checks. This follows the bounded proposal approach of Database122, not a change to existing grants. Cron and authenticated API share service execution infrastructure, so SQL trusts verified caller context only from server code; no browser can assert an actor to these functions.

No grants on legacy tables are changed. No trigger on shared accounts/catalogs/keys is added by this proposal. Therefore immutable key-ID continuity, membership observation consistency and current-principal resolution remain explicit pre-enablement requirements, not implied protections.
