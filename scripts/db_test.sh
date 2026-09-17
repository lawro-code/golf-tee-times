#!/usr/bin/env bash
#
# Apply every migration to a throwaway local Postgres 17 and run the schema
# assertions. This is the machine-checked gate for "the migration applies
# clean" — it never touches a hosted Supabase project.
#
#   ./scripts/db_test.sh
#
# Requires: brew install postgresql@17
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}"
PGDATA="$(mktemp -d "${TMPDIR:-/tmp}/tees-pg.XXXXXX")"
PORT="${PGPORT_TEST:-55432}"
DB="tees_test"

if [ ! -x "$PGBIN/initdb" ]; then
  echo "postgres 17 not found at $PGBIN — brew install postgresql@17" >&2
  exit 1
fi

cleanup() {
  "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$PGDATA"
}
trap cleanup EXIT

echo "== initdb (throwaway cluster at $PGDATA)"
"$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust --encoding=UTF8 --locale=C >/dev/null

echo "== start postgres on port $PORT"
"$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PORT -k $PGDATA -c listen_addresses=''" -w -l "$PGDATA/server.log" start >/dev/null

PSQL=("$PGBIN/psql" -v ON_ERROR_STOP=1 -q -h "$PGDATA" -p "$PORT" -U postgres)

"${PSQL[@]}" -d postgres -c "create database $DB" >/dev/null
echo "== postgres $("$PGBIN/psql" -h "$PGDATA" -p "$PORT" -U postgres -d "$DB" -tAc 'show server_version')"

echo "== stubs"
"${PSQL[@]}" -d "$DB" -f "$ROOT/supabase/local/00_stubs.sql" >/dev/null

echo "== migrations"
shopt -s nullglob
for f in "$ROOT"/supabase/migrations/*.sql; do
  printf '   %-34s' "$(basename "$f")"
  "${PSQL[@]}" -d "$DB" -f "$f" >/dev/null
  echo "ok"
done

# Applying twice proves the migrations are idempotent — a rerun after a partial
# failure must not need a hand-repaired database.
echo "== migrations (second pass, idempotency)"
for f in "$ROOT"/supabase/migrations/*.sql; do
  printf '   %-34s' "$(basename "$f")"
  "${PSQL[@]}" -d "$DB" -f "$f" >/dev/null
  echo "ok"
done

echo "== assertions"
"${PSQL[@]}" -d "$DB" -f "$ROOT/supabase/local/01_assertions.sql"

echo
echo "SCHEMA OK"
