-- Add artist_id to sessions, mirroring rooms.artist_id
-- (see 20250310153603_add_artist_id_to_rooms.sql).
--
-- Each chat is provisioned inside one session; the artist the chat
-- belongs to lives on the session row so the chat listing endpoint
-- can filter via `sessions.artist_id`. Backfill from rooms is done
-- inline below — mirrors the legacy migration's pattern of shipping
-- the schema change and the data migration atomically.

ALTER TABLE "public"."sessions"
    ADD COLUMN "artist_id" UUID DEFAULT NULL;

ALTER TABLE "public"."sessions"
    ADD CONSTRAINT "sessions_artist_id_fkey"
    FOREIGN KEY ("artist_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."sessions" VALIDATE CONSTRAINT "sessions_artist_id_fkey";

-- Backfill from legacy rooms via the uuidv5 derivation used by the
-- Phase 2 backfill script (api/scripts/backfill/migrateRoom.ts). The
-- fixed namespace is the same one the script hardcodes, so this
-- SQL reproduces the exact session id each migrated room was given.
-- Verified pre-merge: 17,985 of 23,252 migrated sessions have a
-- matching legacy room with a non-null artist_id.
UPDATE "public"."sessions" s
SET "artist_id" = r."artist_id"
FROM "public"."rooms" r
WHERE s."id" = uuid_generate_v5(
        'f47ac10b-58cc-4372-a567-0e02b2c3d479'::uuid,
        r."id"::text
      )::text
  AND r."artist_id" IS NOT NULL;

-- Direct lookup of "all sessions for an artist".
CREATE INDEX IF NOT EXISTS "sessions_artist_id_idx"
    ON "public"."sessions" ("artist_id");

-- Composite scoping index for the sidebar's `(account, artist)` filter.
-- Chat-side recency ordering is satisfied by the existing
-- `chats_session_id_idx` + the sort on `chats.updated_at`, so this
-- index does not include `sessions.updated_at`.
CREATE INDEX IF NOT EXISTS "sessions_account_artist_idx"
    ON "public"."sessions" ("account_id", "artist_id");
