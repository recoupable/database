# Retained video projection — inactive local-source proposal

This implements the accepted CE15 source plan using three proposal-schema functions and existing Context tables. The fixture producer is synthetic. No production producer, runtime registration, migration or spending authority is supplied.

## Local qualification

Run from this Database checkout with an explicit local PostgreSQL binary directory:

```sh
PG_BIN=/opt/homebrew/opt/postgresql@15/bin python3 proposals/context-retained-video-2131/test_retained_video.py
PG_BIN=/opt/homebrew/opt/postgresql@17/bin python3 proposals/context-retained-video-2131/test_retained_video.py
```

The runner requires the pinned #107 Git object locally; it will fail closed without fetching if absent or mismatched. It verifies source hashes before PostgreSQL startup, then applies real prerequisite SQL in two separate owned databases (normal and final-main-overrides compatibility). The copied #138 runner machinery is a source reference, not a dependency on Application admission or an inherited qualification pass. No database URL is accepted. All fixture-only grants and synthetic setup are outside retained-video.sql.

Use `VIDEO_QUALIFICATION_FAULT=source-export|signal|timeout|worker-exit` with the same command to exercise failure cleanup. Each is expected to exit nonzero while emitting owned cleanup/removal receipts. The worker-exit fault deliberately leaves a child for the supervisor to quiesce. Uncatchable SIGKILL/host loss is not claimed automatically recoverable. Ambiguous identity preserves the owned directory and reports it. A macOS signal permission error is accepted only after bounded independent group-absence checks; a still-present or unverifiable group remains a failure. Postmaster and socket cleanup are checked separately.

Every negative SQL assertion requires its exact parsed verbose server SQLSTATE; injected trigger faults also require their exact message. Only psql ON_ERROR_STOP script-error exit 3 with one ERROR diagnostic becomes SQLFailure. Executor, connection, signal, timeout and unclassified failures remain separate and cannot satisfy a denial. Negative controls exercise actual missing socket/executable failures and unexpected server states.

PostgreSQL tests exercise actual service-role calls, transaction rollback, exact replay, CAS, source withdrawal/removal, strict envelopes, 32-source and exact 4 MiB boundaries, both locator rejection/deletion lock orderings with observed blocking PIDs, related mutation locks, and browser/default-service denial. The original #107 SQL fixture runs unchanged and its rollback is checked afterward. Generic enrichment function definitions are compared before/after proposal installation, and video_narrative remains rejected by the real claim. No paid execution/accounting tables are created or changed by this proposal.

## Decision and exact source boundary

This implements an **inactive proposal**, outside `supabase/migrations`, which saves and reads a deterministic video-only projection of already retained evidence. It links original `context_source_versions.id` values directly through `context_result_sources`; it never inserts or updates source versions. Source retention/collection itself remains a separate dependency. Synthetic fixtures supply actual retained rows in a disposable database; they do not prove that such rows exist in production.

Base: Database `7708e337feca212563bdfa48934a72227bcf1b63`. Compose the exact locator migration from open #107 `23262f99d2a6c010f00c459a4b1814d6623c3843` in disposable qualification only. API projection/schema reference is merged `21d9971c9e6152cf11fedbe8de0402e1fc806591` (#1276). All 23 exact file hashes are in `sources.json`, including the six previously omitted chain migrations, #107 SQL fixture and actual #138 runner source. No Database AGENTS.md exists in the base tree or the inspected owning checkout; Mono AGENTS.md governs.

Open #138 `f507a77696f20429f977df9885d6c8c11a5f304b` and #139 `acea75c0e118b6ca12bb9a22470a8bd7b383f925` own the Application 2104 proposal directories. They are not video admission infrastructure. Do not change their files, branches, worktrees, registration policies, qualification runs or claims. A copied runner safety pattern is not a dependency on their application contract or an inherited test pass.

Existing API #1019 `ce28c4481ac00bd0a28bd686f3224c6ee8375a33` remains the only proposed video intake. Do not duplicate it. #107 is still open. The associated documentation #366 belongs to archived `recoupable/docs-legacy`; a future release must reconcile current Docs separately.

## Files and dependency order

All new implementation files belong under `proposals/context-retained-video-2131/` in Database:

1. `CONTRACT.md`: this reviewed contract, limitations, exact commands and rollout gates.
2. `retained-video.sql`: three proposal-schema functions below; no new tables, triggers, public RPCs or production grants.
3. `qualification-bootstrap.sql`: minimal synthetic legacy tables/roles needed by real prerequisite SQL, explicitly not a full historical migration replay.
4. `fixtures.sql`: actual transactional positive/negative save/read assertions and synthetic retained evidence.
5. `test_retained_video.py`: owned disposable PostgreSQL runner, source composition verification, concurrency and process-cleanup assertions.
6. `sources.json`: exact commits, paths, blob SHA-256, ordered qualification dependencies and runner-copy provenance.

