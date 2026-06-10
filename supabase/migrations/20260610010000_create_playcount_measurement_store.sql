-- Play-count measurement store (recoupable/chat#1791).
-- Four tables: song_identifiers (platform ID <-> ISRC mapping), song_measurements
-- (append-only metric captures — the system of record for play counts),
-- songstats_quota_ledger (rolling-window spend tracking), and
-- songstats_backfill_queue (value-ranked historic backfill work list).
-- Builds on songs.isrc as the canonical key, mirroring catalog_songs/song_artists.

-- ============================================================
-- song_identifiers: maps external platform identifiers to ISRCs.
-- Needed because the Apify play-count actor takes Spotify album URLs in and
-- returns Spotify track IDs out — without this, actor results can't join songs.
-- ============================================================
create table "public"."song_identifiers" (
    "id" uuid not null default gen_random_uuid(),
    "song" text not null,
    "platform" text not null,
    "identifier_type" text not null,
    "value" text not null,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
);

alter table "public"."song_identifiers" enable row level security;

CREATE UNIQUE INDEX song_identifiers_pkey ON public.song_identifiers USING btree (id);
alter table "public"."song_identifiers" add constraint "song_identifiers_pkey" PRIMARY KEY using index "song_identifiers_pkey";

-- An external identifier resolves to exactly one recording (reverse lookup path)
CREATE UNIQUE INDEX song_identifiers_platform_type_value_unique ON public.song_identifiers USING btree (platform, identifier_type, value);
alter table "public"."song_identifiers" add constraint "song_identifiers_platform_type_value_unique" UNIQUE using index "song_identifiers_platform_type_value_unique";

CREATE INDEX idx_song_identifiers_song ON public.song_identifiers USING btree (song);

alter table "public"."song_identifiers" add constraint "song_identifiers_song_fkey" FOREIGN KEY (song) REFERENCES "public"."songs"(isrc) ON DELETE CASCADE not valid;
alter table "public"."song_identifiers" validate constraint "song_identifiers_song_fkey";

grant delete on table "public"."song_identifiers" to "service_role";
grant insert on table "public"."song_identifiers" to "service_role";
grant references on table "public"."song_identifiers" to "service_role";
grant select on table "public"."song_identifiers" to "service_role";
grant trigger on table "public"."song_identifiers" to "service_role";
grant truncate on table "public"."song_identifiers" to "service_role";
grant update on table "public"."song_identifiers" to "service_role";

CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON song_identifiers
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();

COMMENT ON TABLE "public"."song_identifiers" IS 'Maps external platform identifiers (Spotify track/album IDs, TikTok sound IDs) to songs by ISRC';
COMMENT ON COLUMN "public"."song_identifiers"."song" IS 'Foreign key reference to songs table (ISRC)';
COMMENT ON COLUMN "public"."song_identifiers"."platform" IS 'Platform the identifier belongs to (e.g. spotify, tiktok)';
COMMENT ON COLUMN "public"."song_identifiers"."identifier_type" IS 'Kind of identifier (e.g. track_id, album_id, sound_id)';
COMMENT ON COLUMN "public"."song_identifiers"."value" IS 'The external identifier value';

-- ============================================================
-- song_measurements: append-only metric captures. The system of record for
-- play counts — every Apify snapshot, Songstats backfill, and future
-- granted-analytics import writes one immutable row per capture.
-- Deliberately no set_updated_at trigger and no UPDATE grant beyond house
-- baseline usage: rows are written once and never modified.
-- ============================================================
create table "public"."song_measurements" (
    "id" uuid not null default gen_random_uuid(),
    "song" text not null,
    "platform" text not null,
    "metric" text not null,
    "value" bigint not null,
    "captured_at" timestamp with time zone not null,
    "source" text not null,
    "raw_ref" text,
    "created_at" timestamp with time zone not null default now()
);

alter table "public"."song_measurements" enable row level security;

CREATE UNIQUE INDEX song_measurements_pkey ON public.song_measurements USING btree (id);
alter table "public"."song_measurements" add constraint "song_measurements_pkey" PRIMARY KEY using index "song_measurements_pkey";

-- Fetch-once: one capture per (song, platform, metric, capture time)
CREATE UNIQUE INDEX song_measurements_capture_unique ON public.song_measurements USING btree (song, platform, metric, captured_at);
alter table "public"."song_measurements" add constraint "song_measurements_capture_unique" UNIQUE using index "song_measurements_capture_unique";

-- Latest-per-track and time-series reads
CREATE INDEX idx_song_measurements_series ON public.song_measurements USING btree (song, platform, metric, captured_at DESC);

alter table "public"."song_measurements" add constraint "song_measurements_song_fkey" FOREIGN KEY (song) REFERENCES "public"."songs"(isrc) ON DELETE CASCADE not valid;
alter table "public"."song_measurements" validate constraint "song_measurements_song_fkey";

grant delete on table "public"."song_measurements" to "service_role";
grant insert on table "public"."song_measurements" to "service_role";
grant references on table "public"."song_measurements" to "service_role";
grant select on table "public"."song_measurements" to "service_role";
grant trigger on table "public"."song_measurements" to "service_role";
grant truncate on table "public"."song_measurements" to "service_role";
grant update on table "public"."song_measurements" to "service_role";

COMMENT ON TABLE "public"."song_measurements" IS 'Append-only platform metric captures per song (system of record for play counts); rows are immutable once written';
COMMENT ON COLUMN "public"."song_measurements"."song" IS 'Foreign key reference to songs table (ISRC)';
COMMENT ON COLUMN "public"."song_measurements"."platform" IS 'Platform measured (e.g. spotify, tiktok)';
COMMENT ON COLUMN "public"."song_measurements"."metric" IS 'Metric name (e.g. platform_displayed_play_count)';
COMMENT ON COLUMN "public"."song_measurements"."value" IS 'Metric value at capture time';
COMMENT ON COLUMN "public"."song_measurements"."captured_at" IS 'When the value was observed on the platform';
COMMENT ON COLUMN "public"."song_measurements"."source" IS 'Provenance label (e.g. apify_spotify_playcount, songstats, granted_analytics)';
COMMENT ON COLUMN "public"."song_measurements"."raw_ref" IS 'Pointer to the archived raw vendor payload (e.g. actor run id), nullable';

-- ============================================================
-- songstats_quota_ledger: every Songstats API hit is recorded so spend over
-- the rolling 30-day window can be computed before making new calls.
-- ============================================================
create table "public"."songstats_quota_ledger" (
    "id" uuid not null default gen_random_uuid(),
    "hits" integer not null,
    "purpose" text,
    "spent_at" timestamp with time zone not null default now()
);

alter table "public"."songstats_quota_ledger" enable row level security;

CREATE UNIQUE INDEX songstats_quota_ledger_pkey ON public.songstats_quota_ledger USING btree (id);
alter table "public"."songstats_quota_ledger" add constraint "songstats_quota_ledger_pkey" PRIMARY KEY using index "songstats_quota_ledger_pkey";

alter table "public"."songstats_quota_ledger" add constraint "songstats_quota_ledger_hits_positive" CHECK (hits > 0);

CREATE INDEX idx_songstats_quota_ledger_spent_at ON public.songstats_quota_ledger USING btree (spent_at);

grant delete on table "public"."songstats_quota_ledger" to "service_role";
grant insert on table "public"."songstats_quota_ledger" to "service_role";
grant references on table "public"."songstats_quota_ledger" to "service_role";
grant select on table "public"."songstats_quota_ledger" to "service_role";
grant trigger on table "public"."songstats_quota_ledger" to "service_role";
grant truncate on table "public"."songstats_quota_ledger" to "service_role";
grant update on table "public"."songstats_quota_ledger" to "service_role";

COMMENT ON TABLE "public"."songstats_quota_ledger" IS 'Songstats API spend ledger; sum(hits) over the rolling 30-day window enforces the quota budget';
COMMENT ON COLUMN "public"."songstats_quota_ledger"."hits" IS 'Number of Songstats resource hits spent';
COMMENT ON COLUMN "public"."songstats_quota_ledger"."purpose" IS 'What the hits were spent on (e.g. backfill ISRC, endpoint name)';
COMMENT ON COLUMN "public"."songstats_quota_ledger"."spent_at" IS 'When the hits were spent';

-- ============================================================
-- songstats_backfill_queue: value-ranked work list for historic backfill.
-- The backfill worker claims rows FOR UPDATE SKIP LOCKED in rank order and
-- spends Songstats quota only on the tracks where history is worth most.
-- ============================================================
create table "public"."songstats_backfill_queue" (
    "id" uuid not null default gen_random_uuid(),
    "song" text not null,
    "rank_score" bigint not null default 0,
    "status" text not null default 'pending',
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
);

alter table "public"."songstats_backfill_queue" enable row level security;

CREATE UNIQUE INDEX songstats_backfill_queue_pkey ON public.songstats_backfill_queue USING btree (id);
alter table "public"."songstats_backfill_queue" add constraint "songstats_backfill_queue_pkey" PRIMARY KEY using index "songstats_backfill_queue_pkey";

-- One queue entry per song
CREATE UNIQUE INDEX songstats_backfill_queue_song_unique ON public.songstats_backfill_queue USING btree (song);
alter table "public"."songstats_backfill_queue" add constraint "songstats_backfill_queue_song_unique" UNIQUE using index "songstats_backfill_queue_song_unique";

alter table "public"."songstats_backfill_queue" add constraint "songstats_backfill_queue_status_check" CHECK (status in ('pending', 'in_progress', 'done', 'failed'));

alter table "public"."songstats_backfill_queue" add constraint "songstats_backfill_queue_song_fkey" FOREIGN KEY (song) REFERENCES "public"."songs"(isrc) ON DELETE CASCADE not valid;
alter table "public"."songstats_backfill_queue" validate constraint "songstats_backfill_queue_song_fkey";

-- Worker drain order: pending rows by descending value
CREATE INDEX idx_songstats_backfill_queue_drain ON public.songstats_backfill_queue USING btree (status, rank_score DESC);

grant delete on table "public"."songstats_backfill_queue" to "service_role";
grant insert on table "public"."songstats_backfill_queue" to "service_role";
grant references on table "public"."songstats_backfill_queue" to "service_role";
grant select on table "public"."songstats_backfill_queue" to "service_role";
grant trigger on table "public"."songstats_backfill_queue" to "service_role";
grant truncate on table "public"."songstats_backfill_queue" to "service_role";
grant update on table "public"."songstats_backfill_queue" to "service_role";

CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON songstats_backfill_queue
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_updated_at();

COMMENT ON TABLE "public"."songstats_backfill_queue" IS 'Value-ranked queue of songs awaiting Songstats historic backfill; drained by the api backfill workflow as quota allows';
COMMENT ON COLUMN "public"."songstats_backfill_queue"."song" IS 'Foreign key reference to songs table (ISRC)';
COMMENT ON COLUMN "public"."songstats_backfill_queue"."rank_score" IS 'Backfill priority — all-time play count descending';
COMMENT ON COLUMN "public"."songstats_backfill_queue"."status" IS 'pending | in_progress | done | failed';
