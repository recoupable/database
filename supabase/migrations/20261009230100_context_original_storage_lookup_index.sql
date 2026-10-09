-- Support owner/path conflict probes without scanning unrelated retained history.
-- This is not a constant-time or measured production-performance guarantee.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
CREATE INDEX context_source_versions_owner_storage_path_idx
 ON public.context_source_versions(owner_id,storage_path)
 WHERE storage_path IS NOT NULL;
COMMIT;