No migration path is included in this contribution. A future migration name and public grants require a separate release review; moving this file into the auto-applied migration directory is not a routine follow-up.

Qualification order is bootstrap, then the real main migrations listed below, then #107's exact locator migration, then `retained-video.sql`, then fixtures. Resolve duplicate prerequisite filenames once, never edit their contents:

```
20260920010000_context_foundation.sql
20260920020000_context_spotify_pipeline.sql
20260920030000_context_enrichment_pilot.sql
20260922070000_context_catalog_entry.sql
20260924040000_context_release_entry.sql
20260925100000_context_songwriter_name_entry.sql
20260925110000_context_company_name_entry.sql
20260925120000_context_campaign_brief_entry.sql
20260925130000_context_supporting_text_entry.sql
20261008030000_onboarding_membership_lock_privilege.sql
20261008160000_context_release_cases.sql
20261010213100_context_video_entry.sql  # exact #107 blob, not main
```

This is the existing locator qualification chain plus actual attempt-input and membership authorization prerequisites. PL/pgSQL bodies not exercised by this slice are not qualified merely by loading their definitions. The separate compatibility profile applies the same ordered prerequisite chain above, then `20260923070000_context_enrichment_scope.sql`, then `20260927090000_context_audio_source.sql` from pinned main, then the proposal SQL and fixtures. These final overrides intentionally run after the base chain in this isolated compatibility profile so the final definitions are explicit. Capture function definitions after overrides and compare before/after the proposal, and execute the real final claim with a valid in-scope video subject/module to prove `video_narrative` still rejects without creating an attempt. The normal profile applies the base chain then proposal/fixtures. Neither profile rewrites migration text. `sources.json` → `qualification` records both exact ordered lists and their source-index references. Any necessary bootstrap adjustment must be recorded, not silently patched into migration text. Extract #107's blob by exact commit from the owning repository and verify its recorded digest before SQL; no ambient branch fallback or automatic network fetch in the runner.

## Functions and input contract

Proposal namespace: `context_retained_video_2131`. All functions SECURITY INVOKER, `SET search_path=''`, fully qualified relations. Revoke PUBLIC/anon/authenticated/service_role execution and schema access in proposal SQL. Only the disposable fixture explicitly grants the existing synthetic service role schema usage/function execution. Nothing in this contribution exposes a production entry point.

```sql
context_retained_video_2131.load_retained_evidence(
  p_actor uuid, p_owner uuid, p_request uuid, p_snapshot_version uuid
) returns jsonb;

context_retained_video_2131.save_projection(
  p_actor uuid, p_owner uuid, p_request uuid, p_snapshot_version uuid,
  p_key text, p_expected_revision bigint
) returns jsonb;

context_retained_video_2131.read_projection(
  p_actor uuid, p_owner uuid, p_request uuid
) returns jsonb;
```

The snapshot version is an **existing retained full-evidence snapshot**, not a newly created object containing only references. Its `content` is the exact API `ContextVideoEvidence` envelope. Its `media_manifest` has a required `contextVideo` object `{contractVersion:"retained-video-evidence-v1", requestId, videoSubjectId, videoId, mediaVersion}`. All referenced versions must already exist, have the same owner, and carry the same binding. The snapshot ID must itself occur exactly once in `content.sources`. A producer can allocate its UUID before retaining the snapshot; this proposal does not implement that producer or mutate a retained snapshot to insert its ID later.

This is a new **proposed retained-producer format**, not a claim that current production sources already satisfy it. Existing locator snapshots do not satisfy it. Missing content, reference-only content, unrecognized manifests or absent retained rows fail closed. For this proposed snapshot format, require its fingerprint to equal SHA-256 of the UTF-8 PostgreSQL JSONB content serialization; record that format-specific convention explicitly rather than applying it to every legacy source kind. Do not create wrapper source versions to make old data pass. The accepted source-implementation scope explicitly includes this absent producer prerequisite; if the desired outcome includes first-time raw evidence retention, commission that separate source-producing contract rather than mislabel this projection writer as ingestion.

