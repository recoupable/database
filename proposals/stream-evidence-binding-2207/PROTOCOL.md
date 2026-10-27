# Retained Luminate → Context evidence proposal (#2207)

Status: source/design proposal, 2026-10-27. No migration, production writer,
service grant, provider call, ingestion service or durable adapter is implemented.
`proposal.sql` is an executable **read/lock qualification**, not an activation
script. The private proposal schema denies service/browser execution. Catalog
meaning review and root adoption remain required before runtime implementation.

## Existing sources and exact scope

Database base `6ae03a0cc71dc2ad3955594c9cfcb6156c3fb8b8`; API base
`c1298deb6bb981543bf442d26a32def889e60d71`. The relevant existing migrations are:

- `20260920010000_context_foundation.sql`: sources, versions, attempts, accepted
  results, current documents, `accept_context_result`, `withdraw_context_source`.
- `20260920020000_context_spotify_pipeline.sql`: metadata writer and ordinary
  request document reader. The writer hardcodes Spotify; do not reuse it here.
- `20260922070000_context_catalog_entry.sql` and
  `20260923080000_context_execution_records.sql`: owned catalog request, explicit
  expansion edges and exact `resolve_context_catalog_member_recording`.
- `20261008160000_context_release_cases.sql`: current actor/workspace authorization.
- `20261009193000_catalog_daily_stream_tracking.sql` and
  `20261010040000_catalog_stream_parent_lock_order.sql`: retained daily tuple,
  latest-per-day ordering and current collection lock order.

A global recording subject is not source authority. Require an existing expanded
member of an owned ready request, exact Recoup catalog resource and current
workspace/catalog/ISRC memberships. Never expand a request, infer a UUID, call a
provider or create a recording while resolving a selection. Expanded recordings
are deliberately outside `request.output.subjectIds`.

## Minimal evidence representation

Reuse the existing Context tables; add no observation mirror table or identifier
registry. The suggested source scope is **owner + catalog + recording**, with
`kind=provider_metadata` and server-generated locator
`urn:recoup:luminate-daily:<catalog UUID>:<recording subject UUID>`. It is a retained
evidence locator, not a provider URL or provider identity assertion.

Use topic `luminate_daily_streams_v1:<catalog UUID>`, attempt provider `luminate`,
recipe `retained-luminate-daily-v1`, schema `1`, accepted result evidence kind
`observation`. The attempt records local retention work, not a new provider request
or a claim about historical provider costs. A recording in two catalogs has two
independent source/document scopes even in the same workspace.

One exact source version contains the bounded snapshot; one result links exactly
that version. This preserves up to 62 daily observations without violating the
ObjectRef maximum of 32 source-version IDs. Suggested content/normalized result:

```json
{
  "schemaVersion": 1,
  "catalogId": "<UUID>",
  "subjectId": "<UUID>",
  "isrc": "USAAA2600001",
  "metric": "luminate_all_dsp_worldwide_daily_streams",
  "since": "2026-10-24",
  "until": "2026-10-25",
  "observations": [
    {
      "catalog_id": "<UUID>",
      "isrc": "USAAA2600001",
      "date": "2026-10-24",
      "run_id": "<retained run UUID>",
      "provider_recording_id": "provider-a",
      "source_hash": "<retained opaque hash>",
      "retrieved_at": "2026-10-25T00:00:00+00:00",
      "streams": 100
    }
  ]
}
```

`since` inclusive / `until` exclusive, 1–62 completed UTC days; observations sorted
by date. Preserve all eight tuple fields, including nullable streams. Missing days
stay missing; null is unknown, never zero. Reject empty snapshots and mixed/empty
provider IDs. Run ID must join the same catalog. Latest selection exactly matches
Catalog's `retrieved_at DESC, run_id DESC`, without choosing a convenient older row.
The metric is all-DSP worldwide Luminate daily streams; no rights, royalties,
Spotify-only measure or aggregate catalog totals follow from this evidence.

Use SHA256 of UTC-serialized database JSONB text for **internal version deduplication**
only. Do not confuse it with the retained `source_hash`, or promise equivalence to
JavaScript JSON serialization. Source-version `retrieved_at` records local retention;
each observation's provider retrieval time remains in content.

Minimality tradeoff: one current document per owner/recording/catalog. A newly
accepted snapshot of another window also supersedes the prior current result;
old selections refuse rather than silently refresh. If parallel windows must stay
current, root/Catalog should instead adopt a window-qualified topic before building
the writer. That is a document-currentness choice, not a new evidence store.

## Proposed retention transaction (not implemented by this proof)

1. Trusted API supplies authenticated actor/owner, exact existing request, subject,
   catalog, window, expected current revision and expected observed tuple set.
   Validate strict shapes and byte bounds in the API; do not accept source content,
   provider assertions or owner IDs directly from descriptor payloads.
