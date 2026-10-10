-- Forward-only: preview has already applied the playback-policy migration.
alter table public.release_players
  add constraint release_players_audio_not_blank check (
    free_playback <> 'audio' or nullif(btrim(audio_url), '') is not null
  );
