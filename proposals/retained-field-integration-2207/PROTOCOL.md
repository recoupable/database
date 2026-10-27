# Offline retained field integration (2207)

Status: candidate qualification, 2026-10-27. No migrations, runtime exports,
production grants, actor adapter, UI descriptor projection or provider requests.

## Concrete gap and dependency

The evaluator's own vectors supply a qualified/unavailable boundary. This suite
obtains that boundary from the actual retained writer and `read_binding` against
disposable PostgreSQL, then calls the actual Catalog evaluator while the read
transaction remains open. It does not duplicate field math or introduce a codec.

Database base: `a118b020911222e88d1c254c1babfbd60de370a1`, including
[writer #129](https://github.com/recoupable/database/pull/129) and the adopted reader.
Catalog dependency: [API #1190](https://github.com/recoupable/api/pull/1190), exact
reviewed head `6ba799dbb67be284adcd6f8bcd8fcde2faa6c2b8` (root merged at
`c5dfa7c4a3c50b8daabf8d3b7d11a53b118582ee`). The harness checks the exact checkout
HEAD and evaluator/recipe/helper SHA256 values before compilation and after tests.
The helper and manifest retain their original relative paths in temporary output;
actual source imports are bundled with esbuild from the pinned API dependency tree.
No API checkout is modified. Node is a test transport over JSON stdin/stdout only.

## Operating sequence

1. Create explicit synthetic owner, actor, request, catalog, recording and retained
   observations using the existing disposable fixture. The actor is never inferred
   from the receipt. No external source is fetched.
2. Call actual `stream_binding_proposal.retain`; use the returned immutable receipt
   to select exact owner/request/subject/catalog/result/version/document revision.
3. Start a READ COMMITTED transaction and call actual `read_binding`. A null read
   becomes `unavailable`, never a forged qualified envelope. A SQL failure fails the
   test instead of permitting evaluation.
4. Pass the exact envelope plus the explicit query and requested field to the actual
   evaluator while the PostgreSQL session and its locks remain open. Evaluate all
   four field names independently; preserve complete binding, query, provenance,
   periods, recipe/helper identity and field state in returned results.
5. Roll back the read-only transaction. Any later computation opens a new read.
   A prior successful result is not permission to reuse a cached envelope.

## Executable claims

- Four actual fields for previous=50/current=100 return 50,100,50,100 respectively,
  with complete returned binding and original evidence tuples.
- Changed result ID, version, document revision or query refuses. An identical
  retry/reconciliation returns its original receipt. A new key can reuse the
  immutable source version while advancing the document revision and result ID;
  the old receipt no longer authorizes computation.
- Absent evidence returns unknown, never zero. Observed zero remains zero and a
  zero baseline keeps percentage growth unknown.
- A correction through actual `commit_catalog_stream_track` denies the old read;
  actual retention of corrected evidence creates a new version and computes 150.
  Direct fixture correction, supported withdrawal, catalog membership removal,
  workspace-catalog removal and an unauthorized explicit actor deny stale values.
- Supported withdrawal, both membership removals and stream commit hit a bounded
  test statement timeout while the read transaction is held. Computation succeeds
  inside that transaction; withdrawal succeeds afterward and the fresh read denies.
- UTF-8 evidence over 512 KiB refuses retention atomically without saved rows.
  Source-history overflow also denies a previously readable receipt. The unchanged
  reader and evaluator enforce 512 KiB evidence / 768 KiB envelope caps without
  truncation. Existing reader/writer regressions remain a separate CI step.

These are logical data/size bounds, not hard CPU, physical scan or memory bounds.
The 200ms timeout belongs only to competing test statements; it is not a production
execution deadline. No persisted field authority or durable surface is created.
Source/current-result revision is not a surface or working-controls revision.

## Run

Use a separate, exact pinned API checkout with its pnpm dependencies installed:

```sh
export CATALOG_API_SOURCE=/absolute/path/to/pinned-api-checkout
export PATH=/path/to/postgresql/bin:$PATH
python3 proposals/stream-retention-writer-2207/test_writer.py
python3 proposals/retained-field-integration-2207/test_integration.py
```

CI runs PostgreSQL 15 and 17, Node 20, pnpm 9 and frozen dependency installation.
Both suites create Unix-socket-only temporary databases, without hosted DSNs.

## Remaining gates and owner handoff

Root owns review/merge and any future activation decision. Production source-family
write enforcement, authenticated actor derivation, execution deadlines and durable
composition remain separate gates. Generic/direct table writes are not covered by
the supported-mutator atomicity claim. Currentness lasts only while locks are held;
publishing or caching the derived field after release requires its own protocol.

The UI owner retains descriptor projection. Four fields share one ObjectRef;
field identity and full result/query/method binding must survive projection rather
than inventing per-field object IDs. App part 256 KiB, controls 64 KiB and command
128 KiB limits remain unchanged; a 768 KiB evidence envelope is not a chat payload.
Do not copy all retained tuples into saved controls or equate document revision with
surface revision. This suite does not prove deployed behavior or provider execution.
