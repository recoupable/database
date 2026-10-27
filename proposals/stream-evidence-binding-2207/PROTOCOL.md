# Retained Catalog stream → Context evidence proposal (#2207)

Status: source/design qualification, 2026-10-27. Aligned to the Catalog source
contract adopted by root from API #1187, head
`b185ea9ded070cd6d621d2bf13843bf9df6e5a8f`, merge
`08f62b7474e52b2bd0114d2d2c62c642c17ef6bf`.
[Canonical Catalog contract](https://github.com/recoupable/api/blob/08f62b7474e52b2bd0114d2d2c62c642c17ef6bf/docs/contracts/catalog-stream-evidence-2207/README.md)
and its 31 synthetic vectors govern source meaning. Earlier versions of this
proposal's dynamic topic, different locator and 62-date limit are superseded.

No migration, production writer, service grant, provider call, ingestion service or
live adapter. `proposal.sql` is a private, default-denied **evidence read/lock proof**.
Its fixture inserts are not a retention writer. It does not authorize derived sums,
growth or comparison fields: exact bundle equality is not a result-field validator.
Root and Catalog review the revised exact heads before any further implementation.

## Follow-on offline writer

The [executable retention writer proposal](../stream-retention-writer-2207/PROTOCOL.md)
now exercises the transaction described below outside migrations. It shares the
extracted authority helper and adds logical row/history budgets to this reader.
The original 25 read regressions remain; production writer activation and derived
field authorization are still excluded. The original fixture remains a read fixture,
not evidence that the separate writer ran.

## Existing source authority

Database base `6ae03a0cc71dc2ad3955594c9cfcb6156c3fb8b8`; API inspection base
`c1298deb6bb981543bf442d26a32def889e60d71`, with adopted Catalog contract above.
Relevant Database migrations under `supabase/migrations/`:

- `20260920010000_context_foundation.sql`: sources, versions, attempts, results,
  current documents, `accept_context_result`, `withdraw_context_source`.
- `20260920020000_context_spotify_pipeline.sql` and current metadata replacement
  `20260920040000_context_guests.sql`: Spotify-specific writer; do not reuse here.
- `20260922070000_context_catalog_entry.sql` and
  `20260923080000_context_execution_records.sql`: owned catalog requests, explicit
  expansion edges and exact `resolve_context_catalog_member_recording`.
- `20261008160000_context_release_cases.sql`: actor/workspace authorization.
- `20261009193000_catalog_daily_stream_tracking.sql` and
  `20261010040000_catalog_stream_parent_lock_order.sql`: retained rows, latest-day
  ordering and supported collection lock order.

A global recording UUID is not evidence authority. Require the exact existing
expanded member of an owned partial/completed request; current actor/workspace,
workspace/catalog and catalog/ISRC memberships; exact Recoup catalog resource and
recording binding. Expanded recordings are outside `request.output.subjectIds`.
The reader never expands, invents a UUID, collects or creates a recording.

## Adopted series, topic and current-document behavior

Use existing Context tables. One owned source per catalog/recording/metric scope:

`urn:recoup:retained-catalog-streams:<catalog UUID>:<recording UUID>:all_dsps:worldwide`

The source kind is `provider_metadata`; the locator is internal, not a provider URL
or fetch target. Provider recording ID is version content, never part of this key.
The stable topic is **`catalog_retained_streams`**. Existing document uniqueness
therefore gives **one current document per owner/recording/topic across catalogs
and windows**. A newly accepted catalog/window replaces via revision CAS, making
old bindings stale. No dynamic query topics or simultaneous-current-window promise.

One version contains the full bounded tuple bundle, and one accepted observation
result links exactly that version. This keeps all 732 supported dates within one
of ObjectRef's 32 allowed version IDs. Attempt provider `luminate`, recipe
`retained-luminate-daily-v1`, schema `1` identify truthful local binding work. They
must not imply a provider request, paid collection or confirmed historical cost.

The strict evidence content is reconstructed by the proof, with no additional keys:

- `schemaVersion: 1`, `workspaceId`, `catalogId`, `subjectId`, `isrc`.
- `provider: luminate`, `metric: daily_streams`, `platform: all_dsps`,
  `territory: worldwide`, `timezone: UTC`, `providerRecordingId`.
- `since` inclusive and `until` exclusive span two equal completed UTC periods,
  each 1–366 days (2–732 total dates). `periods` matches Catalog's previous/current
  start/end_exclusive, days and timezone shape.
- Sorted latest-per-date `observations`, with all eight fields:
  `(catalog_id,isrc,date,run_id,provider_recording_id,source_hash,retrieved_at,streams)`.
- Sorted `absentDates` and `nullDates`, kept separate; no synthetic absent tuple.
- `retrievalRange: {earliest,latest}` from included retained observations.

Latest selection is exactly `retrieved_at DESC, run_id DESC`. Select the full set,
then reject invalid lineage; never filter out a bad latest row to choose an older
or convenient provider identity. Every row must join its run's catalog and fall
within that run's **inclusive** since/until range. Collection runs remain at most
62 dates; a comparison bundle can span many runs. Final run status does not erase
earlier committed rows. No-row series refuses; zero and stored null remain distinct.
Mixed provider IDs, blank IDs, non-64-hex hashes and nonfinite timestamps refuse.
Accepted/stale/withdrawn results on the same source with a different retained
provider ID also refuse pending an owning identity-switch disposition.

`context_source_versions.retrieved_at` equals the **maximum included retained
retrieval time**; the range remains in content. Binding time belongs in attempt/
result provenance. Published/source-updated time remains unknown. No fake freshness.
A future writer computes SHA256 of normalized UTC PostgreSQL JSONB text for internal
version deduplication. It is distinct from Luminate's raw payload hash and the
JavaScript surface hash; never claim cross-runtime serialization equality.

## Explicit size limits and field boundary

Proof limits: evidence content at most **524,288 bytes (512 KiB)** in both UTF-8
PostgreSQL JSONB text and `pg_column_size(JSONB)`; returned evidence envelope at most
**786,432 bytes (768 KiB)** by the same two checks. Reject overflow, never truncate
rows, versions or strings. The 732-date test spans 12 runs and fits these limits;
large provider text may still make a shorter bundle refuse.

These evidence limits do not enlarge the existing durable command/source-part caps.
A future API must separately measure the actual outgoing serialized UTF-8 bytes,
and emit only a bounded field projection plus exact references into the descriptor.
Do not copy a large evidence bundle into a capped chat data part or saved controls.
The full evidence read envelope is not a durable mutation command.

The proof requires `normalized_response = version.content` to qualify **evidence
only**. It does not qualify complete-period sums/growth, percentage rounding,
zero-baseline behavior, safe-total overflow or which descriptor field is supported.
Those need the strict writer/result-field validator using existing
`compareSpotifyDailyStreams` semantics before any field ObjectRef is enabled.
Incomplete evidence may be retained without authorizing invented numeric totals.

## Retention transaction design (offline follow-on linked above)

1. Derive actor/owner from trusted authentication; strictly validate exact request,
   subject, catalog, periods, expected revision and observed tuple set. The descriptor
   cannot supply authoritative source content, provider assertions or owner IDs.
2. Hold durable session/chat/fence locks first when composing with a mutation.
   Then owner account → catalog → song KEY SHARE; tracking UPDATE; actor membership,
   workspace/catalog, catalog/song, request/edge/resource/subjects SHARE. Recheck the
   exact expanded-member resolver. Require tracking owner, not enabled collection.
3. Load full current tuples under that boundary; validate all run/identity/shape/
   size and source-meaning checks. Compare expected tuples so a correction requires
   explicit rebuild/reselection. Preserve all nulls/absences. Refuse provider switches
   without an adopted source-owner disposition. Preserve explicit customer-assertion
   corrections; no provider projection silently overwrites them.
4. Find all matching source locators, including withdrawn history, under tracking
   serialization. Refuse withdrawn/duplicate/ambiguous scope; never recreate an
   active source to evade withdrawal. Lock source before result/document. Reserve
   this locator/topic against generic writer paths before activation.
5. Insert/reuse exact immutable version with retained retrieval max. Create a truthful
   local attempt/result and exactly one lineage link. Validate derived fields before
   field authorization. Use expected document revision and `accept_context_result`;
   failure rolls back all inserts. Identical current replay can return its exact
   receipt; an old receipt cannot restore an old current result. Preserve exact
   originating request on reuse, or create an explicitly new result.
6. Return exact result/topic/revision/version receipt. Unknown acknowledgment requires
   receipt reconciliation, not provider retry or implicit collection.

Concurrent first creation, CAS/retry/rollback and receipt behavior are not proven
by this read fixture. The separate executable writer suite now qualifies those
operations offline; runtime integration remains gated.

## Read/lock qualification and withdrawal

`read_binding` requires READ COMMITTED. Otherwise an earlier repeatable-read snapshot
could miss a correction committed before the tracking lock. It authorizes exact
actor/member/request/subject and current result/revision/source/version, reconstructs
the full evidence bundle and compares retained tuples. It returns redacted JSON null
for unavailable/stale/malformed evidence; operational SQL errors remain errors.

Source/version locks precede result/document, matching withdrawal. Result UPDATE
blocks new lineage FK links; existing links are SHARE locked. A new statement
rechecks lineage count after result-lock acquisition, covering an insertion committed
while the reader waited. Existing run/observation rows are SHARE locked against
update/delete. The supported stream commit serializes on tracking. No source→chat
callback or inverted chat lock acquisition is introduced.

Withdrawal uses existing `withdraw_context_source`: all versions/results for that
owned series become unavailable, current pointers clear and revisions advance.
Historical withdrawn locator rows also prevent a replacement active source passing
the reader. Collection disable is not withdrawal. Membership revocation removes
current access without deleting retained rows/global identity. No provider retention
policy, automatic republication or erasure of prior chat/export copies is implied.

## Qualification, limitations and next action

Run `python3 proposals/stream-evidence-binding-2207/test_binding.py` with PostgreSQL
on PATH. It creates a disposable Unix-socket-only cluster, applies actual existing
migrations and uses explicitly synthetic parents/evidence. No hosted DSN is read.
The revised suite has 25 tests; see `VECTOR-COVERAGE.md` for Catalog vector mapping.

The 732-date cap bounds output dates, **not retained correction history or lock
footprint**. Arbitrary direct inserts bypassing tracking are not serialized by this
proof. Runtime work needs participating-writer enforcement, a row/work budget and
fail-closed overflow behavior. No production grants/RLS delivery, all cascade
interleavings, production writer idempotency/CAS/rollback, actual API transport byte
validation, derived field validation or durable chat composition is qualified.

The evidence protocol was adopted in Database #127. Current next work and writer
qualification are recorded in the linked follow-on protocol; root retains review
and activation authority. Source merge alone activates nothing.
