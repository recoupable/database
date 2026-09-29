-- Context metadata resolves Spotify IDs through this server-owned mapping.
grant select, insert, update, delete on public.song_identifiers to service_role;
-- Account provisioning uses this log to make its existing welcome-email path idempotent.
grant select, insert, update on public.email_send_log to service_role;
