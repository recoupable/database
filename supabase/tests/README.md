# Context foundation tests

## Single-video locator entry

After `20261010213100_context_video_entry.sql`, run `context_video_entry.sql` in a
disposable database transaction, or `python3 -m unittest discover -s tests -p
'test_context_video_entry.py'` from the repository root (local PostgreSQL on PATH;
on macOS export `LC_ALL=C` if `pg_ctl` reports a multithreaded postmaster). The
fixture saves one YouTube video as a `video` subject with a `video_locator`
customer assertion and six explicit gaps, then checks identifier validation,
same-key replay, key conflicts, re-submission of the same video under a new key
(one subject, source and document; one more request, attempt and result), a
second video, workspace isolation, source
withdrawal and browser-role denial. It asserts no account, roster, song, song
identifier, artist, recording or release row is created and no song or artist
document is written. No provider is called. The chain applied in CI includes the
catalog and name/brief/text entry migrations so the `video` kind is checked against
the current subject constraints.

## Brief snapshots

After `20260926170000_context_brief_snapshots.sql`, run `context_brief_snapshots.sql`
in a disposable database. It rolls back its fixture and covers exact save/read,
idempotent replay, key conflicts, changed/forged evidence, manifest mismatch,
workspace isolation, superseded context, cancellation, source withdrawal and
service/browser privileges. It needs only the Context foundation and Spotify
pipeline migrations plus the existing accounts/songs/storage tables and roles.
No providers are called.

## Foundation

Run `context_foundation.sql` after `20260920010000_context_foundation.sql` in a **disposable** PostgreSQL/Supabase database with the existing `accounts`, `songs`, storage schema and Supabase roles. The fixture transaction rolls back.

The assertions cover provider-ID case, per-owner request uniqueness, cross-owner source references, required provenance, acceptance ownership, stale result rejection, creative-proposal exclusion, withdrawal and browser permissions. They do not invoke external providers or charge credits.

The migration was also tested with PostgreSQL 17 and minimal fixtures for the preexisting tables. This checks new-schema behavior, not the entire historical migration chain. A separate local storage check granted an intentionally broad permissive read policy: anonymous readers still could not see `context-private`, and unrelated buckets retained their original access.

This is the additive foundation for recoupable/app#2116, not activation of the complete Context Engine. API authorization, durable orchestration, spend reservations, retained-file deletion, full document-to-document invalidation and brief snapshots require subsequent implementation. The database functions accept only trusted service-role calls; domain operations must independently check the authenticated actor and owner.

## Connected Spotify metadata pilot

After both Context Engine migrations, run `supabase/tests/context_pipeline.sql`. It exercises real transactions for retry identity, input conflicts, worker claims, saved context, artist reuse across two tracks and owner-scoped reads. It rolls back synthetic fixtures. Use a disposable database with the existing accounts, songs, social/roster and organization tables; do not run test fixtures in production.

The opt-in API `lib/context/__tests__/pipeline.live.test.ts` uses the same stored functions against local PostgreSQL with real Spotify metadata. This is not deployed Supabase or paid-enrichment validation.

## Execution records

Run `context_execution_records.sql` after the provider-evidence and execution-record migrations in a disposable database. It verifies immutable plan replay, conflicting replay, duplicate keys, subject scope, owner isolation, idempotent outcomes, unknown nodes, invented success receipts, a real claim/save receipt, cancellation and browser privilege restrictions. Fixtures roll back.

These records store a server-built plan and policy version, not a spending authorization. The server must validate graph cycles and its policy, recheck workspace access, and reserve/settle paid work separately. Outcome writes remain available after cancellation so in-flight work can leave an accurate trace. Evidence writes retain their separate request guards. Success receipts currently support only the three audited dispatcher modules. Durable orchestration and inspector loading are subsequent integration work.
## Enrichment completion scope

After the enrichment migrations through `20260923070000_context_enrichment_scope.sql`, run `context_completion_scope.sql` in a disposable local database. It rolls back its fixtures and checks cancellation after claim, removed/missing/malformed subject membership, wrong owner, valid completion, duplicate completion, and cancellation before an idempotent response. Rejected completions must leave no documents, results or sources.

Both claim and completion acquire a shared request row lock before examining scope. This permits concurrent collectors while preventing status/output updates until their transaction finishes. API actor/workspace authorization remains required; this migration does not enable workflow dispatch.
