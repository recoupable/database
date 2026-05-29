-- Add artist_id to sessions, mirroring rooms.artist_id
-- (see 20250310153603_add_artist_id_to_rooms.sql).
--
-- Each chat is provisioned inside one session; the artist the chat
-- belongs to lives on the session row so the chat listing endpoint
-- can filter via `sessions.artist_id`. Backfill from rooms happens
-- in a later data-migration step (rooms+memories → sessions+chats+
-- chat_messages); this migration only adds the column + index.

ALTER TABLE "public"."sessions"
    ADD COLUMN "artist_id" UUID DEFAULT NULL;

ALTER TABLE "public"."sessions"
    ADD CONSTRAINT "sessions_artist_id_fkey"
    FOREIGN KEY ("artist_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."sessions" VALIDATE CONSTRAINT "sessions_artist_id_fkey";

-- Direct lookup of "all sessions for an artist".
CREATE INDEX IF NOT EXISTS "idx_sessions_artist_id"
    ON "public"."sessions" ("artist_id");

-- Backs the chat sidebar's `(account, artist, recency)` filter ordering.
CREATE INDEX IF NOT EXISTS "idx_sessions_account_artist_updated_at"
    ON "public"."sessions" ("account_id", "artist_id", "updated_at" DESC);
