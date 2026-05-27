-- Create the `public-uploads` Storage bucket for phase-1 of the Arweave -> Supabase
-- migration. Files written here are served from the public CDN; access control
-- comes from the parent resource that references the storage_key (chat / account
-- / artist / etc.), not from anything in this row.
--
-- Idempotent: safe to re-apply.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'public-uploads',
  'public-uploads',
  true,
  26214400, -- 25 MiB
  array[
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'application/pdf',
    'text/csv',
    'text/markdown',
    'text/x-markdown',
    'text/plain',
    'application/json',
    'audio/mpeg',
    'audio/wav',
    'audio/x-m4a',
    'audio/webm'
  ]
)
on conflict (id) do nothing;
