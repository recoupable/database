-- An account can finish profile setup for an artist who has no profile yet.
-- This is a private, reversible preference, not a change to artist access or socials.
create table public.account_artist_profile_preferences (
  account_id uuid not null references public.accounts(id) on delete cascade,
  artist_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (account_id, artist_id)
);
comment on table public.account_artist_profile_preferences is
  'Presence means this account reviewed the artist and chose No profile yet. Delete to undo.';
create index account_artist_profile_preferences_artist_idx
  on public.account_artist_profile_preferences (artist_id);
alter table public.account_artist_profile_preferences enable row level security;
revoke all on public.account_artist_profile_preferences from anon, authenticated;
grant select, insert, update, delete on public.account_artist_profile_preferences to service_role;
