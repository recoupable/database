# Executable retained-evidence writer proposal (#2207)

Status: offline source qualification, 2026-10-27. Based on adopted Database #127
merge `7160086321f16db8a1d4f09c721d3928ade042f6` and API #1188 merge
`d9683853c8471423c5aa763bf60270bee5b89ff7`. The adopted Catalog source contract and
[exact evidence read protocol](../stream-evidence-binding-2207/PROTOCOL.md) remain
in force. This adds an executable writer, not a fixture-only writer claim.

Everything stays outside migrations in the private `stream_binding_proposal` schema.
Schema usage and all functions remain revoked from public, anon, authenticated and
service_role. No runtime call site, grant, provider request, collection, customer
operation or deployment is introduced. Root owns merge and activation approval.

## Writer and receipt storage

Load the read proposal first, then `writer.sql`. `retain(actor,owner,request,subject,
catalog,key,expected_revision,evidence)` takes trusted authenticated scope and the
exact expected evidence bundle, never a provider fetch request. It validates the
bundle through the adopted reader before success. All inserts and the document
revision change roll back if final validation or receipt persistence fails.

No receipt store or observation mirror is added. Existing records hold:

- `context_attempts.module = retained-binding:<key>`, attempt 1: retry identity
  scoped to the exact owned request. Keys are 1–100 ASCII letters/digits/underscore/
  hyphen. Current Catalog request scope prevents cross-catalog key ambiguity.
- `context_results.reuse_key`: SHA256 of UTC PostgreSQL JSONB text for
  `[owner,request,subject,catalog,key,expected_revision,evidence]`. A changed command
  under the same key conflicts, including a changed expected revision.
- `context_results.validation.retentionReceipt`: immutable writer receipt with
  owner/request/subject/catalog, key, commandDigest, resultId, sourceVersionId and
  committed document revision. The writer sets it before returning success.
- `context_source_versions.fingerprint`: separately computed content-only hash.
  Different command keys may reuse the same exact version while creating their
  own attempt/result/receipt and advancing the document revision. Deduplication is
  at the immutable evidence-version level, not by overwriting an earlier receipt.

Provider `luminate` and recipe `retained-luminate-daily-v1` identify local retention
of existing observations. Attempt times are local binding times. Provider cost
remains unknown, with no confirmed zero or invented provider request ID. Version
retrieved_at remains the latest included retained observation time.

`reconcile_retention(actor,owner,request,key)` performs no writes and returns the
original receipt only after exact current authority/readback. Lost acknowledgments
can therefore be reconciled without repeating collection or creating another result.
An exact retry takes the same path. Superseded, corrected, withdrawn, removed,
revoked or over-budget bindings return redacted JSON null; the original commit may
still exist historically, so null does not prove it never committed. Do not retry
with a new key automatically. No stale receipt substitutes a newer version.

Unavailable/invalid evidence returns JSON null and rolls back tentative changes.
Changed command keys and revision mismatches raise explicit command/revision conflict
errors. Operational SQL errors propagate and roll back the statement; they are not
converted to a successful empty receipt. Actor is excluded from the command digest
so another currently authorized workspace actor can reconcile the same owned request.

## Transaction and lock behavior

The adopted authority sequence is extracted to `lock_scope`, shared by read and
write: READ COMMITTED only; owner account → catalog → song KEY SHARE; tracking
UPDATE; actor/workspace, workspace/catalog, catalog/song and request/expanded-edge/
resource/subject checks and SHARE locks. It reuses the exact expanded-member resolver.
There is no implicit expansion or identity creation.

Tracking serializes competing retention commands for the catalog and the supported
`commit_catalog_stream_track`. Source lookup includes withdrawn history; duplicate or
withdrawn scope refuses. Source UPDATE precedes version and document locks. The
stable `catalog_retained_streams` document unique key serializes first creation and
replacement across different catalogs, even though they have different tracking and
source locks. Expected revision is checked while holding the document UPDATE lock.

The writer refuses a current customer_assertion before insertion/acceptance. It does
not lock an old result after taking the document lock: that would invert withdrawal's
source → result → document order. Participating writers treat existing evidence and
receipt contents as immutable. Generic/direct mutations are outside this proof.

The writer inserts/reuses the version, writes the local attempt/result/link, calls
existing `accept_context_result`, then calls the adopted `read_binding`. That final
check verifies exact retained tuples, run/date/hash/time/provider history, closed
schema, byte bounds, current result/revision and full version set. Receipt persistence
follows that check, in the same transaction. A function exception subtransaction
rolls back the entire tentative save on refusal. Synthetic trigger injection verifies
that even a failure at the final receipt update leaves no partial save.

Future durable composition must acquire session/chat/fence locks before this boundary.
No source function calls back into chat locking. This proposal does not implement
that composition or a durable API endpoint.