Loading locks and checks the authenticated actor using existing `public.authorize_context_case_actor(actor,owner)` first. The actor must originate from trusted authentication in any future caller; an actor UUID alone is not authentication. Personal owner access follows that existing metadata policy only. No Application #138 entitlement is substituted. Then lock the request FOR SHARE and require owner, `input.kind=video`, partial/completed status, exact YouTube resource/provider ID and a single output video subject for that resource. Lock the exact resource row and then the video subject row FOR SHARE and recheck their IDs, provider/kind/provider ID and subject-resource relationship. Next select the target `context_resource_links` row for that exact resource/subject and relation `identity` FOR SHARE. Do not filter only on `status=accepted` and assume a previous optimistic observation remains valid: require an actual locked row and explicitly recheck its current ID, resource, subject, relation and `status=accepted` after lock acquisition. Missing, deleted, replaced, rejected, candidate or conflicting bindings fail closed with controlled unavailable/permission error and no evidence payload. Never interpret this locator link as artist or recording identity.

The uniform row-lock order is membership → request → resource → video subject → target locator link → sources/versions (sorted source-ID/version-ID) → document. Save's operation advisory lock remains after the loader's row locks and before document locking. Preserve all these transaction locks through commit/rollback; never release them between helper validation and save/read/replay. The proposal targets the existing READ COMMITTED behavior. Serialization/deadlock/lock-timeout errors fail the whole call; they are not authorization or permission to bypass a check. The target link uses FOR SHARE, not FOR KEY SHARE: status changes must conflict with the held lock. A concurrent UPDATE or DELETE must wait if the authorized operation acquired its lock first. If rejection/deletion commits first, a waiting operation must inspect the locked current row (or missing row) and refuse. It must not return an optimistic pre-wait status. Resource/subject locks similarly prevent the validated locator tuple from changing during the operation.

Read the snapshot optimistically without a row lock, validate the complete bounded envelope, enumerate all source IDs, then acquire source/version FOR SHARE locks in stable source-ID/version-ID order and re-read/revalidate the snapshot and exact set. If the snapshot or its source set changed while locks were acquired, fail with a controlled conflict; do not acquire an additional unsorted set. Never lock the snapshot version first out of order. Every ID must resolve; no inner-join omission is acceptable. Reject withdrawn sources, removed versions, absent content, owner/request/subject/video/media mismatches or retrieval timestamps unequal to the retained row's instant. Keep original timestamp spelling/text in returned JSON. Accept API UTC minute/second spellings, reject hour 24/leap-second normalization, and reject nonzero sub-microsecond digits that PostgreSQL would round; persisted retrieval instants must be exactly representable by PostgreSQL. Do not trim, normalize or reconstruct retained prose. UUID comparisons use UUID values while the stored envelope preserves the original text.

SQL must enforce strict keys, types, limits, source-reference closure, duplicate UUID rejection, range ordering/duration, finite numbers and text validity consistent with API #1276. PostgreSQL cannot store malformed surrogate/NUL JSON in the first place; remaining control/blank-only/Unicode cases need explicit parity fixtures. Do not claim `char_length` alone matches JavaScript UTF-16 bounds; count supplementary code points as two units for the API limits. Bound the total JSON byte size to 4 MiB as an explicit narrower storage limit, tested at the boundary. Avoid silent truncation.

**Attribution restriction:** accept `identity.state=unresolved` only in this first proposal. Preserve observed performer names and their exact retained references; they confer no account link. Reject `matched` explicitly. The current graph's single accepted `identity` link for the YouTube resource is already the video locator; it cannot also express a recording match. Inventing another relation or trusting caller-supplied recording/artist IDs would exceed this slice. Supporting accepted recording/artist attribution requires a separately reviewed persisted binding contract. The API's broader fixture shape remains unchanged; this storage subset is documented and negative-tested. Do not downgrade matched input silently.

## Save, replay, read and withdrawal

`save_projection` obtains live evidence through the helper. Validate key against `^[A-Za-z0-9._:-]{1,128}$` and nonnegative expected revision. Derive the operation identity from a domain-separated JSON tuple of actor/owner/request/key; use its SHA-256 as `context_attempts.module`, attempt=1. An advisory transaction lock on that identity serializes identical requests; hash collisions may serialize unrelated work but never authorize it. Store the complete tuple and input fingerprint in attempt.input and compare them, not only the hash. The fingerprint includes snapshot ID, complete retained envelope and expected revision.

Check for an existing operation after authorization, locked locator-binding revalidation and lineage validation. Exact replay returns the same attempt/result/revision receipt only if the saved result is still accepted and current for this request, with all original lineage valid. Changed actor scope is a different key scope; changed content/snapshot/revision within the same scope is a controlled conflict. A withdrawn, superseded, cancelled or locator-rejected replay never revives or republishes old content. Store the server-observed locator binding `{linkId,resourceId,subjectId,relation:"identity"}` in attempt.input at the original save. Read and replay must compare that exact recorded binding to the currently locked row; a newly inserted accepted replacement link with another ID cannot silently substitute for the original binding. This is server-owned receipt metadata, never caller-provided evidence or a new source version. It returns a controlled unavailable/conflict error, with no evidence payload. An unexpected pre-existing running/unknown attempt is reconciliation-required, not permission to retry or overwrite.

