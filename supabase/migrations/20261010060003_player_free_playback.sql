-- Release owners choose the Free-account destination; existing releases retain Spotify handoff.
alter table public.release_players
  add column free_playback text not null default 'spotify' check (free_playback in ('spotify','audio')),
  add column audio_url text,
  add constraint release_players_audio_fallback check (
    free_playback <> 'audio' or (audio_url is not null and spotify_url is not null)
  );
