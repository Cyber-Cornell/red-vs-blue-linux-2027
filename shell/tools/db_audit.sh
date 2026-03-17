#!/bin/sh

# ==============================================================================
# Deep Database Auditor
# Checks: UDF Rootkits, Malicious Stored Procedures, File Privileges, Untrusted Langs
# Supported: MySQL, MariaDB, PostgreSQL
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Must run as root."
  exit 1
fi

echo "Starting Deep Database Audit..."
echo "----------------------------------------------------------------"

# ==============================================================================
# 1. OS-LEVEL CHECKS (History Files)
# ==============================================================================
echo "[1] Checking for cleartext passwords in history files..."
# Admins often type passwords in CLI args, which get saved to history.
# Attackers read these to move laterally.
for hist in /root/.mysql_history /home/*/.mysql_history /root/.psql_history /home/*/.psql_history; do
  if [ -f "$hist" ]; then
    if grep -qi "IDENTIFIED BY" "$hist" || grep -qi "PASSWORD" "$hist"; then
      echo "  [WARN] Cleartext password artifacts found in: $hist"
      echo "         Action: rm $hist && ln -s /dev/null $hist"
    fi
  fi
done

# ==============================================================================
# 2. MYSQL / MARIADB AUDIT
# ==============================================================================
if command -v mysql >/dev/null 2>&1; then
  echo ""
  echo "[2] MySQL/MariaDB Detected. Auditing..."

  # Define a helper to run queries safely
  # -B: Batch (tab separated) -N: Skip headers -e: Execute
  run_sql() {
    mysql -BNe "$1" 2>/dev/null
  }

  # A. Check for UDF Rootkits (The #1 DB Persistence Vector)
  # Attackers load a .so file (like lib_mysqludf_sys.so) to run OS commands.
  # A clean DB usually has an empty mysql.func table.
  UDFS=$(run_sql "SELECT name, dl FROM mysql.func;")
  if [ -n "$UDFS" ]; then
    echo "  [CRITICAL] User Defined Functions (UDFs) found!"
    echo "  Malware often uses these to execute OS commands (sys_exec)."
    echo "  Entries:"
    echo "$UDFS"
  else
    echo "  [OK] No User Defined Functions (UDFs) loaded."
  fi

  # B. Check for 'secure_file_priv' (Web Shell Vector)
  # If this is empty, users can write files anywhere (e.g., /var/www/html/shell.php)
  SEC_FILE=$(run_sql "SHOW VARIABLES LIKE 'secure_file_priv';" | awk '{print $2}')
  if [ -z "$SEC_FILE" ] || [ "$SEC_FILE" = "/" ]; then
    echo "  [HIGH RISK] 'secure_file_priv' is empty or root (/). users can write files anywhere."
  elif [ "$SEC_FILE" = "NULL" ]; then
    echo "  [OK] 'secure_file_priv' is NULL (File export disabled)."
  else
    echo "  [INFO] File export restricted to: $SEC_FILE"
  fi

  # C. Check Users with FILE privilege
  # These users can read/write files on the OS.
  FILE_USERS=$(run_sql "SELECT user, host FROM mysql.user WHERE File_priv='Y';")
  if [ -n "$FILE_USERS" ]; then
    echo "  [WARN] Users with FILE (Read/Write OS) privilege:"
    echo "$FILE_USERS"
  fi

  # D. Malicious Stored Procedures & Triggers
  # Scanning routine bodies for "sys_exec", "cmd", "shell"
  echo "  Scanning Stored Procedures for suspicious keywords..."
  SUSPICIOUS_ROUTINES=$(run_sql "SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_DEFINITION LIKE '%sys_exec%' OR ROUTINE_DEFINITION LIKE '%cmd%' OR ROUTINE_DEFINITION LIKE '%shell_exec%';")
  if [ -n "$SUSPICIOUS_ROUTINES" ]; then
    echo "  [CRITICAL] Suspicious code found in Stored Procedures:"
    echo "$SUSPICIOUS_ROUTINES"
  fi
else
  echo ""
  echo "[2] MySQL/MariaDB not installed or not in PATH."
fi

# ==============================================================================
# 3. POSTGRESQL AUDIT
# ==============================================================================
if command -v psql >/dev/null 2>&1; then
  echo ""
  echo "[3] PostgreSQL Detected. Auditing..."

  # Helper for PG execution
  run_pg() {
    su - postgres -c "psql -t -c \"$1\"" 2>/dev/null
  }

  # A. Untrusted Languages (Python/Perl/C execution)
  # 'plpythonu' or 'plperlu' ('u' stands for untrusted) allows OS execution.
  LANGS=$(run_pg "SELECT lanname FROM pg_language WHERE lanpltrusted = false;")
  if echo "$LANGS" | grep -qE "python|perl|tcl|c"; then
    echo "  [WARN] Untrusted languages enabled (Potential RCE vector):"
    echo "$LANGS" | grep -E "python|perl|tcl|c"
  else
    echo "  [OK] No untrusted languages (plpythonu/plperlu) found."
  fi

  # B. Extensions check (similar to UDFs)
  # extensions like 'adminpack' or 'dblink' can be abused.
  EXTS=$(run_pg "SELECT extname FROM pg_extension;")
  echo "  Installed Extensions (Verify these):"
  echo "$EXTS" | tr -d ' ' | sed '/^$/d' | sed 's/^/    - /'

  # C. Superusers
  SUPERS=$(run_pg "SELECT usename FROM pg_user WHERE usesuper = true;")
  echo "  Superusers (Full OS Access via DB):"
  echo "$SUPERS" | tr -d ' ' | sed '/^$/d' | sed 's/^/    - /'

else
  echo ""
  echo "[3] PostgreSQL not installed."
fi

echo "----------------------------------------------------------------"
echo "Database Audit Complete."
