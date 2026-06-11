-- Fix (recoupable/chat#1794): the unique constraint on song_identifiers was
-- (platform, identifier_type, value), which is right for track ids (one
-- external id = one recording) but wrong for album ids — an album contains
-- many songs, so (spotify, album_id, <album>) must exist once PER SONG.
-- The old constraint silently capped every album at one mapped song, which is
-- why GET /playcounts served 1 of 18 tracks.
--
-- New uniqueness: one mapping per (song, platform, identifier_type, value).
-- Reverse lookups (value -> songs) keep an index, now non-unique.

ALTER TABLE public.song_identifiers
  DROP CONSTRAINT song_identifiers_platform_type_value_unique;

ALTER TABLE public.song_identifiers
  ADD CONSTRAINT song_identifiers_song_platform_type_value_unique
  UNIQUE (song, platform, identifier_type, value);

CREATE INDEX idx_song_identifiers_lookup
  ON public.song_identifiers (platform, identifier_type, value);
