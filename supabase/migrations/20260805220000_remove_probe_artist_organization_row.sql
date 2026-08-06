-- Remove the orphan artist_organization_ids row created by a security probe
-- (recoupable/chat#1939).
--
-- Provenance, stated plainly: on 2026-08-05 I probed whether
-- POST /api/organizations/artists validated its body before authenticating.
-- I expected a 401. The endpoint had no authentication at all, so instead of
-- refusing the request it performed the write and returned
-- 200 {"status":"success","id":"64380a31-8e74-47f0-9d14-b064d926773a"}.
-- That response is what proved the vulnerability now fixed in
-- recoupable/api#818 -- and it also left this row behind. It is test debris,
-- not customer data.
--
-- The row is inert, though not for the reason first assumed. Both ids are the
-- all-zero UUID, which IS a real row in `accounts` named "Nullable Account" --
-- a sentinel, not a missing reference (the FKs on this table would have
-- rejected the insert otherwise). Measured on prod before writing this:
-- artist_organization_ids holds 82 rows and exactly ONE references the
-- sentinel, this one. account_artist_ids (1512 rows) and
-- account_organization_ids (127 rows) reference it zero times, so all-zero is
-- not a legitimate value anywhere in these join tables.
--
-- It is removed because a membership row linking the sentinel to itself means
-- nothing and is a trap for whoever next audits organization membership, not
-- because it is doing harm.
--
-- Safety:
--   * Targeted by id AND guarded on the all-zero shape, so a wrong or reused
--     id cannot delete a real membership. Both conditions must hold.
--   * Idempotent: re-running finds nothing and no-ops.
--   * The deleted row is copied into a manifest first. Deliberate even for a
--     single inert row -- a delete that leaves no record of what it removed is
--     unreviewable, and "it was only one row" is exactly the reasoning that
--     makes destructive migrations hard to audit later.

-- ---------- 1. Record before deleting ----------
CREATE TABLE IF NOT EXISTS public.zz_probe_cleanup_20260805 (
  captured_at timestamptz NOT NULL DEFAULT now(),
  id uuid,
  artist_id uuid,
  organization_id uuid,
  created_at timestamptz,
  updated_at timestamptz
);

INSERT INTO public.zz_probe_cleanup_20260805 (
  id, artist_id, organization_id, created_at, updated_at
)
SELECT
  aoi.id,
  aoi.artist_id,
  aoi.organization_id,
  aoi.created_at,
  aoi.updated_at
FROM public.artist_organization_ids AS aoi
WHERE aoi.id = '64380a31-8e74-47f0-9d14-b064d926773a'
  AND aoi.artist_id = '00000000-0000-0000-0000-000000000000'
  AND aoi.organization_id = '00000000-0000-0000-0000-000000000000'
  AND NOT EXISTS (
    SELECT 1
    FROM public.zz_probe_cleanup_20260805 AS z
    WHERE z.id = aoi.id
  );

-- ---------- 2. Delete ----------
DELETE FROM public.artist_organization_ids
WHERE id = '64380a31-8e74-47f0-9d14-b064d926773a'
  AND artist_id = '00000000-0000-0000-0000-000000000000'
  AND organization_id = '00000000-0000-0000-0000-000000000000';

-- ---------- 3. Sweep for any other all-zero rows ----------
-- The probe ran once and produced one row, but an unauthenticated write
-- endpoint was reachable by anyone for as long as it existed. If other
-- all-zero rows are present they were not created by me, and their existence
-- would be worth knowing about -- so record them WITHOUT deleting, and leave
-- the judgement to a human.
INSERT INTO public.zz_probe_cleanup_20260805 (
  id, artist_id, organization_id, created_at, updated_at
)
SELECT
  aoi.id,
  aoi.artist_id,
  aoi.organization_id,
  aoi.created_at,
  aoi.updated_at
FROM public.artist_organization_ids AS aoi
WHERE (
    aoi.artist_id = '00000000-0000-0000-0000-000000000000'
    OR aoi.organization_id = '00000000-0000-0000-0000-000000000000'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.zz_probe_cleanup_20260805 AS z
    WHERE z.id = aoi.id
  );
