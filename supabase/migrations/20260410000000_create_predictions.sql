-- Neural engagement predictions from TRIBE v2 model
create table if not exists public.predictions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  file_url text not null,
  modality text not null check (modality in ('video', 'audio', 'text')),
  engagement_score numeric not null,
  engagement_timeline jsonb not null,
  peak_moments jsonb not null,
  weak_spots jsonb not null,
  regional_activation jsonb not null,
  total_duration_seconds numeric not null,
  elapsed_seconds numeric not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_predictions_account_id
  on public.predictions(account_id);

create index if not exists idx_predictions_created_at
  on public.predictions(created_at desc);

alter table public.predictions enable row level security;
