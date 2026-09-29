-- The verified-audio module stores WAVs in the existing user-files contract.
-- Production already has this bucket; fresh branches need it provisioned too.
insert into storage.buckets (id, name, public)
values ('user-files', 'user-files', false)
on conflict (id) do nothing;
