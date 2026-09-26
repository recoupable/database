# Context foundation tests

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
