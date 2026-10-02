#!/bin/sh
# Read-only local database metadata survey; query failures are coverage gaps.
set -u
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
. "$SCRIPT_DIR/../lib/portable.sh"
case "${1:-}" in
  -h|--help) printf 'Usage: %s\nUses local socket authentication; PostgreSQL database: CCDC_PG_DATABASE (default postgres).\n' "$0"; exit 0 ;;
  '') ;;
  *) die "Unknown argument: $1" ;;
esac
require_root
[ "$(uname -s)" = Linux ] || die 'This database audit supports Linux only'
have_cmd timeout || die 'timeout is required for bounded database queries'
FAILED=0
CHECKED=0
printf '%s\n' '=== DATABASE HISTORY EXPOSURE ==='
for _hist in /root/.mysql_history /home/*/.mysql_history /root/.psql_history /home/*/.psql_history; do
  [ -f "$_hist" ] || continue
  if grep -qiE 'IDENTIFIED BY|PASSWORD' "$_hist"; then
    printf '[REVIEW] Possible credential material in %s (contents redacted); preserve securely before remediation.\n' "$_hist"
  fi
done

mysql_query() {
  printf '\n--- %s ---\n' "$1"
  if ! timeout 15 "$MYSQL_CLIENT" --no-defaults --protocol=socket --host=localhost --connect-timeout=5 --batch --skip-column-names --execute "$2"; then
    printf '[UNKNOWN] MySQL query failed; do not interpret missing rows as a clean result.\n'
    FAILED=1
  fi
}
MYSQL_CLIENT=''
if have_cmd mariadb; then MYSQL_CLIENT=mariadb; elif have_cmd mysql; then MYSQL_CLIENT=mysql; fi
if [ -n "$MYSQL_CLIENT" ]; then
  CHECKED=$((CHECKED + 1))
  printf '\n%s\n' '=== MYSQL / MARIADB (local client authentication) ==='
  mysql_query 'Loadable UDFs (review provenance; presence is not proof of compromise)' 'SELECT name, dl FROM mysql.func;'
  mysql_query 'File import/export restriction (empty is unrestricted subject to FILE and OS permissions)' "SHOW VARIABLES LIKE 'secure_file_priv';"
  mysql_query 'Accounts with FILE privilege' "SELECT user, host FROM mysql.user WHERE File_priv='Y';"
  mysql_query 'Privileged and remotely accessible accounts' "SELECT user, host, Super_priv, Grant_priv FROM mysql.user;"
  mysql_query 'Stored routines needing review' "SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, DEFINER FROM information_schema.ROUTINES WHERE ROUTINE_DEFINITION LIKE '%sys_exec%' OR ROUTINE_DEFINITION LIKE '%shell_exec%' OR ROUTINE_DEFINITION LIKE '%OUTFILE%';"
  mysql_query 'Triggers and definers' 'SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE, DEFINER FROM information_schema.TRIGGERS;'
  mysql_query 'Scheduled events and definers' 'SELECT EVENT_SCHEMA, EVENT_NAME, DEFINER, STATUS FROM information_schema.EVENTS;'
else
  printf '[SKIP] MySQL/MariaDB client unavailable.\n'
fi

pg_query() {
  printf '\n--- %s ---\n' "$1"
  if ! runuser -u postgres -- env PGHOST='' PGHOSTADDR='' PGSERVICE='' PGCONNECT_TIMEOUT=5 PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000' \
    psql -X -w -v ON_ERROR_STOP=1 -d "${CCDC_PG_DATABASE:-postgres}" -P pager=off -c "$2"; then
    printf '[UNKNOWN] PostgreSQL query failed; do not interpret missing rows as a clean result.\n'
    FAILED=1
  fi
}
if have_cmd psql; then
  CHECKED=$((CHECKED + 1))
  if have_cmd runuser && id postgres >/dev/null 2>&1; then
    printf '\n%s\n' '=== POSTGRESQL (selected database only) ==='
    pg_query 'Nonbuiltin untrusted languages' "SELECT lanname FROM pg_language WHERE NOT lanpltrusted AND lanname NOT IN ('c', 'internal');"
    pg_query 'Installed extensions (review provenance)' 'SELECT extname, extversion FROM pg_extension;'
    pg_query 'Privileged roles' 'SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls FROM pg_roles WHERE rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls;'
    pg_query 'Role memberships' 'SELECT roleid::regrole, member::regrole, admin_option FROM pg_auth_members;'
    pg_query 'User event triggers' 'SELECT evtname, evtevent, evtowner::regrole, evtenabled FROM pg_event_trigger;'
    pg_query 'Non-template databases (repeat audit per application database)' 'SELECT datname FROM pg_database WHERE NOT datistemplate;'
  else
    printf '[UNKNOWN] PostgreSQL requires runuser and a local postgres OS account.\n'
    FAILED=1
  fi
else
  printf '[SKIP] PostgreSQL client unavailable.\n'
fi
[ "$CHECKED" -gt 0 ] || { printf '[UNKNOWN] No database client available; no live database checks completed.\n'; exit 2; }
printf '\n%s\n' '[INFO] Metadata visibility depends on privileges. No data or configuration was changed.'
exit "$FAILED"
