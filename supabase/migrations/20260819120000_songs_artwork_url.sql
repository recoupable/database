-- Artist page V2 (recoupable/chat#1968): persist Apple Music artwork per song
-- so the public profile does not hit Apple on every page build. Populated
-- lazily by the api's fetch-on-miss write-through; null until resolved.
alter table public.songs
  add column if not exists artwork_url text;

comment on column public.songs.artwork_url is
  'Apple Music artwork URL for the song''s release, resolved lazily from the batch ISRC lookup. Null until first resolution.';
