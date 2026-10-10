#!/usr/bin/env bash
set -euo pipefail
# Always use a new disposable cluster; never read DATABASE_URL.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${PG_BINDIR:-}" ]]; then
  pg_bin="$PG_BINDIR"
elif command -v initdb >/dev/null; then
  pg_bin="$(dirname "$(command -v initdb)")"
elif command -v pg_config >/dev/null; then
  pg_bin="$(pg_config --bindir)"
else
  pg_bin="/opt/homebrew/opt/postgresql@17/bin"
fi
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
"$pg_bin/psql" "${args[@]}" -f "$repo_root/supabase/migrations/20261010035000_catalog_stream_membership_locks.sql" >/dev/null
"$pg_bin/psql" "${args[@]}" -f "$repo_root/supabase/migrations/20261010040000_catalog_stream_parent_lock_order.sql" >/dev/null
"$pg_bin/psql" "${args[@]}" -f "$repo_root/supabase/tests/catalog_daily_stream_tracking.sql"
# Exercise real concurrent deletion against membership rows held by a commit.
"$pg_bin/psql" "${args[@]}" >/dev/null <<'SQL'
insert into accounts values ('10000000-0000-4000-8000-000000000001');
insert into catalogs values ('10000000-0000-4000-8000-000000000002');
insert into songs values ('USAAA2400001');
insert into account_catalogs values ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002');
insert into catalog_songs values ('USAAA2400001','10000000-0000-4000-8000-000000000002');
insert into catalog_stream_tracking(catalog_id,owner_id,enabled) values ('10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',true);
select * from claim_catalog_stream_run('10000000-0000-4000-8000-000000000002',current_date);
SQL
"$pg_bin/psql" "${args[@]}" >"$cluster_root/lock-holder.log" 2>&1 <<'SQL' &
begin;
select commit_catalog_stream_track((select id from catalog_stream_runs limit 1),'USAAA2400001','{"state":"unavailable"}'::jsonb);
\echo LOCKS_HELD
select pg_sleep(3);
rollback;
SQL
holder_pid=$!
for attempt in {1..100}; do
  if [[ "$(<"$cluster_root/lock-holder.log")" == *LOCKS_HELD* ]]; then break; fi
  sleep 0.02
done
[[ "$(<"$cluster_root/lock-holder.log")" == *LOCKS_HELD* ]]
for table_name in account_catalogs catalog_songs; do
  if "$pg_bin/psql" "${args[@]}" -c "set statement_timeout='300ms'; delete from public.$table_name;" >"$cluster_root/delete.log" 2>&1; then
    printf 'Concurrent membership deletion escaped commit fence.\n' >&2
    exit 1
  fi
  [[ "$(<"$cluster_root/delete.log")" == *"statement timeout"* ]]
done
wait "$holder_pid"

# Start the account cascade before a commit: it must finish without a lock cycle.
"$pg_bin/psql" "${args[@]}" >"$cluster_root/owner-delete.log" 2>&1 <<'SQL' &
begin;
select id from accounts for update;
delete from account_catalogs;
\echo DELETE_HELD
select pg_sleep(1);
delete from accounts;
commit;
SQL
deleter_pid=$!
for attempt in {1..100}; do
  if [[ "$(<"$cluster_root/owner-delete.log")" == *DELETE_HELD* ]]; then break; fi
  sleep 0.02
done
[[ "$(<"$cluster_root/owner-delete.log")" == *DELETE_HELD* ]]
"$pg_bin/psql" "${args[@]}" -At -c "select commit_catalog_stream_track((select id from catalog_stream_runs limit 1),'USAAA2400001','{\"state\":\"unavailable\"}'::jsonb);" >"$cluster_root/revoked-commit.log"
wait "$deleter_pid"
[[ "$(<"$cluster_root/revoked-commit.log")" == f ]]

printf 'Catalog stream storage checks passed.\n'
