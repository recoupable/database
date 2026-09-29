-- commit_spotify_context runs as the server role and creates verified artist
-- profile/workspace links when a release is first encountered.
grant insert on public.account_socials, public.artist_organization_ids to service_role;
