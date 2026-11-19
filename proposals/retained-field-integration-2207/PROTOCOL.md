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

## Genuine receipt selection consumer (source-only increment, 2026-11-19)

`selection-source.json` pins the separate API proposal consumer. The original
adopted evaluator checkout and all three original method hashes remain independently
required by `test_integration.py`; they are not replaced or widened. The added
consumer reads an existing current `reconcile_retention` receipt, projects its exact
Context selection, rechecks the original selection via `read_binding`, and evaluates
inside the original held transaction. No raw report, new authority store, latest
upgrade, implicit retain/expand or actor substitution is used. No SQL definition,
grant, route or production transport is introduced.

`test_selection_transport.py` builds the exact new API consumer plus its unchanged
real evaluator and checks the actual generated inner fieldContext fixture. These
five runnable **pure synthetic transport** tests do not initialize PostgreSQL or
claim authenticated source authority. Use the frozen source checkout with its
existing dependencies:

```sh
CATALOG_SELECTION_SOURCE=/path/to/frozen/api python3 proposals/retained-field-integration-2207/test_selection_transport.py
```

`test_selection_consumer.py` extends the existing actual database harness with five
new deferred scenarios: current genuine receipt → exact inner response, missing key
and wrong actor, withdrawn/removed/member/expanded-edge loss, superseded result,
and supported stream correction refusing the original selection. It calls actual
reconciliation and source reads; no new permissive SQL adapter is installed. The
SQL cases default to skipped. The focused local qualification below subsequently
executed all five; later runs must explicitly set `CATALOG_SELECTION_SQL_QUALIFICATION=1`;
that also requires `CATALOG_API_SOURCE` at the original adopted evaluator pin and
`CATALOG_SELECTION_SOURCE` at the new companion pin. The five sequential cases do
not qualify concurrent max-eight batch locking or production transaction transport.

The synthetic actor/session/chat/assistant strings in this harness are test context,
not session authentication proof. Returning a real selection also is not a lease:
the next read reauthorizes it. `fieldContext` is exactly the inner projection response
without `state`; UI owns its explicitly versioned offline envelope. Schema-v1 is
unchanged. No initial-send/replay/history/text/export/model disclosure path is enabled;
these paths must jointly withhold projections on current denial before live routing.

### Focused local qualification — 2026-11-19

All five new SelectionConsumer scenarios passed without skips against Database
`1185562def1bdbc49b70cdc7d889ba52b352f03b`, API consumer
`4ca23de6a6cea3226c2f0392a454eb57861aedf8` and original evaluator
`6ba799dbb67be284adcd6f8bcd8fcde2faa6c2b8`, using installed PostgreSQL 17.7.
Only those five tests ran; inherited unrelated suites were excluded. The default
PostgreSQL 14 server failed before startup because its ICU74 library was absent;
no tools were installed, and its temporary directory was removed.

The successful run cleared inherited connection/credential settings, initialized a
new synthetic temporary cluster, verified its postmaster/data-directory/socket
identity and empty listen_addresses before fixture SQL, and checked zero TCP
listeners. All schema/role/data writes stayed in that disposable database. Cleanup
verified the owned process, Unix socket, PID file and temporary directory were gone.
No hosted DSN, existing database, account credential, runtime route, production
apply/grant/enrollment or activation was used. This closes the five sequential
consumer scenarios only; batch concurrency, authenticated production transport and
publication/history disclosure qualification remain outstanding.
