-- Create catalog_valuations: persisted valuation history per catalog
-- (recoupable/chat#1889 row 15 — the keystone of the 2026-07-29 reorder).
--
-- The estimated catalog value is currently recomputed live on every read
-- (GET /api/catalogs/{id}/measurements derives the band at read time) and
-- stored nowhere. That costs the product its retention hook — a weekly report
-- can never say "your number moved" without two numbers to compare — and costs
-- sales a sortable Attio Catalog Value field (today hand-priced per lead).
--
-- One row per band computation, at most one per catalog per day from the
-- read path (valuation runs always insert). History is the point: columns on
-- catalogs would only ever hold the latest value.
--
-- Written by api: runValuationHandler (funnel + onboarding seeding) and the
-- measurements read path (daily-deduped). Read by
-- GET /api/catalogs/{catalogId}/valuations (contract: docs#279).
--
-- FK to catalogs with ON DELETE CASCADE: a valuation row is meaningless
-- without its catalog, unlike the loose-id bookkeeping tables.

CREATE TABLE IF NOT EXISTS public.catalog_valuations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    catalog_id          UUID NOT NULL REFERENCES public.catalogs(id) ON DELETE CASCADE,
    low                 NUMERIC NOT NULL,   -- band low, USD
    mid                 NUMERIC NOT NULL,   -- band midpoint, USD
    high                NUMERIC NOT NULL,   -- band high, USD
    measured_song_count INTEGER  NOT NULL,  -- songs measured in the underlying capture
    total_streams       BIGINT   NOT NULL,  -- whole-catalog lifetime streams at measurement
    measured_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    created_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- The read is always "latest rows for one catalog".
CREATE INDEX IF NOT EXISTS catalog_valuations_catalog_measured_idx
  ON public.catalog_valuations (catalog_id, measured_at DESC);
