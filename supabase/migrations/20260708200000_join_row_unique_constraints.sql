-- Add pair UNIQUE constraints to the roster/org join tables so join-row
-- keying is possible for connector-connection scoping (recoupable/chat#1860 P1).
--
-- * account_artist_ids: only a bigint PK on id today — nothing stops the same
--   (account_id, artist_id) pair from being inserted twice, so a Composio
--   connection can't be re-keyed onto the join row deterministically.
-- * artist_organization_ids: same gap for (artist_id, organization_id).
--
-- Also closes the check-then-insert race class (recoupable/chat#1844) for
-- these two tables: with the pair unique, concurrent duplicate inserts fail
-- at the database instead of minting duplicate rows.
--
-- Each constraint is preceded by a defensive dedupe (keep the lowest id per
-- pair, delete the rest) so the migration applies cleanly against prod data
-- even if duplicate pairs exist. None are known today.
--
-- Idempotent: dedupes are no-ops when there are no duplicates, and the
-- constraint adds are guarded by pg_constraint existence checks.

-- 1) account_artist_ids: UNIQUE (account_id, artist_id) ----------------------

-- Dedupe: keep the lowest id per (account_id, artist_id) pair.
DELETE FROM public.account_artist_ids a
USING public.account_artist_ids b
WHERE a.account_id IS NOT DISTINCT FROM b.account_id
  AND a.artist_id IS NOT DISTINCT FROM b.artist_id
  AND a.id > b.id;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'account_artist_ids_account_id_artist_id_key'
    ) THEN
        ALTER TABLE "public"."account_artist_ids"
            ADD CONSTRAINT "account_artist_ids_account_id_artist_id_key"
            UNIQUE (account_id, artist_id);
    END IF;
END $$;

-- 2) artist_organization_ids: UNIQUE (artist_id, organization_id) ------------

-- Dedupe: keep the lowest id per (artist_id, organization_id) pair.
DELETE FROM public.artist_organization_ids a
USING public.artist_organization_ids b
WHERE a.artist_id = b.artist_id
  AND a.organization_id = b.organization_id
  AND a.id > b.id;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'artist_organization_ids_artist_id_organization_id_key'
    ) THEN
        ALTER TABLE "public"."artist_organization_ids"
            ADD CONSTRAINT "artist_organization_ids_artist_id_organization_id_key"
            UNIQUE (artist_id, organization_id);
    END IF;
END $$;