## Logical work budgets and overflow

`within_budget` is shared by writer preflight and the adopted reader. After holding
tracking, it limits matching retained history in the requested 2–732-date window to
4,096 rows and 8 MiB of measured row/string data. For the exact owned source locator,
it permits at most 256 versions / 8 MiB of JSONB-text content and 512 result-source
links. It inspects at most limit+1 matching rows for each count. The existing
catalog/ISRC/date index and source/version indexes support these predicates.

Refuse overflow, never delete old history, truncate tuples, bypass versions or hide
lineage to fit. Post-insertion readback repeats these checks, so a writer that would
create version 257 or link 513 rolls back. Exact retries and reconcile also refuse if
current history exceeds the adopted read budget. The existing 512 KiB evidence and
768 KiB response bounds remain separate. Durable command/data-part limits are not
increased.

These are logical matched-row/byte refusal budgets, **not hard physical scan, CPU,
wall-clock or memory ceilings**. PostgreSQL can scan unrelated rows, and evaluating
an existing oversized JSON value can materialize it before refusal. No statement
or lock timeout is installed by this proposal. Runtime adoption still needs an
execution deadline/work policy and query-plan qualification. No claim of universally
bounded database execution follows from the row caps.

## Participating writers and enforcement boundary

The following inventory is based on the adopted Database source, not hosted grants:

| Path                                                                                          | Participation / enforcement                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Proposed retain/read/reconcile                                                                | Share exact scope helper and tracking lock; immutable evidence plus existing CAS; default-denied application execution.                                                                        |
| `commit_catalog_stream_track`, current `20261010040000` body                                  | Locks the same parent/tracking/member rows before inserting observations. Real concurrent test verifies contention, and actual correction commit invalidates old receipt.                      |
| `withdraw_context_source`, foundation                                                         | Source UPDATE then results/documents. Held replacement blocks withdrawal; subsequent withdrawal denies retries and new bindings without resurrection.                                          |
| Current membership delete/update                                                              | Conflicts with held SHARE rows; later calls reauthorize and refuse removed access.                                                                                                             |
| Generic `save_context_metadata` (`20260920040000` replacement)                                | Takes arbitrary topic/URL, uses active-source lookup and Spotify-specific provenance. It is not admitted to this reserved source/topic protocol. No deployment claim that it is blocked today. |
| `complete_context_enrichment` (`20260923070000`) / current claim allowlist (`20260924020000`) | Existing provider workflow, with different topic/output checks and write ordering; not a retained-stream writer.                                                                               |
| Release/artist/catalog/supporting-text/campaign entry and identity writers                    | Write other source/topic families. Must remain excluded from this reserved topic/locator; no implicit delegation to them.                                                                      |
| Direct service SQL, generic source/result updates and administrative deletion                 | Existing foundation and stream migrations grant broad service table access. These can bypass the tracking protocol and immutable-content assumption. Explicitly outside atomicity proof.       |

Enforcement **inside this offline proposal** is the default-denied schema/functions,
mandatory shared helper, lock/CAS/readback, and rollback tests. This does not enforce
the allowlist against privileged direct writers. Before any shared runtime claim,
root must inventory current deployed writers and adopt a permission or guarded-write
mechanism that reserves this source/topic and observation write path. No GUC flag,
caller boolean, advisory-lock convention or unreviewed production grant is offered
as proof that privileged bypass is prevented. Current atomicity claims apply only
to the participating operations above.

## Evidence and remaining work

Run `python3 proposals/stream-retention-writer-2207/test_writer.py` with one PostgreSQL
installation on PATH. The runner applies actual existing migrations and both proposal
files in a fresh Unix-socket-only cluster. It runs all 25 adopted read regressions
plus 20 writer tests (45 total). Synthetic baseline parents and expected bundles
remain explicit; all writer outcomes come from executing `retain`/reconcile, not
manual insertion of the result under test.

Writer cases cover first creation; identical retry/reconcile; changed command and
revision conflict; same-key and different-key races; cross-catalog first creation and
replacement CAS; version dedup with separate receipts; prior-document preservation;
customer correction/removed-version refusal; withdrawal/revocation and provider
history; actual stream commit correction; late receipt fault rollback; real held
writer contention with supported mutators; row/byte/history/link budgets and denial
of application execution. No provider data or hosted credentials are used.

Still excluded: derived totals/growth and field authorization, actual API serialized
byte checks, durable chat composition, production permission enforcement, all parent
cascade interleavings, deployment and live customer outcomes. Catalog supports future
field semantics through the canonical comparison helper; do not duplicate that
comparison calculation in SQL. Root reviews exact source, independent review and
PG15/17 CI before deciding the next scope. Source merge activates nothing.
