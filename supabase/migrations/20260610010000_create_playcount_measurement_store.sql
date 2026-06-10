-- Play-count measurement store (recoupable/chat#1791).
-- Five tables built on songs.isrc as the canonical key:
--   song_identifiers      external platform ID <-> ISRC mapping
--   playcount_snapshots   snapshot jobs (mints snapshot_id for POST /research/snapshots)
--   song_measurements     append-only metric captures — the system of record
--   songstats_quota_ledger rolling-window Songstats spend, attributable per account
--   songstats_backfill_queue value-ranked historic backfill work list

-- Maps external platform identifiers (Spotify track/album IDs, TikTok sound IDs)
-- to ISRCs. The Apify actor takes album URLs in and returns Spotify track IDs
-- out; without this mapping, actor results can't join to songs.
CREATE TABLE song_identifiers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  song TEXT NOT NULL REFERENCES songs(isrc) ON DELETE CASCADE,
  platform TEXT NOT NULL,
  identifier_type TEXT NOT NULL,
  value TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- an external identifier resolves to exactly one recording
  UNIQUE (platform, identifier_type, value)
);
CREATE INDEX idx_song_identifiers_song ON song_identifiers (song);
ALTER TABLE public.song_identifiers ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON song_identifiers
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Snapshot jobs: one row per POST /api/research/snapshots. Mints snapshot_id,
-- tracks async state, and carries the cost estimate returned before execution.
-- (account, created_at) supports the per-org monthly cap (429).
CREATE TABLE playcount_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  catalog UUID REFERENCES catalogs(id) ON DELETE SET NULL,
  album_ids TEXT[],
  isrcs TEXT[],
  platforms TEXT[] NOT NULL,
  schedule TEXT NOT NULL DEFAULT 'once' CHECK (schedule IN ('once', 'monthly')),
  state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'done', 'failed')),
  album_count INTEGER CHECK (album_count >= 0),
  estimated_cost_usd NUMERIC(10, 4) CHECK (estimated_cost_usd >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_playcount_snapshots_account_created ON playcount_snapshots (account, created_at);
ALTER TABLE public.playcount_snapshots ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON playcount_snapshots
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Append-only metric captures. Every Apify snapshot, Songstats backfill, and
-- future granted-analytics import writes one row per capture; rows are never
-- updated or deleted by application code, so there is no set_updated_at
-- trigger. data_source matches the published contract field (docs#238):
-- apify_spotify_playcount | songstats | granted_analytics.
CREATE TABLE song_measurements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  song TEXT NOT NULL REFERENCES songs(isrc) ON DELETE CASCADE,
  platform TEXT NOT NULL,
  metric TEXT NOT NULL,
  value BIGINT NOT NULL CHECK (value >= 0),
  captured_at TIMESTAMPTZ NOT NULL,
  data_source TEXT NOT NULL,
  raw_ref TEXT,
  snapshot UUID REFERENCES playcount_snapshots(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- fetch-once: one capture per (song, platform, metric, capture time)
  UNIQUE (song, platform, metric, captured_at)
);
CREATE INDEX idx_song_measurements_series ON song_measurements (song, platform, metric, captured_at DESC);
ALTER TABLE public.song_measurements ENABLE ROW LEVEL SECURITY;

-- Songstats spend ledger: sum(hits) over the rolling 30-day window enforces
-- the quota budget; account attributes spend to the org that triggered it
-- (nullable for system-initiated backfill).
CREATE TABLE songstats_quota_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account UUID REFERENCES accounts(id) ON DELETE SET NULL,
  hits INTEGER NOT NULL CHECK (hits > 0),
  purpose TEXT,
  spent_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_songstats_quota_ledger_spent_at ON songstats_quota_ledger (spent_at);
CREATE INDEX idx_songstats_quota_ledger_account_spent ON songstats_quota_ledger (account, spent_at);
ALTER TABLE public.songstats_quota_ledger ENABLE ROW LEVEL SECURITY;

-- Value-ranked backfill work list; the worker claims rows FOR UPDATE SKIP
-- LOCKED in (status, rank_score DESC) order. rank_score = all-time play count.
CREATE TABLE songstats_backfill_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  song TEXT NOT NULL UNIQUE REFERENCES songs(isrc) ON DELETE CASCADE,
  rank_score BIGINT NOT NULL DEFAULT 0 CHECK (rank_score >= 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'done', 'failed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_songstats_backfill_queue_drain ON songstats_backfill_queue (status, rank_score DESC);
ALTER TABLE public.songstats_backfill_queue ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON songstats_backfill_queue
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