For a new save, while retaining membership/request/resource/subject/locator-link/source locks, insert the video_narrative document if absent, lock it FOR UPDATE and compare the expected revision (0 for an absent document). Other requests for the same video subject share that document; a current result from another request must never be returned as this request's evidence. Revision checks prevent late replacement. Create the local projection attempt and accepted interpretation result atomically; derive normalized content exactly from the retained envelope plus `originalSongLyrics:not_established`, `scope:video_only`, `artistBrand:not_established`, with partial coverage and retained source-ID trace. Link exactly the supplied original version IDs in `context_result_sources`, including the full snapshot, and call existing `accept_context_result` with the locked revision. Any validation/CAS/accept failure rolls back every inserted row.

Attempt metadata is provider `retained-evidence`, model `none`, recipe `video-narrative-fixture-v1`, schema `1`, provider cost NULL/status unknown, no settlement reference. The attempt transitions to succeeded inside this same transaction: there is no externally runnable running state or dispatch claim. Store the resulting document revision in attempt.input as a server-owned receipt field. Return `{state:"saved",attemptId,resultId,documentId,revision,evidence}`. Do not overwrite any existing attempt, source, identity, recording or artist row.

`read_projection` authorizes and validates the request and locks/revalidates the resource, subject and target locator link in the same order as save. It optimistically locates the current video_narrative document/result and original snapshot ID, loads and locks the complete retained evidence/source set before the document, then locks the document and rechecks the current pointer, request-bound attempt, recorded exact locator binding and projection contract. If the pointer changed while acquiring locks, return a controlled retry/conflict without content; never combine old evidence with a new receipt. Use the already locked retained loader result and compare its full envelope to the saved projection input before returning the receipt/evidence. Do not acquire a newly discovered locator or source set after taking the document lock: a changed optimistic binding/pointer fails with a controlled conflict and no payload. Historical fallback, source substitution, newest-version substitution and provider fallback are unsupported.

Use existing `withdraw_context_source`: direct links ensure it marks this result withdrawn and clears the current document. Independent version removal must also cause read/replay refusal even if the document pointer remains. Check result status and lineage on every read/replay, not only at save. Source-before-document lock ordering follows existing case readers and withdrawal, with membership/request/resource/subject/locator locks first. Locator rejection need not clear the document or mark the result withdrawn: these functions independently refuse to expose it when the recorded locator binding is no longer accepted. Do not claim this protects unrelated existing raw-table or other readers; public wiring remains disabled. Withdrawal/revocation/locator rejection committed before a call must deny it; a transaction already holding the relevant share locks may finish before withdrawal/revocation commits. This is transaction ordering, not retroactive erasure of already delivered bytes.

## Admission, claims and accounting

This proposal is a storage transform of already retained data and creates no provider work. Do not call or broaden `claim_context_enrichment`, `complete_context_enrichment`, execution-node claims, reservation functions or the fixture-only accounting adapter. The generic completion writer creates new source versions and is the wrong persistence path for these exact retained references.

The local projection attempt exists because `context_results` requires an attempt FK; it is not an admitted paid attempt, a wallet receipt, an execution lease, or a zero-cost assertion. Keep original acquisition cost unknown. No customer debit/reservation/settlement or reuse journal is manufactured. An accepted retained result alone must never be treated as permission to dispatch fresh work.

Future accounting integration may record authorized retained reuse through its reviewed durable reuse path, with zero new debit, only after this read succeeds. The current API adapter requires injected durable storage and has no production policy defaults; this plan supplies neither. Any provider-produced missing evidence still requires separate authenticated admission, budget/reservation composition, single-dispatch and settlement/reconciliation gates **before** acquisition. Do not add a Boolean `admitted` parameter or accept a fabricated claim to bypass those gates. Production execution remains disabled, including nominally free collection.

## Required real SQL qualification

