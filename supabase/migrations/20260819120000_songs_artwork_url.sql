-- Artist page V2 (recoupable/chat#1968): persist artwork per song so the
-- public profile does not call a streaming provider on every page build.
-- Populated lazily by the api's fetch-on-miss write-through; null until
-- resolved. Source-agnostic: the api decides which provider resolves art
-- (Apple Music today), and the column just stores the resulting URL.
alter table public.songs
  add column if not exists artwork_url text;

comment on column public.songs.artwork_url is
  'Artwork URL for the song''s release, resolved lazily by the api from a streaming provider. Null until first resolution.';