2. Lock owner account → catalog → song (KEY SHARE), tracking row (UPDATE), actor
   organization membership (SHARE), workspace/catalog then catalog/song memberships
   (SHARE), request/expanded edge/resource/subjects (SHARE). Recheck the exact
   resolver under these locks. Do not require collection `enabled=true` for retained
   evidence. Tracking owner must match the selected owner.
3. Read latest retained observations in the exact bounded window and compare with
   the submitted expected tuples. Corrections arriving since the surface snapshot
   require explicit rebuild/reselection. Reject missing rows, mismatches, mixed
   provider IDs and a changed provider identity relative to this source's retained
   history; a provider identity conflict needs Catalog reconciliation, not a new UUID.
4. Under the tracking serialization lock, find **all** matching source locators,
   including withdrawn sources. Refuse withdrawn, duplicate or ambiguous scope;
   never recreate an active source to bypass withdrawal. Lock source before any
   result/document. Initial creation and retry must serialize here. Existing generic
   metadata/enrichment writers are not authorized for this reserved locator/topic.
5. Insert/reuse the exact immutable version, reject removed versions. Create a local
   attempt/result with trusted content and exactly one lineage link. Use expected
   document revision and `accept_context_result`; failure rolls back all inserts.
   Identical current request/result/version replay can return the same receipt;
   an old receipt cannot restore an old current result. Cross-request reuse must
   retain the original request reference or create an explicitly new result; the
   proof requires the attempt's request to match the authorized request.
6. Return owner/request/subject/catalog, topic, document revision, result ID and
   exact version set. No provider request or collection is dispatched. A failed or
   unknown acknowledgment requires exact receipt reconciliation, not paid retry.

These steps still need executable writer/CAS/retry/rollback tests before activation.
The synthetic fixture deliberately inserts evidence directly to qualify the existing
relations; it is not that production writer and does not prove its idempotency.

## Exact read and durable authorization

`read_binding` demonstrates current actor/member checks and joins the exact result,
version, source, attempt and document revision. It checks snapshot content against
current retained tuples and returns a single redacted JSON null for absent,
inaccessible, unsupported, removed, mismatched or stale evidence. It never drops a
failed version or substitutes latest into an old selection. Operational SQL errors
remain errors; transport must not label them successful empty results.

Future durable calls must hold their adopted session/chat/fence locks **before**
this source boundary. The source boundary locks source/version before result/document,
matching existing withdrawal. No callback from this boundary may acquire chat locks.
The proof refuses isolation levels other than READ COMMITTED, so a preexisting
repeatable-read snapshot cannot hide a correction committed before the tracking lock.
It locks existing run/observation rows against update/delete and exact lineage links;
the result UPDATE lock blocks new lineage links through their FK.
The proof holds tracking before membership and source, matching the supported stream
commit's parent order. It locks mutable request/resource/subject/edge participants
before the existing resolver. Current request output only needs the catalog subject.

Withdrawal uses the existing `withdraw_context_source`: all versions in this
owner/catalog/recording scope become unavailable, results become withdrawn and current
document pointers clear with a revision increment. This proposed scope needs Catalog
acceptance. Collection disable retains evidence. Membership removal refuses future
reads without deleting global identities or retained history. Neither operation
proves removal from chat/export copies. No automatic source restoration is proposed.

## Qualification and limits

Run with a single PostgreSQL installation on PATH:

```sh
python3 proposals/stream-evidence-binding-2207/test_binding.py
```

Sixteen tests passed on local PostgreSQL 15 and 17. The harness creates a new
Unix-socket-only cluster and applies the actual foundation, pipeline, catalog,
execution, access and stream migrations. Synthetic parents and evidence are explicit.
It never reads a hosted DSN. Tests cover exact expanded-member joins, wrong owner/
actor/version/revision, missing memberships/edge/lineage, removed version, tuple
mutation, correction/null/provider-change staleness, explicit corrected version,
withdrawal and disable distinction. Real competing connections show that organization
revocation, catalog membership removal, withdrawal and tracking updates wait for an
authorized transaction. The inherited release-case lifecycle test also runs.

Not proven: production grants/RLS delivery, generic-writer exclusion, arbitrary direct
SQL observation insertion/deletion races, all account/catalog cascade interleavings,
concurrent first retention, writer idempotency/rollback, durable chat composition,
strict API byte/schema validation or provider identity reconciliation. The tracking
lock serializes the existing `commit_catalog_stream_track`; it is not an enforcement
mechanism against direct table writers that bypass it. A runtime release must inventory
and constrain participating writers before claiming that atomic boundary. This is a
qualified proposal with explicit gaps, not production-ready authorization.

Next: root obtains Catalog review of metric/provider conflict/withdrawal scope and
current-window choice; adopt or revise this representation; implement and independently
qualify the trusted retention writer and durable composition. No activation, migration,
provider/customer operation or grant follows from source merge alone.
