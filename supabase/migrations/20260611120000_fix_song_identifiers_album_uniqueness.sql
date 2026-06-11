-- Fix (recoupable/chat#1794): the unique constraint on song_identifiers was
-- (platform, identifier_type, value), which is right for track ids (one
-- external id = one recording) but wrong for album ids — an album contains
-- many songs, so (spotify, album_id, <album>) must exist once PER SONG.
-- The old constraint silently capped every album at one mapped song, which is
-- why GET /playcounts served 1 of 18 tracks.
--
-- The old constraint was declared inline in 20260610010000, so its name is
-- Postgres-generated — drop the table's (single) unique constraint by lookup
-- instead of by name.

DO $$
DECLARE
  old_constraint text;
BEGIN
  SELECT conname INTO old_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.song_identifiers'::regclass
    AND contype = 'u';

  IF old_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.song_identifiers DROP CONSTRAINT %I', old_constraint);
  END IF;
END $$;

-- New uniqueness: one mapping per (song, platform, identifier_type, value).
ALTER TABLE public.song_identifiers
  ADD CONSTRAINT song_identifiers_song_platform_type_value_unique
  UNIQUE (song, platform, identifier_type, value);

-- Reverse lookups (value -> songs) keep an index, now non-unique.
CREATE INDEX idx_song_identifiers_lookup
  ON public.song_identifiers (platform, identifier_type, value);
