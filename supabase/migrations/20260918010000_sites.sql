-- Sites are accessed through authenticated server routes. Drafts and fan data
-- are never exposed through the anonymous Supabase API.
create table public.sites (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.accounts(id),
  created_by uuid not null references public.accounts(id),
  artist_id uuid references public.accounts(id) on delete set null,
  name text not null check (length(name) between 1 and 120),
  brief text not null default '',
  release_url text not null default '',
  assets jsonb not null default '[]',
  draft jsonb,
  published jsonb,
  revision integer not null default 0,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index sites_owner_idx on public.sites(owner_id, updated_at desc);
alter table public.sites enable row level security;
revoke all on public.sites from anon, authenticated;
grant all on public.sites to service_role;

create table public.site_signups (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.sites(id) on delete cascade,
  email text not null check (length(email) <= 254),
  consent_text text not null,
  created_at timestamptz not null default now(),
  unique(site_id, email)
);
alter table public.site_signups enable row level security;
revoke all on public.site_signups from anon, authenticated;
grant all on public.site_signups to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site-assets', 'site-assets', true, 20971520,
  array['image/jpeg','image/png','image/webp','audio/mpeg','audio/wav'])
on conflict (id) do nothing;
-- Only the service role uploads; public assets must not contain private data.
