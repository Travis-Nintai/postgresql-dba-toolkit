#!/usr/bin/env bash
#
# run_sql_check.sh
#
# Run a PostgreSQL diagnostic SQL script with logging and exit codes.
#
# Usage:
#   bash/run_sql_check.sh -f sql/db_health_check.sql [-h host] [-p port]
#                         [-U user] [-d dbname] [-v name=value ...]
#
# Connection defaults come from the standard libpq environment variables
# (PGHOST, PGPORT, PGUSER, PGDATABASE) when flags are not given.
#
# Exit codes:
#   0  check ran successfully
#   1  usage error
#   2  could not connect to PostgreSQL
#   3  the SQL script reported an error
#
# Logs are written to logs/<script>_<timestamp>.log.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "${LOG_DIR}"

usage() {
    cat <<EOF
Usage: $(basename "$0") -f <sql_file> [-h host] [-p port] [-U user] [-d dbname] [-v name=value ...]

  -f  SQL script to run (required)
  -h  database host (default: \$PGHOST or localhost)
  -p  port (default: \$PGPORT or 5432)
  -U  user (default: \$PGUSER or current OS user)
  -d  database (default: \$PGDATABASE or postgres)
  -v  psql variable in name=value form; may be repeated
EOF
}

SQL_FILE=""
HOST="${PGHOST:-localhost}"
PORT="${PGPORT:-5432}"
USER="${PGUSER:-$(id -un)}"
DBNAME="${PGDATABASE:-postgres}"
PSQL_VARS=()

while getopts ":f:h:p:U:d:v:" opt; do
    case "${opt}" in
        f) SQL_FILE="${OPTARG}" ;;
        h) HOST="${OPTARG}" ;;
        p) PORT="${OPTARG}" ;;
        U) USER="${OPTARG}" ;;
        d) DBNAME="${OPTARG}" ;;
        v) PSQL_VARS+=("-v" "${OPTARG}") ;;
        *) usage; exit 1 ;;
    esac
done

if [[ -z "${SQL_FILE}" ]]; then
    echo "ERROR: -f <sql_file> is required." >&2
    usage
    exit 1
fi

if [[ ! -f "${SQL_FILE}" ]]; then
    echo "ERROR: SQL file not found: ${SQL_FILE}" >&2
    exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: psql is not installed or not on PATH." >&2
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BASE="$(basename "${SQL_FILE}" .sql)"
LOG_FILE="${LOG_DIR}/${BASE}_${STAMP}.log"

echo "Running ${SQL_FILE} against ${USER}@${HOST}:${PORT}/${DBNAME}"
echo "Log: ${LOG_FILE}"

# 1. Connectivity probe before running anything.
if ! psql -h "${HOST}" -p "${PORT}" -U "${USER}" -d "${DBNAME}" \
        -tAc "SELECT 1" >/dev/null 2>"${LOG_FILE}.connect_err"; then
    echo "ERROR: could not connect to PostgreSQL ${HOST}:${PORT}/${DBNAME}." >&2
    cat "${LOG_FILE}.connect_err" >&2
    rm -f "${LOG_FILE}.connect_err"
    exit 2
fi
rm -f "${LOG_FILE}.connect_err"

# 2. Run the check. ON_ERROR_STOP=1 turns any SQL error into a psql failure.
if psql -h "${HOST}" -p "${PORT}" -U "${USER}" -d "${DBNAME}" \
        -v ON_ERROR_STOP=1 "${PSQL_VARS[@]}" \
        -f "${SQL_FILE}" >"${LOG_FILE}" 2>&1; then
    echo "OK: check completed successfully."
    exit 0
else
    echo "ERROR: the SQL script reported an error. See ${LOG_FILE}." >&2
    exit 3
fi
