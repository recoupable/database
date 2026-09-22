-- The legacy-compatible artist lookup otherwise scans all social profiles.
-- Match the expression in commit_spotify_context without changing identity rules.
create index socials_context_profile_identity_idx on public.socials
  ((regexp_replace(regexp_replace(profile_url, '^https?://', ''), '[?#].*$', '')), id);
