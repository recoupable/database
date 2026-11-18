-- Synthetic legacy prerequisites only, inside the owned disposable cluster.
CREATE ROLE service_role BYPASSRLS;
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean,file_size_limit bigint);
CREATE TABLE storage.objects(id uuid PRIMARY KEY,bucket_id text);
CREATE TABLE public.accounts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text);
CREATE TABLE public.songs(isrc text PRIMARY KEY,name text,album text);
CREATE TABLE public.song_identifiers(song text,platform text,identifier_type text,value text);
CREATE TABLE public.account_artist_ids(account_id uuid,artist_id uuid);
CREATE TABLE public.catalogs(id uuid PRIMARY KEY,name text,updated_at timestamptz DEFAULT now());
CREATE TABLE public.account_catalogs(account uuid,catalog uuid);
CREATE TABLE public.account_organization_ids(account_id uuid,organization_id uuid,updated_at timestamptz DEFAULT now(),PRIMARY KEY(account_id,organization_id));
GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT ON public.account_organization_ids TO service_role;
