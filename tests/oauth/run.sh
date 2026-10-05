#!/usr/bin/env bash
set -euo pipefail
# Always creates its own cluster. Does not read DATABASE_URL or connect to a shared database.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
pg_bin="${PG_BINDIR:-$(dirname "$(command -v initdb)")}"
cluster_root="$(mktemp -d /tmp/recoup-oauth-pg.XXXXXX)"
cleanup() {
  "$pg_bin/pg_ctl" -D "$cluster_root/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$cluster_root"
}
trap cleanup EXIT
mkdir "$cluster_root/socket"
"$pg_bin/initdb" -D "$cluster_root/data" -A trust -U oauth_test_admin --no-locale >"$cluster_root/init.log"
"$pg_bin/pg_ctl" -D "$cluster_root/data" -l "$cluster_root/server.log" -o "-k $cluster_root/socket -p 5432 -h ''" start >/dev/null
export OAUTH_TEST_PSQL="$pg_bin/psql"
export OAUTH_TEST_SOCKET="$cluster_root/socket"
psql_args=(-X -w -h "$cluster_root/socket" -p 5432 -U oauth_test_admin -d postgres -v ON_ERROR_STOP=1)
"$pg_bin/psql" "${psql_args[@]}" -f "$repo_root/tests/oauth/bootstrap.sql" >/dev/null
migration="$repo_root/supabase/migrations/20261005170000_oauth_provider_store.sql"
if [[ -f "$migration" ]]; then
  "$pg_bin/psql" "${psql_args[@]}" -f "$migration" >/dev/null
fi
python3 "$repo_root/tests/oauth/test_store.py"
