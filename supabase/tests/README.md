# Context foundation tests

Run `context_foundation.sql` after `20260920010000_context_foundation.sql` in a **disposable** PostgreSQL/Supabase database with the existing `accounts`, `songs`, storage schema and Supabase roles. The fixture transaction rolls back.

The assertions cover provider-ID case, per-owner request uniqueness, cross-owner source references, required provenance, acceptance ownership, stale result rejection, creative-proposal exclusion, withdrawal and browser permissions. They do not invoke external providers or charge credits.

The migration was also tested with PostgreSQL 17 and minimal fixtures for the preexisting tables. This checks new-schema behavior, not the entire historical migration chain. A separate local storage check granted an intentionally broad permissive read policy: anonymous readers still could not see `context-private`, and unrelated buckets retained their original access.

This is the additive foundation for recoupable/app#2116, not activation of the complete Context Engine. API authorization, durable orchestration, spend reservations, retained-file deletion, full document-to-document invalidation and brief snapshots require subsequent implementation. The database functions accept only trusted service-role calls; domain operations must independently check the authenticated actor and owner.

## Connected Spotify metadata pilot

After both Context Engine migrations, run `supabase/tests/context_pipeline.sql`. It exercises real transactions for retry identity, input conflicts, worker claims, saved context, artist reuse across two tracks and owner-scoped reads. It rolls back synthetic fixtures. Use a disposable database with the existing accounts, songs, social/roster and organization tables; do not run test fixtures in production.

The opt-in API `lib/context/__tests__/pipeline.live.test.ts` uses the same stored functions against local PostgreSQL with real Spotify metadata. This is not deployed Supabase or paid-enrichment validation.
