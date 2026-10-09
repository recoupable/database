#!/usr/bin/env bash
set -euo pipefail
# Always use a new disposable cluster; never read DATABASE_URL.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pg_bin="${PG_BINDIR:-/opt/homebrew/opt/postgresql@17/bin}"
cluster_root="$(mktemp -d /tmp/recoup-streams-pg.XXXXXX)"
cleanup() {
  "$pg_bin/pg_ctl" -D "$cluster_root/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$cluster_root"
}
trap cleanup EXIT
mkdir "$cluster_root/socket"
"$pg_bin/initdb" -D "$cluster_root/data" -A trust -U stream_test_admin --no-locale >"$cluster_root/init.log"
"$pg_bin/pg_ctl" -D "$cluster_root/data" -l "$cluster_root/server.log" -o "-k $cluster_root/socket -p 5432 -h ''" start >/dev/null
args=(-X -w -h "$cluster_root/socket" -p 5432 -U stream_test_admin -d postgres -v ON_ERROR_STOP=1)
"$pg_bin/psql" "${args[@]}" >/dev/null <<'SQL'
create role anon;
create role authenticated;
create role service_role bypassrls;
create table public.accounts(id uuid primary key);
create table public.catalogs(id uuid primary key);
create table public.songs(isrc text primary key);
create table public.account_catalogs(account uuid,catalog uuid);
create table public.catalog_songs(song text,catalog uuid);
grant all on public.accounts, public.catalogs, public.songs, public.account_catalogs, public.catalog_songs to service_role;
SQL
"$pg_bin/psql" "${args[@]}" -f "$repo_root/supabase/migrations/20261009193000_catalog_daily_stream_tracking.sql" >/dev/null
"$pg_bin/psql" "${args[@]}" -f "$repo_root/supabase/tests/catalog_daily_stream_tracking.sql"
printf 'Catalog stream storage checks passed.\n'