Run the owned Unix-socket-only harness on PostgreSQL 15 and 17. Use the exact #138 source `proposals/application-registration-2104/test_registration.py` at `f507a77696f20429f977df9885d6c8c11a5f304b` as the read-only runner reference; its complete Git-blob hash is now in `sources.json`. Copy/adapt only its standalone supervisor, environment, lease and cleanup machinery into the proposed new runner, not its application registration SQL/import or business tests. Record copied function ranges and any changed behavior in the implementation manifest; do not claim code has already been copied or qualified. The actual #107 SQL fixture is separately pinned, in addition to its Python runner. Explicit binary directory, owned HOME/TMPDIR, allowlisted environment, UTF-8 cluster, no inherited libpq/service/credential/loader variables, isolated worker process group, checked lease before SQL, bounded startup/SQL/lock/worker/cleanup waits, and checked postmaster/socket/process cleanup. Never accept a database URL or reuse a developer/hosted database. Run SQL only through the owned disposable harness below.

Required tests exercise real functions and tables, not text assertions alone:

- Save/read exact envelope, prose, UUID references and original snapshot IDs; no source/source-version count change. Correct partial interpretation and NULL/unknown costs; no recording/artist document changes.
- Missing/unavailable analysis and captions retain title/channel/description/performer evidence and honest reasons. Matched attribution, locator-only input and reference-only snapshots are explicitly rejected.
- Same-key same-input replay returns the same IDs with no extra rows. Same-key changed snapshot/envelope/revision conflicts; cancelled request and revoked member replay fail.
- Foreign owner/request/resource/subject/source, missing source, mismatched media version/retrieval time, duplicate/case-variant IDs, dangling references, malformed ranges, Unicode/blank/control cases and size/count boundaries fail before durable inserts.
- Source withdrawal and individual version removal block save, read and replay. Withdrawing any original dependency clears current visibility through existing withdrawal semantics; no wrapper can survive it.
- Concurrent identical saves yield one attempt/result; different keys with the same expected revision produce one save and one revision conflict. Lost save reply retries return the same receipt. Fault after each write proves full rollback.
- Two connections exercise contended source withdrawal, membership revocation, document supersession and request cancellation with deterministic barriers and bounded waits. Test both commit orderings and verify no cross-request receipt leakage.
- Add actual two-connection locator lifecycle tests for each of new save, read and exact replay. In operation-first ordering, connection A invokes the real function in an explicit open transaction, retaining its link lock. Connection B attempts `UPDATE context_resource_links SET status='rejected' WHERE id=<target>`; prove B is blocked by A with backend IDs/`pg_blocking_pids`, not elapsed time alone. Commit A, observe B complete and commit, and prove every subsequent save/read/replay refuses with no payload or new rows. A's prior successful result is allowed because rejection committed later.
- In rejection-first ordering, B updates that target link to rejected and holds the transaction; A invokes the real function and must block on B. Verify the blocker, commit B, then assert A resumes and refuses rather than using an earlier accepted observation. No save attempt/result/document change may survive. Repeat the same orderings for link deletion; test candidate/conflict status as ordinary refusal cases. Use bounded statement/lock timeouts and barriers to avoid hanging fixtures.
- Seed a completed projection, then replace its locator link with a different accepted row ID for the same tuple using fixture setup. Read and same-key replay must reject the changed server-recorded binding rather than treat it as the old link. A brand-new save under a new key may proceed only after all normal current-binding, source and expected-revision checks; no automatic retry or replacement is implied.
- Resource/provider-ID or subject-resource mutation committed before invocation must fail binding checks; a concurrent mutation while the operation holds its resource/subject share locks must block. Verify these row locks in the real service-role path. Do not add a locator rewrite or lifecycle trigger just to pass the tests.
- Actual SET ROLE calls prove anon/authenticated denial, proposal default service denial, and disposable explicitly granted service behavior. Do not mistake owner/superuser tests for runtime privilege proof.
- Compare before/after source IDs, locator document, generic claims/definitions, execution-claim counts and any composed accounting rows; this slice must not create dispatch or spending effects. Run #107's actual fixture and rollback assertion unchanged in the composed cluster.
- Runner failure/timeout/signal/exited-worker-child and synthetic poisoned-environment cases prove cleanup on this harness. A reused runner implementation alone does not inherit #138's results. Check fixture rollback after the fixture actually executes.

## Delivery and remaining gates

The accepted plan SHA-256 is recorded in sources.json. This contribution stays a six-file inactive proposal; no public RPC, production grant, migration, provider, accounting or API wiring is included. Independent implementation review and PostgreSQL qualification are required before the draft PR is ready for Root's merge decision.

Future work must separately reconcile locator #107/#1019, establish the real retained-source producer and its authenticated provenance/admission, review the thin API storage reader, and review production schema/grants/release. The full-snapshot manifest and hash do not authenticate its producer. The unresolved-only subset does not establish recording, artist, rights or ownership identity. Source tests never prove hosted access, provider execution, full ingestion or API/MCP/UI parity.
